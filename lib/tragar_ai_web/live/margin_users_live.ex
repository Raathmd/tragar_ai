defmodule TragarAiWeb.MarginUsersLive do
  @moduledoc """
  Admin-only management of who can access the margin dashboards. Add a user
  (email + type), re-issue a temp password (forgot-password), or revoke access.
  Since prod can't send email yet, the generated temp password is shown here once
  for the admin to relay; the user is forced to reset it on first login.
  """
  use TragarAiWeb, :live_view

  alias TragarAi.Accounts

  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Margin access", issued: nil) |> load_users()}
  end

  defp load_users(socket) do
    assign(socket, :users, Enum.sort_by(Accounts.list_users!(), & &1.email))
  end

  def handle_event("add", %{"email" => email, "type" => type}, socket) do
    email = String.trim(email)

    cond do
      not String.contains?(email, "@") ->
        {:noreply, put_flash(socket, :error, "Enter a valid email.")}

      true ->
        case Accounts.create_user(email, type) do
          {:ok, user, password} ->
            {:noreply,
             socket
             |> load_users()
             |> assign(:issued, %{email: user.email, password: password, action: "created"})}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Couldn't create — #{email} may already exist.")}
        end
    end
  end

  def handle_event("reissue", %{"id" => id}, socket) do
    with user when not is_nil(user) <- Enum.find(socket.assigns.users, &(&1.id == id)),
         {:ok, u, password} <- Accounts.reissue_password(user) do
      {:noreply,
       socket
       |> load_users()
       |> assign(:issued, %{email: u.email, password: password, action: "reset"})}
    else
      _ -> {:noreply, put_flash(socket, :error, "Couldn't reset that user's password.")}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    user = Enum.find(socket.assigns.users, &(&1.id == id))

    cond do
      is_nil(user) ->
        {:noreply, socket}

      user.id == socket.assigns.current_user.id ->
        {:noreply, put_flash(socket, :error, "You can't remove your own access.")}

      true ->
        Accounts.delete_user!(user)
        {:noreply, socket |> load_users() |> put_flash(:info, "Removed #{user.email}.")}
    end
  end

  def handle_event("reset_2fa", %{"id" => id}, socket) do
    with user when not is_nil(user) <- Enum.find(socket.assigns.users, &(&1.id == id)),
         {:ok, _u} <- Accounts.reset_totp(user) do
      {:noreply,
       socket
       |> load_users()
       |> put_flash(:info, "2FA reset for #{user.email}; they'll re-enroll on next login.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Couldn't reset 2FA.")}
    end
  end

  def handle_event("dismiss_issued", _params, socket),
    do: {:noreply, assign(socket, :issued, nil)}

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl p-4">
      <div class="mb-4 flex items-center justify-between">
        <h1 class="text-lg font-semibold">Margin access</h1>
        <div class="flex items-center gap-2 text-sm">
          <.link navigate={~p"/margin"} class="btn btn-ghost btn-sm">← Margin</.link>
          <a href="/logout" class="btn btn-ghost btn-sm">Log out</a>
        </div>
      </div>

      <p
        :if={Phoenix.Flash.get(@flash, :error)}
        class="mb-3 rounded bg-error/10 p-2 text-sm text-error"
      >
        {Phoenix.Flash.get(@flash, :error)}
      </p>
      <p :if={Phoenix.Flash.get(@flash, :info)} class="mb-3 rounded bg-success/10 p-2 text-sm">
        {Phoenix.Flash.get(@flash, :info)}
      </p>

      <div :if={@issued} class="mb-4 rounded border border-warning bg-warning/10 p-3 text-sm">
        <div class="mb-1 font-medium">Temp password {@issued.action} for {@issued.email}</div>
        <div class="mb-2 opacity-70">
          Email isn't wired yet — copy this and send it to them privately. They'll set their own
          password on first login.
        </div>
        <code class="rounded bg-base-200 px-2 py-1 font-mono text-base">{@issued.password}</code>
        <button phx-click="dismiss_issued" class="btn btn-ghost btn-xs ml-2">Done</button>
      </div>

      <form phx-submit="add" class="mb-6 flex flex-wrap items-end gap-2">
        <div class="flex-1">
          <label class="mb-1 block text-xs opacity-60">Email</label>
          <input
            type="email"
            name="email"
            required
            placeholder="person@tragar.co.za"
            class="input input-bordered input-sm w-full"
          />
        </div>
        <div>
          <label class="mb-1 block text-xs opacity-60">Role</label>
          <select name="type" class="select select-bordered select-sm">
            <option value="user">User</option>
            <option value="admin">Admin</option>
          </select>
        </div>
        <button class="btn btn-primary btn-sm">Add user</button>
      </form>

      <table class="table table-sm w-full">
        <thead>
          <tr>
            <th>Email</th>
            <th>Role</th>
            <th>Status</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={u <- @users}>
            <td class="font-mono text-xs">{u.email}</td>
            <td>
              <span class={["badge badge-sm", (u.type == "admin" && "badge-primary") || "badge-ghost"]}>
                {u.type}
              </span>
            </td>
            <td class="text-xs opacity-70">
              {(u.must_reset && "reset pending") || "active"} · {(u.totp_confirmed_at && "2FA on") ||
                "2FA off"}
            </td>
            <td class="text-right">
              <button phx-click="reissue" phx-value-id={u.id} class="btn btn-ghost btn-xs">
                Reset
              </button>
              <button
                :if={u.totp_confirmed_at}
                phx-click="reset_2fa"
                phx-value-id={u.id}
                data-confirm={"Reset 2FA for #{u.email}?"}
                class="btn btn-ghost btn-xs"
              >
                Reset 2FA
              </button>
              <button
                :if={u.id != @current_user.id}
                phx-click="revoke"
                phx-value-id={u.id}
                data-confirm={"Remove #{u.email}?"}
                class="btn btn-ghost btn-xs text-error"
              >
                Revoke
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
