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
