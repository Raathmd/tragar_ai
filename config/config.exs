# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :tragar_ai,
  ecto_repos: [TragarAi.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Ash domains exposed by the application.
config :tragar_ai,
  ash_domains: [
    TragarAi.Accounts,
    TragarAi.Assist,
    TragarAi.Logistics,
    TragarAi.Customers,
    TragarAi.Support,
    TragarAi.Finance,
    TragarAi.Fleet,
    TragarAi.Sources,
    TragarAi.QuoteIntake
  ]

# Ash configuration
config :ash,
  include_embedded_source_by_default?: false,
  policies: [no_filter_static_forbidden_reads?: false]

# Oban — durable job queue (resilience: interrupted jobs re-run on restart).
# Phase 1 (support assist) answers from live facts and has no scheduled jobs
# yet; the knowledge-layer reconcile jobs arrive in Phase 2.
config :tragar_ai, Oban,
  engine: Oban.Engines.Basic,
  repo: TragarAi.Repo,
  queues: [default: 10],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # Refresh the FreightWare account directory hourly in the background, so no
    # user request (ticket click / console lookup) ever triggers the load or
    # blocks on a slow FreightWare — see TragarAi.Freight.AccountsRefreshWorker.
    {Oban.Plugins.Cron, crontab: [{"0 * * * *", TragarAi.Freight.AccountsRefreshWorker}]}
  ]

# Core AI (the local model reached over local HTTP — the "Swift sidecar").
# In :stub mode a deterministic rule/template interpreter+phraser runs in-process
# so the full loop works without the model; switch to :http and point base_url at
# the sidecar to use the real local model.
config :tragar_ai, TragarAi.CoreAI,
  mode: :stub,
  # Optional display name of the model (e.g. "qwen2.5:7b-instruct" or
  # "Apple Foundation Models"); shown in the console. nil => derived label.
  model: nil,
  base_url: "http://127.0.0.1:11434",
  receive_timeout: 30_000

# Configure the endpoint
config :tragar_ai, TragarAiWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TragarAiWeb.ErrorHTML, json: TragarAiWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: TragarAi.PubSub,
  live_view: [signing_salt: "cNeZ6V70"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :tragar_ai, TragarAi.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  tragar_ai: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  tragar_ai: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
