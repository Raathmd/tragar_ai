defmodule TragarAiWeb.Plugs.ApiAuth do
  @moduledoc """
  Bearer-token auth for the inbound `/api` surface.

  The Freshdesk automation sends `Authorization: Bearer <token>` — the token is
  configured once on the automation's webhook and sent on every call. We compare
  it (constant-time) against `:api_key`.

  When `:api_key` is unset the surface is open — intended for local development
  only; production sets `TRAGAR_API_KEY` (see `config/runtime.exs`).
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case Application.get_env(:tragar_ai, :api_key) do
      key when key in [nil, ""] -> conn
      key -> if authorized?(conn, key), do: conn, else: deny(conn)
    end
  end

  defp authorized?(conn, key) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Plug.Crypto.secure_compare(token, key)
      _ -> false
    end
  end

  defp deny(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
    |> halt()
  end
end
