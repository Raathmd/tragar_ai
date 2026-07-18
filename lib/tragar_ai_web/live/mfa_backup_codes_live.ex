defmodule TragarAiWeb.MfaBackupCodesLive do
  @moduledoc """
  Shown once, right after TOTP enrollment: the one-time backup recovery codes.
  They are read from the session (stashed by `MfaController.confirm_setup`) and
  only ever displayed here — the server keeps hashes, not the plaintext. The
  "Continue" button posts to `MfaController.ack_backup_codes`, which finishes the
  login and clears the codes from the session.
  """
  use TragarAiWeb, :live_view

  def mount(_params, session, socket) do
    codes = session["mfa_new_backup_codes"] || []

    {:ok,
     assign(socket,
       page_title: "Backup codes",
       codes: codes,
       form: to_form(%{}, as: :mfa)
     )}
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto mt-16 max-w-sm p-6">
      <h1 class="mb-1 text-lg font-semibold">Save your backup codes</h1>
      <p class="mb-4 text-sm opacity-60">
        Each code works once if you lose your authenticator. Store them somewhere safe —
        they won't be shown again.
      </p>

      <ul class="mb-4 grid grid-cols-2 gap-2 rounded bg-base-200 p-3 font-mono text-sm">
        <li :for={code <- @codes}>{code}</li>
      </ul>

      <.form for={@form} action={~p"/mfa/backup-codes"} class="space-y-3">
        <button class="btn btn-primary w-full">I've saved them — continue</button>
      </.form>
    </div>
    """
  end
end
