defmodule TragarAiWeb.DeliveryAuditLive do
  @moduledoc """
  A visual window on what the expected-cost calc is finding, per delivery.

  Each row lays the customer (sell) and supplier (expected buy vs actual buy) side
  by side with the RESOLUTION behind the expected: the delivery town + postal code,
  the resolved subcontractor rate area, and the single chosen rate. Defaults to
  June 2026; month/year selectable; and the set can be narrowed to one manifest,
  one supplier, or one customer for the period. Costed facts come from the
  warehouse; the resolution is enriched live from the replica for the shown page
  (`TragarAi.Insight.DeliveryAudit`).
  """
  use TragarAiWeb, :live_view

  alias TragarAi.Insight.DeliveryAudit

  @years 2016..2026 |> Enum.to_list() |> Enum.reverse()
  @months ~w(January February March April May June July August September October November December)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active, :delivery_audit)
     |> assign(:years, @years)
     |> assign(:months, Enum.with_index(@months, 1))
     |> assign(:year, 2026)
     |> assign(:month, 6)
     |> assign(:filter_type, "all")
     |> assign(:supplier, "")
     |> assign(:customer, "")
     |> assign(:manifest, "")
     |> assign(:page, 1)
     |> assign(:suppliers, [])
     |> assign(:customers, [])
     |> assign(:rows, [])
     |> assign(:total, 0)
     |> assign(:error, nil)
     |> assign(:expanded, MapSet.new())
     |> load()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:year, to_int(params["year"], socket.assigns.year))
     |> assign(:month, to_int(params["month"], socket.assigns.month))
     |> assign(:filter_type, params["filter_type"] || "all")
     |> assign(:supplier, params["supplier"] || "")
     |> assign(:customer, params["customer"] || "")
     |> assign(:manifest, String.trim(params["manifest"] || ""))
     |> assign(:page, 1)
     |> load()}
  end

  def handle_event("page", %{"to" => to}, socket) do
    {:noreply, socket |> assign(:page, max(1, to_int(to, socket.assigns.page))) |> load()}
  end

  def handle_event("toggle", %{"wb" => wb}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, wb),
        do: MapSet.delete(expanded, wb),
        else: MapSet.put(expanded, wb)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  # ── data ────────────────────────────────────────────────────────────────────

  defp load(socket) do
    %{year: y, month: m, page: page} = socket.assigns

    socket =
      socket
      |> assign(:suppliers, DeliveryAudit.suppliers(y, m))
      |> assign(:customers, DeliveryAudit.customers(y, m))

    case build_filter(socket.assigns) do
      {:error, msg} ->
        socket |> assign(:rows, []) |> assign(:total, 0) |> assign(:error, msg)

      filter ->
        {rows, total} = DeliveryAudit.list(y, m, filter, page)

        resolution =
          case DeliveryAudit.resolve(Enum.map(rows, & &1.waybill_obj)) do
            {:ok, map} -> map
            {:error, _} -> %{}
          end

        socket
        |> assign(:rows, Enum.map(rows, &merge_row(&1, resolution)))
        |> assign(:total, total)
        |> assign(:error, nil)
    end
  end

  defp merge_row(r, resolution) do
    res = Map.get(resolution, r.waybill_obj, %{})

    %{
      waybill_obj: r.waybill_obj,
      waybill_number: r.waybill_number,
      waybill_date: r.waybill_date,
      customer: r.account_name,
      supplier: r.contractor_reference,
      wb_service: Map.get(res, :wb_service),
      sell: r.sell,
      buy: r.buy,
      expected: r.expected,
      priced: r.priced,
      sell_from_area: r.rate_area_from_code,
      sell_to_area: r.rate_area_to_code,
      rate_count: Map.get(res, :rate_count, 0),
      candidates: Map.get(res, :candidates, []),
      res: res
    }
  end

  defp build_filter(%{filter_type: "supplier", supplier: s}) when s != "", do: {:supplier, s}
  defp build_filter(%{filter_type: "customer", customer: c}) when c != "", do: {:customer, c}

  defp build_filter(%{filter_type: "manifest", manifest: man}) when man != "" do
    case DeliveryAudit.manifest_waybill_objs(man) do
      {:ok, []} -> {:error, "No waybills found for manifest #{man}."}
      {:ok, objs} -> {:manifest, objs}
      {:error, reason} -> {:error, "Manifest lookup failed: #{inspect(reason)}"}
    end
  end

  defp build_filter(_), do: :all

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp to_int(v, default) do
    case Integer.parse(to_string(v || "")) do
      {n, _} -> n
      :error -> default
    end
  end

  defp num_str(v) do
    case Float.parse(to_string(v || "0")) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp pages(total), do: max(1, ceil(total / DeliveryAudit.per_page()))

  defp money(nil), do: "—"
  defp money(%Decimal{} = d), do: money(Decimal.to_float(d))
  defp money(n) when is_number(n), do: "R" <> :erlang.float_to_binary(n * 1.0, decimals: 2)

  defp numfmt(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 1)
  defp numfmt(_), do: "—"

  # Increment term: R<amount> per <unit> of weight; "flat" when there's no per-unit step.
  defp fmt_incr(_amount, unit) when unit in [0, 0.0], do: "flat"
  defp fmt_incr(amount, unit), do: money(amount) <> " / " <> numfmt(unit)

  # Default discount: amount and/or percent; "—" when neither is set.
  defp fmt_disc(amount, percent) when amount in [0, 0.0] and percent in [0, 0.0], do: "—"
  defp fmt_disc(amount, percent), do: money(amount) <> " / " <> numfmt(percent) <> "%"

  defp res(res, key), do: blank(Map.get(res, key))
  defp blank(v) when v in [nil, ""], do: "—"
  defp blank(v), do: v

  # ── render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-full p-4">
      <div class="mb-3 flex items-center justify-between gap-2">
        <h1 class="text-lg font-semibold">Delivery audit — what the rate calc finds</h1>
        <a href="/logout" class="btn btn-ghost btn-xs">Log out</a>
      </div>
      <p class="mb-3 text-sm opacity-60">
        Per delivery: customer sell, supplier expected buy vs actual buy, and the resolution
        behind expected — delivery town + postcode → the subcontractor's rate area → the one
        chosen rate. Costed facts from the warehouse; resolution enriched live for this page.
      </p>

      <form phx-change="filter" class="mb-3 flex flex-wrap items-end gap-3 rounded border p-3 text-sm">
        <label class="flex flex-col gap-1">
          <span class="opacity-60">Year</span>
          <select name="year" class="select select-bordered select-sm">
            <option :for={y <- @years} value={y} selected={y == @year}>{y}</option>
          </select>
        </label>
        <label class="flex flex-col gap-1">
          <span class="opacity-60">Month</span>
          <select name="month" class="select select-bordered select-sm">
            <option :for={{name, n} <- @months} value={n} selected={n == @month}>{name}</option>
          </select>
        </label>
        <label class="flex flex-col gap-1">
          <span class="opacity-60">View</span>
          <select name="filter_type" class="select select-bordered select-sm">
            <option value="all" selected={@filter_type == "all"}>All deliveries</option>
            <option value="supplier" selected={@filter_type == "supplier"}>By supplier</option>
            <option value="customer" selected={@filter_type == "customer"}>By customer</option>
            <option value="manifest" selected={@filter_type == "manifest"}>By manifest</option>
          </select>
        </label>
        <label :if={@filter_type == "supplier"} class="flex flex-col gap-1">
          <span class="opacity-60">Supplier</span>
          <select name="supplier" class="select select-bordered select-sm">
            <option value="">— pick —</option>
            <option :for={s <- @suppliers} value={s} selected={s == @supplier}>{s}</option>
          </select>
        </label>
        <label :if={@filter_type == "customer"} class="flex flex-col gap-1">
          <span class="opacity-60">Customer</span>
          <select name="customer" class="select select-bordered select-sm">
            <option value="">— pick —</option>
            <option :for={c <- @customers} value={c} selected={c == @customer}>{c}</option>
          </select>
        </label>
        <label :if={@filter_type == "manifest"} class="flex flex-col gap-1">
          <span class="opacity-60">Manifest (trip ref or obj)</span>
          <input
            name="manifest"
            value={@manifest}
            phx-debounce="500"
            class="input input-bordered input-sm"
            placeholder="e.g. JHB129258"
          />
        </label>
        <span class="ml-auto opacity-60">{@total} deliveries · page {@page}/{pages(@total)}</span>
      </form>

      <div :if={@error} class="mb-3 rounded border border-error/40 bg-error/10 p-2 text-sm">
        {@error}
      </div>

      <div class="overflow-x-auto rounded border">
        <table class="table table-xs">
          <thead>
            <tr>
              <th>Waybill</th>
              <th>Date</th>
              <th>Customer</th>
              <th class="text-right">Sell</th>
              <th>Supplier</th>
              <th>Service</th>
              <th>Delivery town</th>
              <th>Postcode</th>
              <th>Sell area (from→to)</th>
              <th>Buy area (delivery)</th>
              <th class="text-center">Rates</th>
              <th class="text-right">Expected buy</th>
              <th class="text-right">Actual buy</th>
              <th class="text-right">Rate base</th>
              <th>Rate eff.</th>
              <th>Rate obj</th>
            </tr>
          </thead>
          <tbody :for={r <- @rows}>
            <tr class={[!r.priced && "bg-warning/10"]}>
              <td class="font-mono">{r.waybill_number}</td>
              <td>{r.waybill_date}</td>
              <td class="max-w-40 truncate" title={r.customer}>{blank(r.customer)}</td>
              <td class="text-right">{money(r.sell)}</td>
              <td class="font-mono">{blank(r.supplier)}</td>
              <td class="font-mono">{blank(r.wb_service)}</td>
              <td>{res(r.res, :consignee_suburb)}</td>
              <td>{res(r.res, :consignee_postcode)}</td>
              <td class="font-mono opacity-70">{blank(r.sell_from_area)}→{blank(r.sell_to_area)}</td>
              <td class="font-mono">{res(r.res, :delivery_rate_area)}</td>
              <td class="text-center">
                <button
                  :if={r.rate_count > 0}
                  type="button"
                  phx-click="toggle"
                  phx-value-wb={r.waybill_obj}
                  class="link link-primary font-semibold"
                >
                  {r.rate_count}
                </button>
                <span :if={r.rate_count == 0} class="opacity-50">0</span>
              </td>
              <td class={["text-right", r.priced && "text-success"]}>{money(r.expected)}</td>
              <td class="text-right">{money(r.buy)}</td>
              <td class="text-right">{(r.priced && money(Map.get(r.res, :rate_base))) || "—"}</td>
              <td>{res(r.res, :rate_effective)}</td>
              <td class="font-mono opacity-70">{res(r.res, :entity_rate_obj)}</td>
            </tr>
            <tr :if={MapSet.member?(@expanded, r.waybill_obj)}>
              <td colspan="16" class="bg-base-200 p-2">
                <div class="mb-1 text-xs font-semibold">
                  {r.rate_count} rate(s) found on the delivery area for {r.waybill_number} — the
                  highlighted row is the one the calc used.
                </div>
                <table class="table table-xs w-auto">
                  <thead>
                    <tr>
                      <th>Used</th>
                      <th>Rate obj</th>
                      <th>Service</th>
                      <th>Rate type</th>
                      <th>Calc rule</th>
                      <th>From area</th>
                      <th>To area</th>
                      <th>Product</th>
                      <th>Consgmt</th>
                      <th>Mirror</th>
                      <th>Effective</th>
                      <th>Cease</th>
                      <th>Weight band</th>
                      <th class="text-right">Base</th>
                      <th class="text-right">Increment</th>
                      <th class="text-right">Discount</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={c <- r.candidates} class={[c.used? && "bg-success/20 font-semibold"]}>
                      <td>{(c.used? && "✓ used") || ""}</td>
                      <td class="font-mono">{c.entity_rate_obj}</td>
                      <td class="font-mono">{blank(c.service)}</td>
                      <td class="font-mono">{blank(c.rate_type)}</td>
                      <td class="font-mono">{blank(c.calc_rule)}</td>
                      <td class="font-mono">{c.from_rate_area_obj}</td>
                      <td class="font-mono">{c.to_rate_area_obj}</td>
                      <td>{if num_str(c.product) == 0, do: "generic", else: c.product}</td>
                      <td class="font-mono">{blank(c.consignment_type)}</td>
                      <td>{if num_str(c.bidirectional) == 0, do: "—", else: "mirror"}</td>
                      <td>{blank(c.effective)}</td>
                      <td>{blank(c.cease)}</td>
                      <td>{numfmt(c.from_unit)}–{numfmt(c.to_unit)}</td>
                      <td class="text-right">{money(c.base)}</td>
                      <td class="text-right">{fmt_incr(c.increment_amount, c.increment_unit)}</td>
                      <td class="text-right">{fmt_disc(c.discount_amount, c.discount_percent)}</td>
                    </tr>
                  </tbody>
                </table>
              </td>
            </tr>
          </tbody>
          <tbody :if={@rows == []}>
            <tr>
              <td colspan="16" class="p-4 text-center opacity-60">
                No deliveries — the month may not be materialised yet (run a warehouse refresh),
                or the filter matched nothing.
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={pages(@total) > 1} class="mt-3 flex items-center gap-2 text-sm">
        <button class="btn btn-sm" disabled={@page <= 1} phx-click="page" phx-value-to={@page - 1}>
          ← Prev
        </button>
        <span class="opacity-60">page {@page} / {pages(@total)}</span>
        <button
          class="btn btn-sm"
          disabled={@page >= pages(@total)}
          phx-click="page"
          phx-value-to={@page + 1}
        >
          Next →
        </button>
      </div>
    </div>
    """
  end
end
