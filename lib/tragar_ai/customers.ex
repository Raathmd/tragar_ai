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

  @doc """
  Merge a source's contribution into the customer keyed by `account_reference`.

  A customer exists across systems (FreightWare account, Pastel debtor, Freshdesk
  contact, …). Each source contributes via this function: its name is unioned
  into `sources`, its raw payload is stored under `source_data[source]`, and its
  domain `fields` fill/refresh the record **without** clobbering existing values
  with blanks or wiping other sources. Returns `{:ok, customer}`.
  """
  def contribute(account_reference, source, payload, fields \\ %{}) do
    existing =
      case get_customer(account_reference) do
        {:ok, %{} = c} -> c
        _ -> nil
      end

    attrs =
      existing
      |> domain_fields()
      |> Map.merge(drop_blanks(fields))
      |> Map.merge(%{
        account_reference: account_reference,
        sources: Enum.uniq(sources_of(existing) ++ [source]),
        source_data: Map.put(source_data_of(existing), source, payload),
        cached_at: DateTime.utc_now()
      })

    upsert_customer(attrs)
  end

  defp domain_fields(nil), do: %{}

  defp domain_fields(c),
    do: drop_blanks(%{name: c.name, email: c.email, description: c.description})

  defp sources_of(nil), do: []
  defp sources_of(c), do: c.sources || []
  defp source_data_of(nil), do: %{}
  defp source_data_of(c), do: c.source_data || %{}

  defp drop_blanks(map),
    do: for({k, v} <- map, not is_nil(v) and v != "", into: %{}, do: {k, v})
end
