defmodule TragarAi.QuoteIntake.Flow do
  @moduledoc """
  Pure conversation logic for guided quote intake — no I/O, no persistence.

  The app walks the customer through the parameters FreightWare needs for a
  quote, one question at a time. Each Freshdesk reply answers the slot we last
  asked about; when every slot is filled we assemble the FreightWare quote
  parameters and ask the customer to confirm.
  """

  # Ordered slots = the questions we guide the customer through. Keep the keys
  # aligned with `to_quote_params/2` / `TragarAi.Freight.build_quote/1`.
  @slots [
    {"service",
     "Which service do you need — Economy, Road Express, Overnight, Same-day, or Abnormal?"},
    {"collection", "Where are we collecting from? Please give the suburb and postal code."},
    {"delivery", "Where are we delivering to? Suburb and postal code, please."},
    {"goods",
     "What are you shipping? Tell me the contents, number of items, and total mass (kg)."}
  ]

  @doc "The opening question for a brand-new conversation."
  def opening_question, do: elem(hd(@slots), 1)

  @doc "Slot keys in order."
  def slot_keys, do: Enum.map(@slots, &elem(&1, 0))

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

  @doc "Assemble FreightWare quote params from the gathered slots."
  def to_quote_params(slots, account) do
    %{
      "account_reference" => account,
      "service_type" => slots["service"],
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

  defp question(key), do: @slots |> List.keyfind(key, 0) |> elem(1)

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
