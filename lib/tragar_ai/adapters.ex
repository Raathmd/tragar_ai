defmodule TragarAi.Adapters do
  @moduledoc """
  Registry and dispatcher for source-system adapters (the adapter framework).

  Maps each domain capability (intent) to the adapter that serves it and routes
  requests to it. Adapters map their source into Tragar's domain shape, so the
  rest of the app is source-agnostic. Two systems are wired (FreightWare,
  Freshdesk); the other four declare their capabilities and return
  `{:error, :not_available}` until access is provisioned.
  """

  alias TragarAi.Adapters.{FleetIT, FreightWare, Freshdesk, Granite, Pastel, Vantage}

  @adapters [FreightWare, Vantage, Granite, Pastel, FleetIT, Freshdesk]

  @doc "All registered adapter modules."
  def adapters, do: @adapters

  @doc "Map of capability (intent) => adapter module, from each adapter's `capabilities/0`."
  def routes do
    for adapter <- @adapters, cap <- adapter.capabilities(), into: %{}, do: {cap, adapter}
  end

  @doc "Every capability any adapter can serve."
  def capabilities, do: routes() |> Map.keys()

  @doc "The adapter that serves a capability, or nil."
  def adapter_for(intent), do: Map.get(routes(), intent)

  @doc """
  Serve a capability through its adapter. Returns `{:ok, domain_facts}`,
  `{:error, {:no_adapter, intent}}` if nothing serves it, or the adapter's error.
  """
  @spec fetch(atom(), map()) :: {:ok, map()} | {:error, term()}
  def fetch(intent, params) do
    case adapter_for(intent) do
      nil -> {:error, {:no_adapter, intent}}
      adapter -> adapter.fetch(intent, params)
    end
  end

  @doc """
  Fan out across capabilities and collect each adapter's contribution. Lets a
  domain entity "reach into any source capability" — every adapter that can
  serve one of `capabilities` is asked, and the successful slices are returned as
  `[{source_name, slice}]`. Unavailable/erroring sources are skipped.
  """
  @spec gather([atom()], map()) :: [{String.t(), map()}]
  def gather(capabilities, params) do
    for cap <- capabilities,
        adapter = adapter_for(cap),
        not is_nil(adapter),
        {:ok, slice} <- [adapter.fetch(cap, params)] do
      {adapter.name(), slice}
    end
  end
end
