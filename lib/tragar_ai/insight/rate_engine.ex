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
        → that supplier's to-area  (fwc_rate_area_postcode, FWMSC + owning_obj = supplier)
        → the origin depot         (manifestBranch = fwm_station.station_code)
        → that depot's postcode    (fwm_station.physical_address_postcode_obj)
        → that supplier's from-area (fwc_rate_area_postcode, same supplier, origin postcode)
        → the supplier's buy service (fwm_contractor_service_type, station_contractor_obj =
                                    supplier, company_service_type_obj = waybill.service_type_obj,
                                    map effective_date ≤ waybill_date → cst.service_type_obj)
        → that supplier's rate     (fwm_entity_rate, FWMSC, service_type_obj + rate_type_obj =
                                    cst.*, from_rate_area + to_rate_area, effective_date ≤ waybill_date
                                    ≤ cease_date, excluding bidirectional mirror rows)
        → weight band              (fwm_rate_table, from_unit ≤ chargable_units < to_unit)

  SERVICE MAPPING (resolved 2026-07-22): the buy-rate's service_type_obj is deliberately
  DIFFERENT from the waybill's — a booked sell service maps to the supplier's own buy
  service, per-subcontractor and effective-dated, via fwm_contractor_service_type
  (company_service_type_obj → service_type_obj, and its rate_type_obj). Confirmed on
  waybill 1198849517: sell service 36836 → buy service 44693 → correct rate R108.29 (was
  fanning out to R73M when unpinned). This is the DB table behind the
  /subcontractors/{ref}/ServiceTypes API, so the pin stays a plain replica join. A
  waybill whose service has no mapping for its delivery supplier prices nothing here
  (uncosted in the drill — never dropped).

  RATE DE-DUP (2026-07-22): a lane+supplier+service+effective still carries several
  fwm_entity_rate rows. Expected cost must resolve to EXACTLY ONE rate — never a sum,
  never an arbitrary pick, never zero when a rate exists. So `rate_sort_key` imposes a
  TOTAL order and `max_by` takes the single winner. Only real determinants are hard
  filters: `rate_type_obj` = the mapping's cst.rate_type_obj. Everything else is a
  PREFERENCE in the sort key (candidate never dropped, so we never zero a priced lane):
  (a) generic `account_product_obj` = 0 preferred — product-specific rates are 0.6%
  (26/4682), consignment_type never set; per-line product override
  (fwt_waybill_line_product) is a follow-up. (b) canonical preferred over its generated
  reverse-mirror (bidirectional_entity_rate_obj = 0) — but the mirror stays a candidate
  so a lane stored only as the reverse still prices. (c) highest entity_rate_obj is the
  unique final tie-break guaranteeing determinism for a genuine duplicate.
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

  `station_code` is the manifest's owning branch (the API's `manifestBranch`,
  = `fwm_station.station_code`) — the depot the goods ship from. It pins the
  origin (`from`) rate area, so a supplier is priced on the actual depot lane.
  Origin is pinned via a LEFT join, so a candidate supplier that services the
  destination but has **no rate for that origin area** is never dropped: it ranks
  LAST with `total_expected: nil` ("rate could not be determined"). A missing or
  unresolvable branch isn't an error either — origin simply can't be pinned, so
  every candidate surfaces as undetermined.
  """
  @spec rank_manifest_suppliers(String.t(), String.t() | nil) ::
          {:ok, %{ranking: [map()], total_waybills: non_neg_integer()}} | {:error, term()}
  def rank_manifest_suppliers(manifest_obj, station_code \\ nil) when is_binary(manifest_obj) do
    with {:ok, obj} <- sanitize_obj(manifest_obj),
         {:ok, code} <- sanitize_station(station_code),
         {:ok, rows} <- Db.query_rows(rows_sql(obj, code)),
         {:ok, total_rows} <- Db.query_rows(total_waybills_sql(obj)) do
      total = total_rows |> List.first(%{}) |> Map.get("total") |> to_int()
      {:ok, %{ranking: rank(rows, total), total_waybills: total}}
    end
  end

  @doc """
  Expected delivery cost **per waybill**, priced against the waybill's actual
  DELIVERY supplier — the 3rd party pulled from its contractor charges (not the
  often-blank `fwt_waybill.contractor_reference` header), self-selected as the one
  whose rate area covers the consignee postcode. This is the base rate-card "buy
  expected" the margin report shows beside the booked "buy actual".

  `where_sql` is a SQL predicate over the query's aliases — `w` (`PUB.fwt_waybill`)
  and `sc` (`PUB.fwm_station_contractor`, the delivery supplier) — that selects
  the waybills to price (e.g. `"w.waybill_date = '2026-07-01'"`, or a month +
  dimension filter, or `"sc.contractor_reference = 'ITT001'"` for one supplier).
  The caller owns escaping its values — the rate joins and formula are fixed here.

  Returns `{:ok, [row]}` with one row per waybill whose delivery supplier has a
  current 3rd-party rate covering its destination:

      %{waybill_obj, waybill_date, account_name, rate_area_to_code,
        contractor_reference, expected}

  The price is `base rate × (1 + SCFUEL%)` — the base rate card plus the supplier's
  effective-dated fuel surcharge. Destination sundry surcharges (area / township /
  line-haul via `fwm_sundry_postcode`) are NOT yet folded in, and own-fleet legs /
  suppliers without a card don't appear — so at aggregate grains the sum is still a
  partial (base+fuel) figure, not a like-for-like total against actual. Priced in
  Elixir (latest-effective rate band + fuel, clamped) — the SQL stays a plain
  SELECT.
  """
  @spec assigned_expected(String.t()) :: {:ok, [map()]} | {:error, term()}
  def assigned_expected(where_sql) when is_binary(where_sql) do
    with {:ok, rows} <- Db.query_rows(assigned_rows_sql(where_sql)) do
      priced =
        rows
        |> Enum.group_by(&Map.get(&1, "waybill_obj"))
        |> Enum.map(fn {wb, wb_rows} ->
          # Base and fuel version independently: the charge/rate/fuel joins fan
          # out, so pick the correct rate band for the base and the latest-effective
          # SCFUEL % for the multiplier, across the group. Two effective-dated axes,
          # both SQL-bounded to `<= waybill_date`: the service MAPPING version
          # (fwm_contractor_service_type, sell service → this supplier's buy service)
          # and the RATE version. Pick the latest in-force mapping, then the latest
          # in-force rate under it — so a superseded mapping whose newer version has
          # no rate on the lane falls back to the mapping that actually prices.
          base_row = Enum.max_by(wb_rows, &rate_sort_key/1)
          base = waybill_cost(base_row)
          mult = fuel_multiplier(wb_rows)

          %{
            waybill_obj: wb,
            waybill_date: base_row["waybill_date"],
            account_name: base_row["account_name"],
            rate_area_to_code: base_row["rate_area_to_code"],
            contractor_reference: base_row["contractor_reference"],
            expected: Float.round(base * mult, 2),
            # Per-term breakdown for the reconciliation console (every component of
            # the quote exposed, incl. the still-pending sundry term at 0).
            components: %{
              chargable_units: num(base_row["chargable_units"]),
              from_unit: num(base_row["from_unit"]),
              minimum: num(base_row["base_amount"]),
              increment_amount: num(base_row["increment_amount"]),
              increment_unit: num(base_row["increment_unit"]),
              base_subtotal: Float.round(base, 2),
              fuel_percent: Float.round((mult - 1.0) * 100, 2),
              fuel_multiplier: mult,
              sundry: 0.0
            }
          }
        end)

      {:ok, priced}
    end
  end

  # SCFUEL fuel surcharge as a multiplier on the base subtotal: 1 + pct/100, using
  # the waybill supplier's latest-effective percent (LEFT JOIN, so no fuel row →
  # ×1.0). Clamped to a sane band — fwm_charge carries junk config percents
  # (-9 to 313) that would otherwise blow up a supplier's expected cost.
  @fuel_pct_min 0.0
  @fuel_pct_max 50.0
  defp fuel_multiplier(wb_rows) do
    pct =
      wb_rows
      |> Enum.reject(&(&1["fuel_percent"] in [nil, ""]))
      |> latest_fuel_pct()

    1.0 + max(@fuel_pct_min, min(pct, @fuel_pct_max)) / 100.0
  end

  defp latest_fuel_pct([]), do: 0.0

  defp latest_fuel_pct(fueled) do
    fueled
    |> Enum.max_by(&(&1["fuel_effective"] || ""))
    |> Map.get("fuel_percent")
    |> num()
  end

  # --- ranking ------------------------------------------------------------

  defp rank(rows, total) do
    rows
    |> Enum.group_by(&Map.get(&1, "supplier_ref"))
    |> Enum.map(fn {ref, supplier_rows} ->
      # The origin is LEFT-joined, so a candidate that services the destination
      # but has no origin-area rate comes back with null rate columns. Keep only
      # the rows that actually resolved a rate band before pricing — the rest
      # price nothing, and the supplier is surfaced as undetermined, not dropped.
      waybill_costs =
        supplier_rows
        |> Enum.filter(&rated?/1)
        |> Enum.group_by(&Map.get(&1, "waybill_obj"))
        |> Enum.map(fn {_wb, wb_rows} ->
          # Latest in-force service mapping, then latest in-force rate (mirrors
          # assigned_expected) — both SQL-bounded to <= today for the live ranking.
          wb_rows |> Enum.max_by(&rate_sort_key/1) |> waybill_cost()
        end)

      priced = length(waybill_costs)
      determined = priced > 0

      %{
        supplier_ref: ref,
        supplier_name: supplier_rows |> hd() |> Map.get("supplier_name"),
        waybills_priced: priced,
        total_waybills: total,
        full_coverage: total > 0 and priced == total,
        # nil = no rate could be determined for this supplier from the origin.
        determined: determined,
        total_expected: (determined && waybill_costs |> Enum.sum() |> Float.round(2)) || nil
      }
    end)
    # Determined suppliers first (full-coverage, then cheapest); undetermined
    # (no origin-area rate) sink to the bottom — never dropped.
    |> Enum.sort_by(fn s ->
      {not s.determined, not s.full_coverage, s.total_expected || 0.0}
    end)
  end

  # Did this (waybill, supplier) row resolve an actual rate band? The origin
  # LEFT join leaves rt.base_amount null when the supplier has no rate for the
  # origin area, so a present base_amount is the "can price this" signal.
  defp rated?(row), do: row["base_amount"] not in [nil, ""]

  # Ordering key that resolves a waybill's fanned-out rate rows to EXACTLY ONE rate.
  # Expected cost must always use a single rate — never a sum, never an arbitrary pick,
  # and never zero when a rate exists. Total order (max_by wins on the largest tuple):
  #   1. latest in-force service MAPPING (fwm_contractor_service_type)
  #   2. latest in-force RATE version
  #   3. prefer the GENERIC (account_product_obj = 0) rate — product-specific rates are
  #      0.6%; without per-line account_product resolution the account-agnostic base is
  #      correct for the ~99% of accounts with no product (per-line override = follow-up)
  #   4. prefer the CANONICAL rate over its generated reverse-mirror
  #      (bidirectional_entity_rate_obj = 0). A PREFERENCE, not a filter: the mirror stays
  #      a candidate, so a lane whose rate is stored only as the reverse row still prices
  #      (never zero) — we just favour the canonical when both exist.
  #   5. highest entity_rate_obj — a UNIQUE final tie-break so the pick is deterministic
  #      even for a genuine duplicate (OpenEdge obj is sequence-assigned, so highest =
  #      latest-created record). This guarantees "only one rate is ever used".
  # Mapping/rate are SQL-bounded to <= the reference date; ISO date strings sort
  # chronologically. Falls back to an older mapping only when the newer has no lane rate.
  defp rate_sort_key(row) do
    generic = if num(row["account_product_obj"]) == 0.0, do: 1, else: 0
    canonical = if num(row["bidirectional_entity_rate_obj"]) == 0.0, do: 1, else: 0

    {row["map_effective_date"] || "", row["effective_date"] || "", generic, canonical,
     num(row["entity_rate_obj"])}
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
  # Candidacy (INNER) = the supplier `c` whose rate area covers the waybill's
  # DESTINATION postcode, AND is currently active — a ceased / not-yet-started
  # contractor (fwm_station_contractor.cease_date / start_date) is eliminated from
  # the ranking outright, because it isn't a selectable option (distinct from an
  # active supplier that merely lacks an origin rate — that one still ranks last).
  # This active filter is RANKING-ONLY; the margin calc (assigned_rows_sql) never
  # applies it, since it prices against whoever actually delivered.
  # The ORIGIN chain is LEFT-joined: the manifest branch
  # (`code` = manifestBranch = fwm_station.station_code) → that depot's physical
  # postcode → the same supplier's origin rate area → the rate row's from_rate_area.
  # When a candidate has no rate for that origin area (or the branch can't be
  # resolved), er/rt come back null — the supplier is kept and priced as
  # undetermined (rank/2 sorts it last), never dropped. A blank `code` matches no
  # station, so every candidate is undetermined — the "no origin branch" case.
  #
  # NOTE: forward direction only. Bidirectional cards (fwm_entity_rate.bidirectional)
  # stored as dest→origin are not yet matched in reverse — a follow-up.
  defp rows_sql(obj, code) do
    today = Date.utc_today() |> Date.to_iso8601()

    """
    SELECT c.contractor_reference AS supplier_ref, c.contractor_name AS supplier_name, \
    w.waybill_obj, w.chargable_units, er.entity_rate_obj, \
    er.bidirectional_entity_rate_obj, er.effective_date, \
    cst.effective_date AS map_effective_date, er.account_product_obj, rt.from_unit, rt.base_amount, \
    rt.increment_amount, rt.increment_unit \
    FROM PUB.fwt_parcel_tripsheet pt \
    JOIN PUB.fwt_waybill_parcel wp ON wp.waybill_parcel_obj = pt.waybill_parcel_obj \
    JOIN PUB.fwt_waybill w ON w.waybill_obj = wp.waybill_obj \
    JOIN PUB.fwc_rate_area_postcode pc ON pc.postcode_obj = w.consignee_postcode_obj \
    AND pc.owning_entity_mnemonic = 'FWMSC' \
    JOIN PUB.fwm_station_contractor c ON c.station_contractor_obj = pc.owning_obj \
    AND (c.cease_date IS NULL OR c.cease_date >= '#{today}') \
    AND (c.start_date IS NULL OR c.start_date <= '#{today}') \
    LEFT JOIN PUB.fwm_contractor_service_type cst ON cst.station_contractor_obj = c.station_contractor_obj \
    AND cst.company_service_type_obj = w.service_type_obj \
    AND cst.effective_date <= '#{today}' \
    LEFT JOIN PUB.fwm_station st ON st.station_code = '#{code}' \
    LEFT JOIN PUB.fwc_rate_area_postcode opc ON opc.postcode_obj = st.physical_address_postcode_obj \
    AND opc.owning_entity_mnemonic = 'FWMSC' AND opc.owning_obj = pc.owning_obj \
    LEFT JOIN PUB.fwm_entity_rate er ON er.owning_entity_mnemonic = 'FWMSC' \
    AND er.owning_obj = pc.owning_obj AND er.to_rate_area_obj = pc.rate_area_obj \
    AND er.from_rate_area_obj = opc.rate_area_obj \
    AND er.service_type_obj = cst.service_type_obj \
    AND er.rate_type_obj = cst.rate_type_obj \
    AND er.effective_date <= '#{today}' \
    AND (er.cease_date IS NULL OR er.cease_date >= '#{today}') \
    LEFT JOIN PUB.fwm_rate_table rt ON rt.entity_rate_obj = er.entity_rate_obj \
    AND w.chargable_units >= rt.from_unit AND w.chargable_units < rt.to_unit \
    WHERE pt.tripsheet_obj = #{obj}
    """
  end

  # Raw per-(waybill, effective-version, band) rate rows for the waybills matched
  # by `where_sql`, priced against each waybill's actual DELIVERY supplier.
  #
  # The supplier comes from the waybill's contractor charges
  # (fwt_contractor_charge -> fwm_station_contractor), NOT the fwt_waybill
  # .contractor_reference header — that header is blank on ~70% of waybills, so
  # keying on it dropped most real 3rd-party spend. The supplier is pinned to the
  # party whose rate area covers the consignee postcode
  # (pc.owning_obj = sc.station_contractor_obj), which self-selects the delivery
  # leg's supplier without having to guess the charge type. DISTINCT collapses the
  # charge-join fan-out (a waybill can carry several charge lines for the same
  # supplier); the Elixir side then dedups by waybill (latest effective) and prices.
  #
  # ORIGIN (buy-side): SAME METHOD as the supplier ranking (rows_sql) — the rate
  # lane's `from` is pinned to the scanning/delivery branch's physical postcode →
  # the same supplier's rate area → er.from_rate_area_obj. This query only EMITS a
  # priced row when the origin matches; a waybill with no origin-area rate simply
  # isn't in the result. It is NOT dropped from the margin report: the drill lists
  # every waybill from its own sell/buy query and treats the absence here as
  # "uncosted" (counted + colored — see Drill), so never-drop holds. The branch is
  # `fwt_waybill.at_station_obj` — the station the waybill is at / was scanned at,
  # the per-waybill analogue of the delivery manifest's `manifestBranch` (station_obj
  # is the booking branch and does NOT match the delivery supplier's card). Coverage
  # is intrinsically partial: no derivable origin matches these cards for >~42% of
  # waybills, so buy-expected is a partial figure. (Same bidirectional caveat.)
  defp assigned_rows_sql(where_sql) do
    """
    SELECT DISTINCT w.waybill_obj, w.waybill_date, w.account_name, w.rate_area_to_code, \
    sc.contractor_reference, w.chargable_units, er.entity_rate_obj, \
    er.bidirectional_entity_rate_obj, er.effective_date, \
    cst.effective_date AS map_effective_date, er.account_product_obj, rt.from_unit, \
    rt.base_amount, rt.increment_amount, rt.increment_unit, \
    fc.charge_percent AS fuel_percent, fc.effective_date AS fuel_effective \
    FROM PUB.fwt_waybill w \
    JOIN PUB.fwt_contractor_charge cc ON cc.waybill_obj = w.waybill_obj \
    JOIN PUB.fwm_station_contractor sc ON sc.station_contractor_obj = cc.station_contractor_obj \
    JOIN PUB.fwm_contractor_service_type cst ON cst.station_contractor_obj = sc.station_contractor_obj \
    AND cst.company_service_type_obj = w.service_type_obj \
    AND cst.effective_date <= w.waybill_date \
    JOIN PUB.fwc_rate_area_postcode pc ON pc.postcode_obj = w.consignee_postcode_obj \
    AND pc.owning_entity_mnemonic = 'FWMSC' AND pc.owning_obj = sc.station_contractor_obj \
    JOIN PUB.fwm_station ws ON ws.station_obj = w.at_station_obj \
    JOIN PUB.fwc_rate_area_postcode wopc ON wopc.postcode_obj = ws.physical_address_postcode_obj \
    AND wopc.owning_entity_mnemonic = 'FWMSC' AND wopc.owning_obj = sc.station_contractor_obj \
    JOIN PUB.fwm_entity_rate er ON er.owning_entity_mnemonic = 'FWMSC' \
    AND er.owning_obj = pc.owning_obj AND er.to_rate_area_obj = pc.rate_area_obj \
    AND er.from_rate_area_obj = wopc.rate_area_obj \
    AND er.service_type_obj = cst.service_type_obj \
    AND er.rate_type_obj = cst.rate_type_obj \
    AND er.effective_date <= w.waybill_date \
    AND (er.cease_date IS NULL OR er.cease_date >= w.waybill_date) \
    JOIN PUB.fwm_rate_table rt ON rt.entity_rate_obj = er.entity_rate_obj \
    AND w.chargable_units >= rt.from_unit AND w.chargable_units < rt.to_unit \
    LEFT JOIN PUB.fwm_charge fc ON fc.owning_entity_mnemonic = 'FWMSC' \
    AND fc.owning_obj = sc.station_contractor_obj AND fc.charge_code = 'SCFUEL' \
    AND fc.effective_date <= w.waybill_date \
    AND (fc.effective_until_date IS NULL OR fc.effective_until_date >= w.waybill_date) \
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

  # The API's manifestBranch = fwm_station.station_code, used to pin the origin
  # (from) rate area. Whitelist to a bare station code so it's a safe SQL literal.
  # A missing/blank/odd value isn't an error — it just interpolates to an empty
  # literal that matches no station, so the LEFT-joined origin stays null and
  # every candidate ranks as undetermined (never dropped).
  defp sanitize_station(code) do
    c = code |> to_string() |> String.trim()

    if String.match?(c, ~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,19}$/),
      do: {:ok, c},
      else: {:ok, ""}
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
