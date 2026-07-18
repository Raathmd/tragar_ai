defmodule TragarAi.Repo.Migrations.CreateRoles do
  use Ecto.Migration

  # Role-based access to the browser LiveViews (see TragarAi.Accounts.Role).
  #   roles            — named permission bundles; is_admin? = wildcard (all pages)
  #   role_permissions — one row per (role, page_key) the role may view
  #   user_roles       — join: a user holds one or more roles
  # Also adds users.mfa_required so an account (e.g. the shared CSD display) can
  # skip the TOTP second factor.
  def change do
    create table(:roles, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :is_admin, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:roles, [:name])

    create table(:role_permissions, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :role_id, references(:roles, type: :uuid, on_delete: :delete_all), null: false

      add :page_key, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:role_permissions, [:role_id, :page_key])

    create table(:user_roles, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :role_id, references(:roles, type: :uuid, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_roles, [:user_id, :role_id])

    alter table(:users) do
      add :mfa_required, :boolean, null: false, default: true
    end
  end
end
