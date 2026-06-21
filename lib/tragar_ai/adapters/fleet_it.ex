defmodule TragarAi.Adapters.FleetIT do
  @moduledoc "FleetIT adapter — vehicle status/availability (own-fleet CPK source). Access not yet provisioned."
  @behaviour TragarAi.Adapters.Adapter

  @impl true
  def name, do: "FleetIT"
  @impl true
  def capabilities, do: [:vehicle_status]
  @impl true
  def fetch(_intent, _params), do: {:error, :not_available}
end
