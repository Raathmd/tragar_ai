defmodule TragarAi.Logistics.Shipment do
  @moduledoc """
  A shipment in **Tragar's** domain — a consignment/delivery, independent of any
  one source system. Fields use domain vocabulary (status, consignor, consignee);
  `sources` records which systems contributed and `source_data` keeps each
  source's raw payload for provenance. Today FreightWare populates it (status,
  events, POD); Granite/Vantage will contribute POD/route via their adapters.

  Populated read-through by `TragarAi.Logistics.Cache`.
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
    attribute :status, :string
    attribute :status_code, :string
    attribute :service_type, :string
    attribute :consignor, :string
    attribute :consignee, :string
    attribute :consignee_city, :string

    attribute :events, {:array, :map}, default: []
    attribute :pod, :map

    attribute :sources, {:array, :string},
      default: [],
      description: "Source systems that contributed to this record."

    attribute :source_data, :map,
      default: %{},
      description: "Provenance: each source's raw payload, keyed by source name."

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
        :status,
        :status_code,
        :service_type,
        :consignor,
        :consignee,
        :consignee_city,
        :events,
        :pod,
        :sources,
        :source_data,
        :cached_at
      ]

      upsert? true
      upsert_identity :unique_waybill
    end
  end
end
