defmodule TragarAi.Freight.Accounts do
  @moduledoc """
  Cached directory of the FreightWare accounts the configured user is allocated
  to (`Freight.accounts/0` → `system/baseData/accounts`).

  Used to validate any account reference *before* it is used to scope a query —
  whether it arrives from a Freshdesk ticket or is typed into the console/chat —
  so an invalid code (e.g. `ITD001`, which isn't a real account) is rejected up
  front with a clear message instead of silently returning empty results.

  The directory is cached for a TTL (it changes rarely). Validation **fails open**:
  if FreightWare is unreachable and we have no cached directory, we allow the
  reference (and log it) rather than block every account-scoped lookup.
  """

  alias TragarAi.Freight
  require Logger

  @ttl_ms :timer.minutes(30)
  @key {__MODULE__, :directory}

  @doc "The `%{REF => account_map}` directory, cached. `{:error, reason}` if it can't load."
  @spec directory() :: {:ok, map()} | {:error, term()}
  def directory do
    case cached() do
      {:ok, dir} -> {:ok, dir}
      :miss -> load()
    end
  end

  @doc """
  Is `ref` a known allocated account? Normalises case/whitespace. Fails open
  (returns `true`) when the directory can't be loaded, so a FreightWare outage
  doesn't block legitimate work.
  """
  @spec valid?(term()) :: boolean()
  def valid?(ref) when is_binary(ref) and ref != "" do
    case directory() do
      {:ok, dir} ->
        Map.has_key?(dir, norm(ref))

      {:error, reason} ->
        Logger.warning("[accounts] directory unavailable (#{inspect(reason)}); allowing #{ref}")
        true
    end
  end

  def valid?(_), do: false

  @doc "Look up a single account map by reference, or `:error`."
  @spec lookup(String.t()) :: {:ok, map()} | :error
  def lookup(ref) when is_binary(ref) do
    with {:ok, dir} <- directory() do
      Map.fetch(dir, norm(ref))
    else
      _ -> :error
    end
  end

  @doc "Force a fresh load of the directory (bypasses the cache)."
  def refresh, do: load()

  @doc """
  Resolve the account from whatever signals we have, in priority order:

    1. an explicit, valid account `:code`
    2. a `:company` name matched against account_name / short_name / other_name /
       contact_name (normalised substring, either direction)
    3. a requester email `:domain` matched against the account email's domain

  Returns `{:ok, ref}` for a single confident match, `{:ambiguous, [refs]}` when
  several accounts match (the caller asks the user which), or `:none`.
  """
  @spec resolve(map()) :: {:ok, String.t()} | {:ambiguous, [String.t()]} | :none
  def resolve(signals) when is_map(signals) do
    code = signals[:code] || signals["code"]
    company = signals[:company] || signals["company"]
    domain = signals[:domain] || signals["domain"]

    cond do
      is_binary(code) and code != "" and valid?(code) -> {:ok, norm(code)}
      match = match_first([by_name(company), by_domain(domain)]) -> match
      true -> :none
    end
  end

  def resolve(_), do: :none

  @doc "Account references whose name-ish fields match `company` (normalised substring)."
  @spec by_name(term()) :: [String.t()]
  def by_name(company) when is_binary(company) and company != "" do
    q = norm(company)

    with {:ok, dir} <- directory() do
      for {ref, a} <- dir, name_match?(a, q), do: ref
    else
      _ -> []
    end
    |> Enum.uniq()
  end

  def by_name(_), do: []

  @doc "Account references whose account email domain equals `domain`."
  @spec by_domain(term()) :: [String.t()]
  def by_domain(domain) when is_binary(domain) and domain != "" do
    d = domain |> String.trim() |> String.downcase()

    with {:ok, dir} <- directory() do
      for {ref, a} <- dir, email_domain(a["email"]) == d, do: ref
    else
      _ -> []
    end
    |> Enum.uniq()
  end

  def by_domain(_), do: []

  # First non-empty match list → {:ok, one} | {:ambiguous, many}; else fall through.
  defp match_first(lists) do
    Enum.find_value(lists, fn
      [one] -> {:ok, one}
      [_ | _] = many -> {:ambiguous, Enum.sort(many)}
      _ -> nil
    end)
  end

  defp name_match?(account, q) do
    [
      account["account_name"],
      account["short_name"],
      account["other_name"],
      account["contact_name"]
    ]
    |> Enum.any?(fn v ->
      is_binary(v) and v != "" and (String.contains?(norm(v), q) or String.contains?(q, norm(v)))
    end)
  end

  defp email_domain(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [_, dom] -> dom |> String.trim() |> String.downcase()
      _ -> nil
    end
  end

  defp email_domain(_), do: nil

  # ── internals ────────────────────────────────────────────────────────────────

  defp load do
    case Freight.accounts() do
      {:ok, list} when is_list(list) ->
        dir =
          for a <- list,
              ref = a["account_reference"],
              is_binary(ref) and ref != "",
              into: %{},
              do: {norm(ref), a}

        :persistent_term.put(@key, %{dir: dir, at: now()})
        {:ok, dir}

      {:error, _} = err ->
        err
    end
  end

  defp cached do
    case :persistent_term.get(@key, nil) do
      %{dir: dir, at: at} -> if now() - at < @ttl_ms, do: {:ok, dir}, else: :miss
      _ -> :miss
    end
  end

  defp norm(ref), do: ref |> String.trim() |> String.upcase()
  defp now, do: System.monotonic_time(:millisecond)
end
