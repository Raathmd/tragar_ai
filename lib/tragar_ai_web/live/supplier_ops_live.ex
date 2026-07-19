defmodule TragarAiWeb.SupplierOpsLive do
  @moduledoc """
  Operations supplier-selection board:

    * **Open delivery manifests** — the live FreightWare feed (`/multiManifest`),
      newest first. For any manifest, "Rank suppliers" prices the candidate 3rd
      parties from the live rate card (`Insight.RateEngine`) — cheapest first,
      with how many of the manifest's waybills each can cover.
    * **Lane ranking** — pick an origin → destination rate area for the
      historical-actuals ranking from the `supplier_route_costs` warehouse.

  Gated by the `:supplier_ops` page permission (operations + admin roles).
  """
  use TragarAiWeb, :live_view

  alias TragarAi.Freight
  alias TragarAi.Insight.RateEngine
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
      |> assign(:ranking_ref, nil)
      |> assign(:ranking, nil)
      |> assign(:ranking_error, nil)
      |> assign(:ranking_loading, false)

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
      (d && Date.compare(d, low) != :lt) and Date.compare(d, high) != :gt
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

  # Rank the candidate 3rd-party suppliers for one open manifest by expected cost
  # (live from the FreightWare rate card). On-demand per manifest — the join is
  # heavy, so we never price every manifest up front.
  @impl true
  def handle_event("rank_manifest", %{"ref" => ref}, socket) do
    # The rate join is heavy; run it off the LiveView process so the UI shows a
    # loading state immediately instead of blocking until it returns.
    socket =
      socket
      |> assign(ranking_ref: ref, ranking: nil, ranking_error: nil, ranking_loading: true)
      |> start_async(:rank, fn -> RateEngine.rank_manifest_suppliers(ref) end)

    {:noreply, socket}
  end

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
  def handle_async(:rank, {:ok, {:ok, ranking}}, socket) do
    {:noreply, assign(socket, ranking: ranking, ranking_error: nil, ranking_loading: false)}
  end

  def handle_async(:rank, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, ranking_error: inspect(reason), ranking_loading: false)}
  end

  def handle_async(:rank, {:exit, reason}, socket) do
    {:noreply,
     assign(socket, ranking_error: "pricing crashed: #{inspect(reason)}", ranking_loading: false)}
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
          <h2 class="text-sm font-medium">
            Open delivery manifests <span class="opacity-50">· last 30 days</span>
          </h2>
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
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={m <- @manifests} class={m["manifest_number"] == @ranking_ref && "bg-base-200"}>
              <td class="font-mono text-xs">{m["manifest_number"]}</td>
              <td class="text-xs">{m["manifest_date"]}</td>
              <td class="text-xs">{m["station_code"]}</td>
              <td><span class="badge badge-sm badge-ghost">{m["status_code"]}</span></td>
              <td class="text-xs">{m["subcontractor_reference"]}</td>
              <td class="text-right">
                <button
                  phx-click="rank_manifest"
                  phx-value-ref={m["manifest_number"]}
                  class="btn btn-ghost btn-xs"
                >
                  Rank suppliers
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </section>

      <section :if={@ranking_ref} class="rounded-lg border border-primary/40">
        <div class="border-b border-base-300 px-4 py-2 text-sm font-medium">
          Cheapest 3rd parties for <span class="font-mono">{@ranking_ref}</span>
          <span class="opacity-60">· expected cost from the rate card</span>
        </div>

        <p :if={@ranking_loading} class="p-4 text-sm opacity-70">
          Pricing from the FreightWare rate card…
        </p>
        <p :if={@ranking_error} class="p-4 text-sm text-error">
          Couldn't price this manifest: {@ranking_error}
        </p>
        <p :if={not @ranking_loading and @ranking == []} class="p-4 text-sm opacity-70">
          No 3rd party has a rate covering this manifest's deliveries.
        </p>

        <table :if={@ranking not in [nil, []]} class="table table-sm w-full">
          <thead>
            <tr>
              <th>#</th>
              <th>Supplier</th>
              <th class="text-right">Waybills priced</th>
              <th class="text-right">Total expected</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{r, i} <- Enum.with_index(@ranking, 1)} class={i == 1 && "bg-success/10"}>
              <td>{i}</td>
              <td>{r.supplier_name || r.supplier_ref}</td>
              <td class="text-right">{r.waybills_priced}</td>
              <td class="text-right font-mono">
                R{:erlang.float_to_binary(r.total_expected, decimals: 2)}
              </td>
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
