defmodule TragarAi.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TragarAiWeb.Telemetry,
      TragarAi.Repo,
      {DNSCluster, query: Application.get_env(:tragar_ai, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: TragarAi.PubSub},
      {Oban, Application.fetch_env!(:tragar_ai, Oban)},
      # Caches the Dovetail/FreightWare auth token and refreshes it on expiry.
      TragarAi.Dovetail.TokenStore,
      # Caches the Vantage auth token.
      TragarAi.Vantage.TokenStore,
      # TTL cache over the heavy FreightWare collections fetch (shared by all
      # staff dashboards + the poll, so the ~15s all-rows pull runs once per TTL).
      TragarAi.Freight.CollectionsCache,
      # Runs the ticket auto-answer work off the request path so the webhook can
      # return immediately (Freshdesk's webhook timeout is short).
      {Task.Supervisor, name: TragarAi.TaskSupervisor},
      # Start to serve requests, typically the last entry
      TragarAiWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TragarAi.Supervisor]

    with {:ok, _pid} = ok <- Supervisor.start_link(children, opts) do
      warm_accounts_cache()
      ok
    end
  end

  # Enqueue an immediate background refresh of the FreightWare account directory
  # so a cold cache (right after a deploy) is warmed before the first hourly cron
  # tick — and before the first ticket click would otherwise have to pay for it.
  defp warm_accounts_cache do
    TragarAi.Freight.AccountsRefreshWorker.new(%{}) |> Oban.insert()
    :ok
  rescue
    # Never let a warm-up enqueue failure stop the app from booting.
    error ->
      require Logger
      Logger.warning("[accounts] boot warm-up enqueue failed: #{inspect(error)}")
      :ok
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TragarAiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
