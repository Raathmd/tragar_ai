defmodule TragarAi.CoreAI.Stub do
  @moduledoc """
  Deterministic, in-process stand-in for the local model. Rule-based intent
  detection and template-based phrasing — enough to run the full
  interpret → validate → fetch → phrase loop without a model, with the exact
  same contract as the real sidecar (`TragarAi.CoreAI`).
  """

  @waybill_re ~r/\b(?:load|waybill|wb|consignment)?\s*#?\s*(\d{4,})\b/i
  @account_re ~r/\b(?:account|acc|customer)\s*#?\s*([A-Z0-9]{3,})\b/i
  @quote_re ~r/\bquote\s*#?\s*(\d{3,})\b/i

  @doc false
  def interpret(question, _context \\ %{}) do
    q = String.downcase(question)
    entities = extract_entities(question)

    %{intent: classify(q, entities), entities: entities, raw: question}
  end

  defp classify(q, entities) do
    cond do
      contains?(q, ["service type", "service types", "services available"]) ->
        :service_types

      contains?(q, ["quote"]) ->
        :quote_lookup

      contains?(q, ["pod", "proof of delivery", "signed for", "who signed"]) ->
        :pod

      contains?(q, ["eta", "when will", "arrive", "how long"]) ->
        :eta

      contains?(q, ["stock", "pick", "pack", "in the warehouse", "on hand"]) ->
        :stock

      contains?(q, ["invoice", "balance", "payment", "paid", "owe", "account status"]) ->
        :invoice

      contains?(q, ["route", "distance", "planned route", "km to"]) ->
        :route

      contains?(q, ["vehicle", "truck", "fleet", "driver available"]) ->
        :vehicle_status

      contains?(q, ["ticket", "complaint", "previous query", "case"]) ->
        :ticket_context

      contains?(q, ["billing contact", "customer contact", "who is the customer", "debtor"]) ->
        :customer_lookup

      contains?(q, ["where", "status", "track", "trace", "happening with"]) ->
        :load_status

      Map.has_key?(entities, :waybill) ->
        :load_status

      true ->
        :unknown
    end
  end

  defp extract_entities(question) do
    %{}
    |> put_match(:waybill, Regex.run(@waybill_re, question))
    |> put_match(:account, Regex.run(@account_re, question))
    |> put_match(:quote, Regex.run(@quote_re, question))
  end

  defp put_match(acc, _key, nil), do: acc
  defp put_match(acc, key, [_, captured | _]), do: Map.put(acc, key, captured)
  defp put_match(acc, _key, _), do: acc

  defp contains?(q, terms), do: Enum.any?(terms, &String.contains?(q, &1))

  # ── Phrasing ────────────────────────────────────────────────────────────────

  @doc false
  def phrase(intent, facts, _context \\ %{})

  def phrase(:load_status, f, _) do
    "Waybill #{get(f, "waybill_number")} is currently #{quote_status(f)}." <>
      eta_suffix(f) <> location_suffix(f)
  end

  def phrase(:eta, f, _) do
    case get(f, "eta") do
      nil -> "I don't have an ETA on record for waybill #{get(f, "waybill_number")} yet."
      eta -> "Waybill #{get(f, "waybill_number")} is expected to arrive #{eta}."
    end
  end

  def phrase(:pod, f, _) do
    case get(f, "pod") do
      pod when is_map(pod) ->
        "Waybill #{get(f, "waybill_number")} was delivered" <>
          pod_when(pod) <> pod_receiver(pod) <> "."

      _ ->
        "There is no proof of delivery on record for waybill #{get(f, "waybill_number")} yet."
    end
  end

  def phrase(:route, f, _) do
    "Load #{get(f, "waybill_number")} is on #{get(f, "route") || "an unplanned route"}" <>
      if(get(f, "current_location"),
        do: ", currently near #{get(f, "current_location")}",
        else: ""
      ) <>
      if(get(f, "distance_remaining"),
        do: " with #{get(f, "distance_remaining")} km to go",
        else: ""
      ) <>
      if(get(f, "eta"), do: " (ETA #{get(f, "eta")}).", else: ".")
  end

  def phrase(:stock, f, _), do: generic("Stock", f)

  def phrase(:customer_lookup, f, _) do
    "#{get(f, "name") || "The customer"} (account #{get(f, "account_reference")})" <>
      if(get(f, "email"), do: " — billing contact #{get(f, "email")}", else: "") <>
      if(get(f, "description"), do: ". #{get(f, "description")}.", else: ".")
  end

  def phrase(:quote_lookup, f, _) do
    "Quote #{get(f, "quote_number")} is #{get(f, "status") || "on record"}" <>
      if(get(f, "charged_amount"), do: " at #{get(f, "charged_amount")}", else: "") <>
      if(get(f, "service_type"), do: " (#{get(f, "service_type")}).", else: ".")
  end

  def phrase(:invoice, f, _) do
    "Account #{get(f, "account_reference")}: invoice #{get(f, "invoice_number")} is " <>
      "#{String.downcase(get(f, "status") || "on record")}" <>
      if(get(f, "balance"), do: ", balance #{get(f, "balance")}", else: "") <>
      if(get(f, "due_date"), do: " (due #{get(f, "due_date")}).", else: ".")
  end

  def phrase(:vehicle_status, f, _) do
    avail =
      case get(f, "available") do
        true -> " and available"
        false -> " and not currently available"
        _ -> ""
      end

    "Vehicle #{get(f, "registration")}" <>
      if(get(f, "status"), do: " is #{get(f, "status")}", else: "") <> avail <> "."
  end

  def phrase(:service_types, f, _) do
    case get(f, "service_types") do
      [_ | _] = list -> "We offer: #{Enum.join(list, ", ")}."
      _ -> "I don't have the service list on hand."
    end
  end

  def phrase(:ticket_context, f, _) do
    "Previous ticket ##{get(f, "id")} — \"#{get(f, "subject")}\"" <>
      if(get(f, "status"), do: " (#{get(f, "status")}).", else: ".")
  end

  def phrase(_intent, facts, _) do
    "Here is what I found: #{summarise(facts)}"
  end

  # ── phrasing helpers ─────────────────────────────────────────────────────────

  defp quote_status(f), do: "\"#{get(f, "status") || "unknown"}\""

  defp eta_suffix(f), do: if(get(f, "eta"), do: " Estimated arrival #{get(f, "eta")}.", else: "")

  defp location_suffix(f),
    do:
      if(get(f, "last_event"), do: " Last update: #{event_text(get(f, "last_event"))}.", else: "")

  defp event_text(%{"description" => d, "date" => date}), do: "#{d} on #{date}"
  defp event_text(%{"description" => d}), do: d
  defp event_text(%{"event_description" => d, "event_date" => date}), do: "#{d} on #{date}"
  defp event_text(%{"event_description" => d}), do: d
  defp event_text(other), do: inspect(other)

  defp pod_when(%{"date" => date}) when is_binary(date), do: " on #{date}"
  defp pod_when(_), do: ""
  defp pod_receiver(%{"receiver" => r}) when is_binary(r), do: ", received by #{r}"
  defp pod_receiver(_), do: ""

  defp generic(label, facts), do: "#{label} details: #{summarise(facts)}"

  defp summarise(facts) when is_map(facts) do
    facts
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" or is_map(v) or is_list(v) end)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{v}" end)
  end

  defp summarise(other), do: inspect(other)

  defp get(facts, key) when is_map(facts), do: Map.get(facts, key)
  defp get(_, _), do: nil
end
