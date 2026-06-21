defmodule TragarAi.Logistics do
  @moduledoc """
  Logistics domain — FreightWare reads cached as Ash resources in Postgres.

  `Shipment` (waybills + tracking + POD) and `Quote` are populated read-through
  by `TragarAi.Logistics.Cache` from the live `TragarAi.Freight` API, so the
  assist loop and AshAdmin query Elixir's own store rather than hitting
  FreightWare on every read. (The Phase-2 reconcile job will keep these fresh.)
  """

  use Ash.Domain, otp_app: :tragar_ai, extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource TragarAi.Logistics.Shipment do
      define :upsert_shipment, action: :upsert
      define :get_shipment_by_waybill, action: :read, get_by: [:waybill_number]
      define :list_shipments, action: :read
      define :list_shipments_for_account, action: :for_account, args: [:account_reference]
    end

    resource TragarAi.Logistics.Quote do
      define :upsert_quote, action: :upsert
      define :get_quote_by_number, action: :read, get_by: [:quote_number]
      define :list_quotes, action: :read
      define :list_quotes_for_account, action: :for_account, args: [:account_reference]
    end
  end
end
