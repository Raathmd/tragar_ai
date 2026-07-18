defmodule TragarAi.Insight.SupplierCostBackfill do
  @moduledoc """
  Populate the `supplier_route_costs` warehouse from the FreightWare replica.

  Historical supplier cost per lane, consolidation-attributed. Two aggregate
  queries, merged in Elixir and upserted per `(month, lane, supplier)` — the data
  stays on-box, only aggregates leave the replica.

    * DIRECT — non-consolidated waybills: each waybill's supplier cost
      (`SUM(fwt_contractor_charge.total_charge_amount)`) attributed to that
      waybill's own lane and the charging supplier.
    * CONSOL — consolidated members: the trip cost (sum of contractor charges
      over ALL members of the consolidation, since only ~1 lead member carries
      it) is spread across members by chargeable-weight share
      `member.chargable_units / total_chargeable_units`, attributed to the
      MEMBER's lane and the CONSOLIDATION's supplier.

  Both are aggregated by `(year, month, rate_area_from, rate_area_to,
  station_contractor_obj)` then merged.

  NOTE: authored against the OpenEdge SQL dialect (short aliases ≤32 chars, no
  `DAY()`, derived tables, `NOT EXISTS`) but not yet run — validate with
  `run/0` against the deployed release and confirm the CONSOL weight-share
  denominator (`total_chargeable_units`) is populated before trusting the numbers.
  """
  require Logger

  alias TragarAi.Insight.Db
  alias TragarAi.Insight.SupplierRouteCost
  alias TragarAi.Repo

  @from_year 2016
  @to_year 2026

  # Non-consolidated waybills. Inner derived table collapses charge lines to one
  # row per (waybill, supplier) so weight/date aren't fan-out-inflated and the
  # per-waybill cost is correct; outer aggregates to the warehouse cell.
  @direct_sql """
  SELECT t.yr AS yr, t.mo AS mo, t.frm AS frm, t.too AS too, t.sc AS sc,
         sctr.contractor_reference AS ref, COUNT(*) AS n, SUM(t.wb_cost) AS cost,
         SUM(t.kg) AS kg, MIN(t.wb_cost) AS mincost, MAX(t.wdate) AS lastd
  FROM (
    SELECT YEAR(w.waybill_date) AS yr, MONTH(w.waybill_date) AS mo,
           w.rate_area_from_code AS frm, w.rate_area_to_code AS too,
           cc.station_contractor_obj AS sc, w.waybill_obj AS wobj,
           MAX(w.chargable_units) AS kg, MAX(w.waybill_date) AS wdate,
           SUM(cc.total_charge_amount) AS wb_cost
    FROM PUB.fwt_contractor_charge cc
    JOIN PUB.fwt_waybill w ON w.waybill_obj = cc.waybill_obj
    WHERE YEAR(w.waybill_date) >= #{@from_year} AND YEAR(w.waybill_date) <= #{@to_year}
      AND NOT EXISTS (SELECT 1 FROM PUB.fwt_consolidated_waybill_item ci
                      WHERE ci.waybill_obj = w.waybill_obj)
    GROUP BY YEAR(w.waybill_date), MONTH(w.waybill_date), w.rate_area_from_code,
             w.rate_area_to_code, cc.station_contractor_obj, w.waybill_obj
  ) t
  JOIN PUB.fwm_station_contractor sctr ON sctr.station_contractor_obj = t.sc
  GROUP BY t.yr, t.mo, t.frm, t.too, t.sc, sctr.contractor_reference
  """

  # Consolidated members. Inner `tc` = per-consolidation trip cost + supplier +
  # total chargeable units; middle derived table attributes it to each member by
  # weight share; outer aggregates to the warehouse cell (member's lane, trip
  # supplier). Guards total_chargeable_units > 0.
  @consol_sql """
  SELECT t.yr AS yr, t.mo AS mo, t.frm AS frm, t.too AS too, t.sc AS sc,
         sctr.contractor_reference AS ref, COUNT(*) AS n, SUM(t.att_cost) AS cost,
         SUM(t.kg) AS kg, MIN(t.att_cost) AS mincost, MAX(t.wdate) AS lastd
  FROM (
    SELECT YEAR(w.waybill_date) AS yr, MONTH(w.waybill_date) AS mo,
           w.rate_area_from_code AS frm, w.rate_area_to_code AS too,
           tc.sc AS sc, w.chargable_units AS kg, w.waybill_date AS wdate,
           (tc.trip_cost * w.chargable_units / tc.total_kg) AS att_cost
    FROM PUB.fwt_consolidated_waybill_item ci
    JOIN PUB.fwt_waybill w ON w.waybill_obj = ci.waybill_obj
    JOIN (
      SELECT ci2.consolidated_waybill_obj AS cwobj,
             cw.station_contractor_obj AS sc,
             cw.total_chargeable_units AS total_kg,
             SUM(cc.total_charge_amount) AS trip_cost
      FROM PUB.fwt_consolidated_waybill_item ci2
      JOIN PUB.fwt_consolidated_waybill cw
        ON cw.consolidated_waybill_obj = ci2.consolidated_waybill_obj
      JOIN PUB.fwt_contractor_charge cc ON cc.waybill_obj = ci2.waybill_obj
      WHERE cw.total_chargeable_units > 0
      GROUP BY ci2.consolidated_waybill_obj, cw.station_contractor_obj,
               cw.total_chargeable_units
    ) tc ON tc.cwobj = ci.consolidated_waybill_obj
    WHERE YEAR(w.waybill_date) >= #{@from_year} AND YEAR(w.waybill_date) <= #{@to_year}
  ) t
  JOIN PUB.fwm_station_contractor sctr ON sctr.station_contractor_obj = t.sc
  GROUP BY t.yr, t.mo, t.frm, t.too, t.sc, sctr.contractor_reference
  """

  @doc """
  Rebuild the whole `supplier_route_costs` warehouse. Returns `{:ok, cells}` or
  `{:error, reason}`.
  """
  @spec run() :: {:ok, non_neg_integer()} | {:error, term()}
  def run do
    with {:ok, direct} <- Db.query_rows(@direct_sql, timeout: 600_000),
         {:ok, consol} <- Db.query_rows(@consol_sql, timeout: 600_000) do
      merged = merge_cells(direct ++ consol)

      count =
        Enum.reduce(merged, 0, fn {_key, cell}, acc ->
          if valid_month?(cell.yr, cell.mo) do
            upsert(cell)
            acc + 1
          else
            acc
          end
        end)

      Logger.info("[supplier_cost.backfill] supplier_route_costs cells upserted: #{count}")
      {:ok, count}
    end
  end

  # Merge DIRECT + CONSOL rows sharing a (month, lane, supplier) cell: add counts,
  # cost and kg; keep the smallest min-cost and the latest charge date.
  defp merge_cells(rows) do
    Enum.reduce(rows, %{}, fn r, acc ->
      key = {integer(r["yr"]), integer(r["mo"]), r["frm"], r["too"], r["sc"]}

      cell = %{
        yr: integer(r["yr"]),
        mo: integer(r["mo"]),
        frm: r["frm"],
        too: r["too"],
        sc: r["sc"],
        ref: r["ref"],
        n: integer(r["n"]),
        cost: decimal(r["cost"]),
        kg: decimal(r["kg"]),
        mincost: decimal(r["mincost"]),
        lastd: r["lastd"]
      }

      Map.update(acc, key, cell, fn prev ->
        %{
          prev
          | n: prev.n + cell.n,
            cost: Decimal.add(prev.cost, cell.cost),
            kg: Decimal.add(prev.kg, cell.kg),
            mincost: Decimal.min(prev.mincost, cell.mincost),
            lastd: max_date(prev.lastd, cell.lastd),
            ref: prev.ref || cell.ref
        }
      end)
    end)
  end

  defp upsert(cell) do
    %SupplierRouteCost{}
    |> SupplierRouteCost.changeset(%{
      period_month: Date.new!(cell.yr, cell.mo, 1),
      rate_area_from: dim(cell.frm),
      rate_area_to: dim(cell.too),
      station_contractor_obj: to_string(cell.sc),
      contractor_label: cell.ref,
      waybills: cell.n,
      total_cost: cell.cost,
      total_chargeable_kg: cell.kg,
      min_cost: cell.mincost,
      last_charged_date: parse_date(cell.lastd)
    })
    |> Repo.insert!(
      on_conflict:
        {:replace,
         [
           :contractor_label,
           :waybills,
           :total_cost,
           :total_chargeable_kg,
           :min_cost,
           :last_charged_date,
           :updated_at
         ]},
      conflict_target: [:period_month, :rate_area_from, :rate_area_to, :station_contractor_obj]
    )
  end

  defp valid_month?(y, m), do: y >= @from_year and y <= @to_year and m in 1..12

  defp dim(nil), do: "(unknown)"
  defp dim(""), do: "(unknown)"
  defp dim(s), do: s

  defp max_date(nil, b), do: b
  defp max_date(a, nil), do: a
  defp max_date(a, b), do: if(a >= b, do: a, else: b)

  # The Java Query tool prints dates as "YYYY-MM-DD" strings; tolerate blanks.
  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(s) when is_binary(s) do
    case Date.from_iso8601(String.slice(s, 0, 10)) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp integer(nil), do: 0
  defp integer(""), do: 0

  defp integer(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp decimal(nil), do: Decimal.new(0)
  defp decimal(""), do: Decimal.new(0)

  defp decimal(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, _} -> d
      :error -> Decimal.new(0)
    end
  end
end
