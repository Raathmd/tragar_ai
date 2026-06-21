defmodule TragarAi.Adapters.Granite do
  @moduledoc "Granite (WMS) adapter — stock position, pick/pack, receipts. Access not yet provisioned."
  @behaviour TragarAi.Adapters.Adapter

  @impl true
  def name, do: "Granite (WMS)"
  @impl true
  def capabilities, do: [:stock]
  @impl true
  def fetch(_intent, _params), do: {:error, :not_available}
end
