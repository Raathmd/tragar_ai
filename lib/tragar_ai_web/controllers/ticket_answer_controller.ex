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
    with {:ok, ticket_id} <- require_param(params, "ticket_id") do
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
        flag_field: params["flag_field"],
        # Attachments the agent chose to ingest (from the sidebar picker) — their
        # text is extracted server-side and folded into the answer.
        attachment_ids: normalize_ids(params["attachment_ids"])
      ]

      # Answer the webhook immediately and run the assist loop (interpret → fetch →
      # phrase → post note) off the request path — Freshdesk's webhook timeout is
      # short, and the loop can take much longer. The answer is delivered as a
      # ticket note, not in this response. Runs inline under `ticket_async: false`
      # (tests) so it stays deterministic. Content may be empty — the responder
      # pulls the full ticket thread itself.
      deliver(ticket_id, ticket_text(params), opts)

      conn |> put_status(:accepted) |> json(%{status: "accepted", ticket_id: ticket_id})
    else
      {:missing, field} ->
        conn |> put_status(:bad_request) |> json(%{error: "#{field} is required"})
    end
  end

  defp normalize_ids(ids) when is_list(ids), do: ids
  defp normalize_ids(_), do: []

  @doc """
  The ticket's **readable** attachments for the sidebar picker — `id`, `name`,
  `content_type`, `size`. Only types Tragar AI can extract (CSV/Excel/PDF) are
  returned; images and anything else are omitted so the picker never offers a file
  that can't be ingested. The agent ticks the ones to ingest; their ids come back
  in the `/answer` call's `attachment_ids`.
  """
  def attachments(conn, %{"id" => id}) do
    case TragarAi.Freshdesk.ticket_attachments(to_string(id)) do
      {:ok, list} ->
        views =
          list
          |> Enum.filter(&TragarAi.Assist.Extract.supported?(&1.content_type, &1.name))
          |> Enum.map(&attachment_view/1)

        json(conn, %{ticket_id: to_string(id), attachments: views})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  defp attachment_view(a) do
    %{id: a.id, name: a.name, content_type: a.content_type, size: a.size}
  end

  # Run the assist loop and post the answer as a ticket note. Off the request path
  # via a Task in prod; inline when `:ticket_async` is false (tests).
  defp deliver(ticket_id, content, opts) do
    work = fn ->
      with {:error, reason} <- TicketResponder.respond(ticket_id, content, opts) do
        Logger.warning("[tickets/answer] #{ticket_id} failed: #{inspect(reason)}")
      end
    end

    if Application.get_env(:tragar_ai, :ticket_async, true) do
      Task.Supervisor.start_child(TragarAi.TaskSupervisor, work)
    else
      work.()
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
