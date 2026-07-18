defmodule TragarAiWeb.MfaSetupLive do
  @moduledoc """
  First factor done, no 2FA yet: enroll a TOTP authenticator. Shows a QR code
  (and the manual key) to scan, then a plain form that posts the first 6-digit
  code to `MfaController.confirm_setup` (a controller is needed to write the
  session). Enrollment is mandatory before reaching /margin.
  """
  use TragarAiWeb, :live_view

  alias TragarAi.Accounts
  alias TragarAi.Accounts.Totp

  def mount(_params, _session, socket) do
    user = socket.assigns.pending_user

    if Accounts.totp_enabled?(user) do
      # Already enrolled — don't clobber the existing secret; go verify instead.
      {:ok, push_navigate(socket, to: ~p"/mfa/verify")}
    else
      {:ok, enrolled} = Accounts.begin_totp_enrollment(user)
      uri = Totp.otpauth_uri(enrolled.email, enrolled.totp_secret)

      {:ok,
       assign(socket,
         page_title: "Set up 2FA",
         secret: enrolled.totp_secret,
         qr_svg: Totp.qr_svg(uri),
         form: to_form(%{}, as: :mfa)
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto mt-16 max-w-sm p-6">
      <h1 class="mb-1 text-lg font-semibold">Set up two-factor authentication</h1>
      <p class="mb-4 text-sm opacity-60">
        Scan this with an authenticator app (Google Authenticator, 1Password, Authy),
        then enter the 6-digit code to finish.
      </p>

      <p
        :if={Phoenix.Flash.get(@flash, :error)}
        class="mb-3 rounded bg-error/10 p-2 text-sm text-error"
      >
        {Phoenix.Flash.get(@flash, :error)}
      </p>

      <div class="mb-3 flex justify-center rounded bg-white p-3">
        {Phoenix.HTML.raw(@qr_svg)}
      </div>

      <p class="mb-1 text-xs opacity-60">Can't scan? Enter this key manually:</p>
      <code class="mb-4 block rounded bg-base-200 px-2 py-1 font-mono text-sm">{@secret}</code>

      <.form for={@form} action={~p"/mfa/setup"} class="space-y-3">
        <input
          type="text"
          name="code"
          required
          inputmode="numeric"
          autocomplete="one-time-code"
          placeholder="6-digit code"
          class="input input-bordered w-full"
        />
        <button class="btn btn-primary w-full">Verify &amp; continue</button>
      </.form>

      <p class="mt-4 text-center text-sm">
        <a href="/logout" class="opacity-60 hover:underline">Cancel</a>
      </p>
    </div>
    """
  end
end
