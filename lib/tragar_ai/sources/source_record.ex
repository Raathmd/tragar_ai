defmodule TragarAi.Sources.SourceRecord do
  @moduledoc """
  One source system's connection to one domain entity.

  Keyed by `(entity_type, entity_key, source)` — e.g.
  `("vehicle", "CA12345", "Pastel")`. `data` holds the domain *pieces* that
  source provides (its slice of the entity); `raw` keeps the source's raw
  payload. The entity is reconciled from all its source records.
  """

  use Ash.Resource,
    otp_app: :tragar_ai,
    domain: TragarAi.Sources,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "source_records"
    repo TragarAi.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :entity_type, :string,
      allow_nil?: false,
      description: "e.g. \"customer\", \"vehicle\"."

    attribute :entity_key, :string, allow_nil?: false, description: "The entity's natural key."
    attribute :source, :string, allow_nil?: false, description: "Source system name."
    attribute :external_id, :string, description: "The entity's id within that source, if any."

    attribute :data, :map, default: %{}, description: "Domain pieces this source provides."
    attribute :raw, :map, default: %{}, description: "Raw source payload."
    attribute :synced_at, :utc_datetime_usec

    timestamps()
  end

  identities do
    identity :unique_link, [:entity_type, :entity_key, :source]
  end

  actions do
    defaults [:read, :destroy]

    read :for_entity do
      argument :entity_type, :string, allow_nil?: false
      argument :entity_key, :string, allow_nil?: false
      filter expr(entity_type == ^arg(:entity_type) and entity_key == ^arg(:entity_key))
    end

    create :upsert do
      accept [:entity_type, :entity_key, :source, :external_id, :data, :raw, :synced_at]
      upsert? true
      upsert_identity :unique_link
    end
  end
end
