defmodule TragarAi.Logistics do
  @moduledoc """
  Logistics domain — the Dovetail (FreightWare) side of the integration.

  Holds locally-cached snapshots of shipments/waybills pulled from Dovetail so
  support agents can query them without hitting the upstream API on every read,
  and so Freshdesk tickets can be linked to a known shipment.
  """

  use Ash.Domain, otp_app: :tragar_ai, extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource TragarAi.Logistics.Shipment do
      define :list_shipments, action: :read
      define :list_shipments_for_account, action: :for_account, args: [:account_reference]
      define :get_shipment_by_waybill, action: :read, get_by: [:waybill_number]
      define :upsert_shipment, action: :upsert
    end
  end
end
