defmodule TragarAi.Connectors.Source do
  @moduledoc """
  Behaviour for a read-only source-system connector.

  Each of Tragar's source systems (FreightWare, Vantage, Granite, Pastel,
  FleetIT, Freshdesk) implements this. A connector is **read-only** — it serves
  live facts for a set of intents and never writes to the source system.
  """

  @doc "Human-readable source name (e.g. \"FreightWare\")."
  @callback name() :: String.t()

  @doc "The intents this source can serve."
  @callback intents() :: [atom()]

  @doc """
  Fetch the live fact for an intent given validated entities. Returns
  `{:ok, facts_map}` or `{:error, reason}` (e.g. `:not_available` for a source
  whose access is not yet wired).
  """
  @callback fetch(intent :: atom(), entities :: map()) :: {:ok, map()} | {:error, term()}
end
