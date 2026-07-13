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
  alias TragarAi.Freight.Accounts
  alias TragarAi.Freight.Statuses

  # The console waybill search is bounded to at most the last month.
  @wb_window_days 30

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(question: "", agent: "")
     |> assign(messages: [], frame: %{intent: nil, entities: %{}})
     |> assign(interaction: nil, last_runtime: nil, live_facts: [])
     |> assign(model: TragarAi.CoreAI.info())
     |> assign(right_tab: "log", detail: nil, detail_title: nil)
     |> assign(search_results: [], search_meta: nil)
     |> assign(wb_account: "", account_matches: [])
     |> assign(quote_results: [], quote_meta: nil)
     |> assign(selected_ticket: nil, distilling: false, account_choices: [])
     # nil = free console session → unscoped (trusted internal lookup). A loaded
     # ticket sets this to the requester's entitled accounts, scoping like FD.
     |> assign(ticket_accounts: nil)
     |> assign(attachments: [], queued_question: nil)
     |> assign(pre_simplify: nil, simplifying: false)
     |> assign(ticket_status: "open", ticket_agent: nil, agents: [])
     |> assign(next_msg_id: 0, last_question: nil)
     |> load_history()
     |> load_agents()
     |> load_tickets()}
  end

  # ── Prompt (centre) ─────────────────────────────────────────────────────────

  # "Simplify" — rewrite the prompt into a concise, accurate restatement of what's
  # being asked (folding in the read attachment contents, keeping every reference),
  # and drop it back into the textarea for review. Undo via "restore original".
  @impl true
  def handle_event("ask", %{"op" => "simplify"} = params, socket) do
    text = String.trim(params["question"] || "")
    engine_text = text <> attachments_block(socket.assigns.attachments)

    if text == "" do
      {:noreply,
       put_flash(socket, :error, "Nothing to simplify — load a ticket or type a request first.")}
    else
      {:noreply,
       socket
       |> assign(simplifying: true, pre_simplify: params["question"])
       |> start_async(:simplify, fn -> TragarAi.CoreAI.summarize(engine_text) end)}
    end
  end

  def handle_event("restore_original", _params, socket) do
    {:noreply,
     assign(socket,
       question: socket.assigns.pre_simplify || socket.assigns.question,
       pre_simplify: nil
     )}
  end

  # A chat turn: the AI keeps clarifying (carrying the frame) until it resolves
  # the intent, or the user ends the chat.
  def handle_event("ask", params, socket) do
    text = String.trim(params["question"] || "")

    # Refresh the model badge so a settings switch shows up without a page reload.
    socket =
      assign(socket,
        agent: params["agent"] || socket.assigns.agent,
        model: TragarAi.CoreAI.info()
      )

    cond do
      text == "" ->
        {:noreply, put_flash(socket, :error, "Type a message first.")}

      ticket = parse_ticket_fetch(text) ->
        # "ticket 227703" / "#227703" → fetch that ticket, distil + resolve it.
        {:noreply, start_ticket_load(socket, ticket)}

      spec = parse_quote_search(text) ->
        {:noreply, search_or_converse(socket, text, :quotes, spec)}

      spec = parse_waybill_search(text) ->
        {:noreply, search_or_converse(socket, text, :waybills, spec)}

      # Attachments are still being read — hold the prompt and run it automatically
      # once extraction finishes, so the answer sees their contents.
      extracting?(socket.assigns.attachments) ->
        {:noreply,
         socket
         |> assign(queued_question: text, question: "")
         |> put_flash(:info, "Reading attachments — I'll answer as soon as they're done.")}

      true ->
        {:noreply, converse(socket, text)}
    end
  end

  def handle_event("search_waybills", params, socket) do
    case blank_to_nil(params["account"]) do
      nil ->
        {:noreply, put_flash(socket, :error, "Enter an account to search.")}

      acc ->
        {from, to} =
          clamp_wb_dates(blank_to_nil(params["date_from"]), blank_to_nil(params["date_to"]))

        {:noreply,
         socket
         |> assign(account_matches: [])
         |> run_waybill_search(
           acc,
           params["status"] || "all",
           from,
           to,
           blank_to_nil(params["waybill_number"]),
           blank_to_nil(params["shipper_reference"])
         )}
    end
  end

  # Type-ahead over the accounts already ingested (the cached FreightWare
  # directory) as the user types into the waybill account field.
  def handle_event("wb_account_search", %{"value" => value}, socket) do
    {:noreply, assign(socket, wb_account: value, account_matches: Accounts.search(value))}
  end

  def handle_event("pick_wb_account", %{"ref" => ref}, socket) do
    {:noreply, assign(socket, wb_account: ref, account_matches: [])}
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
    do: {:noreply, start_ticket_load(socket, id)}

  # Fetch a ticket by number (listed or not) via the input above the ticket list.
  def handle_event("fetch_ticket", %{"ticket_no" => id}, socket) do
    case String.trim(to_string(id)) do
      "" -> {:noreply, put_flash(socket, :error, "Enter a ticket number.")}
      n -> {:noreply, start_ticket_load(socket, n)}
    end
  end

  # Pick one account when the resolver returned several candidates, then CONTINUE
  # — re-run the pending prompt now that the account is chosen, rather than leaving
  # the agent to re-submit (which felt like a reset).
  def handle_event("pick_account", %{"ref" => ref}, socket) do
    frame = put_in(socket.assigns.frame.entities[:account], ref)
    socket = assign(socket, frame: frame, account_choices: [])

    # Re-run the prompt that triggered the ambiguity — the still-unsent input if
    # present (e.g. a loaded ticket), otherwise the last submitted prompt. The
    # chosen account now scopes it (frame.entities[:account]).
    case blank_to_nil(socket.assigns.question) || socket.assigns[:last_question] do
      nil -> {:noreply, socket}
      q -> {:noreply, converse(socket, q)}
    end
  end

  # "Check all" when the user isn't sure which of several accounts owns the
  # reference. Probe each candidate in turn and STOP at the first that yields a
  # grounded result — so a waybill/quote is located without the agent guessing.
  def handle_event("check_all_accounts", _params, socket) do
    refs = socket.assigns.account_choices
    q = blank_to_nil(socket.assigns.question) || socket.assigns[:last_question]

    case {refs, q} do
      {[], _} -> {:noreply, socket}
      {_, nil} -> {:noreply, socket}
      {refs, q} -> {:noreply, converse_all(socket, q, refs)}
    end
  end

  # ── Attachments ─────────────────────────────────────────────────────────────

  # Toggle whether an attachment is selected for extraction (only while it's still
  # selectable — a supported file that hasn't been read/queued yet).
  def handle_event("toggle_attachment", %{"id" => id}, socket) do
    attachments =
      Enum.map(socket.assigns.attachments, fn a ->
        if to_string(a.id) == id and selectable?(a), do: %{a | selected: not a.selected}, else: a
      end)

    {:noreply, assign(socket, attachments: attachments)}
  end

  # Kick off async extraction for every selected, not-yet-read attachment.
  def handle_event("extract_attachments", _params, socket) do
    socket =
      Enum.reduce(socket.assigns.attachments, socket, fn a, sock ->
        if a.selected and selectable?(a), do: start_extract(sock, a), else: sock
      end)

    {:noreply, socket}
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
          simplifying={@simplifying}
          pre_simplify={@pre_simplify}
          account_choices={@account_choices}
          attachments={@attachments}
          queued_question={@queued_question}
          frame={@frame}
          messages={@messages}
          interaction={@interaction}
          last_runtime={@last_runtime}
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
          wb_account={@wb_account}
          account_matches={@account_matches}
          quote_results={@quote_results}
          quote_meta={@quote_meta}
        />
      </div>

      <.ticket_modal ticket={@selected_ticket} />

      <script :type={Phoenix.LiveView.ColocatedHook} name=".DragDrop">
        export default {
          mounted() { this.bind() },
          bind() {
            // Guard on the hook instance, NOT a DOM data-attribute: morphdom strips
            // attributes the server didn't render, so a data-* guard would reset on
            // every update (each streamed token re-renders) and stack duplicate
            // listeners — one chip click would then insert the snippet many times.
            // All handlers are delegated on the root, so they cover chips/textareas
            // added by later renders without re-binding.
            if (this.bound) return
            this.bound = true
            const el = this.el
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
            el.addEventListener("dragover", (e) => {
              if (e.target.closest("textarea[data-drop]")) e.preventDefault()
            })
            el.addEventListener("drop", (e) => {
              const ta = e.target.closest("textarea[data-drop]")
              if (!ta) return
              e.preventDefault()
              this.insert(ta, e.dataTransfer.getData("text/plain"))
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
            title="Click to load this ticket into a prompt"
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
          Several accounts match — pick one to scope this, or check them all:
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
          <button
            :if={length(@account_choices) > 1}
            type="button"
            phx-click="check_all_accounts"
            class="btn btn-xs btn-primary"
          >
            Check all
          </button>
        </div>
      </div>

      <div :if={@frame.entities[:account]} class="text-xs text-base-content/60">
        Scoped to account <span class="badge badge-xs badge-ghost">{@frame.entities[:account]}</span>
      </div>

      <div
        :if={@attachments != []}
        class="rounded-lg border border-base-300 p-2 text-sm space-y-2"
      >
        <div class="flex items-center justify-between gap-2">
          <span class="text-xs text-base-content/70">
            Ticket attachments — tick the relevant ones to read into the prompt:
          </span>
          <button
            type="button"
            phx-click="extract_attachments"
            class="btn btn-xs btn-primary"
            disabled={not any_selectable?(@attachments)}
          >
            Extract selected
          </button>
        </div>
        <ul class="space-y-1">
          <li :for={a <- @attachments} class="flex items-center gap-2">
            <input
              type="checkbox"
              class="checkbox checkbox-xs"
              checked={a.selected}
              disabled={not selectable?(a)}
              phx-click="toggle_attachment"
              phx-value-id={a.id}
            />
            <span class="truncate flex-1" title={a.name}>{a.name}</span>
            <span class="text-[11px] text-base-content/50 shrink-0">{human_size(a.size)}</span>
            <span class={"badge badge-xs shrink-0 " <> attach_badge(a)}>{attach_status(a)}</span>
          </li>
        </ul>
        <div :if={@queued_question} class="text-[11px] text-base-content/60">
          Prompt queued — it'll run once the selected attachments are read.
        </div>
      </div>

      <form phx-submit="ask" class="space-y-2">
        <textarea
          name="question"
          rows="3"
          data-drop
          disabled={@distilling}
          class="textarea textarea-bordered w-full"
          placeholder="Ask Tragar AI — or click a Freshdesk ticket on the left to load it into a prompt…"
        >{@question}</textarea>
        <div class="flex flex-wrap items-center gap-3">
          <button
            type="submit"
            name="op"
            value="send"
            class="btn btn-primary"
            disabled={@distilling or @simplifying}
          >
            Send
          </button>
          <button
            type="submit"
            name="op"
            value="simplify"
            class="btn btn-outline btn-sm"
            disabled={@distilling or @simplifying}
            title="Show the references/intents the model extracts from this prompt"
          >
            Simplify
          </button>
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
            <span class="loading loading-spinner loading-xs"></span> Loading ticket…
          </span>
          <span :if={@simplifying} class="flex items-center gap-2 text-sm text-base-content/60">
            <span class="loading loading-spinner loading-xs"></span> Simplifying…
          </span>
        </div>
      </form>

      <p :if={@pre_simplify} class="text-[11px] text-base-content/60 flex items-center gap-1">
        <span>Request simplified.</span>
        <button type="button" phx-click="restore_original" class="link link-primary">
          Restore original
        </button>
      </p>

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
          <span :if={provisional?(@interaction)} class="badge badge-ghost gap-1">
            <span class="loading loading-spinner loading-xs"></span> Retrieving…
          </span>
          <span :if={not provisional?(@interaction)} class={"badge " <> outcome_class(@interaction)}>
            {outcome_label(@interaction)}
          </span>
          <span :if={show_intent?(@interaction)} class="badge badge-ghost">
            {@interaction.intent}
          </span>
          <span :if={@interaction.source} class="text-base-content/60">
            via {@interaction.source}
          </span>
          <span
            :if={@last_runtime}
            class="badge badge-ghost badge-sm gap-1"
            title="Wall-clock time for this request"
          >
            ⏱ {@last_runtime.ms} ms · {TragarAi.Assist.SearchStrategy.label(@last_runtime.strategy)}
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
          <div class="relative">
            <input
              name="account"
              value={@wb_account}
              autocomplete="off"
              phx-keyup="wb_account_search"
              phx-debounce="200"
              placeholder="Account, e.g. ITD02"
              class="input input-bordered input-xs w-full"
            />
            <ul
              :if={@account_matches != []}
              class="absolute z-10 mt-0.5 w-full rounded-lg border border-base-300 bg-base-100 shadow divide-y divide-base-200 max-h-48 overflow-y-auto"
            >
              <li :for={a <- @account_matches}>
                <button
                  type="button"
                  phx-click="pick_wb_account"
                  phx-value-ref={a.ref}
                  class="w-full text-left px-2 py-1 hover:bg-base-200"
                >
                  <span class="text-xs font-medium">{a.ref}</span>
                  <span :if={a.name != ""} class="text-[11px] text-base-content/50">· {a.name}</span>
                </button>
              </li>
            </ul>
          </div>
          <input
            name="waybill_number"
            placeholder="Waybill number (optional)"
            class="input input-bordered input-xs w-full"
          />
          <input
            name="shipper_reference"
            placeholder="Shipper reference (optional)"
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
            <input
              type="date"
              name="date_from"
              min={wb_date_min()}
              max={today_iso()}
              class="input input-bordered input-xs flex-1"
            />
            <input
              type="date"
              name="date_to"
              min={wb_date_min()}
              max={today_iso()}
              class="input input-bordered input-xs flex-1"
            />
          </div>
          <div class="text-[11px] text-base-content/40">Searches the last month by default.</div>
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
            <input
              name="dkey"
              placeholder="e.g. DIS0124440"
              class="input input-bordered input-xs flex-1"
            />
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

  # Fetch a ticket → load its contents into the prompt → resolve its account.
  # Async (the model call takes ~1s); result handled in handle_async(:load_ticket).
  defp start_ticket_load(socket, id) do
    socket
    |> assign(distilling: true, selected_ticket: nil, account_choices: [], attachments: [])
    |> start_async(:load_ticket, fn ->
      # Pre-fill the prompt with the ACTUAL ticket contents (subject + body), not a
      # distilled summary — the agent edits/submits it as-is.
      with {:ok, info} <- TragarAi.Freshdesk.ticket_text(id) do
        accounts = resolve_ticket_accounts(id, info)
        {info.ticket_id, info.text, accounts, load_attachments(id)}
      end
    end)
  end

  defp load_attachments(id) do
    case TragarAi.Freshdesk.ticket_attachments(id) do
      {:ok, list} -> Enum.map(list, &init_attachment/1)
      _ -> []
    end
  end

  # A fetched attachment as UI state: unselected, not yet read, and flagged with
  # whether we can extract its type at all.
  defp init_attachment(a) do
    Map.merge(a, %{
      status: :pending,
      selected: false,
      text: nil,
      chars: 0,
      error: nil,
      supported: TragarAi.Assist.Extract.supported?(a.content_type, a.name)
    })
  end

  # Which account(s) to scope the ticket to. Prefer the requester's ENTITLED
  # accounts from the Freshdesk API (the Company `freightware_accounts` field, via
  # ticket → company) — the authoritative allowed set — so a single entitled
  # account auto-scopes and several offer a chooser (+ "Check all"). Fall back to
  # resolving one account from the ticket content when the requester has no linked
  # company/accounts. Returned in the {:ok, ref} | {:ambiguous, refs} | :none shape
  # that handle_async(:load_ticket) already understands.
  defp resolve_ticket_accounts(id, info) do
    case TragarAi.Freshdesk.accounts_for_requester(id) do
      {:ok, [ref]} -> {:ok, ref}
      {:ok, [_ | _] = refs} -> {:ambiguous, refs}
      _ -> TragarAi.Freshdesk.resolve_account(info)
    end
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

    # The model sees the prompt PLUS any extracted attachment text; the chat shows
    # only the typed prompt (history stays clean, references get picked up).
    engine_text = text <> attachments_block(socket.assigns.attachments)

    context =
      %{
        agent: blank_to_nil(socket.assigns.agent),
        channel: :console,
        entities: base,
        intent: frame.intent,
        history: build_history(socket.assigns.messages),
        on_chunk: fn chunk -> send(lv, {:chunk, id, chunk}) end,
        on_event: fn event -> send(lv, {:event, id, event}) end
      }
      |> maybe_scope(socket.assigns.ticket_accounts)

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
      pre_simplify: nil,
      # Remember the prompt so an account pick (or other re-run) can replay it.
      last_question: text,
      next_msg_id: id + 1,
      right_tab: "log",
      # Cleared now; set from the timed run below so it reflects THIS request only.
      last_runtime: nil,
      # Clear the prior result; facts stream in via {:facts,…} before the answer
      # finishes, repopulating the resource panel as they're retrieved.
      interaction: nil,
      live_facts: []
    )
    |> start_async({:converse, id}, fn ->
      strategy = TragarAi.Assist.SearchStrategy.get()
      {micros, result} = :timer.tc(fn -> Engine.answer(engine_text, context) end)
      {result, base, frame.intent, %{ms: div(micros, 1000), strategy: strategy}}
    end)
  end

  # Like `converse/2`, but fans the pending prompt across every candidate account
  # SEQUENTIALLY (a FreightWare login invalidates the previous session, so probes
  # must not run concurrently), stopping at the first grounded hit. Per-account
  # progress streams into the log via {:event, ...}; the outcome is applied in
  # handle_async({:check_all, id}, ...).
  defp converse_all(socket, text, refs) do
    frame = socket.assigns.frame
    base = frame.entities
    intent = frame.intent
    agent = blank_to_nil(socket.assigns.agent)

    id = socket.assigns.next_msg_id
    lv = self()

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

    user_text = "Check all matching accounts (#{Enum.join(refs, ", ")}) for this."

    socket
    |> assign(
      messages: socket.assigns.messages ++ [%{role: :user, text: user_text}, pending],
      question: "",
      # Remember the prompt so a later re-run (e.g. an account pick) can replay it.
      last_question: text,
      account_choices: [],
      next_msg_id: id + 1,
      right_tab: "log"
    )
    |> start_async({:check_all, id}, fn ->
      check_accounts(text, refs, base, intent, agent, id, lv)
    end)
  end

  # Probe each account in order; halt on the first grounded (`:drafted`) answer.
  # Returns {:found, ref, interaction, entities} or {:none, base}. Each attempt
  # emits its own source step (keyed by the account) so the log shows progress.
  defp check_accounts(text, refs, base, intent, agent, id, lv) do
    step_intent = intent || :lookup

    Enum.reduce_while(refs, {:none, base}, fn ref, _acc ->
      entities = Map.put(base, :account, ref)
      label = %{account: ref}
      send(lv, {:event, id, {:source_started, step_intent, "FreightWare", label}})

      context = %{
        agent: agent,
        channel: :console,
        entities: entities,
        intent: intent,
        history: [],
        # This iteration probes ONE candidate account: scope the gate to it (and
        # keep the engine's own search to this single account, no re-cycling).
        accounts: [ref],
        # No streaming while probing — the matched answer is applied in one shot.
        on_chunk: nil,
        on_event: fn _ -> :ok end
      }

      case Engine.answer(text, context) do
        {:ok, %{status: :drafted} = interaction} ->
          send(lv, {:event, id, {:source_done, step_intent, "FreightWare", label, true}})
          {:halt, {:found, ref, interaction, entities}}

        _ ->
          send(lv, {:event, id, {:source_done, step_intent, "FreightWare", label, false}})
          {:cont, {:none, base}}
      end
    end)
  end

  # Prior turns as a compact transcript for the model, so follow-ups resolve
  # against the conversation instead of the user having to repeat context. Only
  # real user/AI text (skip the in-flight pending bubble); keep the last ~6 turns.
  defp build_history(messages) do
    messages
    |> Enum.flat_map(fn
      %{role: :user, text: t} when is_binary(t) and t != "" -> [%{role: "user", text: t}]
      %{role: :ai, text: t} when is_binary(t) and t != "" -> [%{role: "assistant", text: t}]
      _ -> []
    end)
    |> Enum.take(-12)
  end

  @impl true
  def handle_async(
        {:converse, id},
        {:ok, {{:ok, interaction}, base, prior_intent, timing}},
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
        last_runtime: timing,
        # The real interaction supersedes the provisional facts view.
        live_facts: [],
        right_tab: "log"
      )
      |> load_history()

    {:noreply, socket}
  end

  # Ticket loaded into a prompt → pre-fill the input for editing, carrying the
  # ticket_id (so a relayed answer posts back) and the resolved account. If the
  # resolver returned several candidates, offer a chooser instead of guessing.
  def handle_async(:load_ticket, {:ok, {ticket_id, query, resolution, attachments}}, socket)
      when is_binary(query) do
    {account, choices} =
      case resolution do
        {:ok, ref} -> {ref, []}
        {:ambiguous, refs} -> {nil, refs}
        _ -> {nil, []}
      end

    # The requester's entitled accounts, threaded into context as `:accounts` so a
    # console ticket is scoped exactly like the FD webhook: a number is only
    # surfaced if its waybill belongs to one of these. Empty = deny (as FD does)
    # when we couldn't resolve the ticket's account.
    accounts =
      case resolution do
        {:ok, ref} -> [ref]
        {:ambiguous, refs} -> refs
        _ -> []
      end

    entities = %{ticket_id: ticket_id} |> put_if(:account, account)

    {:noreply,
     socket
     |> reset_chat_state()
     |> assign(
       question: query,
       frame: %{intent: nil, entities: entities},
       distilling: false,
       account_choices: choices,
       ticket_accounts: accounts,
       attachments: attachments
     )}
  end

  def handle_async(:load_ticket, {:ok, _}, socket) do
    {:noreply,
     socket
     |> assign(distilling: false)
     |> put_flash(:error, "Couldn't load that ticket from Freshdesk.")}
  end

  def handle_async(:load_ticket, {:exit, reason}, socket) do
    Logger.error("[console] ticket load crashed: #{inspect(reason)}")

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

  # "Check all" found a grounded answer — show it and scope the frame to the
  # matching account so follow-ups continue there (as if it had been picked).
  def handle_async({:check_all, id}, {:ok, {:found, _ref, interaction, entities}}, socket) do
    ai = %{
      role: :ai,
      id: id,
      pending: false,
      stream: "",
      text: interaction.draft_answer,
      resolved: true,
      suggestions: []
    }

    new_frame = %{
      intent: carry_intent(interaction, socket.assigns.frame.intent),
      entities: Map.merge(entities, atomize_entities(interaction.entities))
    }

    socket =
      socket
      |> assign(
        messages: replace_msg(socket.assigns.messages, id, ai),
        frame: new_frame,
        interaction: interaction,
        right_tab: "log"
      )
      |> load_history()

    {:noreply, socket}
  end

  def handle_async({:check_all, id}, {:ok, {:none, _base}}, socket) do
    ai = %{
      role: :ai,
      id: id,
      pending: false,
      stream: "",
      text:
        "Checked all matching accounts — no waybill or quote turned up under any of them. " <>
          "Please double-check the reference.",
      resolved: false,
      suggestions: []
    }

    {:noreply, assign(socket, messages: replace_msg(socket.assigns.messages, id, ai))}
  end

  def handle_async({:check_all, id}, {:exit, reason}, socket) do
    Logger.error("[console] check_all crashed: #{inspect(reason)}")

    ai = %{
      role: :ai,
      id: id,
      pending: false,
      stream: "",
      text: "Something went wrong while checking the accounts — please try again.",
      resolved: false,
      suggestions: []
    }

    {:noreply, assign(socket, messages: replace_msg(socket.assigns.messages, id, ai))}
  end

  # Attachment extraction finished (or died) — record the outcome, then run any
  # prompt that was queued waiting on it.
  def handle_async({:extract, id}, {:ok, {_id, result}}, socket) do
    {:noreply, socket |> apply_extract_result(id, result) |> maybe_run_queued()}
  end

  def handle_async({:extract, id}, {:exit, reason}, socket) do
    Logger.error("[console] attachment extract crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> update_attachment(id, %{status: :error, error: "crashed"})
     |> maybe_run_queued()}
  end

  # "Simplify" finished — drop the restated request into the prompt for review.
  def handle_async(:simplify, {:ok, {:ok, summary}}, socket) when is_binary(summary) do
    {:noreply,
     socket
     |> assign(simplifying: false, question: String.trim(summary))
     |> put_flash(:info, "Simplified — review it, then Send. Use “restore original” to undo.")}
  end

  def handle_async(:simplify, {:ok, _}, socket) do
    {:noreply,
     socket
     |> assign(simplifying: false, pre_simplify: nil)
     |> put_flash(:error, "Couldn't simplify that request.")}
  end

  def handle_async(:simplify, {:exit, reason}, socket) do
    Logger.error("[console] simplify crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(simplifying: false, pre_simplify: nil)
     |> put_flash(:error, "Couldn't simplify that request.")}
  end

  @impl true
  def handle_info({:chunk, id, chunk}, socket) do
    messages =
      Enum.map(socket.assigns.messages, fn m ->
        if Map.get(m, :id) == id, do: %{m | stream: Map.get(m, :stream, "") <> chunk}, else: m
      end)

    {:noreply, assign(socket, messages: messages)}
  end

  # Per-attachment extraction progress (downloading → extracting), streamed from
  # the async task so the console shows live status.
  def handle_info({:attach_stage, id, stage}, socket),
    do: {:noreply, update_attachment(socket, id, %{status: stage})}

  # Live per-source progress for a multi-lookup turn (concurrent gather).
  # Facts were retrieved (before the answer finishes phrasing) — surface them in
  # the resource panel now via a provisional interaction, replaced by the real one
  # when the turn completes.
  def handle_info({:event, _id, {:facts, entity, key, intent, entities, sources, fields}}, socket) do
    view = %{
      entity: entity,
      key: key,
      intent: intent,
      entities: entities,
      sources: sources,
      fields: fields
    }

    live = socket.assigns.live_facts ++ [view]
    {:noreply, assign(socket, live_facts: live, interaction: provisional_interaction(live))}
  end

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
        # No entity in play — offer capability hints that don't fire a lookup on a
        # made-up identifier (the old fallback used demo waybill/account values).
        [
          %{label: "What can you do?", q: "What can you help me with?"},
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
    number? = Regex.match?(~r/\bwaybill\s*#?\s*[A-Z0-9][A-Z0-9-]{3,}/i, text)

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

  defp run_waybill_search(
         socket,
         account,
         status,
         date_from \\ nil,
         date_to \\ nil,
         waybill \\ nil,
         shipper \\ nil
       )

  defp run_waybill_search(socket, account, status, date_from, date_to, waybill, shipper) do
    cond do
      not TragarAi.Freight.Accounts.valid?(account) ->
        invalid_account_search(socket, account, status, "search")

      true ->
        run_waybill_search!(socket, account, status, date_from, date_to, waybill, shipper)
    end
  end

  defp run_waybill_search!(socket, account, status, date_from, date_to, waybill, shipper) do
    # A real status code filters server-side; a group (undelivered/delivered/all)
    # fetches the window and filters client-side.
    code = if status in Statuses.waybill_codes(), do: status, else: nil

    case fetch_waybills(account, code, date_from, date_to, waybill, shipper) do
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

  defp fetch_waybills(account, code, from, to, waybill, shipper) do
    params =
      %{account_reference: account}
      |> put_if(:status_code, code)
      |> put_if(:date_from, from)
      |> put_if(:date_to, to)
      |> put_if(:waybill_number, waybill)
      |> put_if(:shipper_reference, shipper)

    case TragarAi.Freight.search_waybills(params) do
      {:ok, r} -> {:ok, r["waybills"] || []}
      err -> err
    end
  end

  # Bound the waybill search to at most the last month: default both ends to the
  # one-month window, and never let date_from reach back past it.
  defp clamp_wb_dates(from, to) do
    floor = Date.add(Date.utc_today(), -@wb_window_days)
    {clamp_from(from, floor), to || today_iso()}
  end

  defp clamp_from(nil, floor), do: Date.to_iso8601(floor)

  defp clamp_from(from, floor) do
    case Date.from_iso8601(from) do
      {:ok, d} -> Date.to_iso8601(Enum.max([d, floor], Date))
      _ -> Date.to_iso8601(floor)
    end
  end

  defp today_iso, do: Date.to_iso8601(Date.utc_today())
  defp wb_date_min, do: Date.to_iso8601(Date.add(Date.utc_today(), -@wb_window_days))

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

  defp provisional?(%{provisional: true}), do: true
  defp provisional?(_), do: false

  # An interaction-shaped map built from facts emitted mid-loop, so the resource
  # panel renders retrieved facts while the answer is still phrasing. Replaced by
  # the real interaction on completion.
  defp provisional_interaction(views) do
    base = %{
      id: nil,
      status: :retrieving,
      draft_answer: nil,
      error: nil,
      agent: nil,
      tool_log: [],
      ticket_id: nil,
      duration_ms: nil,
      search_strategy: nil,
      inserted_at: nil,
      provisional: true
    }

    case views do
      [one] ->
        Map.merge(base, %{
          facts: one.fields,
          source: Enum.join(one.sources, ", "),
          intent: to_string(one.intent),
          entities: str_keys(one.entities)
        })

      many ->
        Map.merge(base, %{
          facts: %{
            "results" =>
              Enum.map(many, fn v ->
                %{
                  "facts" => v.fields,
                  "entities" => str_keys(v.entities),
                  "intent" => to_string(v.intent),
                  "answer" => nil
                }
              end)
          },
          source: many |> Enum.flat_map(& &1.sources) |> Enum.uniq() |> Enum.join(", "),
          intent: many |> Enum.map(&to_string(&1.intent)) |> Enum.uniq() |> Enum.join(", "),
          entities: many |> Enum.flat_map(&Map.to_list(&1.entities)) |> Map.new() |> str_keys()
        })
    end
  end

  defp str_keys(m) when is_map(m), do: Map.new(m, fn {k, v} -> {to_string(k), v} end)
  defp str_keys(other), do: other

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
      question: "",
      attachments: [],
      queued_question: nil,
      pre_simplify: nil,
      # A cleared session is a free console again → unscoped until a ticket loads.
      ticket_accounts: nil
    )
  end

  # Scope a console turn to a loaded ticket's entitled accounts (like the FD
  # webhook). nil = free-typed session → leave `:accounts` unset (unscoped).
  defp maybe_scope(context, nil), do: context
  defp maybe_scope(context, accounts), do: Map.put(context, :accounts, accounts)

  # ── Attachment extraction helpers ────────────────────────────────────────────

  # Selectable = a type we can read that hasn't already been read or queued.
  defp selectable?(%{supported: true, status: s}) when s in [:pending, :error, :skipped],
    do: true

  defp selectable?(_), do: false

  defp extracting?(attachments),
    do: Enum.any?(attachments, &(&1.status in [:queued, :downloading, :extracting]))

  defp start_extract(socket, a) do
    lv = self()
    id = a.id
    %{url: url, content_type: ct, name: name} = a

    socket
    |> update_attachment(id, %{status: :queued, error: nil})
    |> start_async({:extract, id}, fn ->
      send(lv, {:attach_stage, id, :downloading})

      case TragarAi.Freshdesk.Client.download(url) do
        {:ok, bin} ->
          send(lv, {:attach_stage, id, :extracting})
          {id, TragarAi.Assist.Extract.extract(bin, ct, name)}

        {:error, reason} ->
          {id, {:error, {:download, reason}}}
      end
    end)
  end

  defp apply_extract_result(socket, id, {:ok, text}),
    do: update_attachment(socket, id, %{status: :done, text: text, chars: String.length(text)})

  defp apply_extract_result(socket, id, {:skip, reason}),
    do: update_attachment(socket, id, %{status: :skipped, error: skip_label(reason), text: nil})

  defp apply_extract_result(socket, id, {:error, reason}),
    do: update_attachment(socket, id, %{status: :error, error: error_label(reason), text: nil})

  defp update_attachment(socket, id, changes) do
    attachments =
      Enum.map(socket.assigns.attachments, fn a ->
        if to_string(a.id) == to_string(id), do: Map.merge(a, changes), else: a
      end)

    assign(socket, attachments: attachments)
  end

  # Once nothing is in flight, either run a prompt that was queued waiting on
  # extraction, or (nothing queued) fold the read attachment text into the visible
  # prompt so the agent sees exactly what the model will read.
  defp maybe_run_queued(socket) do
    cond do
      extracting?(socket.assigns.attachments) -> socket
      q = socket.assigns[:queued_question] -> converse(assign(socket, queued_question: nil), q)
      true -> fold_attachments_into_prompt(socket)
    end
  end

  # Append each newly-read attachment's text to the end of the prompt textarea
  # (once each — folded attachments are marked and then skipped by
  # attachments_block/1, so the text is never sent twice). This surfaces the
  # extracted contents inline so the agent can see why a reference is/isn't picked
  # up, and edit it before sending.
  defp fold_attachments_into_prompt(socket) do
    pending =
      for a <- socket.assigns.attachments,
          a.status == :done,
          is_binary(a.text) and a.text != "",
          not Map.get(a, :folded, false),
          do: a

    case pending do
      [] ->
        socket

      list ->
        addition = Enum.map_join(list, "\n\n", fn a -> "--- #{a.name} ---\n#{a.text}" end)

        question =
          String.trim_trailing(socket.assigns.question) <>
            "\n\n[Attached documents]\n" <> addition

        folded = MapSet.new(list, & &1.id)

        attachments =
          Enum.map(socket.assigns.attachments, fn a ->
            if MapSet.member?(folded, a.id), do: Map.put(a, :folded, true), else: a
          end)

        assign(socket, question: question, attachments: attachments)
    end
  end

  # The extracted attachment text appended to the model's input. Files already
  # folded into the visible prompt are skipped here so they aren't sent twice.
  defp attachments_block(attachments) do
    read =
      for a <- attachments,
          a.status == :done,
          not Map.get(a, :folded, false),
          is_binary(a.text) and a.text != "",
          do: a

    case read do
      [] ->
        ""

      list ->
        body = Enum.map_join(list, "\n\n", fn a -> "--- #{a.name} ---\n#{a.text}" end)
        "\n\n[Attached documents]\n#{body}"
    end
  end


  defp any_selectable?(attachments),
    do: Enum.any?(attachments, &(&1.selected and selectable?(&1)))

  defp skip_label(:unsupported), do: "not readable"
  defp skip_label(:too_large), do: "too large"
  defp skip_label(:empty), do: "no text"
  defp skip_label(other), do: to_string(other)

  defp error_label(:pdftotext_unavailable), do: "PDF reader unavailable"
  defp error_label({:download, _}), do: "download failed"
  defp error_label(_), do: "couldn't read"

  defp attach_status(%{supported: false}), do: "not readable"
  defp attach_status(%{status: :pending}), do: "ready"
  defp attach_status(%{status: :queued}), do: "queued"
  defp attach_status(%{status: :downloading}), do: "downloading…"
  defp attach_status(%{status: :extracting}), do: "extracting…"
  defp attach_status(%{status: :done, chars: n}), do: "read · #{n} chars"
  defp attach_status(%{status: :skipped, error: e}), do: e || "skipped"
  defp attach_status(%{status: :error, error: e}), do: e || "failed"
  defp attach_status(_), do: ""

  defp attach_badge(%{supported: false}), do: "badge-ghost"
  defp attach_badge(%{status: :done}), do: "badge-success"
  defp attach_badge(%{status: :error}), do: "badge-error"
  defp attach_badge(%{status: :skipped}), do: "badge-warning"

  defp attach_badge(%{status: s}) when s in [:queued, :downloading, :extracting],
    do: "badge-info"

  defp attach_badge(_), do: "badge-ghost"

  defp human_size(b) when not is_integer(b), do: ""
  defp human_size(b) when b >= 1_048_576, do: "#{Float.round(b / 1_048_576, 1)} MB"
  defp human_size(b) when b >= 1024, do: "#{div(b, 1024)} KB"
  defp human_size(b), do: "#{b} B"

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
