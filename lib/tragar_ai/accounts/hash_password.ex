defmodule TragarAi.Accounts.HashPassword do
  @moduledoc "Ash change: hashes the action's `:password` argument into `:hashed_password`."
  use Ash.Resource.Change

  alias TragarAi.Accounts.Password

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_argument(changeset, :password) do
      {:ok, pw} when is_binary(pw) and pw != "" ->
        Ash.Changeset.force_change_attribute(changeset, :hashed_password, Password.hash(pw))

      _ ->
        changeset
    end
  end
end
