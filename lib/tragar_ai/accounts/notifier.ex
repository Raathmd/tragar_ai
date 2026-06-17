defmodule TragarAi.Accounts.Notifier do
  @moduledoc "Builds and delivers account notification emails via Swoosh."

  import Swoosh.Email

  alias TragarAi.Mailer

  @doc "Email the customer a magic link to activate their API access."
  def deliver_magic_link(email, token, account_reference) do
    url = activation_url(token)

    new()
    |> to(email)
    |> from(from_address())
    |> subject("Your Tragar API access for account #{account_reference}")
    |> text_body("""
    Hello,

    A request was made to grant API access for Tragar account #{account_reference}.

    To activate your API key, open this link (valid for 24 hours):

    #{url}

    If you did not request this, you can safely ignore this email.

    — Tragar
    """)
    |> html_body("""
    <p>Hello,</p>
    <p>A request was made to grant API access for Tragar account
    <strong>#{account_reference}</strong>.</p>
    <p>To activate your API key, click the link below (valid for 24 hours):</p>
    <p><a href="#{url}">Activate API access</a></p>
    <p>If you did not request this, you can safely ignore this email.</p>
    <p>— Tragar</p>
    """)
    |> Mailer.deliver()
  end

  defp activation_url(token), do: "#{base_url()}/activate/#{token}"

  defp base_url do
    :tragar_ai
    |> Application.get_env(TragarAi.Accounts, [])
    |> Keyword.get(:base_url, "http://localhost:4000")
  end

  defp from_address do
    :tragar_ai
    |> Application.get_env(TragarAi.Accounts, [])
    |> Keyword.get(:from_email, "no-reply@tragar.co.za")
    |> then(&{"Tragar", &1})
  end
end
