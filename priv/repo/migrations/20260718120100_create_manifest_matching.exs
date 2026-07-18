defmodule TragarAi.Repo.Migrations.CreateManifestMatching do
  use Ecto.Migration

  # Materialised supplier-matching outcomes — one row per assigned manifest. The
  # "management" half of the cheapest-supplier feature: the chosen supplier vs the
  # reconstructed cheapest-at-the-time (via effective-dated rates), classified
  # preferred/override with the cost delta (savings forgone).
  #
  # A past manifest's outcome is immutable (fixed date ⇒ fixed effective-dated
  # rates ⇒ fixed cheapest), so this is computed once and only appended as new
  # manifests reach a chosen/costed status. Populated by
  # TragarAi.Insight.ManifestMatchingBackfill (PR-2). Read by the management board
  # (year → month → supplier → manifest drill).
  def change do
    create table(:manifest_matching) do
      add :manifest_obj, :string, null: false
      add :manifest_reference, :string
      add :manifest_date, :date, null: false
      add :period_month, :date, null: false
      add :rate_area_from, :string
      add :rate_area_to, :string

      add :chosen_contractor_obj, :string
      add :chosen_contractor_label, :string
      add :chosen_cost, :decimal
      add :cheapest_contractor_obj, :string
      add :cheapest_contractor_label, :string
      add :cheapest_cost, :decimal
      add :rank_of_chosen, :integer
      # outcome: "preferred" | "override"
      add :outcome, :string
      add :cost_delta, :decimal
      add :ops_user, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:manifest_matching, [:manifest_obj])
    # Management drill: month → supplier, and adherence rollups over time.
    create index(:manifest_matching, [:period_month, :chosen_contractor_obj])
    create index(:manifest_matching, [:period_month, :outcome])
  end
end
