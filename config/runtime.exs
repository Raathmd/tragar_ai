import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/tragar_ai start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :tragar_ai, TragarAiWeb.Endpoint, server: true
end

config :tragar_ai, TragarAiWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# ---------------------------------------------------------------------------
# External integrations (loaded for dev and releases; the test env supplies its
# own values in config/test.exs, so we skip this block there to avoid clobbering
# them with unset env vars).
#
# Tragar's "Dovetail" system is the FreightWare REST API hosted on the
# dovetail.co.za servers. Auth is a POST to /system/auth/login returning a
# token in the `X-FreightWare` response header, which is then sent on every
# subsequent request. See TragarAi.Dovetail.Client.
# ---------------------------------------------------------------------------
if config_env() != :test do
  dovetail_env = System.get_env("DOVETAIL_ENV", "uat")

  # FreightWare (source 1) — read-only live facts: load/consignment status, ETA,
  # waybill lookup. Hosted on Tragar's Dovetail servers.
  config :tragar_ai, TragarAi.Dovetail.Client,
    env: dovetail_env,
    base_url:
      System.get_env("DOVETAIL_BASE_URL") ||
        if(dovetail_env == "prod",
          do: "https://tragar-db.dovetail.co.za/WebServices/web",
          else: "https://tragar-db.dovetail.co.za/WebServicesUAT/web"
        ),
    username: System.get_env("DOVETAIL_USERNAME"),
    password: System.get_env("DOVETAIL_PASSWORD"),
    station: System.get_env("DOVETAIL_STATION"),
    pod_image_base:
      System.get_env("DOVETAIL_POD_IMAGE_BASE") ||
        "https://tragar-db.dovetail.co.za/FWO_UAT/views/viewImage.html"

  # Freshdesk (source 6) — read-only ticket context + the customer a question is
  # about. Auth is HTTP Basic with the API key as the username.
  config :tragar_ai, TragarAi.Freshdesk.Client,
    domain: System.get_env("FRESHDESK_DOMAIN"),
    api_key: System.get_env("FRESHDESK_API_KEY")

  # Core AI (the local model sidecar). Default stays :stub; set CORE_AI_MODE=http
  # and CORE_AI_URL to use a running local model.
  config :tragar_ai, TragarAi.CoreAI,
    mode: String.to_atom(System.get_env("CORE_AI_MODE") || "stub"),
    model: System.get_env("CORE_AI_MODEL"),
    base_url: System.get_env("CORE_AI_URL") || "http://127.0.0.1:11434"

  # Inbound API auth — the bearer token Freddy (Freshdesk AI Agent) must send to
  # call /api/* . We mint this; the admin stores it in Freshdesk's Action
  # Authentication. When unset, /api is open (local dev only); prod must set it.
  config :tragar_ai, :api_key, System.get_env("TRAGAR_API_KEY")

  # IP allowlist for /api — restrict to Freshworks' egress CIDRs. Unset → allow
  # all (local dev). Set TRAGAR_API_TRUST_XFF=1 when behind a proxy/LB so the
  # client IP is read from X-Forwarded-For.
  config :tragar_ai,
         :api_allowed_ips,
         (System.get_env("TRAGAR_API_ALLOWED_IPS") || "")
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)

  config :tragar_ai,
         :api_trust_forwarded,
         System.get_env("TRAGAR_API_TRUST_XFF") in ~w(1 true yes)

  # The Freshdesk Company custom-field key that holds the customer's FreightWare
  # account code(s). The quote-intake gate derives the account from this — a
  # requester whose company has no code is refused.
  if field = System.get_env("FRESHDESK_ACCOUNT_FIELD") do
    config :tragar_ai, :freshdesk_account_field, field
  end
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :tragar_ai, TragarAi.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :tragar_ai, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :tragar_ai, TragarAiWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :tragar_ai, TragarAiWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :tragar_ai, TragarAiWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :tragar_ai, TragarAi.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
