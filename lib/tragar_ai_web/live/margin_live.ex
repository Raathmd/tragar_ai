defmodule TragarAiWeb.MarginLive do
  @moduledoc """
  Management margin dashboard — the monthly sell / buy / margin trend across the
  whole history, read from the `insight_rollups` warehouse (enterprise grain).

  This is the first "charts and graphs" surface of the intelligence platform;
  drill-down by customer / supplier / lane follows once those grains are backfilled.
  """
  use TragarAiWeb, :live_view

  import Ecto.Query

  alias TragarAi.Insight.Rollup
  alias TragarAi.Repo

  @impl true
  def mount(_params, _session, socket) do
    rows =
      Repo.all(
        from r in Rollup,
          where: r.grain == "enterprise",
          order_by: [asc: r.period_month]
      )

    totals = totals(rows)
    max_margin = rows |> Enum.map(&to_f(&1.margin)) |> Enum.max(fn -> 0.0 end)

    {:ok,
     socket
     |> assign(:active, :margin)
     |> assign(:rows, Enum.reverse(rows))
     |> assign(:totals, totals)
     |> assign(:chart, build_chart(rows))
     |> assign(:max_margin, max(max_margin, 1.0))}
  end

  # ── Server-rendered SVG chart: sell (green) and buy (red) lines over the months;
  # the shaded gap between them is the margin. No JS/chart deps.
  @chart_w 960
  @chart_h 240
  @chart_pad_x 8
  @chart_pad_top 10
  @chart_pad_bottom 22

  defp build_chart([]), do: nil

  defp build_chart(rows) do
    n = length(rows)
    ymax = rows |> Enum.map(&to_f(&1.sell)) |> Enum.max(fn -> 1.0 end) |> max(1.0)
    plot_w = @chart_w - 2 * @chart_pad_x
    plot_h = @chart_h - @chart_pad_top - @chart_pad_bottom

    coord = fn i, v ->
      x = @chart_pad_x + if(n > 1, do: i / (n - 1) * plot_w, else: plot_w / 2)
      y = @chart_pad_top + (1.0 - min(v / ymax, 1.0)) * plot_h
      {Float.round(x, 1), Float.round(y, 1)}
    end

    sell = pts(rows, &to_f(&1.sell), coord)
    buy = pts(rows, &to_f(&1.buy), coord)

    ticks =
      rows
      |> Enum.with_index()
      |> Enum.filter(fn {r, _} -> match?(%Date{month: 1}, r.period_month) end)
      |> Enum.map(fn {r, i} -> {elem(coord.(i, 0.0), 0), r.period_month.year} end)

    %{
      sell: polyline(sell),
      buy: polyline(buy),
      area: polyline(sell) <> " " <> polyline(Enum.reverse(buy)),
      ticks: ticks,
      peak: money(ymax),
      baseline: @chart_h - @chart_pad_bottom
    }
  end

  defp pts(rows, fun, coord) do
    rows |> Enum.with_index() |> Enum.map(fn {r, i} -> coord.(i, fun.(r)) end)
  end

  defp polyline(points), do: points |> Enum.map(fn {x, y} -> "#{x},#{y}" end) |> Enum.join(" ")

  defp totals(rows) do
    sell = sum(rows, & &1.sell)
    buy = sum(rows, & &1.buy)
    margin = sell - buy

    %{
      months: length(rows),
      waybills: Enum.reduce(rows, 0, fn r, a -> a + (r.waybills || 0) end),
      sell: sell,
      buy: buy,
      margin: margin,
      margin_pct: pct(margin, sell)
    }
  end

  defp sum(rows, fun), do: Enum.reduce(rows, 0.0, fn r, a -> a + to_f(fun.(r)) end)

  defp to_f(nil), do: 0.0
  defp to_f(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_f(n) when is_number(n), do: n * 1.0

  defp pct(_num, denom) when denom in [0, 0.0], do: 0.0
  defp pct(num, denom), do: Float.round(num / denom * 100, 1)

  defp money(v) do
    f = to_f(v)
    abs_f = abs(f)

    cond do
      abs_f >= 1_000_000 -> "R#{Float.round(f / 1_000_000, 2)}M"
      abs_f >= 1_000 -> "R#{Float.round(f / 1_000, 1)}k"
      true -> "R#{Float.round(f, 0)}"
    end
  end

  defp month_label(%Date{} = d), do: Calendar.strftime(d, "%Y-%m")
  defp month_label(_), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl p-4">
      <h1 class="mb-1 text-lg font-semibold">Margin — enterprise</h1>
      <p class="mb-4 text-sm opacity-60">
        Monthly sell vs contractor buy across the history. Margin = sell − buy
        (buy is contractor cost only; own-fleet deliveries carry no buy).
      </p>

      <div class="mb-5 grid grid-cols-2 gap-3 sm:grid-cols-5">
        <div class="rounded border p-3">
          <div class="text-xs opacity-60">Months</div>
          <div class="text-lg font-semibold">{@totals.months}</div>
        </div>
        <div class="rounded border p-3">
          <div class="text-xs opacity-60">Sell</div>
          <div class="text-lg font-semibold">{money(@totals.sell)}</div>
        </div>
        <div class="rounded border p-3">
          <div class="text-xs opacity-60">Buy</div>
          <div class="text-lg font-semibold">{money(@totals.buy)}</div>
        </div>
        <div class="rounded border p-3">
          <div class="text-xs opacity-60">Margin</div>
          <div class="text-lg font-semibold">{money(@totals.margin)}</div>
        </div>
        <div class="rounded border p-3">
          <div class="text-xs opacity-60">Margin %</div>
          <div class="text-lg font-semibold">{@totals.margin_pct}%</div>
        </div>
      </div>

      <div :if={@chart} class="mb-5 rounded border p-3">
        <div class="mb-2 flex flex-wrap items-center gap-4 text-xs">
          <span class="flex items-center gap-1">
            <span class="inline-block h-2 w-3 rounded" style="background: rgb(34,197,94)"></span>
            Sell
          </span>
          <span class="flex items-center gap-1">
            <span class="inline-block h-2 w-3 rounded" style="background: rgb(239,68,68)"></span>
            Buy
          </span>
          <span class="opacity-60">shaded gap = margin · peak {@chart.peak}/mo</span>
        </div>
        <svg viewBox="0 0 960 240" class="w-full" style="max-height:280px">
          <polygon points={@chart.area} fill="rgba(34,197,94,0.15)" />
          <polyline points={@chart.buy} fill="none" stroke="rgb(239,68,68)" stroke-width="1.5" />
          <polyline points={@chart.sell} fill="none" stroke="rgb(34,197,94)" stroke-width="1.5" />
          <text
            :for={{x, yr} <- @chart.ticks}
            x={x}
            y={@chart.baseline + 14}
            font-size="9"
            text-anchor="middle"
            fill="currentColor"
            opacity="0.5"
          >{yr}</text>
        </svg>
      </div>

      <div class="overflow-x-auto">
        <table class="table table-sm w-full">
          <thead>
            <tr>
              <th>Month</th>
              <th class="text-right">Waybills</th>
              <th class="text-right">Sell</th>
              <th class="text-right">Buy</th>
              <th class="text-right">Margin</th>
              <th class="text-right">Margin %</th>
              <th class="w-40">Trend</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={r <- @rows}>
              <td class="whitespace-nowrap font-mono text-xs">{month_label(r.period_month)}</td>
              <td class="text-right">{r.waybills}</td>
              <td class="text-right">{money(r.sell)}</td>
              <td class="text-right">{money(r.buy)}</td>
              <td class="text-right">{money(r.margin)}</td>
              <td class="text-right">{pct(to_f(r.margin), to_f(r.sell))}%</td>
              <td>
                <div
                  class="h-2 rounded bg-primary"
                  style={"width: #{bar(to_f(r.margin), @max_margin)}%"}
                >
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <p :if={@rows == []} class="mt-4 text-sm opacity-60">
        No rollups yet — run the backfill.
      </p>
    </div>
    """
  end

  defp bar(v, max) when max > 0, do: Float.round(max(v, 0.0) / max * 100, 1)
  defp bar(_v, _max), do: 0.0
end
