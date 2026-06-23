defmodule TragarAi.Vantage do
  @moduledoc """
  Vantage telematics context — trip data from `multi.vantage.run`.

  `trips_since/1` pulls trips created since a `YYYYMMDDHHmmss` datetime;
  `recent_trips/1` is a convenience window. `find_trip_by_waybill/2` is a
  best-effort link from a waybill to its trip (the exact trip field is TBD
  against real data — see `trip_matches?/2`).

  All calls return `{:error, :not_configured}` until `VANTAGE_*` is set, so the
  assist loop degrades gracefully where Vantage isn't provisioned.
  """

  alias TragarAi.Vantage.Client

  @default_days 7

  @doc "Is the Vantage client configured (credentials present)?"
  def configured? do
    cfg = Client.config()
    Keyword.get(cfg, :email) not in [nil, ""] and Keyword.get(cfg, :password) not in [nil, ""]
  end

  @doc "Trips created since a `YYYYMMDDHHmmss` string."
  def trips_since(created_since) when is_binary(created_since) do
    if configured?() do
      with {:ok, trips} <- Client.trips_since(created_since), do: {:ok, List.wrap(trips)}
    else
      {:error, :not_configured}
    end
  end

  @doc "Trips created in the last `days` (default 7)."
  def recent_trips(days \\ @default_days) do
    since = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> stamp()
    trips_since(since)
  end

  @doc "Best-effort: the recent trip that references `waybill`, or `{:error, :not_found}`."
  def find_trip_by_waybill(waybill, days \\ @default_days) do
    with {:ok, trips} <- recent_trips(days) do
      case Enum.find(trips, &trip_matches?(&1, waybill)) do
        nil -> {:error, :not_found}
        trip -> {:ok, trip}
      end
    end
  end

  # The trip's waybill field is unconfirmed — match common keys, fall back to the
  # raw text. Tighten once we have a real trip sample.
  defp trip_matches?(trip, waybill) when is_map(trip) do
    wb = to_string(waybill)

    keys = ["waybill", "waybill_number", "waybillNumber", "reference", "load", "loadNumber"]
    direct = keys |> Enum.map(&to_string(trip[&1]))

    wb in direct or String.contains?(inspect(trip), wb)
  end

  defp trip_matches?(_trip, _waybill), do: false

  defp stamp(dt), do: Calendar.strftime(dt, "%Y%m%d%H%M%S")
end
