defmodule TragarAi.Repo.Migrations.AddPricedBuyToInsightRollups do
  use Ecto.Migration

  # Actual buy summed over ONLY the rate-carded (priced) waybills — the like-for-like
  # partner to expected_buy. `buy` sums actual across ALL legs (incl. own-fleet and
  # uncosted), so buy vs expected_buy is coverage-confounded; priced_buy vs expected_buy
  # isolates pure rate divergence (same waybills on both sides). Populated by the month
  # cascade in WaybillCostBackfill. Existing rows default to 0 until a refresh re-runs.
  def change do
    alter table(:insight_rollups) do
      add :priced_buy, :decimal, null: false, default: 0
    end
  end
end
