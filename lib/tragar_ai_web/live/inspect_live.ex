defmodule TragarAiWeb.InspectLive do
  @moduledoc """
  Hidden, read-only DB inspection console — intentionally NOT in the app menu.

  Two ways to run a query, both in-app against the FreightWare replica via
  `TragarAi.Insight.Db`, streaming results into a live log so raw data stays
  inside Tragar's own infrastructure:

    * the **catalog** — clickable read-only SELECTs authored by Claude Code (which
      never sees results, only writes the catalog file); you click one to run it;
    * a **free-text** box for your own ad-hoc SELECTs.

  Read-only: the bridge refuses anything that isn't a single SELECT. Admin-only
  — gated at the route by the `:inspect` page permission (the old `?token=` gate
  is retired; role membership is the gate now).
  """
  use TragarAiWeb, :live_view

  alias TragarAi.Accounts
  alias TragarAi.Insight.Catalog
  alias TragarAi.Insight.Db

  # Keep the on-screen log bounded (newest-first internally, reversed for display).
  @max_lines 2000

  @impl true
  def mount(_params, _session, socket) do
    # The route gate (require_page :inspect) already ensures only admins mount;
    # re-check here for defence in depth before any query can run.
    {:ok,
     socket
     |> assign(:authorized, Accounts.can_view?(socket.assigns[:current_user], :inspect))
     |> assign(:catalog, Catalog.load())
     |> assign(:sql, "")
     |> assign(:current, nil)
     |> assign(:log, [])
     |> assign(:running, false)
     |> assign(:status, nil)
     |> assign(:job_status, nil)
     |> assign(:ref, nil)
     |> assign(:quote_result, nil)
     |> assign(:quote_params, default_quote_params())}
  end

  @impl true
  def handle_event("reload_catalog", _params, socket) do
    {:noreply, assign(socket, :catalog, Catalog.load())}
  end

  def handle_event("run_catalog", %{"id" => id}, %{assigns: %{authorized: true}} = socket) do
    case Catalog.fetch(id) do
      %{title: title, sql: sql} when is_binary(sql) ->
        {:noreply, start_query(socket, sql, title)}

      _ ->
        {:noreply, assign(socket, :status, "not a SQL entry")}
    end
  end

  # Fill the quick-quote form from a catalog "quote" test case (params are the same
  # string-keyed fields the form submits). You then click Run quote to execute it.
  def handle_event("fill_quote", %{"id" => id}, %{assigns: %{authorized: true}} = socket) do
    case Catalog.fetch(id) do
      # Real-data case: run the SELECT in-app, fill the form from its first row
      # (columns aliased to the form field names). The real lane never enters
      # Claude's session — Claude only authored the query.
      %{quote_sql: sql} when is_binary(sql) ->
        case Db.query_rows(sql) do
          {:ok, [row | _]} ->
            {:noreply,
             socket
             |> assign(:quote_params, Map.merge(default_quote_params(), row))
             |> assign(:status, "form filled from a real lane — click Run quote below")}

          {:ok, []} ->
            {:noreply, assign(socket, :status, "quote_sql returned no rows")}

          {:error, reason} ->
            {:noreply, assign(socket, :status, "quote_sql error — #{inspect(reason)}")}
        end

      # Static case: params baked into the entry.
      %{quote: quote} when is_map(quote) ->
        {:noreply,
         socket
         |> assign(:quote_params, Map.merge(default_quote_params(), quote))
         |> assign(:status, "form filled — click Run quote below")}

      _ ->
        {:noreply, assign(socket, :status, "not a quote entry")}
    end
  end

  def handle_event("run", %{"sql" => sql}, %{assigns: %{authorized: true}} = socket) do
    {:noreply, start_query(socket, sql, "ad-hoc")}
  end

  def handle_event("delete_catalog", %{"id" => id}, %{assigns: %{authorized: true}} = socket) do
    status =
      case Catalog.delete(id) do
        :ok -> "deleted catalog query"
        {:error, reason} -> "delete failed — #{inspect(reason)}"
      end

    {:noreply, socket |> assign(:catalog, Catalog.load()) |> assign(:status, status)}
  end

  # Enqueue the supplier-cost warehouse rebuild as a background Oban job — it runs
  # in-app (never in a user request or an operator's session); we only enqueue here.
  def handle_event("rebuild_supplier_costs", _params, %{assigns: %{authorized: true}} = socket) do
    status =
      case TragarAi.Insight.SupplierCostWorker.new(%{}) |> Oban.insert() do
        {:ok, _job} -> "supplier-cost rebuild enqueued — runs in the background (see logs)"
        {:error, reason} -> "could not enqueue — #{inspect(reason)}"
      end

    {:noreply, assign(socket, :job_status, status)}
  end

  # Run a FreightWare quick-quote IN-APP (never from Claude's session) — the same
  # data-blind rule as the DB console: Claude authors the form, you execute it here
  # and see the esRates. Supplier-as-account / site codes are filled in by you.
  def handle_event("run_quote", params, %{assigns: %{authorized: true}} = socket) do
    qp = %{
      "account_reference" => params["account_reference"],
      "service_type" => params["service_type"],
      "consignor_site" => params["consignor_site"],
      "consignor_suburb" => params["consignor_suburb"],
      "consignor_city" => params["consignor_city"],
      "collection_postal_code" => params["collection_postal_code"],
      "consignee_site" => params["consignee_site"],
      "consignee_suburb" => params["consignee_suburb"],
      "consignee_city" => params["consignee_city"],
      "delivery_postal_code" => params["delivery_postal_code"],
      "items" => [
        %{
          "quantity" => 1,
          "weight" => params["weight"],
          "length" => params["length"],
          "width" => params["width"],
          "height" => params["height"]
        }
      ]
    }

    {:noreply,
     socket
     |> assign(:quote_params, params)
     |> assign(:quote_result, TragarAi.Freight.quick_quote(qp))}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:db_row, ref, line}, %{assigns: %{ref: ref}} = socket) do
    {:noreply, update(socket, :log, fn log -> Enum.take([line | log], @max_lines) end)}
  end

  def handle_info({:db_done, ref, status}, %{assigns: %{ref: ref}} = socket) do
    label =
      case status do
        :ok -> "done"
        {:error, reason} -> "error — #{inspect(reason)}"
      end

    {:noreply, socket |> assign(:running, false) |> assign(:status, label)}
  end

  # Stale messages from a superseded query — ignore.
  def handle_info({:db_row, _ref, _line}, socket), do: {:noreply, socket}
  def handle_info({:db_done, _ref, _status}, socket), do: {:noreply, socket}

  defp start_query(socket, sql, label) do
    case Db.stream(sql, self()) do
      ref when is_reference(ref) ->
        socket
        |> assign(:sql, sql)
        |> assign(:current, label)
        |> assign(:log, [])
        |> assign(:running, true)
        |> assign(:status, "running #{label}…")
        |> assign(:ref, ref)

      {:error, :not_select} ->
        assign(socket, :status, "refused — read-only SELECT queries only")
    end
  end

  # Format the quick-quote result for the in-app log. Raw rate maps so every
  # returned field (freightCharge / sundryCharge / totalCharge per service) shows.
  defp quote_output({:ok, rates}) do
    "OK — #{length(rates)} rate(s):\n" <>
      Enum.map_join(rates, "\n", &inspect(&1, limit: :infinity))
  end

  defp quote_output({:error, reason}), do: "ERROR: #{inspect(reason, limit: :infinity)}"
  defp quote_output(_), do: ""

  # Field name + placeholder for the in-app quick-quote form, rendered via :for so
  # each input line stays short (formatter-stable).
  defp quote_fields do
    [
      {"account_reference", "accountReference"},
      {"service_type", "serviceType (blank=all)"},
      {"consignor_site", "consignorSite code"},
      {"consignee_site", "consigneeSite code"},
      {"consignor_suburb", "consignor suburb"},
      {"consignor_city", "consignor city"},
      {"collection_postal_code", "consignor postcode"},
      {"weight", "weight (kg)"},
      {"consignee_suburb", "consignee suburb"},
      {"consignee_city", "consignee city"},
      {"delivery_postal_code", "consignee postcode"},
      {"length", "L (cm)"},
      {"width", "W (cm)"},
      {"height", "H (cm)"}
    ]
  end

  # Blank/synthetic defaults so the form is click-ready; catalog "quote" test cases
  # merge over these. NOT real customer data (data-blind rule) — swap accountReference
  # + site codes for a real supplier to test the buy quote.
  defp default_quote_params do
    %{
      "account_reference" => "",
      "service_type" => "",
      "consignor_site" => "",
      "consignor_suburb" => "",
      "consignor_city" => "",
      "collection_postal_code" => "",
      "consignee_site" => "",
      "consignee_suburb" => "",
      "consignee_city" => "",
      "delivery_postal_code" => "",
      "weight" => "",
      "length" => "30",
      "width" => "30",
      "height" => "30"
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl p-4">
      <h1 class="mb-1 text-lg font-semibold">DB inspection console</h1>
      <p class="mb-3 text-sm opacity-60">
        Read-only. Data stays in this app — results stream below.
      </p>

      <div :if={not @authorized} class="text-sm opacity-70">Not authorized.</div>

      <div :if={@authorized}>
        <div class="mb-4 rounded border border-dashed p-2">
          <div class="flex items-center gap-2">
            <h2 class="text-sm font-medium">Warehouse jobs</h2>
            <button
              type="button"
              phx-click="rebuild_supplier_costs"
              class="btn btn-secondary btn-xs"
            >
              Rebuild supplier-cost warehouse
            </button>
            <span :if={@job_status} class="text-xs opacity-70">{@job_status}</span>
          </div>
          <p class="mt-1 text-xs opacity-60">
            Runs the ETL in the background via Oban — the aggregation stays in-app.
          </p>
        </div>

        <div class="mb-4 rounded border border-dashed p-2">
          <h2 class="text-sm font-medium">FreightWare quick quote (runs in-app)</h2>
          <p class="mt-1 text-xs opacity-60">
            POST /quotes/quick. Supplier account as accountReference; lane by site
            code + address. serviceType blank returns all rates. Results below.
          </p>
          <form phx-submit="run_quote" class="mt-2 grid grid-cols-2 gap-2 md:grid-cols-4">
            <input
              :for={{name, ph} <- quote_fields()}
              name={name}
              value={@quote_params[name]}
              placeholder={ph}
              class="rounded border p-1 text-xs"
            />
            <div class="col-span-2 md:col-span-4">
              <button type="submit" class="btn btn-primary btn-xs">Run quote</button>
            </div>
          </form>
          <pre
            :if={@quote_result}
            class="mt-2 overflow-auto rounded bg-base-200 p-2 text-xs"
            style="max-height:30vh"
          >{quote_output(@quote_result)}</pre>
        </div>

        <div class="mb-4">
          <div class="mb-1 flex items-center justify-between">
            <h2 class="text-sm font-medium">Catalog</h2>
            <button type="button" phx-click="reload_catalog" class="btn btn-ghost btn-xs">
              reload
            </button>
          </div>

          <p :if={@catalog == []} class="text-sm opacity-60">No catalog queries yet.</p>

          <div class="grid gap-2">
            <div :for={q <- @catalog} class="min-w-0 rounded border p-2">
              <div class="flex items-start justify-between gap-2">
                <span class="min-w-0 break-words text-sm font-medium">{q.title}</span>
                <div class="flex shrink-0 gap-1">
                  <button
                    :if={q.quote || q.quote_sql}
                    type="button"
                    phx-click="fill_quote"
                    phx-value-id={q.id}
                    class="btn btn-secondary btn-xs"
                  >
                    Fill form
                  </button>
                  <button
                    :if={q.sql}
                    type="button"
                    phx-click="run_catalog"
                    phx-value-id={q.id}
                    class="btn btn-primary btn-xs"
                    disabled={@running}
                  >
                    Run
                  </button>
                  <button
                    type="button"
                    phx-click="delete_catalog"
                    phx-value-id={q.id}
                    data-confirm={"Delete catalog entry “#{q.title}”?"}
                    class="btn btn-ghost btn-xs text-error"
                    disabled={@running}
                  >
                    Delete
                  </button>
                </div>
              </div>
              <p :if={q.description != ""} class="text-xs opacity-70">{q.description}</p>
              <pre
                :if={q.sql}
                class="mt-1 max-w-full overflow-x-auto whitespace-pre-wrap break-words rounded bg-base-200 p-2 text-xs"
              >{q.sql}</pre>
              <pre
                :if={q.quote}
                class="mt-1 max-w-full overflow-x-auto whitespace-pre-wrap break-words rounded bg-base-200 p-2 text-xs"
              >{inspect(q.quote, pretty: true)}</pre>
              <pre
                :if={q.quote_sql}
                class="mt-1 max-w-full overflow-x-auto whitespace-pre-wrap break-words rounded bg-base-200 p-2 text-xs"
              >{q.quote_sql}</pre>
            </div>
          </div>
        </div>

        <form phx-submit="run" class="mb-3">
          <textarea
            name="sql"
            rows="10"
            wrap="soft"
            spellcheck="false"
            class="w-full rounded border p-2 font-mono text-sm leading-snug"
            style="resize: vertical; min-height: 8rem;"
            placeholder="SELECT … (read-only ad-hoc query)"
          >{@sql}</textarea>
          <div class="mt-2 flex items-center gap-3">
            <button type="submit" class="btn btn-primary btn-sm" disabled={@running}>Run</button>
            <span class="text-sm opacity-70">{@status}</span>
          </div>
        </form>

        <pre
          class="overflow-auto rounded bg-base-200 p-3 font-mono text-xs"
          style="max-height:60vh"
        >{Enum.join(Enum.reverse(@log), "\n")}</pre>
      </div>
    </div>
    """
  end
end
