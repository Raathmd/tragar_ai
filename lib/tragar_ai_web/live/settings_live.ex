defmodule TragarAiWeb.SettingsLive do
  @moduledoc """
  Runtime settings for the assist engine. Currently the search strategy toggle
  (`sequential` vs `fanout`). Changes apply immediately via application env and
  reset to the configured default on restart.
  """
  use TragarAiWeb, :live_view

  alias TragarAi.Assist.SearchStrategy

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, strategy: SearchStrategy.get())}
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
  def render(assigns) do
    ~H"""
    <div class="p-4 lg:p-6 space-y-4">
      <Layouts.app_nav active={:settings} />

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
    </div>
    """
  end
end
