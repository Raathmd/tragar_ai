defmodule TragarAi.Connectors.FreightWare do
  @moduledoc """
  FreightWare (Dovetail) read-only connector — load/consignment status, ETA,
  waybill lookup and proof-of-delivery. Wraps `TragarAi.Dovetail.Client`.
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
    with {:ok, waybill_data} <- Client.get_waybill(waybill),
         {:ok, tracking} <- Client.track_and_trace(:waybills, waybill) do
      {:ok, facts(waybill, waybill_data, tracking)}
    end
  end

  def fetch(:waybill_lookup, %{waybill: waybill}) when is_binary(waybill) do
    with {:ok, waybill_data} <- Client.get_waybill(waybill) do
      {:ok, facts(waybill, waybill_data, %{})}
    end
  end

  def fetch(intent, _entities) when intent in [:load_status, :eta, :pod, :waybill_lookup],
    do: {:error, :missing_waybill}

  def fetch(intent, _), do: {:error, {:unsupported_intent, intent}}

  # ── Normalisation ───────────────────────────────────────────────────────────

  defp facts(waybill, data, tracking) do
    events = events(tracking)

    %{
      "waybill_number" => dig(data, ["waybillNumber", "waybill_number"]) || waybill,
      "status" =>
        dig(data, ["statusDescription", "status_description"]) ||
          dig(data, ["statusCode", "status_code"]),
      "status_code" => dig(data, ["statusCode", "status_code"]),
      "service_type" => dig(data, ["serviceType", "service_type"]),
      "consignor" => dig(data, ["consignorName", "consignor_name"]),
      "consignee" => dig(data, ["consigneeName", "consignee_name"]),
      "eta" => dig(data, ["eta", "estimatedDelivery", "estimated_delivery"]),
      "events" => events,
      "last_event" => List.first(events),
      "pod" => pod(tracking, events)
    }
    |> compact()
  end

  defp events(tracking) do
    tracking
    |> extract_events()
    |> Enum.map(fn e ->
      %{
        "code" => dig(e, ["eventCode", "event_code"]),
        "date" => dig(e, ["eventDate", "event_date"]),
        "time" => dig(e, ["eventTime", "event_time"]),
        "description" => dig(e, ["eventDescription", "event_description"]),
        "branch" => dig(e, ["branchCode", "branch_code"])
      }
      |> compact()
    end)
  end

  defp extract_events(%{"events" => e}) when is_list(e), do: e
  defp extract_events(%{"trackEvents" => e}) when is_list(e), do: e
  defp extract_events(%{"trackingEvents" => e}) when is_list(e), do: e
  defp extract_events(e) when is_list(e), do: e
  defp extract_events(_), do: []

  defp pod(tracking, events) do
    raw = get_in(tracking, ["pod"]) || Enum.find_value(events, fn e -> e["pod"] end)

    case raw do
      pod when is_map(pod) ->
        %{
          "date" => dig(pod, ["podDate", "pod_date"]),
          "receiver" => dig(pod, ["receiverName", "receiver_name"]),
          "image_url" => dig(pod, ["podImageUrl", "pod_image_url"])
        }
        |> compact()

      _ ->
        nil
    end
  end

  defp dig(map, keys) when is_map(map), do: Enum.find_value(keys, fn k -> Map.get(map, k) end)
  defp dig(_, _), do: nil

  defp compact(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end) |> Map.new()
  end
end
