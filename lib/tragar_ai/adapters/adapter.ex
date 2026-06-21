defmodule TragarAi.Adapters.Adapter do
  @moduledoc """
  Port for a source-system integration.

  Each of Tragar's systems (FreightWare, Vantage, Granite, Pastel, FleetIT,
  Freshdesk) implements this behaviour. An adapter's job is to **map a source
  system's data into Tragar's domain shape** — the assist loop, cache and
  analytics work against the domain (`Shipment`, `Quote`, …), never against a
  source's raw format. New systems integrate by adding one adapter; nothing
  downstream changes.

  An adapter is **read-only** unless it explicitly exposes a write capability.
  """

  @doc "Human-readable source name (e.g. \"FreightWare\"). Used for provenance."
  @callback name() :: String.t()

  @doc """
  The domain capabilities (intents) this adapter can serve, e.g.
  `[:load_status, :eta, :pod, :track]`. The registry routes an intent to the
  adapter that declares it.
  """
  @callback capabilities() :: [atom()]

  @doc """
  Serve a capability: fetch from the source and return **domain-shaped** facts
  (`{:ok, map}`), or `{:error, reason}` (`:not_available` for a source whose
  access is not yet wired). The returned map is in Tragar's domain vocabulary,
  not the source's.
  """
  @callback fetch(intent :: atom(), params :: map()) :: {:ok, map()} | {:error, term()}
end
