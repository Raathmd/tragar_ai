defmodule TragarAi.Adapters.Pastel do
  @moduledoc "Pastel (accounting) adapter — invoice, balance, payment status. Access not yet provisioned."
  @behaviour TragarAi.Adapters.Adapter

  @impl true
  def name, do: "Pastel"
  @impl true
  def capabilities, do: [:invoice]
  @impl true
  def fetch(_intent, _params), do: {:error, :not_available}
end
