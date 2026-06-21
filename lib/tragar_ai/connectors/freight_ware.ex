defmodule TragarAi.Connectors.FreightWare do
  @moduledoc """
  FreightWare (Dovetail) read-only connector for the support-assist loop.

  Shipment and quote reads go through `TragarAi.Logistics.Cache` (read-through,
  backed by the `Shipment`/`Quote` Ash resources); reference data (service types)
  goes live via `TragarAi.Freight`. Results are shaped into the flat `facts` map
  the phraser expects.
  """

  @behaviour TragarAi.Connectors.Source

  alias TragarAi.Freight
  alias TragarAi.Logistics.Cache

  @impl true
  def name, do: "FreightWare"

  @impl true
  def intents,
    do: [:load_status, :eta, :pod, :waybill_lookup, :track, :quote_lookup, :service_types]

  @impl true
  def fetch(intent, entities)

  def fetch(intent, %{waybill: waybill})
      when is_binary(waybill) and intent in [:load_status, :eta, :pod] do
    with {:ok, %{"waybill" => wb, "events" => events}} <- Cache.fetch_shipment(waybill) do
      {:ok, shipment_facts(wb, events)}
    end
  end

  def fetch(:waybill_lookup, %{waybill: waybill}) when is_binary(waybill) do
    with {:ok, %{"waybill" => wb}} <- Cache.fetch_shipment(waybill), do: {:ok, wb}
  end

  def fetch(:track, %{waybill: waybill}) when is_binary(waybill) do
    with {:ok, %{"waybill" => wb, "events" => events}} <- Cache.fetch_shipment(waybill) do
      {:ok,
       %{
         "waybill_number" => wb["waybill_number"] || waybill,
         "events" => events,
         "last_event" => List.first(events)
       }}
    end
  end

  def fetch(:quote_lookup, %{quote: quote}) when is_binary(quote) do
    with {:ok, q} when is_map(q) <- Cache.fetch_quote(quote), do: {:ok, q}
  end

  def fetch(:service_types, _entities) do
    with {:ok, types} <- Freight.service_types(), do: {:ok, %{"service_types" => types}}
  end

  def fetch(intent, _entities)
      when intent in [:load_status, :eta, :pod, :waybill_lookup, :track],
      do: {:error, :missing_waybill}

  def fetch(:quote_lookup, _), do: {:error, :missing_quote}
  def fetch(intent, _), do: {:error, {:unsupported_intent, intent}}

  # ── Shaping ─────────────────────────────────────────────────────────────────

  defp shipment_facts(wb, events) do
    %{
      "waybill_number" => wb["waybill_number"],
      "status" => wb["status_description"] || wb["status_code"],
      "status_code" => wb["status_code"],
      "service_type" => wb["service_type"],
      "consignor" => wb["consignor_name"],
      "consignee" => wb["consignee_name"],
      "consignee_city" => wb["consignee_city"],
      "events" => events,
      "last_event" => List.first(events),
      "pod" => pod_from(events, wb)
    }
    |> compact()
  end

  defp pod_from(events, wb) do
    case Enum.find_value(events, & &1["pod"]) do
      pod when is_map(pod) -> pod
      _ -> if wb["pod_image_url"], do: %{"image_url" => wb["pod_image_url"]}, else: nil
    end
  end

  defp compact(map), do: for({k, v} <- map, v != nil and v != "", into: %{}, do: {k, v})
end
