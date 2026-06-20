defmodule TragarAi.Assist do
  @moduledoc """
  Assist domain — the Phase 1 support-assist surface.

  Owns the `Interaction` resource (history + audit). The orchestration of the
  safe loop (interpret → validate → fetch → phrase) lives in
  `TragarAi.Assist.Engine`.
  """

  use Ash.Domain, otp_app: :tragar_ai, extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource TragarAi.Assist.Interaction do
      define :create_interaction, action: :draft
      define :relay_interaction, action: :relay
      define :discard_interaction, action: :discard
      define :get_interaction, action: :read, get_by: [:id]
      define :list_interactions, action: :read
    end
  end
end
