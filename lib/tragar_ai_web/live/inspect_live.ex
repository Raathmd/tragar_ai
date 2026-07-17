defmodule TragarAiWeb.InspectLive do
  @moduledoc """
  Hidden, read-only DB inspection console — intentionally NOT in the app menu.

  Two ways to run a query, both in-app against the FreightWare replica via
  `TragarAi.Insight.Db`, streaming results into a live log so raw data stays
  inside Tragar's own infrastructure:

    * the **catalog** — clickable read-only SELECTs authored by Claude Code (which
      never sees results, only writes the catalog file); you click one to run it;
    * a **free-text** box for your own ad-hoc SELECTs.

  Read-only: the bridge refuses anything that isn't a single SELECT. Gated by
  `:inspect_token` when configured — reach it at `/_inspect?token=…`.
  """
  use TragarAiWeb, :live_view

  alias TragarAi.Insight.Catalog
  alias TragarAi.Insight.Db

  # Keep the on-screen log bounded (newest-first internally, reversed for display).
  @max_lines 2000

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:authorized, authorized?(params))
     |> assign(:catalog, Catalog.load())
     |> assign(:sql, "")
     |> assign(:current, nil)
     |> assign(:log, [])
     |> assign(:running, false)
     |> assign(:status, nil)
     |> assign(:ref, nil)}
  end

  @impl true
  def handle_event("reload_catalog", _params, socket) do
    {:noreply, assign(socket, :catalog, Catalog.load())}
  end

  def handle_event("run_catalog", %{"id" => id}, %{assigns: %{authorized: true}} = socket) do
    case Catalog.fetch(id) do
      %{title: title, sql: sql} -> {:noreply, start_query(socket, sql, title)}
      _ -> {:noreply, assign(socket, :status, "query not found")}
    end
  end

  def handle_event("run", %{"sql" => sql}, %{assigns: %{authorized: true}} = socket) do
    {:noreply, start_query(socket, sql, "ad-hoc")}
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

  defp authorized?(params) do
    case Application.get_env(:tragar_ai, :inspect_token) do
      nil -> true
      "" -> true
      token -> params["token"] == token
    end
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
        <div class="mb-4">
          <div class="mb-1 flex items-center justify-between">
            <h2 class="text-sm font-medium">Catalog</h2>
            <button type="button" phx-click="reload_catalog" class="btn btn-ghost btn-xs">
              reload
            </button>
          </div>

          <p :if={@catalog == []} class="text-sm opacity-60">No catalog queries yet.</p>

          <div class="grid gap-2">
            <div :for={q <- @catalog} class="rounded border p-2">
              <div class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium">{q.title}</span>
                <button
                  type="button"
                  phx-click="run_catalog"
                  phx-value-id={q.id}
                  class="btn btn-primary btn-xs"
                  disabled={@running}
                >
                  Run
                </button>
              </div>
              <p :if={q.description != ""} class="text-xs opacity-70">{q.description}</p>
              <pre class="mt-1 overflow-auto rounded bg-base-200 p-2 text-xs">{q.sql}</pre>
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
