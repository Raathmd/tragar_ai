defmodule TragarAi.Insight.SupplierCostWorker do
  @moduledoc """
  Rebuilds the `supplier_route_costs` warehouse in the background, **inside the
  app**, via Oban — so the heavy replica aggregation never runs in a user request
  or an operator's session. Enqueue on demand from the `/_inspect` console (or
  programmatically); a `Oban.Plugins.Cron` tick can be added once the run is
  validated and its runtime is known.

  Mirrors `TragarAi.Freight.AccountsRefreshWorker`. `max_attempts: 1` — a heavy
  aggregation shouldn't auto-retry; re-enqueue deliberately.
  """
  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 300]

  require Logger

  alias TragarAi.Insight.SupplierCostBackfill

  @impl Oban.Worker
  def perform(_job) do
    case SupplierCostBackfill.run() do
      {:ok, cells} ->
        Logger.info("[supplier_cost.worker] supplier_route_costs rebuilt: #{cells} cells")
        :ok

      {:error, reason} = err ->
        Logger.error("[supplier_cost.worker] rebuild failed: #{inspect(reason)}")
        err
    end
  end
end
