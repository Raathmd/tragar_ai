defmodule TragarAi.Customers.Cache do
  @moduledoc """
  Read-through cache over the `Customer` domain resource, fed from FreightWare
  accounts base data. Fresh-TTL hit → cached; else fetch the account list, find
  the reference, map to domain, upsert with provenance.
  """

  alias TragarAi.Customers
  alias TragarAi.Freight

  @source "FreightWare"

  defp ttl_minutes do
    :tragar_ai
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:ttl_minutes, 60)
  end

  @doc "Read-through fetch of a customer by account reference. Returns the domain map."
  def customer(account_reference) do
    cached = cached_customer(account_reference)

    if cached && fresh?(cached.cached_at) do
      {:ok, domain(cached)}
    else
      case fetch_live(account_reference) do
        {:ok, domain} -> {:ok, domain}
        {:error, reason} -> stale_or_error(cached, reason)
      end
    end
  end

  defp fetch_live(account_reference) do
    with {:ok, accounts} <- Freight.accounts(),
         account when is_map(account) <-
           Enum.find(accounts, &(&1["account_reference"] == account_reference)) do
      # Contribute FreightWare's slice; merges with any other source already present.
      {:ok, customer} =
        Customers.contribute(account_reference, @source, account, %{
          name: account["account_name"],
          description: account["account_description"]
        })

      {:ok, domain(customer)}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp cached_customer(ref) do
    case Customers.get_customer(ref) do
      {:ok, %{} = c} -> c
      _ -> nil
    end
  end

  defp domain(c) do
    %{
      "account_reference" => c.account_reference,
      "name" => c.name,
      "email" => c.email,
      "description" => c.description
    }
    |> compact()
  end

  defp fresh?(nil), do: false

  defp fresh?(%DateTime{} = at),
    do: DateTime.diff(DateTime.utc_now(), at, :minute) < ttl_minutes()

  defp stale_or_error(nil, reason), do: {:error, reason}
  defp stale_or_error(cached, _reason), do: {:ok, domain(cached)}

  defp compact(map), do: for({k, v} <- map, v != nil and v != "", into: %{}, do: {k, v})
end
