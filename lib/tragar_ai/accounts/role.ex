defmodule TragarAi.Accounts.Role do
  @moduledoc """
  A named bundle of page permissions. A user is granted one or more roles (via
  `UserRole`); the union of their roles' `RolePermission` rows is what they may
  view. `is_admin` roles are a wildcard — they see every page regardless of the
  permission rows, so the `admin` role carries no explicit `role_permissions`.

  Seeded roles (see the data migration): `admin` (wildcard), `csd` (collections
  only — the shared-display account), `operations` (supplier-selection board).
  """

  use Ash.Resource,
    otp_app: :tragar_ai,
    domain: TragarAi.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "roles"
    repo TragarAi.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string, allow_nil?: false
    attribute :description, :string, allow_nil?: true

    # Wildcard flag: an is_admin role grants every page (no permission rows).
    attribute :is_admin, :boolean, allow_nil?: false, default: false

    timestamps()
  end

  identities do
    identity :unique_name, [:name]
  end

  relationships do
    has_many :permissions, TragarAi.Accounts.RolePermission

    many_to_many :users, TragarAi.Accounts.User do
      through TragarAi.Accounts.UserRole
      source_attribute_on_join_resource :role_id
      destination_attribute_on_join_resource :user_id
    end
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [:name, :description, :is_admin],
      update: [:name, :description, :is_admin]
    ]
  end
end
