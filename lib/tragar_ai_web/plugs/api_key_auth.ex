defmodule TragarAiWeb.Plugs.ApiKeyAuth do
  @moduledoc """
  Authenticates AI callers via an `Authorization: Bearer <key>` header
  (an `x-api-key: <key>` header is also accepted) and resolves the key to a
  scope used for authorization downstream.

  Two kinds of key:

    * **Partner** keys — configured under `config :tragar_ai, TragarAi.Gateway,
      partner_api_keys: [...]`. Trusted systems (Freddy) that may request access
      on customers' behalf, but may not read customer data directly.
    * **Account** keys — issued at runtime via the magic-link flow and stored
      (hashed) as `TragarAi.Accounts.ApiClient`. Locked to a single
      `account_reference`.

  On success stashes `conn.assigns.gateway_auth`:

      %{scope: :partner | :account, account_reference: nil | binary,
        client_id: nil | binary, client: binary}

  On failure halts with `401`. If no partner keys are configured and no key is
  presented, the request is treated as an anonymous partner — intended for local
  dev only (such a caller still cannot read account-scoped data).
  """

  import Plug.Conn

  alias TragarAi.Accounts.Registration

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case extract_key(conn) do
      nil ->
        if partner_keys() == [] do
          assign(conn, :gateway_auth, anonymous())
        else
          unauthorized(conn)
        end

      key ->
        authenticate(conn, key)
    end
  end

  defp authenticate(conn, key) do
    cond do
      key in partner_keys() ->
        assign(conn, :gateway_auth, %{
          scope: :partner,
          account_reference: nil,
          client_id: nil,
          client: "partner"
        })

      match?({:ok, _}, Registration.resolve(key)) ->
        {:ok, client} = Registration.resolve(key)
        # Best-effort last-used bookkeeping; never block the request on it.
        _ = TragarAi.Accounts.touch_client(client)

        assign(conn, :gateway_auth, %{
          scope: client.scope,
          account_reference: client.account_reference,
          client_id: client.id,
          client: client.label || "account:#{client.account_reference}"
        })

      true ->
        unauthorized(conn)
    end
  end

  defp anonymous,
    do: %{scope: :partner, account_reference: nil, client_id: nil, client: "anonymous"}

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      401,
      Jason.encode!(%{error: "unauthorized", message: "Invalid or missing API key"})
    )
    |> halt()
  end

  defp partner_keys do
    :tragar_ai
    |> Application.get_env(TragarAi.Gateway, [])
    |> Keyword.get(:partner_api_keys, [])
  end

  defp extract_key(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> key | _] -> String.trim(key)
      ["bearer " <> key | _] -> String.trim(key)
      _ -> conn |> get_req_header("x-api-key") |> List.first()
    end
  end
end
