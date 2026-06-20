defmodule TragarAi.Repo.Migrations.AddObanJobs do
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 14)

  # Keep at least one Oban migration version when rolling back.
  def down, do: Oban.Migration.down(version: 1)
end
