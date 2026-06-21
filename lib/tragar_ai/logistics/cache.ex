defmodule TragarAi.Logistics.Cache do
  @moduledoc """
  Read-through cache over FreightWare reads, backed by the `Shipment` and
  `Quote` Ash resources.

  On a query: return the cached row if it's fresh (within the TTL); otherwise
  fetch live via `TragarAi.Freight`, upsert the resource, and return. If the
  live call fails but a (stale) row exists, the stale row is returned so the
  assist tool degrades gracefully rather than erroring.
  """

  alias TragarAi.Freight
  alias TragarAi.Logistics

  require Logger

  defp ttl_minutes do
    :tragar_ai
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:ttl_minutes, 15)
  end

  # ── Shipments ───────────────────────────────────────────────────────────────

  @doc "Read-through fetch of a waybill. Returns %{\"waybill\" => map, \"events\" => list}."
  def fetch_shipment(waybill) do
    cached = cached_shipment(waybill)

    if cached && fresh?(cached.cached_at) do
      {:ok, shipment_view(cached)}
    else
      case fetch_live_shipment(waybill) do
        {:ok, view} -> {:ok, view}
        {:error, reason} -> stale_or_error(cached, &shipment_view/1, reason)
      end
    end
  end

  defp fetch_live_shipment(waybill) do
    with {:ok, wb} when is_map(wb) <- Freight.get_waybill(waybill),
         {:ok, events} <- Freight.track_and_trace(:waybills, waybill) do
      upsert_shipment(waybill, wb, events)
      {:ok, %{"waybill" => wb, "events" => events}}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp upsert_shipment(waybill, wb, events) do
    Logistics.upsert_shipment(%{
      waybill_number: wb["waybill_number"] || waybill,
      account_reference: wb["account_reference"],
      shipper_reference: wb["shipper_reference"],
      service_type: wb["service_type"],
      status_code: wb["status_code"],
      status_description: wb["status_description"],
      consignor_name: wb["consignor_name"],
      consignee_name: wb["consignee_name"],
      consignee_city: wb["consignee_city"],
      tracking_events: events,
      pod: pod_from(events, wb),
      raw: wb,
      cached_at: DateTime.utc_now()
    })
  rescue
    e -> Logger.warning("Failed to cache shipment #{waybill}: #{Exception.message(e)}")
  end

  defp cached_shipment(waybill) do
    case Logistics.get_shipment_by_waybill(waybill) do
      {:ok, %{} = s} -> s
      _ -> nil
    end
  end

  defp shipment_view(s), do: %{"waybill" => s.raw, "events" => s.tracking_events || []}

  defp pod_from(events, wb) do
    case Enum.find_value(events, & &1["pod"]) do
      pod when is_map(pod) -> pod
      _ -> if wb["pod_image_url"], do: %{"image_url" => wb["pod_image_url"]}, else: nil
    end
  end

  # ── Quotes ──────────────────────────────────────────────────────────────────

  @doc "Read-through fetch of a quote. Returns the normalized quote map."
  def fetch_quote(quote_id) do
    cached = cached_quote(quote_id)

    if cached && fresh?(cached.cached_at) do
      {:ok, cached.raw}
    else
      case fetch_live_quote(quote_id) do
        {:ok, quote} -> {:ok, quote}
        {:error, reason} -> stale_or_error(cached, & &1.raw, reason)
      end
    end
  end

  defp fetch_live_quote(quote_id) do
    with {:ok, quote} when is_map(quote) <- Freight.get_quote(quote_id) do
      upsert_quote(quote)
      {:ok, quote}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp upsert_quote(q) do
    Logistics.upsert_quote(%{
      quote_number: q["quote_number"],
      quote_obj: q["quote_obj"],
      account_reference: q["account_reference"],
      service_type: q["service_type"],
      status_code: q["status_code"],
      status_description: q["status_description"],
      consignor_name: q["consignor_name"],
      consignee_name: q["consignee_name"],
      charged_amount: to_string_or_nil(q["charged_amount"]),
      items: q["items"] || [],
      sundries: q["sundries"] || [],
      raw: q,
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

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp fresh?(nil), do: false

  defp fresh?(%DateTime{} = at),
    do: DateTime.diff(DateTime.utc_now(), at, :minute) < ttl_minutes()

  defp stale_or_error(nil, _view_fun, reason), do: {:error, reason}
  defp stale_or_error(cached, view_fun, _reason), do: {:ok, view_fun.(cached)}

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(v), do: to_string(v)
end
