defmodule TragarAi.Freshdesk.Client do
  @moduledoc """
  REST client for the [Freshdesk API v2](https://developers.freshdesk.com/api/).

  ## Authentication

  Freshdesk uses HTTP Basic auth: the API key is the username and any value
  (conventionally `"X"`) is the password. The base URL is derived from the
  configured account domain, e.g. domain `"tragar"` →
  `https://tragar.freshdesk.com/api/v2`.

  Configure via `config/runtime.exs` under `TragarAi.Freshdesk.Client`.
  """

  require Logger

  @api_path "/api/v2"

  # ── Configuration ───────────────────────────────────────────────────────────

  @doc "Returns the keyword config for this client."
  def config, do: Application.get_env(:tragar_ai, __MODULE__, [])

  @doc "Base URL derived from the configured Freshdesk domain."
  def base_url do
    domain = fetch!(:domain)

    cond do
      String.starts_with?(domain, "http") -> domain
      String.contains?(domain, ".") -> "https://#{domain}"
      true -> "https://#{domain}.freshdesk.com"
    end
  end

  defp fetch!(key) do
    config()
    |> Keyword.fetch(key)
    |> case do
      {:ok, nil} -> raise "Freshdesk config #{inspect(key)} is not set"
      {:ok, value} -> value
      :error -> raise "Freshdesk config #{inspect(key)} is missing"
    end
  end

  # ── Tickets ───────────────────────────────────────────────────────────────────

  @doc "List tickets. `params` is a map of query filters (e.g. `%{updated_since: ...}`)."
  def list_tickets(params \\ %{}), do: get("/tickets", params: params)

  @doc "Fetch a single ticket by id."
  def get_ticket(id, params \\ %{}), do: get("/tickets/#{id}", params: params)

  @doc """
  Create a ticket. `attrs` is a map of Freshdesk ticket fields, e.g.

      %{subject: "Delivery exception WB123", description: "...",
        email: "customer@example.com", priority: 2, status: 2}
  """
  def create_ticket(attrs), do: post("/tickets", attrs)

  @doc "Update a ticket."
  def update_ticket(id, attrs), do: put("/tickets/#{id}", attrs)

  @doc """
  List every ticket field with its type and — for dropdowns — the allowed
  `choices`. Used to discover which fields exist and what values they accept
  before the assistant pre-fills them.
  """
  def list_ticket_fields, do: get("/ticket_fields")

  @doc "Add a public or private note/reply to a ticket."
  def add_note(ticket_id, attrs), do: post("/tickets/#{ticket_id}/notes", attrs)

  @doc "Add a reply (outgoing email) to a ticket."
  def reply_to_ticket(ticket_id, attrs), do: post("/tickets/#{ticket_id}/reply", attrs)

  # ── Contacts & companies ───────────────────────────────────────────────────────

  def list_contacts(params \\ %{}), do: get("/contacts", params: params)
  def get_contact(id), do: get("/contacts/#{id}")
  def create_contact(attrs), do: post("/contacts", attrs)
  def update_contact(id, attrs), do: put("/contacts/#{id}", attrs)

  def list_companies(params \\ %{}), do: get("/companies", params: params)
  def get_company(id), do: get("/companies/#{id}")

  @doc "Lightweight connectivity probe against the account's settings endpoint."
  @spec health() :: :ok | {:error, term()}
  def health do
    case get("/settings/helpdesk") do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # ── HTTP plumbing ───────────────────────────────────────────────────────────

  @doc false
  def get(path, opts \\ []), do: request(:get, path, opts)

  @doc false
  def post(path, body, opts \\ []), do: request(:post, path, Keyword.put(opts, :json, body))

  @doc false
  def put(path, body, opts \\ []), do: request(:put, path, Keyword.put(opts, :json, body))

  defp request(method, path, opts) do
    req = base_request() |> Req.merge([method: method, url: @api_path <> path] ++ opts)

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: 429} = resp} ->
        retry_after = Req.Response.get_header(resp, "retry-after")
        {:error, {:rate_limited, retry_after}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp base_request do
    [
      base_url: base_url(),
      auth: {:basic, "#{fetch!(:api_key)}:X"},
      receive_timeout: 30_000,
      retry: :transient,
      max_retries: 2,
      headers: [{"content-type", "application/json"}]
    ]
    |> Keyword.merge(Keyword.get(config(), :req_options, []))
    |> Req.new()
  end
end
