defmodule TragarAi.Freight.AccountsRefreshWorker do
  @moduledoc """
  Refreshes the cached FreightWare account directory (`TragarAi.Freight.Accounts`)
  in the background, so no user-facing request — a ticket click, a console/chat
  account lookup — ever triggers the `system/baseData/accounts` load or blocks on
  a slow/unavailable FreightWare.

  Runs hourly via `Oban.Plugins.Cron` (see `config/config.exs`) and is enqueued
  once at application start (`TragarAi.Application`) to warm a cold cache right
  after a deploy, before the first hourly tick.
  """
  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 120]

  require Logger

  alias TragarAi.Freight.Accounts

  @impl Oban.Worker
  def perform(_job) do
    case Accounts.refresh() do
      {:ok, dir} ->
        Logger.info("[accounts] directory refreshed: #{map_size(dir)} accounts")
        :ok

      {:error, reason} = err ->
        # Leave the previously cached directory in place and let Oban retry /
        # the next hourly tick try again — never crash-loop on a FreightWare blip.
        Logger.warning("[accounts] scheduled refresh failed: #{inspect(reason)}")
        err
    end
  end
end
