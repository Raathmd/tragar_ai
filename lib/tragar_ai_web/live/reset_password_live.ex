defmodule TragarAiWeb.ResetPasswordLive do
  @moduledoc "First-login (or self-service) password reset. Gated by UserAuth :require_reset."
  use TragarAiWeb, :live_view

  alias TragarAi.Accounts

  def mount(_params, _session, socket) do
    {:ok, assign(socket, error: nil, page_title: "Set password")}
  end

  def handle_event("save", %{"password" => password, "confirm" => confirm}, socket) do
    cond do
      String.length(password) < 8 ->
        {:noreply, assign(socket, :error, "Password must be at least 8 characters.")}

      password != confirm ->
        {:noreply, assign(socket, :error, "Passwords don't match.")}

      true ->
        case Accounts.set_password(socket.assigns.current_user, %{password: password}) do
          {:ok, _user} ->
            {:noreply, push_navigate(socket, to: ~p"/margin")}

          {:error, _} ->
            {:noreply, assign(socket, :error, "Couldn't update password. Try again.")}
        end
    end
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto mt-16 max-w-sm p-6">
      <h1 class="mb-1 text-lg font-semibold">Set a new password</h1>
      <p class="mb-4 text-sm opacity-60">
        Signed in as {@current_user.email}. Choose a password to continue.
      </p>

      <p :if={@error} class="mb-3 rounded bg-error/10 p-2 text-sm text-error">{@error}</p>

      <form phx-submit="save" class="space-y-3">
        <input
          type="password"
          name="password"
          required
          minlength="8"
          placeholder="New password"
          autocomplete="new-password"
          class="input input-bordered w-full"
        />
        <input
          type="password"
          name="confirm"
          required
          placeholder="Confirm password"
          autocomplete="new-password"
          class="input input-bordered w-full"
        />
        <button class="btn btn-primary w-full">Save &amp; continue</button>
      </form>
    </div>
    """
  end
end
