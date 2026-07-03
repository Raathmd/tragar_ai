defmodule TragarAiWeb.TicketAnswerController do
  @moduledoc """
  Endpoint a Freshdesk automation calls when a ticket is created.

  `POST /api/tickets/answer` with JSON:

      {"ticket_id": "55", "subject": "Where is my delivery?",
       "description": "Tracking 0006794936FC",
       "account": "{{ticket.company.freightware_accounts}}",
       "requester_email": "{{ticket.requester.email}}", "post_reply": true}

  `account` is the scope, injected by the Freshdesk automation from the company's
  custom field (Freshdesk-rendered, behind the bearer + IP gates). When it's
  absent we derive it via the Freshdesk API instead.

  Tragar AI interprets the question, uses the read tools to fetch the live facts
  (scoped to that account), composes an answer, and (by default) posts it onto the
  ticket as a private note for the agent. The answer is also returned in the
  response.

  It then **pre-fills the ticket's custom fields** from those facts where it can
  match them confidently (validating dropdown values against the field's allowed
  choices). It never sets the assignee/group — assignment stays a human decision.
  Pass `"fill_fields": false` to skip pre-fill. The fields it filled are returned
  under `filled_fields`.
  """

  use TragarAiWeb, :controller

  require Logger

  alias TragarAi.Assist.TicketResponder

  def answer(conn, params) do
    with {:ok, ticket_id} <- require_param(params, "ticket_id"),
         content when content != "" <- ticket_text(params) do
      ticket_id = to_string(ticket_id)

      opts = [
        post_reply: truthy(params["post_reply"], true),
        private: truthy(params["private"], true),
        # Account scope injected by the Freshdesk automation ({{ticket.company.freightware_accounts}});
        # falls back to deriving it via the Freshdesk API when absent.
        account: params["account"],
        requester_email: params["requester_email"],
        # Pre-fill matching custom ticket fields from the retrieved facts (never
        # assignment). Set "fill_fields": false to skip.
        fill_fields: truthy(params["fill_fields"], true),
        # Override the automation trigger checkbox unchecked after answering
        # (breaks the on-update answer loop). Defaults to the configured field.
        flag_field: params["flag_field"]
      ]

      # Answer the webhook immediately and run the assist loop (interpret → fetch →
      # phrase → post note) off the request path — Freshdesk's webhook timeout is
      # short, and the loop can take much longer. The answer is delivered as a
      # ticket note, not in this response.
      Task.Supervisor.start_child(TragarAi.TaskSupervisor, fn ->
        with {:error, reason} <- TicketResponder.respond(ticket_id, content, opts) do
          Logger.warning("[tickets/answer] #{ticket_id} failed: #{inspect(reason)}")
        end
      end)

      conn |> put_status(:accepted) |> json(%{status: "accepted", ticket_id: ticket_id})
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
