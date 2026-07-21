defmodule TragarAi.Repo.Migrations.CreateInsightWaybillCosts do
  use Ecto.Migration

  # Per-waybill costed fact table — the leaf of the margin warehouse. One row per
  # waybill (full history 2016..2026), holding everything the day/waybill/detail
  # drills need so they stop re-querying the FreightWare replica on every click
  # (today only the MONTH grain is materialised in insight_rollups; day and below
  # are live). Populated by TragarAi.Insight.WaybillCostBackfill via the scheduled
  # WarehouseRefreshWorker — aggregates + per-waybill rows stay on-box.
  #
  # `own_fleet` is the key new signal: a waybill with NO fwt_contractor_charge row
  # rode Tragar's own fleet (no 3rd-party supplier, no rate card). It lets the
  # "No rate" / uncosted count exclude own-fleet waybills instead of miscounting
  # them as unrated — the correctness fix #156 could not make.
  def change do
    create table(:insight_waybill_costs) do
      add :waybill_obj, :string, null: false
      add :waybill_number, :string
      add :waybill_date, :date, null: false

      # Denormalised drill dimensions (all off fwt_waybill), so day/waybill drills
      # filter this table by client / lane without touching the replica.
      add :account_name, :string
      add :rate_area_from_code, :string
      add :rate_area_to_code, :string
      # Assigned / delivery supplier (contractor grain). NULL for own-fleet.
      add :contractor_reference, :string

      add :sell, :decimal, null: false, default: 0
      # Booked contractor charge (buy actual). 0 for own-fleet.
      add :buy, :decimal, null: false, default: 0
      # RateEngine expected buy (assigned supplier's rate card). NULL when the
      # supplier has no origin-area rate — the "uncosted" case, never dropped.
      add :expected, :decimal
      # Did this waybill resolve an origin-area rate (got an expected cost)?
      add :priced, :boolean, null: false, default: false
      # No fwt_contractor_charge → own fleet, no card. Excluded from "No rate".
      add :own_fleet, :boolean, null: false, default: false

      add :margin, :decimal, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    # One row per waybill — the upsert key.
    create unique_index(:insight_waybill_costs, [:waybill_obj])

    # Day-grain drill: "waybills on this date" (enterprise) — and the source the
    # day rollup aggregates from.
    create index(:insight_waybill_costs, [:waybill_date])

    # Dimensional day/waybill drills: "this client / lane / supplier on this date".
    create index(:insight_waybill_costs, [:account_name, :waybill_date])
    create index(:insight_waybill_costs, [:rate_area_to_code, :waybill_date])
    create index(:insight_waybill_costs, [:contractor_reference, :waybill_date])
  end
end
