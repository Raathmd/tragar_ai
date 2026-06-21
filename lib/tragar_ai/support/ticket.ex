defmodule TragarAi.Support.Ticket do
  @moduledoc "A support ticket in Tragar's domain (Freshdesk-sourced), with provenance."

  use Ash.Resource,
    otp_app: :tragar_ai,
    domain: TragarAi.Support,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "tickets"
    repo TragarAi.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :ticket_id, :string, allow_nil?: false
    attribute :subject, :string
    attribute :status, :string
    attribute :priority, :string
    attribute :requester_email, :string
    attribute :account_reference, :string
    attribute :updated_at_source, :string

    attribute :sources, {:array, :string}, default: []
    attribute :source_data, :map, default: %{}
    attribute :cached_at, :utc_datetime_usec

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
        :subject,
        :status,
        :priority,
        :requester_email,
        :account_reference,
        :updated_at_source,
        :sources,
        :source_data,
        :cached_at
      ]

      upsert? true
      upsert_identity :unique_ticket
    end
  end
end
