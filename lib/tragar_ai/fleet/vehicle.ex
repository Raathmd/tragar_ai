defmodule TragarAi.Fleet.Vehicle do
  @moduledoc "A fleet vehicle in Tragar's domain (FleetIT-sourced), with provenance."

  use Ash.Resource,
    otp_app: :tragar_ai,
    domain: TragarAi.Fleet,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "vehicles"
    repo TragarAi.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :registration, :string, allow_nil?: false
    attribute :status, :string
    attribute :available, :boolean
    attribute :description, :string

    attribute :sources, {:array, :string},
      default: [],
      description: "Source systems contributing to this vehicle (derived from source records)."

    attribute :cached_at, :utc_datetime_usec

    timestamps()
  end

  identities do
    identity :unique_registration, [:registration]
  end

  relationships do
    has_many :source_records, TragarAi.Sources.SourceRecord do
      no_attributes? true
      filter expr(entity_type == "vehicle" and entity_key == parent(registration))
    end
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      accept [
        :registration,
        :status,
        :available,
        :description,
        :sources,
        :cached_at
      ]

      upsert? true
      upsert_identity :unique_registration
    end
  end
end
