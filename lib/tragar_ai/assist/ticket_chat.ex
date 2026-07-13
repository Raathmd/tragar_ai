defmodule TragarAi.Assist.TicketChat do
  @moduledoc """
  Synchronous, agent-facing assist for the Freshdesk ticket-sidebar app.

  Unlike `TicketResponder` (async, posts a private note), this runs ONE turn and
  RETURNS the answer for the app to render — nothing is written back to the
  ticket. Because it never posts, there's no agent-in-the-loop review step; the
  agent is the one driving it live.

  Scoped to the ticket requester's entitled accounts (Freshdesk Company
  `freightware_accounts`), so it reuses the Engine's account cycling: a reference
  is searched across those accounts, stopping at the first that owns it. A
  requester with no linked account can't look up waybill/shipper-ref details
  (same boundary as the ticket answer path).

  The Freshdesk facade is injectable (`:freshdesk`) so this is testable without
  the live API.
  """

  alias TragarAi.Assist.Engine

  @spec answer(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def answer(ticket_id, message, opts \\ []) when is_binary(message) do
    fd = Keyword.get(opts, :freshdesk, TragarAi.Freshdesk)
    accounts = accounts_for(ticket_id, fd)

    context = %{
      intent: nil,
      channel: :freshdesk,
      accounts: accounts,
      entities: %{ticket_id: ticket_id},
      history: history(opts[:history]),
      ticket_id: ticket_id
    }

    case Engine.answer(message, context) do
      {:ok, interaction} ->
        {:ok,
         %{
           ticket_id: ticket_id,
           reply: interaction.draft_answer,
           resolved: interaction.status == :drafted,
           intent: interaction.intent && to_string(interaction.intent),
           source: interaction.source,
           accounts: accounts,
           # Reserved for future clickable prompts (e.g. offering a specific
           # account); the Engine already cycles the entitled accounts itself.
           options: []
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The requester's entitled account(s) from Freshdesk (authoritative Company
  # field); fall back to resolving one account from the ticket content.
  defp accounts_for(ticket_id, fd) do
    case fd.accounts_for_requester(ticket_id) do
      {:ok, accounts} when is_list(accounts) -> accounts
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

  # Normalise the client-supplied transcript to the Engine's history shape
  # (`[%{role: "user" | "assistant", text: ...}]`), tolerating string or atom keys.
  defp history(list) when is_list(list) do
    for m <- list,
        is_map(m),
        role = to_string(m["role"] || m[:role] || ""),
        text = m["text"] || m[:text],
        role in ["user", "assistant"] and is_binary(text) and text != "" do
      %{role: role, text: text}
    end
  end

  defp history(_), do: []
end
