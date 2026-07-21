defmodule TragarAi.Insight.WaybillCost do
  @moduledoc """
  A per-waybill costed fact — one row per waybill in the margin warehouse.

  The leaf grain the day/waybill/detail drills read so they stop re-querying the
  FreightWare replica (see `TragarAi.Insight.Drill`, which today reads month from
  the warehouse but day and below live). Populated by
  `TragarAi.Insight.WaybillCostBackfill` from the replica; the time axis is
  `waybill_date` (invoice_date is dirty).

    * `sell`     — the customer charge (`fwt_waybill.total_cost`).
    * `buy`      — booked contractor charge (`Σ fwt_contractor_charge`); 0 own-fleet.
    * `expected` — assigned supplier's rate-card cost (`RateEngine`); `nil` when no
                   origin-area rate resolved (the uncosted case — never dropped).
    * `priced`   — did an origin-area rate resolve (got an `expected`)?
    * `own_fleet`— no contractor charge → Tragar's own fleet, no card. Excluded
                   from the "No rate" / uncosted count so it isn't miscounted as
                   an unrated 3rd-party supplier.

  Day rollups are aggregated from these rows on read (GROUP BY `waybill_date`);
  month rollups stay in `insight_rollups`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "insight_waybill_costs" do
    field :waybill_obj, :string
    field :waybill_number, :string
    field :waybill_date, :date

    field :account_name, :string
    field :rate_area_from_code, :string
    field :rate_area_to_code, :string
    field :contractor_reference, :string

    field :sell, :decimal
    field :buy, :decimal
    field :expected, :decimal
    field :priced, :boolean, default: false
    field :own_fleet, :boolean, default: false
    field :margin, :decimal

    timestamps(type: :utc_datetime_usec)
  end

  @cast ~w(waybill_obj waybill_number waybill_date account_name rate_area_from_code
           rate_area_to_code contractor_reference sell buy expected priced own_fleet
           margin)a

  def changeset(cost, attrs) do
    cost
    |> cast(attrs, @cast)
    |> validate_required([:waybill_obj, :waybill_date])
    |> unique_constraint(:waybill_obj)
  end
end
