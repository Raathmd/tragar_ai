defmodule TragarAiWeb.MfaVerifyLive do
  @moduledoc """
  Returning user with 2FA enabled: enter the current 6-digit code (or a one-time
  backup code). The form posts to `MfaController.verify`, which finishes the login
  by writing the session.
  """
  use TragarAiWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Two-factor", form: to_form(%{}, as: :mfa))}
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto mt-16 max-w-sm p-6">
      <h1 class="mb-1 text-lg font-semibold">Two-factor authentication</h1>
      <p class="mb-4 text-sm opacity-60">
        Enter the 6-digit code from your authenticator app.
      </p>

      <p
        :if={Phoenix.Flash.get(@flash, :error)}
        class="mb-3 rounded bg-error/10 p-2 text-sm text-error"
      >
        {Phoenix.Flash.get(@flash, :error)}
      </p>

      <.form for={@form} action={~p"/mfa/verify"} class="space-y-3">
        <input
          type="text"
          name="code"
          required
          inputmode="numeric"
          autocomplete="one-time-code"
          placeholder="6-digit code"
          class="input input-bordered w-full"
        />
        <button class="btn btn-primary w-full">Verify</button>
      </.form>

      <p class="mt-4 text-center text-sm opacity-60">
        Lost your device? Enter one of your backup codes above instead.
      </p>
      <p class="mt-2 text-center text-sm">
        <a href="/logout" class="opacity-60 hover:underline">Back to sign in</a>
      </p>
    </div>
    """
  end
end
