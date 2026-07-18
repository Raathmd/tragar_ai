defmodule TragarAiWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use TragarAiWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint TragarAiWeb.Endpoint

      use TragarAiWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import TragarAiWeb.ConnCase
    end
  end

  setup tags do
    TragarAi.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup helper that creates an admin user (wildcard access) and puts them in the
  session, so tests of the now role-gated LiveViews mount as a signed-in admin.

      setup :register_and_log_in_admin
  """
  def register_and_log_in_admin(%{conn: conn}) do
    {:ok, conn: log_in_admin(conn)}
  end

  @doc "Create an admin user, grant the admin role, and store them in the session."
  def log_in_admin(conn) do
    email = "admin-#{System.unique_integer([:positive])}@test.local"

    {:ok, user} =
      TragarAi.Accounts.register_user(%{
        email: email,
        type: "admin",
        password: "test-password-123"
      })

    # Clear the first-login reset flag so the gate doesn't redirect to /reset-password.
    {:ok, user} = TragarAi.Accounts.set_password(user, %{password: "test-password-123"})

    admin_role =
      case Enum.find(TragarAi.Accounts.list_roles!(), &(&1.name == "admin")) do
        nil ->
          TragarAi.Accounts.Role
          |> Ash.Changeset.for_create(:create, %{name: "admin", is_admin: true})
          |> Ash.create!()

        role ->
          role
      end

    {:ok, _} = TragarAi.Accounts.assign_role(user.id, admin_role.id)

    Plug.Test.init_test_session(conn, %{"user_id" => user.id})
  end
end
