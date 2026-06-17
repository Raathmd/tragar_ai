defmodule TragarAiWeb.ActivationController do
  @moduledoc """
  Handles the customer-facing magic link.

  `GET /activate/:token` activates a pending `ApiClient`, issues the API key, and
  renders it **once** with instructions to add it to Freshdesk. The key is shown
  only here — it is never stored in plaintext, so it cannot be retrieved again.
  """

  use TragarAiWeb, :controller

  alias TragarAi.Accounts.Registration

  def show(conn, %{"token" => token}) do
    case Registration.activate(token) do
      {:ok, api_key, client} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, success_page(api_key, client))

      {:error, :invalid_or_expired} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(410, error_page())
    end
  end

  defp success_page(api_key, client) do
    page("""
    <h1>API access activated</h1>
    <p>Your API key for account <strong>#{esc(client.account_reference)}</strong> is ready.
    Copy it now — for security it is shown only once and cannot be retrieved again.</p>
    <pre class="key">#{esc(api_key)}</pre>
    <h2>Next step</h2>
    <p>Add this key to your Freshdesk integration so Freddy can answer status
    questions for your account. Send it as the
    <code>Authorization: Bearer &lt;key&gt;</code> header.</p>
    """)
  end

  defp error_page do
    page("""
    <h1>Link invalid or expired</h1>
    <p>This activation link is no longer valid. Please request access again from
    Freshdesk to receive a new link.</p>
    """)
  end

  defp page(inner) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Tragar API Access</title>
      <style>
        body { font-family: system-ui, sans-serif; max-width: 40rem; margin: 4rem auto; padding: 0 1rem; color: #1a1a1a; }
        h1 { font-size: 1.5rem; } h2 { font-size: 1.1rem; margin-top: 2rem; }
        pre.key { background: #f4f4f5; border: 1px solid #d4d4d8; border-radius: .5rem; padding: 1rem; font-size: 1.1rem; word-break: break-all; white-space: pre-wrap; }
        code { background: #f4f4f5; padding: .1rem .3rem; border-radius: .25rem; }
      </style>
    </head>
    <body>#{inner}</body>
    </html>
    """
  end

  defp esc(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
