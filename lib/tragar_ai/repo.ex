defmodule TragarAi.Repo do
  use AshPostgres.Repo, otp_app: :tragar_ai

  @doc """
  Postgres extensions installed for this repo. `ash-functions` installs the
  helper functions Ash relies on; `uuid-ossp` and `citext` are commonly useful.
  """
  def installed_extensions do
    ["ash-functions", "uuid-ossp", "citext"]
  end

  @doc "Minimum supported Postgres version."
  def min_pg_version do
    %Version{major: 14, minor: 0, patch: 0}
  end
end
