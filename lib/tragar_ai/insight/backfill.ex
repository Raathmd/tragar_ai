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
  alias TragarAi.Insight.Rollup
  alias TragarAi.Repo

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
  @grain_cols %{
    "client" => "account_name",
    "contractor" => "contractor_name",
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

      {:ok, Map.put(grains, "enterprise", {:ok, ent})}
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
