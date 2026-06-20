defmodule TragarAi.Connectors.FleetIT do
  @moduledoc """
  FleetIT connector — vehicle status / availability (the consolidated own-fleet
  cost feed; the CPK source used in Phase 3 margin).

  Stub: read-only access not yet provisioned. Declares its intents and reports
  `:not_available` until wired.
  """

  @behaviour TragarAi.Connectors.Source

  @impl true
  def name, do: "FleetIT"

  @impl true
  def intents, do: [:vehicle_status]

  @impl true
  def fetch(_intent, _entities), do: {:error, :not_available}
end
