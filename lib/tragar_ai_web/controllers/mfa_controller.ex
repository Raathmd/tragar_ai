defmodule TragarAiWeb.MfaController do
  @moduledoc """
  The second-factor (TOTP) step of the margin login. Reached only after the
  password check, which leaves `:pending_user_id` in the session. This controller
  performs the session write that promotes a pending login to a full one
  (`:user_id`). Enrollment is mandatory, so a user with no confirmed TOTP is sent
  to set one up before they can finish signing in.
  """
  use TragarAiWeb, :controller

  alias TragarAi.Accounts

  # Dispatch by enrollment state: enrolled → enter a code; not yet → set 2FA up.
  def index(conn, _params) do
    case pending_user(conn) do
      nil ->
        redirect(conn, to: "/login")

      user ->
        if Accounts.totp_enabled?(user),
          do: redirect(conn, to: "/mfa/verify"),
          else: redirect(conn, to: "/mfa/setup")
    end
  end

  # Enrollment: verify the first code, then hand back the one-time backup codes.
  def confirm_setup(conn, %{"code" => code}) do
    with user when not is_nil(user) <- pending_user(conn),
         false <- Accounts.totp_enabled?(user),
         true <- Accounts.verify_totp(user, code),
         {:ok, _user, codes} <- Accounts.confirm_totp(user) do
      conn
      |> put_session(:mfa_new_backup_codes, codes)
      |> redirect(to: "/mfa/backup-codes")
    else
      nil ->
        redirect(conn, to: "/login")

      true ->
        redirect(conn, to: "/mfa/verify")

      _ ->
        conn
        |> put_flash(:error, "That code didn't match. Try again.")
        |> redirect(to: "/mfa/setup")
    end
  end

  def confirm_setup(conn, _params) do
    conn
    |> put_flash(:error, "Enter the 6-digit code.")
    |> redirect(to: "/mfa/setup")
  end

  # Returning user: a valid TOTP or backup code completes the login.
  def verify(conn, %{"code" => code}) do
    with user when not is_nil(user) <- pending_user(conn),
         true <- verify_second_factor(user, code) do
      finalize(conn, user)
    else
      nil ->
        redirect(conn, to: "/login")

      _ ->
        conn
        |> put_flash(:error, "Invalid code.")
        |> redirect(to: "/mfa/verify")
    end
  end

  def verify(conn, _params) do
    conn
    |> put_flash(:error, "Enter your code.")
    |> redirect(to: "/mfa/verify")
  end

  # The user acknowledged their backup codes — finish the login.
  def ack_backup_codes(conn, _params) do
    case pending_user(conn) do
      nil ->
        redirect(conn, to: "/login")

      user ->
        conn
        |> delete_session(:mfa_new_backup_codes)
        |> finalize(user)
    end
  end

  defp verify_second_factor(user, code) do
    Accounts.verify_totp(user, code) or match?({:ok, _}, Accounts.use_backup_code(user, code))
  end

  defp finalize(conn, user) do
    conn
    |> delete_session(:pending_user_id)
    |> put_session(:user_id, user.id)
    |> configure_session(renew: true)
    |> redirect(to: (user.must_reset && "/reset-password") || "/margin")
  end

  defp pending_user(conn), do: Accounts.fetch_user(get_session(conn, :pending_user_id))
end
