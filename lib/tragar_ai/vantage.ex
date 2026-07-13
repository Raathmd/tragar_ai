defmodule TragarAi.Vantage do
  @moduledoc """
  Vantage telematics context — trip data from `multi.vantage.run`.

  Vantage has no per-waybill query: `master_trip/created_since` returns the full
  (paginated) trip set since a datetime, so we page through it, cache it briefly,
  and filter in memory. A FreightWare waybill links to a trip via a stop order's
  `orderNumber`; a vehicle registration links via `trip.vehicle.fleetNumber`.
  Matched trips are normalised (`TragarAi.Vantage.Normalize`) into the domain
  shape before they reach the assist loop.

  All calls return `{:error, :not_configured}` until `VANTAGE_*` is set, so the
  loop degrades gracefully where Vantage isn't provisioned.
  """

  alias TragarAi.Vantage.{Client, Normalize}

  @default_days 7
  @max_pages 50
  @cache_ttl_ms 120_000

  @doc "Is the Vantage client configured (credentials present)?"
  def configured? do
    cfg = Client.config()
    Keyword.get(cfg, :email) not in [nil, ""] and Keyword.get(cfg, :password) not in [nil, ""]
  end

  @doc "All trips created since a `YYYYMMDDHHmmss` string (pages accumulated)."
  def trips_since(created_since) when is_binary(created_since) do
    if configured?(), do: all_pages(created_since), else: {:error, :not_configured}
  end

  @doc "Trips created in the last `days` (default 7), cached for a short TTL."
  def recent_trips(days \\ @default_days) do
    case cached(days) do
      {:ok, _} = hit ->
        hit

      :miss ->
        since = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> stamp()

        with {:ok, trips} <- trips_since(since) do
          put_cache(days, trips)
          {:ok, trips}
        end
    end
  end

  @doc "The recent trip whose order matches `waybill`, normalised — or `{:error, :not_found}`."
  def find_trip_by_waybill(waybill, days \\ @default_days) do
    # Waybills are alphanumeric (e.g. DIS0124440); match on the whole identifier,
    # case-insensitively and trimmed, so casing/whitespace differences between
    # FreightWare and Vantage don't miss a real trip.
    wb = normalize_ref(waybill)

    with {:ok, trips} <- recent_trips(days) do
      case Enum.find(trips, fn t ->
             Enum.any?(Normalize.order_numbers(t), &(normalize_ref(&1) == wb))
           end) do
        nil -> {:error, :not_found}
        trip -> {:ok, Normalize.route_slice(trip, String.trim(to_string(waybill)))}
      end
    end
  end

  defp normalize_ref(ref), do: ref |> to_string() |> String.trim() |> String.upcase()

  @doc "The recent trip for vehicle `registration` (fleet number), normalised."
  def find_trip_by_vehicle(registration, days \\ @default_days) do
    reg = to_string(registration)

    with {:ok, trips} <- recent_trips(days) do
      case Enum.find(trips, fn t -> Normalize.fleet_number(t) == reg end) do
        nil -> {:error, :not_found}
        trip -> {:ok, Normalize.vehicle_slice(trip)}
      end
    end
  end

  # ── pagination ───────────────────────────────────────────────────────────────

  defp all_pages(created_since) do
    Enum.reduce_while(1..@max_pages, {:ok, []}, fn page, {:ok, acc} ->
      case Client.trips_since(created_since, page) do
        {:ok, body} ->
          acc = acc ++ items_of(body)
          if has_next?(body), do: {:cont, {:ok, acc}}, else: {:halt, {:ok, acc}}

        {:error, _} = err ->
          # Surface the error only if we have nothing; otherwise keep what we got.
          if acc == [], do: {:halt, err}, else: {:halt, {:ok, acc}}
      end
    end)
  end

  # Paginated envelope; older shapes may return a bare list.
  defp items_of(%{"items" => items}) when is_list(items), do: items
  defp items_of(list) when is_list(list), do: list
  defp items_of(_), do: []

  defp has_next?(%{"hasNext" => v}), do: v == true
  defp has_next?(_), do: false

  # ── tiny TTL cache (avoids re-paging the dataset per lookup within a turn) ─────

  defp cached(days) do
    case :persistent_term.get({__MODULE__, :cache}, nil) do
      %{days: ^days, trips: trips, at_ms: at} ->
        if System.monotonic_time(:millisecond) - at < @cache_ttl_ms, do: {:ok, trips}, else: :miss

      _ ->
        :miss
    end
  end

  defp put_cache(days, trips) do
    :persistent_term.put(
      {__MODULE__, :cache},
      %{days: days, trips: trips, at_ms: System.monotonic_time(:millisecond)}
    )
  end

  defp stamp(dt), do: Calendar.strftime(dt, "%Y%m%d%H%M%S")
end
