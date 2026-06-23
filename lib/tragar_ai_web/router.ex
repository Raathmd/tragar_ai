defmodule TragarAiWeb.Router do
  use TragarAiWeb, :router

  import AshAdmin.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TragarAiWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug TragarAiWeb.Plugs.ApiAuth
  end

  scope "/", TragarAiWeb do
    pipe_through :browser

    get "/", PageController, :home

    # Phase 1 — the support-assist agent console.
    live "/console", ConsoleLive
  end

  # Freshdesk-facing API: guided quote intake from a ticket.
  scope "/api", TragarAiWeb do
    pipe_through :api

    get "/quotes/workflow", QuoteIntakeController, :workflow
    post "/quotes/intake", QuoteIntakeController, :intake

    # MCP server (JSON-RPC) exposing the quote workflow as tools for Freddy.
    post "/mcp", McpController, :rpc
  end

  # Ash admin UI for browsing interactions (dev only until real auth is added).
  if Application.compile_env(:tragar_ai, :dev_routes) do
    scope "/admin" do
      pipe_through :browser
      ash_admin("/")
    end
  end

  # LiveDashboard and mailbox preview in development.
  if Application.compile_env(:tragar_ai, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TragarAiWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
