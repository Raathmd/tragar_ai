defmodule TragarAi.Support.Cache do
  @moduledoc """
  Read-through cache over the `Ticket` domain resource, fed from Freshdesk.
  Fresh-TTL hit → cached; else fetch live, map to domain, upsert with provenance.
  """

  alias TragarAi.Freshdesk.Client
  alias TragarAi.Support

  require Logger

  @source "Freshdesk"

  defp ttl_minutes do
    :tragar_ai
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:ttl_minutes, 15)
  end

  @doc "Read-through fetch of a ticket by id. Returns the domain ticket map."
  def ticket(id) do
    cached = cached_ticket(id)

    if cached && fresh?(cached.cached_at) do
      {:ok, domain(cached)}
    else
      case fetch_live(id) do
        {:ok, domain} -> {:ok, domain}
        {:error, reason} -> stale_or_error(cached, reason)
      end
    end
  end

  defp fetch_live(id) do
    with {:ok, ticket} when is_map(ticket) <- Client.get_ticket(id) do
      domain = map_ticket(ticket)
      upsert(domain, ticket)
      {:ok, domain}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp map_ticket(t) do
    %{
      "ticket_id" => to_string(t["id"]),
      "subject" => t["subject"],
      "status" => to_string_or_nil(t["status"]),
      "priority" => to_string_or_nil(t["priority"]),
      "requester_email" => t["email"],
      "updated_at" => t["updated_at"]
    }
    |> compact()
  end

  defp upsert(domain, raw) do
    Support.upsert_ticket(%{
      ticket_id: domain["ticket_id"],
      subject: domain["subject"],
      status: domain["status"],
      priority: domain["priority"],
      requester_email: domain["requester_email"],
      updated_at_source: domain["updated_at"],
      sources: [@source],
      source_data: %{@source => raw},
      cached_at: DateTime.utc_now()
    })
  rescue
    e -> Logger.warning("Failed to cache ticket: #{Exception.message(e)}")
  end

  defp cached_ticket(id) do
    case Support.get_ticket(to_string(id)) do
      {:ok, %{} = t} -> t
      _ -> nil
    end
  end

  defp domain(t) do
    %{
      "ticket_id" => t.ticket_id,
      "subject" => t.subject,
      "status" => t.status,
      "priority" => t.priority,
      "requester_email" => t.requester_email,
      "updated_at" => t.updated_at_source
    }
    |> compact()
  end

  defp fresh?(nil), do: false

  defp fresh?(%DateTime{} = at),
    do: DateTime.diff(DateTime.utc_now(), at, :minute) < ttl_minutes()

  defp stale_or_error(nil, reason), do: {:error, reason}
  defp stale_or_error(cached, _reason), do: {:ok, domain(cached)}

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(v), do: to_string(v)

  defp compact(map), do: for({k, v} <- map, v != nil and v != "", into: %{}, do: {k, v})
end
