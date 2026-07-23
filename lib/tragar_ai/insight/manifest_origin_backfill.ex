defmodule TragarAi.Insight.ManifestOriginBackfill do
  @moduledoc """
  Materialises each waybill's delivery-manifest origin into `insight_manifest_origin`.

  The waybill has NO direct manifest/tripsheet reference (confirmed via schema), so
  the only link is through the FreightWare parcel tables, which is a slow unindexed
  scan — impossible to run live per Fill-form click. We run it ONCE here, offline,
  starting from the supplier's tripsheets (the small side) → parcels → waybill, and
  store the collection depot (tripsheet station) site + address plus the fields a
  quick quote needs (consignee + weight + actual FRA). The /_inspect quote form then
  reads this table from Postgres and fills instantly.

  Bounded to a recent window (@days) to keep the one-off scan tractable; widen later
  if needed. Read-only against the replica; writes stay on-box.
  """

  require Logger

  alias TragarAi.Insight.Db
  alias TragarAi.Repo

  # Resolve PER SUPPLIER (each supplier's tripsheets are a small set) with TOP 50 —
  # the all-suppliers scan times out even offline. Scoped to the test suppliers for
  # now; widen the list once the quote proves out.
  @suppliers ~w(JX002 ITT001 FPD001 GAV001)
  @days 90
  @per_query_timeout 300_000

  @spec refresh([String.t()]) :: {:ok, map()} | {:error, term()}
  def refresh(suppliers \\ @suppliers) do
    cutoff = Date.utc_today() |> Date.add(-@days) |> Date.to_iso8601()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {rows, skipped} =
      Enum.reduce(suppliers, {[], []}, fn ref, {acc, skip} ->
        case Db.query_rows(sql(ref, cutoff), timeout: @per_query_timeout) do
          {:ok, rs} ->
            Logger.info("[insight.manifest_origin] #{ref}: #{length(rs)} rows")
            {rs ++ acc, skip}

          {:error, reason} ->
            Logger.error("[insight.manifest_origin] #{ref}: #{inspect(reason)}")
            {acc, [ref | skip]}
        end
      end)

    maps =
      rows
      |> Enum.uniq_by(&Map.get(&1, "waybill_number"))
      |> Enum.reject(&(Map.get(&1, "waybill_number") in [nil, ""]))
      |> Enum.map(&to_map(&1, now))

    Repo.transaction(fn ->
      Repo.delete_all("insight_manifest_origin")

      maps
      |> Enum.chunk_every(1000)
      |> Enum.each(&Repo.insert_all("insight_manifest_origin", &1))
    end)

    {:ok, %{rows: length(maps), suppliers: suppliers, skipped: skipped}}
  end

  defp to_map(r, now) do
    %{
      waybill_number: r["waybill_number"],
      contractor_reference: r["contractor_reference"],
      origin_site: r["origin_site"],
      origin_suburb: r["origin_suburb"],
      origin_city: r["origin_city"],
      origin_postcode: r["origin_postcode"],
      consignee_suburb: r["consignee_suburb"],
      consignee_city: r["consignee_city"],
      consignee_postcode: r["consignee_postcode"],
      weight: dec(r["weight"]),
      actual_fra: dec(r["actual_fra"]),
      inserted_at: now,
      updated_at: now
    }
  end

  defp dec(v) when v in [nil, ""], do: nil

  defp dec(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, _} -> d
      :error -> nil
    end
  end

  defp dec(_), do: nil

  # Start from the supplier's tripsheets (small set) so we read parcels by the
  # indexed waybill_parcel_obj rather than scanning by waybill_obj. Origin = the
  # tripsheet station; destination + weight + FRA come off the waybill/charge.
  defp sql(ref, cutoff) do
    """
    SELECT TOP 50 w.waybill_number, sc.contractor_reference, \
    osite.site_reference AS origin_site, \
    st.physical_address_suburb AS origin_suburb, \
    st.physical_address_city AS origin_city, \
    opc.post_code AS origin_postcode, \
    w.consignee_suburb, w.consignee_city, pcd.post_code AS consignee_postcode, \
    w.chargable_units AS weight, cc.charge_amount AS actual_fra \
    FROM PUB.fwt_tripsheet ts \
    JOIN PUB.fwm_station_contractor sc ON sc.station_contractor_obj = ts.station_contractor_obj \
    JOIN PUB.fwm_station st ON st.station_obj = ts.station_obj \
    LEFT JOIN PUB.fwm_site osite ON osite.station_obj = ts.station_obj \
    JOIN PUB.fwm_postcode opc ON opc.postcode_obj = st.physical_address_postcode_obj \
    JOIN PUB.fwc_rate_area_postcode rap ON rap.postcode_obj = st.physical_address_postcode_obj \
    AND rap.owning_entity_mnemonic = 'FWMSC' AND rap.owning_obj = sc.station_contractor_obj \
    JOIN PUB.fwt_parcel_tripsheet pt ON pt.tripsheet_obj = ts.tripsheet_obj \
    JOIN PUB.fwt_waybill_parcel wp ON wp.waybill_parcel_obj = pt.waybill_parcel_obj \
    JOIN PUB.fwt_waybill w ON w.waybill_obj = wp.waybill_obj \
    JOIN PUB.fwt_contractor_charge cc ON cc.waybill_obj = w.waybill_obj \
    AND cc.charge_type_tla = 'FRA' AND cc.station_contractor_obj = sc.station_contractor_obj \
    JOIN PUB.fwm_postcode pcd ON pcd.postcode_obj = w.consignee_postcode_obj \
    WHERE sc.contractor_reference = '#{ref}' AND w.waybill_date >= '#{cutoff}' \
    AND w.chargable_units > 0 AND w.consignee_suburb <> '' \
    AND EXISTS (SELECT 1 FROM PUB.fwm_entity_rate er \
    WHERE er.owning_entity_mnemonic = 'FWMSC' AND er.owning_obj = sc.station_contractor_obj \
    AND er.from_rate_area_obj = rap.rate_area_obj)
    """
  end
end
