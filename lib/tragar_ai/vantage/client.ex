defmodule TragarAi.Vantage.Client do
  @moduledoc """
  REST client for Vantage (telematics / trip data) at `multi.vantage.run`.

  Auth: `POST /api/auth/login` with `{email, password}` returns an
  `Authentication-Token`, sent on every subsequent request in the
  `Authentication-Token` header. The token is cached by `Vantage.TokenStore`.

  Configure via `config/runtime.exs` under `TragarAi.Vantage.Client`
  (`base_url`, `email`, `password`).
  """

  alias TragarAi.Vantage.TokenStore

  @api "/api"

  def config, do: Application.get_env(:tragar_ai, __MODULE__, [])
  def base_url, do: Keyword.get(config(), :base_url) || "https://multi.vantage.run"

  @doc "Authenticate. Returns `{:ok, token}` or `{:error, reason}`."
  def login do
    body = %{"email" => fetch!(:email), "password" => fetch!(:password)}
    req = base_request() |> Req.merge(method: :post, url: "#{@api}/auth/login", json: body)

    case Req.request(req) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        case token_from(resp) do
          nil -> {:error, {:no_token, status}}
          token -> {:ok, token}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:auth_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Trips created since `created_since` — a `YYYYMMDDHHmmss` datetime string.
  Returns `{:ok, trips}` (a list).
  """
  def trips_since(created_since, page \\ 1) when is_binary(created_since),
    do: get("/master_trip/created_since", params: [createdSince: created_since, page: page])

  @doc false
  def get(path, opts \\ [], retry? \\ true) do
    with {:ok, token} <- TokenStore.token() do
      req =
        base_request()
        |> Req.merge(
          [method: :get, url: @api <> path, headers: [{"authentication-token", token}]] ++ opts
        )

      case Req.request(req) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %Req.Response{status: 401, body: body}} ->
          # Token expired/revoked — drop it and re-authenticate once.
          TokenStore.invalidate()
          if retry?, do: get(path, opts, false), else: {:error, {:unauthorized, body}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ── internals ────────────────────────────────────────────────────────────────

  defp token_from(%Req.Response{body: body} = resp) do
    from_body =
      is_map(body) &&
        (body["auth_token"] || body["Authentication-Token"] || body["authentication_token"] ||
           body["authToken"] || body["token"])

    from_body || Req.Response.get_header(resp, "authentication-token") |> List.first()
  end

  defp fetch!(key) do
    case Keyword.fetch(config(), key) do
      {:ok, v} when not is_nil(v) and v != "" -> v
      _ -> raise "Vantage config #{inspect(key)} is not set"
    end
  end

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
end
