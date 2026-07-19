defmodule TragarAi.Insight.RateEngine do
  @moduledoc """
  Expected 3rd-party delivery cost from the live FreightWare rate card (Half 2).

  For an open delivery manifest, ranks the candidate 3rd-party suppliers by what
  each *would* charge to deliver its waybills — the "who's cheapest" comparison.
  It is a comparison of alternatives, not a lookup of the assigned party (many
  manifests run on Tragar's own fleet, which has no rate card).

  The chain, reverse-engineered + validated against the replica. The API's open
  "delivery manifest" is a driver **tripsheet** (`owning_obj` = `tripsheet_obj`),
  and its deliveries are reached through the parcel tables:

      tripsheet (fwt_tripsheet, tripsheet_obj = API owning_obj)
        → its parcels             (fwt_parcel_tripsheet.tripsheet_obj)
        → each parcel's waybill    (fwt_waybill_parcel → fwt_waybill)
        → each destination         (fwt_waybill.consignee_postcode_obj)
        → that supplier's area     (fwc_rate_area_postcode, FWMSC + owning_obj = supplier)
        → that supplier's rate     (fwm_entity_rate, FWMSC, to_rate_area = area, effective)
        → weight band              (fwm_rate_table, from_unit ≤ chargable_units < to_unit)
        → per-waybill expected cost = base_amount + increment_amount ×
                                       ((weight − from_unit) / increment_unit)

  Rates are read LIVE (small, effective-dated, must be current), in-app, per
  manifest on demand — never batched — so a single manifest's handful of waybills
  keeps the query light. The raw rate rows come back from `Insight.Db`; the
  per-waybill formula, latest-effective pick, and summing happen here in Elixir
  (robust, and keeps the SQL a plain SELECT).
  """

  alias TragarAi.Insight.Db

  @doc """
  Rank candidate 3rd-party suppliers for a manifest, keyed by its numeric
  `manifest_obj` (the FreightWare API's `owning_obj`), by total expected cost
  across its waybills, cheapest first. Returns `{:ok, [row]}` where each row is:

      %{supplier_ref, supplier_name, waybills_priced, total_expected}

  `waybills_priced` is how many of the manifest's waybills that supplier can
  cover — a full alternative covers them all; a partial one covers fewer.

  Keyed on `manifest_obj` (not the reference string) because the API's delivery-
  manifest number and `fwt_manifest.manifest_reference` are different identifiers.
  """
  @spec rank_manifest_suppliers(String.t()) ::
          {:ok, %{ranking: [map()], total_waybills: non_neg_integer()}} | {:error, term()}
  def rank_manifest_suppliers(manifest_obj) when is_binary(manifest_obj) do
    with {:ok, obj} <- sanitize_obj(manifest_obj),
         {:ok, rows} <- Db.query_rows(rows_sql(obj)),
         {:ok, total_rows} <- Db.query_rows(total_waybills_sql(obj)) do
      total = total_rows |> List.first(%{}) |> Map.get("total") |> to_int()
      {:ok, %{ranking: rank(rows, total), total_waybills: total}}
    end
  end

  @doc """
  Expected delivery cost **per waybill**, each priced against its OWN assigned
  contractor's rate card — i.e. what the party that actually carried the waybill
  *should* have charged, per the live card. This is the "buy expected" the margin
  report compares against the booked "buy actual".

  `where_sql` is a SQL predicate on the `w` alias of `PUB.fwt_waybill` that
  selects the waybills to price (e.g. `"w.waybill_date = '2026-07-01'"` or a
  month + dimension filter). The caller owns escaping its values — the rate joins
  and formula are fixed here.

  Returns `{:ok, [row]}` with one row per waybill whose assigned contractor has a
  current 3rd-party rate covering its destination:

      %{waybill_obj, waybill_date, account_name, rate_area_to_code,
        contractor_reference, expected}

  Waybills on own-fleet (no rate card) simply don't appear — so at aggregate
  grains the sum is a partial-coverage figure, not a like-for-like total against
  actual. Priced in Elixir (latest-effective pick + formula) exactly like
  `rank_manifest_suppliers/1`, keeping the SQL a plain SELECT.
  """
  @spec assigned_expected(String.t()) :: {:ok, [map()]} | {:error, term()}
  def assigned_expected(where_sql) when is_binary(where_sql) do
    with {:ok, rows} <- Db.query_rows(assigned_rows_sql(where_sql)) do
      priced =
        rows
        |> Enum.group_by(&Map.get(&1, "waybill_obj"))
        |> Enum.map(fn {wb, wb_rows} ->
          # Same waybill can match several effective versions/bands — keep the
          # latest-effective, then price it.
          top = Enum.max_by(wb_rows, &(&1["effective_date"] || ""))

          %{
            waybill_obj: wb,
            waybill_date: top["waybill_date"],
            account_name: top["account_name"],
            rate_area_to_code: top["rate_area_to_code"],
            contractor_reference: top["contractor_reference"],
            expected: top |> waybill_cost() |> Float.round(2)
          }
        end)

      {:ok, priced}
    end
  end

  # --- ranking ------------------------------------------------------------

  defp rank(rows, total) do
    rows
    |> Enum.group_by(&Map.get(&1, "supplier_ref"))
    |> Enum.map(fn {ref, supplier_rows} ->
      # Per waybill, keep only the latest-effective rate version, then price it.
      waybill_costs =
        supplier_rows
        |> Enum.group_by(&Map.get(&1, "waybill_obj"))
        |> Enum.map(fn {_wb, wb_rows} ->
          wb_rows |> Enum.max_by(&(&1["effective_date"] || "")) |> waybill_cost()
        end)

      priced = length(waybill_costs)

      %{
        supplier_ref: ref,
        supplier_name: supplier_rows |> hd() |> Map.get("supplier_name"),
        waybills_priced: priced,
        total_waybills: total,
        full_coverage: total > 0 and priced == total,
        total_expected: waybill_costs |> Enum.sum() |> Float.round(2)
      }
    end)
    # Full-coverage suppliers first (a real alternative), then cheapest.
    |> Enum.sort_by(fn s -> {not s.full_coverage, s.total_expected} end)
  end

  # base + increment × ((weight − from) / increment_unit); flat when increment_unit = 0.
  defp waybill_cost(row) do
    base = num(row["base_amount"])
    increment = num(row["increment_amount"])
    increment_unit = num(row["increment_unit"])
    from_unit = num(row["from_unit"])
    weight = num(row["chargable_units"])

    if increment_unit > 0.0,
      do: base + increment * ((weight - from_unit) / increment_unit),
      else: base
  end

  defp num(nil), do: 0.0

  defp num(str) when is_binary(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  # --- query --------------------------------------------------------------

  # Raw per-(waybill, supplier, effective-version, band) rows for one tripsheet
  # (the API delivery manifest). Kept a plain SELECT; the Elixir side dedups and
  # prices. A tripsheet's waybills come via its parcels; the same waybill can be
  # on several parcels, so the Elixir grouping by waybill_obj dedups it. `obj` is
  # a bare integer (validated by sanitize_obj), compared to numeric tripsheet_obj.
  defp rows_sql(obj) do
    today = Date.utc_today() |> Date.to_iso8601()

    """
    SELECT c.contractor_reference AS supplier_ref, c.contractor_name AS supplier_name, \
    w.waybill_obj, w.chargable_units, er.effective_date, rt.from_unit, rt.base_amount, \
    rt.increment_amount, rt.increment_unit \
    FROM PUB.fwt_parcel_tripsheet pt \
    JOIN PUB.fwt_waybill_parcel wp ON wp.waybill_parcel_obj = pt.waybill_parcel_obj \
    JOIN PUB.fwt_waybill w ON w.waybill_obj = wp.waybill_obj \
    JOIN PUB.fwc_rate_area_postcode pc ON pc.postcode_obj = w.consignee_postcode_obj \
    AND pc.owning_entity_mnemonic = 'FWMSC' \
    JOIN PUB.fwm_station_contractor c ON c.station_contractor_obj = pc.owning_obj \
    JOIN PUB.fwm_entity_rate er ON er.owning_entity_mnemonic = 'FWMSC' \
    AND er.owning_obj = pc.owning_obj AND er.to_rate_area_obj = pc.rate_area_obj \
    AND (er.cease_date IS NULL OR er.cease_date >= '#{today}') \
    JOIN PUB.fwm_rate_table rt ON rt.entity_rate_obj = er.entity_rate_obj \
    AND w.chargable_units >= rt.from_unit AND w.chargable_units < rt.to_unit \
    WHERE pt.tripsheet_obj = #{obj}
    """
  end

  # Raw per-(waybill, effective-version, band) rate rows for the waybills matched
  # by `where_sql`, priced against each waybill's OWN assigned contractor — the
  # rate area/rate is pinned to that contractor via
  # `c.contractor_reference = w.contractor_reference`, so a waybill only prices if
  # the party that carried it has a current 3rd-party card covering its
  # destination. The Elixir side dedups by waybill (latest effective) and prices.
  defp assigned_rows_sql(where_sql) do
    today = Date.utc_today() |> Date.to_iso8601()

    """
    SELECT w.waybill_obj, w.waybill_date, w.account_name, w.rate_area_to_code, \
    w.contractor_reference, w.chargable_units, er.effective_date, rt.from_unit, \
    rt.base_amount, rt.increment_amount, rt.increment_unit \
    FROM PUB.fwt_waybill w \
    JOIN PUB.fwc_rate_area_postcode pc ON pc.postcode_obj = w.consignee_postcode_obj \
    AND pc.owning_entity_mnemonic = 'FWMSC' \
    JOIN PUB.fwm_station_contractor c ON c.station_contractor_obj = pc.owning_obj \
    AND c.contractor_reference = w.contractor_reference \
    JOIN PUB.fwm_entity_rate er ON er.owning_entity_mnemonic = 'FWMSC' \
    AND er.owning_obj = pc.owning_obj AND er.to_rate_area_obj = pc.rate_area_obj \
    AND (er.cease_date IS NULL OR er.cease_date >= '#{today}') \
    JOIN PUB.fwm_rate_table rt ON rt.entity_rate_obj = er.entity_rate_obj \
    AND w.chargable_units >= rt.from_unit AND w.chargable_units < rt.to_unit \
    WHERE #{where_sql}
    """
  end

  # Total distinct waybills on the tripsheet (the coverage denominator) — used to
  # tell full-coverage alternatives from partial ones.
  defp total_waybills_sql(obj) do
    "SELECT COUNT(DISTINCT wp.waybill_obj) AS total " <>
      "FROM PUB.fwt_parcel_tripsheet pt " <>
      "JOIN PUB.fwt_waybill_parcel wp ON wp.waybill_parcel_obj = pt.waybill_parcel_obj " <>
      "WHERE pt.tripsheet_obj = #{obj}"
  end

  # `owning_obj` comes from the API as a number (sometimes "12345.0"); take the
  # integer part and allow digits only, so it's a safe bare numeric literal.
  defp sanitize_obj(obj) do
    digits = obj |> to_string() |> String.trim() |> String.split(".") |> List.first()

    if String.match?(digits, ~r/^[0-9]{1,20}$/),
      do: {:ok, digits},
      else: {:error, :invalid_manifest_obj}
  end

  defp to_int(nil), do: 0
  defp to_int(n) when is_integer(n), do: n

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> 0
    end
  end
end
