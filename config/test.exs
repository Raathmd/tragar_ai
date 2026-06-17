import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :tragar_ai, TragarAi.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "tragar_ai_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :tragar_ai, TragarAiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "C+b+6V/KaSScPpaZz2FZOWmeMbXW9sHT198xARdjneLVTM2hlf7nSiExg5Wpfkpz",
  server: false

# In test we don't send emails
config :tragar_ai, TragarAi.Mailer, adapter: Swoosh.Adapters.Test

# Run Oban inline + no plugins/queues during tests.
config :tragar_ai, Oban, testing: :manual

# A known partner API key so partner-scope auth can be exercised in tests.
config :tragar_ai, TragarAi.Gateway, partner_api_keys: ["test-partner-key"]

# Deterministic base URL for magic-link activation emails in tests.
config :tragar_ai, TragarAi.Accounts,
  base_url: "http://localhost:4002",
  from_email: "no-reply@tragar.test"

# Stub the external API clients. `req_options` routes every Req call through
# Req.Test, where individual tests register expectations via stubs.
config :tragar_ai, TragarAi.Dovetail.Client,
  env: "uat",
  base_url: "https://dovetail.test/WebServicesUAT/web",
  username: "test-user",
  password: "test-pass",
  station: "TEST",
  pod_image_base: "https://dovetail.test/view",
  req_options: [plug: {Req.Test, TragarAi.Dovetail.Client}]

config :tragar_ai, TragarAi.Freshdesk.Client,
  domain: "tragar",
  api_key: "test-key",
  webhook_secret: "test-secret",
  req_options: [plug: {Req.Test, TragarAi.Freshdesk.Client}]

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
