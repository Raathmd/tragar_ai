defmodule TragarAi.Connectors.Pastel do
  @moduledoc """
  Pastel (accounting) connector — invoice, account balance, payment status.

  Stub: read-only access not yet provisioned. Declares its intents and reports
  `:not_available` until wired.
  """

  @behaviour TragarAi.Connectors.Source

  @impl true
  def name, do: "Pastel"

  @impl true
  def intents, do: [:invoice]

  @impl true
  def fetch(_intent, _entities), do: {:error, :not_available}
end
