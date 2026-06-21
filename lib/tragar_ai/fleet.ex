defmodule TragarAi.Fleet do
  @moduledoc """
  Fleet domain — `Vehicle` records in Tragar's domain shape.

  A vehicle exists across systems: an **asset** in Pastel, **tracked** in
  Vantage, **assigned** to loads in FreightWare, and **cost/availability** in
  FleetIT. `assemble/1` reaches into every source capability that can describe a
  vehicle and merges their pieces (field-level ownership, no overrides) via
  `contribute/4`.
  """

  use Ash.Domain, otp_app: :tragar_ai, extensions: [AshAdmin.Domain]

  alias TragarAi.Adapters
  alias TragarAi.Harmonize
  alias TragarAi.Sources

  @entity_type "vehicle"

  admin do
    show?(true)
  end

  resources do
    resource TragarAi.Fleet.Vehicle do
      define :upsert_vehicle, action: :upsert
      define :get_vehicle, action: :read, get_by: [:registration]
      define :list_vehicles, action: :read
    end
  end

  # Capabilities across which a vehicle can be assembled — one per source.
  @vehicle_capabilities [:vehicle_asset, :vehicle_tracking, :vehicle_assignment, :vehicle_status]

  @doc """
  Assemble a vehicle by reaching into every source capability that can describe
  it (Pastel asset, Vantage tracking, FreightWare assignment, FleetIT status),
  recording each source's pieces and harmonizing. Returns the merged `Vehicle`
  or `{:error, :not_found}` if no source contributed.
  """
  def assemble(registration) do
    @vehicle_capabilities
    |> Adapters.gather(%{registration: registration})
    |> Enum.each(fn {source, slice} ->
      contribute(registration, source, vehicle_fields(slice), raw: slice)
    end)

    case get_vehicle(registration) do
      {:ok, %{} = vehicle} -> {:ok, vehicle}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Record a source's pieces of the vehicle (as a `SourceRecord`) and re-harmonize.
  Sources don't override each other.
  """
  def contribute(registration, source, fields, opts \\ []) do
    {:ok, _} =
      Sources.put_source_record(%{
        entity_type: @entity_type,
        entity_key: registration,
        source: source,
        external_id: opts[:external_id],
        data: stringify(fields),
        raw: opts[:raw] || %{},
        synced_at: DateTime.utc_now()
      })

    reproject(registration)
  end

  defp reproject(registration) do
    {:ok, records} = Sources.source_records_for(@entity_type, registration)
    %{fields: f, sources: sources} = Harmonize.project(records)

    upsert_vehicle(%{
      registration: registration,
      status: f["status"],
      available: f["available"],
      description: f["description"],
      sources: sources,
      cached_at: DateTime.utc_now()
    })
  end

  defp vehicle_fields(slice) when is_map(slice),
    do: Map.take(slice, ~w(status available description))

  defp vehicle_fields(_), do: %{}

  defp stringify(map), do: for({k, v} <- map, into: %{}, do: {to_string(k), v})
end
