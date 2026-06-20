defmodule TragarAi.Assist.Interaction do
  @moduledoc """
  A single support-assist interaction: the customer question, how the model
  interpreted it, the live facts fetched, the drafted answer, and what the agent
  did with it. Serves as the history shown in the console and the audit log
  (e.g. after-hours lookups a person reviews in the morning).
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
    attribute :facts, :map, default: %{}
    attribute :source, :string, description: "Source system that served the fact."
    attribute :draft_answer, :string
    attribute :final_answer, :string

    attribute :status, :atom,
      constraints: [one_of: [:drafted, :relayed, :discarded, :failed]],
      default: :drafted,
      allow_nil?: false

    attribute :error, :string
    attribute :agent, :string, description: "Agent who handled the interaction."

    timestamps()
  end

  actions do
    defaults [:read, :destroy]

    create :draft do
      accept [
        :question,
        :intent,
        :entities,
        :facts,
        :source,
        :draft_answer,
        :status,
        :error,
        :agent
      ]
    end

    update :relay do
      accept [:final_answer, :agent]
      change set_attribute(:status, :relayed)
    end

    update :discard do
      accept [:agent]
      change set_attribute(:status, :discarded)
    end
  end
end
