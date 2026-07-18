defmodule TragarAiWeb.UserAuth do
  @moduledoc """
  LiveView `on_mount` gates for the margin surfaces. Reads the session's
  `user_id`, assigns `:current_user`, and halts (redirect) when the requirement
  isn't met:

    * `:require_authenticated` — a signed-in user who has completed first-login
      reset (else → /reset-password); used by /margin.
    * `:require_reset` — a signed-in user (reset pending or not); used by the
      reset page itself so it doesn't redirect to itself.
    * `:require_admin` — a signed-in, reset-complete admin; used by /margin/users.
    * `:require_pending` — a password-verified login awaiting its second factor
      (`:pending_user_id` set, not yet `:user_id`); used by the /mfa pages.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias TragarAi.Accounts

  def on_mount(:require_authenticated, _params, session, socket) do
    user = current_user(session)
    socket = assign(socket, :current_user, user)

    cond do
      is_nil(user) -> {:halt, redirect(socket, to: "/login")}
      user.must_reset -> {:halt, redirect(socket, to: "/reset-password")}
      true -> {:cont, socket}
    end
  end

  def on_mount(:require_reset, _params, session, socket) do
    user = current_user(session)
    socket = assign(socket, :current_user, user)

    if user, do: {:cont, socket}, else: {:halt, redirect(socket, to: "/login")}
  end

  def on_mount(:require_admin, _params, session, socket) do
    user = current_user(session)
    socket = assign(socket, :current_user, user)

    cond do
      is_nil(user) ->
        {:halt, redirect(socket, to: "/login")}

      user.must_reset ->
        {:halt, redirect(socket, to: "/reset-password")}

      user.type != "admin" ->
        {:halt, socket |> put_flash(:error, "Admins only.") |> redirect(to: "/margin")}

      true ->
        {:cont, socket}
    end
  end

  def on_mount(:require_pending, _params, session, socket) do
    user = Accounts.fetch_user(session["pending_user_id"])
    socket = assign(socket, :pending_user, user)

    if user, do: {:cont, socket}, else: {:halt, redirect(socket, to: "/login")}
  end

  defp current_user(session), do: Accounts.fetch_user(session["user_id"])
end
