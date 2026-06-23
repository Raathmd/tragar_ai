defmodule TragarAi.Freshdesk do
  @moduledoc """
  Freshdesk-facing helpers for the quote-intake loop (the *outbound* direction —
  our app calling Freshdesk with the account's API key).

  - `accounts_for_requester/2` is the **authorization gate**: it resolves the
    FreightWare account(s) a ticket's requester is entitled to, from the
    requester's Company in Freshdesk (a Company custom field holds one or more
    account codes). A requester with no linked company/account is refused — this
    is how we ensure a quote can only be raised by a real customer of an account.
  - `run_quote/3` bridges a ticket to `QuoteIntake.Server` (which derives the
    account via the gate above) and posts the reply back onto the ticket.
  - `create_test_ticket/2` seeds a ticket to exercise the loop end-to-end.

  The Freshdesk client is injectable (`:client` opt) so this is testable without
  hitting the live API.
  """

  alias TragarAi.QuoteIntake.Server

  # Default Company custom-field key holding the account code(s). Override with
  # `config :tragar_ai, :freshdesk_account_field, "cf_..."`.
  @default_account_field "cf_account"

  @doc """
  The FreightWare account code(s) the ticket's requester is entitled to, read
  from their Freshdesk Company. Returns `{:ok, [codes]}` (one or more), or
  `{:error, :requester_not_linked}` when the requester has no company, and
  `{:error, :company_has_no_account}` when the company carries no account code.
  """
  def accounts_for_requester(ticket_id, opts \\ []) do
    client = Keyword.get(opts, :client, TragarAi.Freshdesk.Client)
    field = Keyword.get(opts, :account_field, account_field())

    with {:ok, ticket} <- client.get_ticket(ticket_id),
         {:ok, company} <- fetch_company(client, ticket) do
      case parse_accounts(company, field) do
        [] -> {:error, :company_has_no_account}
        accounts -> {:ok, accounts}
      end
    end
  end

  @doc """
  Run one inbound message from a Freshdesk ticket through quote intake, then post
  the resulting `reply` back onto the ticket as a note. The Server derives the
  account from the requester (see `accounts_for_requester/2`).

  Options: `:client`, `:freightware`, `:freshdesk`, `:private` (note visibility,
  default true), `:reply` (post back at all, default true).
  """
  def run_quote(ticket_id, message, opts \\ []) do
    client = Keyword.get(opts, :client, TragarAi.Freshdesk.Client)

    with {:ok, result} <-
           Server.handle(
             %{ticket_id: to_string(ticket_id), message: message},
             Keyword.take(opts, [:freightware, :freshdesk])
           ),
         {:ok, _} <- maybe_post(client, ticket_id, result.reply, opts) do
      {:ok, result}
    end
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

  defp account_field,
    do: Application.get_env(:tragar_ai, :freshdesk_account_field, @default_account_field)

  defp fetch_company(client, ticket) do
    case ticket["company_id"] || ticket[:company_id] do
      id when not is_nil(id) -> client.get_company(id)
      _ -> {:error, :requester_not_linked}
    end
  end

  # A Company custom field may hold one code or several ("ITD01, ITD02" or a
  # multi-select list). Normalize to an upper-cased, de-duplicated list.
  defp parse_accounts(company, field) do
    cf = company["custom_fields"] || company[:custom_fields] || %{}

    (cf[field] || cf[to_string(field)] || company[field])
    |> List.wrap()
    |> Enum.flat_map(fn
      s when is_binary(s) -> String.split(s, ~r/[,;\s]+/, trim: true)
      _ -> []
    end)
    |> Enum.map(&(&1 |> String.trim() |> String.upcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp maybe_post(client, ticket_id, reply, opts) do
    if Keyword.get(opts, :reply, true) do
      client.add_note(ticket_id, %{body: reply, private: Keyword.get(opts, :private, true)})
    else
      {:ok, :skipped}
    end
  end
end
