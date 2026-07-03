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
  alias TragarAi.Freshdesk.Client

  # Default Company custom-field key holding the account code(s). Override with
  # `config :tragar_ai, :freshdesk_account_field, "cf_..."`.
  @default_account_field "freightware_accounts"

  # Freshdesk numeric ticket statuses.
  @status_names %{2 => "open", 3 => "pending", 4 => "resolved", 5 => "closed"}

  @doc """
  Live ticket list for the console's left panel. `filters` may include
  `:status` (default `"open"`; `"all"` for every status) and `:agent_id`.
  Returns display maps, newest-first.
  """
  def console_tickets(filters \\ %{}) do
    status = Map.get(filters, :status, "open")
    agent_id = Map.get(filters, :agent_id)

    with {:ok, list} when is_list(list) <-
           Client.list_tickets(%{per_page: 100, order_by: "updated_at", order_type: "desc"}) do
      tickets =
        list
        |> Enum.filter(fn t ->
          status in [nil, "", "all"] or @status_names[t["status"]] == status
        end)
        |> Enum.filter(fn t -> is_nil(agent_id) or t["responder_id"] == agent_id end)
        |> Enum.map(&ticket_summary/1)

      {:ok, tickets}
    end
  end

  @doc "Helpdesk agents as `[%{id, name}]` for the console's agent filter."
  def agents do
    with {:ok, list} when is_list(list) <- Client.list_agents(%{per_page: 100}) do
      {:ok,
       Enum.map(list, fn a ->
         %{id: a["id"], name: get_in(a, ["contact", "name"]) || "Agent #{a["id"]}"}
       end)}
    end
  end

  @doc """
  A ticket's full content + the signals used to resolve its account, in ONE
  Freshdesk call (`?include=requester,company`): subject/body/text plus the
  requester email + domain and the company name.
  """
  def ticket_text(id) do
    with {:ok, t} <- Client.get_ticket(id, %{include: "requester,company"}) do
      subject = t["subject"] || ""
      body = t["description_text"] || strip_html(t["description"] || "")
      email = get_in(t, ["requester", "email"]) || t["email"]

      {:ok,
       %{
         ticket_id: to_string(t["id"] || id),
         subject: subject,
         body: body,
         text: String.trim("#{subject}\n\n#{body}"),
         requester_email: email,
         requester_domain: email_domain(email),
         company_id: t["company_id"],
         company_name: get_in(t, ["company", "name"])
       }}
    end
  end

  # Tragar AI's own notes are prefixed with this marker so the thread can exclude
  # them — the model must never read (and echo) its own prior answers.
  @bot_marker "Tragar AI"

  @doc "The marker Tragar AI's own notes start with (see `ticket_thread/2`)."
  def bot_marker, do: @bot_marker

  # Keep the request + the most recent messages so a long ticket can't blow the prompt.
  @thread_max 25

  @doc """
  The full ticket thread for the model's context: the original request plus every
  reply and private note, oldest→newest, each labelled **Requestor** (the
  customer) or **Agent** (a human agent — public reply or private note). Tragar
  AI's own notes are excluded so the model never reads its own answers. Returns
  the assembled `transcript` plus the account-resolution signals; the caller falls
  back to the webhook body if this can't be fetched.
  """
  def ticket_thread(id, opts \\ []) do
    client = Keyword.get(opts, :client, Client)

    with {:ok, t} <- client.get_ticket(id, %{include: "requester,company"}) do
      convos =
        case client.conversations(id) do
          {:ok, list} when is_list(list) -> list
          _ -> []
        end

      email = get_in(t, ["requester", "email"]) || t["email"]

      {:ok,
       %{
         ticket_id: to_string(t["id"] || id),
         subject: t["subject"],
         transcript: build_thread(t, convos),
         requester_email: email,
         requester_domain: email_domain(email),
         company_id: t["company_id"],
         company_name: get_in(t, ["company", "name"])
       }}
    end
  end

  defp build_thread(ticket, convos) do
    opening = "Requestor: " <> body_of(ticket["description_text"], ticket["description"])

    lines =
      convos
      |> Enum.sort_by(&(&1["created_at"] || ""))
      |> Enum.reject(&ours?/1)
      |> Enum.map(&thread_line/1)
      |> Enum.reject(&is_nil/1)

    ([opening] ++ Enum.take(lines, -@thread_max)) |> Enum.join("\n\n")
  end

  # Ours = a private note whose text starts with the bot marker.
  defp ours?(%{"private" => true} = c),
    do: c |> convo_text() |> String.trim() |> String.starts_with?(@bot_marker)

  defp ours?(_), do: false

  defp thread_line(c) do
    case String.trim(convo_text(c)) do
      "" -> nil
      body -> "#{role(c)}: #{body}"
    end
  end

  defp role(%{"incoming" => true}), do: "Requestor (reply)"
  defp role(%{"private" => true}), do: "Agent (note)"
  defp role(_), do: "Agent (reply)"

  defp convo_text(c), do: body_of(c["body_text"], c["body"])

  defp body_of(text, html) do
    if is_binary(text) and String.trim(text) != "", do: text, else: strip_html(html || "")
  end

  @doc """
  Resolve the FreightWare account for a ticket from its content — a valid account
  code found in the body, the company name, or the requester's email domain —
  via `Freight.Accounts.resolve/1`. Returns `{:ok, ref}` | `{:ambiguous, refs}` |
  `:none`. Complements the authoritative Company custom-field gate
  (`accounts_for_requester/2`) as a fallback when that field is unset.
  """
  def resolve_account(info) when is_map(info) do
    TragarAi.Freight.Accounts.resolve(%{
      code: account_code_in(info[:body] || info["body"]),
      company: info[:company_name] || info["company_name"],
      domain: info[:requester_domain] || info["requester_domain"]
    })
  end

  # First account-code-shaped token in the text that is actually a valid account.
  defp account_code_in(text) when is_binary(text) do
    ~r/\b[A-Za-z]{2,}\d{1,}[A-Za-z0-9]*\b/
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.find(&TragarAi.Freight.Accounts.valid?/1)
  end

  defp account_code_in(_), do: nil

  defp email_domain(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [_, dom] -> dom |> String.trim() |> String.downcase()
      _ -> nil
    end
  end

  defp email_domain(_), do: nil

  defp ticket_summary(t) do
    %{
      id: to_string(t["id"]),
      subject: t["subject"] || "(no subject)",
      status: @status_names[t["status"]] || to_string(t["status"]),
      priority: t["priority"],
      responder_id: t["responder_id"],
      updated_at: t["updated_at"]
    }
  end

  defp strip_html(html) do
    html
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

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
    normalize_codes(cf[field] || cf[to_string(field)] || company[field])
  end

  @doc """
  Normalize one or several account codes to an upper-cased, de-duplicated list.
  Accepts a string ("ITD01, ITD02"), a list, or nil — used for both the Company
  custom field and a webhook-supplied account value.
  """
  def normalize_codes(value) do
    value
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
