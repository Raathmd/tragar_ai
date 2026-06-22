defmodule TragarAi.QuoteIntake.Session do
  @moduledoc "A guided quote conversation, keyed by Freshdesk ticket."

  use Ash.Resource,
    otp_app: :tragar_ai,
    domain: TragarAi.QuoteIntake,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "quote_sessions"
    repo TragarAi.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :ticket_id, :string, allow_nil?: false
    attribute :account_reference, :string, allow_nil?: false
    attribute :requester_email, :string

    # collecting → ready (all params gathered) → accepted | rejected.
    attribute :status, :string, default: "collecting"

    # Filled quote parameters keyed by slot ("service", "collection", …).
    attribute :slots, :map, default: %{}

    attribute :request_text, :string, description: "The customer's opening message."
    attribute :last_reply, :string, description: "The last question/answer we sent back."
    attribute :quote_number, :string, description: "Set once a FreightWare quote exists."

    timestamps()
  end

  identities do
    identity :unique_ticket, [:ticket_id]
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      accept [
        :ticket_id,
        :account_reference,
        :requester_email,
        :status,
        :slots,
        :request_text,
        :last_reply,
        :quote_number
      ]

      upsert? true
      upsert_identity :unique_ticket
    end
  end
end
