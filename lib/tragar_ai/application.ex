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
      # Runs the ticket auto-answer work off the request path so the webhook can
      # return immediately (Freshdesk's webhook timeout is short).
      {Task.Supervisor, name: TragarAi.TaskSupervisor},
      # Start to serve requests, typically the last entry
      TragarAiWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TragarAi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TragarAiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
