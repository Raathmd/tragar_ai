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

  alias TragarAi.Assist.Engine

  @spec respond(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def respond(ticket_id, content, opts \\ []) when is_binary(content) do
    fd = Keyword.get(opts, :freshdesk, TragarAi.Freshdesk)
    client = Keyword.get(opts, :client, TragarAi.Freshdesk.Client)
    account = account_for(ticket_id, fd)

    context = %{demo: false, intent: nil, entities: entities(account)}

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

        maybe_post(client, ticket_id, result.answer, opts)
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Scope facts to the requester's account when Freshdesk links one (best-effort —
  # a general read-only answer can still be composed without it).
  defp account_for(ticket_id, fd) do
    case fd.accounts_for_requester(ticket_id) do
      {:ok, [acc | _]} -> acc
      _ -> nil
    end
  end

  defp entities(nil), do: %{}
  defp entities(account), do: %{account: account}

  defp maybe_post(client, ticket_id, answer, opts) do
    if Keyword.get(opts, :post_reply, true) and is_binary(answer) and answer != "" do
      client.add_note(ticket_id, %{body: answer, private: Keyword.get(opts, :private, true)})
    else
      {:ok, :skipped}
    end
  end
end
