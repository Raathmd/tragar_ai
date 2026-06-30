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
      question:
        "Where are we collecting from? Give the site name (e.g. “Italtile Menlyn”) — I'll look it up in FreightWare and confirm.",
      required: true,
      type: "site",
      maps_to: ["consignorSite", "consignorSuburb", "consignorCity", "consignorPostalCode"],
      hint: "A site name or reference; resolved to a FreightWare site via the address lookup."
    },
    %{
      key: "delivery",
      question: "Where are we delivering to? Give the site name — I'll look it up and confirm.",
      required: true,
      type: "site",
      maps_to: ["consigneeSite", "consigneeSuburb", "consigneeCity", "consigneePostalCode"],
      hint: "A site name or reference; resolved to a FreightWare site via the address lookup."
    },
    %{
      key: "goods",
      question:
        "What are you shipping? Give the contents, number of items, total mass in kg, and the " <>
          "dimensions per item as L×W×H in cm (e.g. 120×100×150). FreightWare needs all four to rate.",
      required: true,
      type: "freight",
      maps_to: [
        "Items[].description",
        "Items[].quantity",
        "Items[].totalWeight",
        "Items[].length",
        "Items[].width",
        "Items[].height"
      ],
      hint: "Contents, number of pieces, total mass (kg), and L×W×H (cm) — all required to rate."
    }
  ]

  @doc "The opening question for a brand-new conversation."
  def opening_question, do: hd(@slots).question

  @doc "Slot keys in order."
  def slot_keys, do: Enum.map(@slots, & &1.key)

  @doc """
  Machine-readable description of the quote workflow — the steps, parameters and
  actions a caller (e.g. the Freshdesk automation) needs to take a customer
  through creating a quote. `allowed_values` is injected per step (e.g. live
  service types) by the caller.
  """
  def workflow(opts \\ []) do
    allowed = Keyword.get(opts, :allowed_values, %{})

    %{
      "name" => "create_quote",
      "description" =>
        "Guided FreightWare quote creation for a Tragar account. The account is NOT supplied by " <>
          "the caller — it is derived from the ticket requester's Freshdesk Company (a requester " <>
          "not linked to an account is refused). Ask the customer each step in order, then submit.",
      "account_source" => "derived_from_freshdesk_ticket_company",
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

  @doc "The first slot not yet filled, or nil when the quote is ready."
  def next_unfilled(slots), do: Enum.find(slot_keys(), &(not filled?(slots, &1)))

  @doc "The question text for a slot key."
  def question(key), do: Enum.find(@slots, &(&1.key == key)).question

  @doc "Collection/delivery are resolved to a FreightWare site, not a bare string."
  def address_slot?(key), do: key in ["collection", "delivery"]

  @doc """
  Is a slot filled? String slots need a non-blank value; address slots need a
  resolved site map (with a `site_code`).
  """
  def filled?(slots, key) do
    case Map.get(slots, key) do
      %{} = site when key in ["collection", "delivery"] -> present?(site["site_code"])
      v when key in ["collection", "delivery"] -> match?(%{}, v)
      v -> not blank?(v)
    end
  end

  defp present?(v), do: is_binary(v) and String.trim(v) != ""

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

    "Here's your quote request — from #{place_label(slots["collection"])} to " <>
      "#{place_label(slots["delivery"])}, #{slots["service"]}, #{slots["goods"]}.#{price} " <>
      "Reply ACCEPT to create the quote in FreightWare, or REJECT to cancel."
  end

  @doc "Human label for a resolved site or a bare string."
  def place_label(%{} = site),
    do: "#{site["name"] || site["site_name"]} (#{site["site_code"]})"

  def place_label(text) when is_binary(text), do: text
  def place_label(_), do: "?"

  @doc "Assemble FreightWare quote params from the gathered slots."
  def to_quote_params(slots, account) do
    %{
      "account_reference" => account,
      # Prefer the resolved FreightWare service code over the customer's words.
      "service_type" => slots["service_code"] || slots["service"],
      "items" => [
        %{
          "description" => slots["goods"],
          "quantity" => pieces(slots["goods"]),
          "weight" => mass(slots["goods"]),
          "length" => dim(slots["goods"], 0),
          "width" => dim(slots["goods"], 1),
          "height" => dim(slots["goods"], 2)
        }
      ]
    }
    |> Map.merge(party_fields("consignor", slots["collection"]))
    |> Map.merge(party_fields("consignee", slots["delivery"]))
  end

  # A resolved site → full FreightWare address fields; a bare string → best-effort
  # name + postal (fallback when no site was confirmed).
  defp party_fields(prefix, %{} = site) do
    %{
      "#{prefix}_site" => site["site_code"],
      "#{prefix}_name" => site["name"] || site["site_name"],
      "#{prefix}_building" => site["building"],
      "#{prefix}_street" => site["street"],
      "#{prefix}_suburb" => site["suburb"],
      "#{prefix}_city" => site["city"],
      "#{prefix}_postal_code" => site["post_code"] || site["postal_code"]
    }
  end

  defp party_fields(prefix, text) when is_binary(text),
    do: %{"#{prefix}_name" => name_part(text), "#{prefix}_postal_code" => postal(text)}

  defp party_fields(_prefix, _), do: %{}

  # ── internals ────────────────────────────────────────────────────────────────

  defp blank?(nil), do: true
  defp blank?(v) when is_binary(v), do: String.trim(v) == ""
  defp blank?(_), do: false

  # A 4-digit South African postal code. Only ever called with a binary (the sole
  # caller, party_fields/2, guards on `is_binary(text)`).
  defp postal(text), do: Regex.run(~r/\b(\d{4})\b/, text) |> List.last()

  # Everything that isn't the postal code, as the location/contact name.
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

  # Dimensions written as L×W×H (or LxWxH), in cm.
  defp dim(nil, _i), do: nil

  defp dim(text, i) do
    case Regex.run(~r/(\d+(?:\.\d+)?)\s*[x×]\s*(\d+(?:\.\d+)?)\s*[x×]\s*(\d+(?:\.\d+)?)/i, text) do
      [_, l, w, h] -> Enum.at([l, w, h], i)
      _ -> nil
    end
  end
end
