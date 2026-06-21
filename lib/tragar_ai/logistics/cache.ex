defmodule TragarAi.Logistics.Cache do
  @moduledoc """
  Read-through cache over the domain `Shipment` and `Quote` resources.

  Returns the cached row if fresh (within the TTL); otherwise fetches live via
  `TragarAi.Freight`, maps it into the domain shape
  (`TragarAi.Adapters.FreightWare.Mapper`), upserts the resource with provenance,
  and returns the domain entity. If the live call fails but a stale row exists,
  the stale row is returned so the assist tool degrades gracefully.

  The returned value is the **domain entity** (a map), not a source payload.
  """

  alias TragarAi.Adapters.FreightWare.Mapper
  alias TragarAi.Freight
  alias TragarAi.Logistics

  require Logger

  @source "FreightWare"

  defp ttl_minutes do
    :tragar_ai
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:ttl_minutes, 15)
  end

  # ── Shipments ───────────────────────────────────────────────────────────────

  @doc "Read-through fetch of a shipment by waybill. Returns the domain shipment map."
  def shipment(waybill) do
    cached = cached_shipment(waybill)

    if cached && fresh?(cached.cached_at) do
      {:ok, shipment_domain(cached)}
    else
      case fetch_live_shipment(waybill) do
        {:ok, domain} -> {:ok, domain}
        {:error, reason} -> stale_or_error(cached, &shipment_domain/1, reason)
      end
    end
  end

  defp fetch_live_shipment(waybill) do
    with {:ok, wb} when is_map(wb) <- Freight.get_waybill(waybill),
         {:ok, events} <- Freight.track_and_trace(:waybills, waybill) do
      domain = Mapper.shipment(wb, events)
      upsert_shipment(domain, %{"waybill" => wb, "tracking" => events})
      {:ok, domain}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp upsert_shipment(domain, raw) do
    Logistics.upsert_shipment(%{
      waybill_number: domain["waybill_number"],
      account_reference: domain["account_reference"],
      status: domain["status"],
      status_code: domain["status_code"],
      service_type: domain["service_type"],
      consignor: domain["consignor"],
      consignee: domain["consignee"],
      consignee_city: domain["consignee_city"],
      events: domain["events"] || [],
      pod: domain["pod"],
      sources: [@source],
      source_data: %{@source => raw},
      cached_at: DateTime.utc_now()
    })
  rescue
    e -> Logger.warning("Failed to cache shipment: #{Exception.message(e)}")
  end

  defp cached_shipment(waybill) do
    case Logistics.get_shipment_by_waybill(waybill) do
      {:ok, %{} = s} -> s
      _ -> nil
    end
  end

  defp shipment_domain(s) do
    %{
      "waybill_number" => s.waybill_number,
      "account_reference" => s.account_reference,
      "status" => s.status,
      "status_code" => s.status_code,
      "service_type" => s.service_type,
      "consignor" => s.consignor,
      "consignee" => s.consignee,
      "consignee_city" => s.consignee_city,
      "events" => s.events || [],
      "pod" => s.pod
    }
    |> compact()
  end

  # ── Quotes ──────────────────────────────────────────────────────────────────

  @doc "Read-through fetch of a quote. Returns the domain quote map."
  def quote(quote_id) do
    cached = cached_quote(quote_id)

    if cached && fresh?(cached.cached_at) do
      {:ok, quote_domain(cached)}
    else
      case fetch_live_quote(quote_id) do
        {:ok, domain} -> {:ok, domain}
        {:error, reason} -> stale_or_error(cached, &quote_domain/1, reason)
      end
    end
  end

  defp fetch_live_quote(quote_id) do
    with {:ok, q} when is_map(q) <- Freight.get_quote(quote_id) do
      domain = Mapper.quote(q)
      upsert_quote(domain, q)
      {:ok, domain}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp upsert_quote(domain, raw) do
    Logistics.upsert_quote(%{
      quote_number: domain["quote_number"],
      quote_obj: domain["quote_obj"],
      account_reference: domain["account_reference"],
      status: domain["status"],
      status_code: domain["status_code"],
      service_type: domain["service_type"],
      consignor: domain["consignor"],
      consignee: domain["consignee"],
      charged_amount: to_string_or_nil(domain["charged_amount"]),
      items: domain["items"] || [],
      sundries: domain["sundries"] || [],
      sources: [@source],
      source_data: %{@source => raw},
      cached_at: DateTime.utc_now()
    })
  rescue
    e -> Logger.warning("Failed to cache quote: #{Exception.message(e)}")
  end

  defp cached_quote(quote_id) do
    case Logistics.get_quote_by_number(quote_id) do
      {:ok, %{} = q} -> q
      _ -> nil
    end
  end

  defp quote_domain(q) do
    %{
      "quote_number" => q.quote_number,
      "quote_obj" => q.quote_obj,
      "account_reference" => q.account_reference,
      "status" => q.status,
      "status_code" => q.status_code,
      "service_type" => q.service_type,
      "consignor" => q.consignor,
      "consignee" => q.consignee,
      "charged_amount" => q.charged_amount,
      "items" => q.items || [],
      "sundries" => q.sundries || []
    }
    |> compact()
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp fresh?(nil), do: false

  defp fresh?(%DateTime{} = at),
    do: DateTime.diff(DateTime.utc_now(), at, :minute) < ttl_minutes()

  defp stale_or_error(nil, _fun, reason), do: {:error, reason}
  defp stale_or_error(cached, fun, _reason), do: {:ok, fun.(cached)}

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(v), do: to_string(v)

  defp compact(map), do: for({k, v} <- map, v != nil and v != "", into: %{}, do: {k, v})
end
