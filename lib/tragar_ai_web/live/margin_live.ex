defmodule TragarAiWeb.MarginLive do
  @moduledoc """
  Management margin dashboard over the `insight_rollups` warehouse, with drill-down
  by grain (enterprise / client / lane / contractor): the enterprise sell-vs-buy
  line chart, a revenue-share pie, and a margin-ranked table per dimension.
  """
  use TragarAiWeb, :live_view

  import Ecto.Query

  alias TragarAi.Insight.Drill
  alias TragarAi.Insight.Predict
  alias TragarAi.Insight.Rollup
  alias TragarAi.Repo

  @grains ~w(enterprise client lane contractor)
  @pie_colors ~w(#22c55e #3b82f6 #f59e0b #ef4444 #a855f7 #14b8a6 #eab308 #ec4899 #94a3b8)

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:active, :margin)
     |> assign(:authorized, authorized?(params))
     |> assign(:token, params["token"])
     |> assign(:drill, nil)
     |> assign(:ai_answer, "")
     |> assign(:ai_running, false)
     |> assign(:ai_prompt, "")}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{authorized: false}} = socket) do
    {:noreply, socket}
  end

  def handle_params(params, _uri, socket) do
    grain = if params["grain"] in @grains, do: params["grain"], else: "enterprise"
    year = parse_year(params["year"])
    compare = parse_compare(params["compare"])

    {:noreply,
     socket
     |> assign(:year, year)
     |> assign(:compare, compare)
     |> load(grain, year, compare)
     |> assign(:drill, nil)}
  end

  # Reach /margin only with ?token=… — reuses the SAME :inspect_token as /_inspect
  # (one token for both hidden surfaces). Unset → open (dev). Not in the menu.
  defp authorized?(params) do
    case Application.get_env(:tragar_ai, :inspect_token) do
      nil -> true
      "" -> true
      token -> params["token"] == token
    end
  end

  defp parse_compare(nil), do: nil
  defp parse_compare("prev"), do: "prev"
  defp parse_compare(s), do: parse_year(s)

  @impl true
  def handle_event(_event, _params, %{assigns: %{authorized: false}} = socket) do
    {:noreply, socket}
  end

  def handle_event("explain", _params, socket) do
    {:noreply, start_ai(socket, explain_prompt(socket.assigns))}
  end

  def handle_event("ai_send", %{"prompt" => prompt}, socket) do
    {:noreply, start_ai(socket, prompt)}
  end

  def handle_event("explain_row", %{"dim" => dim}, socket) do
    row = Enum.find(socket.assigns.ranked, &(&1.dim == dim))
    grain = socket.assigns.grain
    year = socket.assigns.year

    prompt =
      if grain == "contractor" do
        contractor_row_prompt(year, row)
      else
        row_prompt(grain, year, row)
      end

    {:noreply, start_ai(socket, prompt)}
  end

  def handle_event("explain_month", %{"month" => month}, socket) do
    row = Enum.find(socket.assigns.rows, &(month_label(&1.period_month) == month))
    {:noreply, start_ai(socket, month_prompt(row))}
  end

  # ── drill-down: dimension → month → day → waybill ──────────────────────────
  # Months come from the warehouse (synchronous); days & waybills are live reads
  # of the FreightWare replica, run in a task so the LiveView stays responsive.
  def handle_event("drill_dim", %{"dim" => dim}, socket) do
    drill =
      case socket.assigns.drill do
        %{dim: ^dim, level: :months} ->
          nil

        _ ->
          %{
            dim: dim,
            level: :months,
            month: nil,
            day: nil,
            loading: false,
            error: nil,
            token: nil,
            detail: nil,
            rows: Drill.months(socket.assigns.grain, dim, socket.assigns.year)
          }
      end

    {:noreply, assign(socket, :drill, drill)}
  end

  def handle_event("drill_month", %{"v" => iso}, socket) do
    month = Date.from_iso8601!(iso)
    grain = socket.assigns.grain
    # Enterprise has no dimension row to open from; its dim_key is "all".
    dim =
      case socket.assigns.drill do
        %{dim: d} -> d
        _ -> "all"
      end

    base = %{dim: dim, level: :days, month: month, day: nil}
    {:noreply, start_drill_load(socket, base, fn -> Drill.days(grain, dim, month) end)}
  end

  def handle_event("drill_day", %{"v" => iso}, socket) do
    drill = socket.assigns.drill
    day = Date.from_iso8601!(iso)
    grain = socket.assigns.grain
    base = %{drill | level: :waybills, day: day}
    {:noreply, start_drill_load(socket, base, fn -> Drill.waybills(grain, drill.dim, day) end)}
  end

  def handle_event("waybill_detail", %{"v" => obj}, socket) do
    base = %{socket.assigns.drill | level: :detail}
    {:noreply, start_drill_load(socket, base, fn -> Drill.detail(obj) end)}
  end

  def handle_event("drill_close", _params, socket), do: {:noreply, assign(socket, :drill, nil)}

  defp start_drill_load(socket, base, fun) do
    token = make_ref()
    lv = self()

    Task.Supervisor.start_child(TragarAi.TaskSupervisor, fn ->
      send(lv, {:drill_result, token, fun.()})
    end)

    assign(
      socket,
      :drill,
      Map.merge(base, %{loading: true, rows: [], detail: nil, error: nil, token: token})
    )
  end

  @impl true
  def handle_info({:ai_chunk, chunk}, socket) do
    {:noreply, assign(socket, :ai_answer, socket.assigns.ai_answer <> chunk)}
  end

  def handle_info(:ai_done, socket), do: {:noreply, assign(socket, :ai_running, false)}

  # Apply a live drill result only if it's for the drill still on screen (the user
  # may have navigated on/closed while the FreightWare query was in flight).
  def handle_info({:drill_result, token, result}, socket) do
    case socket.assigns.drill do
      %{token: ^token} = drill ->
        drill =
          case result do
            {:ok, payload} when drill.level == :detail ->
              %{drill | loading: false, detail: payload, error: nil}

            {:ok, rows} ->
              %{drill | loading: false, rows: rows, error: nil}

            {:error, reason} ->
              %{drill | loading: false, rows: [], detail: nil, error: drill_error(reason)}
          end

        {:noreply, assign(socket, :drill, drill)}

      _ ->
        {:noreply, socket}
    end
  end

  defp drill_error(:not_select), do: "query refused"
  defp drill_error(:timeout), do: "timed out"
  defp drill_error(reason), do: inspect(reason)

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

  defp month_prompt(nil), do: "No data for that month."

  defp month_prompt(r) do
    "You are Tragar's freight margin analyst. Give a concise situational outlook " <>
      "(2–3 sentences) for #{month_label(r.period_month)}: sell #{money(r.sell)}, " <>
      "buy #{money(r.buy)}, margin #{money(r.margin)} " <>
      "(#{pct(to_f(r.margin), to_f(r.sell))}%), #{r.waybills} waybills."
  end

  defp contractor_row_prompt(_year, nil), do: "No data for that supplier."

  defp contractor_row_prompt(year, row) do
    t = Predict.cost_trend("contractor", row.dim, year)

    "You are Tragar's freight procurement analyst. Contractor \"#{row.dim}\" is a SERVICE " <>
      "PROVIDER we pay.#{year_scope(year)}: we paid them #{money(row.buy)} to move " <>
      "#{row.waybills} waybills whose customer revenue (sell) was #{money(row.sell)}, " <>
      "so the margin on the freight they carried is #{money(row.margin)} " <>
      "(#{row.margin_pct}%).#{cost_trend_note(t)} Evaluate their cost of service and the " <>
      "margin we make on their freight, and how both are trending. NOTE: a waybill can " <>
      "involve several suppliers, so this sell is the full revenue of the waybills they " <>
      "touched (not additive across suppliers). Ideally compare to other suppliers on the " <>
      "same routes (route-level comparison is a planned follow-up)."
  end

  defp cost_trend_note(nil), do: ""

  defp cost_trend_note(t) do
    dir =
      cond do
        t.slope > 0 -> "rising"
        t.slope < 0 -> "falling"
        true -> "flat"
      end

    " Monthly cost is #{dir} (#{money(abs(t.slope))}/mo), latest #{money(t.latest)}."
  end

  defp row_prompt(_grain, _year, nil), do: "No data for that row."

  defp row_prompt(grain, year, row) do
    trend = Predict.dim_trend(grain, row.dim, year)

    "You are Tragar's freight margin analyst. " <>
      "For the #{grain} \"#{row.dim}\"#{year_scope(year)}: " <>
      "sell #{money(row.sell)}, buy #{money(row.buy)}, margin #{money(row.margin)} " <>
      "(#{row.margin_pct}%), #{row.waybills} waybills.#{trend_note(trend)} " <>
      "Give a concise situational and predictive outlook (2–3 sentences)."
  end

  defp trend_note(nil), do: ""

  defp trend_note(t) do
    " Its margin% trend is #{t.slope}/mo, projected #{t.projected_pct}% in 6 months."
  end

  defp year_scope(nil), do: " (all years)"
  defp year_scope(y), do: " in #{y}"

  defp explain_prompt(%{grain: "contractor"} = assigns) do
    "You are Tragar's freight procurement analyst. These are SERVICE PROVIDERS (suppliers " <>
      "we pay). For each, sell = revenue of the waybills they moved and margin = sell − their " <>
      "cost (a waybill with several suppliers counts its sell under each, so sell is not " <>
      "additive across suppliers). Based ONLY on this data, evaluate supplier cost and the " <>
      "margin on their freight, and how both are trending, in 3–5 sentences:\n\n" <>
      view_context(assigns)
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

    base <> top_note(a) <> forecast_note(a) <> risk_note(a) <> flags_note(a)
  end

  # The tab's dimensions (year-scoped) so "Explain this view" reasons across all
  # clients / lanes / contractors, not just the totals.
  defp top_note(%{grain: "enterprise"}), do: ""

  defp top_note(%{ranked: [_ | _] = ranked, grain: "contractor"}) do
    " Top suppliers by cost: " <> Enum.map_join(Enum.take(ranked, 8), "; ", &cost_item/1)
  end

  defp top_note(%{ranked: [_ | _] = ranked, grain: grain}) do
    " Top #{grain}s: " <> Enum.map_join(Enum.take(ranked, 8), "; ", &top_item/1)
  end

  defp top_note(_), do: ""

  defp top_item(d), do: "#{d.dim} margin #{money(d.margin)} (#{d.margin_pct}%)"

  defp cost_item(d),
    do:
      "#{d.dim} cost #{money(d.buy)}, sell #{money(d.sell)}, margin #{money(d.margin)} (#{d.margin_pct}%)"

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

  defp risk_item(r), do: "#{r.dim} #{r.detail}"

  defp flags_note(%{exceptions: [_ | _] = ex}) do
    " Rate flags: " <> Enum.map_join(Enum.take(ex, 5), "; ", &flag_item/1)
  end

  defp flags_note(_), do: ""

  defp flag_item(e), do: "#{e.dim} #{e.detail}"

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

  # Token is threaded through every patch so reconnects/refreshes keep the gate
  # satisfied (LiveView re-mounts from the current URL).
  defp margin_path(grain, year, compare, token) do
    q = [grain: grain]
    q = if year, do: q ++ [year: year], else: q
    q = if compare, do: q ++ [compare: compare], else: q
    q = if token, do: q ++ [token: token], else: q
    "/margin?" <> URI.encode_query(q)
  end

  defp load(socket, "enterprise", year, _compare) do
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
    |> assign(:forecast, Predict.trend("enterprise", year))
    |> assign(:at_risk, [])
    |> assign(:exceptions, [])
  end

  defp load(socket, grain, year, compare) do
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
    |> assign(:at_risk, at_risk_for(grain, year, compare))
    |> assign(:exceptions, exceptions_for(grain, year, compare))
  end

  # Margin-% erosion / rate-quality flags only make sense where sell is attributed
  # (client/lane); the contractor grain is a pure cost view. When a year AND a
  # comparison baseline are chosen, switch to year-over-year (current vs baseline);
  # otherwise use the within-period trend. Both exclude inactive dimensions.
  defp at_risk_for(grain, year, compare) when grain in ["client", "lane"] do
    if is_integer(year) and not is_nil(compare) do
      Predict.compare_risk(grain, year, compare)
    else
      Predict.at_risk(grain, year)
    end
  end

  defp at_risk_for(_grain, _year, _compare), do: []

  defp exceptions_for(grain, year, compare) when grain in ["client", "lane"] do
    if is_integer(year) and not is_nil(compare) do
      Predict.compare_flags(grain, year, compare)
    else
      Predict.exceptions(grain, year)
    end
  end

  defp exceptions_for(_grain, _year, _compare), do: []

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

  defp compare_cls(active, c) do
    ["btn btn-xs", (active == c && "btn-primary") || "btn-ghost"]
  end

  # ── drill-down view helpers ──────────────────────────────────────────────────
  defp drill_dim_open?(%{dim: dim}, dim), do: true
  defp drill_dim_open?(_, _), do: false

  defp drill_month_open?(%{month: %Date{} = mo}, %Date{} = period),
    do: Date.compare(mo, period) == :eq

  defp drill_month_open?(_, _), do: false

  defp drill_caret(%{dim: dim}, dim), do: "▾"
  defp drill_caret(_, _), do: "▸"

  defp drill_col(:months), do: "Month"
  defp drill_col(:days), do: "Day"
  defp drill_col(:waybills), do: "Waybill"
  defp drill_col(:detail), do: "Waybill"

  # The expandable panel shared by the dimension table and the enterprise month
  # table: a breadcrumb of the drill path plus the current level's rows.
  attr :drill, :map, required: true
  attr :grain, :string, required: true

  defp drill_panel(assigns) do
    ~H"""
    <div class="p-3">
      <div class="mb-2 flex flex-wrap items-center gap-1 text-xs">
        <button :if={@grain == "enterprise"} phx-click="drill_close" class="link link-hover">
          All months
        </button>
        <button
          :if={@grain != "enterprise"}
          phx-click="drill_dim"
          phx-value-dim={@drill.dim}
          class="link link-hover font-medium"
        >
          {@drill.dim}
        </button>
        <span :if={@drill.month} class="opacity-40">›</span>
        <button
          :if={@drill.month && @drill.level != :days}
          phx-click="drill_month"
          phx-value-v={Date.to_iso8601(@drill.month)}
          class="link link-hover"
        >
          {Calendar.strftime(@drill.month, "%b %Y")}
        </button>
        <span :if={@drill.month && @drill.level == :days} class="font-medium">
          {Calendar.strftime(@drill.month, "%b %Y")}
        </span>
        <span :if={@drill.day} class="opacity-40">›</span>
        <button
          :if={@drill.day && @drill.level == :detail}
          phx-click="drill_day"
          phx-value-v={Date.to_iso8601(@drill.day)}
          class="link link-hover"
        >
          {Calendar.strftime(@drill.day, "%d %b %Y")}
        </button>
        <span :if={@drill.day && @drill.level == :waybills} class="font-medium">
          {Calendar.strftime(@drill.day, "%d %b %Y")}
        </span>
        <span :if={@drill.level == :detail} class="opacity-40">›</span>
        <span :if={@drill.level == :detail} class="font-medium">
          WB {@drill.detail && @drill.detail.number}
        </span>
        <button phx-click="drill_close" class="btn btn-ghost btn-xs ml-auto">Close</button>
      </div>

      <div :if={@drill.loading} class="py-2 text-xs opacity-60">Loading from FreightWare…</div>
      <div :if={@drill.error} class="py-2 text-xs text-error">Couldn't load: {@drill.error}</div>

      <table
        :if={!@drill.loading && !@drill.error && @drill.level != :detail}
        class="table table-xs w-full"
      >
        <thead>
          <tr>
            <th>{drill_col(@drill.level)}</th>
            <th class="text-right">Waybills</th>
            <th class="text-right">Sell</th>
            <th class="text-right">Buy</th>
            <th class="text-right">Margin</th>
            <th class="text-right">Margin %</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @drill.rows} class={row.margin < 0 && "text-error"}>
            <td class="whitespace-nowrap">
              <button
                :if={row.next}
                phx-click={row.next.ev}
                phx-value-v={row.next.v}
                class="link link-hover"
              >
                {row.label}
              </button>
              <span :if={!row.next} class="font-mono text-xs">{row.label}</span>
            </td>
            <td class="text-right">{row.n}</td>
            <td class="text-right">{money(row.sell)}</td>
            <td class="text-right">{money(row.buy)}</td>
            <td class="text-right">{money(row.margin)}</td>
            <td class="text-right">{row.margin_pct}%</td>
          </tr>
          <tr :if={@drill.rows == []}>
            <td colspan="6" class="text-xs opacity-60">No rows.</td>
          </tr>
        </tbody>
      </table>

      <div
        :if={!@drill.loading && !@drill.error && @drill.level == :detail && @drill.detail}
        class="text-xs"
      >
        <div class="mb-3 grid grid-cols-2 gap-x-4 gap-y-1 sm:grid-cols-3">
          <div><span class="opacity-60">Waybill</span> {@drill.detail.number}</div>
          <div><span class="opacity-60">Date</span> {@drill.detail.date}</div>
          <div><span class="opacity-60">Account</span> {@drill.detail.account}</div>
          <div><span class="opacity-60">Shipper</span> {@drill.detail.shipper}</div>
          <div><span class="opacity-60">Lane</span> {@drill.detail.from} → {@drill.detail.to}</div>
          <div><span class="opacity-60">Weight</span> {@drill.detail.weight}</div>
          <div><span class="opacity-60">Items</span> {@drill.detail.items}</div>
          <div><span class="opacity-60">Sell</span> {money(@drill.detail.sell)}</div>
          <div><span class="opacity-60">Buy</span> {money(@drill.detail.buy)}</div>
          <div>
            <span class="opacity-60">Margin</span>
            <span class={@drill.detail.margin < 0 && "text-error"}>
              {money(@drill.detail.margin)} ({@drill.detail.margin_pct}%)
            </span>
          </div>
        </div>

        <div class="mb-1 font-medium opacity-70">Contractor charges (buy breakdown)</div>
        <table class="table table-xs w-full">
          <thead>
            <tr>
              <th>Supplier</th>
              <th>Type</th>
              <th class="text-right">Amount</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={c <- @drill.detail.charges}>
              <td>{c.supplier}</td>
              <td>{c.type}</td>
              <td class="text-right">{money(c.amount)}</td>
            </tr>
            <tr :if={@drill.detail.charges == []}>
              <td colspan="3" class="opacity-60">No contractor charges.</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  @impl true
  def render(%{authorized: false} = assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl p-4">
      <h1 class="mb-1 text-lg font-semibold">Margin</h1>
      <p class="text-sm opacity-70">Not authorized.</p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl p-4 lg:pr-80">
      <h1 class="mb-1 text-lg font-semibold">Margin</h1>
      <p class="mb-3 text-sm opacity-60">
        Sell vs contractor buy; margin = sell − buy. Drill down by dimension.
      </p>

      <div class="mb-4 text-xs opacity-60">Drill down by</div>
      <div role="tablist" class="tabs tabs-lg tabs-boxed mb-4 w-fit bg-base-200">
        <.link
          patch={margin_path("enterprise", @year, @compare, @token)}
          role="tab"
          class={tab_cls(@grain, "enterprise")}
        >
          Enterprise
        </.link>
        <.link
          patch={margin_path("client", @year, @compare, @token)}
          role="tab"
          class={tab_cls(@grain, "client")}
        >
          Client
        </.link>
        <.link
          patch={margin_path("lane", @year, @compare, @token)}
          role="tab"
          class={tab_cls(@grain, "lane")}
        >
          Lane
        </.link>
        <.link
          patch={margin_path("contractor", @year, @compare, @token)}
          role="tab"
          class={tab_cls(@grain, "contractor")}
        >
          Contractor
        </.link>
      </div>

      <div class="mb-2 flex flex-wrap items-center gap-1 text-xs">
        <span class="mr-1 opacity-60">Year:</span>
        <.link patch={margin_path(@grain, nil, @compare, @token)} class={year_cls(@year, nil)}>
          All
        </.link>
        <.link
          :for={y <- 2016..2026}
          patch={margin_path(@grain, y, @compare, @token)}
          class={year_cls(@year, y)}
        >
          {y}
        </.link>
      </div>

      <div :if={is_integer(@year)} class="mb-5 flex flex-wrap items-center gap-1 text-xs">
        <span class="mr-1 opacity-60">Compare vs:</span>
        <.link patch={margin_path(@grain, @year, nil, @token)} class={compare_cls(@compare, nil)}>
          Off
        </.link>
        <.link
          patch={margin_path(@grain, @year, "prev", @token)}
          class={compare_cls(@compare, "prev")}
        >
          Prev years
        </.link>
        <.link
          :for={y <- 2016..2026}
          :if={y < @year}
          patch={margin_path(@grain, @year, y, @token)}
          class={compare_cls(@compare, y)}
        >
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

      <p :if={@grain == "contractor"} class="mb-5 text-xs opacity-60">
        Supplier sell = revenue of the waybills each supplier moved; margin = sell − their cost.
        A waybill carried by several suppliers counts under each, so these per-supplier figures
        don't sum to enterprise revenue (the totals above over-count sell for the same reason).
      </p>

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
        <div class="mb-2 text-sm font-medium">Margin at risk (Nx) — {@grain}</div>
        <div class="grid grid-cols-1 gap-1 text-xs sm:grid-cols-2">
          <div :for={a <- @at_risk} class="flex items-center gap-2">
            <span class="max-w-xs truncate">{a.dim}</span>
            <span class="ml-auto text-right text-error">{a.detail}</span>
          </div>
        </div>
      </div>

      <div :if={@exceptions != []} class="mb-4 rounded border border-warning p-3">
        <div class="mb-2 text-sm font-medium">Rate flags (Nx) — {@grain}</div>
        <div class="grid grid-cols-1 gap-1 text-xs sm:grid-cols-2">
          <div :for={e <- @exceptions} class="flex items-center gap-2">
            <span class="max-w-xs truncate">{e.dim}</span>
            <span class="ml-auto text-right text-warning">{e.detail}</span>
          </div>
        </div>
      </div>

      <p :if={@unattributed} class="mb-2 text-xs opacity-60">
        Unattributed (blank {@grain}): {money(@unattributed.sell)} sell, {money(@unattributed.margin)} margin — excluded from the pie & table above.
      </p>

      <div :if={@grain != "enterprise"} class="overflow-x-auto">
        <div class="mb-2 text-xs opacity-60">
          Click a {@grain} to drill Year → Month → Day → Waybill (day & waybill read live from FreightWare).
        </div>
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
              <th></th>
            </tr>
          </thead>
          <tbody>
            <%= for d <- @ranked do %>
              <tr class={drill_dim_open?(@drill, d.dim) && "bg-base-200"}>
                <td class="max-w-xs truncate">
                  <button
                    phx-click="drill_dim"
                    phx-value-dim={d.dim}
                    class="link link-hover flex items-center gap-1 text-left"
                  >
                    <span class="opacity-50">{drill_caret(@drill, d.dim)}</span>
                    <span class="truncate">{d.dim}</span>
                  </button>
                </td>
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
                <td>
                  <button
                    phx-click="explain_row"
                    phx-value-dim={d.dim}
                    class="btn btn-ghost btn-xs"
                    disabled={@ai_running}
                  >
                    Explain
                  </button>
                </td>
              </tr>
              <tr :if={drill_dim_open?(@drill, d.dim)}>
                <td colspan="8" class="bg-base-200/40 p-0">
                  <.drill_panel drill={@drill} grain={@grain} />
                </td>
              </tr>
            <% end %>
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
              <th></th>
            </tr>
          </thead>
          <tbody>
            <%= for r <- @rows do %>
              <tr class={drill_month_open?(@drill, r.period_month) && "bg-base-200"}>
                <td class="whitespace-nowrap font-mono text-xs">
                  <button
                    phx-click="drill_month"
                    phx-value-v={Date.to_iso8601(r.period_month)}
                    class="link link-hover"
                  >
                    {month_label(r.period_month)}
                  </button>
                </td>
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
                <td>
                  <button
                    phx-click="explain_month"
                    phx-value-month={month_label(r.period_month)}
                    class="btn btn-ghost btn-xs"
                    disabled={@ai_running}
                  >
                    Explain
                  </button>
                </td>
              </tr>
              <tr :if={drill_month_open?(@drill, r.period_month)}>
                <td colspan="8" class="bg-base-200/40 p-0">
                  <.drill_panel drill={@drill} grain={@grain} />
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <div class="mt-6 rounded border bg-base-100 p-3 lg:fixed lg:right-0 lg:top-0 lg:bottom-0 lg:z-20 lg:mt-0 lg:w-80 lg:overflow-y-auto lg:rounded-none lg:border-l lg:pt-16">
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
