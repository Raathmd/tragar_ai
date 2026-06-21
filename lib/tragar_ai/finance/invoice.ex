defmodule TragarAi.Finance.Invoice do
  @moduledoc "An invoice in Tragar's domain (Pastel-sourced), with provenance."

  use Ash.Resource,
    otp_app: :tragar_ai,
    domain: TragarAi.Finance,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "invoices"
    repo TragarAi.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :invoice_number, :string, allow_nil?: false
    attribute :account_reference, :string
    attribute :amount, :string
    attribute :balance, :string
    attribute :status, :string
    attribute :invoice_date, :string

    attribute :sources, {:array, :string}, default: []
    attribute :source_data, :map, default: %{}
    attribute :cached_at, :utc_datetime_usec

    timestamps()
  end

  identities do
    identity :unique_invoice, [:invoice_number]
  end

  actions do
    defaults [:read, :destroy]

    read :for_account do
      argument :account_reference, :string, allow_nil?: false
      filter expr(account_reference == ^arg(:account_reference))
    end

    create :upsert do
      accept [
        :invoice_number,
        :account_reference,
        :amount,
        :balance,
        :status,
        :invoice_date,
        :sources,
        :source_data,
        :cached_at
      ]

      upsert? true
      upsert_identity :unique_invoice
    end
  end
end
