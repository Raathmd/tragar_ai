defmodule TragarAi.Freshdesk.FieldMapper do
  @moduledoc """
  Best-effort mapping of the live facts the assistant retrieved from the source
  systems (FreightWare/Vantage/…) onto **editable custom** Freshdesk ticket
  fields, so the agent opens a ticket with the data already filled in.

  Rules, by design:

    * Only **custom** ticket fields are filled (`type` starting with `custom_`).
      Default workflow fields (status, priority, type, group) and — crucially —
      **assignment (responder/group) are never touched**: a human agent owns who
      the ticket goes to.
    * **Dropdown** fields are only filled when the fact value matches one of the
      field's allowed `choices` (case-insensitive); a non-matching value is
      skipped rather than sent (which Freshdesk would reject).
    * Matching is by normalized field name/label against the fact key (and a
      small alias table for the common Tragar facts). Anything we can't match
      confidently is left blank — better empty than wrong.

  Returns `%{field_name => value}` suitable for `update_ticket(id, %{custom_fields: ...})`.
  """

  # Fact key → normalized field-name forms it may fill. The fact's own key
  # (normalized) is always a candidate too; these add human-label synonyms.
  @aliases %{
    "status" => ~w(status waybillstatus deliverystatus loadstatus shipmentstatus),
    "status_description" => ~w(status waybillstatus deliverystatus loadstatus),
    "status_code" => ~w(statuscode),
    "waybill_number" => ~w(waybill waybillno loadnumber loadno shipmentnumber),
    "account_reference" => ~w(account accountcode accountref freightwareaccount customeraccount),
    "consignee" => ~w(consignee recipient deliverto receiver),
    "consignee_name" => ~w(consignee recipient deliverto receiver),
    "consignee_city" => ~w(consigneecity destinationcity deliverycity destination),
    "consignor" => ~w(consignor sender collectfrom shipper),
    "consignor_name" => ~w(consignor sender collectfrom shipper),
    "service_type" => ~w(service servicetype servicelevel),
    "charged_amount" => ~w(amount charge chargedamount value),
    "quote_number" => ~w(quote quotenumber quoteno),
    "pod" => ~w(pod proofofdelivery),
    "pod_image_url" => ~w(pod proofofdelivery podurl podimage)
  }

  @doc """
  Custom-field updates `%{field_name => value}` we can confidently fill from the
  given facts. `ticket_fields` is the raw list from `GET /api/v2/ticket_fields`.
  """
  @spec custom_field_updates([map()], map()) :: %{optional(String.t()) => term()}
  def custom_field_updates(ticket_fields, facts)
      when is_list(ticket_fields) and is_map(facts) do
    facts = stringify_keys(facts)

    for field <- ticket_fields, custom?(field), reduce: %{} do
      acc ->
        case value_for(field, facts) do
          {:ok, value} -> Map.put(acc, field["name"], value)
          :none -> acc
        end
    end
  end

  def custom_field_updates(_, _), do: %{}

  # ── internals ────────────────────────────────────────────────────────────────

  defp custom?(field),
    do: field |> Map.get("type", "") |> to_string() |> String.starts_with?("custom_")

  defp value_for(field, facts) do
    target = norm(field["label"] || field["name"])

    case find_fact(target, facts) do
      {:ok, raw} -> coerce(field, raw)
      :none -> :none
    end
  end

  # A fact matches when the field's normalized name/label equals the fact key's
  # normalized form or any of that key's aliases.
  defp find_fact(target, facts) do
    Enum.find_value(facts, :none, fn {key, value} ->
      forms = [norm(key) | Map.get(@aliases, key, [])]

      if usable?(value) and target in forms, do: {:ok, value}, else: nil
    end)
  end

  # Dropdowns: only emit a value that matches an allowed choice (mapped to the
  # exact choice string). Free-text/number/etc.: pass the value through.
  defp coerce(field, raw) do
    case choices(field) do
      [] ->
        {:ok, scalar(raw)}

      list ->
        case Enum.find(list, &(downcase(&1) == downcase(raw))) do
          nil -> :none
          choice -> {:ok, choice}
        end
    end
  end

  defp choices(field) do
    case field["choices"] do
      list when is_list(list) -> Enum.flat_map(list, &choice_label/1)
      map when is_map(map) -> Map.keys(map)
      _ -> []
    end
  end

  # A choice can be a bare string, or (nested/older shapes) a [label, value] pair
  # or a %{"value" => ...} map — we only ever match/return the label.
  defp choice_label(label) when is_binary(label), do: [label]
  defp choice_label([label | _]) when is_binary(label), do: [label]
  defp choice_label(%{"value" => label}) when is_binary(label), do: [label]
  defp choice_label(_), do: []

  defp usable?(v), do: v not in [nil, "", []]

  defp scalar(v) when is_binary(v) or is_number(v) or is_boolean(v), do: v
  defp scalar(v), do: to_string(v)

  defp downcase(v), do: v |> to_string() |> String.downcase() |> String.trim()
  defp norm(s), do: s |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")
  defp stringify_keys(m), do: Map.new(m, fn {k, v} -> {to_string(k), v} end)
end
