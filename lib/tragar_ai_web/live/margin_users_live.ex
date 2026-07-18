defmodule TragarAiWeb.MarginUsersLive do
  @moduledoc """
  Admin-only access management. Add a user, assign/unassign roles (which decide
  the pages they may view — see `TragarAi.Accounts.pages/0`), toggle whether the
  account needs 2FA (off for the shared CSD display), re-issue a temp password,
  reset 2FA, or revoke access. Since prod can't send email yet, a generated temp
  password is shown here once for the admin to relay.
  """
  use TragarAiWeb, :live_view

  alias TragarAi.Accounts

  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Access", issued: nil) |> load()}
  end

  defp load(socket) do
    users = Accounts.list_users!() |> Ash.load!([:roles]) |> Enum.sort_by(& &1.email)
    roles = Accounts.list_roles!() |> Enum.sort_by(& &1.name)
    assign(socket, users: users, roles: roles)
  end

  def handle_event("add", %{"email" => email, "role_id" => role_id}, socket) do
    email = String.trim(email)

    cond do
      not String.contains?(email, "@") ->
        {:noreply, put_flash(socket, :error, "Enter a valid email.")}

      true ->
        case Accounts.create_user(email, "user") do
          {:ok, user, password} ->
            if role_id not in [nil, ""], do: Accounts.assign_role(user.id, role_id)

            {:noreply,
             socket
             |> load()
             |> assign(:issued, %{email: user.email, password: password, action: "created"})}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Couldn't create — #{email} may already exist.")}
        end
    end
  end

  # Add or remove a role from a user (click the badge to toggle).
  def handle_event("toggle_role", %{"user" => uid, "role" => rid}, socket) do
    user = Enum.find(socket.assigns.users, &(&1.id == uid))
    role = Enum.find(socket.assigns.roles, &(&1.id == rid))
    has? = user && Enum.any?(user.roles, &(&1.id == rid))

    cond do
      is_nil(user) or is_nil(role) ->
        {:noreply, socket}

      # Guard against self-lockout: don't let an admin strip their own admin role.
      has? and role.is_admin and user.id == socket.assigns.current_user.id ->
        {:noreply, put_flash(socket, :error, "You can't remove your own admin role.")}

      has? ->
        Accounts.unassign_role(uid, rid)
        {:noreply, load(socket)}

      true ->
        Accounts.assign_role(uid, rid)
        {:noreply, load(socket)}
    end
  end

  # Flip whether this account must pass the TOTP second factor.
  def handle_event("toggle_mfa", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.users, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      user ->
        Accounts.set_mfa_required(user, !user.mfa_required)
        {:noreply, load(socket)}
    end
  end

  def handle_event("reissue", %{"id" => id}, socket) do
    with user when not is_nil(user) <- Enum.find(socket.assigns.users, &(&1.id == id)),
         {:ok, u, password} <- Accounts.reissue_password(user) do
      {:noreply,
       socket
       |> load()
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
        {:noreply, socket |> load() |> put_flash(:info, "Removed #{user.email}.")}
    end
  end

  def handle_event("reset_2fa", %{"id" => id}, socket) do
    with user when not is_nil(user) <- Enum.find(socket.assigns.users, &(&1.id == id)),
         {:ok, _u} <- Accounts.reset_totp(user) do
      {:noreply,
       socket
       |> load()
       |> put_flash(:info, "2FA reset for #{user.email}; they'll re-enroll on next login.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Couldn't reset 2FA.")}
    end
  end

  def handle_event("dismiss_issued", _params, socket),
    do: {:noreply, assign(socket, :issued, nil)}

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-4xl p-4">
      <div class="mb-4 flex items-center justify-between">
        <h1 class="text-lg font-semibold">Access</h1>
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
          <label class="mb-1 block text-xs opacity-60">Initial role</label>
          <select name="role_id" class="select select-bordered select-sm">
            <option value="">(none — assign below)</option>
            <option :for={r <- @roles} value={r.id}>{r.name}</option>
          </select>
        </div>
        <button class="btn btn-primary btn-sm">Add user</button>
      </form>

      <p class="mb-2 text-xs opacity-60">
        Click a role badge to grant or remove it. A user sees the pages granted by any of their
        roles; <span class="font-medium">admin</span> sees everything.
      </p>

      <table class="table table-sm w-full">
        <thead>
          <tr>
            <th>Email</th>
            <th>Roles</th>
            <th>2FA</th>
            <th>Status</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={u <- @users}>
            <td class="font-mono text-xs align-top">{u.email}</td>
            <td class="align-top">
              <div class="flex flex-wrap gap-1">
                <button
                  :for={role <- @roles}
                  type="button"
                  phx-click="toggle_role"
                  phx-value-user={u.id}
                  phx-value-role={role.id}
                  class={[
                    "badge badge-sm cursor-pointer",
                    (Enum.any?(u.roles, &(&1.id == role.id)) && "badge-primary") ||
                      "badge-ghost opacity-50"
                  ]}
                >
                  {role.name}
                </button>
              </div>
            </td>
            <td class="align-top text-xs">
              <button phx-click="toggle_mfa" phx-value-id={u.id} class="btn btn-ghost btn-xs">
                {(u.mfa_required && "required") || "off"}
              </button>
              <div class="opacity-60">{(u.totp_confirmed_at && "enrolled") || "not enrolled"}</div>
            </td>
            <td class="align-top text-xs opacity-70">
              {(u.must_reset && "reset pending") || "active"}
            </td>
            <td class="align-top text-right">
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
