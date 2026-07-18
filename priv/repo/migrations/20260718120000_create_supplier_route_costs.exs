defmodule TragarAi.Repo.Migrations.CreateSupplierRouteCosts do
  use Ecto.Migration

  # Warehouse of historical supplier cost per lane — one row per
  # (month × rate_area_from → rate_area_to × supplier). The "historical benchmark"
  # half of the cheapest-supplier feature: what each supplier has ACTUALLY billed
  # to carry a given lane, consolidation-attributed so consolidated members that
  # ride free still carry their weight-share of the trip cost.
  #
  # Populated by TragarAi.Insight.SupplierCostBackfill from the FreightWare replica
  # (aggregates only leave the DB). Time axis is waybill_date, truncated to month.
  def change do
    create table(:supplier_route_costs) do
      add :period_month, :date, null: false
      add :rate_area_from, :string, null: false
      add :rate_area_to, :string, null: false
      add :station_contractor_obj, :string, null: false
      add :contractor_label, :string
      add :waybills, :integer, null: false, default: 0
      add :total_cost, :decimal, null: false, default: 0
      add :total_chargeable_kg, :decimal, null: false, default: 0
      add :min_cost, :decimal, null: false, default: 0
      add :last_charged_date, :date

      timestamps(type: :utc_datetime_usec)
    end

    # One cell per month/lane/supplier — upserts key on this.
    create unique_index(
             :supplier_route_costs,
             [:period_month, :rate_area_from, :rate_area_to, :station_contractor_obj],
             name: :supplier_route_costs_cell_index
           )

    # The ops/board read: "all suppliers on this lane, recent months".
    create index(:supplier_route_costs, [:rate_area_from, :rate_area_to, :period_month])
  end
end
