defmodule TragarAiWeb.FreightWareController do
  @moduledoc """
  Staff action to force a fresh FreightWare login from the nav's "Log in" button
  (shown only when there's no session token). Invalidates any cached token and
  re-authenticates via `TragarAi.Dovetail.Client.login/0` (the configured
  username / password / station), then flashes the outcome so the result — a
  token, or the exact error — is visible immediately.
  """
  use TragarAiWeb, :controller

  def login(conn, _params) do
    TragarAi.Dovetail.TokenStore.invalidate(:any)

    conn =
      case TragarAi.Dovetail.TokenStore.token() do
        {:ok, _token} ->
          put_flash(conn, :info, "FreightWare login OK — session token acquired.")

        {:error, reason} ->
          put_flash(conn, :error, "FreightWare login failed: #{inspect(reason)}")
      end

    redirect(conn, to: back_to(conn))
  end

  # Return to the page the button was clicked from (path only, so it can't be an
  # open redirect); fall back to the dashboard.
  defp back_to(conn) do
    with [referer | _] <- get_req_header(conn, "referer"),
         %URI{path: path} when is_binary(path) and path != "" <- URI.parse(referer) do
      path
    else
      _ -> ~p"/"
    end
  end
end
