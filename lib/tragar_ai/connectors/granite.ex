defmodule TragarAi.Connectors.Granite do
  @moduledoc """
  Granite (WMS) connector — stock position, pick/pack status, receipts.

  Stub: read-only access not yet provisioned. Declares its intents and reports
  `:not_available` until wired.
  """

  @behaviour TragarAi.Connectors.Source

  @impl true
  def name, do: "Granite (WMS)"

  @impl true
  def intents, do: [:stock]

  @impl true
  def fetch(_intent, _entities), do: {:error, :not_available}
end
