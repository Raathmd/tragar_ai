defmodule TragarAiWeb.UserAuth do
  @moduledoc """
  LiveView `on_mount` gates for the browser surfaces. Reads the session's
  `user_id`, assigns `:current_user` (with roles + permissions preloaded), and
  halts (redirect) when the requirement isn't met:

    * `{:require_page, key}` — a signed-in, reset-complete user whose roles grant
      the page `key` (admins are a wildcard). Used by every app LiveView; on a
      permission miss the user is bounced to their own landing page. This is the
      one gate that replaced the old `:require_authenticated`/`:require_admin`.
    * `:require_reset` — a signed-in user (reset pending or not); used by the
      reset page itself so it doesn't redirect to itself.
    * `:require_pending` — a password-verified login awaiting its second factor
      (`:pending_user_id` set, not yet `:user_id`); used by the /mfa pages.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias TragarAi.Accounts

  def on_mount({:require_page, page_key}, _params, session, socket) do
    user = current_user(session)
    socket = assign(socket, :current_user, user)

    cond do
      is_nil(user) ->
        {:halt, redirect(socket, to: "/login")}

      user.must_reset ->
        {:halt, redirect(socket, to: "/reset-password")}

      Accounts.can?(user, page_key) ->
        {:cont, socket}

      true ->
        # Signed in but not entitled to this page — send them to a page they can
        # see (their landing), or back to /login if they have no pages at all.
        {:halt,
         socket
         |> put_flash(:error, "You don't have access to that page.")
         |> redirect(to: Accounts.landing_path(user))}
    end
  end

  def on_mount(:require_reset, _params, session, socket) do
    user = current_user(session)
    socket = assign(socket, :current_user, user)

    if user, do: {:cont, socket}, else: {:halt, redirect(socket, to: "/login")}
  end

  def on_mount(:require_pending, _params, session, socket) do
    user = Accounts.fetch_user(session["pending_user_id"])
    socket = assign(socket, :pending_user, user)

    if user, do: {:cont, socket}, else: {:halt, redirect(socket, to: "/login")}
  end

  defp current_user(session), do: Accounts.fetch_user(session["user_id"])
end
