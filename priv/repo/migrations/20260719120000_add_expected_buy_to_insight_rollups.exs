defmodule TragarAi.Repo.Migrations.AddExpectedBuyToInsightRollups do
  use Ecto.Migration

  # "Buy expected" for the margin report: what each waybill's assigned supplier
  # should have charged per its rate card. Populated by Backfill.run_expected/0
  # (separate from the sell/buy backfill), so existing rows default to 0 until
  # that runs.
  def change do
    alter table(:insight_rollups) do
      add :expected_buy, :decimal, null: false, default: 0
    end
  end
end
