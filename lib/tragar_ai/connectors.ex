defmodule TragarAi.Connectors do
  @moduledoc """
  Registry and dispatcher for the read-only source connectors.

  Maps each intent to the source that serves it (the "live facts each source
  serves" table from the plan) and routes a validated request to it. Two sources
  are wired today — FreightWare and Freshdesk; the remaining four
  (Vantage, Granite, Pastel, FleetIT) are declared with their intents and return
  `{:error, :not_available}` until read-only access is provisioned.
  """

  alias TragarAi.Connectors.{FleetIT, FreightWare, Freshdesk, Granite, Pastel, Vantage}

  @sources [FreightWare, Vantage, Granite, Pastel, FleetIT, Freshdesk]

  @doc "All registered source modules."
  def sources, do: @sources

  @doc "Map of intent => source module, built from each source's `intents/0`."
  def routes do
    for source <- @sources, intent <- source.intents(), into: %{}, do: {intent, source}
  end

  @doc "All intents any source can serve."
  def intents, do: routes() |> Map.keys()

  @doc "The source module that serves an intent, or nil."
  def source_for(intent), do: Map.get(routes(), intent)

  @doc """
  Fetch the live fact for a validated request. Returns `{:ok, facts}`,
  `{:error, {:no_source, intent}}` if no source serves the intent, or whatever
  the source returns on failure.
  """
  @spec fetch(atom(), map()) :: {:ok, map()} | {:error, term()}
  def fetch(intent, entities) do
    case source_for(intent) do
      nil -> {:error, {:no_source, intent}}
      source -> source.fetch(intent, entities)
    end
  end
end
