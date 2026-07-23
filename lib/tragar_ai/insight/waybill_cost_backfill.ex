defmodule TragarAi.Insight.WaybillCostBackfill do
  @moduledoc """
  Populate the `insight_waybill_costs` per-waybill fact table from the FreightWare
  replica — the leaf grain the margin drills read instead of re-querying the
  replica live.

  Driven by `TragarAi.Insight.WarehouseRefreshWorker`. Two entry modes:

    * `refresh(:full)`   — rebuild every year (2016..2026). One-time seed / safety
      rebuild.
    * `refresh(:window)` — the scheduled tick: rebuild the ROLLING WINDOW (current
      + previous year) plus any OLDER months flagged by `changed_periods/1` (waybill
      status-events since the stored high-water). We re-sum each period from source,
      so new / changed / late-posted waybills are absorbed without diffing.

  Both funnel through `build_period/2`, which prices one (year, month) at a time —
  matching `RateEngine`'s per-scope design — and upserts one row per waybill.

  ## STATUS — implemented; change detection is 3-layer (2026-07-21)

  `build_period/2` is implemented: per-waybill sell / buy / own_fleet from the
  replica (`base_sql/2`), priced against each assigned supplier via
  `RateEngine.assigned_expected/1` (origin-pinned expected + priced flag), batch-
  upserted on `:waybill_obj`, then `roll_month/2` re-aggregates that month's
  insight_rollups straight from the facts (day → month → year consistent; the
  "No rate" count excludes own-fleet). `refresh(:full)` and the rolling `:window`
  work.

  `fwt_waybill` has NO row-modified timestamp (the wb-modified-cols / wb-all-cols
  probes: all 126 date columns are business dates). So change detection is three
  layers: (1) the rolling `:window` (current + previous year, re-summed every tick)
  catches recent churn; (2) `changed_periods/1` high-waters `fwt_status_history`
  (mnemonic `'fwtwb'`, `created_date_time`, marker in `insight_etl_state`) to catch
  new / late-posted / backdated waybills landing in OLD years; (3) a periodic
  `refresh(:full)` (scheduled less often) is the backstop for SILENT total_cost /
  fwt_contractor_charge edits — neither table carries a modified timestamp.

  Not compiled locally (all mix runs go through the runner). The OpenEdge timestamp
  literal in `changed_periods/1` and that query's runtime need live /_inspect
  validation (WB-EVENTS-5). Do NOT enable the Cron tick or trust output until then.
  """
  require Logger

  import Ecto.Query

  alias TragarAi.Insight.Db
  alias TragarAi.Insight.EtlState
  alias TragarAi.Insight.RateEngine
  alias TragarAi.Insight.Rollup
  alias TragarAi.Insight.WaybillCost
  alias TragarAi.Repo

  @from_year 2016
  @to_year 2026

  # Rolling window the scheduled tick always re-sums: current_year/0 back through
  # current_year − (@window_years − 1) — i.e. current + previous year.
  @window_years 2

  # insert_all batch size — ≈15 cols × 1000 stays well under Postgres' 65535
  # bind-parameter ceiling.
  @chunk 1000

  # Change-detection high-water: the fwt_status_history point WaybillCostBackfill
  # has processed. Stored in insight_etl_state under this key.
  @status_hw_key "status_high_water"

  # When advancing the high-water we rewind it by this much so replica-lag / app-DB
  # clock skew can't drop an event at the boundary. build_period is idempotent, so
  # re-scanning the overlap is harmless — only ever re-work, never a miss.
  @hw_overlap_seconds 6 * 3600

  @type mode :: :full | :window
  @type stats :: %{periods: non_neg_integer(), waybills: non_neg_integer()}

  @doc """
  Refresh the fact table. `:full` rebuilds all years; `:window` rebuilds the
  rolling window plus high-water-flagged older periods. Returns `{:ok, stats}`.
  """
  @spec refresh(mode()) :: {:ok, stats()} | {:error, term()}
  def refresh(:full) do
    periods = for y <- @from_year..@to_year, m <- 1..12, do: {y, m}
    run(periods)
  end

  def refresh(:window) do
    cy = current_year()
    lo = max(@from_year, cy - (@window_years - 1))
    window = for y <- lo..cy, m <- 1..12, do: {y, m}

    # Capture the cutoff BEFORE processing; events logged during the run land after
    # it and are caught next tick. Advance the high-water only on a clean run.
    started = DateTime.utc_now() |> DateTime.truncate(:second)
    old_hw = EtlState.get_time(@status_hw_key)

    with {:ok, older} <- changed_periods(old_hw),
         {:ok, stats} <- run(Enum.uniq(window ++ older)) do
      EtlState.put_time(@status_hw_key, DateTime.add(started, -@hw_overlap_seconds, :second))
      {:ok, stats}
    end
  end

  # Price + upsert each period, tallying periods and waybills touched. A single
  # period's failure aborts the run (returns {:error, _}) so the worker can retry
  # deliberately rather than leave a half-built window.
  defp run(periods) do
    Enum.reduce_while(periods, {:ok, %{periods: 0, waybills: 0}}, fn {y, m}, {:ok, acc} ->
      case build_period(y, m) do
        {:ok, n} ->
          {:cont, {:ok, %{acc | periods: acc.periods + 1, waybills: acc.waybills + n}}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  # ── Phase 2: per-period build ───────────────────────────────────────────────
  # Build one (year, month): pull every waybill's header + aggregated buy +
  # own-fleet signal from the replica (base_sql/2), price each against its assigned
  # supplier via RateEngine.assigned_expected/1 (origin-pinned expected + priced
  # flag), then batch-upsert one row per waybill on :waybill_obj. own_fleet = the
  # waybill raised no fwt_contractor_charge (LEFT JOIN → 0 charges). Returns
  # {:ok, waybills_written}.
  @spec build_period(pos_integer(), pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp build_period(y, m) do
    where = "YEAR(w.waybill_date) = #{y} AND MONTH(w.waybill_date) = #{m}"

    with {:ok, rows} <- Db.query_rows(base_sql(y, m)),
         {:ok, priced} <- RateEngine.assigned_expected(where) do
      exp = Map.new(priced, &{&1.waybill_obj, &1.expected})
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      rows
      |> Enum.map(&fact_row(&1, exp, now))
      |> upsert_all()

      # Cascade: re-roll this month's insight_rollups straight from the facts we
      # just wrote, so day → month → year stay consistent by construction.
      roll_month(y, m)

      {:ok, length(rows)}
    end
  end

  # Every waybill in the month with its drill dimensions, its actual buy
  # (Σ contractor charges), and a charge COUNT — 0 = own fleet. LEFT JOIN so
  # own-fleet waybills (no charge) are kept; sell is the waybill's own total_cost,
  # grouped on so the charge join never fans it out.
  defp base_sql(y, m) do
    "SELECT w.waybill_obj AS obj, w.waybill_number AS num, w.waybill_date AS d, " <>
      "w.account_name AS acct, w.rate_area_from_code AS frm, " <>
      "w.rate_area_to_code AS too, w.contractor_reference AS ref, " <>
      "w.total_cost AS sell, SUM(cc.total_charge_amount) AS buy, " <>
      "COUNT(cc.waybill_obj) AS charges " <>
      "FROM PUB.fwt_waybill w " <>
      "LEFT JOIN PUB.fwt_contractor_charge cc ON cc.waybill_obj = w.waybill_obj " <>
      "WHERE YEAR(w.waybill_date) = #{y} AND MONTH(w.waybill_date) = #{m} " <>
      "GROUP BY w.waybill_obj, w.waybill_number, w.waybill_date, w.account_name, " <>
      "w.rate_area_from_code, w.rate_area_to_code, w.contractor_reference, w.total_cost"
  end

  # One replica row → one insert_all map. expected is nil (not 0) when the assigned
  # supplier had no origin-area rate — the uncosted signal, distinct from a genuine
  # R0. priced = the waybill got an expected; own_fleet = no charge rows.
  defp fact_row(r, exp, now) do
    obj = r["obj"]
    sell = to_dec(r["sell"])
    buy = to_dec(r["buy"])

    {expected, priced} =
      case Map.fetch(exp, obj) do
        {:ok, x} -> {Decimal.from_float(Float.round(x, 2)), true}
        :error -> {nil, false}
      end

    %{
      waybill_obj: obj,
      waybill_number: r["num"],
      waybill_date: to_date(r["d"]),
      account_name: r["acct"],
      rate_area_from_code: r["frm"],
      rate_area_to_code: r["too"],
      contractor_reference: blank_to_nil(r["ref"]),
      sell: sell,
      buy: buy,
      expected: expected,
      priced: priced,
      own_fleet: int(r["charges"]) == 0,
      margin: Decimal.sub(sell, buy),
      inserted_at: now,
      updated_at: now
    }
  end

  # Columns replaced on conflict — everything but the key (:waybill_obj) and
  # :inserted_at (kept from the first insert).
  @replace ~w(waybill_number waybill_date account_name rate_area_from_code
              rate_area_to_code contractor_reference sell buy expected priced
              own_fleet margin updated_at)a

  defp upsert_all([]), do: :ok

  defp upsert_all(rows) do
    rows
    |> Enum.chunk_every(@chunk)
    |> Enum.each(fn chunk ->
      Repo.insert_all(WaybillCost, chunk,
        on_conflict: {:replace, @replace},
        conflict_target: [:waybill_obj]
      )
    end)
  end

  # ── month rollup cascade (insight_rollups from the fact table) ───────────────
  # After a month's per-waybill facts are rebuilt, re-aggregate the WAYBILL-KEYED
  # grains (enterprise / client / lane) of insight_rollups for that month straight
  # from insight_waybill_costs — so month (and the year that sums it) can never
  # disagree with the waybills beneath, and the "No rate" count becomes a stored
  # number that EXCLUDES own fleet (own_fleet and priced are disjoint: RateEngine
  # prices via an INNER join to the charge, so an own-fleet waybill is never priced).
  #
  # The CONTRACTOR grain is deliberately NOT touched: it's charge-keyed and multi-
  # supplier (a waybill's cost splits across its legs' suppliers), which the one-
  # supplier-per-waybill fact table can't reproduce — Backfill.run_contractor owns it.
  #
  # Delete-then-insert is scoped to the month + these three grains, so a dimension
  # that lost all its waybills drops out. Guarded on a non-empty month: if the fact
  # table has no rows for the month (e.g. before the initial :full seed) we leave
  # insight_rollups untouched rather than wiping it.
  defp roll_month(y, m) do
    period = Date.new!(y, m, 1)
    first = period
    last = Date.end_of_month(period)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      enterprise_agg(first, last, period, now) ++
        grouped_agg(first, last, :account_name, "client", period, now) ++
        grouped_agg(first, last, :rate_area_to_code, "lane", period, now)

    if rows == [] do
      :ok
    else
      Repo.transaction(fn ->
        Repo.delete_all(
          from(r in Rollup,
            where: r.period_month == ^period and r.grain in ["enterprise", "client", "lane"]
          )
        )

        rows
        |> Enum.chunk_every(@chunk)
        |> Enum.each(&Repo.insert_all(Rollup, &1))
      end)

      :ok
    end
  end

  # Enterprise grain: one aggregate over the whole month, or [] if the month is empty.
  defp enterprise_agg(first, last, period, now) do
    from(c in WaybillCost,
      where: c.waybill_date >= ^first and c.waybill_date <= ^last,
      select: %{
        waybills: count(c.waybill_obj),
        sell: sum(c.sell),
        buy: sum(c.buy),
        expected_buy: sum(coalesce(c.expected, 0)),
        priced_buy: sum(fragment("CASE WHEN ? THEN ? ELSE 0 END", c.priced, c.buy)),
        priced_waybills: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", c.priced)),
        own_fleet_waybills: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", c.own_fleet))
      }
    )
    |> Repo.one()
    |> case do
      %{waybills: n} = a when is_integer(n) and n > 0 ->
        [rollup_map(period, "enterprise", "all", "Enterprise", a, now)]

      _ ->
        []
    end
  end

  # A dimensional grain keyed on `field` of the fact row. NULL/blank dimension values
  # collapse to "(unknown)" IN the GROUP BY so they merge into one row (matching the
  # rollup's unique (month, grain, dim_key) — two blank variants must not collide).
  defp grouped_agg(first, last, field, grain, period, now) do
    from(c in WaybillCost,
      where: c.waybill_date >= ^first and c.waybill_date <= ^last,
      group_by: fragment("COALESCE(NULLIF(?, ''), '(unknown)')", field(c, ^field)),
      select: %{
        dim: fragment("COALESCE(NULLIF(?, ''), '(unknown)')", field(c, ^field)),
        waybills: count(c.waybill_obj),
        sell: sum(c.sell),
        buy: sum(c.buy),
        expected_buy: sum(coalesce(c.expected, 0)),
        priced_buy: sum(fragment("CASE WHEN ? THEN ? ELSE 0 END", c.priced, c.buy)),
        priced_waybills: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", c.priced)),
        own_fleet_waybills: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", c.own_fleet))
      }
    )
    |> Repo.all()
    |> Enum.map(fn %{dim: dim} = a -> rollup_map(period, grain, dim, dim, a, now) end)
  end

  # One aggregate → an insert_all-ready rollup map. surcharges stays 0 (folded into
  # buy elsewhere); margin = sell − buy.
  defp rollup_map(period, grain, dim_key, dim_label, a, now) do
    sell = a.sell || Decimal.new(0)
    buy = a.buy || Decimal.new(0)

    %{
      period_month: period,
      grain: grain,
      dim_key: dim_key,
      dim_label: dim_label,
      waybills: a.waybills || 0,
      sell: sell,
      buy: buy,
      expected_buy: a.expected_buy || Decimal.new(0),
      priced_buy: a.priced_buy || Decimal.new(0),
      priced_waybills: a.priced_waybills || 0,
      own_fleet_waybills: a.own_fleet_waybills || 0,
      surcharges: Decimal.new(0),
      margin: Decimal.sub(sell, buy),
      inserted_at: now,
      updated_at: now
    }
  end

  # Older periods (outside the rolling window) whose waybills had a status-event
  # since the stored high-water. fwt_waybill itself has no modified timestamp, but
  # fwt_status_history is a per-change audit feed — polymorphic on
  # (owning_entity_mnemonic, owning_obj); the waybill mnemonic is 'fwtwb' and
  # owning_obj = waybill_obj. So a waybill posted/backdated/re-statused into an OLD
  # year carries a RECENT created_date_time here, and we re-`build_period` exactly
  # those months — which the rolling window alone would miss.
  #
  # Limits (why the periodic :full rebuild still matters): status_history logs
  # STATUS changes + lifecycle, not SILENT total_cost / fwt_contractor_charge edits
  # (that table has no timestamp either), so a quiet re-rate of an old waybill is
  # only caught by :full. And nil high-water (first ever tick) returns [] — the
  # window covers recent, :full seeds history, and refresh/1 sets the baseline
  # after. Any query error degrades to [] so a status-history hiccup never fails
  # the whole refresh.
  @spec changed_periods(DateTime.t() | nil) :: {:ok, [{pos_integer(), pos_integer()}]}
  defp changed_periods(nil), do: {:ok, []}

  defp changed_periods(%DateTime{} = hw) do
    sql =
      "SELECT DISTINCT YEAR(w.waybill_date) AS yr, MONTH(w.waybill_date) AS mo " <>
        "FROM PUB.fwt_status_history sh " <>
        "JOIN PUB.fwt_waybill w ON w.waybill_obj = sh.owning_obj " <>
        "WHERE sh.owning_entity_mnemonic = 'fwtwb' " <>
        "AND sh.created_date_time > '#{fmt_ts(hw)}'"

    case Db.query_rows(sql) do
      {:ok, rows} ->
        {:ok,
         rows
         |> Enum.map(&{int(&1["yr"]), int(&1["mo"])})
         |> Enum.reject(fn {y, m} -> y == 0 or m == 0 end)}

      {:error, reason} ->
        Logger.warning("[insight.warehouse] changed_periods degraded to []: #{inspect(reason)}")
        {:ok, []}
    end
  end

  # OpenEdge SQL timestamp literal (validate the exact accepted form live before
  # trusting — see the WB-EVENTS-5 /_inspect card).
  defp fmt_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  # The rolling window's upper bound — the actual current year, so the window
  # tracks the calendar (2016..@to_year still bound the :full rebuild).
  defp current_year, do: Date.utc_today().year

  # ── coercion (Db returns string cells) ───────────────────────────────────────
  defp to_dec(nil), do: Decimal.new(0)
  defp to_dec(""), do: Decimal.new(0)
  defp to_dec(%Decimal{} = d), do: d

  defp to_dec(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, _} -> d
      :error -> Decimal.new(0)
    end
  end

  defp int(nil), do: 0
  defp int(""), do: 0
  defp int(n) when is_integer(n), do: n

  defp int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_date(%Date{} = d), do: d

  defp to_date(s) when is_binary(s) do
    case Date.from_iso8601(String.slice(s, 0, 10)) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s
end
