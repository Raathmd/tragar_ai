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
      define :get_interaction, action: :read, get_by: [:id]
      define :list_interactions, action: :read
    end
  end

  @doc """
  Mark an interaction relayed. Accepts the engine's in-memory record (a plain map
  with `:id`) or the persisted struct — the row is reloaded by id, then updated.
  """
  def relay_interaction(%{id: id}, params \\ %{}), do: update_by_id(id, :relay, params)

  @doc "Mark an interaction discarded (see `relay_interaction/2` for the arg shape)."
  def discard_interaction(%{id: id}, params \\ %{}), do: update_by_id(id, :discard, params)

  defp update_by_id(id, action, params) do
    with {:ok, rec} <- get_interaction(id) do
      rec
      |> Ash.Changeset.for_update(action, Map.take(params, [:agent]))
      |> Ash.update()
    end
  end
end
