defmodule TragarAi.Sources do
  @moduledoc """
  Sources domain — the link between a source system and a domain entity.

  Each `SourceRecord` is one source's connection to one entity (e.g. Pastel's
  view of vehicle "CA12345"), holding the pieces that source provides plus its
  raw payload. A domain entity (Customer, Vehicle, …) is the **harmonized
  projection** of all its source records (`TragarAi.Harmonize`), so systems are
  reconciled into one record without any source overriding another.
  """

  use Ash.Domain, otp_app: :tragar_ai, extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource TragarAi.Sources.SourceRecord do
      define :put_source_record, action: :upsert
      define :source_records_for, action: :for_entity, args: [:entity_type, :entity_key]
      define :list_source_records, action: :read
    end
  end
end
