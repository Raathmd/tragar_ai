defmodule TragarAi.Repo.Migrations.AddOwnFleetWaybillsToInsightRollups do
  use Ecto.Migration

  # How many of a rollup's waybills rode Tragar's OWN fleet (no fwt_contractor_charge,
  # no 3rd-party supplier, no rate card). Populated by the month re-aggregation
  # cascade (WaybillCostBackfill.roll_month/2) from the per-waybill fact table.
  #
  # It's the missing term in the "No rate" / uncosted count: own-fleet waybills have
  # no supplier to rate, so they must NOT be counted as unrated 3rd-party. With it,
  # uncosted = waybills - priced_waybills - own_fleet_waybills (own_fleet and priced
  # are disjoint — RateEngine prices via an INNER join to the charge, so an own-fleet
  # waybill is never priced). Existing rows default to 0 until the cascade runs.
  def change do
    alter table(:insight_rollups) do
      add :own_fleet_waybills, :integer, null: false, default: 0
    end
  end
end
