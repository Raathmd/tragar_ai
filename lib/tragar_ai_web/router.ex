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
    plug TragarAiWeb.Plugs.IpAllowlist
    plug TragarAiWeb.Plugs.ApiAuth
  end

  # Unauthenticated health probe (Docker healthcheck + deploy gate).
  scope "/", TragarAiWeb do
    get "/health", HealthController, :index
  end

  scope "/", TragarAiWeb do
    pipe_through :browser

    # Integration monitor — the landing page (internal app).
    live "/", DashboardLive

    # Phase 1 — the support-assist agent console.
    live "/console", ConsoleLive

    # Read-only tour of the application's design (systems, surfaces, flows).
    live "/architecture", ArchitectureLive

    # Plain chat with the local AI.
    live "/chat", ChatLive
  end

  # Freshdesk-facing API: guided quote intake from a ticket.
  scope "/api", TragarAiWeb do
    pipe_through :api

    get "/quotes/workflow", QuoteIntakeController, :workflow
    post "/quotes/intake", QuoteIntakeController, :intake

    # Freshdesk automation → answer a ticket: interpret → tools fetch facts →
    # compose an answer → post it back (private note) for the agent.
    post "/tickets/answer", TicketAnswerController, :answer

    # Freshdesk ticket-sidebar app → interactive assist: one turn, scoped to the
    # requester's entitled accounts, answered synchronously (nothing posted back).
    post "/tickets/chat", TicketChatController, :chat
  end

  # MCP server (JSON-RPC) at the conventional `/mcp` path — same `:api` gates
  # (IP allowlist → bearer → session). This is the URL registered in Freshdesk.
  scope "/", TragarAiWeb do
    pipe_through :api

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
