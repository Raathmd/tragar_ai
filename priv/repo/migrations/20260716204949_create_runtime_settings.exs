defmodule TragarAi.Repo.Migrations.CreateRuntimeSettings do
  use Ecto.Migration

  # A tiny durable key/value store for runtime-adjustable settings (the active
  # Core AI model, the reasoning toggle, …) so a change made in the UI survives a
  # server restart / redeploy instead of resetting to the configured default.
  def change do
    create table(:runtime_settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
