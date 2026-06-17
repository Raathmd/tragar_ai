defmodule TragarAi.Accounts.Registration do
  @moduledoc """
  Orchestrates the magic-link registration flow.

  1. `request_access/2` — a partner (Freddy) asks for access for an account +
     email. We verify the account exists and the email matches the authoritative
     `Account.email`. On a match we create a pending `ApiClient` and email the
     customer a magic link. To avoid account/email enumeration this always
     returns `:ok` regardless of whether a match was found.
  2. `activate/1` — the customer follows the link; we issue an API key (returning
     the plaintext **once**) and activate the client.
  3. `resolve/1` — used by the auth plug to turn a presented key into its active
     `ApiClient`.
  """

  alias TragarAi.Accounts
  alias TragarAi.Accounts.{Notifier, Token}

  require Logger

  @activation_ttl_seconds 24 * 60 * 60

  @spec request_access(String.t(), String.t()) :: :ok
  def request_access(account_reference, email)
      when is_binary(account_reference) and is_binary(email) do
    with {:ok, account} <- Accounts.get_account(account_reference),
         true <- account.active,
         true <- emails_match?(account.email, email) do
      token = Token.generate_activation_token()

      {:ok, _client} =
        Accounts.request_access(%{
          account_id: account.id,
          account_reference: account.account_reference,
          email: to_string(account.email),
          label: "Freshdesk – #{account.account_reference}",
          activation_token_hash: Token.hash(token),
          activation_expires_at:
            DateTime.add(DateTime.utc_now(), @activation_ttl_seconds, :second)
        })

      Notifier.deliver_magic_link(to_string(account.email), token, account.account_reference)
      :ok
    else
      _ ->
        Logger.info("Access request for #{account_reference} did not match — no email sent")
        :ok
    end
  end

  def request_access(_, _), do: :ok

  @spec activate(String.t()) ::
          {:ok, api_key :: String.t(), Ash.Resource.record()} | {:error, :invalid_or_expired}
  def activate(token) when is_binary(token) do
    with {:ok, client} <- Accounts.get_pending_client(Token.hash(token)),
         false <- expired?(client) do
      api_key = Token.generate_api_key()
      {:ok, client} = Accounts.activate_client(client, %{token_hash: Token.hash(api_key)})
      {:ok, api_key, client}
    else
      _ -> {:error, :invalid_or_expired}
    end
  end

  def activate(_), do: {:error, :invalid_or_expired}

  @spec resolve(String.t()) :: {:ok, Ash.Resource.record()} | :error
  def resolve(api_key) when is_binary(api_key) do
    case Accounts.get_active_client(Token.hash(api_key)) do
      {:ok, %{} = client} -> {:ok, client}
      _ -> :error
    end
  end

  def resolve(_), do: :error

  @doc """
  Admin/seed/test helper: directly mint an active account-scoped key, bypassing
  the magic-link flow. Returns the plaintext key **once**.
  """
  @spec provision_account_key(Ash.Resource.record(), keyword()) ::
          {:ok, api_key :: String.t(), Ash.Resource.record()}
  def provision_account_key(account, opts \\ []) do
    api_key = Token.generate_api_key()

    {:ok, client} =
      Accounts.provision_client(%{
        scope: :account,
        account_id: account.id,
        account_reference: account.account_reference,
        email: to_string(account.email),
        label: opts[:label] || "Account #{account.account_reference}",
        token_hash: Token.hash(api_key)
      })

    {:ok, api_key, client}
  end

  defp emails_match?(nil, _), do: false

  defp emails_match?(account_email, given) do
    String.downcase(String.trim(to_string(account_email))) ==
      String.downcase(String.trim(given))
  end

  defp expired?(%{activation_expires_at: nil}), do: false
  defp expired?(%{activation_expires_at: at}), do: DateTime.compare(DateTime.utc_now(), at) == :gt
end
