defmodule TragarAiWeb.CollectionsLive do
  @moduledoc """
  Staff view of FreightWare collections for the current branch: those awaiting
  authorisation, and those still outstanding (not yet on a collection manifest).

  A LiveView over the socket: the server re-polls FreightWare every 10s, flashes
  collections that are newly seen, and colours each row by how long it has been
  open (age since it first appeared / its collection date).
  """
  use TragarAiWeb, :live_view

  alias TragarAi.Freight

  # Auto-refresh interval, adjustable live from the header. Defaults to 1 minute —
  # the FreightWare collections fetch is heavy (~15s for the full branch set), so
  # polling faster than that just piles requests up.
  @default_poll_ms 60_000
  @poll_options [{"30s", 30_000}, {"1m", 60_000}, {"2m", 120_000}, {"5m", 300_000}, {"Off", 0}]

  # Age thresholds (seconds) for the open-duration highlight.
  @amber_after 30 * 60
  @red_after 2 * 60 * 60
  # A collection first seen within this window still reads as "new".
  @new_within 20

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        unauthorised: [],
        outstanding: [],
        unauthorised_error: nil,
        outstanding_error: nil,
        first_seen: %{},
        new_keys: MapSet.new(),
        now: DateTime.utc_now(),
        updated_at: nil,
        loading: true,
        poll_ms: @default_poll_ms,
        poll_timer: nil,
        filters: empty_filters(),
        hidden_columns: MapSet.new(),
        show_columns_panel: false
      )

    if connected?(socket) do
      {:ok, socket |> start_load() |> schedule_poll()}
    else
      {:ok, socket}
    end
  end

  # Re-poll FreightWare on the current interval.
  @impl true
  def handle_info(:poll, socket) do
    {:noreply, socket |> start_load() |> schedule_poll()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    Freight.CollectionsCache.refresh()
    {:noreply, start_load(socket)}
  end

  # Live interval change from the header select.
  def handle_event("set_poll", %{"ms" => ms}, socket) do
    {:noreply, socket |> assign(poll_ms: String.to_integer(ms)) |> schedule_poll()}
  end

  def handle_event("filter", %{"filters" => filters}, socket),
    do: {:noreply, assign(socket, filters: Map.merge(empty_filters(), filters))}

  def handle_event("clear_filters", _params, socket),
    do: {:noreply, assign(socket, filters: empty_filters())}

  def handle_event("toggle_columns_panel", _params, socket),
    do: {:noreply, assign(socket, show_columns_panel: not socket.assigns.show_columns_panel)}

  def handle_event("toggle_column", %{"col" => col}, socket) do
    hidden = socket.assigns.hidden_columns

    hidden =
      if MapSet.member?(hidden, col),
        do: MapSet.delete(hidden, col),
        else: MapSet.put(hidden, col)

    {:noreply, assign(socket, hidden_columns: hidden)}
  end

  def handle_event("show_all_columns", _params, socket),
    do: {:noreply, assign(socket, hidden_columns: MapSet.new())}

  defp empty_filters,
    do: %{"account" => "", "branch" => "", "status" => "", "month" => "", "year" => ""}

  @impl true
  def handle_async(:collections, {:ok, %{unauthorised: unauth, outstanding: out}}, socket) do
    unauthorised = unauth |> ok_list() |> by_date_desc()
    outstanding = out |> ok_list() |> by_date_desc()
    now = DateTime.utc_now()

    {first_seen, new_keys} =
      track_seen(socket.assigns.first_seen, unauthorised ++ outstanding, now)

    {:noreply,
     assign(socket,
       unauthorised: unauthorised,
       unauthorised_error: error(unauth),
       outstanding: outstanding,
       outstanding_error: error(out),
       first_seen: first_seen,
       new_keys: new_keys,
       now: now,
       updated_at: now,
       loading: false
     )}
  end

  def handle_async(:collections, {:exit, reason}, socket) do
    {:noreply,
     assign(socket,
       loading: false,
       unauthorised_error: "load crashed (#{inspect(reason)})",
       outstanding_error: "load crashed"
     )}
  end

  # Read the self-refreshing cache (instant) — the heavy FreightWare fetch runs on
  # the cache's own timer, not per viewer/poll. The ↻ button forces a refetch.
  defp start_load(socket) do
    socket
    |> assign(loading: true)
    |> start_async(:collections, fn -> Freight.CollectionsCache.get() end)
  end

  # (Re)arm the auto-refresh timer for the current interval, cancelling any pending
  # one first so an interval change takes effect immediately. `Off` (0) stops
  # auto-refresh — the manual ↻ button still works.
  defp schedule_poll(socket) do
    if ref = socket.assigns.poll_timer, do: Process.cancel_timer(ref)

    ref =
      case socket.assigns.poll_ms do
        ms when is_integer(ms) and ms > 0 -> Process.send_after(self(), :poll, ms)
        _ -> nil
      end

    assign(socket, poll_timer: ref)
  end

  defp poll_options, do: @poll_options

  defp poll_label(0), do: "auto-refresh off"
  defp poll_label(_), do: "live"

  defp ok_list({:ok, l}) when is_list(l), do: l
  defp ok_list(_), do: []

  # Newest first — by collection date, then collect-after time (ISO strings sort
  # lexically; blanks sort last).
  defp by_date_desc(rows),
    do: Enum.sort_by(rows, &{&1["collection_date"] || "", &1["collect_after"] || ""}, :desc)

  defp error({:ok, _}), do: nil
  defp error({:error, reason}), do: inspect(reason)
  defp error(_), do: nil

  # First-seen timestamp per collection, so we can show how long each has been
  # open. A first appearance is seeded from the collection's own date/time (real
  # age) when parseable, else now. `new_keys` are those that appeared since the
  # previous poll — flashed as "new" (never on the very first load).
  defp track_seen(prev, rows, now) do
    first_load? = map_size(prev) == 0

    first_seen =
      for c <- rows, into: %{} do
        k = key(c)
        {k, Map.get(prev, k) || seed_seen(c, now)}
      end

    new_keys =
      if first_load? do
        MapSet.new()
      else
        for c <- rows, k = key(c), not Map.has_key?(prev, k), into: MapSet.new(), do: k
      end

    {first_seen, new_keys}
  end

  defp key(c), do: c["collection_reference"] || c["collection_obj"] || :erlang.phash2(c)

  defp seed_seen(c, now) do
    case open_datetime(c) do
      %DateTime{} = dt -> if DateTime.compare(dt, now) == :lt, do: dt, else: now
      _ -> now
    end
  end

  defp open_datetime(c) do
    with d when is_binary(d) <- c["collection_date"],
         {:ok, date} <- Date.from_iso8601(d),
         time <- parse_time(c["collect_after"]),
         {:ok, naive} <- NaiveDateTime.new(date, time) do
      DateTime.from_naive!(naive, "Etc/UTC")
    else
      _ -> nil
    end
  end

  defp parse_time(t) when is_binary(t) do
    case Time.from_iso8601(t) do
      {:ok, time} -> time
      _ -> ~T[00:00:00]
    end
  end

  defp parse_time(_), do: ~T[00:00:00]

  defp age_seconds(c, first_seen, now) do
    case Map.get(first_seen, key(c)) do
      %DateTime{} = seen -> max(0, DateTime.diff(now, seen, :second))
      _ -> 0
    end
  end

  defp new?(c, new_keys, age), do: MapSet.member?(new_keys, key(c)) or age <= @new_within

  @impl true
  def render(assigns) do
    all = assigns.unauthorised ++ assigns.outstanding
    fu = filtered(assigns.unauthorised, assigns.filters)
    fo = filtered(assigns.outstanding, assigns.filters)
    all_cols = columns(fu ++ fo)
    visible = Enum.reject(all_cols, &MapSet.member?(assigns.hidden_columns, &1))

    assigns =
      assign(assigns,
        fu: fu,
        fo: fo,
        all_columns: all_cols,
        visible_columns: visible,
        totals: totals(fu, fo),
        opt_accounts: options(all, "account_reference"),
        opt_branches: options(all, "originating_branch"),
        opt_statuses: options(all, "status"),
        opt_years: years(all),
        any_filter: any_filter?(assigns.filters)
      )

    ~H"""
    <div class="p-4 lg:p-6 space-y-4 max-w-7xl mx-auto">
      <Layouts.app_nav active={:collections} flash={@flash} />

      <header class="flex items-end justify-between gap-3">
        <div>
          <h1 class="text-2xl font-semibold">Collections</h1>
          <p class="text-sm text-base-content/60">
            Awaiting authorisation and outstanding. Rows are coloured by how long they've been open;
            new ones flash. Filter, choose columns, and see totals below.
          </p>
        </div>
        <div class="shrink-0 space-y-1 text-right">
          <div class="flex items-center justify-end gap-2">
            <span class="text-[11px] text-base-content/50">Auto-refresh</span>
            <form phx-change="set_poll">
              <select name="ms" class="select select-xs select-bordered">
                <option :for={{label, ms} <- poll_options()} value={ms} selected={@poll_ms == ms}>
                  {label}
                </option>
              </select>
            </form>
            <button class="btn btn-sm btn-ghost" phx-click="refresh" disabled={@loading}>
              <span :if={@loading} class="loading loading-spinner loading-xs"></span> ↻ Refresh
            </button>
          </div>
          <div :if={@updated_at} class="text-[11px] text-base-content/50">
            {poll_label(@poll_ms)} · {duration(DateTime.diff(@now, @updated_at, :second))} ago
          </div>
        </div>
      </header>

      <%!-- Totals across the (filtered) set --%>
      <div class="stats stats-horizontal shadow w-full overflow-x-auto">
        <div class="stat">
          <div class="stat-title">Collections</div>
          <div class="stat-value text-2xl">{@totals.total}</div>
          <div class="stat-desc">
            {@totals.unauthorised} unauth · {@totals.outstanding} outstanding
          </div>
        </div>
        <div class="stat">
          <div class="stat-title">Est. waybills</div>
          <div class="stat-value text-2xl">{@totals.waybills}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Est. parcels</div>
          <div class="stat-value text-2xl">{@totals.parcels}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Branches</div>
          <div class="stat-value text-2xl">{@totals.branches}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Accounts</div>
          <div class="stat-value text-2xl">{@totals.accounts}</div>
        </div>
      </div>

      <%!-- Filters --%>
      <form
        phx-change="filter"
        class="flex flex-wrap items-end gap-2 rounded-lg border border-base-300 p-2"
      >
        <.filter_select
          name="account"
          label="Account"
          value={@filters["account"]}
          options={@opt_accounts}
        />
        <.filter_select
          name="branch"
          label="Branch"
          value={@filters["branch"]}
          options={@opt_branches}
        />
        <.filter_select
          name="status"
          label="Status"
          value={@filters["status"]}
          options={@opt_statuses}
        />
        <.filter_select name="year" label="Year" value={@filters["year"]} options={@opt_years} />
        <.filter_select name="month" label="Month" value={@filters["month"]} options={months()} />
        <button
          :if={@any_filter}
          type="button"
          phx-click="clear_filters"
          class="btn btn-xs btn-ghost"
        >
          Clear filters
        </button>
        <button
          type="button"
          phx-click="toggle_columns_panel"
          class={"btn btn-xs ml-auto " <> if(@show_columns_panel, do: "btn-primary", else: "btn-ghost")}
        >
          Columns ⚙
        </button>
      </form>

      <div class={["grid gap-4", @show_columns_panel && "lg:grid-cols-[minmax(0,1fr)_240px]"]}>
        <div class="space-y-6 min-w-0">
          <.collections_section
            title="Awaiting authorisation"
            rows={@fu}
            columns={@visible_columns}
            error={@unauthorised_error}
            loading={@loading}
            first_seen={@first_seen}
            new_keys={@new_keys}
            now={@now}
          />

          <.collections_section
            title="Outstanding (not yet manifested)"
            rows={@fo}
            columns={@visible_columns}
            error={@outstanding_error}
            loading={@loading}
            first_seen={@first_seen}
            new_keys={@new_keys}
            now={@now}
          />
        </div>

        <aside
          :if={@show_columns_panel}
          class="rounded-lg border border-base-300 p-3 space-y-2 h-fit lg:sticky lg:top-16"
        >
          <div class="flex items-center justify-between">
            <h3 class="text-sm font-medium">Show columns</h3>
            <button type="button" phx-click="show_all_columns" class="btn btn-xs btn-ghost">
              All
            </button>
          </div>
          <div class="space-y-1 max-h-[60vh] overflow-y-auto pr-1">
            <label
              :for={col <- @all_columns}
              class="flex items-center gap-2 text-xs cursor-pointer hover:bg-base-200 rounded px-1 py-0.5"
            >
              <input
                type="checkbox"
                class="checkbox checkbox-xs"
                checked={not MapSet.member?(@hidden_columns, col)}
                phx-click="toggle_column"
                phx-value-col={col}
              />
              <span>{col_header(col)}</span>
            </label>
          </div>
        </aside>
      </div>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: ""
  attr :options, :list, required: true

  defp filter_select(assigns) do
    ~H"""
    <label class="flex flex-col gap-0.5">
      <span class="text-[10px] uppercase tracking-wide text-base-content/50">{@label}</span>
      <select name={"filters[#{@name}]"} class="select select-xs select-bordered">
        <option value="" selected={@value in [nil, ""]}>All</option>
        <option :for={o <- @options} value={opt_value(o)} selected={@value == opt_value(o)}>
          {opt_label(o)}
        </option>
      </select>
    </label>
    """
  end

  defp opt_value({v, _label}), do: v
  defp opt_value(v), do: v
  defp opt_label({_v, label}), do: label
  defp opt_label(v), do: v

  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :columns, :list, required: true
  attr :error, :string, default: nil
  attr :loading, :boolean, default: false
  attr :first_seen, :map, required: true
  attr :new_keys, :any, required: true
  attr :now, :any, required: true

  defp collections_section(assigns) do
    ~H"""
    <section class="space-y-3">
      <div class="flex items-center gap-2">
        <h2 class="text-lg font-semibold">{@title}</h2>
        <span class="badge badge-sm badge-outline">{length(@rows)}</span>
      </div>

      <div :if={@error} class="alert alert-error text-sm">Couldn't load: {@error}</div>

      <p
        :if={@rows == [] and is_nil(@error) and not @loading}
        class="text-sm text-base-content/50 py-4"
      >
        None.
      </p>

      <div :if={@rows != []} class="overflow-x-auto rounded-lg border border-base-300">
        <table class="table table-xs">
          <thead>
            <tr>
              <th class="whitespace-nowrap">Open</th>
              <th :for={col <- @columns} class="whitespace-nowrap">{col_header(col)}</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={c <- @rows}
              class={
                row_class(
                  age_seconds(c, @first_seen, @now),
                  new?(c, @new_keys, age_seconds(c, @first_seen, @now))
                )
              }
            >
              <td class="whitespace-nowrap">
                <span
                  :if={new?(c, @new_keys, age_seconds(c, @first_seen, @now))}
                  class="badge badge-xs badge-success mr-1"
                >
                  NEW
                </span>
                <span class={"font-mono " <> age_class(age_seconds(c, @first_seen, @now))}>
                  {duration(age_seconds(c, @first_seen, @now))}
                </span>
              </td>
              <td :for={col <- @columns} class="whitespace-nowrap">{cell(c, col)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  # Every field key present across the rows — a few useful ones first, then the
  # rest sorted. No whitelist: whatever FreightWare returns is shown as a column.
  @preferred_columns ~w(collection_reference status originating_branch collection_date collect_after collect_before)
  defp columns(rows) do
    keys = rows |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()
    Enum.filter(@preferred_columns, &(&1 in keys)) ++ Enum.sort(keys -- @preferred_columns)
  end

  defp col_header(col), do: String.replace(col, "_", " ")

  defp cell(c, col) do
    case Map.get(c, col) do
      nil -> "—"
      v -> to_string(v)
    end
  end

  defp row_class(_age, true), do: "bg-success/10"
  defp row_class(age, _new) when age >= @red_after, do: "bg-error/5"
  defp row_class(_age, _new), do: ""

  defp age_class(age) when age >= @red_after, do: "text-error font-semibold"
  defp age_class(age) when age >= @amber_after, do: "text-warning"
  defp age_class(_age), do: "text-success"

  # Compact duration: 45s, 12m, 3h, 2d.
  defp duration(seconds) when is_integer(seconds) do
    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  defp duration(_), do: "—"

  # ── Filtering, options, totals ────────────────────────────────────────────────

  defp filtered(rows, filters) do
    Enum.filter(rows, fn c ->
      match_val(c["account_reference"], filters["account"]) and
        match_val(c["originating_branch"], filters["branch"]) and
        match_val(c["status"], filters["status"]) and
        match_year(c["collection_date"], filters["year"]) and
        match_month(c["collection_date"], filters["month"])
    end)
  end

  defp match_val(_v, f) when f in [nil, ""], do: true
  defp match_val(v, f), do: to_string(v) == f

  defp match_year(_d, f) when f in [nil, ""], do: true
  defp match_year(date, y), do: is_binary(date) and String.starts_with?(date, y <> "-")

  defp match_month(_d, f) when f in [nil, ""], do: true

  defp match_month(date, m) when is_binary(date) do
    case String.split(date, "-") do
      [_y, mm | _] -> mm == m
      _ -> false
    end
  end

  defp match_month(_d, _m), do: false

  defp any_filter?(filters), do: Enum.any?(filters, fn {_k, v} -> v not in [nil, ""] end)

  # Distinct non-blank values of `key` across rows, as sorted strings.
  defp options(rows, key) do
    rows
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Distinct years present in the collection dates.
  defp years(rows) do
    rows
    |> Enum.map(fn c ->
      with d when is_binary(d) <- c["collection_date"], do: String.slice(d, 0, 4)
    end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.sort(:desc)
  end

  @months [
    {"01", "January"},
    {"02", "February"},
    {"03", "March"},
    {"04", "April"},
    {"05", "May"},
    {"06", "June"},
    {"07", "July"},
    {"08", "August"},
    {"09", "September"},
    {"10", "October"},
    {"11", "November"},
    {"12", "December"}
  ]
  defp months, do: @months

  defp totals(unauth, out) do
    all = unauth ++ out

    %{
      total: length(all),
      unauthorised: length(unauth),
      outstanding: length(out),
      waybills: sum_field(all, "estimated_waybills"),
      parcels: sum_field(all, "estimated_parcels"),
      branches: distinct_count(all, "originating_branch"),
      accounts: distinct_count(all, "account_reference")
    }
  end

  defp sum_field(rows, key), do: rows |> Enum.map(&num(Map.get(&1, key))) |> Enum.sum()

  defp distinct_count(rows, key) do
    rows
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> length()
  end

  defp num(v) when is_number(v), do: v

  defp num(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} ->
        n

      :error ->
        case Float.parse(v) do
          {f, _} -> f
          :error -> 0
        end
    end
  end

  defp num(_), do: 0
end
