defmodule TragarAiWeb.LoginLive do
  @moduledoc "Standalone sign-in page for the margin dashboards (posts to SessionController)."
  use TragarAiWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, form: to_form(%{}, as: :session), page_title: "Sign in")}
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto mt-16 max-w-sm p-6">
      <h1 class="mb-1 text-lg font-semibold">Tragar Margin — sign in</h1>
      <p class="mb-4 text-sm opacity-60">Restricted access. Sign in with your Tragar email.</p>

      <p
        :if={Phoenix.Flash.get(@flash, :error)}
        class="mb-3 rounded bg-error/10 p-2 text-sm text-error"
      >
        {Phoenix.Flash.get(@flash, :error)}
      </p>
      <p :if={Phoenix.Flash.get(@flash, :info)} class="mb-3 rounded bg-success/10 p-2 text-sm">
        {Phoenix.Flash.get(@flash, :info)}
      </p>

      <.form for={@form} action={~p"/login"} class="space-y-3">
        <input
          type="email"
          name="email"
          required
          placeholder="Email"
          autocomplete="username"
          class="input input-bordered w-full"
        />
        <input
          type="password"
          name="password"
          required
          placeholder="Password"
          autocomplete="current-password"
          class="input input-bordered w-full"
        />
        <button class="btn btn-primary w-full">Sign in</button>
      </.form>
    </div>
    """
  end
end
