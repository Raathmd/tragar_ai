defmodule TragarAi.Insight.WarehouseRefreshWorker do
  @moduledoc """
  Keeps the margin warehouse fresh in the background, **inside the app**, via Oban
  — so the per-waybill costing pass never runs in a user request or an operator's
  session, and the drills stop re-querying the FreightWare replica for history.

  Two modes (job args):

    * `%{"mode" => "window"}` (default) — the SCHEDULED tick. Re-aggregates the
      ROLLING WINDOW (current + previous year) from source every run, so new,
      changed, and cross-period late-posted waybills in that window are absorbed
      (we re-sum from the replica, not diff). Plus any OLDER periods flagged by
      the `fwt_waybill` modified-timestamp high-water — cheap, only touched
      periods re-price. This is the tick a `Oban.Plugins.Cron` entry drives.
    * `%{"mode" => "full"}` — a full historical rebuild (2016..2026). The heavy
      one-time seed after the migration deploys, and a periodic safety rebuild if
      the replica has no usable modified timestamp (see WaybillCostBackfill).

  Mirrors `TragarAi.Insight.SupplierCostWorker`: `max_attempts: 1` (a heavy
  aggregation shouldn't auto-retry — re-enqueue deliberately) and `unique` so an
  overlapping tick coalesces. The Cron entry is deliberately left OFF in
  `config/config.exs` until the run is validated and its runtime is known — same
  as SupplierCostWorker.
  """
  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 600]

  require Logger

  alias TragarAi.Insight.WaybillCostBackfill

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    mode = mode(args)

    case WaybillCostBackfill.refresh(mode) do
      {:ok, stats} ->
        Logger.info("[insight.warehouse] refresh #{inspect(mode)} ok: #{inspect(stats)}")
        :ok

      {:error, reason} = err ->
        Logger.error("[insight.warehouse] refresh #{inspect(mode)} failed: #{inspect(reason)}")
        err
    end
  end

  # Default to the light rolling-window refresh; only a full rebuild when asked.
  defp mode(%{"mode" => "full"}), do: :full
  defp mode(_), do: :window
end
