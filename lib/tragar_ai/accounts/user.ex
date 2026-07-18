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

    # TOTP second factor (see TragarAi.Accounts.Totp). `totp_secret` is a base32
    # shared secret; `totp_confirmed_at` is non-nil once enrollment is complete
    # (2FA active); `backup_codes` are PBKDF2 hashes of one-time recovery codes.
    attribute :totp_secret, :string, allow_nil?: true, sensitive?: true
    attribute :totp_confirmed_at, :utc_datetime_usec, allow_nil?: true
    attribute :backup_codes, {:array, :string}, allow_nil?: false, default: [], sensitive?: true

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

    # Begin (or restart) TOTP enrollment: store a fresh, unconfirmed secret and
    # clear any prior 2FA state.
    update :begin_totp do
      require_atomic? false
      argument :secret, :string, allow_nil?: false, sensitive?: true

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(
          :totp_secret,
          Ash.Changeset.get_argument(changeset, :secret)
        )
        |> Ash.Changeset.force_change_attribute(:totp_confirmed_at, nil)
        |> Ash.Changeset.force_change_attribute(:backup_codes, [])
      end
    end

    # Finish enrollment: store the hashed backup codes and mark 2FA active.
    update :confirm_totp do
      require_atomic? false
      argument :backup_codes, {:array, :string}, allow_nil?: false, sensitive?: true

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(
          :backup_codes,
          Ash.Changeset.get_argument(changeset, :backup_codes)
        )
        |> Ash.Changeset.force_change_attribute(:totp_confirmed_at, DateTime.utc_now())
      end
    end

    # Persist the remaining backup codes after one is spent.
    update :consume_backup_code do
      require_atomic? false
      argument :remaining, {:array, :string}, allow_nil?: false, sensitive?: true

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :backup_codes,
          Ash.Changeset.get_argument(changeset, :remaining)
        )
      end
    end

    # Admin clears 2FA so the user re-enrolls on next login (lost-device path).
    update :reset_totp do
      require_atomic? false

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(:totp_secret, nil)
        |> Ash.Changeset.force_change_attribute(:totp_confirmed_at, nil)
        |> Ash.Changeset.force_change_attribute(:backup_codes, [])
      end
    end
  end
end
