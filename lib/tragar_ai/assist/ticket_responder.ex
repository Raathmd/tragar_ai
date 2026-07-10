defmodule TragarAi.Assist.TicketResponder do
  @moduledoc """
  Compose an answer to a Freshdesk ticket.

  Freshdesk automation calls our API when a ticket is created; the ticket content
  comes here. We derive the requester's account (for scoping), run the assist
  Engine — Core AI interprets the question → the tools fetch the live facts →
  Core AI phrases the answer — and post the draft back onto the ticket for the
  agent to review/relay (private note by default, per the agent-in-the-loop
  principle).

  The Freshdesk verifier/client are injectable (`:freshdesk`, `:client`) so this
  is testable without the live API.
  """

  require Logger

  alias TragarAi.Assist.Engine
  alias TragarAi.Freshdesk.FieldMapper

  @spec respond(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def respond(ticket_id, content, opts \\ []) when is_binary(content) do
    fd = Keyword.get(opts, :freshdesk, TragarAi.Freshdesk)
    client = Keyword.get(opts, :client, TragarAi.Freshdesk.Client)

    # The Freshdesk automation fires on the "Tragar AI" checkbox being set. Our own
    # write-backs (private note, field pre-fill) are ticket updates that would
    # re-fire it → an answer loop. Uncheck the flag FIRST — before any other update
    # — so by the time we post the note / fill fields the trigger no longer matches.
    clear_flag(client, ticket_id, opts)

    accounts = accounts_for(ticket_id, opts, fd)
    account = List.first(accounts)

    # Pull the WHOLE ticket thread (original request + every reply and human-agent
    # note, minus our own notes) so the model understands the full context; fall
    # back to the webhook-supplied body if it can't be fetched.
    content = thread_content(fd, ticket_id, content)

    # Fold in the text of any attachments the agent chose to ingest (extracted
    # server-side, model-free). Empty ids → no-op, so the non-attachment path is
    # unchanged.
    content = content <> attachments_text(ticket_id, opts, fd, client)

    # Feed the model the RAW thread — no distil. Distillation was mangling
    # references (e.g. gluing a destination onto a waybill: "ITD0048113" ->
    # "ITD0048113-Lusikisiki"), so it never matched. Same as the console now does.

    # `:accounts` enforces scope in the Engine — facts must be on the requester's
    # account, so a ticket can't pull another account's records.
    context = %{
      intent: nil,
      accounts: accounts,
      entities: entities(account),
      ticket_id: ticket_id
    }

    case Engine.answer(content, context) do
      {:ok, interaction} ->
        result = %{
          ticket_id: ticket_id,
          account: account,
          answer: interaction.draft_answer,
          resolved: interaction.status == :drafted,
          intent: interaction.intent && to_string(interaction.intent),
          source: interaction.source
        }

        maybe_post(client, ticket_id, interaction, opts)
        filled = maybe_fill_fields(client, ticket_id, interaction.facts, opts)
        {:ok, Map.put(result, :filled_fields, filled)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Scope = the account(s) the request is allowed to read. Prefer the account the
  # Freshdesk automation injected in the webhook (`{{ticket.company.freightware_accounts}}`,
  # rendered by Freshdesk, behind the bearer + IP gates) for speed; fall back to
  # deriving it via the Freshdesk API when the body doesn't carry one.
  defp accounts_for(ticket_id, opts, fd) do
    case TragarAi.Freshdesk.normalize_codes(opts[:account]) do
      [] -> derive_accounts(ticket_id, fd)
      accounts -> accounts
    end
  end

  defp derive_accounts(ticket_id, fd) do
    case fd.accounts_for_requester(ticket_id) do
      {:ok, accounts} when is_list(accounts) -> accounts
      # No authoritative Company custom field — resolve from ticket content
      # (account code / company name / requester email domain).
      _ -> resolve_from_content(ticket_id, fd)
    end
  end

  defp resolve_from_content(ticket_id, fd) do
    with true <- function_exported?(fd, :ticket_text, 1),
         {:ok, info} <- fd.ticket_text(ticket_id),
         {:ok, ref} <- fd.resolve_account(info) do
      [ref]
    else
      _ -> []
    end
  end

  defp entities(nil), do: %{}
  defp entities(account), do: %{account: account}

  # Uncheck the automation's trigger checkbox so our subsequent write-backs don't
  # re-fire it. Best-effort and non-fatal. The field's Freshdesk API name is
  # configurable (`:flag_field` opt or `:ticket_flag_field` app env); `nil`/"" to
  # disable.
  @default_flag_field "cf_tragar_ai"
  defp clear_flag(client, ticket_id, opts) do
    field = Keyword.get(opts, :flag_field) || flag_field_config()

    if is_binary(field) and field != "" do
      attrs = %{custom_fields: %{field => false}}

      with {:error, reason} <- client.update_ticket(ticket_id, attrs) do
        Logger.warning("[ticket_responder] clear flag failed: #{inspect(reason)}")
      end
    end
  rescue
    error -> Logger.warning("[ticket_responder] clear flag error: #{inspect(error)}")
  end

  defp flag_field_config,
    do: Application.get_env(:tragar_ai, :ticket_flag_field, @default_flag_field)

  defp maybe_post(client, ticket_id, interaction, opts) do
    answer = interaction.draft_answer

    if Keyword.get(opts, :post_reply, true) and is_binary(answer) and answer != "" do
      # Lay the note out as HTML so it reads cleanly in Freshdesk (whose notes
      # render HTML): a bold header — which also carries the bot marker for thread
      # exclusion and labels the note's purpose (a resolved answer is a draft the
      # agent can send to the requestor; an unresolved turn is the model asking the
      # agent for input) — then the answer with links, emphasis and paragraphs.
      # The draft is built from source FACTS, so private-note content never bleeds
      # into the customer-facing reply.
      body = format_note(note_label(interaction), answer)
      client.add_note(ticket_id, %{body: body, private: Keyword.get(opts, :private, true)})
    else
      {:ok, :skipped}
    end
  end

  defp note_label(%{status: :drafted}), do: "Suggested reply to requestor"
  defp note_label(_), do: "Agent note (needs input)"

  # Lay out the note as HTML — a bold header (bot marker + purpose label) then the
  # answer rendered via the shared markdown formatter, so the note reads the same
  # as the console/chat.
  defp format_note(label, answer) do
    header = "<strong>#{TragarAi.Freshdesk.bot_marker()} — #{label}</strong>"
    "<p>#{header}</p>\n#{TragarAi.Markdown.to_html(answer)}"
  end

  # The whole ticket thread as the model's context, or the webhook body if the
  # Freshdesk fetch fails.
  defp thread_content(fd, ticket_id, fallback) do
    case safe(fn -> fd.ticket_thread(ticket_id) end) do
      {:ok, %{transcript: t}} when is_binary(t) and t != "" -> t
      _ -> fallback
    end
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # The extracted text of the attachments the agent picked, as a labelled block
  # appended to the model input. Downloaded + parsed here (in the async answer
  # task) so a slow document never blocks the webhook response. Best-effort — a
  # failed file is simply omitted.
  defp attachments_text(ticket_id, opts, fd, client) do
    case opts[:attachment_ids] do
      ids when is_list(ids) and ids != [] -> selected_attachment_text(ticket_id, ids, fd, client)
      _ -> ""
    end
  end

  defp selected_attachment_text(ticket_id, ids, fd, client) do
    wanted = MapSet.new(ids, &to_string/1)

    with {:ok, list} when is_list(list) <- safe(fn -> fd.ticket_attachments(ticket_id) end) do
      blocks =
        list
        |> Enum.filter(&MapSet.member?(wanted, to_string(&1.id)))
        |> Enum.flat_map(fn a ->
          case download_and_extract(client, a) do
            {:ok, text} -> ["--- #{a.name} ---\n#{text}"]
            _ -> []
          end
        end)

      case blocks do
        [] -> ""
        _ -> "\n\n[Attached documents]\n" <> Enum.join(blocks, "\n\n")
      end
    else
      _ -> ""
    end
  end

  defp download_and_extract(client, a) do
    with {:ok, bin} <- client.download(a.url) do
      TragarAi.Assist.Extract.extract(bin, a.content_type, a.name)
    end
  end

  # Pre-fill the ticket's **custom** fields from the facts we just retrieved, so
  # the agent opens a ticket with the data already populated. Best-effort and
  # non-fatal — a failure here never blocks the answer. We never set the
  # assignee/group: assignment stays a human decision (`fill_fields: false` to
  # opt out entirely). Returns the map of fields we filled, for the response.
  defp maybe_fill_fields(client, ticket_id, facts, opts) do
    with true <- Keyword.get(opts, :fill_fields, true),
         true <- is_map(facts) and map_size(facts) > 0,
         {:ok, fields} when is_list(fields) <- client.list_ticket_fields(),
         updates when map_size(updates) > 0 <- FieldMapper.custom_field_updates(fields, facts) do
      case client.update_ticket(ticket_id, %{custom_fields: updates}) do
        {:ok, _} ->
          updates

        {:error, reason} ->
          Logger.warning("[ticket_responder] field pre-fill failed: #{inspect(reason)}")
          %{}
      end
    else
      _ -> %{}
    end
  rescue
    error ->
      Logger.warning("[ticket_responder] field pre-fill error: #{inspect(error)}")
      %{}
  end
end
