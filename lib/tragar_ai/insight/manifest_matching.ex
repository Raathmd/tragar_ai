defmodule TragarAi.Insight.ManifestMatching do
  @moduledoc """
  A materialised supplier-matching outcome — one row per assigned manifest.

  The management/history half of the cheapest-supplier feature: the chosen
  supplier vs the reconstructed cheapest-at-the-time (effective-dated rates),
  classified `preferred`/`override` with the cost delta (savings forgone). A past
  manifest's outcome is immutable, so rows are computed once and appended.

  Schema only in PR-1; the reconstruction ETL
  (`TragarAi.Insight.ManifestMatchingBackfill`) lands in PR-2 once the manifest
  status/type checks are confirmed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @outcomes ~w(preferred override)

  schema "manifest_matching" do
    field :manifest_obj, :string
    field :manifest_reference, :string
    field :manifest_date, :date
    field :period_month, :date
    field :rate_area_from, :string
    field :rate_area_to, :string

    field :chosen_contractor_obj, :string
    field :chosen_contractor_label, :string
    field :chosen_cost, :decimal
    field :cheapest_contractor_obj, :string
    field :cheapest_contractor_label, :string
    field :cheapest_cost, :decimal
    field :rank_of_chosen, :integer
    field :outcome, :string
    field :cost_delta, :decimal
    field :ops_user, :string

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(manifest_obj manifest_reference manifest_date period_month
             rate_area_from rate_area_to chosen_contractor_obj
             chosen_contractor_label chosen_cost cheapest_contractor_obj
             cheapest_contractor_label cheapest_cost rank_of_chosen outcome
             cost_delta ops_user)a

  def outcomes, do: @outcomes

  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required([:manifest_obj, :manifest_date, :period_month])
    |> validate_inclusion(:outcome, @outcomes)
    |> unique_constraint(:manifest_obj)
  end
end
