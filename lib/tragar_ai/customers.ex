defmodule TragarAi.Customers do
  @moduledoc """
  Customers domain — `Customer` records in Tragar's domain shape. Today sourced
  from FreightWare accounts; Freshdesk contacts and Pastel can contribute via
  their adapters (recorded in `sources`/`source_data`). Cached read-through by
  `TragarAi.Customers.Cache`.
  """

  use Ash.Domain, otp_app: :tragar_ai, extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource TragarAi.Customers.Customer do
      define :upsert_customer, action: :upsert
      define :get_customer, action: :read, get_by: [:account_reference]
      define :list_customers, action: :read
    end
  end

  @entity_type "customer"

  @doc """
  Record a source's contribution to the customer keyed by `account_reference`,
  then re-harmonize. `fields` are the domain pieces this source provides;
  `opts` may include `:raw` (raw payload) and `:external_id`. A customer exists
  across systems (FreightWare account, Pastel debtor, Freshdesk contact, …) —
  each is its own `SourceRecord` and none overrides another. Returns `{:ok, customer}`.
  """
  def contribute(account_reference, source, fields, opts \\ []) do
    {:ok, _} =
      TragarAi.Sources.put_source_record(%{
        entity_type: @entity_type,
        entity_key: account_reference,
        source: source,
        external_id: opts[:external_id],
        data: stringify(fields),
        raw: opts[:raw] || %{},
        synced_at: DateTime.utc_now()
      })

    reproject(account_reference)
  end

  defp reproject(account_reference) do
    {:ok, records} = TragarAi.Sources.source_records_for(@entity_type, account_reference)
    %{fields: f, sources: sources} = TragarAi.Harmonize.project(records)

    upsert_customer(%{
      account_reference: account_reference,
      name: f["name"],
      email: f["email"],
      description: f["description"],
      sources: sources,
      cached_at: DateTime.utc_now()
    })
  end

  defp stringify(map),
    do: for({k, v} <- map, into: %{}, do: {to_string(k), v})
end
