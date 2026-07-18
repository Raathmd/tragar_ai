defmodule TragarAiWeb.SessionController do
  @moduledoc """
  Email+password login for the margin dashboards. Login must go through a
  controller (not a LiveView) so it can set the session cookie; the gating then
  happens in `TragarAiWeb.UserAuth` on_mount hooks.
  """
  use TragarAiWeb, :controller

  alias TragarAi.Accounts

  def create(conn, %{"email" => email, "password" => password}) do
    case Accounts.authenticate(email, password) do
      {:ok, %{mfa_required: false} = user} ->
        # This account skips the second factor (e.g. the shared CSD display).
        # Promote straight to a full session. The page gates route the user to a
        # surface they may see; must_reset is enforced there too.
        conn
        |> configure_session(renew: true)
        |> delete_session(:pending_user_id)
        |> put_session(:user_id, user.id)
        |> redirect(to: "/")

      {:ok, user} ->
        # Password checked — hold the login as "pending" and require the second
        # factor. MfaController promotes it to a full session (:user_id) only
        # once the TOTP (or a backup) code checks out.
        conn
        |> configure_session(renew: true)
        |> delete_session(:user_id)
        |> put_session(:pending_user_id, user.id)
        |> redirect(to: "/mfa")

      :error ->
        conn
        |> put_flash(:error, "Invalid email or password.")
        |> redirect(to: "/login")
    end
  end

  def create(conn, _params) do
    conn |> put_flash(:error, "Enter an email and password.") |> redirect(to: "/login")
  end

  def delete(conn, _params) do
    conn |> configure_session(drop: true) |> redirect(to: "/login")
  end
end
