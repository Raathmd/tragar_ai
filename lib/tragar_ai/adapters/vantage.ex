defmodule TragarAi.Adapters.Vantage do
  @moduledoc """
  Vantage (telematics) adapter — the trip/route for a shipment, from
  `multi.vantage.run`. Returns `{:error, :not_configured}` until `VANTAGE_*` is set.
  """
  @behaviour TragarAi.Adapters.Adapter

  @impl true
  def name, do: "Vantage"

  @impl true
  def capabilities, do: [:route, :vehicle_tracking]

  @impl true
  def fetch(:route, %{waybill: waybill}) when is_binary(waybill),
    do: TragarAi.Vantage.find_trip_by_waybill(waybill)

  def fetch(:route, _), do: {:error, :missing_waybill}

  def fetch(:vehicle_tracking, %{registration: registration}) when is_binary(registration),
    do: TragarAi.Vantage.find_trip_by_vehicle(registration)

  def fetch(:vehicle_tracking, _), do: {:error, :missing_registration}

  def fetch(_intent, _params), do: {:error, :not_available}
end
