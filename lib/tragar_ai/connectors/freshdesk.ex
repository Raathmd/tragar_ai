defmodule TragarAi.Connectors.Freshdesk do
  @moduledoc """
  Freshdesk read-only connector — ticket context and the customer a question is
  about. Wraps `TragarAi.Freshdesk.Client`.
  """

  @behaviour TragarAi.Connectors.Source

  alias TragarAi.Freshdesk.Client

  @impl true
  def name, do: "Freshdesk"

  @impl true
  def intents, do: [:ticket_context]

  @impl true
  def fetch(:ticket_context, %{ticket_id: id}) when not is_nil(id) do
    with {:ok, ticket} <- Client.get_ticket(id) do
      {:ok, ticket_facts(ticket)}
    end
  end

  def fetch(:ticket_context, _), do: {:error, :missing_ticket_id}
  def fetch(intent, _), do: {:error, {:unsupported_intent, intent}}

  defp ticket_facts(ticket) when is_map(ticket) do
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

  defp ticket_facts(_), do: %{}
end
