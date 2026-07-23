defmodule TragarAi.Insight.ManifestOriginWorker do
  @moduledoc """
  Background job that materialises delivery-manifest origins into
  `insight_manifest_origin` via `ManifestOriginBackfill`. The parcel->tripsheet scan
  is far too slow to run on a Fill-form click, so it runs here, off-line and once,
  and the quote form then reads the result from Postgres instantly.
  """
  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 600]

  require Logger

  alias TragarAi.Insight.ManifestOriginBackfill

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case ManifestOriginBackfill.refresh() do
      {:ok, stats} ->
        Logger.info("[insight.manifest_origin] refresh ok: #{inspect(stats)}")
        :ok

      {:error, reason} = err ->
        Logger.error("[insight.manifest_origin] refresh failed: #{inspect(reason)}")
        err
    end
  end
end
