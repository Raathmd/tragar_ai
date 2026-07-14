defmodule TragarAiWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use TragarAiWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  The single shared, fixed (sticky) top menu across every internal LiveView.
  Rendered as the first element of each page, it pins to the top on scroll and
  uses verified routes so moving between pages is live navigation, not a full
  reload. Add a page here once and every LiveView that drops in `app_nav` picks
  it up.

  The Admin link (AshAdmin) only appears when `:dev_routes` is enabled — the same
  gate the `/admin` route itself uses in the router — so it never dangles to a
  404 (or exposes admin) in production.

  ## Examples

      <Layouts.app_nav active={:console} />
      <Layouts.app_nav active={:architecture} />
  """
  attr :active, :atom,
    default: nil,
    doc: "current page — :dashboard | :console | :architecture | :settings"

  def app_nav(assigns) do
    ~H"""
    <nav class="sticky top-0 z-40 flex items-center gap-1 rounded-lg border border-base-300 bg-base-100/95 px-2 py-1.5 shadow-sm backdrop-blur">
      <span class="select-none px-2 text-sm font-semibold tracking-tight text-base-content/80">
        Tragar<span class="text-primary">·</span>AI
      </span>
      <span class="mx-1 h-5 w-px bg-base-300"></span>
      <.link
        navigate={~p"/"}
        class={["btn btn-sm", (@active == :dashboard && "btn-primary") || "btn-ghost"]}
      >
        Dashboard
      </.link>
      <.link
        navigate={~p"/console"}
        class={["btn btn-sm", (@active == :console && "btn-primary") || "btn-ghost"]}
      >
        Console
      </.link>
      <.link
        navigate={~p"/collections"}
        class={["btn btn-sm", (@active == :collections && "btn-primary") || "btn-ghost"]}
      >
        Collections
      </.link>
      <.link
        navigate={~p"/architecture"}
        class={["btn btn-sm", (@active == :architecture && "btn-primary") || "btn-ghost"]}
      >
        Architecture
      </.link>
      <.link
        navigate={~p"/settings"}
        class={["btn btn-sm", (@active == :settings && "btn-primary") || "btn-ghost"]}
      >
        Settings
      </.link>

      <div class="ml-auto flex items-center gap-1">
        <.theme_toggle />
        <.link :if={dev_routes?()} href="/admin" class="btn btn-sm btn-ghost">
          Admin <span aria-hidden="true">↗</span>
        </.link>
      </div>
    </nav>
    """
  end

  # Admin (AshAdmin) is mounted only under `:dev_routes`; mirror that gate so the
  # menu link tracks the actual route rather than dangling in production.
  @dev_routes Application.compile_env(:tragar_ai, :dev_routes, false)
  defp dev_routes?, do: @dev_routes

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <a href="/" class="flex-1 flex w-fit items-center gap-2">
          <img src={~p"/images/logo.svg"} width="36" />
          <span class="text-sm font-semibold">v{Application.spec(:phoenix, :vsn)}</span>
        </a>
      </div>
      <div class="flex-none">
        <ul class="flex flex-column px-1 space-x-4 items-center">
          <li>
            <a href="https://phoenixframework.org/" class="btn btn-ghost">Website</a>
          </li>
          <li>
            <a href="https://github.com/phoenixframework/phoenix" class="btn btn-ghost">GitHub</a>
          </li>
          <li>
            <.theme_toggle />
          </li>
          <li>
            <a href="https://hexdocs.pm/phoenix/overview.html" class="btn btn-primary">
              Get Started <span aria-hidden="true">&rarr;</span>
            </a>
          </li>
        </ul>
      </div>
    </header>

    <main class="px-4 py-20 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
