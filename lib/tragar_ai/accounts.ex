defmodule TragarAi.Accounts do
  @moduledoc """
  Accounts domain — identity and access control for the gateway.

  Holds the authoritative `Account` records (the `account_reference` → contact
  `email` mapping that registration is verified against) and the `ApiClient`
  records that bind an API key to a single account. Elixir stores only SHA-256
  hashes of keys (see `TragarAi.Accounts.Token`); the orchestration of the
  magic-link registration flow lives in `TragarAi.Accounts.Registration`.
  """

  use Ash.Domain, otp_app: :tragar_ai, extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource TragarAi.Accounts.Account do
      define :upsert_account, action: :upsert
      define :get_account, action: :read, get_by: [:account_reference]
      define :list_accounts, action: :read
    end

    resource TragarAi.Accounts.ApiClient do
      define :request_access, action: :request_access
      define :activate_client, action: :activate
      define :revoke_client, action: :revoke
      define :touch_client, action: :touch
      define :create_partner_client, action: :create_partner
      define :provision_client, action: :provision
      define :get_active_client, action: :active_by_token_hash, args: [:token_hash]

      define :get_pending_client,
        action: :pending_by_activation_hash,
        args: [:activation_token_hash]

      define :list_clients, action: :read
    end
  end
end
