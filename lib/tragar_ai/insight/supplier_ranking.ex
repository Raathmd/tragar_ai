defmodule TragarAi.Insight.SupplierRanking do
  @moduledoc """
  Rank candidate suppliers on a lane by what they have ACTUALLY billed — the
  historical-actuals column of the ops board — read from the
  `supplier_route_costs` warehouse (see `TragarAi.Insight.SupplierRouteCost`).

  This is the deployable first column. The live rate-engine columns (rate-only
  and rate+surcharge) and the auto open-manifest list layer on top of it once
  the manifest status/type probes are confirmed.
  """
  import Ecto.Query

  alias TragarAi.Insight.SupplierRouteCost
  alias TragarAi.Repo

  @doc "Distinct origin rate areas present in the warehouse (for the lane picker)."
  def from_areas do
    Repo.all(
      from r in SupplierRouteCost,
        distinct: true,
        select: r.rate_area_from,
        order_by: r.rate_area_from
    )
  end

  @doc "Distinct destination rate areas present in the warehouse."
  def to_areas do
    Repo.all(
      from r in SupplierRouteCost,
        distinct: true,
        select: r.rate_area_to,
        order_by: r.rate_area_to
    )
  end

  @doc """
  Suppliers who have carried `from → to`, cheapest first by cost-per-kg over the
  last `months` (default 12). Each row: `:supplier`, `:obj`, `:waybills`,
  `:cost_per_kg`, `:min_cost`, `:last_charged_date`. Suppliers with no chargeable
  weight (can't derive per-kg) sort last.
  """
  def rank(from, to, opts \\ []) when is_binary(from) and is_binary(to) do
    months = Keyword.get(opts, :months, 12)
    since = Date.utc_today() |> Date.beginning_of_month() |> Date.add(-months * 31)

    from(r in SupplierRouteCost,
      where:
        r.rate_area_from == ^from and r.rate_area_to == ^to and
          r.period_month >= ^since,
      group_by: [r.station_contractor_obj, r.contractor_label],
      select: %{
        obj: r.station_contractor_obj,
        supplier: r.contractor_label,
        waybills: sum(r.waybills),
        total_cost: sum(r.total_cost),
        total_kg: sum(r.total_chargeable_kg),
        min_cost: min(r.min_cost),
        last_charged_date: max(r.last_charged_date)
      }
    )
    |> Repo.all()
    |> Enum.map(&with_cost_per_kg/1)
    |> Enum.sort_by(fn r -> {is_nil(r.cost_per_kg), r.cost_per_kg || 0.0} end)
  end

  defp with_cost_per_kg(row) do
    kg = to_float(row.total_kg)
    cost = to_float(row.total_cost)
    cpk = if (kg && kg > 0.0) and cost, do: cost / kg, else: nil
    Map.put(row, :cost_per_kg, cpk)
  end

  defp to_float(nil), do: nil
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n * 1.0
end
