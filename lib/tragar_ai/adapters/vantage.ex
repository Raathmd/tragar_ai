defmodule TragarAi.Adapters.Vantage do
  @moduledoc "Vantage (routing) adapter — planned route, ETA, distance. Access not yet provisioned."
  @behaviour TragarAi.Adapters.Adapter

  @impl true
  def name, do: "Vantage"
  @impl true
  def capabilities, do: [:route]
  @impl true
  def fetch(_intent, _params), do: {:error, :not_available}
end
