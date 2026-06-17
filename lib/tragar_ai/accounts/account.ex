defmodule TragarAi.Accounts.Account do
  @moduledoc """
  An authoritative FreightWare account record: its `account_reference`, the
  contact `email` registration is verified against, and a display `name`.

  Seeded/synced from FreightWare base data (`TragarAi.Dovetail.Client.accounts/1`).
  """

  use Ash.Resource,
    otp_app: :tragar_ai,
    domain: TragarAi.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "accounts"
    repo TragarAi.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :account_reference, :string, allow_nil?: false
    attribute :email, :ci_string, description: "Authoritative contact email (case-insensitive)."
    attribute :name, :string
    attribute :active, :boolean, default: true, allow_nil?: false

    timestamps()
  end

  identities do
    identity :unique_reference, [:account_reference]
  end

  relationships do
    has_many :api_clients, TragarAi.Accounts.ApiClient
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      accept [:account_reference, :email, :name, :active]
      upsert? true
      upsert_identity :unique_reference
    end

    update :update do
      accept [:email, :name, :active]
    end
  end
end
