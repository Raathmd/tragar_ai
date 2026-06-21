defmodule TragarAi.Customers do
  @moduledoc """
  Customers domain — `Customer` records in Tragar's domain shape. Today sourced
  from FreightWare accounts; Freshdesk contacts and Pastel can contribute via
  their adapters (recorded in `sources`/`source_data`). Cached read-through by
  `TragarAi.Customers.Cache`.
  """

  use Ash.Domain, otp_app: :tragar_ai, extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource TragarAi.Customers.Customer do
      define :upsert_customer, action: :upsert
      define :get_customer, action: :read, get_by: [:account_reference]
      define :list_customers, action: :read
    end
  end
end
