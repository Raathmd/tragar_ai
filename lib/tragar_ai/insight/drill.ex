defmodule TragarAi.Insight.Drill do
  @moduledoc """
  Row-level drill-down for the margin dashboard: from a dimension's monthly
  rollups down through days, individual waybills, and a single waybill's detail.

  Months come from the `insight_rollups` warehouse (fast, offline). Days,
  waybills, and waybill detail are **not** in the warehouse — it only stores
  monthly grain — so they are read live from the FreightWare replica
  (`PUB.fwt_waybill` / `fwt_contractor_charge`) through [`TragarAi.Insight.Db`],
  one query per drill.

  Margin follows the dashboard convention `sell − buy` (surcharges fold into
  buy), so every level sums into the one above it. Waybill-keyed grains
  (enterprise / client / lane) filter on a column of `fwt_waybill`; contractor is
  a cost view (sell = 0, margin = −buy) keyed on the charge side via
  `fwm_station_contractor.contractor_reference`.

  OpenEdge SQL has **no `DAY()` scalar** (only `YEAR()`/`MONTH()`), so the day
  grain is derived by grouping on the raw `waybill_date` and a single day is
  selected with a `waybill_date = 'YYYY-MM-DD'` equality.

  Each level function returns **uniform** rows the LiveView renders without caring
  about the level:

      %{label, obj, n, sell, buy, expected, margin, margin_pct, next}

  where `next` is `%{ev, v}` (the phx event + value to drill deeper) or `nil`.
  `buy` is the booked contractor charge (buy actual); `expected` is what each
  waybill's *assigned* supplier should have charged per its live rate card (buy
  expected, via [`TragarAi.Insight.RateEngine`]). Expected only covers waybills
  whose assigned supplier has a 3rd-party card (own-fleet legs have none), so at
  rolled-up grains it is a partial-coverage figure, not a like-for-like total.
  Live functions return `{:ok, ...}` or `{:error, reason}`.
  """
  import Ecto.Query

  alias TragarAi.Insight.Db
  alias TragarAi.Insight.RateEngine
  alias TragarAi.Insight.Rollup
  alias TragarAi.Repo

  # Waybill-keyed grains filter on a column of fwt_waybill (enterprise = no
  # filter); contractor is charge-keyed and handled separately.
  @wb_grains ~w(enterprise client lane)

  # ── Month level (warehouse) ────────────────────────────────────────────────
  @doc "A dimension's monthly rollups (year-scoped), newest first."
  @spec months(String.t(), String.t(), integer() | nil) :: [map()]
  def months(grain, dim, year) do
    from(r in Rollup, where: r.grain == ^grain and r.dim_key == ^dim)
    |> year_scope(year)
    |> order_by([r], desc: r.period_month)
    |> Repo.all()
    |> Enum.map(&month_row/1)
  end

  # ── Day level (live FreightWare) ───────────────────────────────────────────
  @doc "Per-day margin for a dimension within one month (live)."
  @spec days(String.t(), String.t(), Date.t()) :: {:ok, [map()]} | {:error, term()}
  def days(grain, dim, %Date{year: y, month: m}) when grain in @wb_grains do
    sell =
      "SELECT waybill_date AS d, COUNT(*) AS n, SUM(total_cost) AS sell " <>
        "FROM PUB.fwt_waybill " <>
        "WHERE YEAR(waybill_date) = #{y} AND MONTH(waybill_date) = #{m}" <>
        dim_filter(grain, dim, "") <>
        " GROUP BY waybill_date"

    buy =
      "SELECT w.waybill_date AS d, SUM(cc.total_charge_amount) AS buy " <>
        "FROM PUB.fwt_contractor_charge cc " <>
        "JOIN PUB.fwt_waybill w ON w.waybill_obj = cc.waybill_obj " <>
        "WHERE YEAR(w.waybill_date) = #{y} AND MONTH(w.waybill_date) = #{m}" <>
        dim_filter(grain, dim, "w.") <>
        " GROUP BY w.waybill_date"

    with {:ok, sell_rows} <- Db.query_rows(sell),
         {:ok, buy_rows} <- Db.query_rows(buy) do
      buys = Map.new(buy_rows, &{&1["d"], f(&1["buy"])})
      exp = expected_by(month_where(grain, dim, y, m), & &1.waybill_date)

      rows =
        sell_rows
        |> Enum.map(&{&1["d"], int(&1["n"]), f(&1["sell"])})
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {d, n, s} ->
          day_row(d, n, s, Map.get(buys, d, 0.0), Map.get(exp, d, 0.0))
        end)

      {:ok, rows}
    end
  end

  # Contractor is charge-keyed, but a waybill can carry several contractors
  # (collection / line-haul / delivery legs), so its sell (total_cost) must be
  # counted ONCE. Group at the waybill grain first, then roll up to the day —
  # sell = Σ distinct-waybill total_cost, buy = Σ this contractor's charges.
  def days("contractor", dim, %Date{year: y, month: m}) do
    sql =
      "SELECT w.waybill_obj AS obj, w.waybill_date AS d, w.total_cost AS sell, " <>
        "SUM(cc.total_charge_amount) AS buy " <>
        "FROM PUB.fwt_contractor_charge cc " <>
        "JOIN PUB.fwt_waybill w ON w.waybill_obj = cc.waybill_obj " <>
        "JOIN PUB.fwm_station_contractor sc ON sc.station_contractor_obj = cc.station_contractor_obj " <>
        "WHERE sc.contractor_reference = '#{escape(dim)}' " <>
        "AND YEAR(w.waybill_date) = #{y} AND MONTH(w.waybill_date) = #{m} " <>
        "GROUP BY w.waybill_obj, w.waybill_date, w.total_cost"

    with {:ok, rows} <- Db.query_rows(sql) do
      exp = expected_by(month_where("contractor", dim, y, m), & &1.waybill_date)

      {:ok,
       rows
       |> Enum.group_by(& &1["d"])
       |> Enum.map(fn {d, wbs} ->
         sell = wbs |> Enum.map(&f(&1["sell"])) |> Enum.sum()
         buy = wbs |> Enum.map(&f(&1["buy"])) |> Enum.sum()
         day_row(d, length(wbs), sell, buy, Map.get(exp, d, 0.0))
       end)
       |> Enum.sort_by(& &1.next.v)}
    end
  end

  # ── Waybill level (live FreightWare) ───────────────────────────────────────
  @doc "Individual waybills for a dimension on one day (live)."
  @spec waybills(String.t(), String.t(), Date.t()) :: {:ok, [map()]} | {:error, term()}
  def waybills(grain, dim, %Date{} = day) when grain in @wb_grains do
    iso = Date.to_iso8601(day)

    sell =
      "SELECT waybill_number, waybill_obj, total_cost AS sell FROM PUB.fwt_waybill " <>
        "WHERE waybill_date = '#{iso}'" <> dim_filter(grain, dim, "")

    buy =
      "SELECT cc.waybill_obj AS waybill_obj, SUM(cc.total_charge_amount) AS buy " <>
        "FROM PUB.fwt_contractor_charge cc " <>
        "JOIN PUB.fwt_waybill w ON w.waybill_obj = cc.waybill_obj " <>
        "WHERE w.waybill_date = '#{iso}'" <>
        dim_filter(grain, dim, "w.") <>
        " GROUP BY cc.waybill_obj"

    with {:ok, sell_rows} <- Db.query_rows(sell),
         {:ok, buy_rows} <- Db.query_rows(buy) do
      buys = Map.new(buy_rows, &{&1["waybill_obj"], f(&1["buy"])})
      exp = expected_by(day_where(grain, dim, iso), & &1.waybill_obj)

      rows =
        sell_rows
        |> Enum.map(fn r ->
          wb_row(
            r["waybill_number"],
            r["waybill_obj"],
            nil,
            f(r["sell"]),
            Map.get(buys, r["waybill_obj"], 0.0),
            Map.get(exp, r["waybill_obj"], 0.0)
          )
        end)
        |> Enum.sort_by(& &1.margin)

      {:ok, rows}
    end
  end

  def waybills("contractor", dim, %Date{} = day) do
    iso = Date.to_iso8601(day)

    sql =
      "SELECT w.waybill_number AS waybill_number, w.waybill_obj AS waybill_obj, " <>
        "w.total_cost AS sell, SUM(cc.total_charge_amount) AS buy " <>
        "FROM PUB.fwt_contractor_charge cc " <>
        "JOIN PUB.fwt_waybill w ON w.waybill_obj = cc.waybill_obj " <>
        "JOIN PUB.fwm_station_contractor sc ON sc.station_contractor_obj = cc.station_contractor_obj " <>
        "WHERE sc.contractor_reference = '#{escape(dim)}' AND w.waybill_date = '#{iso}' " <>
        "GROUP BY w.waybill_number, w.waybill_obj, w.total_cost"

    with {:ok, rows} <- Db.query_rows(sql) do
      exp = expected_by(day_where("contractor", dim, iso), & &1.waybill_obj)

      {:ok,
       rows
       |> Enum.map(fn r ->
         wb_row(
           r["waybill_number"],
           r["waybill_obj"],
           nil,
           f(r["sell"]),
           f(r["buy"]),
           Map.get(exp, r["waybill_obj"], 0.0)
         )
       end)
       |> Enum.sort_by(& &1.margin)}
    end
  end

  # ── Waybill detail (live FreightWare, leaf) ────────────────────────────────
  @doc "One waybill's header fields plus its contractor-charge (buy) breakdown."
  @spec detail(String.t()) :: {:ok, map()} | {:error, term()}
  def detail(obj) do
    header =
      "SELECT waybill_number, waybill_date, account_name, shipper_reference, " <>
        "contractor_reference, rate_area_from_code, rate_area_to_code, " <>
        "waybill_weight, number_of_items, total_cost AS sell " <>
        "FROM PUB.fwt_waybill WHERE waybill_obj = '#{escape(obj)}'"

    charges =
      "SELECT sc.contractor_reference AS supplier, cc.charge_type_tla AS type, " <>
        "cc.total_charge_amount AS amount " <>
        "FROM PUB.fwt_contractor_charge cc " <>
        "JOIN PUB.fwm_station_contractor sc ON sc.station_contractor_obj = cc.station_contractor_obj " <>
        "WHERE cc.waybill_obj = '#{escape(obj)}'"

    with {:ok, [h | _]} <- Db.query_rows(header),
         {:ok, charge_rows} <- Db.query_rows(charges) do
      lines =
        Enum.map(charge_rows, fn c ->
          %{supplier: c["supplier"], type: c["type"], amount: f(c["amount"])}
        end)

      sell = f(h["sell"])
      buy = lines |> Enum.map(& &1.amount) |> Enum.sum()

      expected =
        case RateEngine.assigned_expected("w.waybill_obj = '#{escape(obj)}'") do
          {:ok, priced} -> priced |> Enum.map(& &1.expected) |> Enum.sum()
          {:error, _} -> 0.0
        end

      {:ok,
       %{
         number: h["waybill_number"],
         date: h["waybill_date"],
         account: h["account_name"],
         shipper: h["shipper_reference"],
         contractor: h["contractor_reference"],
         from: h["rate_area_from_code"],
         to: h["rate_area_to_code"],
         weight: h["waybill_weight"],
         items: h["number_of_items"],
         sell: sell,
         buy: buy,
         expected: expected,
         margin: sell - buy,
         margin_pct: pct(sell - buy, sell),
         charges: lines
       }}
    else
      {:ok, []} -> {:error, :not_found}
      other -> other
    end
  end

  # ── uniform rows ────────────────────────────────────────────────────────────
  defp month_row(r) do
    s = f(r.sell)
    b = f(r.buy)

    %{
      label: Calendar.strftime(r.period_month, "%b %Y"),
      obj: nil,
      n: r.waybills || 0,
      sell: s,
      buy: b,
      expected: f(r.expected_buy),
      margin: s - b,
      margin_pct: pct(s - b, s),
      next: %{ev: "drill_month", v: Date.to_iso8601(r.period_month)}
    }
  end

  defp day_row(iso, n, sell, buy, expected) do
    date = Date.from_iso8601!(iso)

    %{
      label: Calendar.strftime(date, "%d %a"),
      obj: nil,
      n: n,
      sell: sell,
      buy: buy,
      expected: expected,
      margin: sell - buy,
      margin_pct: pct(sell - buy, sell),
      next: %{ev: "drill_day", v: iso}
    }
  end

  defp wb_row(number, obj, n, sell, buy, expected) do
    %{
      label: "WB #{number}",
      obj: obj,
      n: n,
      sell: sell,
      buy: buy,
      expected: expected,
      margin: sell - buy,
      margin_pct: pct(sell - buy, sell),
      next: %{ev: "waybill_detail", v: obj}
    }
  end

  # ── expected buy (assigned-supplier rate card, live) ─────────────────────────
  # Sum RateEngine's per-waybill expected cost into %{key => expected} for the
  # waybills matched by `where_sql`. A rate hiccup degrades to no expected column
  # (empty map) rather than failing the whole drill — buy/sell/margin still load.
  defp expected_by(where_sql, key_fun) do
    case RateEngine.assigned_expected(where_sql) do
      {:ok, priced} ->
        priced
        |> Enum.group_by(key_fun, & &1.expected)
        |> Map.new(fn {k, xs} -> {k, Enum.sum(xs)} end)

      {:error, _} ->
        %{}
    end
  end

  # WHERE over the expected-cost query's aliases (`w` = fwt_waybill, `sc` =
  # fwm_station_contractor delivery supplier), mirroring the sell/buy filters. The
  # contractor grain keys on the delivery supplier (sc.contractor_reference — the
  # charge-side party, matching how buy is aggregated); wb-grains reuse dim_filter.
  defp month_where("contractor", dim, y, m),
    do:
      "YEAR(w.waybill_date) = #{y} AND MONTH(w.waybill_date) = #{m} " <>
        "AND sc.contractor_reference = '#{escape(dim)}'"

  defp month_where(grain, dim, y, m),
    do:
      "YEAR(w.waybill_date) = #{y} AND MONTH(w.waybill_date) = #{m}" <>
        dim_filter(grain, dim, "w.")

  defp day_where("contractor", dim, iso),
    do: "w.waybill_date = '#{iso}' AND sc.contractor_reference = '#{escape(dim)}'"

  defp day_where(grain, dim, iso),
    do: "w.waybill_date = '#{iso}'" <> dim_filter(grain, dim, "w.")

  # ── query building ──────────────────────────────────────────────────────────
  defp dim_filter("enterprise", _dim, _prefix), do: ""
  defp dim_filter("client", dim, prefix), do: " AND #{prefix}account_name = '#{escape(dim)}'"
  defp dim_filter("lane", dim, prefix), do: " AND #{prefix}rate_area_to_code = '#{escape(dim)}'"

  # Values come from our own rollups (real DB data), but escape defensively: double
  # single-quotes and drop `;` so a dimension name can't break or be refused by the
  # read-only SELECT guard.
  defp escape(s), do: s |> to_string() |> String.replace("'", "''") |> String.replace(";", "")

  defp year_scope(query, nil), do: query

  defp year_scope(query, year) do
    from r in query,
      where:
        r.period_month >= ^Date.new!(year, 1, 1) and
          r.period_month <= ^Date.new!(year, 12, 31)
  end

  # ── coercion (Db returns string cells; warehouse returns Decimal/Date) ───────
  defp f(nil), do: 0.0
  defp f(%Decimal{} = d), do: Decimal.to_float(d)
  defp f(n) when is_number(n), do: n * 1.0

  defp f(s) when is_binary(s) do
    case Float.parse(s) do
      {v, _} -> v
      :error -> 0.0
    end
  end

  defp int(nil), do: 0
  defp int(n) when is_integer(n), do: n

  defp int(s) when is_binary(s) do
    case Integer.parse(s) do
      {v, _} -> v
      :error -> 0
    end
  end

  defp pct(_num, denom) when denom in [0, 0.0], do: 0.0
  defp pct(num, denom), do: Float.round(num / denom * 100, 1)
end
