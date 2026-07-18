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

    # Staff view of FreightWare collections (unauthorised + outstanding).
    live "/collections", CollectionsLive

    # Sign-in for the margin dashboards (not linked in the menu). Login posts to
    # the controller so it can set the session cookie; gating is in UserAuth.
    live "/login", LoginLive
    post "/login", SessionController, :create
    get "/logout", SessionController, :delete

    # Second factor (TOTP). The password step leaves :pending_user_id; these
    # promote it to a full session once the code (or a backup code) checks out.
    get "/mfa", MfaController, :index
    post "/mfa/setup", MfaController, :confirm_setup
    post "/mfa/verify", MfaController, :verify
    post "/mfa/backup-codes", MfaController, :ack_backup_codes

    live_session :margin_mfa, on_mount: [{TragarAiWeb.UserAuth, :require_pending}] do
      live "/mfa/setup", MfaSetupLive
      live "/mfa/verify", MfaVerifyLive
      live "/mfa/backup-codes", MfaBackupCodesLive
    end

    # First-login / self-service password reset (needs a session, reset pending OK).
    live_session :margin_reset, on_mount: [{TragarAiWeb.UserAuth, :require_reset}] do
      live "/reset-password", ResetPasswordLive
    end

    # The margin dashboard — requires a signed-in, reset-complete user.
    live_session :margin_authenticated,
      on_mount: [{TragarAiWeb.UserAuth, :require_authenticated}] do
      live "/margin", MarginLive
    end

    # Admin-only: manage who can access the margin data.
    live_session :margin_admin, on_mount: [{TragarAiWeb.UserAuth, :require_admin}] do
      live "/margin/users", MarginUsersLive
    end

    # Read-only tour of the application's design (systems, surfaces, flows).
    live "/architecture", ArchitectureLive

    # Runtime settings (search pipeline toggle, …).
    live "/settings", SettingsLive

    # Hidden, read-only DB inspection console — intentionally NOT linked in the
    # app menu. Gated by :inspect_token (reach it at /_inspect?token=…). Streams
    # SELECT results in-app so raw data stays inside Tragar's infrastructure.
    live "/_inspect", InspectLive

    # Force a FreightWare login (nav "Log in" button when there's no token).
    post "/fw/login", FreightWareController, :login
  end

  # Freshdesk-facing API: guided quote intake from a ticket.
  scope "/api", TragarAiWeb do
    pipe_through :api

    get "/quotes/workflow", QuoteIntakeController, :workflow
    post "/quotes/intake", QuoteIntakeController, :intake

    # Freshdesk automation → answer a ticket: interpret → tools fetch facts →
    # compose an answer → post it back (private note) for the agent.
    post "/tickets/answer", TicketAnswerController, :answer

    # The sidebar app lists a ticket's attachments (for the picker) before firing
    # /answer with the chosen ones.
    get "/tickets/:id/attachments", TicketAnswerController, :attachments

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
