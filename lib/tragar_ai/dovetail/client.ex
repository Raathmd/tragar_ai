defmodule TragarAi.Dovetail.Client do
  @moduledoc """
  REST client for Tragar's **Dovetail** system — the FreightWare API hosted at
  `tragar-db.dovetail.co.za`.

  ## Authentication

  A `POST {base}/FreightWare/V2/system/auth/login` with body
  `%{"request" => %{"username" => ..., "password" => ..., "station" => ...}}`
  returns a session token in the `X-FreightWare` **response header**. Every
  subsequent request sends that token back in the `X-FreightWare` **request
  header**. The token is cached by `TragarAi.Dovetail.TokenStore`; this module
  transparently re-authenticates once if a request is rejected as unauthorized.

  ## Request / response envelope

  FreightWare wraps request bodies in a top-level `"request"` key and responses
  in a top-level `"response"` key. The `*` functions here accept and return the
  *inner* maps; the envelope is added/stripped for you.

  Configure via `config/runtime.exs` under `TragarAi.Dovetail.Client`.
  """

  require Logger

  @api_path "/FreightWare/V2"
  @auth_header "x-freightware"

  # ── Configuration ───────────────────────────────────────────────────────────

  @doc "Returns the keyword config for this client."
  def config, do: Application.get_env(:tragar_ai, __MODULE__, [])

  @doc "Base URL of the configured Dovetail environment."
  def base_url, do: fetch!(:base_url)

  defp fetch!(key) do
    config()
    |> Keyword.fetch(key)
    |> case do
      {:ok, nil} -> raise "Dovetail config #{inspect(key)} is not set"
      {:ok, value} -> value
      :error -> raise "Dovetail config #{inspect(key)} is missing"
    end
  end

  # ── Authentication ──────────────────────────────────────────────────────────

  @doc """
  Logs in and returns `{:ok, token}` with the session token from the
  `X-FreightWare` response header, or `{:error, reason}`.

  Prefer `TragarAi.Dovetail.TokenStore.token/0`, which caches the result.
  """
  @spec login() :: {:ok, String.t()} | {:error, term()}
  def login do
    body = %{
      "request" => %{
        "username" => fetch!(:username),
        "password" => fetch!(:password),
        "station" => fetch!(:station)
      }
    }

    req = base_request() |> Req.merge(url: @api_path <> "/system/auth/login", json: body)

    case Req.post(req) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        case token_from_headers(resp) do
          nil -> {:error, {:no_token, resp.status}}
          token -> {:ok, token}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:auth_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp token_from_headers(%Req.Response{} = resp) do
    case Req.Response.get_header(resp, @auth_header) do
      [token | _] when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  # ── Quotes ──────────────────────────────────────────────────────────────────

  @doc "Generate an instant ('quick') freight quote. Returns the rates response."
  def quick_quote(params), do: post("/quotes/quick", params)

  @doc "Create a formal quote from quick-quote details."
  def create_quote(params), do: post("/quotes/", params)

  @doc "Fetch a single quote by its FreightWare object id."
  def get_quote(quote_obj), do: get("/quotes/#{quote_obj}/")

  @doc "Search quotes. `params` is a map of query-string filters."
  def search_quotes(params \\ %{}), do: get("/quotes/", params: params)

  @doc "Accept a quote. `acceptance_type` is e.g. `\"quote\"` or `\"waybill\"`."
  def accept_quote(quote_obj, acceptance_type, params \\ %{}),
    do: put("/quotes/#{quote_obj}/accept/#{acceptance_type}", params)

  @doc "Reject a quote."
  def reject_quote(quote_obj, params \\ %{}), do: put("/quotes/#{quote_obj}/reject", params)

  # ── Waybills & tracking ───────────────────────────────────────────────────────

  @doc "Search waybills. `params` is a map of query-string filters."
  def list_waybills(params \\ %{}), do: get("/waybills/", params: params)

  @doc "Fetch a single waybill by number."
  def get_waybill(waybill_number), do: get("/waybills/#{waybill_number}")

  @doc """
  Track & trace by reference. `ref_type` is `:waybills` or `:quotes`
  (anything FreightWare accepts as a track root). Returns tracking events.
  """
  def track_and_trace(ref_type, reference),
    do: get("/#{ref_type}/#{reference}/trackAndTrace")

  @doc """
  Fetch a POD (proof-of-delivery) document image as raw bytes.
  Returns `{:ok, binary}` on success.
  """
  def pod_image(path), do: get_raw("/document/image/#{path}")

  # ── Base data ─────────────────────────────────────────────────────────────────

  def service_types(params \\ %{}), do: get("/system/baseData/serviceTypes", params: params)

  def consignment_types(params \\ %{}),
    do: get("/system/baseData/consignmentTypes", params: params)

  def products(params \\ %{}), do: get("/system/baseData/products", params: params)
  def accounts(params \\ %{}), do: get("/system/baseData/accounts", params: params)
  def sites(params \\ %{}), do: get("/system/baseData/sites", params: params)
  def postal_codes(params \\ %{}), do: get("/system/baseData/postalCodes", params: params)

  @doc "Lightweight connectivity probe — succeeds if we can obtain a token."
  @spec health() :: :ok | {:error, term()}
  def health do
    case TragarAi.Dovetail.TokenStore.token() do
      {:ok, _token} -> :ok
      error -> error
    end
  end

  # ── HTTP plumbing ───────────────────────────────────────────────────────────

  @doc false
  def get(path, opts \\ []), do: request(:get, path, opts)

  @doc false
  def post(path, body, opts \\ []),
    do: request(:post, path, Keyword.put(opts, :json, wrap(body)))

  @doc false
  def put(path, body, opts \\ []),
    do: request(:put, path, Keyword.put(opts, :json, wrap(body)))

  # Performs a request with the cached token, re-authenticating once on 401/403.
  defp request(method, path, opts, retry? \\ true) do
    with {:ok, token} <- TragarAi.Dovetail.TokenStore.token() do
      req =
        base_request()
        |> Req.merge([method: method, url: @api_path <> path] ++ opts)
        |> Req.Request.put_header(@auth_header, token)

      case Req.request(req) do
        {:ok, %Req.Response{status: status}} when status in [401, 403] and retry? ->
          TragarAi.Dovetail.TokenStore.invalidate()
          request(method, path, opts, false)

        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, unwrap(body)}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Raw variant for binary payloads (e.g. POD images) — no JSON decoding/unwrap.
  defp get_raw(path, retry? \\ true) do
    with {:ok, token} <- TragarAi.Dovetail.TokenStore.token() do
      req =
        base_request()
        |> Req.merge(method: :get, url: @api_path <> path, decode_body: false)
        |> Req.Request.put_header(@auth_header, token)

      case Req.request(req) do
        {:ok, %Req.Response{status: status}} when status in [401, 403] and retry? ->
          TragarAi.Dovetail.TokenStore.invalidate()
          get_raw(path, false)

        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Base Req request shared by every call: base URL, JSON content-type, timeouts,
  # and a small amount of transient-failure retrying handled by Req itself.
  defp base_request do
    [
      base_url: base_url(),
      receive_timeout: 30_000,
      retry: :transient,
      max_retries: 2,
      headers: [{"content-type", "application/json"}, {"accept", "application/json"}]
    ]
    |> Keyword.merge(Keyword.get(config(), :req_options, []))
    |> Req.new()
  end

  # FreightWare wraps request bodies in a "request" envelope. If the caller has
  # already wrapped it, leave it alone.
  defp wrap(%{"request" => _} = body), do: body
  defp wrap(%{request: _} = body), do: body
  defp wrap(body), do: %{"request" => body}

  # ...and wraps responses in a "response" envelope. Strip it when present.
  defp unwrap(%{"response" => response}), do: response
  defp unwrap(body), do: body
end
