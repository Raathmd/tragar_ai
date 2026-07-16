defmodule TragarAiWeb.InspectLive do
  @moduledoc """
  Hidden, read-only DB inspection console — intentionally NOT in the app menu.

  Runs SELECTs against the FreightWare replica from inside this app (via
  `TragarAi.Insight.Db`) and streams the result lines into a live log, so the raw
  data stays inside Tragar's own infrastructure and never leaves through anything
  external. Read-only: the bridge refuses anything that isn't a single SELECT.

  Gated by `:inspect_token` when configured — reach it at `/_inspect?token=…`.
  """
  use TragarAiWeb, :live_view

  alias TragarAi.Insight.Db

  # Keep the on-screen log bounded (newest-first internally, reversed for display).
  @max_lines 2000

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:authorized, authorized?(params))
     |> assign(:sql, "")
     |> assign(:log, [])
     |> assign(:running, false)
     |> assign(:status, nil)
     |> assign(:ref, nil)}
  end

  @impl true
  def handle_event("run", %{"sql" => sql}, %{assigns: %{authorized: true}} = socket) do
    case Db.stream(sql, self()) do
      ref when is_reference(ref) ->
        {:noreply,
         socket
         |> assign(:sql, sql)
         |> assign(:log, [])
         |> assign(:running, true)
         |> assign(:status, "running…")
         |> assign(:ref, ref)}

      {:error, :not_select} ->
        {:noreply, assign(socket, :status, "refused — read-only SELECT queries only")}
    end
  end

  def handle_event("run", _params, socket), do: {:noreply, socket}

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
        <form phx-submit="run" class="mb-3">
          <textarea
            name="sql"
            rows="4"
            class="w-full rounded border p-2 font-mono text-sm"
            placeholder="SELECT … (read-only)"
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
