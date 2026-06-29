defmodule TragarAi.Vantage.Normalize do
  @moduledoc """
  Map a Vantage `master_trip` record into Tragar's domain shape.

  Vantage is trip-centric: a trip has `stops`, each stop has `orders`
  (`orderNumber` — the link to a FreightWare waybill), and the vehicle's live GPS
  is in `trip.mobile.lastSeen`. The route capability surfaces, for the matched
  order, the same field names the demo route uses (`waybill_number`, `vehicle`,
  `route`, `distance`, `current_location`, `next_stop`, `eta`, `status`) so
  `Harmonize` merges cleanly with the FreightWare shipment.
  """

  @doc "All order numbers across a record's stops (the waybill link key)."
  @spec order_numbers(map()) :: [String.t()]
  def order_numbers(record) when is_map(record) do
    t = detail(record)
    for stop <- stops(t), order <- orders(stop), n = order["orderNumber"], is_binary(n), do: n
  end

  def order_numbers(_), do: []

  @doc "The vehicle fleet number (the registration link key)."
  @spec fleet_number(map()) :: String.t() | nil
  def fleet_number(record), do: get_in(detail(record), ["vehicle", "fleetNumber"])

  @doc """
  Route/tracking slice for a matched order (waybill). Keyed by `waybill_number`
  so it harmonizes onto the shipment.
  """
  @spec route_slice(map(), String.t()) :: map()
  def route_slice(record, order_number) when is_map(record) do
    t = detail(record)

    %{
      "waybill_number" => order_number,
      "vehicle" => fleet_number(record),
      "trip_reference" => t["referenceNumber"] || t["tripNumber"],
      "status" => t["status"] || record["status"],
      "route" => route_label(t),
      "distance" => t["tripDistance"],
      "distance_actual" => t["tripDistanceActual"],
      "next_stop" => next_stop_name(t),
      "eta" => next_eta(t)
    }
    |> Map.merge(location(t))
    |> compact()
  end

  @doc "Vehicle-tracking slice keyed by `registration` (the fleet number)."
  @spec vehicle_slice(map()) :: map()
  def vehicle_slice(record) when is_map(record) do
    t = detail(record)

    %{
      "registration" => fleet_number(record),
      "vehicle" => fleet_number(record),
      "trip_reference" => t["referenceNumber"] || t["tripNumber"],
      "status" => t["status"] || record["status"],
      "route" => route_label(t),
      "next_stop" => next_stop_name(t),
      "eta" => next_eta(t)
    }
    |> Map.merge(location(t))
    |> compact()
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  # A master_trip record nests the trip detail under "trip"; tolerate a bare
  # detail map too (tests / older shapes).
  defp detail(%{"trip" => t}) when is_map(t), do: t
  defp detail(record), do: record

  defp stops(trip), do: List.wrap(trip["stops"])
  defp orders(stop), do: List.wrap(stop["orders"])

  # First→last stop node, as "Origin → Destination".
  defp route_label(trip) do
    names = stops(trip) |> Enum.map(&node_ref/1) |> Enum.reject(&is_nil/1)

    case names do
      [] -> nil
      [one] -> one
      list -> "#{List.first(list)} → #{List.last(list)}"
    end
  end

  defp node_ref(stop) do
    case get_in(stop, ["node", "externalReference"]) do
      ref when is_binary(ref) and ref != "" -> ref
      _ -> nil
    end
  end

  # The next stop still expecting arrival (carries a revised ETA).
  defp pending_stop(trip),
    do: Enum.find(stops(trip), &get_in(&1, ["tripStopExecution", "revisedEta"]))

  defp next_stop_name(trip), do: pending_stop(trip) && node_ref(pending_stop(trip))

  defp next_eta(trip),
    do: pending_stop(trip) && get_in(pending_stop(trip), ["tripStopExecution", "revisedEta"])

  # Live position from the mobile device's last-seen GPS.
  defp location(trip) do
    seen = get_in(trip, ["mobile", "lastSeen"]) || %{}
    lat = seen["latitude"]
    lon = seen["longitude"]

    if is_number(lat) and is_number(lon) do
      %{"current_location" => "#{lat}, #{lon}", "current_lat" => lat, "current_lon" => lon}
    else
      %{}
    end
  end

  defp compact(map),
    do: for({k, v} <- map, not is_nil(v) and v != "", into: %{}, do: {k, v})
end
