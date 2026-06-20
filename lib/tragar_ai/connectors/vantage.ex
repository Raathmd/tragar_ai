defmodule TragarAi.Connectors.Vantage do
  @moduledoc """
  Vantage (routing) connector — planned route, ETA, distance.

  Stub: read-only access not yet provisioned (see plan §5.5 — confirm the
  mechanism). Declares its intents and reports `:not_available` until wired.
  """

  @behaviour TragarAi.Connectors.Source

  @impl true
  def name, do: "Vantage"

  @impl true
  def intents, do: [:route]

  @impl true
  def fetch(_intent, _entities), do: {:error, :not_available}
end
