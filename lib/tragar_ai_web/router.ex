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
  end

  # AI-facing gateway: API-key authenticated JSON.
  pipeline :gateway do
    plug :accepts, ["json"]
    plug TragarAiWeb.Plugs.ApiKeyAuth
  end

  scope "/", TragarAiWeb do
    pipe_through :browser

    get "/", PageController, :home

    # Customer-facing magic link that activates and reveals an API key.
    get "/activate/:token", ActivationController, :show
  end

  # OpenAPI document — unauthenticated so tooling (and Freddy's importer) can
  # fetch the schema before a key is configured.
  scope "/api", TragarAiWeb do
    pipe_through :api

    get "/openapi.json", OpenAPIController, :spec
  end

  # REST tool gateway (for Freddy custom actions and OpenAPI-consuming agents).
  scope "/api/v1", TragarAiWeb do
    pipe_through :gateway

    get "/tools", ToolController, :index
    post "/tools/:name", ToolController, :invoke

    # Partner (Freddy) requests access for a customer; emails a magic link.
    post "/access-requests", RegistrationController, :create
  end

  # MCP gateway (for MCP-capable agents — Claude, etc.).
  scope "/", TragarAiWeb do
    pipe_through :gateway

    post "/mcp", MCPController, :rpc
  end

  # Ash-generated admin UI for browsing the cached/audit resources.
  # Behind dev_routes for now — put it behind real auth before production use.
  if Application.compile_env(:tragar_ai, :dev_routes) do
    scope "/admin" do
      pipe_through :browser
      ash_admin("/")
    end
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:tragar_ai, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TragarAiWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
