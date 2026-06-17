defmodule TragarAi.Logistics.Shipment do
  @moduledoc """
  A cached snapshot of a Dovetail/FreightWare waybill (shipment).

  Records are upserted from Dovetail by `TragarAi.Integration` when a waybill is
  looked up or tracked. The `raw` attribute keeps the full upstream payload so
  no information is lost even though only the commonly-queried fields are
  promoted to columns.
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

    attribute :tracking_events, {:array, :map},
      default: [],
      description: "Most recent track-and-trace events, as returned by Dovetail."

    attribute :raw, :map, default: %{}, description: "Full upstream payload from FreightWare."

    attribute :view, :map,
      default: %{},
      description: "Normalized AI-facing shipment view, returned verbatim on cache hits."

    attribute :tracked_at, :utc_datetime_usec

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

    create :create do
      accept [
        :waybill_number,
        :account_reference,
        :shipper_reference,
        :service_type,
        :status_code,
        :status_description,
        :consignor_name,
        :consignee_name,
        :tracking_events,
        :raw,
        :view,
        :tracked_at
      ]
    end

    update :update do
      accept [
        :account_reference,
        :shipper_reference,
        :service_type,
        :status_code,
        :status_description,
        :consignor_name,
        :consignee_name,
        :tracking_events,
        :raw,
        :view,
        :tracked_at
      ]
    end

    # Insert-or-update keyed on the waybill number — used by the sync layer.
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
        :tracking_events,
        :raw,
        :view,
        :tracked_at
      ]

      upsert? true
      upsert_identity :unique_waybill
    end
  end
end
