defmodule TragarAiWeb.ChatLive do
  @moduledoc """
  A plain chat with the local AI. Type a prompt; the assist loop runs (Core AI
  interprets → Elixir validates/fetches → Core AI phrases) and the answer plus the
  structured model output (intent, entities, source, trace) is shown below.

  The model call runs **asynchronously** (`start_async`) so a slow qwen response
  never blocks the LiveView process — the UI stays responsive (heartbeats keep
  flowing, so the socket doesn't drop and re-mount), shows a "thinking" state, and
  the chat history survives.

  Layout: the prompt is pinned at the top; the conversation scrolls beneath it,
  newest turn first.
  """
  use TragarAiWeb, :live_view

  require Logger

  alias TragarAi.Assist.Engine
  alias TragarAi.CoreAI

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       turns: [],
       prompt: "",
       free_reasoning: false,
       next_id: 0,
       model: CoreAI.info()
     )}
  end

  @impl true
  def handle_event("draft", %{"message" => message}, socket) do
    {:noreply, assign(socket, prompt: message)}
  end

  @impl true
  def handle_event("toggle_reasoning", _params, socket) do
    {:noreply, assign(socket, free_reasoning: not socket.assigns.free_reasoning)}
  end

  @impl true
  def handle_event("send", %{"message" => message}, socket) do
    case String.trim(message) do
      "" ->
        {:noreply, socket}

      text ->
        id = socket.assigns.next_id
        free = socket.assigns.free_reasoning
        lv = self()
        turn = %{id: id, prompt: text, i: nil, error: false, stream: "", steps: []}

        context = %{
          free_reasoning: free,
          on_chunk: fn chunk -> send(lv, {:chunk, id, chunk}) end,
          on_event: fn event -> send(lv, {:event, id, event}) end
        }

        socket =
          socket
          |> update(:turns, &(&1 ++ [turn]))
          |> assign(prompt: "", next_id: id + 1)
          # Off the LiveView process: tokens stream in via {:chunk,...}; the final
          # interaction (status/source/trace) arrives in handle_async.
          |> start_async({:answer, id}, fn -> Engine.answer(text, context) end)

        {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:answer, id}, {:ok, {:ok, interaction}}, socket) do
    {:noreply, update(socket, :turns, &put_turn(&1, id, fn t -> %{t | i: interaction} end))}
  end

  def handle_async({:answer, id}, {:ok, {:error, reason}}, socket) do
    Logger.error("[chat] answer returned error: #{inspect(reason)}")
    {:noreply, update(socket, :turns, &put_turn(&1, id, fn t -> %{t | error: true} end))}
  end

  def handle_async({:answer, id}, {:exit, reason}, socket) do
    Logger.error("[chat] answer crashed: #{inspect(reason)}")
    {:noreply, update(socket, :turns, &put_turn(&1, id, fn t -> %{t | error: true} end))}
  end

  @impl true
  def handle_info({:chunk, id, chunk}, socket) do
    {:noreply,
     update(socket, :turns, &put_turn(&1, id, fn t -> %{t | stream: t.stream <> chunk} end))}
  end

  # Live per-source progress for a multi-lookup turn (concurrent gather).
  def handle_info({:event, id, {:source_started, intent, source, entities}}, socket) do
    step = %{
      key: step_key(intent, entities),
      intent: intent,
      source: source,
      entity: entity_label(entities),
      status: :running
    }

    {:noreply,
     update(
       socket,
       :turns,
       &put_turn(&1, id, fn t -> %{t | steps: upsert_step(t.steps, step)} end)
     )}
  end

  def handle_info({:event, id, {:source_done, intent, _source, entities, ok?}}, socket) do
    status = if ok?, do: :ok, else: :fail
    key = step_key(intent, entities)

    {:noreply,
     update(
       socket,
       :turns,
       &put_turn(&1, id, fn t -> %{t | steps: set_step_status(t.steps, key, status)} end)
     )}
  end

  defp step_key(intent, entities), do: {intent, entity_label(entities)}

  defp entity_label(entities) when is_map(entities),
    do: entities[:waybill] || entities[:quote] || entities[:account] || entities[:ticket_id]

  defp entity_label(_), do: nil

  defp upsert_step(steps, step) do
    if Enum.any?(steps, &(&1.key == step.key)),
      do: Enum.map(steps, &if(&1.key == step.key, do: step, else: &1)),
      else: steps ++ [step]
  end

  defp set_step_status(steps, key, status),
    do: Enum.map(steps, &if(&1.key == key, do: %{&1 | status: status}, else: &1))

  defp put_turn(turns, id, fun),
    do: Enum.map(turns, fn t -> if(t.id == id, do: fun.(t), else: t) end)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-[100dvh] flex flex-col max-w-3xl mx-auto px-4">
      <%!-- Fixed top: header + the prompt --%>
      <div class="shrink-0 pt-4 pb-3 space-y-3 bg-base-100 border-b border-base-200">
        <Layouts.app_nav active={:chat} />
        <header class="flex items-end justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold">Tragar · Local AI chat</h1>
            <p class="text-xs text-base-content/60">
              The local model interprets and phrases; Elixir validates and fetches the facts.
            </p>
          </div>
          <span class="badge badge-ghost shrink-0">model: {@model.label}</span>
        </header>

        <form phx-submit="send" phx-change="draft" class="flex items-end gap-2">
          <textarea
            id="chat-input"
            name="message"
            rows="3"
            placeholder="Ask the local AI…   (Enter to send · Shift+Enter for a new line)"
            class="textarea textarea-bordered flex-1 text-base leading-relaxed resize-none"
            phx-hook=".SubmitOnEnter"
            phx-mounted={JS.focus()}
          >{@prompt}</textarea>
          <button class="btn btn-primary btn-lg">Send</button>
        </form>

        <label class="flex items-center gap-2 text-xs cursor-pointer select-none w-fit">
          <input
            type="checkbox"
            class="toggle toggle-sm toggle-primary"
            phx-click="toggle_reasoning"
            checked={@free_reasoning}
          />
          <span>
            Reason freely
            <span class="text-base-content/50">
              — answer even when no Tragar fact is found (ungrounded)
            </span>
          </span>
        </label>
      </div>

      <%!-- Scrollable conversation, newest first --%>
      <div id="conversation" class="flex-1 overflow-y-auto py-4 space-y-4">
        <p :if={@turns == []} class="text-sm text-base-content/50 py-8 text-center">
          Ask something — e.g. <em>“Where is waybill 0006794936FC?”</em>
          or <em>“What service types do you offer?”</em>
        </p>

        <div :for={turn <- Enum.reverse(@turns)} class="space-y-1">
          <div class="chat chat-end">
            <div class="chat-bubble chat-bubble-primary whitespace-pre-line">{turn.prompt}</div>
          </div>

          <div class="chat chat-start">
            <ul
              :if={turn.steps != []}
              class="mb-1 w-full max-w-sm space-y-0.5 text-[11px] opacity-80"
            >
              <li :for={s <- turn.steps} class="flex items-center gap-1.5">
                <span class={"badge badge-xs " <> step_badge(s.status)}>{step_icon(s.status)}</span>
                <span>{s.source} · {s.intent}</span>
                <span :if={s.entity} class="opacity-60">{s.entity}</span>
              </li>
            </ul>
            <%= cond do %>
              <% turn.i -> %>
                <div class="chat-bubble whitespace-pre-line">{turn.i.draft_answer}</div>
                <div class="chat-footer mt-1 flex flex-wrap items-center gap-1 text-[11px] opacity-70">
                  <span :if={turn.i.intent} class="badge badge-xs badge-outline">
                    {turn.i.intent}
                  </span>
                  <span :if={turn.i.source} class="badge badge-xs badge-ghost">{turn.i.source}</span>
                  <span class={"badge badge-xs " <> status_class(turn.i.status)}>
                    {turn.i.status}
                  </span>
                </div>

                <details class="chat-footer mt-1 text-[11px] opacity-70">
                  <summary class="cursor-pointer">Model output &amp; trace</summary>
                  <div class="mt-1 space-y-2">
                    <div :if={present?(turn.i.entities)}>
                      <div class="font-medium">entities</div>
                      <pre class="bg-base-200 rounded p-2 overflow-x-auto">{pretty(turn.i.entities)}</pre>
                    </div>
                    <div :if={present?(turn.i.facts)}>
                      <div class="font-medium">facts ({turn.i.source})</div>
                      <pre class="bg-base-200 rounded p-2 overflow-x-auto">{pretty(turn.i.facts)}</pre>
                    </div>
                    <div :if={turn.i.tool_log not in [nil, []]}>
                      <div class="font-medium">trace</div>
                      <ol class="space-y-0.5">
                        <li :for={e <- turn.i.tool_log} class="flex items-center gap-1">
                          <span class={"badge badge-xs " <> if(e["ok"], do: "badge-success", else: "badge-error")}>
                            {if e["ok"], do: "ok", else: "fail"}
                          </span>
                          <span>{e["tool"]}</span>
                        </li>
                      </ol>
                    </div>
                  </div>
                </details>
              <% turn.error -> %>
                <div class="chat-bubble chat-bubble-error">
                  Something went wrong answering that — please try again.
                </div>
              <% turn.stream != "" -> %>
                <div class="chat-bubble whitespace-pre-line">
                  {turn.stream}<span class="loading loading-dots loading-xs align-middle ml-1"></span>
                </div>
              <% true -> %>
                <div class="chat-bubble">
                  <span class="loading loading-dots loading-sm align-middle"></span>
                  <span class="opacity-60">thinking…</span>
                </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".SubmitOnEnter">
      export default {
        mounted() {
          this.el.addEventListener("keydown", (e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault()
              this.el.form.requestSubmit()
            }
          })
        }
      }
    </script>
    """
  end

  defp step_badge(:ok), do: "badge-success"
  defp step_badge(:fail), do: "badge-error"
  defp step_badge(_), do: "badge-ghost"

  defp step_icon(:ok), do: "✓"
  defp step_icon(:fail), do: "✗"
  defp step_icon(_), do: "…"

  defp status_class(:drafted), do: "badge-success"
  defp status_class(:relayed), do: "badge-success"
  defp status_class(:reasoned), do: "badge-info"
  defp status_class(_), do: "badge-warning"

  defp present?(m) when is_map(m), do: map_size(m) > 0
  defp present?(_), do: false

  defp pretty(map), do: Jason.encode!(map, pretty: true)
end
