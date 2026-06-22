defmodule TragarAi.QuoteIntake.Flow do
  @moduledoc """
  Pure conversation logic for guided quote intake — no I/O, no persistence.

  The app walks the customer through the parameters FreightWare needs for a
  quote, one question at a time. Each Freshdesk reply answers the slot we last
  asked about; when every slot is filled we assemble the FreightWare quote
  parameters and ask the customer to confirm.
  """

  # Ordered slots = the questions we guide the customer through, plus the metadata
  # a machine-readable workflow descriptor needs. Keys stay aligned with
  # `to_quote_params/2` / `TragarAi.Freight.build_quote/1`.
  @slots [
    %{
      key: "service",
      question:
        "Which service do you need — Economy, Road Express, Overnight, Same-day, or Abnormal?",
      required: true,
      type: "enum",
      maps_to: ["serviceType"],
      hint: "One of Tragar's FreightWare service types (see allowed_values)."
    },
    %{
      key: "collection",
      question: "Where are we collecting from? Please give the suburb and postal code.",
      required: true,
      type: "address",
      maps_to: ["consignorName", "consignorPostalCode"],
      hint: "Suburb/town plus a 4-digit postal code."
    },
    %{
      key: "delivery",
      question: "Where are we delivering to? Suburb and postal code, please.",
      required: true,
      type: "address",
      maps_to: ["consigneeName", "consigneePostalCode"],
      hint: "Suburb/town plus a 4-digit postal code."
    },
    %{
      key: "goods",
      question:
        "What are you shipping? Tell me the contents, number of items, and total mass (kg).",
      required: true,
      type: "freight",
      maps_to: ["Items[].description", "Items[].pieces", "Items[].mass"],
      hint: "Contents, number of pieces, and total mass in kilograms."
    }
  ]

  @doc "The opening question for a brand-new conversation."
  def opening_question, do: hd(@slots).question

  @doc "Slot keys in order."
  def slot_keys, do: Enum.map(@slots, & &1.key)

  @doc """
  Machine-readable description of the quote workflow — the steps, parameters and
  actions a caller (e.g. Freddy on Freshdesk) needs to take a customer through
  creating a quote. `allowed_values` is injected per step (e.g. live service
  types) by the caller.
  """
  def workflow(opts \\ []) do
    allowed = Keyword.get(opts, :allowed_values, %{})

    %{
      "name" => "create_quote",
      "description" =>
        "Guided FreightWare quote creation for a Tragar account. The account is supplied " <>
          "by Freshdesk in the request body; ask the customer each step in order, then submit.",
      "account_source" => "freshdesk_request_body",
      "steps" =>
        Enum.with_index(@slots, 1)
        |> Enum.map(fn {s, i} ->
          %{
            "order" => i,
            "key" => s.key,
            "question" => s.question,
            "required" => s.required,
            "type" => s.type,
            "freightware_fields" => s.maps_to,
            "hint" => s.hint,
            "allowed_values" => Map.get(allowed, s.key, [])
          }
        end),
      "runner" => %{
        "endpoint" => "POST /api/quotes/intake",
        "note" =>
          "Relay each customer message with the same ticket_id; the response 'reply' is the next " <>
            "question. When status is 'ready', reply ACCEPT to create the quote in FreightWare or REJECT to cancel."
      }
    }
  end

  @doc """
  Record the customer's answer to the slot we were awaiting, then return the
  next question — or, once everything is gathered, a confirmation summary.

  Returns `{:ask, slots, question}` or `{:ready, slots, summary}`.
  """
  def advance(slots, message) do
    slots =
      case next_unfilled(slots) do
        nil -> slots
        key -> Map.put(slots, key, String.trim(message))
      end

    case next_unfilled(slots) do
      nil -> {:ready, slots, summary(slots)}
      key -> {:ask, slots, question(key)}
    end
  end

  @doc "Interpret a confirmation reply once a quote is ready."
  def decision(message) do
    t = String.downcase(message)

    cond do
      Regex.match?(~r/\b(accept|yes|confirm|go ahead|proceed|create)\b/, t) -> :accept
      Regex.match?(~r/\b(reject|no|cancel|decline|stop)\b/, t) -> :reject
      true -> :unclear
    end
  end

  @doc """
  Confirmation summary once a quote is ready, including the live rate if the
  Server obtained one.
  """
  def ready_summary(slots, rate) do
    price = if rate, do: " The estimated rate is R #{rate}.", else: ""

    "Here's your quote request — from #{slots["collection"]} to #{slots["delivery"]}, " <>
      "#{slots["service"]}, #{slots["goods"]}.#{price} " <>
      "Reply ACCEPT to create the quote in FreightWare, or REJECT to cancel."
  end

  @doc "Assemble FreightWare quote params from the gathered slots."
  def to_quote_params(slots, account) do
    %{
      "account_reference" => account,
      # Prefer the resolved FreightWare service code over the customer's words.
      "service_type" => slots["service_code"] || slots["service"],
      "consignor_name" => name_part(slots["collection"]),
      "consignor_postal_code" => postal(slots["collection"]),
      "consignee_name" => name_part(slots["delivery"]),
      "consignee_postal_code" => postal(slots["delivery"]),
      "items" => [
        %{
          "description" => slots["goods"],
          "pieces" => pieces(slots["goods"]),
          "mass" => mass(slots["goods"])
        }
      ]
    }
  end

  # ── internals ────────────────────────────────────────────────────────────────

  defp next_unfilled(slots) do
    Enum.find(slot_keys(), fn key -> blank?(Map.get(slots, key)) end)
  end

  defp question(key), do: Enum.find(@slots, &(&1.key == key)).question

  defp summary(slots) do
    "Here's your quote request — from #{slots["collection"]} to #{slots["delivery"]}, " <>
      "#{slots["service"]}, #{slots["goods"]}. Reply ACCEPT to create the quote in FreightWare, or REJECT to cancel."
  end

  defp blank?(nil), do: true
  defp blank?(v) when is_binary(v), do: String.trim(v) == ""
  defp blank?(_), do: false

  # A 4-digit South African postal code.
  defp postal(nil), do: nil
  defp postal(text), do: Regex.run(~r/\b(\d{4})\b/, text) |> List.last()

  # Everything that isn't the postal code, as the location/contact name.
  defp name_part(nil), do: nil

  defp name_part(text) do
    text |> String.replace(~r/\b\d{4}\b/, "") |> String.trim() |> String.trim(",")
  end

  defp mass(nil), do: nil

  defp mass(text) do
    case Regex.run(~r/(\d+(?:\.\d+)?)\s*kg/i, text) do
      [_, n] -> n
      _ -> nil
    end
  end

  defp pieces(nil), do: nil

  defp pieces(text) do
    case Regex.run(~r/(\d+)\s*(?:item|piece|box|pallet|parcel|carton)/i, text) do
      [_, n] -> n
      _ -> nil
    end
  end
end
