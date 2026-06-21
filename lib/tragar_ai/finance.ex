defmodule TragarAi.Finance do
  @moduledoc """
  Finance domain — `Invoice` records in Tragar's domain shape. Source: Pastel
  (via its adapter, once access is provisioned); shape + provenance defined now
  so it plugs in cleanly.
  """

  use Ash.Domain, otp_app: :tragar_ai, extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource TragarAi.Finance.Invoice do
      define :upsert_invoice, action: :upsert
      define :get_invoice, action: :read, get_by: [:invoice_number]
      define :list_invoices, action: :read
    end
  end
end
