defmodule TragarAi.Repo.Migrations.AddTotpToUsers do
  use Ecto.Migration

  # Second-factor (TOTP) enrollment for margin logins (see TragarAi.Accounts.Totp).
  # totp_secret: base32 shared secret; totp_confirmed_at: non-null once 2FA is
  # active; backup_codes: PBKDF2 hashes of one-time recovery codes.
  def change do
    alter table(:users) do
      add :totp_secret, :string
      add :totp_confirmed_at, :utc_datetime_usec
      add :backup_codes, {:array, :text}, null: false, default: []
    end
  end
end
