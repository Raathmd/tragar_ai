defmodule TragarAi.Logistics.Quote do
  @moduledoc """
  A quote in **Tragar's** domain — source-agnostic, with `sources` + `source_data`
  provenance. Populated read-through by `TragarAi.Logistics.Cache` (FreightWare
  today).
  """

  use Ash.Resource,
    otp_app: :tragar_ai,
    domain: TragarAi.Logistics,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "quotes"
    repo TragarAi.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :quote_number, :string, allow_nil?: false
    attribute :quote_obj, :string
    attribute :account_reference, :string
    attribute :status, :string
    attribute :status_code, :string
    attribute :service_type, :string
    attribute :consignor, :string
    attribute :consignee, :string
    attribute :charged_amount, :string

    attribute :items, {:array, :map}, default: []
    attribute :sundries, {:array, :map}, default: []

    attribute :sources, {:array, :string}, default: []
    attribute :source_data, :map, default: %{}

    attribute :cached_at, :utc_datetime_usec

    timestamps()
  end

  identities do
    identity :unique_quote, [:quote_number]
  end

  actions do
    defaults [:read, :destroy]

    read :for_account do
      argument :account_reference, :string, allow_nil?: false
      filter expr(account_reference == ^arg(:account_reference))
    end

    create :upsert do
      accept [
        :quote_number,
        :quote_obj,
        :account_reference,
        :status,
        :status_code,
        :service_type,
        :consignor,
        :consignee,
        :charged_amount,
        :items,
        :sundries,
        :sources,
        :source_data,
        :cached_at
      ]

      upsert? true
      upsert_identity :unique_quote
    end
  end
end
