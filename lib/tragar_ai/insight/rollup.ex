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
    # how many of `waybills` got an expected cost. Set with expected_buy.
    field :priced_waybills, :integer
    # actual buy over ONLY the priced (rate-carded) waybills — the like-for-like
    # partner to expected_buy. `buy` covers ALL legs, so buy vs expected_buy mixes
    # in coverage; priced_buy vs expected_buy is pure rate divergence (same legs).
    field :priced_buy, :decimal
    # how many of `waybills` rode own fleet (no 3rd-party supplier/card). Set by the
    # month cascade. uncosted = waybills - priced_waybills - own_fleet_waybills — the
    # "No rate" count, now excluding own-fleet (which has no supplier to rate).
    field :own_fleet_waybills, :integer
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
      :priced_buy,
      :own_fleet_waybills,
      :surcharges,
      :margin
    ])
    |> validate_required([:period_month, :grain, :dim_key])
    |> validate_inclusion(:grain, @grains)
    |> unique_constraint([:period_month, :grain, :dim_key])
  end
end
