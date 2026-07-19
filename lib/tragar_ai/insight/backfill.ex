defmodule TragarAi.Insight.Backfill do
  @moduledoc """
  Populate the `insight_rollups` warehouse from the FreightWare replica.

  Sell and buy are aggregated **separately** per month (never a single join, which
  would fan out on contractor charges and double-count the sell), then combined
  into margin. The time axis is `waybill_date` (invoice_date is dirty). Runs
  in-app — the data stays on-box; the functions return only counts, never rows.

  `sell = SUM(fwt_waybill.total_cost)` (the customer charge; the API's chargedAmount),
  `buy  = SUM(fwt_contractor_charge.total_charge_amount)` joined to its waybill and
  bucketed by that waybill's date, `margin = sell − buy`.
  """
  require Logger

  alias TragarAi.Insight.Db
  alias TragarAi.Insight.RateEngine
  alias TragarAi.Insight.Rollup
  alias TragarAi.Repo

  import Ecto.Query, only: [from: 2]

  @from_year 2016
  @to_year 2026

  @sell_sql "SELECT YEAR(waybill_date) AS yr, MONTH(waybill_date) AS mo, COUNT(*) AS n, SUM(total_cost) AS sell FROM PUB.fwt_waybill WHERE YEAR(waybill_date) >= 2016 AND YEAR(waybill_date) <= 2026 GROUP BY YEAR(waybill_date), MONTH(waybill_date)"

  @buy_sql "SELECT YEAR(w.waybill_date) AS yr, MONTH(w.waybill_date) AS mo, SUM(cc.total_charge_amount) AS buy FROM PUB.fwt_contractor_charge cc JOIN PUB.fwt_waybill w ON w.waybill_obj = cc.waybill_obj WHERE YEAR(w.waybill_date) >= 2016 AND YEAR(w.waybill_date) <= 2026 GROUP BY YEAR(w.waybill_date), MONTH(w.waybill_date)"

  @doc """
  Backfill enterprise-grain monthly margin over the full history. Returns
  `{:ok, months_written}` or `{:error, reason}`.
  """
  @spec run_enterprise() :: {:ok, non_neg_integer()} | {:error, term()}
  def run_enterprise do
    with {:ok, sell_rows} <- Db.query_rows(@sell_sql),
         {:ok, buy_rows} <- Db.query_rows(@buy_sql) do
      sell = index_by_month(sell_rows)
      buy = index_by_month(buy_rows)

      count =
        sell
        |> Map.keys()
        |> Enum.filter(fn {y, m} -> valid_month?(y, m) end)
        |> Enum.reduce(0, fn {y, m} = key, acc ->
          s = Map.get(sell, key, %{})
          b = Map.get(buy, key, %{})
          sell_amt = decimal(s["sell"])
          buy_amt = decimal(b["buy"])

          upsert(%{
            period_month: Date.new!(y, m, 1),
            grain: "enterprise",
            dim_key: "all",
            dim_label: "Enterprise",
            waybills: integer(s["n"]),
            sell: sell_amt,
            buy: buy_amt,
            surcharges: Decimal.new(0),
            margin: Decimal.sub(sell_amt, buy_amt)
          })

          acc + 1
        end)

      Logger.info("[insight.backfill] enterprise rollups upserted: #{count}")
      {:ok, count}
    end
  end

  # Dimension column on fwt_waybill for each drill-down grain (all denormalised
  # on the waybill, so sell and buy both key on it).
  # Denormalised dimension columns for the waybill-keyed grains. Contractor is
  # NOT here — it's rebuilt from CHARGES (multi-supplier per waybill), see
  # run_contractor/0.
  @grain_cols %{
    "client" => "account_name",
    "lane" => "rate_area_to_code"
  }

  @doc "Backfill the enterprise grain plus every dimensional grain."
  @spec run_all() :: {:ok, map()} | {:error, term()}
  def run_all do
    with {:ok, ent} <- run_enterprise() do
      grains =
        for {grain, col} <- @grain_cols, into: %{} do
          {grain, run_grain(grain, col)}
        end

      grains =
        grains
        |> Map.put("enterprise", {:ok, ent})
        |> Map.put("contractor", run_contractor())

      {:ok, grains}
    end
  end

  @doc """
  Rebuild the contractor (supplier) grain from CHARGES — the only source that
  captures every supplier on a waybill (collection / line-haul / delivery legs
  each raise their own charge). `buy` = supplier cost. `sell` = the revenue of
  the waybills that supplier moved (each waybill's total_cost counted ONCE via a
  distinct (waybill, contractor) derived table, so multiple legs don't inflate
  it), `margin` = sell − buy. Bucketed by waybill_date; supplier keyed by
  contractor_reference.

  NOTE: contractor sell is NOT additive across suppliers — a waybill carried by
  several suppliers counts its sell under each — so per-supplier figures don't
  sum to enterprise revenue. Correct per-row (what the dashboard shows).
  """
  @spec run_contractor() :: {:ok, non_neg_integer()} | {:error, term()}
  def run_contractor do
    buy_sql =
      "SELECT YEAR(w.waybill_date) AS yr, MONTH(w.waybill_date) AS mo, sc.contractor_reference AS k, SUM(cc.total_charge_amount) AS buy FROM PUB.fwt_contractor_charge cc JOIN PUB.fwt_waybill w ON w.waybill_obj = cc.waybill_obj JOIN PUB.fwm_station_contractor sc ON sc.station_contractor_obj = cc.station_contractor_obj WHERE YEAR(w.waybill_date) >= 2016 AND YEAR(w.waybill_date) <= 2026 GROUP BY YEAR(w.waybill_date), MONTH(w.waybill_date), sc.contractor_reference"

    # Distinct (waybill, contractor) so a multi-leg waybill's total_cost is summed
    # once per supplier; count = distinct waybills that supplier moved.
    sell_sql =
      "SELECT YEAR(w.waybill_date) AS yr, MONTH(w.waybill_date) AS mo, p.k AS k, SUM(w.total_cost) AS sell, COUNT(*) AS n FROM (SELECT DISTINCT cc.waybill_obj AS wobj, sc.contractor_reference AS k FROM PUB.fwt_contractor_charge cc JOIN PUB.fwm_station_contractor sc ON sc.station_contractor_obj = cc.station_contractor_obj) p JOIN PUB.fwt_waybill w ON w.waybill_obj = p.wobj WHERE YEAR(w.waybill_date) >= 2016 AND YEAR(w.waybill_date) <= 2026 GROUP BY YEAR(w.waybill_date), MONTH(w.waybill_date), p.k"

    with {:ok, buy_rows} <- Db.query_rows(buy_sql),
         {:ok, sell_rows} <- Db.query_rows(sell_sql) do
      # Replace the whole grain — the dimension source changed.
      Repo.delete_all(from r in Rollup, where: r.grain == "contractor")

      buy = index_by_month_key(buy_rows)
      sell = index_by_month_key(sell_rows)
      keys = MapSet.union(MapSet.new(Map.keys(buy)), MapSet.new(Map.keys(sell)))

      count =
        Enum.reduce(keys, 0, fn {y, m, k} = key, acc ->
          if valid_month?(y, m) do
            b = Map.get(buy, key, %{})
            s = Map.get(sell, key, %{})
            sell_amt = decimal(s["sell"])
            buy_amt = decimal(b["buy"])

            upsert(%{
              period_month: Date.new!(y, m, 1),
              grain: "contractor",
              dim_key: dim_key(k),
              dim_label: dim_key(k),
              waybills: integer(s["n"]),
              sell: sell_amt,
              buy: buy_amt,
              surcharges: Decimal.new(0),
              margin: Decimal.sub(sell_amt, buy_amt)
            })

            acc + 1
          else
            acc
          end
        end)

      Logger.info("[insight.backfill] contractor (charges + sell) rollups upserted: #{count}")
      {:ok, count}
    end
  end

  @doc """
  Backfill one dimensional grain (dimension value = `dim_col` on fwt_waybill).
  Sell and buy are aggregated separately per (month, dimension). Returns
  `{:ok, rows_written}`.
  """
  @spec run_grain(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def run_grain(grain, dim_col) do
    sell_sql =
      "SELECT YEAR(waybill_date) AS yr, MONTH(waybill_date) AS mo, #{dim_col} AS k, COUNT(*) AS n, SUM(total_cost) AS sell FROM PUB.fwt_waybill WHERE YEAR(waybill_date) >= 2016 AND YEAR(waybill_date) <= 2026 GROUP BY YEAR(waybill_date), MONTH(waybill_date), #{dim_col}"

    buy_sql =
      "SELECT YEAR(w.waybill_date) AS yr, MONTH(w.waybill_date) AS mo, w.#{dim_col} AS k, SUM(cc.total_charge_amount) AS buy FROM PUB.fwt_contractor_charge cc JOIN PUB.fwt_waybill w ON w.waybill_obj = cc.waybill_obj WHERE YEAR(w.waybill_date) >= 2016 AND YEAR(w.waybill_date) <= 2026 GROUP BY YEAR(w.waybill_date), MONTH(w.waybill_date), w.#{dim_col}"

    with {:ok, sell_rows} <- Db.query_rows(sell_sql),
         {:ok, buy_rows} <- Db.query_rows(buy_sql) do
      sell = index_by_month_key(sell_rows)
      buy = index_by_month_key(buy_rows)
      keys = MapSet.union(MapSet.new(Map.keys(sell)), MapSet.new(Map.keys(buy)))

      count =
        Enum.reduce(keys, 0, fn {y, m, _k} = key, acc ->
          if valid_month?(y, m) do
            s = Map.get(sell, key, %{})
            b = Map.get(buy, key, %{})
            sell_amt = decimal(s["sell"])
            buy_amt = decimal(b["buy"])

            upsert(%{
              period_month: Date.new!(y, m, 1),
              grain: grain,
              dim_key: dim_key(elem(key, 2)),
              dim_label: dim_key(elem(key, 2)),
              waybills: integer(s["n"]),
              sell: sell_amt,
              buy: buy_amt,
              surcharges: Decimal.new(0),
              margin: Decimal.sub(sell_amt, buy_amt)
            })

            acc + 1
          else
            acc
          end
        end)

      Logger.info("[insight.backfill] #{grain} rollups upserted: #{count}")
      {:ok, count}
    end
  end

  @doc """
  Populate `expected_buy` on existing rollups — "buy expected" for the margin
  report: each waybill priced against its OWN assigned supplier's rate card
  (`RateEngine.assigned_expected/1`), summed per (month, grain, dim).

  Kept SEPARATE from `run_all/0` — and `expected_buy` is deliberately NOT in the
  upsert replace list — so a normal sell/buy backfill never clobbers it, and this
  heavier per-month pricing pass runs on demand. Prices one month at a time (never
  the whole history in one query), matching RateEngine's per-scope design.

  Only updates rows that already exist, so run it AFTER the sell/buy backfill.
  Own-fleet waybills (no card) contribute nothing, so expected is partial
  coverage — comparable to actual per waybill, a floor at aggregate grains.
  Returns `{:ok, rows_updated}`.
  """
  @spec run_expected() :: {:ok, non_neg_integer()}
  def run_expected do
    updated =
      for y <- @from_year..@to_year, m <- 1..12, reduce: 0 do
        acc -> acc + expected_month(y, m)
      end

    Logger.info("[insight.backfill] expected_buy rollups updated: #{updated}")
    {:ok, updated}
  end

  # Price one month's waybills against their assigned suppliers, fan the totals
  # out to every grain (enterprise / client / lane / contractor), and write each
  # onto its rollup row.
  defp expected_month(y, m) do
    where = "YEAR(w.waybill_date) = #{y} AND MONTH(w.waybill_date) = #{m}"

    case RateEngine.assigned_expected(where) do
      {:ok, [_ | _] = priced} ->
        period = Date.new!(y, m, 1)

        groups = %{
          "enterprise" => %{"all" => sum_expected(priced)},
          "client" => sum_by(priced, & &1.account_name),
          "lane" => sum_by(priced, & &1.rate_area_to_code),
          "contractor" => sum_by(priced, & &1.contractor_reference)
        }

        for {grain, by_dim} <- groups, {dim, amt} <- by_dim, reduce: 0 do
          acc -> acc + set_expected(period, grain, dim, amt)
        end

      _ ->
        0
    end
  end

  defp sum_expected(priced), do: priced |> Enum.map(& &1.expected) |> Enum.sum()

  defp sum_by(priced, key_fun) do
    priced
    |> Enum.group_by(fn r -> dim_key(key_fun.(r)) end)
    |> Map.new(fn {k, rs} -> {k, sum_expected(rs)} end)
  end

  defp set_expected(period, grain, dim, amt) do
    {n, _} =
      from(r in Rollup,
        where: r.period_month == ^period and r.grain == ^grain and r.dim_key == ^dim
      )
      |> Repo.update_all(set: [expected_buy: Decimal.from_float(Float.round(amt, 2))])

    n
  end

  defp index_by_month_key(rows) do
    for r <- rows, into: %{}, do: {{integer(r["yr"]), integer(r["mo"]), r["k"]}, r}
  end

  defp dim_key(nil), do: "(unknown)"
  defp dim_key(""), do: "(unknown)"
  defp dim_key(s), do: s

  defp index_by_month(rows) do
    for r <- rows, into: %{}, do: {{integer(r["yr"]), integer(r["mo"])}, r}
  end

  defp valid_month?(y, m), do: y >= @from_year and y <= @to_year and m in 1..12

  defp upsert(attrs) do
    %Rollup{}
    |> Rollup.changeset(attrs)
    |> Repo.insert!(
      on_conflict:
        {:replace, [:dim_label, :waybills, :sell, :buy, :surcharges, :margin, :updated_at]},
      conflict_target: [:period_month, :grain, :dim_key]
    )
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
