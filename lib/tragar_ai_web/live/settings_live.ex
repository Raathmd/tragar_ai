defmodule TragarAiWeb.SettingsLive do
  @moduledoc """
  Runtime settings for the assist engine. Currently the search strategy toggle
  (`sequential` vs `fanout`). Changes apply immediately via application env and
  reset to the configured default on restart.
  """
  use TragarAiWeb, :live_view

  alias TragarAi.Assist.SearchStrategy
  alias TragarAi.CoreAI.ModelSetting

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       strategy: SearchStrategy.get(),
       model: ModelSetting.get(),
       reasoning: ModelSetting.reasoning_enabled?()
     )}
  end

  @impl true
  def handle_event("set_strategy", %{"strategy" => strategy}, socket) do
    case SearchStrategy.set(String.to_existing_atom(strategy)) do
      {:ok, active} ->
        {:noreply,
         socket
         |> assign(strategy: active)
         |> put_flash(:info, "Search pipeline set to #{SearchStrategy.label(active)}.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Unknown strategy.")}
    end
  end

  @impl true
  def handle_event("set_model", %{"model" => model}, socket) do
    case ModelSetting.set(model) do
      {:ok, active} ->
        {:noreply,
         socket
         |> assign(model: active)
         |> put_flash(
           :info,
           "Model set to #{ModelSetting.label(active)}. Loading it and unloading the other…"
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Unknown model.")}
    end
  end

  @impl true
  def handle_event("toggle_reasoning", _params, socket) do
    {:ok, on} = ModelSetting.set_reasoning_enabled(not socket.assigns.reasoning)

    {:noreply,
     socket
     |> assign(reasoning: on)
     |> put_flash(:info, "Reasoning mode #{if on, do: "on", else: "off"}.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 lg:p-6 space-y-4">
      <Layouts.app_nav active={:settings} flash={@flash} current_user={@current_user} />

      <header>
        <h1 class="text-2xl font-semibold">Settings</h1>
        <p class="text-sm text-base-content/70">Runtime configuration for the assist engine.</p>
      </header>

      <section class="rounded-lg border border-base-300 p-4 space-y-3 max-w-2xl">
        <div>
          <h2 class="text-sm font-medium">Search pipeline</h2>
          <p class="text-xs text-base-content/60">
            How a reference (waybill / quote / shipper reference) is resolved across the source
            systems. Applies immediately; resets to the configured default on restart.
          </p>
        </div>

        <div class="grid gap-2 sm:grid-cols-2">
          <button
            :for={s <- SearchStrategy.all()}
            type="button"
            phx-click="set_strategy"
            phx-value-strategy={s}
            class={[
              "text-left rounded-md border p-3 space-y-1 transition",
              (@strategy == s && "border-primary bg-primary/5") ||
                "border-base-300 hover:border-primary/50"
            ]}
          >
            <div class="flex items-center gap-2">
              <span class="text-sm font-medium">{SearchStrategy.label(s)}</span>
              <span :if={@strategy == s} class="badge badge-xs badge-primary">Active</span>
            </div>
            <p class="text-xs text-base-content/60">{SearchStrategy.describe(s)}</p>
          </button>
        </div>
      </section>

      <section class="rounded-lg border border-base-300 p-4 space-y-3 max-w-2xl">
        <div>
          <h2 class="text-sm font-medium">Inference model</h2>
          <p class="text-xs text-base-content/60">
            Which model answers interpret/phrase. <span class="font-medium">Claude (cloud)</span>
            runs on Anthropic's API (private values redacted to tokens first) and falls back to a
            local model, then the stub, if the API is down. A local model keeps everything on the
            box. Switching a local model loads it and unloads the other so only one stays resident.
            Applies immediately; resets to the configured default on restart.
          </p>
        </div>

        <div class="grid gap-2 sm:grid-cols-2">
          <button
            :for={m <- ModelSetting.all()}
            type="button"
            phx-click="set_model"
            phx-value-model={m.tag}
            class={[
              "text-left rounded-md border p-3 space-y-1 transition",
              (@model == m.tag && "border-primary bg-primary/5") ||
                "border-base-300 hover:border-primary/50"
            ]}
          >
            <div class="flex items-center gap-2">
              <span class="text-sm font-medium">{m.label}</span>
              <span :if={@model == m.tag} class="badge badge-xs badge-primary">Active</span>
              <span :if={m.reasoning} class="badge badge-xs badge-ghost">reasoning</span>
            </div>
            <p class="text-xs text-base-content/60">{m.describe}</p>
          </button>
        </div>

        <div class="border-t border-base-300 pt-3">
          <label class="flex items-start gap-3 cursor-pointer">
            <input
              type="checkbox"
              class="toggle toggle-primary toggle-sm mt-0.5"
              checked={@reasoning}
              phx-click="toggle_reasoning"
              disabled={not ModelSetting.reasoning_capable?(@model)}
            />
            <span>
              <span class="text-sm font-medium">Reasoning (thinking) mode</span>
              <p class="text-xs text-base-content/60">
                <%= if ModelSetting.reasoning_capable?(@model) do %>
                  When on, {ModelSetting.label(@model)} reasons before answering (slower, deeper).
                <% else %>
                  {ModelSetting.label(@model)} has no reasoning mode — select a Qwen3 model to enable.
                <% end %>
              </p>
            </span>
          </label>
        </div>
      </section>
    </div>
    """
  end
end
