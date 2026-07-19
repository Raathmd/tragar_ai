defmodule TragarAiWeb.ReconcileLive do
  @moduledoc """
  Buy/sell verification console for management.

  Documents exactly how the buy and sell figures are calculated in code, and for a
  given waybill reconciles OUR figures against FreightWare, component by component:

    * SELL — our `fwt_waybill.total_cost` vs the live FreightWare API `chargedAmount`
      (a true external check; the API exposes the sell side).
    * BUY ACTUAL — our Σ `fwt_contractor_charge.total_charge_amount` vs FW's recorded
      charge lines in the replica. The live API does NOT expose supplier/buy cost, so
      the replica's recorded charges are the source of truth here.
    * BUY EXPECTED — our rate-engine computation (`base × (1+fuel) + sundry`), every
      term shown as its own component, compared against buy actual.

  Read-only. Admin/`:reconcile`-gated at the route. FreightWare calls block, so they
  run in a Task and post back — the LiveView stays responsive.
  """
  use TragarAiWeb, :live_view

  alias TragarAi.Dovetail.TokenStore
  alias TragarAi.Freight
  alias TragarAi.Insight.Drill
  alias TragarAi.Insight.RateEngine

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active, "reconcile")
     |> assign(:query, "")
     |> assign(:loading, false)
     |> assign(:error, nil)
     |> assign(:result, nil)
     |> assign(:token, nil)
     |> assign(:fw_ready, TokenStore.has_token?())}
  end

  @impl true
  def handle_event("reconcile", %{"waybill" => number}, socket) do
    number = String.trim(number)

    if number == "" do
      {:noreply, assign(socket, error: "Enter a waybill number.", result: nil)}
    else
      token = make_ref()
      lv = self()

      Task.Supervisor.start_child(TragarAi.TaskSupervisor, fn ->
        send(lv, {:reconcile_result, token, reconcile(number)})
      end)

      {:noreply,
       socket
       |> assign(:query, number)
       |> assign(:loading, true)
       |> assign(:error, nil)
       |> assign(:result, nil)
       |> assign(:token, token)}
    end
  end

  @impl true
  def handle_info({:reconcile_result, token, outcome}, %{assigns: %{token: token}} = socket) do
    socket = assign(socket, loading: false, fw_ready: TokenStore.has_token?())

    case outcome do
      {:ok, result} -> {:noreply, assign(socket, result: result, error: nil)}
      {:error, msg} -> {:noreply, assign(socket, result: nil, error: msg)}
    end
  end

  # Stale result from a superseded query — ignore.
  def handle_info({:reconcile_result, _stale, _outcome}, socket), do: {:noreply, socket}

  # ── reconciliation ──────────────────────────────────────────────────────────
  defp reconcile(number) do
    case Freight.get_waybill(number) do
      {:ok, api} when is_map(api) ->
        obj = api["waybill_obj"]

        if is_binary(obj) and obj != "" do
          {:ok, build_result(number, api, detail(obj), components(obj))}
        else
          {:error, "FreightWare returned no waybill_obj for #{number}."}
        end

      {:ok, _} ->
        {:error, "Waybill #{number} not found in FreightWare."}

      {:error, reason} ->
        {:error, "FreightWare API error: #{inspect(reason)}"}
    end
  end

  defp detail(obj) do
    case Drill.detail(obj) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  # Expected-cost component breakdown for this waybill (or nil — own-fleet / no card).
  defp components(obj) do
    case RateEngine.assigned_expected("w.waybill_obj = '#{digits(obj)}'") do
      {:ok, [%{components: c} | _]} -> c
      _ -> nil
    end
  end

  defp build_result(number, api, detail, components) do
    %{
      number: number,
      obj: api["waybill_obj"],
      status: api["status_description"] || api["status_code"],
      account: api["account_reference"],
      api_sell: %{
        freight: f(api["freight_charge"]),
        sundry: f(api["sundry_charge"]),
        tax: f(api["tax_amount"]),
        total: f(api["charged_amount"])
      },
      code_sell: detail && detail.sell,
      charges: detail && detail.charges,
      code_buy: detail && detail.buy,
      components: components,
      expected: detail && detail.expected,
      weight: detail && detail.weight
    }
  end

  # ── render ──────────────────────────────────────────────────────────────────
  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl p-4">
      <div class="mb-3 flex items-center justify-between gap-2">
        <h1 class="text-lg font-semibold">Buy / sell verification</h1>
        <div class="flex items-center gap-2 text-xs">
          <span class="opacity-60">{@current_user.email}</span>
          <a href="/logout" class="btn btn-ghost btn-xs">Log out</a>
        </div>
      </div>

      <p class="mb-4 text-sm opacity-60">{intro()}</p>

      <.methodology />

      <form phx-submit="reconcile" class="mb-2 mt-6 flex flex-wrap items-end gap-2">
        <div>
          <label class="mb-1 block text-xs opacity-60">Waybill number</label>
          <input
            name="waybill"
            value={@query}
            placeholder="e.g. 100123456"
            autocomplete="off"
            class="input input-bordered input-sm w-64 font-mono"
          />
        </div>
        <button type="submit" class="btn btn-primary btn-sm" disabled={@loading}>
          {(@loading && "Reconciling…") || "Reconcile"}
        </button>
        <span class="text-xs opacity-60">{fw_status(@fw_ready)}</span>
      </form>

      <div :if={@error} class="my-3 rounded border border-error p-3 text-sm text-error">
        {@error}
      </div>

      <.result :if={@result} r={@result} />
    </div>
    """
  end

  # ── methodology documentation ───────────────────────────────────────────────
  defp methodology(assigns) do
    ~H"""
    <div class="collapse collapse-arrow rounded border bg-base-100">
      <input type="checkbox" checked />
      <div class="collapse-title text-sm font-medium">
        How buy &amp; sell are calculated (methodology)
      </div>
      <div class="collapse-content space-y-3 text-xs leading-relaxed">
        <div>
          <div class="font-semibold">Sell (customer revenue)</div>
          <p class="font-mono opacity-70">{sell_formula()}</p>
          <p class="opacity-80">{sell_doc()}</p>
        </div>
        <div>
          <div class="font-semibold">Buy — actual (what the supplier was paid)</div>
          <p class="font-mono opacity-70">{buy_actual_formula()}</p>
          <p class="opacity-80">{buy_actual_doc()}</p>
        </div>
        <div>
          <div class="font-semibold">Buy — expected (what the rate card says it should cost)</div>
          <p class="font-mono opacity-70">{expected_formula()}</p>
          <p class="opacity-80">{expected_doc()}</p>
        </div>
      </div>
    </div>
    """
  end

  # ── result panels ───────────────────────────────────────────────────────────
  defp result(assigns) do
    ~H"""
    <div class="mt-4 space-y-5">
      <div class="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm">
        <span class="font-semibold">WB {@r.number}</span>
        <span class="opacity-60">obj {@r.obj}</span>
        <span :if={@r.account} class="opacity-60">acct {@r.account}</span>
        <span :if={@r.status} class="opacity-60">status {@r.status}</span>
        <span :if={@r.weight} class="opacity-60">weight {@r.weight}</span>
      </div>

      <div>
        <div class="mb-1 text-sm font-medium">Sell — our code vs FreightWare API</div>
        <table class="table table-xs w-full">
          <thead>
            <tr>
              <th>Component</th>
              <th class="text-right">Our code (replica)</th>
              <th class="text-right">FreightWare API</th>
              <th class="text-right">Δ</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>Freight charge</td>
              <td class="text-right opacity-40">— not split</td>
              <td class="text-right">{money(@r.api_sell.freight)}</td>
              <td class="text-right opacity-40">—</td>
            </tr>
            <tr>
              <td>Sundry / surcharge</td>
              <td class="text-right opacity-40">— not split</td>
              <td class="text-right">{money(@r.api_sell.sundry)}</td>
              <td class="text-right opacity-40">—</td>
            </tr>
            <tr>
              <td>Tax</td>
              <td class="text-right opacity-40">— not split</td>
              <td class="text-right">{money(@r.api_sell.tax)}</td>
              <td class="text-right opacity-40">—</td>
            </tr>
            <tr class="font-semibold">
              <td>Total sell</td>
              <td class="text-right">{money(@r.code_sell)}</td>
              <td class="text-right">{money(@r.api_sell.total)}</td>
              <td class={"text-right #{delta_cls(delta(@r.code_sell, @r.api_sell.total))}"}>
                {money(delta(@r.code_sell, @r.api_sell.total))}
              </td>
            </tr>
          </tbody>
        </table>
        <p class="mt-1 text-xs opacity-60">{sell_note()}</p>
      </div>

      <div>
        <div class="mb-1 text-sm font-medium">Buy actual — FreightWare recorded charges</div>
        <table :if={@r.charges} class="table table-xs w-full">
          <thead>
            <tr>
              <th>Supplier</th>
              <th>Type</th>
              <th class="text-right">total_charge_amount</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={c <- @r.charges}>
              <td>{c.supplier}</td>
              <td>{c.type}</td>
              <td class="text-right">{money(c.amount)}</td>
            </tr>
            <tr :if={@r.charges == []}>
              <td colspan="3" class="opacity-60">No contractor charges recorded.</td>
            </tr>
            <tr class="font-semibold">
              <td colspan="2">Total buy actual (Σ total_charge_amount)</td>
              <td class="text-right">{money(@r.code_buy)}</td>
            </tr>
          </tbody>
        </table>
        <p :if={!@r.charges} class="text-xs opacity-60">{no_charges_note()}</p>
      </div>

      <div>
        <div class="mb-1 text-sm font-medium">Buy expected — rate-engine components</div>
        <table :if={@r.components} class="table table-xs w-full">
          <tbody>
            <tr>
              <td>Chargeable weight (CW)</td>
              <td class="text-right">{num(@r.components.chargable_units)}</td>
            </tr>
            <tr>
              <td>First-unit breakpoint (from_unit)</td>
              <td class="text-right">{num(@r.components.from_unit)}</td>
            </tr>
            <tr>
              <td>Minimum (base_amount)</td>
              <td class="text-right">{money(@r.components.minimum)}</td>
            </tr>
            <tr>
              <td>Rate (increment_amount / increment_unit)</td>
              <td class="text-right">{rate_str(@r.components)}</td>
            </tr>
            <tr>
              <td>Base subtotal = min + rate × (CW − from_unit)</td>
              <td class="text-right">{money(@r.components.base_subtotal)}</td>
            </tr>
            <tr>
              <td>Fuel surcharge (SCFUEL %)</td>
              <td class="text-right">{fuel_str(@r.components)}</td>
            </tr>
            <tr class="text-warning">
              <td>Sundry / area (fwm_sundry_postcode)</td>
              <td class="text-right">{money(@r.components.sundry)} — pending</td>
            </tr>
            <tr class="font-semibold">
              <td>Total expected = base × (1 + fuel%) + sundry</td>
              <td class="text-right">{money(@r.expected)}</td>
            </tr>
            <tr class="font-semibold">
              <td>vs Buy actual</td>
              <td class={"text-right #{delta_cls(delta(@r.expected, @r.code_buy))}"}>
                {money(delta(@r.expected, @r.code_buy))}
              </td>
            </tr>
          </tbody>
        </table>
        <p :if={!@r.components} class="text-xs opacity-60">{no_expected_note()}</p>
      </div>
    </div>
    """
  end

  # ── doc strings + composed cells (single {} nodes stay formatter-stable) ──────
  defp intro do
    "Reconcile our computed buy & sell figures against FreightWare, component by component. Sell is checked against the live FW API; buy against FW's recorded charges in the replica (the API does not expose supplier cost)."
  end

  defp sell_formula, do: "sell = fwt_waybill.total_cost"

  defp sell_doc do
    "The all-in customer charge; equals the FW API chargedAmount (= freightCharge + sundryCharge + tax). The margin dashboard uses total_cost directly and does not split surcharges out of sell. The reconcile shows the API split beside our single total."
  end

  defp buy_actual_formula, do: "buy = Σ fwt_contractor_charge.total_charge_amount"

  defp buy_actual_doc do
    "Every charge line on the waybill (collection, line-haul, delivery, SUR legs), grouped by station_contractor. Caveat under review: some sundry lines hold their value in charge_amount with total_charge_amount = 0."
  end

  defp expected_formula do
    "expected = ((CW − from_unit) × rate + minimum) × (1 + fuel%) + sundry"
  end

  defp expected_doc do
    "rate/minimum/band come from the delivery supplier's card (fwm_entity_rate → fwm_rate_table); the supplier is the charge-side contractor whose rate area covers the consignee postcode. fuel% = that supplier's SCFUEL (fwm_charge), effective-dated, clamped 0–50%. sundry (fwm_sundry_postcode) is not yet implemented — shown as pending. Uses today's rates."
  end

  defp sell_note do
    "Total sell should match — both are the customer charge. A non-zero Δ means our replica total_cost is out of step with the live API."
  end

  defp no_charges_note, do: "Not in the replica (or replica read failed) — no buy breakdown."

  defp no_expected_note do
    "No 3rd-party rate card for this waybill's delivery supplier (own-fleet, or the rate area does not cover the destination) — expected not computable."
  end

  defp rate_str(c), do: money(c.increment_amount) <> " / " <> num(c.increment_unit)

  defp fuel_str(c), do: num(c.fuel_percent) <> "% (×" <> num(c.fuel_multiplier) <> ")"

  defp fw_status(true), do: "FreightWare: session ready"
  defp fw_status(false), do: "FreightWare: no session (a call will log in)"

  # ── formatting ──────────────────────────────────────────────────────────────
  defp delta(nil, _), do: nil
  defp delta(_, nil), do: nil
  defp delta(a, b), do: f(a) - f(b)

  defp delta_cls(nil), do: "opacity-40"
  defp delta_cls(d) when abs(d) < 0.01, do: "text-success"
  defp delta_cls(_), do: "text-error"

  defp money(nil), do: "—"
  defp money(v), do: "R" <> :erlang.float_to_binary(f(v), decimals: 2)

  defp num(nil), do: "—"
  defp num(%Decimal{} = d), do: num(Decimal.to_float(d))
  defp num(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)

  defp num(s) when is_binary(s) do
    case Float.parse(s) do
      {v, _} -> :erlang.float_to_binary(v, decimals: 2)
      :error -> s
    end
  end

  defp f(nil), do: 0.0
  defp f(%Decimal{} = d), do: Decimal.to_float(d)
  defp f(n) when is_number(n), do: n * 1.0

  defp f(s) when is_binary(s) do
    case Float.parse(s) do
      {v, _} -> v
      :error -> 0.0
    end
  end

  # waybill_obj is numeric; strip to a bare integer literal for the SQL predicate.
  defp digits(obj) do
    obj |> to_string() |> String.split(".") |> List.first() |> String.replace(~r/[^0-9]/, "")
  end
end
