defmodule TragarAiWeb.ConsoleLive do
  @moduledoc """
  The support-assist agent console (Phase 1).

  Three panes:

    * left — the live Freshdesk ticket queue, filterable by status (default open)
      and agent. Clicking a ticket fetches it and pre-fills the prompt with its
      actual contents (subject + body) for the agent to edit and submit.
    * centre — the prompt + the chat conversation, plus the surfaced entity
      details for whatever was looked up.
    * right — the AI progress log (interpret → validate → fetch → phrase, with the
      per-source calls), plus Recents/Details/Waybills/Quotes tabs.
  """
  use TragarAiWeb, :live_view

  require Logger

  alias TragarAi.Assist
  alias TragarAi.Assist.Engine
  alias TragarAi.Freight.Statuses

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(question: "", agent: "")
     |> assign(messages: [], frame: %{intent: nil, entities: %{}})
     |> assign(interaction: nil)
     |> assign(model: TragarAi.CoreAI.info())
     |> assign(right_tab: "log", detail: nil, detail_title: nil)
     |> assign(search_results: [], search_meta: nil)
     |> assign(quote_results: [], quote_meta: nil)
     |> assign(selected_ticket: nil, distilling: false, account_choices: [])
     |> assign(ticket_status: "open", ticket_agent: nil, agents: [])
     |> assign(next_msg_id: 0)
     |> load_history()
     |> load_agents()
     |> load_tickets()}
  end

  # ── Prompt (centre) ─────────────────────────────────────────────────────────

  # A chat turn: the AI keeps clarifying (carrying the frame) until it resolves
  # the intent, or the user ends the chat.
  @impl true
  def handle_event("ask", params, socket) do
    text = String.trim(params["question"] || "")

    socket = assign(socket, agent: params["agent"] || socket.assigns.agent)

    cond do
      text == "" ->
        {:noreply, put_flash(socket, :error, "Type a message first.")}

      ticket = parse_ticket_fetch(text) ->
        # "ticket 227703" / "#227703" → fetch that ticket, distil + resolve it.
        {:noreply, start_ticket_distil(socket, ticket)}

      spec = parse_quote_search(text) ->
        {:noreply, search_or_converse(socket, text, :quotes, spec)}

      spec = parse_waybill_search(text) ->
        {:noreply, search_or_converse(socket, text, :waybills, spec)}

      true ->
        {:noreply, converse(socket, text)}
    end
  end

  def handle_event("search_waybills", params, socket) do
    case blank_to_nil(params["account"]) do
      nil ->
        {:noreply, put_flash(socket, :error, "Enter an account to search.")}

      acc ->
        {:noreply,
         run_waybill_search(
           socket,
           acc,
           params["status"] || "all",
           blank_to_nil(params["date_from"]),
           blank_to_nil(params["date_to"])
         )}
    end
  end

  def handle_event("search_quotes", params, socket) do
    case blank_to_nil(params["account"]) do
      nil ->
        {:noreply, put_flash(socket, :error, "Enter an account to search.")}

      acc ->
        {:noreply,
         run_quote_search(
           socket,
           acc,
           params["status"] || "all",
           blank_to_nil(params["date_from"]),
           blank_to_nil(params["date_to"])
         )}
    end
  end

  def handle_event("prompt_quote", %{"number" => number}, socket) do
    socket
    |> reset_chat_state()
    |> assign(frame: %{intent: nil, entities: %{quote: number}})
    |> converse("Show quote #{number}")
    |> then(&{:noreply, &1})
  end

  # Click a waybill in the search list → auto-prompt for its latest status.
  def handle_event("prompt_waybill", %{"number" => number}, socket) do
    socket
    |> reset_chat_state()
    |> assign(frame: %{intent: nil, entities: %{waybill: number}})
    |> converse("Where is waybill #{number}?")
    |> then(&{:noreply, &1})
  end

  def handle_event("reset_chat", _params, socket),
    do: {:noreply, reset_chat_state(socket)}

  # Run a suggested query the AI offered to help resolve the request.
  def handle_event("suggest", %{"q" => q}, socket),
    do: {:noreply, converse(socket, q)}

  # ── Tickets (left, from Freshdesk) ──────────────────────────────────────────

  def handle_event("refresh_tickets", _params, socket),
    do: {:noreply, load_tickets(socket)}

  # Filter by status (default open) and/or agent — re-queries Freshdesk.
  def handle_event("filter_tickets", params, socket) do
    agent_id =
      case params["agent_id"] do
        v when v in [nil, "", "all"] -> nil
        v -> String.to_integer(v)
      end

    {:noreply,
     socket
     |> assign(ticket_status: params["status"] || "open", ticket_agent: agent_id)
     |> load_tickets()}
  end

  def handle_event("select_ticket", %{"id" => id}, socket) do
    ticket = Enum.find(socket.assigns.tickets, &(&1.id == id))
    {:noreply, assign(socket, selected_ticket: ticket)}
  end

  def handle_event("close_ticket", _params, socket),
    do: {:noreply, assign(socket, selected_ticket: nil)}

  # Click a ticket → fetch it from Freshdesk, distil its subject+body into a
  # concise query, and resolve its account — then pre-fill the prompt for editing.
  def handle_event("prompt_ticket", %{"id" => id}, socket),
    do: {:noreply, start_ticket_distil(socket, id)}

  # Fetch a ticket by number (listed or not) via the input above the ticket list.
  def handle_event("fetch_ticket", %{"ticket_no" => id}, socket) do
    case String.trim(to_string(id)) do
      "" -> {:noreply, put_flash(socket, :error, "Enter a ticket number.")}
      n -> {:noreply, start_ticket_distil(socket, n)}
    end
  end

  # Pick one account when the resolver returned several candidates, then CONTINUE
  # — re-run the pending prompt now that the account is chosen, rather than leaving
  # the agent to re-submit (which felt like a reset).
  def handle_event("pick_account", %{"ref" => ref}, socket) do
    frame = put_in(socket.assigns.frame.entities[:account], ref)
    socket = assign(socket, frame: frame, account_choices: [])

    case String.trim(socket.assigns.question || "") do
      "" -> {:noreply, socket}
      q -> {:noreply, converse(socket, q)}
    end
  end

  # ── Right panel ─────────────────────────────────────────────────────────────

  def handle_event("switch_right", %{"tab" => tab}, socket),
    do: {:noreply, assign(socket, right_tab: tab)}

  def handle_event("show_detail", %{"type" => type, "key" => key}, socket),
    do: {:noreply, load_detail(socket, type, key)}

  def handle_event("lookup_detail", %{"dtype" => type, "dkey" => key}, socket) do
    case blank_to_nil(key) do
      nil -> {:noreply, put_flash(socket, :error, "Enter a value to look up.")}
      k -> {:noreply, load_detail(socket, type, k)}
    end
  end

  # ── Rendering ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id="console" phx-hook=".DragDrop" class="p-4 lg:p-6 space-y-4">
      <Layouts.app_nav active={:console} />
      <header class="flex items-start justify-between gap-3">
        <div>
          <h1 class="text-2xl font-semibold">Tragar · Support Assist</h1>
          <p class="text-sm text-base-content/70">
            Surface facts from the source systems — look something up.
          </p>
        </div>
        <div class="text-right shrink-0">
          <div class="text-[11px] uppercase tracking-wide text-base-content/50">Core AI model</div>
          <div class="flex items-center gap-1 justify-end">
            <span class={"badge badge-sm " <> if(@model.mode == :http, do: "badge-success", else: "badge-ghost")}>
              {@model.label}
            </span>
            <span class="badge badge-sm badge-outline">{@model.mode}</span>
          </div>
        </div>
      </header>

      <div class="grid gap-4 lg:grid-cols-[260px_minmax(0,1fr)_320px]">
        <.tickets_pane
          tickets={@tickets}
          ticket_status={@ticket_status}
          ticket_agent={@ticket_agent}
          agents={@agents}
        />
        <.centre
          question={@question}
          agent={@agent}
          distilling={@distilling}
          account_choices={@account_choices}
          frame={@frame}
          messages={@messages}
          interaction={@interaction}
          model={@model}
        />
        <.right_panel
          right_tab={@right_tab}
          messages={@messages}
          interaction={@interaction}
          model={@model}
          history={@history}
          detail={@detail}
          detail_title={@detail_title}
          search_results={@search_results}
          search_meta={@search_meta}
          quote_results={@quote_results}
          quote_meta={@quote_meta}
        />
      </div>

      <.ticket_modal ticket={@selected_ticket} />

      <script :type={Phoenix.LiveView.ColocatedHook} name=".DragDrop">
        export default {
          mounted() { this.bind() },
          updated() { this.bind() },
          bind() {
            const el = this.el
            if (!el.dataset.ddBound) {
              el.dataset.ddBound = "1"
              el.addEventListener("dragstart", (e) => {
                const chip = e.target.closest("[data-snippet]")
                if (chip) e.dataTransfer.setData("text/plain", chip.getAttribute("data-snippet"))
              })
              el.addEventListener("click", (e) => {
                const chip = e.target.closest("[data-snippet][data-insert]")
                if (!chip) return
                const ta = el.querySelector("textarea[name=question]")
                if (ta) this.insert(ta, chip.getAttribute("data-snippet"))
              })
            }
            el.querySelectorAll("textarea[data-drop]").forEach((ta) => {
              if (ta.dataset.dropBound) return
              ta.dataset.dropBound = "1"
              ta.addEventListener("dragover", (e) => e.preventDefault())
              ta.addEventListener("drop", (e) => {
                e.preventDefault()
                this.insert(ta, e.dataTransfer.getData("text/plain"))
              })
            })
          },
          insert(ta, text) {
            if (!text) return
            const start = ta.selectionStart ?? ta.value.length
            const before = ta.value.slice(0, start)
            const after = ta.value.slice(start)
            const prefix = before && !before.endsWith("\n") ? "\n" : ""
            const piece = prefix + text
            ta.value = before + piece + after
            ta.focus()
            const pos = (before + piece).length
            ta.setSelectionRange(pos, pos)
          }
        }
      </script>
    </div>
    """
  end

  # ── Left pane: tickets ───────────────────────────────────────────────────────

  defp tickets_pane(assigns) do
    ~H"""
    <aside class="space-y-3">
      <div class="flex items-center justify-between">
        <h2 class="text-sm font-medium">
          Freshdesk tickets
        </h2>
        <button type="button" phx-click="refresh_tickets" class="btn btn-ghost btn-xs">
          Refresh
        </button>
      </div>

      <form phx-submit="fetch_ticket" class="flex gap-1">
        <input
          name="ticket_no"
          inputmode="numeric"
          placeholder="Fetch ticket # (any)"
          class="input input-bordered input-xs flex-1"
        />
        <button type="submit" class="btn btn-xs btn-primary">Fetch</button>
      </form>

      <form phx-change="filter_tickets" class="grid grid-cols-2 gap-2">
        <select name="status" class="select select-bordered select-xs">
          <option
            :for={s <- ~w(open pending resolved closed all)}
            value={s}
            selected={@ticket_status == s}
          >
            {String.capitalize(s)}
          </option>
        </select>
        <select name="agent_id" class="select select-bordered select-xs">
          <option value="all" selected={is_nil(@ticket_agent)}>All agents</option>
          <option :for={a <- @agents} value={a.id} selected={@ticket_agent == a.id}>{a.name}</option>
        </select>
      </form>

      <ul class="max-h-[70vh] overflow-y-auto divide-y divide-base-200 rounded-lg border border-base-300">
        <li :for={t <- @tickets}>
          <button
            type="button"
            phx-click="prompt_ticket"
            phx-value-id={t.id}
            class="w-full p-2 text-left hover:bg-base-200"
            title="Click to distil this ticket into a prompt"
          >
            <div class="flex items-start justify-between gap-2">
              <span class="text-xs font-medium">#{t.id}</span>
              <span class={"badge badge-xs " <> ticket_badge(t.status)}>{t.status}</span>
            </div>
            <div class="text-xs truncate">{t.subject}</div>
          </button>
        </li>
        <li :if={@tickets == []} class="p-3 text-xs text-base-content/60">
          No tickets for this filter.
        </li>
      </ul>
    </aside>
    """
  end

  # ── Centre: prompt + result ──────────────────────────────────────────────────

  defp centre(assigns) do
    ~H"""
    <main class="space-y-4">
      <div
        :if={@account_choices != []}
        class="rounded-lg border border-warning/40 bg-warning/10 p-2 text-sm space-y-1"
      >
        <div class="text-xs text-base-content/70">
          Several accounts match — pick one to scope this:
        </div>
        <div class="flex flex-wrap gap-1">
          <button
            :for={ref <- @account_choices}
            type="button"
            phx-click="pick_account"
            phx-value-ref={ref}
            class="btn btn-xs btn-outline"
          >
            {ref}
          </button>
        </div>
      </div>

      <div :if={@frame.entities[:account]} class="text-xs text-base-content/60">
        Scoped to account <span class="badge badge-xs badge-ghost">{@frame.entities[:account]}</span>
      </div>

      <form phx-submit="ask" class="space-y-2">
        <textarea
          name="question"
          rows="3"
          data-drop
          disabled={@distilling}
          class="textarea textarea-bordered w-full"
          placeholder="Ask Tragar AI — or click a Freshdesk ticket on the left to distil it into a prompt…"
        >{@question}</textarea>
        <div class="flex flex-wrap items-center gap-3">
          <button type="submit" class="btn btn-primary" disabled={@distilling}>Send</button>
          <button
            :if={@messages != []}
            type="button"
            phx-click="reset_chat"
            class="btn btn-ghost btn-sm"
          >
            End chat
          </button>
          <input
            name="agent"
            value={@agent}
            placeholder="Your name"
            class="input input-bordered input-sm w-32"
          />
          <span :if={@distilling} class="flex items-center gap-2 text-sm text-base-content/60">
            <span class="loading loading-spinner loading-xs"></span> Distilling ticket…
          </span>
        </div>
      </form>

      <div :if={@messages != []} class="space-y-2 max-h-[40vh] overflow-y-auto">
        <div :for={m <- @messages} class={chat_row(m.role)}>
          <div class={chat_bubble(m)}>
            <div class="text-[10px] uppercase tracking-wide opacity-60">
              {if m.role == :user, do: "You", else: "Tragar AI"}
            </div>
            <%= cond do %>
              <% m.role == :user -> %>
                {m.text}
              <% m[:pending] && m[:stream] not in [nil, ""] -> %>
                <span class="whitespace-pre-line">{m.stream}</span><span class="loading loading-dots loading-xs ml-1"></span>
              <% m[:pending] -> %>
                <span class="loading loading-dots loading-sm"></span>
                <span class="opacity-60">thinking…</span>
              <% true -> %>
                <div class="text-sm [&_a]:text-primary [&_a]:underline [&_ul]:list-disc [&_ul]:pl-5 [&_p]:my-1">
                  {Phoenix.HTML.raw(TragarAi.Markdown.to_html(m.text))}
                </div>
            <% end %>
            <div :if={m[:suggestions] not in [nil, []]} class="mt-2 flex flex-wrap gap-1">
              <button
                :for={s <- m.suggestions}
                type="button"
                phx-click="suggest"
                phx-value-q={s.q}
                class="btn btn-xs"
              >
                {s.label}
              </button>
            </div>
          </div>
        </div>
      </div>

      <details
        :if={multi_results(@interaction) != []}
        class="rounded-lg border border-base-300 p-4"
      >
        <summary class="cursor-pointer text-sm font-medium">
          Answers by source
          <span class="text-xs text-base-content/50">
            ({length(multi_results(@interaction))} lookups)
          </span>
        </summary>
        <div class="mt-3 space-y-3">
          <div
            :for={{source, rows} <- group_by_source(multi_results(@interaction))}
            class="space-y-2"
          >
            <div class="text-[11px] font-medium uppercase tracking-wide text-base-content/50">
              {source}
            </div>
            <div :for={r <- rows} class="rounded border border-base-200 p-2 space-y-1">
              <div class="flex items-center gap-2 text-xs">
                <span class="badge badge-xs badge-outline">{r["intent"]}</span>
                <span :if={result_entity(r)} class="text-base-content/60">{result_entity(r)}</span>
              </div>
              <div class="text-sm [&_a]:text-primary [&_a]:underline [&_ul]:list-disc [&_ul]:pl-5 [&_p]:my-1">
                {Phoenix.HTML.raw(TragarAi.Markdown.to_html(r["answer"]))}
              </div>
            </div>
          </div>
        </div>
      </details>

      <section
        :if={present?(@interaction)}
        id="resource-panel"
        class="rounded-lg border border-base-300 p-4 space-y-4"
      >
        <div class="flex flex-wrap items-center gap-2 text-sm">
          <span class={"badge " <> outcome_class(@interaction)}>{outcome_label(@interaction)}</span>
          <span :if={show_intent?(@interaction)} class="badge badge-ghost">
            {@interaction.intent}
          </span>
          <span :if={@interaction.source} class="text-base-content/60">
            via {@interaction.source}
          </span>
          <% pe = primary_entity(@interaction) %>
          <button
            :if={pe}
            type="button"
            phx-click="show_detail"
            phx-value-type={pe.type}
            phx-value-key={pe.key}
            class="ml-auto btn btn-ghost btn-xs"
          >
            View {pe.label} details →
          </button>
        </div>

        <%= if (fields = surfaced_fields(@interaction)) != [] do %>
          <div>
            <h3 class="text-sm font-medium mb-2">
              {@interaction.source || "Source"} details
            </h3>
            <div class="flex flex-wrap gap-2">
              <button
                :for={f <- fields}
                type="button"
                draggable="true"
                data-snippet={f.snippet}
                data-insert
                class="cursor-grab active:cursor-grabbing rounded-md border border-base-300 bg-base-200 px-2.5 py-1.5 text-left hover:border-primary"
                title="Drag or click to add to your prompt"
              >
                <span class="block text-[10px] uppercase tracking-wide text-base-content/50">
                  {f.label}
                </span>
                <span class="block text-sm">{f.value}</span>
              </button>
            </div>
          </div>
        <% end %>

        <details class="text-xs text-base-content/60">
          <summary class="cursor-pointer">Raw source payload</summary>
          <pre class="bg-base-200 rounded p-3 mt-2 overflow-x-auto">{facts_text(@interaction.facts)}</pre>
        </details>
      </section>
    </main>
    """
  end

  # ── Right pane: recents / details ────────────────────────────────────────────

  defp right_panel(assigns) do
    ~H"""
    <aside class="space-y-2">
      <div class="flex gap-1">
        <button
          type="button"
          phx-click="switch_right"
          phx-value-tab="log"
          class={tab_class(@right_tab == "log")}
        >
          AI log
        </button>
        <button
          type="button"
          phx-click="switch_right"
          phx-value-tab="recents"
          class={tab_class(@right_tab == "recents")}
        >
          Recents
        </button>
        <button
          type="button"
          phx-click="switch_right"
          phx-value-tab="details"
          class={tab_class(@right_tab == "details")}
        >
          Details
        </button>
        <button
          type="button"
          phx-click="switch_right"
          phx-value-tab="search"
          class={tab_class(@right_tab == "search")}
        >
          Waybills
        </button>
        <button
          type="button"
          phx-click="switch_right"
          phx-value-tab="quotes"
          class={tab_class(@right_tab == "quotes")}
        >
          Quotes
        </button>
      </div>

      <div :if={@right_tab == "quotes"} class="space-y-2">
        <form phx-submit="search_quotes" class="rounded-lg border border-base-300 p-2 space-y-2">
          <div class="text-[11px] text-base-content/50">Account-scoped quote search</div>
          <input
            name="account"
            placeholder="Account, e.g. ITD02"
            class="input input-bordered input-xs w-full"
          />
          <select name="status" class="select select-bordered select-xs w-full">
            <option value="all">All statuses</option>
            <option :for={{code, label} <- Statuses.quote()} value={code}>{label} ({code})</option>
          </select>
          <div class="flex gap-1">
            <input type="date" name="date_from" class="input input-bordered input-xs flex-1" />
            <input type="date" name="date_to" class="input input-bordered input-xs flex-1" />
          </div>
          <button class="btn btn-xs btn-primary w-full">Search</button>
        </form>

        <div :if={@quote_meta} class="text-[11px] text-base-content/60 px-1">
          <span :if={@quote_meta[:error]} class="text-error">Search failed: {@quote_meta.error}</span>
          <span :if={!@quote_meta[:error]}>
            {@quote_meta.account} · {@quote_meta.status} · {length(@quote_results)} of {@quote_meta.total} (account-scoped)
          </span>
        </div>

        <div class="rounded-lg border border-base-300 divide-y divide-base-200 max-h-[64vh] overflow-y-auto">
          <button
            :for={q <- @quote_results}
            type="button"
            phx-click="show_detail"
            phx-value-type="quote"
            phx-value-key={q.number}
            class="w-full p-2 text-left hover:bg-base-200"
          >
            <div class="flex items-center justify-between gap-2">
              <span class="text-xs font-medium">{q.number}</span>
              <span class="badge badge-xs badge-ghost">{q.status}</span>
            </div>
            <div class="text-[11px] text-base-content/50">{q.consignee} · {q.amount}</div>
          </button>
          <div :if={@quote_results == [] and @quote_meta} class="p-3 text-xs text-base-content/60">
            No {@quote_meta.status} quotes in the window.
          </div>
          <div :if={is_nil(@quote_meta)} class="p-3 text-xs text-base-content/60">
            Search an account's quotes — or ask “accepted quotes for ITD02”.
          </div>
        </div>
      </div>

      <div :if={@right_tab == "search"} class="space-y-2">
        <form phx-submit="search_waybills" class="rounded-lg border border-base-300 p-2 space-y-2">
          <div class="text-[11px] text-base-content/50">Account-scoped waybill search</div>
          <input
            name="account"
            placeholder="Account, e.g. ITD02"
            class="input input-bordered input-xs w-full"
          />
          <select name="status" class="select select-bordered select-xs w-full">
            <option value="all">All statuses</option>
            <option value="undelivered">Undelivered</option>
            <option value="delivered">Delivered</option>
            <option disabled>── exact status ──</option>
            <option :for={{code, label} <- Statuses.waybill()} value={code}>{label} ({code})</option>
          </select>
          <div class="flex gap-1">
            <input type="date" name="date_from" class="input input-bordered input-xs flex-1" />
            <input type="date" name="date_to" class="input input-bordered input-xs flex-1" />
          </div>
          <button class="btn btn-xs btn-primary w-full">Search</button>
        </form>

        <div :if={@search_meta} class="text-[11px] text-base-content/60 px-1">
          <span :if={@search_meta[:error]} class="text-error">
            Search failed: {@search_meta.error}
          </span>
          <span :if={!@search_meta[:error]}>
            {@search_meta.account} · {@search_meta.status} · {length(@search_results)} of {@search_meta.total} (account-scoped)
          </span>
        </div>

        <div class="rounded-lg border border-base-300 divide-y divide-base-200 max-h-[64vh] overflow-y-auto">
          <div
            :for={w <- @search_results}
            class="w-full p-2 flex items-center justify-between gap-2 hover:bg-base-200"
          >
            <button
              type="button"
              phx-click="prompt_waybill"
              phx-value-number={w.number}
              class="text-left flex-1 min-w-0"
            >
              <div class="text-xs font-medium">{w.number}</div>
              <div class="text-[11px] text-base-content/50 truncate">{w.consignee} · {w.date}</div>
            </button>
            <div class="flex items-center gap-1 shrink-0">
              <span class="badge badge-xs badge-ghost">{w.status}</span>
              <a
                :if={w.pod_url}
                href={w.pod_url}
                target="_blank"
                rel="noopener noreferrer"
                class="btn btn-xs btn-outline btn-primary"
                title="View proof of delivery"
              >
                View
              </a>
            </div>
          </div>
          <div :if={@search_results == [] and @search_meta} class="p-3 text-xs text-base-content/60">
            No {@search_meta.status} waybills in the window.
          </div>
          <div :if={is_nil(@search_meta)} class="p-3 text-xs text-base-content/60">
            Search an account's waybills — or ask “undelivered waybills for ITD02”.
          </div>
        </div>
      </div>

      <div :if={@right_tab == "log"} class="space-y-3 max-h-[74vh] overflow-y-auto">
        <ul :if={live_steps(@messages) != []} class="space-y-0.5 text-[11px]">
          <li :for={s <- live_steps(@messages)} class="flex items-center gap-1.5">
            <span class={"badge badge-xs " <> step_badge(s.status)}>{step_icon(s.status)}</span>
            <span>{s.source} · {s.intent}</span>
            <span :if={s.entity} class="opacity-60">{s.entity}</span>
          </li>
        </ul>

        <section :if={@interaction} class="rounded-lg border border-base-300 bg-base-200/40 p-3">
          <div class="flex items-center justify-between mb-2">
            <h3 class="text-xs font-medium uppercase tracking-wide text-base-content/60">
              AI steps · interpret → validate → fetch → phrase
            </h3>
            <span class="text-[11px] text-base-content/50">model: {@model.label}</span>
          </div>
          <ol class="space-y-1.5">
            <li
              :for={s <- loop_trace(@interaction, @model.label)}
              class="flex items-start gap-2 text-xs"
            >
              <span class={"badge badge-xs mt-0.5 " <> step_class(s.status)}>{s.status}</span>
              <div class="min-w-0">
                <div class="font-medium">{s.label}</div>
                <div class="text-base-content/60 break-words">{s.detail}</div>
              </div>
            </li>
          </ol>
        </section>

        <section
          :if={@interaction && @interaction.tool_log not in [nil, []]}
          class="rounded-lg border border-base-300 p-3"
        >
          <h3 class="text-xs font-medium uppercase tracking-wide text-base-content/60 mb-2">
            Source & tool calls
          </h3>
          <ol class="space-y-2">
            <li :for={c <- @interaction.tool_log} class="text-xs">
              <div class="flex items-center gap-2">
                <span class={"badge badge-xs " <> call_class(c["kind"], c["ok"])}>{c["kind"]}</span>
                <code class="text-[12px]">{c["tool"]}({format_params(c["params"])})</code>
                <span :if={c["ok"] == false} class="badge badge-xs badge-error">error</span>
              </div>
              <details class="mt-1">
                <summary class="cursor-pointer text-base-content/50">data</summary>
                <pre class="bg-base-200 rounded p-2 mt-1 overflow-x-auto">{call_data(c["result"])}</pre>
              </details>
            </li>
          </ol>
        </section>

        <div
          :if={is_nil(@interaction) and live_steps(@messages) == []}
          class="p-2 text-xs text-base-content/60"
        >
          The AI progress log appears here when you run a query.
        </div>
      </div>

      <div
        :if={@right_tab == "recents"}
        class="rounded-lg border border-base-300 divide-y divide-base-200 max-h-[72vh] overflow-y-auto"
      >
        <div :for={i <- @history} class="p-2">
          <div class="flex items-center justify-between gap-2">
            <span class="text-xs truncate">{i.question}</span>
            <span class={"badge badge-xs " <> outcome_class(i)}>{outcome_label(i)}</span>
          </div>
        </div>
        <div :if={@history == []} class="p-3 text-xs text-base-content/60">No interactions yet.</div>
      </div>

      <div :if={@right_tab == "details"} class="space-y-2">
        <form phx-submit="lookup_detail" class="rounded-lg border border-base-300 p-2 space-y-2">
          <select name="dtype" class="select select-bordered select-xs w-full">
            <option value="shipment">Waybill</option>
            <option value="quote">Quote</option>
            <option value="invoice">Invoice (account)</option>
            <option value="customer">Account</option>
          </select>
          <div class="flex gap-1">
            <input name="dkey" placeholder="e.g. 4821" class="input input-bordered input-xs flex-1" />
            <button class="btn btn-xs btn-primary">Fetch</button>
          </div>
        </form>

        <div
          :if={@detail}
          class="rounded-lg border border-base-300 p-3 max-h-[72vh] overflow-y-auto space-y-3"
        >
          <%!-- Header: title + status + POD --%>
          <div class="flex items-center justify-between gap-2">
            <h4 class="text-sm font-medium truncate">{@detail_title}</h4>
            <div class="flex items-center gap-1 shrink-0">
              <span :if={detail_status(@detail)} class="badge badge-sm badge-ghost">
                {detail_status(@detail)}
              </span>
              <a
                :if={@detail["pod_image_url"]}
                href={@detail["pod_image_url"]}
                target="_blank"
                rel="noopener noreferrer"
                class="btn btn-xs btn-outline btn-primary"
                title="View proof of delivery"
              >
                View POD
              </a>
            </div>
          </div>

          <%!-- Collection / Delivery --%>
          <div :for={{role, label} <- [{"consignor", "Collection"}, {"consignee", "Delivery"}]}>
            <div :if={party_address(@detail, role)} class="rounded border border-base-200 p-2">
              <div class="text-[10px] font-semibold uppercase tracking-wide text-base-content/50">
                {label}
              </div>
              <div class="text-xs">{party_address(@detail, role)}</div>
            </div>
          </div>

          <%!-- Key facts --%>
          <dl :if={detail_fields(@detail) != []} class="text-xs">
            <div
              :for={f <- detail_fields(@detail)}
              class="flex justify-between gap-3 border-b border-base-200 py-1"
            >
              <dt class="text-base-content/60">{f.label}</dt>
              <dd class="text-right">{f.value}</dd>
            </div>
          </dl>

          <%!-- Items (quotes) --%>
          <div :if={(items = @detail["items"]) not in [nil, []]}>
            <div class="text-[11px] font-medium uppercase tracking-wide text-base-content/50 mb-1">
              Items ({length(items)})
            </div>
            <ul class="space-y-1">
              <li :for={it <- items} class="text-[11px] border-l-2 border-base-300 pl-2">
                {it["description"]}
                <span class="text-base-content/50">
                  — qty {it["quantity"]}, {it["total_weight"]}kg, {it["length"]}×{it["width"]}×{it[
                    "height"
                  ]}
                </span>
              </li>
            </ul>
          </div>

          <%!-- Charges (quotes) --%>
          <div :if={(sundries = @detail["sundries"]) not in [nil, []]}>
            <div class="text-[11px] font-medium uppercase tracking-wide text-base-content/50 mb-1">
              Charges ({length(sundries)})
            </div>
            <ul class="space-y-1">
              <li :for={s <- sundries} class="flex justify-between gap-3 text-[11px]">
                <span class="text-base-content/60">{s["sundry_description"]}</span>
                <span class="text-right">{money(s["sundry_charge"])}</span>
              </li>
            </ul>
          </div>

          <%!-- Tracking events --%>
          <div :if={(events = @detail["events"]) not in [nil, []]}>
            <div class="text-[11px] font-medium uppercase tracking-wide text-base-content/50 mb-1">
              Tracking ({length(events)})
            </div>
            <ol class="space-y-1">
              <li
                :for={e <- Enum.reverse(events)}
                class="text-[11px] border-l-2 border-base-300 pl-2"
              >
                <div class="text-base-content/50">{e["event_date"]} {e["event_time"]}</div>
                <div class="whitespace-pre-line">
                  {e["event_description"] || e["status_description"] || e["event_code"]}
                </div>
              </li>
            </ol>
          </div>

          <details class="text-[11px] text-base-content/60">
            <summary class="cursor-pointer">Raw payload</summary>
            <pre class="bg-base-200 rounded p-2 mt-1 overflow-x-auto">{facts_text(@detail)}</pre>
          </details>
        </div>
        <p :if={is_nil(@detail)} class="text-xs text-base-content/60 px-1">
          Look up a waybill/quote/invoice, or click a waybill anywhere to load it here.
        </p>
      </div>
    </aside>
    """
  end

  # ── Ticket modal ─────────────────────────────────────────────────────────────

  defp ticket_modal(%{ticket: nil} = assigns), do: ~H""

  defp ticket_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
      <div class="bg-base-100 border border-base-300 rounded-lg p-4 max-w-md w-full space-y-3">
        <div class="flex items-center justify-between">
          <h3 class="font-medium">Ticket #{@ticket.ticket_id}</h3>
          <button type="button" phx-click="close_ticket" class="btn btn-ghost btn-xs">✕</button>
        </div>
        <p class="text-sm">{@ticket.subject}</p>
        <div class="flex flex-wrap items-center gap-2 text-xs">
          <span class={"badge " <> ticket_badge(@ticket.status)}>{@ticket.status}</span>
          <span class="badge badge-ghost">{@ticket.priority}</span>
          <span class="text-base-content/60">{@ticket.account_reference}</span>
        </div>
        <div class="text-xs text-base-content/60">
          {@ticket.requester_email} · received {fmt_dt(@ticket.received_at)}
        </div>
        <div :if={@ticket.waybill_reference} class="text-sm">
          Linked waybill:
          <button
            type="button"
            phx-click="show_detail"
            phx-value-type="shipment"
            phx-value-key={@ticket.waybill_reference}
            class="link link-primary"
          >
            {@ticket.waybill_reference}
          </button>
        </div>
        <div class="flex gap-2 pt-2">
          <button
            type="button"
            phx-click="prompt_ticket"
            phx-value-id={@ticket.ticket_id}
            class="btn btn-primary btn-sm"
          >
            Draft reply
          </button>
          <button type="button" phx-click="close_ticket" class="btn btn-ghost btn-sm">Close</button>
        </div>
      </div>
    </div>
    """
  end

  # ── Data helpers ─────────────────────────────────────────────────────────────

  defp load_history(socket) do
    history =
      case Assist.list_interactions() do
        {:ok, list} -> list |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime}) |> Enum.take(20)
        _ -> []
      end

    assign(socket, history: history)
  end

  # A bare ticket reference ("ticket 227703", "case 227703", "#227703").
  defp parse_ticket_fetch(text) do
    case Regex.run(~r/^\s*(?:ticket|case|#)\s*#?\s*(\d{4,})\s*$/i, text) do
      [_, id] -> id
      _ -> nil
    end
  end

  # Fetch a ticket → distil its content into a query → resolve its account.
  # Async (the model call takes ~1s); result handled in handle_async(:distil_ticket).
  defp start_ticket_distil(socket, id) do
    socket
    |> assign(distilling: true, selected_ticket: nil, account_choices: [])
    |> start_async(:distil_ticket, fn ->
      # Pre-fill the prompt with the ACTUAL ticket contents (subject + body), not a
      # distilled summary — the agent edits/submits it as-is.
      with {:ok, info} <- TragarAi.Freshdesk.ticket_text(id) do
        {info.ticket_id, info.text, TragarAi.Freshdesk.resolve_account(info)}
      end
    end)
  end

  # Live tickets from Freshdesk, filtered by status (default open) + agent.
  defp load_tickets(socket) do
    tickets =
      case TragarAi.Freshdesk.console_tickets(%{
             status: socket.assigns.ticket_status,
             agent_id: socket.assigns.ticket_agent
           }) do
        {:ok, list} -> list
        _ -> []
      end

    assign(socket, tickets: tickets)
  end

  defp load_agents(socket) do
    agents =
      case TragarAi.Freshdesk.agents() do
        {:ok, list} -> list
        _ -> []
      end

    assign(socket, agents: agents)
  end

  defp load_detail(socket, type, key) do
    case fetch_detail(type, key) do
      {:ok, facts} when map_size(facts) > 0 ->
        assign(socket,
          detail: facts,
          detail_title: "#{detail_label(type)} #{key}",
          right_tab: "details",
          selected_ticket: nil
        )

      _ ->
        # Replace any previous result so a miss doesn't leave stale details.
        socket
        |> assign(detail: nil, detail_title: nil, right_tab: "details", selected_ticket: nil)
        |> put_flash(:error, "No #{detail_label(type)} found for #{key}.")
    end
  end

  defp fetch_detail(type, key) do
    {intent, entities} =
      case type do
        "shipment" -> {:load_status, %{waybill: key}}
        "quote" -> {:quote_lookup, %{quote: key}}
        "invoice" -> {:invoice, %{account: key}}
        "customer" -> {:customer_lookup, %{account: key}}
        _ -> {nil, %{}}
      end

    cond do
      is_nil(intent) -> {:error, :unknown_type}
      # Fetch the full live record (incl. pod_image_url, items, sundries) rather
      # than the reduced domain shape the cache/adapter returns.
      type == "quote" -> ok_map(TragarAi.Freight.get_quote(key))
      type == "shipment" -> waybill_detail(key)
      true -> TragarAi.Adapters.fetch(intent, entities)
    end
  end

  defp ok_map({:ok, m}) when is_map(m), do: {:ok, m}
  defp ok_map(_), do: {:error, :not_found}

  # The single-waybill fetch has no tracking — merge in trackAndTrace events.
  defp waybill_detail(key) do
    case TragarAi.Freight.get_waybill(key) do
      {:ok, w} when is_map(w) ->
        events =
          case TragarAi.Freight.track_and_trace("waybills", key) do
            {:ok, ev} when is_list(ev) -> ev
            _ -> []
          end

        {:ok, Map.put(w, "events", events)}

      _ ->
        {:error, :not_found}
    end
  end

  defp detail_label("shipment"), do: "Waybill"
  defp detail_label("quote"), do: "Quote"
  defp detail_label("invoice"), do: "Invoice"
  defp detail_label("customer"), do: "Account"
  defp detail_label(_), do: "Record"

  # The interaction's primary entity, for the "View details" shortcut.
  defp primary_entity(%{facts: f}) when is_map(f) do
    cond do
      f["waybill_number"] -> %{type: "shipment", key: f["waybill_number"], label: "waybill"}
      f["quote_number"] -> %{type: "quote", key: f["quote_number"], label: "quote"}
      f["invoice_number"] -> %{type: "invoice", key: f["account_reference"], label: "invoice"}
      true -> nil
    end
  end

  defp primary_entity(_), do: nil

  # ── Conversation ─────────────────────────────────────────────────────────────

  # One chat turn: append the user message + a pending AI bubble, then run the
  # loop off the LiveView process. Tokens stream in via {:chunk,...}; the final
  # interaction is applied in handle_async (frame accumulation, reply mode).
  defp converse(socket, text) do
    frame = socket.assigns.frame
    base = frame.entities

    id = socket.assigns.next_msg_id
    lv = self()

    context = %{
      agent: blank_to_nil(socket.assigns.agent),
      entities: base,
      intent: frame.intent,
      on_chunk: fn chunk -> send(lv, {:chunk, id, chunk}) end,
      on_event: fn event -> send(lv, {:event, id, event}) end
    }

    pending = %{
      role: :ai,
      id: id,
      pending: true,
      stream: "",
      text: nil,
      resolved: true,
      suggestions: [],
      steps: []
    }

    socket
    |> assign(
      messages: socket.assigns.messages ++ [%{role: :user, text: text}, pending],
      question: "",
      next_msg_id: id + 1,
      right_tab: "log"
    )
    |> start_async({:converse, id}, fn ->
      {Engine.answer(text, context), base, frame.intent}
    end)
  end

  @impl true
  def handle_async(
        {:converse, id},
        {:ok, {{:ok, interaction}, base, prior_intent}},
        socket
      ) do
    resolved? = interaction.status == :drafted

    new_frame = %{
      intent: carry_intent(interaction, prior_intent),
      entities: Map.merge(base, atomize_entities(interaction.entities))
    }

    ai = %{
      role: :ai,
      id: id,
      pending: false,
      stream: "",
      text: interaction.draft_answer,
      resolved: resolved?,
      suggestions: if(resolved?, do: [], else: suggest(interaction))
    }

    socket =
      socket
      |> assign(
        messages: replace_msg(socket.assigns.messages, id, ai),
        frame: new_frame,
        # Keep the interaction so its source details/fields stay available.
        interaction: interaction,
        right_tab: "log"
      )
      |> load_history()

    {:noreply, socket}
  end

  # Ticket distilled into a prompt → pre-fill the input for editing, carrying the
  # ticket_id (so a relayed answer posts back) and the resolved account. If the
  # resolver returned several candidates, offer a chooser instead of guessing.
  def handle_async(:distil_ticket, {:ok, {ticket_id, query, resolution}}, socket)
      when is_binary(query) do
    {account, choices} =
      case resolution do
        {:ok, ref} -> {ref, []}
        {:ambiguous, refs} -> {nil, refs}
        _ -> {nil, []}
      end

    entities = %{ticket_id: ticket_id} |> put_if(:account, account)

    {:noreply,
     socket
     |> reset_chat_state()
     |> assign(
       question: query,
       frame: %{intent: nil, entities: entities},
       distilling: false,
       account_choices: choices
     )}
  end

  def handle_async(:distil_ticket, {:ok, _}, socket) do
    {:noreply,
     socket
     |> assign(distilling: false)
     |> put_flash(:error, "Couldn't load that ticket from Freshdesk.")}
  end

  def handle_async(:distil_ticket, {:exit, reason}, socket) do
    Logger.error("[console] distil crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(distilling: false)
     |> put_flash(:error, "Couldn't prepare a prompt from that ticket.")}
  end

  def handle_async({:converse, id}, {:exit, reason}, socket) do
    Logger.error("[console] converse crashed: #{inspect(reason)}")

    ai = %{
      role: :ai,
      id: id,
      pending: false,
      stream: "",
      text: "Something went wrong — please try again.",
      resolved: false,
      suggestions: []
    }

    {:noreply, assign(socket, messages: replace_msg(socket.assigns.messages, id, ai))}
  end

  @impl true
  def handle_info({:chunk, id, chunk}, socket) do
    messages =
      Enum.map(socket.assigns.messages, fn m ->
        if Map.get(m, :id) == id, do: %{m | stream: Map.get(m, :stream, "") <> chunk}, else: m
      end)

    {:noreply, assign(socket, messages: messages)}
  end

  # Live per-source progress for a multi-lookup turn (concurrent gather).
  def handle_info({:event, id, {:source_started, intent, source, entities}}, socket) do
    step = %{
      key: ev_key(intent, entities),
      intent: intent,
      source: source,
      entity: ev_entity(entities),
      status: :running
    }

    {:noreply,
     assign(socket, messages: update_steps(socket.assigns.messages, id, &upsert_step(&1, step)))}
  end

  def handle_info({:event, id, {:source_done, intent, _source, entities, ok?}}, socket) do
    key = ev_key(intent, entities)
    status = if ok?, do: :ok, else: :fail

    {:noreply,
     assign(socket,
       messages: update_steps(socket.assigns.messages, id, &set_step_status(&1, key, status))
     )}
  end

  defp update_steps(messages, id, fun) do
    Enum.map(messages, fn m ->
      if Map.get(m, :id) == id, do: Map.put(m, :steps, fun.(Map.get(m, :steps, []))), else: m
    end)
  end

  # The per-source progress steps of the in-flight turn, for the right-panel log.
  defp live_steps(messages) do
    Enum.find_value(messages, [], fn m ->
      steps = Map.get(m, :steps, [])
      if Map.get(m, :pending) && steps != [], do: steps
    end) || []
  end

  defp ev_key(intent, entities), do: {intent, ev_entity(entities)}

  defp ev_entity(entities) when is_map(entities),
    do: entities[:waybill] || entities[:quote] || entities[:account] || entities[:ticket_id]

  defp ev_entity(_), do: nil

  defp upsert_step(steps, step) do
    if Enum.any?(steps, &(&1.key == step.key)),
      do: Enum.map(steps, &if(&1.key == step.key, do: step, else: &1)),
      else: steps ++ [step]
  end

  defp set_step_status(steps, key, status),
    do: Enum.map(steps, &if(&1.key == key, do: %{&1 | status: status}, else: &1))

  defp replace_msg(messages, id, new_msg),
    do: Enum.map(messages, fn m -> if(Map.get(m, :id) == id, do: new_msg, else: m) end)

  # The composer starts from the AI's answer only when it actually answered;
  # never seed it with a clarify/error message.

  # Turn a failed interpretation into actionable next steps: queries the schema
  # can answer, grounded in whatever entity the AI did extract.
  defp suggest(%{entities: e}) when is_map(e) do
    cond do
      e["waybill"] ->
        wb = e["waybill"]

        [
          %{label: "Where is #{wb}?", q: "Where is waybill #{wb}?"},
          %{label: "ETA", q: "ETA for waybill #{wb}"},
          %{label: "Proof of delivery", q: "Proof of delivery for #{wb}"}
        ]

      e["account"] ->
        acc = e["account"]

        [
          %{label: "Account balance", q: "Balance on account #{acc}"},
          %{label: "Who is the customer", q: "Who is the customer on #{acc}"}
        ]

      e["quote"] ->
        [%{label: "Show the quote", q: "Show quote #{e["quote"]}"}]

      true ->
        [
          %{label: "Track a waybill", q: "Where is waybill 4821?"},
          %{label: "Account balance", q: "Balance on account ACC1001"},
          %{label: "Service types", q: "What service types do you offer?"}
        ]
    end
  end

  defp suggest(_), do: []

  # ── Waybill search ───────────────────────────────────────────────────────────

  # "show me undelivered waybills for ITD02" → %{account: "ITD02", status: :undelivered}.
  defp parse_waybill_search(text) do
    t = String.downcase(text)
    account = Regex.run(~r/\b(?:for|on|account|customer)\s+([A-Za-z0-9]{3,})\b/, text)
    number? = Regex.match?(~r/\bwaybill\s*#?\s*\d{4,}/i, text)

    cond do
      not String.contains?(t, "waybill") -> nil
      account == nil -> nil
      # A specific "waybill <number>" is a single lookup, not a search.
      number? and not String.contains?(t, "waybills") -> nil
      true -> %{account: account |> tl() |> hd() |> String.upcase(), status: search_status(t)}
    end
  end

  defp search_status(t) do
    cond do
      String.contains?(t, "undeliver") or String.contains?(t, "not delivered") or
        String.contains?(t, "open") or String.contains?(t, "outstanding") ->
        "undelivered"

      String.contains?(t, "deliver") ->
        "delivered"

      true ->
        "all"
    end
  end

  # Account isn't in the FreightWare allocated-accounts directory — show a clear
  # message in the relevant tab instead of running a query that returns nothing.
  defp invalid_account_search(socket, account, status, "quotes") do
    assign(socket,
      quote_results: [],
      quote_meta: %{account: account, status: status, error: account_error(account)},
      right_tab: "quotes"
    )
  end

  defp invalid_account_search(socket, account, status, _search) do
    assign(socket,
      search_results: [],
      search_meta: %{account: account, status: status, error: account_error(account)},
      right_tab: "search"
    )
  end

  defp account_error(account),
    do: "\"#{account}\" isn't a recognised FreightWare account."

  # Run the account-scoped search only when the account resolves (valid code, or a
  # company name that maps to one). Otherwise DON'T hard-fail — fall through to the
  # normal assist loop, which handles the account softly (asks for a valid code).
  defp search_or_converse(socket, text, kind, spec) do
    case resolve_search_account(spec.account) do
      {:ok, ref} when kind == :quotes -> run_quote_search(socket, ref, spec.status)
      {:ok, ref} -> run_waybill_search(socket, ref, spec.status)
      _ -> converse(socket, text)
    end
  end

  defp resolve_search_account(account) do
    if TragarAi.Freight.Accounts.valid?(account) do
      {:ok, account}
    else
      TragarAi.Freight.Accounts.resolve(%{code: account, company: account})
    end
  end

  defp run_waybill_search(socket, account, status, date_from \\ nil, date_to \\ nil)

  defp run_waybill_search(socket, account, status, date_from, date_to) do
    cond do
      not TragarAi.Freight.Accounts.valid?(account) ->
        invalid_account_search(socket, account, status, "search")

      true ->
        run_waybill_search!(socket, account, status, date_from, date_to)
    end
  end

  defp run_waybill_search!(socket, account, status, date_from, date_to) do
    # A real status code filters server-side; a group (undelivered/delivered/all)
    # fetches the window and filters client-side.
    code = if status in Statuses.waybill_codes(), do: status, else: nil

    case fetch_waybills(account, code, date_from, date_to) do
      {:ok, list} ->
        results = list |> apply_group(status) |> Enum.map(&waybill_summary/1)

        assign(socket,
          search_results: results,
          search_meta: %{account: account, status: status, total: length(list)},
          right_tab: "search"
        )

      {:error, reason} ->
        assign(socket,
          search_results: [],
          search_meta: %{account: account, status: status, error: inspect(reason)},
          right_tab: "search"
        )
    end
  end

  defp fetch_waybills(account, code, from, to) do
    params =
      %{account_reference: account}
      |> put_if(:status_code, code)
      |> put_if(:date_from, from)
      |> put_if(:date_to, to)

    case TragarAi.Freight.search_waybills(params) do
      {:ok, r} -> {:ok, r["waybills"] || []}
      err -> err
    end
  end

  defp put_if(map, _k, v) when v in [nil, ""], do: map
  defp put_if(map, k, v), do: Map.put(map, k, v)

  # Group filters (the real status codes are filtered server-side instead).
  defp apply_group(list, "undelivered"),
    do: Enum.reject(list, &(Statuses.delivered?(&1) or Statuses.deleted?(&1)))

  defp apply_group(list, "delivered"), do: Enum.filter(list, &Statuses.delivered?/1)
  defp apply_group(list, _other), do: list

  defp waybill_summary(w) do
    %{
      number: w["waybill_number"],
      status: humanize_status(w["status_code"] || w["status"]),
      consignee: w["consignee_name"] || w["consignee"],
      date: w["waybill_date"] || w["eta"],
      pod_url: blank_to_nil(w["pod_image_url"])
    }
  end

  # ── Quote search (account-scoped) ────────────────────────────────────────────

  # "show me accepted quotes for ITD02" → %{account: "ITD02", status: "ACC"}.
  defp parse_quote_search(text) do
    t = String.downcase(text)
    account = Regex.run(~r/\b(?:for|on|account|customer)\s+([A-Za-z0-9]{3,})\b/, text)
    number? = Regex.match?(~r/\bquote\s*#?\s*\d{3,}/i, text)

    cond do
      not String.contains?(t, "quote") ->
        nil

      account == nil ->
        nil

      number? and not String.contains?(t, "quotes") ->
        nil

      true ->
        %{account: account |> tl() |> hd() |> String.upcase(), status: quote_search_status(t)}
    end
  end

  defp quote_search_status(t) do
    Enum.find_value(TragarAi.Freight.Statuses.quote(), "all", fn {code, label} ->
      if String.contains?(t, String.downcase(label)), do: code
    end)
  end

  defp run_quote_search(socket, account, status, date_from \\ nil, date_to \\ nil)

  defp run_quote_search(socket, account, status, date_from, date_to) do
    cond do
      not TragarAi.Freight.Accounts.valid?(account) ->
        invalid_account_search(socket, account, status, "quotes")

      true ->
        run_quote_search!(socket, account, status, date_from, date_to)
    end
  end

  defp run_quote_search!(socket, account, status, date_from, date_to) do
    code = if status in Enum.map(Statuses.quote(), &elem(&1, 0)), do: status, else: nil

    case fetch_quotes(account, code, date_from, date_to) do
      {:ok, list} ->
        assign(socket,
          quote_results: Enum.map(list, &quote_summary/1),
          quote_meta: %{account: account, status: status, total: length(list)},
          right_tab: "quotes"
        )

      {:error, reason} ->
        assign(socket,
          quote_results: [],
          quote_meta: %{account: account, status: status, error: inspect(reason)},
          right_tab: "quotes"
        )
    end
  end

  defp fetch_quotes(account, code, from, to) do
    params =
      %{account_reference: account}
      |> put_if(:status_code, code)
      |> put_if(:date_from, from)
      |> put_if(:date_to, to)

    case TragarAi.Freight.search_quotes(params) do
      {:ok, %{"quotes" => quotes}} -> {:ok, quotes || []}
      {:ok, list} when is_list(list) -> {:ok, list}
      err -> err
    end
  end

  defp quote_summary(q) do
    %{
      number: q["quote_number"],
      status: humanize_status(q["status_description"] || q["status"] || q["status_code"]),
      amount: money(q["total"] || q["charged_amount"]),
      consignee: q["consignee_name"] || q["consignee"],
      date: q["quote_date"]
    }
  end

  defp money(nil), do: ""
  defp money(n) when is_number(n), do: "R #{:erlang.float_to_binary(n * 1.0, decimals: 2)}"
  defp money(n), do: to_string(n)

  # ── Multi-lookup rendering (combined interaction with per-source results) ─────

  defp multi_results(%{facts: %{"results" => rows}}) when is_list(rows), do: rows
  defp multi_results(_), do: []

  # Nil-guard via a function call so the type-checker doesn't constant-fold the
  # `:if` (the assign starts as nil, so the runtime guard is required).
  defp present?(v), do: not is_nil(v)

  defp group_by_source(rows), do: rows |> Enum.group_by(& &1["source"]) |> Enum.to_list()

  defp result_entity(r) do
    e = r["entities"] || %{}
    e["waybill"] || e["quote"] || e["account"] || e["ticket_id"]
  end

  defp step_badge(:ok), do: "badge-success"
  defp step_badge(:fail), do: "badge-error"
  defp step_badge(_), do: "badge-ghost"

  defp step_icon(:ok), do: "✓"
  defp step_icon(:fail), do: "✗"
  defp step_icon(_), do: "…"

  defp reset_chat_state(socket) do
    assign(socket,
      messages: [],
      frame: %{intent: nil, entities: %{}},
      interaction: nil,
      question: ""
    )
  end

  defp carry_intent(%{intent: intent}, _prev) when is_binary(intent) do
    String.to_existing_atom(intent)
  rescue
    ArgumentError -> nil
  end

  defp carry_intent(_interaction, prev), do: prev

  @entity_atoms %{
    "waybill" => :waybill,
    "account" => :account,
    "ticket_id" => :ticket_id,
    "quote" => :quote
  }

  defp atomize_entities(entities) when is_map(entities) do
    for {k, v} <- entities, key = @entity_atoms[to_string(k)], into: %{}, do: {key, v}
  end

  defp atomize_entities(_), do: %{}

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp blank_to_nil(value), do: value

  defp facts_text(facts), do: Jason.encode!(facts, pretty: true)

  # Flatten facts into draggable {label, value, snippet} fields.
  # Middle panel (assist result): the application/domain shape, incl. the latest
  # event. Unchanged from the original — keep surfacing the app's shape.
  defp surfaced_fields(%{facts: facts}) when is_map(facts),
    do: fact_fields(facts, ~w(events last_event pod waybill_number), false)

  defp surfaced_fields(_), do: []

  # Right detail panel: also hide the party fields, status and POD url — those get
  # their own sections (Collection/Delivery cards, header badge, View POD button).
  defp detail_fields(facts) when is_map(facts) do
    fact_fields(
      facts,
      ~w(events last_event pod waybill_number pod_image_url status status_code status_description),
      true
    )
  end

  defp detail_fields(_), do: []

  defp fact_fields(facts, skip, drop_party?) do
    scalars =
      for {k, v} <- facts, k not in skip, not (drop_party? and party_key?(k)), scalar?(v) do
        field(k, v)
      end

    id_field =
      if facts["waybill_number"], do: [field("waybill_number", facts["waybill_number"])], else: []

    id_field ++ scalars ++ event_field(facts["last_event"]) ++ pod_field(facts["pod"])
  end

  defp scalar?(v), do: is_binary(v) or is_number(v) or is_boolean(v)

  defp field(key, value) do
    label = humanize(key)
    display = if key in ~w(status status_code), do: humanize_status(value), else: to_string(value)
    %{label: label, value: display, snippet: "#{label}: #{display}"}
  end

  # FreightWare status codes → plain language for the chips.
  defp humanize_status(value) do
    v = to_string(value)

    case List.keyfind(Statuses.waybill(), String.upcase(v), 0) do
      {_code, label} -> label
      nil -> v
    end
  end

  defp event_field(%{} = e) do
    text =
      [e["event_description"] || e["description"], e["event_date"] || e["date"]]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" — ")

    if text == "",
      do: [],
      else: [%{label: "Last update", value: text, snippet: "Latest update: #{text}"}]
  end

  defp event_field(_), do: []

  defp pod_field(%{} = pod) do
    text =
      [pod["receiver"] && "received by #{pod["receiver"]}", pod["date"] && "on #{pod["date"]}"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    if text == "",
      do: [],
      else: [%{label: "Proof of delivery", value: text, snippet: "Proof of delivery: #{text}"}]
  end

  defp pod_field(_), do: []

  # Status for the detail header (waybill/quote/invoice).
  defp detail_status(d) when is_map(d) do
    case d["status_description"] || d["status"] || d["status_code"] do
      v when is_binary(v) and v != "" -> humanize_status(v)
      _ -> nil
    end
  end

  defp detail_status(_), do: nil

  defp party_key?(k) do
    s = to_string(k)
    String.starts_with?(s, "consignor_") or String.starts_with?(s, "consignee_")
  end

  # A consignor/consignee as one address line (name, street, suburb, city, postal, site).
  defp party_address(d, role) when is_map(d) do
    parts =
      ["#{role}_name", "#{role}_street", "#{role}_suburb", "#{role}_city", "#{role}_postal_code"]
      |> Enum.map(&d[&1])
      |> Enum.reject(&(&1 in [nil, ""]))

    site = d["#{role}_site"]

    cond do
      parts == [] -> nil
      site in [nil, ""] -> Enum.join(parts, ", ")
      true -> "#{Enum.join(parts, ", ")} (site #{site})"
    end
  end

  defp party_address(_, _), do: nil

  defp humanize(key), do: key |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp fmt_dt(nil), do: "—"
  defp fmt_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%d %b %H:%M")

  defp tab_class(true), do: "btn btn-xs btn-primary"
  defp tab_class(false), do: "btn btn-xs btn-ghost"

  defp ticket_badge("Open"), do: "badge-warning"
  defp ticket_badge("Pending"), do: "badge-info"
  defp ticket_badge("Resolved"), do: "badge-success"
  defp ticket_badge(_), do: "badge-ghost"

  # Build the interpret → validate → fetch → phrase trace from an interaction.
  defp loop_trace(%{} = i, model) do
    err = to_string(i.error || "")

    {validate, fetch, phrase} =
      cond do
        i.status == :drafted -> {:ok, :ok, :ok}
        String.starts_with?(err, "interpret") -> {:skip, :skip, :skip}
        validation_error?(err) -> {:fail, :skip, :skip}
        fetch_error?(err) -> {:ok, :fail, :skip}
        true -> {:ok, :ok, :fail}
      end

    interpret = if String.starts_with?(err, "interpret"), do: :fail, else: :ok

    [
      %{label: "Core AI · interpret · #{model}", status: interpret, detail: trace_interpret(i)},
      %{label: "Elixir · validate", status: validate, detail: trace_validate(validate, err)},
      %{label: "Fetch fact (read-only)", status: fetch, detail: trace_fetch(fetch, i, err)},
      %{label: "Core AI · phrase · #{model}", status: phrase, detail: trace_phrase(phrase, i)}
    ]
  end

  defp loop_trace(_, _), do: []

  defp validation_error?(e),
    do:
      String.starts_with?(e, "not_understood") or String.starts_with?(e, "missing_entities") or
        String.starts_with?(e, "unknown_intent")

  defp fetch_error?(e),
    do:
      String.starts_with?(e, "not_found") or String.starts_with?(e, "not_available") or
        String.starts_with?(e, "missing_waybill")

  defp trace_interpret(i) do
    entities =
      case i.entities do
        m when is_map(m) and map_size(m) > 0 ->
          Enum.map_join(m, ", ", fn {k, v} -> "#{k}=#{v}" end)

        _ ->
          "none"
      end

    "intent: #{i.intent || "—"} · entities: #{entities}"
  end

  defp trace_validate(:fail, err), do: humanize_error(err)
  defp trace_validate(:skip, _), do: "—"
  defp trace_validate(_, _), do: "allowed; required entities present"

  defp trace_fetch(:ok, i, _), do: "via #{i.source || "—"} → #{map_size(i.facts || %{})} fields"
  defp trace_fetch(:fail, _i, err), do: humanize_error(err)
  defp trace_fetch(_, _, _), do: "—"

  defp trace_phrase(:ok, i), do: i.draft_answer
  defp trace_phrase(_, _), do: "—"

  defp humanize_error(err), do: err |> String.replace(":", ": ") |> String.replace("_", " ")

  defp chat_row(:user), do: "flex justify-end"
  defp chat_row(_), do: "flex justify-start"

  defp chat_bubble(%{role: :user}),
    do: "max-w-[85%] rounded-lg bg-primary text-primary-content px-3 py-2 text-sm"

  # An unresolved AI turn is a prompt-back (amber); a resolved one is the answer.
  defp chat_bubble(%{resolved: false}),
    do: "max-w-[85%] rounded-lg bg-warning/15 px-3 py-2 text-sm"

  defp chat_bubble(_),
    do: "max-w-[85%] rounded-lg bg-base-200 px-3 py-2 text-sm"

  defp call_class("source", false), do: "badge-error"
  defp call_class("source", _), do: "badge-info"
  defp call_class(_ai, false), do: "badge-error"
  defp call_class(_ai, _), do: "badge-primary"

  defp format_params(params) when is_map(params) and map_size(params) > 0,
    do: Enum.map_join(params, ", ", fn {k, v} -> "#{k}: #{format_value(v)}" end)

  defp format_params(_), do: ""

  defp format_value(v) when is_binary(v), do: v
  defp format_value(v) when is_map(v) or is_list(v), do: "…"
  defp format_value(v), do: to_string(v)

  defp call_data(result), do: Jason.encode!(result, pretty: true)

  defp step_class(:ok), do: "badge-success"
  defp step_class(:fail), do: "badge-error"
  defp step_class(_), do: "badge-ghost"

  # Plain-language outcome (not raw status/error jargon) for the badge.
  defp outcome_label(%{status: :drafted}), do: "answered"
  defp outcome_label(%{status: :relayed}), do: "relayed"
  defp outcome_label(%{status: :discarded}), do: "discarded"

  defp outcome_label(%{status: :failed, error: error}) do
    cond do
      error == "unsupported_action" -> "out of scope"
      error == "not_found" -> "not found"
      error == "not_available" -> "not connected"
      clarify_error?(error) -> "needs detail"
      true -> "couldn't complete"
    end
  end

  defp outcome_label(_), do: "—"

  defp outcome_class(%{status: :drafted}), do: "badge-info"
  defp outcome_class(%{status: :relayed}), do: "badge-success"
  defp outcome_class(%{status: :discarded}), do: "badge-ghost"

  defp outcome_class(%{status: :failed, error: error}) do
    if error == "not_available", do: "badge-error", else: "badge-warning"
  end

  defp outcome_class(_), do: "badge-ghost"

  defp clarify_error?(error) when is_binary(error) do
    String.starts_with?(error, "not_understood") or String.starts_with?(error, "missing_entities") or
      String.starts_with?(error, "unknown_intent") or
      String.starts_with?(error, "missing_waybill")
  end

  defp clarify_error?(_), do: false

  # Hide the intent chip when it's not a real, queryable intent.
  defp show_intent?(%{intent: intent}) when is_binary(intent),
    do: intent not in ["unsupported_action", "unknown"]

  defp show_intent?(_), do: false
end
