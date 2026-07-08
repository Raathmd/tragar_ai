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

  # FreightWare returns the session token in a header whose spelling varies
  # ("x-freightware" and "xfreightware" have both been observed, and the
  # hyphenated one can come back empty). Read the first non-empty value across
  # the known spellings; an empty token is treated as a failure by login/0.
  @token_headers ["x-freightware", "xfreightware"]

  defp token_from_headers(%Req.Response{} = resp) do
    Enum.find_value(@token_headers, fn header ->
      case Req.Response.get_header(resp, header) do
        [token | _] when is_binary(token) and token != "" -> token
        _ -> nil
      end
    end)
  end

  # Operation-specific endpoints (quotes, waybills, base data) live in
  # `TragarAi.Freight`, which calls the transport functions below and normalizes
  # the responses. This module is the transport layer only.

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
    {filters, opts} = Keyword.pop(opts, :filters)
    {paging, opts} = Keyword.pop(opts, :paging)

    with {:ok, token} <- TragarAi.Dovetail.TokenStore.token() do
      req =
        base_request()
        |> Req.merge([method: method, url: @api_path <> path] ++ opts)
        |> Req.Request.put_header(@auth_header, token)
        |> maybe_put_esfilters(filters, paging)

      case Req.request(req) do
        {:ok, %Req.Response{status: status}} when status in [401, 403] and retry? ->
          # Compare-and-invalidate the exact token that was rejected, then retry
          # once. The TokenStore's login barrier collapses concurrent retries into
          # a single re-login, so a burst of 401s can't stampede.
          TragarAi.Dovetail.TokenStore.invalidate(token)
          request(method, path, opts, false)

        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          decode(body)

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # We take the raw body (Req's `decode_body: false`) and decode it ourselves so
  # we can scrub the non-UTF-8 bytes FreightWare leaves in some text fields (e.g.
  # 0xA0 Latin-1 non-breaking space) that would otherwise break JSON decoding.
  defp decode(""), do: {:ok, %{}}

  defp decode(body) when is_binary(body) do
    case body |> scrub_utf8() |> Jason.decode() do
      {:ok, decoded} -> {:ok, unwrap(decoded)}
      {:error, %Jason.DecodeError{} = err} -> {:error, {:decode_failed, err.position}}
    end
  end

  defp decode(body), do: {:ok, unwrap(body)}

  # Keep valid UTF-8 codepoints; replace any invalid byte with a space.
  defp scrub_utf8(binary), do: do_scrub(binary, []) |> IO.iodata_to_binary()

  defp do_scrub(<<>>, acc), do: Enum.reverse(acc)
  defp do_scrub(<<c::utf8, rest::binary>>, acc), do: do_scrub(rest, [<<c::utf8>> | acc])
  defp do_scrub(<<_bad, rest::binary>>, acc), do: do_scrub(rest, [" " | acc])

  # FreightWare passes search filters/paging in an `esfilters` HTTP header whose
  # value is a JSON string (capitalised Filters/Paging, camelCase inner keys).
  defp maybe_put_esfilters(req, filters, paging) do
    if filters in [nil, []] and is_nil(paging) do
      req
    else
      payload =
        %{"Filters" => build_filters(filters)}
        |> maybe_add_paging(paging)

      Req.Request.put_header(req, "esfilters", Jason.encode!(payload))
    end
  end

  defp build_filters(nil), do: []

  defp build_filters(filters) do
    Enum.map(filters, fn {name, value} ->
      %{"filterName" => to_string(name), "filterValue" => to_string(value)}
    end)
  end

  defp maybe_add_paging(payload, nil), do: payload

  defp maybe_add_paging(payload, paging) do
    Map.put(payload, "Paging", [
      %{
        "paged" => Map.get(paging, :paged, true),
        "resultsPerPage" => Map.get(paging, :results_per_page, 20),
        "pageNumber" => Map.get(paging, :page_number, 1)
      }
    ])
  end

  # Base Req request shared by every call: base URL, JSON content-type, timeouts,
  # and a small amount of transient-failure retrying handled by Req itself.
  defp base_request do
    [
      base_url: base_url(),
      receive_timeout: 30_000,
      retry: :transient,
      max_retries: 2,
      # We decode JSON ourselves (in `decode/1`) after scrubbing non-UTF-8 bytes.
      decode_body: false,
      headers: [{"content-type", "application/json"}, {"accept", "application/json"}]
    ]
    |> Keyword.merge(tls_connect_options())
    |> Keyword.merge(Keyword.get(config(), :req_options, []))
    |> Req.new()
  end

  # TLS options apply ONLY to https endpoints. Passing SSL transport_opts (verify,
  # cacerts, …) to a plain-http (TCP) connection throws :badarg, so for http we
  # add nothing. For https: the Dovetail server presents only its leaf certificate
  # (no intermediate) and Erlang's TLS doesn't chase AIA for the missing one — so
  # default verification fails with `unknown_ca`. We verify against the OS trust
  # store plus the bundled Sectigo intermediate, completing the chain ourselves.
  defp tls_connect_options do
    if String.starts_with?(base_url(), "https") do
      [
        connect_options: [
          transport_opts: [
            verify: :verify_peer,
            depth: 5,
            cacerts: ca_certs(),
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]
        ]
      ]
    else
      []
    end
  end

  # OS root CAs plus the bundled Sectigo intermediate, as DER binaries — built
  # once and cached (decoding ~160 roots on every request would be wasteful).
  defp ca_certs do
    case :persistent_term.get({__MODULE__, :cacerts}, nil) do
      nil ->
        certs = build_ca_certs()
        :persistent_term.put({__MODULE__, :cacerts}, certs)
        certs

      certs ->
        certs
    end
  end

  defp build_ca_certs do
    os_roots = Enum.map(:public_key.cacerts_get(), fn {:cert, der, _} -> der end)
    os_roots ++ extra_ca_certs()
  end

  # The intermediate(s) the server omits, shipped in priv/cert and trusted so the
  # path to a known root can be built. Missing file → no extras (verify still on).
  defp extra_ca_certs do
    path = Path.join(:code.priv_dir(:tragar_ai), "cert/sectigo_intermediate.pem")

    case File.read(path) do
      {:ok, pem} -> for {:Certificate, der, _} <- :public_key.pem_decode(pem), do: der
      {:error, _} -> []
    end
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
