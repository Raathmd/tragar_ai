defmodule TragarAi.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  # People allowed into the margin dashboards (see TragarAi.Accounts.User).
  # type: "admin" | "user"; must_reset forces a password change on first login.
  def change do
    create table(:users, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :email, :string, null: false
      add :type, :string, null: false, default: "user"
      add :hashed_password, :string
      add :must_reset, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])
  end
end
