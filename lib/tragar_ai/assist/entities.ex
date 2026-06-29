defmodule TragarAi.Assist.Entities do
  @moduledoc """
  Domain-entity registry for the "surface everything" assist path.

  An entity (a waybill, an account, …) is a *domain* concept that several source
  capabilities describe. This maps each entity to its reference param and the
  full set of capabilities that surface it across sources — so a broad request
  ("tell me about waybill X") can fan out over every facet and harmonise them
  into one record, rather than resolving to a single intent/source.

  Generalises `TragarAi.Fleet`'s `@vehicle_capabilities`. Add a source's
  capability here (and its `fetch/2` clause) and it joins the entity's surface
  automatically.
  """

  # entity => %{param: entity-key atom, capabilities: [intent]}
  # waybill is curated to non-redundant facets: load_status carries the shipment
  # record, track the events, route the planned/live route (Vantage). eta/pod are
  # subsets of the same FreightWare shipment map, so they're omitted from the fan-out.
  @entities %{
    waybill: %{param: :waybill, capabilities: [:load_status, :track, :route]},
    account: %{param: :account, capabilities: [:customer_lookup, :invoice]},
    quote: %{param: :quote, capabilities: [:quote_lookup]},
    ticket: %{param: :ticket_id, capabilities: [:ticket_context]},
    vehicle: %{
      param: :registration,
      capabilities: [:vehicle_asset, :vehicle_tracking, :vehicle_assignment, :vehicle_status]
    }
  }

  @doc "All known domain entities."
  def all, do: @entities

  @doc "The capability group for a domain entity, or nil."
  @spec group(atom()) :: %{param: atom(), capabilities: [atom()]} | nil
  def group(entity), do: Map.get(@entities, entity)

  @doc """
  Which domain entity a request's entities belong to (by the reference key
  present), or nil when none of the known references is present.
  """
  @spec entity_for(map()) :: atom() | nil
  def entity_for(entities) when is_map(entities) do
    Enum.find_value(@entities, fn {entity, %{param: param}} ->
      v = entities[param]
      if is_binary(v) and v != "", do: entity
    end)
  end

  def entity_for(_), do: nil

  @doc "The reference value for an entity within an entities map (e.g. the waybill number)."
  @spec key(atom(), map()) :: String.t() | nil
  def key(entity, entities) when is_map(entities) do
    case group(entity) do
      %{param: param} -> entities[param]
      _ -> nil
    end
  end

  def key(_, _), do: nil
end
