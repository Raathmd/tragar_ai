defmodule TragarAi.Insight.Backfill do
  @moduledoc """
  Populate the `insight_rollups` warehouse from the FreightWare replica.

  Sell and buy are aggregated **separately** per month (never a single join, which
  would fan out on contractor charges and double-count the sell), then combined
  into margin. The time axis is `waybill_date` (invoice_date is dirty). Runs
  in-app — the data stays on-box; the functions return only counts, never rows.

  `sell = SUM(fwt_waybill.charged_amount)`,
  `buy  = SUM(fwt_contractor_charge.total_charge_amount)` joined to its waybill and
  bucketed by that waybill's date, `margin = sell − buy`.
  """
  require Logger

  alias TragarAi.Insight.Db
  alias TragarAi.Insight.Rollup
  alias TragarAi.Repo

  @from_year 2016
  @to_year 2026

  @sell_sql "SELECT YEAR(waybill_date) AS yr, MONTH(waybill_date) AS mo, COUNT(*) AS n, SUM(charged_amount) AS sell FROM PUB.fwt_waybill WHERE YEAR(waybill_date) >= 2016 AND YEAR(waybill_date) <= 2026 GROUP BY YEAR(waybill_date), MONTH(waybill_date)"

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
