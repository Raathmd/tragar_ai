defmodule TragarAi.Connectors.FreightWare do
  @moduledoc """
  FreightWare (Dovetail) read-only connector — load/consignment status, ETA,
  waybill lookup and proof-of-delivery. Wraps `TragarAi.Dovetail.Client`.

  The response shapes mirror the live FreightWare V2 API (as used by the Rust
  reference, `tragar_quote_dioxus`):

    * waybill   → `response.esWaybills.Waybills[]`
    * tracking  → `response.esTrackAndTrace.TrackAndTrace[]` (each event may
      carry a `POD` with capitalised keys: `PODDate`, `PODImageURL`, …)

  `Client` already strips the outer `response` envelope, so this module reads
  from `esWaybills` / `esTrackAndTrace`.
  """

  @behaviour TragarAi.Connectors.Source

  alias TragarAi.Dovetail.Client

  @impl true
  def name, do: "FreightWare"

  @impl true
  def intents, do: [:load_status, :eta, :waybill_lookup, :pod]

  @impl true
  def fetch(intent, %{waybill: waybill})
      when is_binary(waybill) and intent in [:load_status, :eta, :pod] do
    with {:ok, waybill_resp} <- Client.get_waybill(waybill),
         wb when wb != %{} <- extract_waybill(waybill_resp),
         {:ok, tracking_resp} <- Client.track_and_trace(:waybills, waybill) do
      {:ok, facts(waybill, wb, extract_events(tracking_resp))}
    else
      %{} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def fetch(:waybill_lookup, %{waybill: waybill}) when is_binary(waybill) do
    with {:ok, waybill_resp} <- Client.get_waybill(waybill),
         wb when wb != %{} <- extract_waybill(waybill_resp) do
      {:ok, facts(waybill, wb, [])}
    else
      %{} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def fetch(intent, _entities) when intent in [:load_status, :eta, :pod, :waybill_lookup],
    do: {:error, :missing_waybill}

  def fetch(intent, _), do: {:error, {:unsupported_intent, intent}}

  # ── Normalisation ───────────────────────────────────────────────────────────

  defp facts(waybill_number, wb, events) do
    normalized = Enum.map(events, &normalize_event/1)

    %{
      "waybill_number" => dig(wb, "waybillNumber") || waybill_number,
      "status" => dig(wb, "statusDescription") || dig(wb, "statusCode"),
      "status_code" => dig(wb, "statusCode"),
      "service_type" => dig(wb, "serviceType"),
      "service_type_description" => dig(wb, "serviceTypeDescription"),
      "consignor" => dig(wb, "consignorName"),
      "consignor_city" => dig(wb, "consignorCity"),
      "consignee" => dig(wb, "consigneeName"),
      "consignee_city" => dig(wb, "consigneeCity"),
      "number_of_items" => dig(wb, "numberOfItems"),
      "waybill_date" => dig(wb, "waybillDate"),
      "eta" => dig(wb, "estimatedDelivery") || dig(wb, "deliveryDate"),
      "events" => normalized,
      "last_event" => List.first(normalized),
      "pod" => extract_pod(events)
    }
    |> compact()
  end

  # A single waybill comes back inside esWaybills.Waybills; tolerate a flat map too.
  defp extract_waybill(%{"esWaybills" => %{"Waybills" => [wb | _]}}) when is_map(wb), do: wb
  defp extract_waybill(%{"esWaybills" => %{"Waybills" => []}}), do: %{}
  defp extract_waybill(%{"waybillNumber" => _} = wb), do: wb
  defp extract_waybill(_), do: %{}

  defp extract_events(%{"esTrackAndTrace" => %{"TrackAndTrace" => events}}) when is_list(events),
    do: events

  defp extract_events(%{"TrackAndTrace" => events}) when is_list(events), do: events
  defp extract_events(%{"events" => events}) when is_list(events), do: events
  defp extract_events(events) when is_list(events), do: events
  defp extract_events(_), do: []

  defp normalize_event(e) do
    %{
      "code" => dig(e, "eventCode"),
      "date" => dig(e, "eventDate"),
      "time" => dig(e, "eventTime"),
      "description" => dig(e, "eventDescription"),
      "branch" => dig(e, "branchCode")
    }
    |> compact()
  end

  # POD is nested on a delivery event under the capitalised "POD" key.
  defp extract_pod(events) do
    case Enum.find_value(events, fn e -> Map.get(e, "POD") || Map.get(e, "pod") end) do
      pod when is_map(pod) ->
        %{
          "date" => dig(pod, "PODDate"),
          "time" => dig(pod, "PODTime"),
          "receiver" => dig(pod, "receiverName"),
          "parcels" => dig(pod, "numberofParcels"),
          "image_url" => dig(pod, "PODImageURL"),
          "grn_reference" => dig(pod, "GRNReference"),
          "comments" => dig(pod, "comments")
        }
        |> compact()

      _ ->
        nil
    end
  end

  defp dig(map, key) when is_map(map), do: Map.get(map, key)
  defp dig(_, _), do: nil

  defp compact(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end) |> Map.new()
  end
end
