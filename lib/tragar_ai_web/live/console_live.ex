defmodule TragarAiWeb.ConsoleLive do
  @moduledoc """
  The support-assist agent console (Phase 1).

  An agent pastes a customer question (optionally with a waybill / ticket / account),
  the system interprets → validates → fetches live facts → drafts an answer; the
  agent reviews/edits the draft and relays it. The agent is always in the loop —
  nothing here is sent to a customer automatically.
  """
  use TragarAiWeb, :live_view

  alias TragarAi.Assist
  alias TragarAi.Assist.Engine

  @impl true
  def mount(_params, _session, socket) do
    # Demo mode defaults on until the source systems are connected.
    {:ok,
     socket
     |> assign(question: "", waybill: "", ticket_id: "", account: "", agent: "")
     |> assign(interaction: nil, demo: true)
     |> load_history()}
  end

  @impl true
  def handle_event("ask", params, socket) do
    question = String.trim(params["question"] || "")
    demo = params["demo"] == "true"

    if question == "" do
      {:noreply, put_flash(socket, :error, "Enter a question first.")}
    else
      context = %{
        agent: blank_to_nil(params["agent"]),
        entities: entities_from(params),
        demo: demo
      }

      {:ok, interaction} = Engine.answer(question, context)

      {:noreply,
       socket
       |> assign(
         interaction: interaction,
         demo: demo,
         question: question,
         waybill: params["waybill"] || "",
         ticket_id: params["ticket_id"] || "",
         account: params["account"] || "",
         agent: params["agent"] || ""
       )
       |> load_history()}
    end
  end

  def handle_event("run_sample", %{"idx" => idx}, socket) do
    entry = Enum.at(TragarAi.Demo.catalog(), String.to_integer(idx))
    {:ok, interaction} = Engine.answer(entry.question, %{demo: true, entities: entry.entities})

    {:noreply,
     socket
     |> assign(
       interaction: interaction,
       demo: true,
       question: entry.question,
       waybill: entry.entities[:waybill] || "",
       ticket_id: entry.entities[:ticket_id] || "",
       account: entry.entities[:account] || ""
     )
     |> load_history()}
  end

  def handle_event("seed_demo", _params, socket) do
    :ok = TragarAi.Demo.seed()

    {:noreply,
     put_flash(
       socket,
       :info,
       "Demo data loaded — harmonized customer & vehicle are in the resources."
     )}
  end

  def handle_event("relay", %{"final_answer" => final} = params, socket) do
    {:ok, _} =
      Assist.relay_interaction(socket.assigns.interaction, %{
        final_answer: final,
        agent: blank_to_nil(params["agent"])
      })

    {:noreply,
     socket
     |> put_flash(:info, "Answer relayed and logged.")
     |> reset_question()
     |> load_history()}
  end

  def handle_event("discard", _params, socket) do
    {:ok, _} = Assist.discard_interaction(socket.assigns.interaction, %{})

    {:noreply, socket |> reset_question() |> load_history()}
  end

  # ── Rendering ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id="console" phx-hook=".DragDrop" class="mx-auto max-w-3xl p-6 space-y-8">
      <header>
        <h1 class="text-2xl font-semibold">Tragar · Support Assist</h1>
        <p class="text-sm text-base-content/70">
          Ask across the source systems. The system drafts; you review and relay.
        </p>
      </header>

      <form phx-submit="ask" class="space-y-3">
        <textarea
          name="question"
          rows="3"
          data-drop
          class="textarea textarea-bordered w-full"
          placeholder="e.g. Where is load 4821?"
        >{@question}</textarea>
        <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <input name="waybill" value={@waybill} placeholder="Waybill" class="input input-bordered" />
          <input
            name="ticket_id"
            value={@ticket_id}
            placeholder="Ticket #"
            class="input input-bordered"
          />
          <input name="account" value={@account} placeholder="Account" class="input input-bordered" />
          <input name="agent" value={@agent} placeholder="Your name" class="input input-bordered" />
        </div>
        <div class="flex flex-wrap items-center gap-3">
          <button type="submit" class="btn btn-primary">Ask</button>
          <label class="flex items-center gap-2 text-sm cursor-pointer">
            <input
              type="checkbox"
              name="demo"
              value="true"
              checked={@demo}
              class="checkbox checkbox-sm"
            /> Demo mode <span class="text-base-content/50">(fact-check from fixtures)</span>
          </label>
          <button
            type="button"
            phx-click="seed_demo"
            class="btn btn-ghost btn-sm"
            title="Load the demo customer & vehicle into the resources"
          >
            Load demo data
          </button>
        </div>
      </form>

      <section :if={@demo} class="rounded-lg border border-base-300 p-4 space-y-3">
        <div>
          <h2 class="text-base font-medium">Demo data — what you can ask</h2>
          <p class="text-xs text-base-content/60">
            Each source system below holds fixture data. Click a prompt to run it (the answer
            surfaces from that source), or drag it into the question box.
          </p>
        </div>

        <% catalog = TragarAi.Demo.catalog() %>
        <% sources = catalog |> Enum.map(& &1.source) |> Enum.uniq() %>
        <div :for={source <- sources} class="space-y-1">
          <div class="text-[11px] font-medium uppercase tracking-wide text-base-content/50">
            {source}
          </div>
          <div class="flex flex-wrap gap-2">
            <%= for {e, i} <- Enum.with_index(catalog), e.source == source do %>
              <button
                type="button"
                phx-click="run_sample"
                phx-value-idx={i}
                draggable="true"
                data-snippet={e.question}
                class="cursor-pointer rounded-md border border-base-300 bg-base-100 px-2.5 py-1.5 text-left hover:border-primary"
                title="Click to run, or drag into the question box"
              >
                <span class="block text-sm">{e.question}</span>
                <span class="block text-[11px] text-base-content/50">{e.surfaces}</span>
              </button>
            <% end %>
          </div>
        </div>
      </section>

      <section
        :if={@interaction}
        id="resource-panel"
        class="rounded-lg border border-base-300 p-4 space-y-4"
      >
        <div class="flex items-center gap-2 text-sm">
          <span class={"badge " <> status_class(@interaction.status)}>{@interaction.status}</span>
          <span :if={@interaction.intent} class="badge badge-ghost">{@interaction.intent}</span>
          <span :if={@interaction.source} class="text-base-content/60">
            via {@interaction.source}
          </span>
          <span :if={@demo} class="badge badge-warning badge-sm">demo</span>
        </div>

        <div :if={@interaction.error} class="text-sm text-error">
          Could not complete automatically: {@interaction.error}
        </div>

        <%= if (fields = surfaced_fields(@interaction)) != [] do %>
          <div>
            <h3 class="text-sm font-medium mb-2">
              {@interaction.source || "Source"} data — drag or click a field into your reply
            </h3>
            <div class="flex flex-wrap gap-2">
              <button
                :for={f <- fields}
                type="button"
                draggable="true"
                data-snippet={f.snippet}
                data-insert
                class="cursor-grab active:cursor-grabbing rounded-md border border-base-300 bg-base-200 px-2.5 py-1.5 text-left hover:border-primary"
                title="Drag into the reply, or click to insert"
              >
                <span class="block text-[10px] uppercase tracking-wide text-base-content/50">
                  {f.label}
                </span>
                <span class="block text-sm">{f.value}</span>
              </button>
            </div>
          </div>
        <% end %>

        <form phx-submit="relay" class="space-y-3">
          <input type="hidden" name="agent" value={@agent} />
          <h3 class="text-sm font-medium">Draft answer — drop fields in, edit, then relay</h3>
          <textarea
            name="final_answer"
            rows="6"
            data-drop
            class="textarea textarea-bordered w-full"
            placeholder="Drag fields above into here, or type your reply…"
          >{@interaction.draft_answer}</textarea>
          <div class="flex gap-2">
            <button type="submit" class="btn btn-primary">Relay to customer</button>
            <button type="button" phx-click="discard" class="btn btn-ghost">Discard</button>
          </div>
        </form>

        <details class="text-xs text-base-content/60">
          <summary class="cursor-pointer">Raw source payload</summary>
          <pre class="bg-base-200 rounded p-3 mt-2 overflow-x-auto">{facts_text(@interaction.facts)}</pre>
        </details>
      </section>

      <section>
        <h2 class="text-lg font-medium mb-2">Recent</h2>
        <ul class="divide-y divide-base-300 text-sm">
          <li :for={i <- @history} class="py-2 flex items-center justify-between gap-3">
            <span class="truncate">{i.question}</span>
            <span class={"badge badge-sm " <> status_class(i.status)}>{i.status}</span>
          </li>
          <li :if={@history == []} class="py-2 text-base-content/60">No interactions yet.</li>
        </ul>
      </section>

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

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp load_history(socket) do
    history =
      case Assist.list_interactions() do
        {:ok, list} -> list |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime}) |> Enum.take(20)
        _ -> []
      end

    assign(socket, history: history)
  end

  defp reset_question(socket) do
    assign(socket, interaction: nil, question: "", waybill: "", ticket_id: "", account: "")
  end

  defp entities_from(params) do
    %{}
    |> put_entity(:waybill, params["waybill"])
    |> put_entity(:ticket_id, params["ticket_id"])
    |> put_entity(:account, params["account"])
  end

  defp put_entity(acc, key, value) do
    case blank_to_nil(value) do
      nil -> acc
      v -> Map.put(acc, key, v)
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp blank_to_nil(value), do: value

  defp facts_text(facts), do: Jason.encode!(facts, pretty: true)

  # Flatten the resource's facts into draggable {label, value, snippet} fields.
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
    %{label: label, value: to_string(value), snippet: "#{label}: #{value}"}
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

  defp humanize(key) do
    key |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp status_class(:drafted), do: "badge-info"
  defp status_class(:relayed), do: "badge-success"
  defp status_class(:failed), do: "badge-error"
  defp status_class(:discarded), do: "badge-ghost"
  defp status_class(_), do: "badge-ghost"
end
