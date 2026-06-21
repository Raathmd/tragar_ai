defmodule TragarAi.Adapters.Freshdesk do
  @moduledoc "Freshdesk adapter — ticket context + the customer a question is about."

  @behaviour TragarAi.Adapters.Adapter

  alias TragarAi.Freshdesk.Client

  @impl true
  def name, do: "Freshdesk"

  @impl true
  def capabilities, do: [:ticket_context]

  @impl true
  def fetch(:ticket_context, %{ticket_id: id}) when not is_nil(id) do
    with {:ok, ticket} <- Client.get_ticket(id), do: {:ok, to_domain(ticket)}
  end

  def fetch(:ticket_context, _), do: {:error, :missing_ticket_id}
  def fetch(intent, _), do: {:error, {:unsupported_intent, intent}}

  defp to_domain(ticket) when is_map(ticket) do
    %{
      "ticket_id" => ticket["id"],
      "subject" => ticket["subject"],
      "status" => ticket["status"],
      "requester_email" => ticket["email"],
      "priority" => ticket["priority"],
      "updated_at" => ticket["updated_at"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp to_domain(_), do: %{}
end
