defmodule TragarAi.Logistics.Cache do
  @moduledoc """
  Read-through cache over FreightWare shipment data, account-scoped.

  Customer queries read from Elixir's `Shipment` cache, **not** FreightWare
  directly:

    * **Cache hit** — return the stored normalized view, but only if the cached
      shipment belongs to the caller's account; otherwise `:not_found`.
    * **Cache miss** — fetch *that one* waybill from FreightWare, verify it
      belongs to the caller's account (else `:not_found`, so we never leak other
      accounts' shipments), upsert it into the cache, and return it.

  A background job (`TragarAi.Logistics.SyncWorker`) keeps the cache warm for all
  registered accounts, so most reads are hits.
  """

  alias TragarAi.Dovetail
  alias TragarAi.Logistics
  alias TragarAi.Tools.Normalize

  require Logger

  @doc """
  Fetch a single shipment view for `waybill_number`, scoped to
  `account_reference`. Returns `{:ok, view}` or `{:error, :not_found}` /
  `{:error, reason}`.
  """
  @spec fetch(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(waybill_number, account_reference) do
    case Logistics.get_shipment_by_waybill(waybill_number) do
      {:ok, %{} = shipment} ->
        if owns?(shipment.account_reference, account_reference) do
          {:ok, view(shipment)}
        else
          {:error, :not_found}
        end

      _miss ->
        fetch_live(waybill_number, account_reference)
    end
  end

  @doc "List all cached shipment views for an account."
  @spec list(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(account_reference) do
    case Logistics.list_shipments_for_account(account_reference) do
      {:ok, shipments} -> {:ok, Enum.map(shipments, &view/1)}
      error -> error
    end
  end

  @doc """
  Fetch a waybill from FreightWare and upsert it into the cache, regardless of
  account. Used by the background sync job (which already scopes by account
  upstream). Returns `{:ok, shipment}` or `{:error, reason}`.
  """
  @spec refresh(String.t()) :: {:ok, Ash.Resource.record()} | {:error, term()}
  def refresh(waybill_number) do
    with {:ok, waybill} <- Dovetail.Client.get_waybill(waybill_number),
         {:ok, tracking} <- Dovetail.Client.track_and_trace(:waybills, waybill_number) do
      view = Normalize.shipment(waybill_number, waybill, tracking)
      upsert(view, waybill)
    end
  end

  # ── Internal ──────────────────────────────────────────────────────────────

  defp fetch_live(waybill_number, account_reference) do
    with {:ok, waybill} <- Dovetail.Client.get_waybill(waybill_number),
         {:ok, tracking} <- Dovetail.Client.track_and_trace(:waybills, waybill_number) do
      view = Normalize.shipment(waybill_number, waybill, tracking)

      if owns?(view["account_reference"], account_reference) do
        _ = upsert(view, waybill)
        {:ok, view}
      else
        {:error, :not_found}
      end
    end
  end

  defp upsert(view, raw) do
    Logistics.upsert_shipment(%{
      waybill_number: view["waybill_number"],
      account_reference: view["account_reference"],
      service_type: view["service_type"],
      status_code: view["status_code"],
      status_description: view["status"],
      consignor_name: view["consignor"],
      consignee_name: view["consignee"],
      tracking_events: view["events"] || [],
      raw: raw,
      view: view,
      tracked_at: DateTime.utc_now()
    })
  end

  # The stored view is authoritative for cache hits; fall back to reconstructing
  # from columns for rows written before `view` existed.
  defp view(%{view: view}) when is_map(view) and map_size(view) > 0, do: view

  defp view(shipment) do
    %{
      "waybill_number" => shipment.waybill_number,
      "status" => shipment.status_description,
      "status_code" => shipment.status_code,
      "account_reference" => shipment.account_reference,
      "service_type" => shipment.service_type,
      "consignor" => shipment.consignor_name,
      "consignee" => shipment.consignee_name,
      "events" => shipment.tracking_events || []
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp owns?(nil, _account_reference), do: false
  defp owns?(_shipment_ref, nil), do: false
  defp owns?(shipment_ref, account_reference), do: shipment_ref == account_reference
end
