defmodule TragarAiWeb.ChatLive do
  @moduledoc """
  A plain chat with the local AI. Type a prompt; the assist loop runs (Core AI
  interprets → Elixir validates/fetches → Core AI phrases) and the answer plus the
  structured model output (intent, entities, source, trace) is shown below.

  Layout: the prompt is pinned at the top; the conversation scrolls beneath it,
  newest turn first.
  """
  use TragarAiWeb, :live_view

  alias TragarAi.Assist.Engine
  alias TragarAi.CoreAI

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, turns: [], prompt: "", free_reasoning: false, model: CoreAI.info())}
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
        {:ok, interaction} = Engine.answer(text, %{free_reasoning: socket.assigns.free_reasoning})
        turn = %{prompt: text, i: interaction}
        {:noreply, assign(socket, turns: socket.assigns.turns ++ [turn], prompt: "")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-[100dvh] flex flex-col max-w-3xl mx-auto px-4">
      <%!-- Fixed top: header + the prompt --%>
      <div class="shrink-0 pt-4 pb-3 space-y-3 bg-base-100 border-b border-base-200">
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
          <button class="btn btn-primary btn-lg" phx-disable-with="…">Send</button>
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
            <span class="text-base-content/50">— answer even when no Tragar fact is found (ungrounded)</span>
          </span>
        </label>
      </div>

      <%!-- Scrollable conversation, newest first --%>
      <div id="conversation" class="flex-1 overflow-y-auto py-4 space-y-4">
        <p :if={@turns == []} class="text-sm text-base-content/50 py-8 text-center">
          Ask something — e.g. <em>“Where is waybill 0006794936FC?”</em> or
          <em>“What service types do you offer?”</em>
        </p>

        <div :for={turn <- Enum.reverse(@turns)} class="space-y-1">
          <div class="chat chat-end">
            <div class="chat-bubble chat-bubble-primary whitespace-pre-line">{turn.prompt}</div>
          </div>

          <div class="chat chat-start">
            <div class="chat-bubble whitespace-pre-line">{turn.i.draft_answer}</div>
            <div class="chat-footer mt-1 flex flex-wrap items-center gap-1 text-[11px] opacity-70">
              <span :if={turn.i.intent} class="badge badge-xs badge-outline">{turn.i.intent}</span>
              <span :if={turn.i.source} class="badge badge-xs badge-ghost">{turn.i.source}</span>
              <span class={"badge badge-xs " <> status_class(turn.i.status)}>{turn.i.status}</span>
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

  defp status_class(:drafted), do: "badge-success"
  defp status_class(:relayed), do: "badge-success"
  defp status_class(:reasoned), do: "badge-info"
  defp status_class(_), do: "badge-warning"

  defp present?(m) when is_map(m), do: map_size(m) > 0
  defp present?(_), do: false

  defp pretty(map), do: Jason.encode!(map, pretty: true)
end
