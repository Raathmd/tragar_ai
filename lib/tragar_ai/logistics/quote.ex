defmodule TragarAi.Logistics.Quote do
  @moduledoc """
  Cached FreightWare quote — header fields plus items and sundries. Promoted
  columns for querying/AshAdmin; `raw` keeps the full normalized quote. Upserted
  by `TragarAi.Logistics.Cache`.
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
    attribute :service_type, :string
    attribute :status_code, :string
    attribute :status_description, :string
    attribute :consignor_name, :string
    attribute :consignee_name, :string
    attribute :charged_amount, :string

    attribute :items, {:array, :map}, default: []
    attribute :sundries, {:array, :map}, default: []
    attribute :raw, :map, default: %{}, description: "Full normalized quote."
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
        :service_type,
        :status_code,
        :status_description,
        :consignor_name,
        :consignee_name,
        :charged_amount,
        :items,
        :sundries,
        :raw,
        :cached_at
      ]

      upsert? true
      upsert_identity :unique_quote
    end
  end
end
