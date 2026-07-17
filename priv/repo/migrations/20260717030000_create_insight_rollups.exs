defmodule TragarAi.Repo.Migrations.CreateInsightRollups do
  use Ecto.Migration

  # Warehouse of monthly margin rollups for the intelligence platform — one row per
  # (month × grain × dimension key), e.g. margin for client "ITD02" in 2024-03.
  # Populated by the backfill/observation ETL from the FreightWare replica; read by
  # the dashboards, the Nx analytics, and the RAG insights.
  #
  # Time axis is waybill_date (invoice_date is dirty), truncated to the month.
  def change do
    create table(:insight_rollups) do
      # grain: client | route | lane | contractor | service | enterprise
      add :period_month, :date, null: false
      add :grain, :string, null: false
      add :dim_key, :string, null: false
      add :dim_label, :string
      add :waybills, :integer, null: false, default: 0
      add :sell, :decimal, null: false, default: 0
      add :buy, :decimal, null: false, default: 0
      add :surcharges, :decimal, null: false, default: 0
      add :margin, :decimal, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    # One rollup per month/grain/dimension — upserts key on this.
    create unique_index(:insight_rollups, [:period_month, :grain, :dim_key])
    # Dashboards read "all of one grain over time".
    create index(:insight_rollups, [:grain, :period_month])
  end
end
