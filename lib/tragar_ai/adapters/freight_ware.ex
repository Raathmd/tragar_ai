defmodule TragarAi.Adapters.FreightWare do
  @moduledoc """
  FreightWare (Dovetail) adapter — serves shipment status/ETA/POD/tracking,
  waybill and quote lookups, and service-type reference data, mapped into
  Tragar's domain shape. Shipment/quote reads go through `TragarAi.Logistics.Cache`
  (read-through, Ash-backed); reference data goes live via `TragarAi.Freight`.
  """

  @behaviour TragarAi.Adapters.Adapter

  alias TragarAi.Customers.Cache, as: CustomerCache
  alias TragarAi.Freight
  alias TragarAi.Logistics.Cache

  @impl true
  def name, do: "FreightWare"

  @impl true
  def capabilities,
    do: [
      :load_status,
      :eta,
      :pod,
      :waybill_lookup,
      :track,
      :quote_lookup,
      :service_types,
      :customer_lookup,
      :vehicle_assignment
    ]

  @impl true
  def fetch(intent, params)

  def fetch(intent, %{waybill: waybill})
      when is_binary(waybill) and intent in [:load_status, :eta, :pod, :waybill_lookup] do
    with {:ok, shipment} <- Cache.shipment(waybill) do
      {:ok, Map.put(shipment, "last_event", List.first(shipment["events"] || []))}
    end
  end

  def fetch(:track, %{waybill: waybill}) when is_binary(waybill) do
    with {:ok, shipment} <- Cache.shipment(waybill) do
      events = shipment["events"] || []

      {:ok,
       %{"waybill_number" => waybill, "events" => events, "last_event" => List.first(events)}}
    end
  end

  def fetch(:quote_lookup, %{quote: quote}) when is_binary(quote) do
    Cache.quote(quote)
  end

  def fetch(:customer_lookup, %{account: account}) when is_binary(account) do
    CustomerCache.customer(account)
  end

  def fetch(:customer_lookup, _), do: {:error, :missing_account}

  def fetch(:service_types, _params) do
    with {:ok, types} <- Freight.service_types(), do: {:ok, %{"service_types" => types}}
  end

  def fetch(intent, _params)
      when intent in [:load_status, :eta, :pod, :waybill_lookup, :track],
      do: {:error, :missing_waybill}

  def fetch(:quote_lookup, _), do: {:error, :missing_quote}
  def fetch(intent, _), do: {:error, {:unsupported_intent, intent}}
end
