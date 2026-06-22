defmodule TragarAi.Freshdesk do
  @moduledoc """
  Freshdesk-facing helpers for the quote-intake loop (the *outbound* direction —
  our app calling Freshdesk with the account's API key).

  - `run_quote/3` bridges a ticket to `QuoteIntake.Server`: run one customer
    message through the guided flow and post the reply back onto the ticket.
  - `account_for/1` derives the Tragar account from a ticket.
  - `create_test_ticket/2` seeds a ticket so the loop can be exercised end-to-end
    against a trial (or marked test) Freshdesk account — there's no sandbox API.

  The Freshdesk client is injectable (`:client` opt) so this is testable without
  hitting the live API.
  """

  alias TragarAi.QuoteIntake.Server

  @doc """
  Run one inbound message from a Freshdesk ticket through quote intake, then post
  the resulting `reply` back onto the ticket as a note.

  Options: `:account` (skip ticket lookup), `:client`, `:freightware`,
  `:private` (note visibility, default true), `:reply` (post back at all, default true).
  """
  def run_quote(ticket_id, message, opts \\ []) do
    client = Keyword.get(opts, :client, TragarAi.Freshdesk.Client)

    with {:ok, account} <- resolve_account(ticket_id, client, opts),
         {:ok, result} <-
           Server.handle(
             %{ticket_id: to_string(ticket_id), account: account, message: message},
             Keyword.take(opts, [:freightware])
           ),
         {:ok, _} <- maybe_post(client, ticket_id, result.reply, opts) do
      {:ok, result}
    end
  end

  @doc "Best-effort: the Tragar account a ticket is about (custom field or company)."
  def account_for(ticket) when is_map(ticket) do
    cf = ticket["custom_fields"] || ticket[:custom_fields] || %{}

    cf["cf_account"] || cf["account"] || cf["cf_account_code"] || cf["account_code"] ||
      ticket["company_name"] || ticket[:company_name]
  end

  @doc "Create a clearly-marked test ticket to drive the quote loop end-to-end."
  def create_test_ticket(attrs \\ %{}, opts \\ []) do
    client = Keyword.get(opts, :client, TragarAi.Freshdesk.Client)

    body =
      Map.merge(
        %{
          subject: "TEST — quote request",
          description: "Hi, I'd like a quote for a delivery please.",
          email: "test.buyer@example.com",
          priority: 1,
          status: 2,
          tags: ["tragar-test"]
        },
        attrs
      )

    client.create_ticket(body)
  end

  # ── internals ────────────────────────────────────────────────────────────────

  defp resolve_account(ticket_id, client, opts) do
    case Keyword.get(opts, :account) do
      acc when is_binary(acc) and acc != "" ->
        {:ok, acc}

      _ ->
        with {:ok, ticket} <- client.get_ticket(ticket_id) do
          case account_for(ticket) do
            acc when is_binary(acc) and acc != "" -> {:ok, acc}
            _ -> {:error, :account_not_found_on_ticket}
          end
        end
    end
  end

  defp maybe_post(client, ticket_id, reply, opts) do
    if Keyword.get(opts, :reply, true) do
      client.add_note(ticket_id, %{body: reply, private: Keyword.get(opts, :private, true)})
    else
      {:ok, :skipped}
    end
  end
end
