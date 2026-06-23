defmodule TragarAiWeb.TicketAnswerController do
  @moduledoc """
  Endpoint a Freshdesk automation calls when a ticket is created.

  `POST /api/tickets/answer` with JSON:

      {"ticket_id": "55", "subject": "Where is my delivery?",
       "description": "Tracking 0006794936FC", "post_reply": true}

  Tragar AI interprets the question, uses the read tools to fetch the live facts,
  composes an answer, and (by default) posts it onto the ticket as a private note
  for the agent to review. The answer is also returned in the response.
  """

  use TragarAiWeb, :controller

  alias TragarAi.Assist.TicketResponder

  def answer(conn, params) do
    with {:ok, ticket_id} <- require_param(params, "ticket_id"),
         content when content != "" <- ticket_text(params) do
      opts = [
        post_reply: truthy(params["post_reply"], true),
        private: truthy(params["private"], true)
      ]

      case TicketResponder.respond(to_string(ticket_id), content, opts) do
        {:ok, result} ->
          json(conn, result)

        {:error, reason} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
      end
    else
      {:missing, field} ->
        conn |> put_status(:bad_request) |> json(%{error: "#{field} is required"})

      "" ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "ticket content (subject/description) is required"})
    end
  end

  defp ticket_text(params) do
    [
      params["subject"],
      params["description_text"] || params["description"] || params["body"] || params["text"]
    ]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join(" — ")
  end

  defp truthy(v, default) do
    case v do
      nil -> default
      v -> v in [true, "true", "1", 1]
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
