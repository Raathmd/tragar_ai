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
    {:ok,
     socket
     |> assign(question: "", waybill: "", ticket_id: "", account: "", agent: "")
     |> assign(interaction: nil)
     |> load_history()}
  end

  @impl true
  def handle_event("ask", params, socket) do
    question = String.trim(params["question"] || "")

    if question == "" do
      {:noreply, put_flash(socket, :error, "Enter a question first.")}
    else
      context = %{
        agent: blank_to_nil(params["agent"]),
        entities: entities_from(params)
      }

      {:ok, interaction} = Engine.answer(question, context)

      {:noreply,
       socket
       |> assign(
         interaction: interaction,
         question: question,
         waybill: params["waybill"] || "",
         ticket_id: params["ticket_id"] || "",
         account: params["account"] || "",
         agent: params["agent"] || ""
       )
       |> load_history()}
    end
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
    <div class="mx-auto max-w-3xl p-6 space-y-8">
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
        <button type="submit" class="btn btn-primary">Ask</button>
      </form>

      <section :if={@interaction} class="rounded-lg border border-base-300 p-4 space-y-4">
        <div class="flex items-center gap-2 text-sm">
          <span class={"badge " <> status_class(@interaction.status)}>{@interaction.status}</span>
          <span :if={@interaction.intent} class="badge badge-ghost">{@interaction.intent}</span>
          <span :if={@interaction.source} class="text-base-content/60">
            via {@interaction.source}
          </span>
        </div>

        <div :if={@interaction.error} class="text-sm text-error">
          Could not complete automatically: {@interaction.error}
        </div>

        <div :if={map_size(@interaction.facts || %{}) > 0}>
          <h3 class="text-sm font-medium mb-1">Source facts (read-only)</h3>
          <pre class="bg-base-200 rounded p-3 text-xs overflow-x-auto">{facts_text(@interaction.facts)}</pre>
        </div>

        <form phx-submit="relay" class="space-y-3">
          <input type="hidden" name="agent" value={@agent} />
          <h3 class="text-sm font-medium">Draft answer — review &amp; edit before relaying</h3>
          <textarea name="final_answer" rows="5" class="textarea textarea-bordered w-full">{@interaction.draft_answer}</textarea>
          <div class="flex gap-2">
            <button type="submit" class="btn btn-primary">Relay to customer</button>
            <button type="button" phx-click="discard" class="btn btn-ghost">Discard</button>
          </div>
        </form>
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

  defp status_class(:drafted), do: "badge-info"
  defp status_class(:relayed), do: "badge-success"
  defp status_class(:failed), do: "badge-error"
  defp status_class(:discarded), do: "badge-ghost"
  defp status_class(_), do: "badge-ghost"
end
