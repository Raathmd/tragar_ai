defmodule TragarAiWeb.TicketChatController do
  @moduledoc """
  Synchronous assist endpoint for the Freshdesk ticket-sidebar app.

  `POST /api/tickets/chat` with JSON:

      {"ticket_id": "55", "message": "where is 4821",
       "history": [{"role": "user", "text": "..."}, {"role": "assistant", "text": "..."}]}

  Runs one assist turn scoped to the ticket requester's entitled accounts and
  returns the answer synchronously (nothing is posted to the ticket):

      {"ticket_id": "55", "reply": "...", "resolved": true, "options": []}

  `history` is optional — the app holds the transcript and replays it each turn so
  follow-ups resolve in context (the endpoint is stateless).
  """

  use TragarAiWeb, :controller

  alias TragarAi.Assist.TicketChat

  def chat(conn, params) do
    with {:ok, ticket_id} <- require_param(params, "ticket_id"),
         {:ok, message} <- require_param(params, "message") do
      case TicketChat.answer(to_string(ticket_id), to_string(message), history: params["history"]) do
        {:ok, result} ->
          json(conn, result)

        {:error, reason} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
      end
    else
      {:missing, field} ->
        conn |> put_status(:bad_request) |> json(%{error: "#{field} is required"})
    end
  end

  defp require_param(params, field) do
    case params[field] do
      v when is_binary(v) and v != "" -> {:ok, v}
      v when is_integer(v) -> {:ok, v}
      _ -> {:missing, field}
    end
  end
end
