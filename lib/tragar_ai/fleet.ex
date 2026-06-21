defmodule TragarAi.Fleet do
  @moduledoc """
  Fleet domain — `Vehicle` records in Tragar's domain shape. Source: FleetIT
  (via its adapter, once access is provisioned); shape + provenance defined now.
  """

  use Ash.Domain, otp_app: :tragar_ai, extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource TragarAi.Fleet.Vehicle do
      define :upsert_vehicle, action: :upsert
      define :get_vehicle, action: :read, get_by: [:registration]
      define :list_vehicles, action: :read
    end
  end
end
