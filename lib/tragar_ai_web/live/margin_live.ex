defmodule TragarAiWeb.MarginLive do
  @moduledoc """
  Management margin dashboard over the `insight_rollups` warehouse, with drill-down
  by grain (enterprise / client / lane / contractor): the enterprise sell-vs-buy
  line chart, a revenue-share pie, and a margin-ranked table per dimension.
  """
  use TragarAiWeb, :live_view

  import Ecto.Query

  alias TragarAi.Insight.Predict
  alias TragarAi.Insight.Rollup
  alias TragarAi.Repo

  @grains ~w(enterprise client lane contractor)
  @pie_colors ~w(#22c55e #3b82f6 #f59e0b #ef4444 #a855f7 #14b8a6 #eab308 #ec4899 #94a3b8)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active, :margin)
     |> assign(:ai_answer, "")
     |> assign(:ai_running, false)
     |> assign(:ai_prompt, "")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    grain = if params["grain"] in @grains, do: params["grain"], else: "enterprise"
    year = parse_year(params["year"])
    {:noreply, socket |> assign(:year, year) |> load(grain, year)}
  end

  @impl true
  def handle_event("explain", _params, socket) do
    {:noreply, start_ai(socket, explain_prompt(socket.assigns))}
  end

  def handle_event("ai_send", %{"prompt" => prompt}, socket) do
    {:noreply, start_ai(socket, prompt)}
  end

  @impl true
  def handle_info({:ai_chunk, chunk}, socket) do
    {:noreply, assign(socket, :ai_answer, socket.assigns.ai_answer <> chunk)}
  end

  def handle_info(:ai_done, socket), do: {:noreply, assign(socket, :ai_running, false)}

  # Streams an explanation from the in-app model (Claude on the Tragar account, or
  # the local model) grounded in the current view's numbers. The answer renders in
  # this LiveView — the data reaches the app's model, never the dev session.
  defp start_ai(socket, prompt) do
    lv = self()

    Task.Supervisor.start_child(TragarAi.TaskSupervisor, fn ->
      TragarAi.CoreAI.reason(prompt, %{}, fn chunk -> send(lv, {:ai_chunk, chunk}) end)
      send(lv, :ai_done)
    end)

    socket
    |> assign(:ai_prompt, prompt)
    |> assign(:ai_answer, "")
    |> assign(:ai_running, true)
  end

  defp explain_prompt(assigns) do
    "You are Tragar's freight margin analyst. Based ONLY on this data, give a concise " <>
      "situational and predictive outlook in 3–5 sentences:\n\n" <> view_context(assigns)
  end

  defp view_context(a) do
    t = a.totals

    base =
      "Grain #{a.grain}#{year_note(a)}. #{t.label}: #{t.count}. " <>
        "Sell #{money(t.sell)}, Buy #{money(t.buy)}. " <>
        "Margin #{money(t.margin)} (#{t.margin_pct}%)."

    base <> forecast_note(a) <> risk_note(a) <> flags_note(a)
  end

  defp year_note(%{year: y}) when is_integer(y), do: " (year #{y})"
  defp year_note(_), do: ""

  defp forecast_note(%{forecast: %{} = f}) do
    " Forecast: margin% trend #{f.slope}/mo, projected #{f.projected_pct}% in 6 months."
  end

  defp forecast_note(_), do: ""

  defp risk_note(%{at_risk: [_ | _] = risks}) do
    " At risk: " <> Enum.map_join(Enum.take(risks, 5), "; ", &risk_item/1)
  end

  defp risk_note(_), do: ""

  defp risk_item(r), do: "#{r.dim} #{r.latest_pct}%->#{r.projected_pct}%"

  defp flags_note(%{exceptions: [_ | _] = ex}) do
    " Rate flags: " <> Enum.map_join(Enum.take(ex, 5), "; ", &flag_item/1)
  end

  defp flags_note(_), do: ""

  defp flag_item(e), do: "#{e.dim} #{Float.round(e.margin_pct, 1)}% (#{e.reason})"

  @years 2016..2026

  defp parse_year(y) do
    case Integer.parse(to_string(y || "")) do
      {n, _} -> if n in @years, do: n, else: nil
      :error -> nil
    end
  end

  defp year_where(query, nil), do: query

  defp year_where(query, year) do
    from r in query,
      where:
        r.period_month >= ^Date.new!(year, 1, 1) and
          r.period_month <= ^Date.new!(year, 12, 31)
  end

  defp margin_path(grain, year) do
    q = if year, do: [grain: grain, year: year], else: [grain: grain]
    "/margin?" <> URI.encode_query(q)
  end

  defp load(socket, "enterprise", year) do
    rows =
      from(r in Rollup, where: r.grain == "enterprise")
      |> year_where(year)
      |> order_by([r], asc: r.period_month)
      |> Repo.all()

    max_margin = rows |> Enum.map(&to_f(&1.margin)) |> Enum.max(fn -> 1.0 end) |> max(1.0)
    sell = sum(rows, & &1.sell)
    buy = sum(rows, & &1.buy)

    socket
    |> assign(:grain, "enterprise")
    |> assign(:rows, Enum.reverse(rows))
    |> assign(:totals, totals(length(rows), "Months", sell, buy))
    |> assign(:chart, build_chart(rows))
    |> assign(:max_val, max_margin)
    |> assign(:ranked, [])
    |> assign(:pie, [])
    |> assign(:unattributed, nil)
    |> assign(:forecast, Predict.trend("enterprise"))
    |> assign(:at_risk, [])
    |> assign(:exceptions, [])
  end

  defp load(socket, grain, year) do
    all_dims =
      from(r in Rollup, where: r.grain == ^grain)
      |> year_where(year)
      |> group_by([r], r.dim_key)
      |> select([r], %{
        dim: r.dim_key,
        sell: sum(r.sell),
        buy: sum(r.buy),
        waybills: sum(r.waybills)
      })
      |> Repo.all()
      |> Enum.map(&dim_metrics/1)

    # "(unknown)" = waybills with a blank dimension column; keep it out of the pie
    # and ranked table (it's a data-quality bucket, not a real dimension) but show
    # its size so it's not silently hidden.
    {unknown, dims} = Enum.split_with(all_dims, &(&1.dim == "(unknown)"))

    # Contractor is a cost view (sell = 0) → rank & pie by buy; others by margin/sell.
    {sort_fun, pie_fun} =
      if grain == "contractor", do: {& &1.buy, & &1.buy}, else: {& &1.margin, & &1.sell}

    ranked = Enum.sort_by(dims, sort_fun, :desc)
    max_abs = ranked |> Enum.map(&abs(sort_fun.(&1))) |> Enum.max(fn -> 1.0 end) |> max(1.0)
    sell = Enum.reduce(all_dims, 0.0, &(&2 + &1.sell))
    buy = Enum.reduce(all_dims, 0.0, &(&2 + &1.buy))

    socket
    |> assign(:grain, grain)
    |> assign(:rows, [])
    |> assign(:totals, totals(length(dims), "Dimensions", sell, buy))
    |> assign(:chart, nil)
    |> assign(:max_val, max_abs)
    |> assign(:ranked, Enum.take(ranked, 60))
    |> assign(:pie, build_pie(dims, pie_fun))
    |> assign(:unattributed, unattributed(unknown))
    |> assign(:forecast, nil)
    |> assign(:at_risk, at_risk_for(grain))
    |> assign(:exceptions, exceptions_for(grain))
  end

  # Margin-% erosion / rate-quality flags only make sense where sell is attributed
  # (client/lane); the contractor grain is a pure cost view.
  defp at_risk_for(grain) when grain in ["client", "lane"], do: Predict.at_risk(grain)
  defp at_risk_for(_grain), do: []

  defp exceptions_for(grain) when grain in ["client", "lane"], do: Predict.exceptions(grain)
  defp exceptions_for(_grain), do: []

  defp unattributed([]), do: nil

  defp unattributed(unknown) do
    %{
      sell: Enum.reduce(unknown, 0.0, &(&2 + &1.sell)),
      margin: Enum.reduce(unknown, 0.0, &(&2 + &1.margin))
    }
  end

  defp totals(count, label, sell, buy) do
    %{
      count: count,
      label: label,
      sell: sell,
      buy: buy,
      margin: sell - buy,
      margin_pct: pct(sell - buy, sell)
    }
  end

  defp dim_metrics(%{dim: dim, sell: sell, buy: buy, waybills: wb}) do
    s = to_f(sell)
    b = to_f(buy)

    %{
      dim: dim || "(unknown)",
      sell: s,
      buy: b,
      margin: s - b,
      margin_pct: pct(s - b, s),
      waybills: wb || 0
    }
  end

  # ── revenue-share pie (top 8 dimensions by sell + others) ──────────────────
  defp build_pie(dims, value_fun) do
    sorted = dims |> Enum.map(&{&1.dim, value_fun.(&1)}) |> Enum.sort_by(&elem(&1, 1), :desc)
    {top, rest} = Enum.split(sorted, 8)
    others = rest |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    items = if others > 0, do: top ++ [{"(others)", others}], else: top
    total = items |> Enum.map(&elem(&1, 1)) |> Enum.sum() |> max(1.0)

    {slices, _} =
      items
      |> Enum.with_index()
      |> Enum.map_reduce(0.0, fn {{label, v}, i}, acc ->
        slice = %{
          label: label,
          pct: Float.round(v / total * 100, 1),
          path: arc_path(acc / total, (acc + v) / total),
          color: Enum.at(@pie_colors, rem(i, length(@pie_colors)))
        }

        {slice, acc + v}
      end)

    slices
  end

  defp arc_path(f0, f1) do
    a0 = f0 * 2 * :math.pi()
    a1 = min(f1, 0.9999) * 2 * :math.pi()
    {cx, cy, r} = {90, 90, 82}
    x0 = cx + r * :math.sin(a0)
    y0 = cy - r * :math.cos(a0)
    x1 = cx + r * :math.sin(a1)
    y1 = cy - r * :math.cos(a1)
    large = if a1 - a0 > :math.pi(), do: 1, else: 0
    "M #{cx} #{cy} L #{ff(x0)} #{ff(y0)} A #{r} #{r} 0 #{large} 1 #{ff(x1)} #{ff(y1)} Z"
  end

  defp ff(x), do: :erlang.float_to_binary(x * 1.0, decimals: 1)

  # ── enterprise sell/buy line chart ─────────────────────────────────────────
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

  # ── formatting ─────────────────────────────────────────────────────────────
  defp sum(rows, fun), do: Enum.reduce(rows, 0.0, fn r, a -> a + to_f(fun.(r)) end)

  defp to_f(nil), do: 0.0
  defp to_f(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_f(n) when is_number(n), do: n * 1.0

  defp pct(_num, denom) when denom in [0, 0.0], do: 0.0
  defp pct(num, denom), do: Float.round(num / denom * 100, 1)

  defp money(v) do
    f = to_f(v)
    a = abs(f)

    cond do
      a >= 1_000_000 -> "R#{Float.round(f / 1_000_000, 2)}M"
      a >= 1_000 -> "R#{Float.round(f / 1_000, 1)}k"
      true -> "R#{Float.round(f, 0)}"
    end
  end

  defp month_label(%Date{} = d), do: Calendar.strftime(d, "%Y-%m")
  defp month_label(_), do: "—"

  defp bar(v, max) when max > 0, do: Float.round(abs(v) / max * 100, 1)
  defp bar(_v, _max), do: 0.0

  defp bar_value(d, "contractor"), do: d.buy
  defp bar_value(d, _), do: d.margin

  defp bar_color(_d, "contractor"), do: "bg-primary"
  defp bar_color(d, _), do: (d.margin < 0 && "bg-error") || "bg-primary"

  defp tab_cls(active, g) do
    ["tab text-sm font-medium", (active == g && "tab-active") || ""]
  end

  defp year_cls(active, y) do
    ["btn btn-xs", (active == y && "btn-primary") || "btn-ghost"]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl p-4">
      <h1 class="mb-1 text-lg font-semibold">Margin</h1>
      <p class="mb-3 text-sm opacity-60">
        Sell vs contractor buy; margin = sell − buy. Drill down by dimension.
      </p>

      <div class="mb-4 text-xs opacity-60">Drill down by</div>
      <div role="tablist" class="tabs tabs-lg tabs-boxed mb-4 w-fit bg-base-200">
        <.link
          patch={margin_path("enterprise", @year)}
          role="tab"
          class={tab_cls(@grain, "enterprise")}
        >
          Enterprise
        </.link>
        <.link patch={margin_path("client", @year)} role="tab" class={tab_cls(@grain, "client")}>
          Client
        </.link>
        <.link patch={margin_path("lane", @year)} role="tab" class={tab_cls(@grain, "lane")}>
          Lane
        </.link>
        <.link
          patch={margin_path("contractor", @year)}
          role="tab"
          class={tab_cls(@grain, "contractor")}
        >
          Contractor
        </.link>
      </div>

      <div class="mb-5 flex flex-wrap items-center gap-1 text-xs">
        <span class="mr-1 opacity-60">Year:</span>
        <.link patch={margin_path(@grain, nil)} class={year_cls(@year, nil)}>All</.link>
        <.link :for={y <- 2016..2026} patch={margin_path(@grain, y)} class={year_cls(@year, y)}>
          {y}
        </.link>
      </div>

      <div class="mb-5 grid grid-cols-2 gap-3 sm:grid-cols-5">
        <div class="rounded border p-3">
          <div class="text-xs opacity-60">{@totals.label}</div>
          <div class="text-lg font-semibold">{@totals.count}</div>
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

      <div :if={@forecast} class="mb-5 rounded border p-3 text-sm">
        <span class="font-medium">Forecast (Nx):</span>
        margin % trend {@forecast.slope} pts/mo · latest {@forecast.latest_pct}% · projected {@forecast.projected_pct}% in 6 months.
      </div>

      <div :if={@chart} class="mb-5 rounded border p-3">
        <div class="mb-2 flex flex-wrap items-center gap-4 text-xs">
          <span class="flex items-center gap-1">
            <span class="inline-block h-2 w-3 rounded" style="background: rgb(34,197,94)"></span> Sell
          </span>
          <span class="flex items-center gap-1">
            <span class="inline-block h-2 w-3 rounded" style="background: rgb(239,68,68)"></span> Buy
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
          >
            {yr}
          </text>
        </svg>
      </div>

      <div :if={@pie != []} class="mb-5 flex flex-col gap-4 rounded border p-3 sm:flex-row">
        <svg viewBox="0 0 180 180" class="w-44 shrink-0">
          <path :for={s <- @pie} d={s.path} fill={s.color} stroke="white" stroke-width="0.5" />
        </svg>
        <div class="flex-1">
          <div class="mb-1 text-xs font-medium opacity-70">Revenue share</div>
          <div class="grid grid-cols-1 gap-1 text-xs sm:grid-cols-2">
            <div :for={s <- @pie} class="flex items-center gap-2">
              <span
                class="inline-block h-2 w-3 shrink-0 rounded"
                style={"background: #{s.color}"}
              >
              </span>
              <span class="truncate">{s.label}</span>
              <span class="ml-auto opacity-60">{s.pct}%</span>
            </div>
          </div>
        </div>
      </div>

      <div :if={@at_risk != []} class="mb-4 rounded border border-error p-3">
        <div class="mb-2 text-sm font-medium">
          Margin at risk (Nx) — steepest {@grain} declines
        </div>
        <div class="grid grid-cols-1 gap-1 text-xs sm:grid-cols-2">
          <div :for={a <- @at_risk} class="flex items-center gap-2">
            <span class="max-w-xs truncate">{a.dim}</span>
            <span class="ml-auto opacity-70">{a.latest_pct}% → {a.projected_pct}%</span>
            <span class="w-16 text-right text-error">{a.slope}/mo</span>
          </div>
        </div>
      </div>

      <div :if={@exceptions != []} class="mb-4 rounded border border-warning p-3">
        <div class="mb-2 text-sm font-medium">
          Rate flags (Nx) — loss-making & margin outliers ({@grain})
        </div>
        <div class="grid grid-cols-1 gap-1 text-xs sm:grid-cols-2">
          <div :for={e <- @exceptions} class="flex items-center gap-2">
            <span class="max-w-xs truncate">{e.dim}</span>
            <span class="ml-auto opacity-70">{Float.round(e.margin_pct, 1)}%</span>
            <span class="w-28 text-right text-warning">{e.reason}</span>
          </div>
        </div>
      </div>

      <p :if={@unattributed} class="mb-2 text-xs opacity-60">
        Unattributed (blank {@grain}): {money(@unattributed.sell)} sell, {money(@unattributed.margin)} margin — excluded from the pie & table above.
      </p>

      <div :if={@grain != "enterprise"} class="overflow-x-auto">
        <table class="table table-sm w-full">
          <thead>
            <tr>
              <th>{@grain}</th>
              <th class="text-right">Waybills</th>
              <th class="text-right">Sell</th>
              <th class="text-right">Buy</th>
              <th class="text-right">Margin</th>
              <th class="text-right">Margin %</th>
              <th class="w-32">Margin</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={d <- @ranked}>
              <td class="max-w-xs truncate">{d.dim}</td>
              <td class="text-right">{d.waybills}</td>
              <td class="text-right">{money(d.sell)}</td>
              <td class="text-right">{money(d.buy)}</td>
              <td class="text-right">{money(d.margin)}</td>
              <td class="text-right">{d.margin_pct}%</td>
              <td>
                <div
                  class={"h-2 rounded #{bar_color(d, @grain)}"}
                  style={"width: #{bar(bar_value(d, @grain), @max_val)}%"}
                >
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@grain == "enterprise"} class="overflow-x-auto">
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
                  style={"width: #{bar(to_f(r.margin), @max_val)}%"}
                >
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="mt-6 rounded border p-3">
        <div class="mb-2 text-sm font-medium">Ask the AI about these margins</div>
        <div class="mb-2">
          <button phx-click="explain" class="btn btn-primary btn-sm" disabled={@ai_running}>
            Explain this view
          </button>
        </div>
        <form phx-submit="ai_send" class="mb-2 flex gap-2">
          <input
            type="text"
            name="prompt"
            value={@ai_prompt}
            placeholder="Ask about the margins…"
            class="input input-sm input-bordered flex-1"
          />
          <button type="submit" class="btn btn-sm" disabled={@ai_running}>Send</button>
        </form>
        <div :if={@ai_running} class="mb-1 text-xs opacity-60">thinking…</div>
        <div :if={@ai_answer != ""} class="whitespace-pre-wrap rounded bg-base-200 p-3 text-sm">
          {@ai_answer}
        </div>
      </div>
    </div>
    """
  end
end
