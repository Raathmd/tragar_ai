defmodule TragarAiWeb.SupplierOpsLive do
  @moduledoc """
  Operations supplier-selection board. Pick a lane (origin → destination rate
  area) and see the candidate suppliers ranked cheapest-first by what they have
  actually billed (the `supplier_route_costs` warehouse).

  First increment — the historical-actuals ranking. Still to come (pending the
  manifest status/type probes): the live rate-engine columns (rate-only,
  rate+surcharge) and auto-population of currently-open manifests so ops sees the
  ranking beside a manifest they're building, not just an ad-hoc lane.

  Gated by the `:supplier_ops` page permission (operations + admin roles).
  """
  use TragarAiWeb, :live_view

  alias TragarAi.Freight
  alias TragarAi.Insight.SupplierRanking

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:active, :supplier)
      |> assign(:from_areas, SupplierRanking.from_areas())
      |> assign(:to_areas, SupplierRanking.to_areas())
      |> assign(:from, nil)
      |> assign(:to, nil)
      |> assign(:rows, nil)
      |> assign(:manifests, nil)
      |> assign(:manifest_error, nil)

    # The open-manifest feed is a live FreightWare API call — only on the
    # connected mount, so the first (static) render isn't blocked on it.
    {:ok, if(connected?(socket), do: load_manifests(socket), else: socket)}
  end

  # FreightWare's "can be closed" list includes ancient never-closed manifests —
  # noise for a current-ops board. Keep the last @recent_days, newest first.
  @recent_days 30

  defp load_manifests(socket) do
    case Freight.open_delivery_manifests() do
      {:ok, manifests} ->
        assign(socket, manifests: recent_first(manifests), manifest_error: nil)

      {:error, reason} ->
        assign(socket, manifests: [], manifest_error: inspect(reason))
    end
  end

  defp recent_first(manifests) do
    today = Date.utc_today()
    low = Date.add(today, -@recent_days)
    high = Date.add(today, 2)

    manifests
    |> Enum.map(fn m -> {parse_date(m["manifest_date"]), m} end)
    |> Enum.filter(fn {d, _} ->
      d && Date.compare(d, low) != :lt and Date.compare(d, high) != :gt
    end)
    |> Enum.sort_by(fn {d, _} -> d end, {:desc, Date})
    |> Enum.map(fn {_d, m} -> m end)
  end

  defp parse_date(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  @impl true
  def handle_event("refresh_manifests", _params, socket) do
    {:noreply, load_manifests(socket)}
  end

  def handle_event("rank", %{"from" => from, "to" => to}, socket)
      when from != "" and to != "" do
    {:noreply,
     socket
     |> assign(:from, from)
     |> assign(:to, to)
     |> assign(:rows, SupplierRanking.rank(from, to))}
  end

  def handle_event("rank", _params, socket) do
    {:noreply, put_flash(socket, :error, "Pick both an origin and a destination rate area.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 lg:p-6 space-y-4">
      <Layouts.app_nav active={:supplier} flash={@flash} current_user={@current_user} />

      <header>
        <h1 class="text-2xl font-semibold">Supplier selection</h1>
        <p class="text-sm text-base-content/70">
          Candidate suppliers for a lane, ranked cheapest-first by what they've actually billed
          (last 12 months). Live rate quotes and open-manifest auto-list are coming next.
        </p>
      </header>

      <section class="rounded-lg border border-base-300">
        <div class="flex items-center justify-between border-b border-base-300 px-4 py-2">
          <h2 class="text-sm font-medium">Open delivery manifests <span class="opacity-50">· last 30 days</span></h2>
          <button phx-click="refresh_manifests" class="btn btn-ghost btn-xs">Refresh</button>
        </div>

        <p :if={is_nil(@manifests) and is_nil(@manifest_error)} class="p-4 text-sm opacity-70">
          Loading from FreightWare…
        </p>
        <p :if={@manifest_error} class="p-4 text-sm text-error">
          Couldn't load open manifests: {@manifest_error}
        </p>
        <p :if={@manifests == []} class="p-4 text-sm opacity-70">No open delivery manifests.</p>

        <table :if={@manifests not in [nil, []]} class="table table-sm w-full">
          <thead>
            <tr>
              <th>Manifest</th>
              <th>Date</th>
              <th>Branch</th>
              <th>Status</th>
              <th>Subcontractor</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={m <- @manifests}>
              <td class="font-mono text-xs">{m["manifest_number"]}</td>
              <td class="text-xs">{m["manifest_date"]}</td>
              <td class="text-xs">{m["station_code"]}</td>
              <td><span class="badge badge-sm badge-ghost">{m["status_code"]}</span></td>
              <td class="text-xs">{m["subcontractor_reference"]}</td>
            </tr>
          </tbody>
        </table>
      </section>

      <form
        phx-submit="rank"
        class="flex flex-wrap items-end gap-2 rounded-lg border border-base-300 p-4"
      >
        <div>
          <label class="mb-1 block text-xs opacity-60">Origin rate area</label>
          <select name="from" class="select select-bordered select-sm">
            <option value="">—</option>
            <option :for={a <- @from_areas} value={a} selected={a == @from}>{a}</option>
          </select>
        </div>
        <div>
          <label class="mb-1 block text-xs opacity-60">Destination rate area</label>
          <select name="to" class="select select-bordered select-sm">
            <option value="">—</option>
            <option :for={a <- @to_areas} value={a} selected={a == @to}>{a}</option>
          </select>
        </div>
        <button class="btn btn-primary btn-sm">Rank suppliers</button>
      </form>

      <p :if={@from_areas == []} class="rounded bg-warning/10 p-3 text-sm">
        No supplier-cost data yet — run the
        <span class="font-medium">Rebuild supplier-cost warehouse</span>
        job in <.link navigate={~p"/_inspect"} class="link">/_inspect</.link>
        first.
      </p>

      <section :if={@rows} class="rounded-lg border border-base-300">
        <div class="border-b border-base-300 px-4 py-2 text-sm font-medium">
          {@from} → {@to}
          <span class="opacity-60">· {length(@rows)} supplier(s)</span>
        </div>

        <p :if={@rows == []} class="p-4 text-sm opacity-70">
          No suppliers have billed this lane in the last 12 months.
        </p>

        <table :if={@rows != []} class="table table-sm w-full">
          <thead>
            <tr>
              <th>#</th>
              <th>Supplier</th>
              <th class="text-right">Cost / kg</th>
              <th class="text-right">Cheapest waybill</th>
              <th class="text-right">Waybills</th>
              <th class="text-right">Last billed</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{r, i} <- Enum.with_index(@rows, 1)} class={i == 1 && "bg-success/10"}>
              <td>{i}</td>
              <td>{r.supplier || r.obj}</td>
              <td class="text-right font-mono">{fmt_money(r.cost_per_kg)}</td>
              <td class="text-right font-mono">{fmt_money(r.min_cost)}</td>
              <td class="text-right">{r.waybills}</td>
              <td class="text-right text-xs opacity-70">{r.last_charged_date}</td>
            </tr>
          </tbody>
        </table>
      </section>
    </div>
    """
  end

  defp fmt_money(nil), do: "—"
  defp fmt_money(%Decimal{} = d), do: fmt_money(Decimal.to_float(d))
  defp fmt_money(n) when is_number(n), do: "R" <> :erlang.float_to_binary(n * 1.0, decimals: 2)
end
