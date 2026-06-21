defmodule TragarAi.Logistics.Shipment do
  @moduledoc """
  Cached FreightWare waybill (shipment) — status, parties, tracking events and
  POD. Promoted columns are for querying/AshAdmin; `raw` keeps the full
  normalized waybill so nothing is lost. Upserted by `TragarAi.Logistics.Cache`.
  """

  use Ash.Resource,
    otp_app: :tragar_ai,
    domain: TragarAi.Logistics,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "shipments"
    repo TragarAi.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :waybill_number, :string, allow_nil?: false
    attribute :account_reference, :string
    attribute :shipper_reference, :string
    attribute :service_type, :string
    attribute :status_code, :string
    attribute :status_description, :string
    attribute :consignor_name, :string
    attribute :consignee_name, :string
    attribute :consignee_city, :string

    attribute :tracking_events, {:array, :map}, default: []
    attribute :pod, :map
    attribute :raw, :map, default: %{}, description: "Full normalized waybill."
    attribute :cached_at, :utc_datetime_usec

    timestamps()
  end

  identities do
    identity :unique_waybill, [:waybill_number]
  end

  actions do
    defaults [:read, :destroy]

    read :for_account do
      argument :account_reference, :string, allow_nil?: false
      filter expr(account_reference == ^arg(:account_reference))
    end

    create :upsert do
      accept [
        :waybill_number,
        :account_reference,
        :shipper_reference,
        :service_type,
        :status_code,
        :status_description,
        :consignor_name,
        :consignee_name,
        :consignee_city,
        :tracking_events,
        :pod,
        :raw,
        :cached_at
      ]

      upsert? true
      upsert_identity :unique_waybill
    end
  end
end
