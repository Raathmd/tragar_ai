defmodule TragarAi.Customers.Customer do
  @moduledoc "A customer/account in Tragar's domain, with multi-source provenance."

  use Ash.Resource,
    otp_app: :tragar_ai,
    domain: TragarAi.Customers,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "customers"
    repo TragarAi.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :account_reference, :string, allow_nil?: false
    attribute :name, :string
    attribute :email, :string
    attribute :description, :string

    attribute :sources, {:array, :string}, default: []
    attribute :source_data, :map, default: %{}
    attribute :cached_at, :utc_datetime_usec

    timestamps()
  end

  identities do
    identity :unique_account, [:account_reference]
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      accept [
        :account_reference,
        :name,
        :email,
        :description,
        :sources,
        :source_data,
        :cached_at
      ]

      upsert? true
      upsert_identity :unique_account
    end
  end
end
