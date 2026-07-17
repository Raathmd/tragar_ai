defmodule TragarAi.Accounts.User do
  @moduledoc """
  A person allowed into the margin dashboards. `type` is `"admin"` (can manage
  other users) or `"user"`. `must_reset` forces a password change on first login.
  Passwords are never stored in the clear — only `hashed_password` (PBKDF2).
  """

  use Ash.Resource,
    otp_app: :tragar_ai,
    domain: TragarAi.Accounts,
    data_layer: AshPostgres.DataLayer

  alias TragarAi.Accounts.HashPassword

  postgres do
    table "users"
    repo TragarAi.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :string, allow_nil?: false

    # "admin" | "user" — validated by TragarAi.Accounts.create_user/2.
    attribute :type, :string, allow_nil?: false, default: "user"

    attribute :hashed_password, :string, allow_nil?: true, sensitive?: true
    attribute :must_reset, :boolean, allow_nil?: false, default: true

    timestamps()
  end

  identities do
    identity :unique_email, [:email]
  end

  actions do
    defaults [:read, :destroy]

    create :register do
      accept [:email, :type]
      argument :password, :string, allow_nil?: false, sensitive?: true
      change HashPassword
    end

    # Self-service reset (first login or later): sets the password and clears the
    # must_reset flag.
    update :set_password do
      require_atomic? false
      argument :password, :string, allow_nil?: false, sensitive?: true
      change HashPassword
      change set_attribute(:must_reset, false)
    end

    # Admin re-issues a temp password (forgot-password path); forces reset again.
    update :reissue_password do
      require_atomic? false
      argument :password, :string, allow_nil?: false, sensitive?: true
      change HashPassword
      change set_attribute(:must_reset, true)
    end
  end
end
