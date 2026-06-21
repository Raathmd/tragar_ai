defmodule TragarAi.Adapters.Freshdesk do
  @moduledoc """
  Freshdesk adapter — ticket context + the customer a question is about, mapped
  into Tragar's domain `Ticket` and cached read-through by `TragarAi.Support.Cache`.
  """

  @behaviour TragarAi.Adapters.Adapter

  alias TragarAi.Support.Cache

  @impl true
  def name, do: "Freshdesk"

  @impl true
  def capabilities, do: [:ticket_context]

  @impl true
  def fetch(:ticket_context, %{ticket_id: id}) when not is_nil(id), do: Cache.ticket(id)
  def fetch(:ticket_context, _), do: {:error, :missing_ticket_id}
  def fetch(intent, _), do: {:error, {:unsupported_intent, intent}}
end
