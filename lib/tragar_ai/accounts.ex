defmodule TragarAi.Accounts do
  @moduledoc """
  Accounts domain — the `User` records allowed into the app, their `Role`s, and
  the auth helpers the web layer calls (authenticate, create, re-issue, plus the
  role-based `can?/2` / `landing_path/1` gate). A user's roles decide which pages
  they may view (see `pages/0`); the `admin` role is a wildcard. Users with the
  `margin_users` page (i.e. admins) manage everyone else. No email is sent yet, so
  `create_user`/`reissue_password` return the generated temp password for the
  admin to relay; a mailer can be dropped in later without touching callers.

  The legacy `User.type` string is retained for backwards-compatibility but no
  longer gates anything — authorization is entirely role-based.
  """
  use Ash.Domain, otp_app: :tragar_ai

  require Ash.Query

  alias TragarAi.Accounts.Password
  alias TragarAi.Accounts.Role
  alias TragarAi.Accounts.Totp
  alias TragarAi.Accounts.User
  alias TragarAi.Accounts.UserRole

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
      define :update_mfa_required, action: :set_mfa_required
    end

    resource Role do
      define :list_roles, action: :read
    end

    resource UserRole do
      define :create_user_role, action: :create
      define :list_user_roles, action: :read
    end

    resource TragarAi.Accounts.RolePermission
  end

  # --- Page registry ------------------------------------------------------
  #
  # The single source of truth for gated LiveViews. `key` is what
  # `RolePermission.page_key` and the router's `{:require_page, key}` hook use;
  # `path` is where a permitted user lands. Order matters: `landing_path/1`
  # returns the first page a user may see, so keep the everyday surfaces first.
  @pages [
    %{key: "dashboard", label: "Dashboard", path: "/"},
    %{key: "console", label: "Assist console", path: "/console"},
    %{key: "collections", label: "Collections", path: "/collections"},
    %{key: "supplier_ops", label: "Supplier selection (ops)", path: "/supplier"},
    %{key: "supplier_mgmt", label: "Supplier selection (management)", path: "/supplier/history"},
    %{key: "margin", label: "Margin", path: "/margin"},
    %{key: "margin_users", label: "Access admin", path: "/margin/users"},
    %{key: "settings", label: "Settings", path: "/settings"},
    %{key: "architecture", label: "Architecture", path: "/architecture"},
    %{key: "inspect", label: "DB inspect", path: "/_inspect"}
  ]

  @doc "All gated pages as `%{key, label, path}` in landing-preference order."
  def pages, do: @pages

  @doc "The route a page_key maps to, or nil."
  def page_path(key), do: Enum.find_value(@pages, fn p -> p.key == to_string(key) && p.path end)

  @doc """
  Load a user by id for session lookups, with roles + their permissions
  preloaded (so `can?/2`, `admin?/1`, `landing_path/1` work). nil on anything
  unexpected.
  """
  def fetch_user(id) when is_binary(id) do
    case Ash.get(User, id, load: [roles: [:permissions]]) do
      {:ok, user} -> user
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def fetch_user(_), do: nil

  # --- Authorization ------------------------------------------------------

  @doc "Does the user hold a wildcard (admin) role? Requires roles preloaded."
  def admin?(%User{roles: roles}) when is_list(roles), do: Enum.any?(roles, & &1.is_admin)
  def admin?(_), do: false

  @doc "The set of page_keys a user may view (admins see all). Requires roles preloaded."
  def permitted_pages(%User{} = user) do
    if admin?(user) do
      Enum.map(@pages, & &1.key)
    else
      case user.roles do
        roles when is_list(roles) ->
          roles
          |> Enum.flat_map(fn r -> if(is_list(r.permissions), do: r.permissions, else: []) end)
          |> Enum.map(& &1.page_key)
          |> Enum.uniq()

        _ ->
          []
      end
    end
  end

  def permitted_pages(_), do: []

  @doc "May this user view `page_key`?"
  def can?(%User{} = user, page_key), do: admin?(user) or to_string(page_key) in permitted_pages(user)
  def can?(_, _), do: false

  @doc "First page the user may land on after login (their path), or \"/login\" if none."
  def landing_path(%User{} = user) do
    allowed = permitted_pages(user)

    Enum.find_value(@pages, "/login", fn p -> p.key in allowed && p.path end)
  end

  def landing_path(_), do: "/login"

  @doc "Assign a role to a user (idempotent — a duplicate is treated as success)."
  def assign_role(user_id, role_id) do
    case create_user_role(%{user_id: user_id, role_id: role_id}) do
      {:ok, ur} -> {:ok, ur}
      # Unique (user_id, role_id) violation → already assigned; fine.
      {:error, _} -> {:ok, :exists}
    end
  end

  @doc "Remove a role from a user."
  def unassign_role(user_id, role_id) do
    UserRole
    |> Ash.Query.filter(user_id == ^user_id and role_id == ^role_id)
    |> Ash.read!()
    |> Enum.each(&Ash.destroy!/1)

    :ok
  end

  @doc "Set (replace) a user's roles to exactly `role_ids`."
  def set_user_roles(user_id, role_ids) do
    current =
      UserRole
      |> Ash.Query.filter(user_id == ^user_id)
      |> Ash.read!()

    keep = MapSet.new(role_ids)
    have = MapSet.new(current, & &1.role_id)

    # Drop the ones no longer wanted.
    current
    |> Enum.reject(&MapSet.member?(keep, &1.role_id))
    |> Enum.each(&Ash.destroy!/1)

    # Add the newly-wanted ones.
    keep
    |> Enum.reject(&MapSet.member?(have, &1))
    |> Enum.each(&assign_role(user_id, &1))

    :ok
  end

  @doc "The role ids currently assigned to a user (loads if needed)."
  def role_ids(%User{roles: roles}) when is_list(roles), do: Enum.map(roles, & &1.id)

  def role_ids(%User{id: id}) do
    UserRole
    |> Ash.Query.filter(user_id == ^id)
    |> Ash.read!()
    |> Enum.map(& &1.role_id)
  end

  @doc "Toggle a user's second-factor requirement."
  def set_mfa_required(%User{} = user, required?), do: update_mfa_required(user, %{mfa_required: required?})

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
