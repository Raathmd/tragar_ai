defmodule TragarAi.Support do
  @moduledoc """
  Support domain — `Ticket` records in Tragar's domain shape, sourced from
  Freshdesk via its adapter and cached read-through by `TragarAi.Support.Cache`.
  """

  use Ash.Domain, otp_app: :tragar_ai, extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource TragarAi.Support.Ticket do
      define :upsert_ticket, action: :upsert
      define :get_ticket, action: :read, get_by: [:ticket_id]
      define :list_tickets, action: :read
    end
  end
end
