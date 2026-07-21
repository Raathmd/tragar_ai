defmodule TragarAi.Repo.Migrations.CreateInsightEtlState do
  use Ecto.Migration

  # Tiny key → timestamp store for the margin ETL's durable markers. First user:
  # `status_high_water` — the point up to which WaybillCostBackfill has accounted
  # for fwt_status_history change-events, so each scheduled :window tick only pulls
  # waybill status-events created since. Room for more markers later (e.g. last
  # full-rebuild time) without a schema change.
  def change do
    create table(:insight_etl_state) do
      add :key, :string, null: false
      add :at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:insight_etl_state, [:key])
  end
end
