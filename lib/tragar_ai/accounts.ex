defmodule TragarAi.Accounts do
  @moduledoc """
  Accounts domain — the `User` records allowed into the margin dashboards, plus
  the auth helpers the web layer calls (authenticate, create, re-issue). Admins
  (`type == "admin"`) can register/remove other users. No email is sent yet, so
  `create_user`/`reissue_password` return the generated temp password for the
  admin to relay; a mailer can be dropped in later without touching callers.
  """
  use Ash.Domain, otp_app: :tragar_ai

  require Ash.Query

  alias TragarAi.Accounts.Password
  alias TragarAi.Accounts.Totp
  alias TragarAi.Accounts.User

  resources do
    resource User do
      define :list_users, action: :read
      define :register_user, action: :register
      define :set_password, action: :set_password
      define :reissue, action: :reissue_password
      define :delete_user, action: :destroy
      define :apply_totp_secret, action: :begin_totp
      define :store_backup_codes, action: :confirm_totp
      define :store_remaining_backup, action: :consume_backup_code
      define :clear_totp, action: :reset_totp
    end
  end

  @doc "Load a user by id for session lookups; nil on anything unexpected."
  def fetch_user(id) when is_binary(id) do
    case Ash.get(User, id) do
      {:ok, user} -> user
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def fetch_user(_), do: nil

  @doc "Verify email+password. Returns `{:ok, user}` or `:error` (constant-time-ish)."
  def authenticate(email, password) do
    user = user_by_email(normalize_email(email))

    cond do
      is_nil(user) ->
        Password.no_user_verify()
        :error

      Password.verify(password, user.hashed_password) ->
        {:ok, user}

      true ->
        :error
    end
  end

  @doc "Admin creates a user; returns `{:ok, user, temp_password}` (temp shown to admin)."
  def create_user(email, type) do
    type = if type == "admin", do: "admin", else: "user"
    password = temp_password()

    case register_user(%{email: normalize_email(email), type: type, password: password}) do
      {:ok, user} -> {:ok, user, password}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Admin re-issues a temp password (forgot-password); returns `{:ok, user, temp_password}`."
  def reissue_password(user) do
    password = temp_password()

    case reissue(user, %{password: password}) do
      {:ok, user} -> {:ok, user, password}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Create the default admins if absent. Returns per-email status + any temp password."
  def seed_admins do
    for email <- ["leigh@tragar.co.za", "raathmd@gmail.com"] do
      e = normalize_email(email)

      case user_by_email(e) do
        nil ->
          {:ok, _user, pw} = create_user(e, "admin")
          %{email: e, status: :created, password: pw}

        _ ->
          %{email: e, status: :exists}
      end
    end
  end

  # --- TOTP second factor -------------------------------------------------

  @doc "Whether the user has completed TOTP enrollment (2FA active)."
  def totp_enabled?(%User{totp_confirmed_at: nil}), do: false
  def totp_enabled?(%User{}), do: true
  def totp_enabled?(_), do: false

  @doc """
  Ensure the user has a (possibly unconfirmed) TOTP secret and return the user.
  Reuses an existing unconfirmed secret so reloading the enrollment page keeps
  the same QR; a fully-enrolled user gets a fresh secret (re-enrollment).
  """
  def begin_totp_enrollment(%User{totp_secret: secret, totp_confirmed_at: nil} = user)
      when is_binary(secret),
      do: {:ok, user}

  def begin_totp_enrollment(%User{} = user),
    do: apply_totp_secret(user, %{secret: Totp.new_secret()})

  @doc "Verify a submitted TOTP `code` against the user's secret."
  def verify_totp(%User{totp_secret: secret}, code), do: Totp.valid_code?(secret, code)
  def verify_totp(_user, _code), do: false

  @doc """
  Confirm enrollment: generate one-time backup codes, persist their hashes, and
  mark 2FA active. Returns `{:ok, user, plaintext_codes}` (show the plaintext
  once).
  """
  def confirm_totp(%User{} = user) do
    {plaintext, hashed} = Totp.generate_backup_codes()

    case store_backup_codes(user, %{backup_codes: hashed}) do
      {:ok, user} -> {:ok, user, plaintext}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Consume a backup recovery code; `{:ok, user}` on success, `:error` otherwise."
  def use_backup_code(%User{} = user, input) do
    case Totp.consume_backup_code(user.backup_codes, input) do
      {:ok, remaining} ->
        case store_remaining_backup(user, %{remaining: remaining}) do
          {:ok, user} -> {:ok, user}
          _ -> :error
        end

      :error ->
        :error
    end
  end

  @doc "Admin: clear a user's 2FA so they re-enroll on next login."
  def reset_totp(%User{} = user), do: clear_totp(user)

  def normalize_email(email), do: email |> to_string() |> String.trim() |> String.downcase()

  defp temp_password do
    :crypto.strong_rand_bytes(9) |> Base.url_encode64() |> binary_part(0, 12)
  end

  defp user_by_email(email) do
    User
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one!()
  end
end
