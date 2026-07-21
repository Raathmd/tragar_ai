defmodule TragarAi.Insight.Rollup do
  @moduledoc """
  A monthly margin rollup — one row per `(period_month × grain × dim_key)`.

  This is the warehouse the management dashboards, the Nx analytics, and the RAG
  insights all read. Populated by the ETL from the FreightWare replica; the time
  axis is `waybill_date` truncated to the month (invoice_date is dirty, so it is
  never used as the time key). `sell − (buy + surcharges) = margin`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @grains ~w(client route lane contractor service enterprise)

  @type t :: %__MODULE__{}

  schema "insight_rollups" do
    field :period_month, :date
    field :grain, :string
    field :dim_key, :string
    field :dim_label, :string
    field :waybills, :integer
    field :sell, :decimal
    field :buy, :decimal
    # buy expected: what each waybill's assigned supplier should have charged per
    # its rate card. Populated separately (Backfill.run_expected/0), partial
    # coverage (own-fleet legs have no card), so not folded into margin.
    field :expected_buy, :decimal
    # how many of `waybills` got an expected cost. `waybills - priced_waybills` =
    # the uncosted count (assigned supplier has no origin-area rate). Set with
    # expected_buy by run_expected/0.
    field :priced_waybills, :integer
    field :surcharges, :decimal
    field :margin, :decimal

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The valid grains a rollup can be keyed by."
  def grains, do: @grains

  def changeset(rollup, attrs) do
    rollup
    |> cast(attrs, [
      :period_month,
      :grain,
      :dim_key,
      :dim_label,
      :waybills,
      :sell,
      :buy,
      :expected_buy,
      :priced_waybills,
      :surcharges,
      :margin
    ])
    |> validate_required([:period_month, :grain, :dim_key])
    |> validate_inclusion(:grain, @grains)
    |> unique_constraint([:period_month, :grain, :dim_key])
  end
end
