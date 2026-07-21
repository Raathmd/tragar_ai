defmodule TragarAi.Repo.Migrations.AddPricedWaybillsToInsightRollups do
  use Ecto.Migration

  # How many of a rollup's waybills got an expected cost (their assigned supplier
  # has a current rate covering the origin→destination lane). Populated alongside
  # expected_buy by Backfill.run_expected/0. `waybills - priced_waybills` = the
  # uncosted count the margin drill surfaces (no origin-area rate). Existing rows
  # default to 0 until run_expected re-runs.
  def change do
    alter table(:insight_rollups) do
      add :priced_waybills, :integer, null: false, default: 0
    end
  end
end
