defmodule TragarAiWeb.ConsoleLive do
  @moduledoc """
  The support-assist agent console (Phase 1).

  Three panes:

    * left — the Freshdesk ticket queue (sortable; FIFO by default). Selecting a
      ticket opens its detail; "Draft reply" runs the loop in **reply mode**.
    * centre — the prompt. It surfaces entity details for any use case (waybill,
      quote, invoice, …). The **reply box** only appears for the customer-email
      use case (from a ticket, or via "Draft customer reply").
    * right — switchable between Recents (history) and Details (look up a
      waybill/quote/invoice/account, or click a waybill to load it here).
  """
  use TragarAiWeb, :live_view

  alias TragarAi.Assist
  alias TragarAi.Assist.Engine
  alias TragarAi.Support

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(question: "", agent: "")
     |> assign(messages: [], frame: %{intent: nil, entities: %{}})
     |> assign(interaction: nil, reply: false, demo: true)
     |> assign(model: TragarAi.CoreAI.info())
     |> assign(right_tab: "chat", detail: nil, detail_title: nil)
     |> assign(selected_ticket: nil, ticket_sort: "fifo")
     |> load_history()
     |> load_tickets()}
  end

  # ── Prompt (centre) ─────────────────────────────────────────────────────────

  # A chat turn: the AI keeps clarifying (carrying the frame) until it resolves
  # the intent, or the user ends the chat.
  @impl true
  def handle_event("ask", params, socket) do
    text = String.trim(params["question"] || "")

    socket =
      assign(socket,
        demo: params["demo"] == "true",
        agent: params["agent"] || socket.assigns.agent
      )

    if text == "" do
      {:noreply, put_flash(socket, :error, "Type a message first.")}
    else
      {:noreply, converse(socket, text, false)}
    end
  end

  # Run a demo query as a fresh conversation seeded with its entities.
  def handle_event("run_sample", %{"idx" => idx}, socket) do
    entry = Enum.at(TragarAi.Demo.catalog(), String.to_integer(idx))

    socket
    |> reset_chat_state()
    |> assign(frame: %{intent: nil, entities: entry.entities}, demo: true)
    |> converse(entry.question, false)
    |> then(&{:noreply, &1})
  end

  def handle_event("reset_chat", _params, socket),
    do: {:noreply, reset_chat_state(socket)}

  # Run a suggested query the AI offered to help resolve the request.
  def handle_event("suggest", %{"q" => q}, socket),
    do: {:noreply, converse(socket, q, false)}

  # Reveal the reply composer for the customer-email use case.
  def handle_event("draft_reply", _params, socket), do: {:noreply, assign(socket, reply: true)}

  def handle_event("relay", %{"final_answer" => final} = params, socket) do
    {:ok, _} =
      Assist.relay_interaction(socket.assigns.interaction, %{
        final_answer: final,
        agent: blank_to_nil(params["agent"])
      })

    {:noreply,
     socket
     |> put_flash(:info, "Answer relayed and logged.")
     |> reset_chat_state()
     |> assign(right_tab: "recents")
     |> load_history()}
  end

  def handle_event("discard", _params, socket) do
    {:ok, _} = Assist.discard_interaction(socket.assigns.interaction, %{})
    {:noreply, socket |> reset_chat_state() |> load_history()}
  end

  def handle_event("seed_demo", _params, socket) do
    :ok = TragarAi.Demo.seed()

    {:noreply,
     socket
     |> put_flash(:info, "Demo data loaded across all sources.")
     |> load_tickets()
     |> load_history()}
  end

  # ── Tickets (left) ──────────────────────────────────────────────────────────

  def handle_event("sort_tickets", %{"sort" => sort}, socket),
    do: {:noreply, socket |> assign(ticket_sort: sort) |> load_tickets()}

  def handle_event("select_ticket", %{"id" => id}, socket) do
    ticket = Enum.find(socket.assigns.tickets, &(&1.ticket_id == id))
    {:noreply, assign(socket, selected_ticket: ticket)}
  end

  def handle_event("close_ticket", _params, socket),
    do: {:noreply, assign(socket, selected_ticket: nil)}

  # Draft a customer reply for a ticket: look up the linked waybill if there is
  # one (so the facts are the answer), otherwise the ticket itself. Reply mode on.
  def handle_event("prompt_ticket", %{"id" => id}, socket) do
    ticket = Enum.find(socket.assigns.tickets, &(&1.ticket_id == id))
    {question, entities} = ticket_prompt(ticket)

    socket
    |> reset_chat_state()
    |> assign(frame: %{intent: nil, entities: entities}, selected_ticket: nil)
    |> converse(question, true)
    |> then(&{:noreply, &1})
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
      <header class="flex items-start justify-between gap-3">
        <div>
          <h1 class="text-2xl font-semibold">Tragar · Support Assist</h1>
          <p class="text-sm text-base-content/70">
            Surface facts from the source systems. Reply to a customer, or just look something up.
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
        <.tickets_pane tickets={@tickets} ticket_sort={@ticket_sort} demo={@demo} />
        <.centre
          question={@question}
          agent={@agent}
          demo={@demo}
          messages={@messages}
          interaction={@interaction}
          reply={@reply}
          model={@model}
        />
        <.right_panel
          right_tab={@right_tab}
          messages={@messages}
          history={@history}
          detail={@detail}
          detail_title={@detail_title}
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
                const ta = el.querySelector("textarea[name=final_answer]")
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
      <div class="space-y-2">
        <div class="flex items-center justify-between">
          <h2 class="text-sm font-medium">
            Tickets <span class="text-xs text-base-content/50">(reply)</span>
          </h2>
          <form phx-change="sort_tickets">
            <select name="sort" class="select select-bordered select-xs">
              <option value="fifo" selected={@ticket_sort == "fifo"}>FIFO (oldest)</option>
              <option value="recent" selected={@ticket_sort == "recent"}>Newest</option>
              <option value="priority" selected={@ticket_sort == "priority"}>Priority</option>
              <option value="status" selected={@ticket_sort == "status"}>Status</option>
            </select>
          </form>
        </div>

        <ul class="max-h-[40vh] overflow-y-auto divide-y divide-base-200 rounded-lg border border-base-300">
          <li :for={t <- @tickets}>
            <button
              type="button"
              phx-click="select_ticket"
              phx-value-id={t.ticket_id}
              class="w-full p-2 text-left hover:bg-base-200"
            >
              <div class="flex items-start justify-between gap-2">
                <span class="text-xs font-medium">#{t.ticket_id}</span>
                <span class={"badge badge-xs " <> ticket_badge(t.status)}>{t.status}</span>
              </div>
              <div class="text-xs truncate">{t.subject}</div>
              <div class="text-[11px] text-base-content/50">
                {t.account_reference} · {t.priority} · {fmt_dt(t.received_at)}
              </div>
            </button>
          </li>
          <li :if={@tickets == []} class="p-3 text-xs text-base-content/60">
            No tickets yet — click “Load demo data”.
          </li>
        </ul>
      </div>

      <div :if={@demo} class="space-y-2">
        <div>
          <h2 class="text-sm font-medium">Demo queries</h2>
          <p class="text-[11px] text-base-content/50">
            Retrieve details unrelated to a ticket — click to run.
          </p>
        </div>

        <% catalog = TragarAi.Demo.catalog() %>
        <% sources = catalog |> Enum.map(& &1.source) |> Enum.uniq() %>
        <div class="max-h-[42vh] overflow-y-auto space-y-2 rounded-lg border border-base-300 p-2">
          <div :for={source <- sources} class="space-y-1">
            <div class="text-[11px] font-medium uppercase tracking-wide text-base-content/50">
              {source}
            </div>
            <%= for {e, i} <- Enum.with_index(catalog), e.source == source do %>
              <button
                type="button"
                phx-click="run_sample"
                phx-value-idx={i}
                draggable="true"
                data-snippet={e.question}
                class="block w-full rounded-md border border-base-300 bg-base-100 px-2 py-1.5 text-left hover:border-primary"
              >
                <span class="block text-xs">{e.question}</span>
                <span class="block text-[11px] text-base-content/50">{e.surfaces}</span>
              </button>
            <% end %>
          </div>
        </div>
      </div>
    </aside>
    """
  end

  # ── Centre: prompt + result ──────────────────────────────────────────────────

  defp centre(assigns) do
    ~H"""
    <main class="space-y-4">
      <form phx-submit="ask" class="space-y-2">
        <textarea
          name="question"
          rows="2"
          data-drop
          class="textarea textarea-bordered w-full"
          placeholder="Ask Tragar AI — e.g. “Where is load 4821?”, “an invoice”, then “ACC1001”…"
        >{@question}</textarea>
        <div class="flex flex-wrap items-center gap-3">
          <button type="submit" class="btn btn-primary">Send</button>
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
          <label class="flex items-center gap-2 text-sm cursor-pointer">
            <input
              type="checkbox"
              name="demo"
              value="true"
              checked={@demo}
              class="checkbox checkbox-sm"
            /> Demo mode
          </label>
          <button type="button" phx-click="seed_demo" class="btn btn-ghost btn-sm">
            Load demo data
          </button>
        </div>
      </form>

      <section
        :if={@interaction}
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
          <span :if={@demo} class="badge badge-warning badge-sm">demo</span>
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
              {@interaction.source || "Source"} details<span :if={@reply}> — drag a field into your reply</span>
            </h3>
            <div class="flex flex-wrap gap-2">
              <button
                :for={f <- fields}
                type="button"
                draggable="true"
                data-snippet={f.snippet}
                data-insert
                class="cursor-grab active:cursor-grabbing rounded-md border border-base-300 bg-base-200 px-2.5 py-1.5 text-left hover:border-primary"
                title="Drag into the reply (reply mode), or click to copy in"
              >
                <span class="block text-[10px] uppercase tracking-wide text-base-content/50">
                  {f.label}
                </span>
                <span class="block text-sm">{f.value}</span>
              </button>
            </div>
          </div>
        <% end %>

        <%= if @reply do %>
          <form phx-submit="relay" class="space-y-3">
            <input type="hidden" name="agent" value={@agent} />
            <h3 class="text-sm font-medium">
              Your reply to the customer — write whatever you want; the AI's draft is only a starting point
            </h3>
            <textarea
              name="final_answer"
              rows="6"
              data-drop
              class="textarea textarea-bordered w-full"
              placeholder="Type your reply… (drag fields above in, or ignore the AI entirely)"
            >{reply_seed(@interaction)}</textarea>
            <div class="flex gap-2">
              <button type="submit" class="btn btn-primary">Relay to customer</button>
              <button type="button" phx-click="discard" class="btn btn-ghost">Discard</button>
            </div>
          </form>
        <% else %>
          <div :if={@interaction} class="flex items-center gap-2">
            <button type="button" phx-click="draft_reply" class="btn btn-outline btn-sm">
              Write a reply
            </button>
            <span class="text-xs text-base-content/50">you write it; the AI just helps</span>
          </div>
        <% end %>

        <details class="text-xs text-base-content/60">
          <summary class="cursor-pointer">Raw source payload</summary>
          <pre class="bg-base-200 rounded p-3 mt-2 overflow-x-auto">{facts_text(@interaction.facts)}</pre>
        </details>
      </section>

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
          phx-value-tab="chat"
          class={tab_class(@right_tab == "chat")}
        >
          Chat
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
      </div>

      <div
        :if={@right_tab == "chat"}
        class="space-y-2 max-h-[74vh] overflow-y-auto rounded-lg border border-base-300 p-3"
      >
        <div :for={m <- @messages} class={chat_row(m.role)}>
          <div class={chat_bubble(m)}>
            <div class="text-[10px] uppercase tracking-wide opacity-60">
              {if m.role == :user, do: "You", else: "Tragar AI"}
            </div>
            {m.text}
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
        <div :if={@messages == []} class="p-2 text-xs text-base-content/60">
          Ask Tragar AI on the left — the conversation appears here.
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

        <div :if={@detail} class="rounded-lg border border-base-300 p-3 max-h-[72vh] overflow-y-auto">
          <h4 class="text-xs font-medium mb-1">{@detail_title}</h4>
          <dl class="text-xs">
            <div
              :for={f <- surfaced_fields(%{facts: @detail})}
              class="flex justify-between gap-3 border-b border-base-200 py-1"
            >
              <dt class="text-base-content/60">{f.label}</dt>
              <dd class="text-right">{f.value}</dd>
            </div>
          </dl>

          <%= if (events = @detail["events"]) not in [nil, []] do %>
            <div class="mt-3">
              <div class="text-[11px] font-medium uppercase tracking-wide text-base-content/50 mb-1">
                Tracking ({length(events)})
              </div>
              <ol class="space-y-1">
                <li :for={e <- Enum.reverse(events)} class="text-[11px] border-l-2 border-base-300 pl-2">
                  <div class="text-base-content/50">{e["event_date"]} {e["event_time"]}</div>
                  <div class="whitespace-pre-line">{e["event_description"]}</div>
                </li>
              </ol>
            </div>
          <% end %>

          <details class="mt-3 text-[11px] text-base-content/60">
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

  defp load_tickets(socket) do
    tickets =
      case Support.list_tickets() do
        {:ok, list} -> sort_tickets(list, socket.assigns.ticket_sort)
        _ -> []
      end

    assign(socket, tickets: tickets)
  end

  @epoch ~U[1970-01-01 00:00:00Z]

  defp sort_tickets(list, "recent"),
    do: Enum.sort_by(list, &(&1.received_at || @epoch), {:desc, DateTime})

  defp sort_tickets(list, "priority"),
    do:
      Enum.sort_by(
        list,
        &{priority_rank(&1.priority), DateTime.to_unix(&1.received_at || @epoch)}
      )

  defp sort_tickets(list, "status"),
    do: Enum.sort_by(list, &{&1.status || "", DateTime.to_unix(&1.received_at || @epoch)})

  defp sort_tickets(list, _fifo),
    do: Enum.sort_by(list, &(&1.received_at || @epoch), {:asc, DateTime})

  defp priority_rank(p) do
    case String.downcase(to_string(p)) do
      "urgent" -> 0
      "high" -> 1
      "medium" -> 2
      "low" -> 3
      _ -> 4
    end
  end

  defp ticket_prompt(%{waybill_reference: wb}) when is_binary(wb) and wb != "",
    do: {"Where is waybill #{wb}?", %{waybill: wb}}

  defp ticket_prompt(t),
    do: {"Show ticket #{t.ticket_id}", %{ticket_id: t.ticket_id}}

  defp load_detail(socket, type, key) do
    case fetch_detail(type, key, socket.assigns.demo) do
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

  # In demo mode, resolve a known customer name in the question to its account.
  defp resolve_demo_entities(question, entities) do
    if Map.has_key?(entities, :account) do
      entities
    else
      case demo_account_for(String.downcase(question)) do
        nil -> entities
        acc -> Map.put(entities, :account, acc)
      end
    end
  end

  # Map a customer name, invoice number, or waybill mentioned in the question to
  # its account, so account-scoped intents (customer/invoice) resolve in demo.
  defp demo_account_for(q) do
    name =
      TragarAi.Demo.Fixtures.customer()["name"]
      |> String.split()
      |> List.first()
      |> String.downcase()

    invoice = TragarAi.Demo.Fixtures.invoice()
    invoice_no = String.downcase(invoice["invoice_number"])

    cond do
      String.contains?(q, name) -> TragarAi.Demo.Fixtures.account_reference()
      String.contains?(q, invoice_no) -> invoice["account_reference"]
      true -> waybill_account(q)
    end
  end

  defp waybill_account(q) do
    Enum.find_value(TragarAi.Demo.Fixtures.shipments(), fn {wb, s} ->
      if String.contains?(q, wb), do: s["account_reference"]
    end)
  end

  defp fetch_detail(type, key, demo) do
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
      demo -> TragarAi.Demo.fetch(intent, entities)
      true -> TragarAi.Adapters.fetch(intent, entities)
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

  # One chat turn: interpret in the running frame, validate+fetch+phrase or
  # clarify, accumulate the frame, and append the user + AI messages.
  defp converse(socket, text, reply?) do
    frame = socket.assigns.frame

    base =
      if socket.assigns.demo,
        do: resolve_demo_entities(text, frame.entities),
        else: frame.entities

    context = %{
      demo: socket.assigns.demo,
      agent: blank_to_nil(socket.assigns.agent),
      entities: base,
      intent: frame.intent
    }

    {:ok, interaction} = Engine.answer(text, context)
    resolved? = interaction.status == :drafted

    new_frame = %{
      intent: carry_intent(interaction, frame.intent),
      entities: Map.merge(base, atomize_entities(interaction.entities))
    }

    ai_message = %{
      role: :ai,
      text: interaction.draft_answer,
      resolved: resolved?,
      suggestions: if(resolved?, do: [], else: suggest(interaction))
    }

    messages = socket.assigns.messages ++ [%{role: :user, text: text}, ai_message]

    socket
    |> assign(
      messages: messages,
      frame: new_frame,
      question: "",
      # Keep the interaction (even if unresolved) so the agent can always reply.
      interaction: interaction,
      reply: reply?,
      right_tab: "chat"
    )
    |> load_history()
  end

  # The composer starts from the AI's answer only when it actually answered;
  # never seed it with a clarify/error message.
  defp reply_seed(%{status: :drafted, draft_answer: draft}), do: draft
  defp reply_seed(_), do: ""

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

  defp reset_chat_state(socket) do
    assign(socket,
      messages: [],
      frame: %{intent: nil, entities: %{}},
      interaction: nil,
      reply: false,
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
  defp surfaced_fields(%{facts: facts}) when is_map(facts) do
    scalars =
      for {k, v} <- facts, k not in ~w(events last_event pod waybill_number), scalar?(v) do
        field(k, v)
      end

    id_field =
      if facts["waybill_number"], do: [field("waybill_number", facts["waybill_number"])], else: []

    id_field ++ scalars ++ event_field(facts["last_event"]) ++ pod_field(facts["pod"])
  end

  defp surfaced_fields(_), do: []

  defp scalar?(v), do: is_binary(v) or is_number(v) or is_boolean(v)

  defp field(key, value) do
    label = humanize(key)
    display = if key in ~w(status status_code), do: humanize_status(value), else: to_string(value)
    %{label: label, value: display, snippet: "#{label}: #{display}"}
  end

  # FreightWare status codes → plain language for the chips.
  defp humanize_status(value) do
    case String.upcase(to_string(value)) do
      "POD" -> "Delivered"
      "DLV" -> "Delivered"
      "DEL" -> "Delivered"
      "INT" -> "In transit"
      "COL" -> "Collected"
      _ -> to_string(value)
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
