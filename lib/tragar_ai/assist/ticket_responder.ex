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

    # Distil the thread into a clean query first — same step the console runs — so
    # the loop looks up the shipment references in the ticket instead of just
    # echoing the ticket metadata.
    query = distil(content)

    # `:accounts` enforces scope in the Engine — facts must be on the requester's
    # account, so a ticket can't pull another account's records.
    context = %{
      intent: nil,
      accounts: accounts,
      entities: entities(account),
      ticket_id: ticket_id
    }

    case Engine.answer(query, context) do
      {:ok, interaction} ->
        result = %{
          ticket_id: ticket_id,
          account: account,
          answer: interaction.draft_answer,
          resolved: interaction.status == :drafted,
          intent: interaction.intent && to_string(interaction.intent),
          source: interaction.source
        }

        maybe_post(client, ticket_id, result.answer, opts)
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

  # Reuse the console's distiller; fall back to the raw content if it's unavailable.
  defp distil(content) do
    case TragarAi.CoreAI.distil(content) do
      {:ok, query} when is_binary(query) and query != "" -> query
      _ -> content
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

  defp maybe_post(client, ticket_id, answer, opts) do
    if Keyword.get(opts, :post_reply, true) and is_binary(answer) and answer != "" do
      # Prefix the bot marker so this note is excluded from the thread next time
      # (the model must never read its own answers back in as context).
      body = "#{TragarAi.Freshdesk.bot_marker()}\n\n#{answer}"
      client.add_note(ticket_id, %{body: body, private: Keyword.get(opts, :private, true)})
    else
      {:ok, :skipped}
    end
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
