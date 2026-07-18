defmodule TragarAi.Accounts.UserRole do
  @moduledoc """
  Join between a `User` and a `Role`. A user may hold several roles; their
  effective permissions are the union across all of them.
  """

  use Ash.Resource,
    otp_app: :tragar_ai,
    domain: TragarAi.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "user_roles"
    repo TragarAi.Repo
  end

  attributes do
    uuid_primary_key :id
    timestamps()
  end

  relationships do
    belongs_to :user, TragarAi.Accounts.User, allow_nil?: false, attribute_writable?: true
    belongs_to :role, TragarAi.Accounts.Role, allow_nil?: false, attribute_writable?: true
  end

  identities do
    identity :unique_user_role, [:user_id, :role_id]
  end

  actions do
    defaults [:read, :destroy, create: [:user_id, :role_id]]
  end
end
