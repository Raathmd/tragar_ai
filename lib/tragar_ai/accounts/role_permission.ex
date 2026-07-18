defmodule TragarAi.Accounts.RolePermission do
  @moduledoc """
  One page a role may view. `page_key` is a stable identifier for a gated
  LiveView (see `TragarAi.Accounts.pages/0`), e.g. `"collections"`,
  `"supplier_ops"`. A role's viewable pages = its set of these rows; the `admin`
  wildcard role has none (it sees everything).
  """

  use Ash.Resource,
    otp_app: :tragar_ai,
    domain: TragarAi.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "role_permissions"
    repo TragarAi.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :page_key, :string, allow_nil?: false
    timestamps()
  end

  relationships do
    belongs_to :role, TragarAi.Accounts.Role, allow_nil?: false, attribute_writable?: true
  end

  identities do
    identity :unique_role_page, [:role_id, :page_key]
  end

  actions do
    defaults [:read, :destroy, create: [:role_id, :page_key]]
  end
end
