defmodule TragarAi.Insight.SupplierRouteCost do
  @moduledoc """
  A monthly supplier-cost-per-lane rollup — one row per
  `(period_month × rate_area_from → rate_area_to × supplier)`.

  The historical-benchmark half of the cheapest-supplier feature: what each
  supplier has actually billed to carry a lane, consolidation-attributed (a
  consolidated trip's cost is spread across its member waybills by chargeable-
  weight share, so free-riding members aren't treated as free). Populated by
  `TragarAi.Insight.SupplierCostBackfill` from the FreightWare replica.

  Read side computes `avg_cost_per_kg = Σtotal_cost / Σtotal_chargeable_kg` over
  the recent window, ranked ascending.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "supplier_route_costs" do
    field :period_month, :date
    field :rate_area_from, :string
    field :rate_area_to, :string
    field :station_contractor_obj, :string
    field :contractor_label, :string
    field :waybills, :integer
    field :total_cost, :decimal
    field :total_chargeable_kg, :decimal
    field :min_cost, :decimal
    field :last_charged_date, :date

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(period_month rate_area_from rate_area_to station_contractor_obj
             contractor_label waybills total_cost total_chargeable_kg min_cost
             last_charged_date)a

  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required([
      :period_month,
      :rate_area_from,
      :rate_area_to,
      :station_contractor_obj
    ])
    |> unique_constraint(
      [:period_month, :rate_area_from, :rate_area_to, :station_contractor_obj],
      name: :supplier_route_costs_cell_index
    )
  end
end
