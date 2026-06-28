defmodule TragarAiWeb.DashboardLive do
  @moduledoc """
  Integration monitor — the landing page. Tracks the two Freshdesk flows:

    * **Ticket auto-answer** — AI responses grouped by ticket, with the
      request→response time (latency) for each turn.
    * **Quote creation** — the per-ticket guided quote sessions and their status.

  Built for watching the integration and the time-to-response users experience.
  Auto-refreshes every few seconds.
  """
  use TragarAiWeb, :live_view

  alias TragarAi.Assist
  alias TragarAi.Dashboard
  alias TragarAi.QuoteIntake

  # Push updates are instant via PubSub; this slow tick only keeps the relative
  # timestamps ("2m ago") fresh between changes.
  @tick_ms 15_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Dashboard.subscribe()
      Process.send_after(self(), :tick, @tick_ms)
    end

    {:ok, load(socket)}
  end

  # A tracked flow changed (ticket answered / quote advanced) — re-render now.
  @impl true
  def handle_info(:dashboard_changed, socket), do: {:noreply, load(socket)}

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, load(socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  # ── Data ──────────────────────────────────────────────────────────────────────

  defp load(socket) do
    interactions = ticket_interactions()
    tickets = group_by_ticket(interactions)
    quotes = quote_sessions()

    assign(socket,
      tickets: tickets,
      quotes: quotes,
      metrics: metrics(interactions, tickets, quotes),
      updated_at: DateTime.utc_now()
    )
  end

  # Only ticket-linked interactions (console/chat lookups carry no ticket_id).
  defp ticket_interactions do
    case Assist.list_interactions() do
      {:ok, list} -> Enum.reject(list, &(&1.ticket_id in [nil, ""]))
      _ -> []
    end
  end

  defp group_by_ticket(interactions) do
    interactions
    |> Enum.group_by(& &1.ticket_id)
    |> Enum.map(fn {ticket_id, turns} ->
      turns = Enum.sort_by(turns, & &1.inserted_at, {:desc, DateTime})
      durations = turns |> Enum.map(& &1.duration_ms) |> Enum.reject(&is_nil/1)

      %{
        ticket_id: ticket_id,
        account: Enum.find_value(turns, &account_of/1),
        turns: turns,
        count: length(turns),
        last: hd(turns),
        avg_ms: avg(durations)
      }
    end)
    |> Enum.sort_by(& &1.last.inserted_at, {:desc, DateTime})
    |> Enum.take(50)
  end

  defp quote_sessions do
    case QuoteIntake.list_sessions() do
      {:ok, list} -> list |> Enum.sort_by(& &1.updated_at, {:desc, DateTime}) |> Enum.take(50)
      _ -> []
    end
  end

  defp metrics(interactions, tickets, quotes) do
    durations = interactions |> Enum.map(& &1.duration_ms) |> Enum.reject(&is_nil/1)

    %{
      tickets: length(tickets),
      responses: length(interactions),
      avg_ms: avg(durations),
      p95_ms: p95(durations),
      failures: Enum.count(interactions, &(&1.status == :failed)),
      quotes_open: Enum.count(quotes, &(&1.quote_number in [nil, ""])),
      quotes_created: Enum.count(quotes, &(&1.quote_number not in [nil, ""]))
    }
  end

  defp account_of(%{entities: e}) when is_map(e), do: e["account"]
  defp account_of(_), do: nil

  defp avg([]), do: nil
  defp avg(xs), do: round(Enum.sum(xs) / length(xs))

  defp p95([]), do: nil

  defp p95(xs) do
    sorted = Enum.sort(xs)
    Enum.at(sorted, max(0, round(0.95 * length(sorted)) - 1))
  end

  # ── Render ────────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 lg:p-6 space-y-6 max-w-6xl mx-auto">
      <Layouts.app_nav active={:dashboard} />

      <header class="flex items-end justify-between gap-3">
        <div>
          <h1 class="text-2xl font-semibold">Tragar · Integration monitor</h1>
          <p class="text-sm text-base-content/60">
            Freshdesk ticket auto-answers and quote sessions, with request→response times.
          </p>
        </div>
        <div class="text-right shrink-0">
          <button class="btn btn-sm btn-ghost" phx-click="refresh">↻ Refresh</button>
          <div class="text-[11px] text-base-content/50">
            live · updated {ago(@updated_at)}
          </div>
        </div>
      </header>

      <div class="stats stats-vertical sm:stats-horizontal shadow w-full">
        <div class="stat">
          <div class="stat-title">Tickets answered</div>
          <div class="stat-value text-3xl">{@metrics.tickets}</div>
          <div class="stat-desc">{@metrics.responses} AI responses</div>
        </div>
        <div class="stat">
          <div class="stat-title">Avg response time</div>
          <div class="stat-value text-3xl">{ms(@metrics.avg_ms)}</div>
          <div class="stat-desc">p95 {ms(@metrics.p95_ms)}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Failures</div>
          <div class={"stat-value text-3xl " <> if(@metrics.failures > 0, do: "text-error", else: "")}>
            {@metrics.failures}
          </div>
          <div class="stat-desc">refused / errored answers</div>
        </div>
        <div class="stat">
          <div class="stat-title">Quote sessions</div>
          <div class="stat-value text-3xl">{@metrics.quotes_created}</div>
          <div class="stat-desc">{@metrics.quotes_open} in progress</div>
        </div>
      </div>

      <%!-- Ticket auto-answers, grouped by ticket --%>
      <section class="space-y-3">
        <h2 class="text-lg font-semibold">Ticket responses</h2>

        <p :if={@tickets == []} class="text-sm text-base-content/50 py-6 text-center">
          No ticket-linked AI responses yet. They appear here once Freshdesk posts a ticket to <code>/api/tickets/answer</code>.
        </p>

        <div :for={t <- @tickets} class="card border border-base-300 bg-base-100">
          <div class="card-body p-4 gap-2">
            <div class="flex items-center justify-between gap-3 flex-wrap">
              <div class="flex items-center gap-2">
                <span class="font-mono font-semibold">#{t.ticket_id}</span>
                <span :if={t.account} class="badge badge-sm badge-ghost">{t.account}</span>
                <span class="badge badge-sm badge-outline">{t.count} turn{t.count > 1 && "s"}</span>
              </div>
              <div class="text-xs text-base-content/60">
                last {ago(t.last.inserted_at)} · avg {ms(t.avg_ms)}
              </div>
            </div>

            <table class="table table-xs">
              <thead>
                <tr>
                  <th>When</th>
                  <th>Question</th>
                  <th>Intent</th>
                  <th>Source</th>
                  <th>Status</th>
                  <th class="text-right">Response time</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={i <- t.turns}>
                  <td class="whitespace-nowrap text-base-content/60">{ago(i.inserted_at)}</td>
                  <td class="max-w-xs truncate" title={i.question}>{i.question}</td>
                  <td>{i.intent || "—"}</td>
                  <td>{i.source || "—"}</td>
                  <td><span class={"badge badge-xs " <> status_class(i.status)}>{i.status}</span></td>
                  <td class="text-right font-mono">{ms(i.duration_ms)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <%!-- Quote creation sessions --%>
      <section class="space-y-3">
        <h2 class="text-lg font-semibold">Quote sessions</h2>

        <p :if={@quotes == []} class="text-sm text-base-content/50 py-6 text-center">
          No quote sessions yet.
        </p>

        <table :if={@quotes != []} class="table table-sm">
          <thead>
            <tr>
              <th>Ticket</th>
              <th>Account</th>
              <th>Status</th>
              <th>Quote #</th>
              <th class="text-right">Last activity</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={q <- @quotes}>
              <td class="font-mono">#{q.ticket_id}</td>
              <td>{q.account_reference}</td>
              <td><span class={"badge badge-xs " <> quote_class(q)}>{q.status}</span></td>
              <td class="font-mono">{q.quote_number || "—"}</td>
              <td class="text-right text-base-content/60">{ago(q.updated_at)}</td>
            </tr>
          </tbody>
        </table>
      </section>
    </div>
    """
  end

  # ── View helpers ──────────────────────────────────────────────────────────────

  defp status_class(:drafted), do: "badge-success"
  defp status_class(:relayed), do: "badge-success"
  defp status_class(:reasoned), do: "badge-info"
  defp status_class(:failed), do: "badge-error"
  defp status_class(_), do: "badge-ghost"

  defp quote_class(%{quote_number: n}) when n not in [nil, ""], do: "badge-success"
  defp quote_class(%{status: "choosing_account"}), do: "badge-warning"
  defp quote_class(_), do: "badge-info"

  defp ms(nil), do: "—"
  defp ms(ms) when ms < 1000, do: "#{ms}ms"
  defp ms(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp ago(nil), do: "—"

  defp ago(%DateTime{} = dt) do
    case DateTime.diff(DateTime.utc_now(), dt, :second) do
      s when s < 5 -> "just now"
      s when s < 60 -> "#{s}s ago"
      s when s < 3600 -> "#{div(s, 60)}m ago"
      s when s < 86_400 -> "#{div(s, 3600)}h ago"
      s -> "#{div(s, 86_400)}d ago"
    end
  end
end
