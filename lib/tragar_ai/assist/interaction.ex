defmodule TragarAi.Assist.Interaction do
  @moduledoc """
  A single support-assist interaction — the durable **dashboard-stats** record:
  the customer question, how the model interpreted it, which source served it,
  the outcome status and loop latency.

  The fetched source data (`facts`/`tool_log`) and the rehydrated answer are
  customer PII and are deliberately **not** persisted — they live only in the
  in-memory record the engine returns for the active turn (console/chat render +
  ticket draft), and are discarded after. Only the metadata below is stored, so
  the dashboard stats survive restarts without keeping PII at rest.
  """

  use Ash.Resource,
    otp_app: :tragar_ai,
    domain: TragarAi.Assist,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "interactions"
    repo TragarAi.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :question, :string, allow_nil?: false
    attribute :intent, :string
    attribute :entities, :map, default: %{}
    attribute :source, :string, description: "Source system that served the fact."

    attribute :status, :atom,
      constraints: [one_of: [:drafted, :relayed, :discarded, :failed, :reasoned]],
      default: :drafted,
      allow_nil?: false

    attribute :error, :string
    attribute :agent, :string, description: "Agent who handled the interaction."

    attribute :ticket_id, :string,
      description: "Freshdesk ticket this interaction answered (nil for ad-hoc console/chat)."

    attribute :duration_ms, :integer,
      description: "Wall-clock ms for the assist loop (interpret → fetch → phrase)."

    timestamps()
  end

  actions do
    defaults [:read, :destroy]

    create :draft do
      accept [
        :question,
        :intent,
        :entities,
        :source,
        :status,
        :error,
        :agent,
        :ticket_id,
        :duration_ms
      ]
    end

    update :relay do
      accept [:agent]
      change set_attribute(:status, :relayed)
    end

    update :discard do
      accept [:agent]
      change set_attribute(:status, :discarded)
    end
  end
end
