defmodule TragarAi.RuntimeSettings do
  @moduledoc """
  Tiny durable key/value store for runtime-adjustable settings — the active Core
  AI model, the reasoning toggle, and so on — so a change made in the UI survives
  a server restart or redeploy instead of resetting to the configured default.

  Backed by the `runtime_settings` table; values are strings. Every function is
  best-effort: if the DB is unreachable (or the table not yet migrated) reads
  return the default and writes silently no-op, so a settings change never crashes
  a request and a missing store just falls back to the in-memory default.
  """
  import Ecto.Query, only: [from: 2]

  alias TragarAi.Repo

  @table "runtime_settings"

  @doc "The persisted value for `key`, or `default` when absent/unreadable."
  @spec get(String.t() | atom(), term()) :: String.t() | term()
  def get(key, default \\ nil) do
    Repo.one(from(s in @table, where: s.key == ^to_string(key), select: s.value)) || default
  rescue
    _ -> default
  catch
    _, _ -> default
  end

  @doc "Persist `value` under `key` (upsert). Best-effort; always returns `:ok`."
  @spec put(String.t() | atom(), String.t()) :: :ok
  def put(key, value) when is_binary(value) do
    now = DateTime.utc_now()

    Repo.insert_all(
      @table,
      [%{key: to_string(key), value: value, inserted_at: now, updated_at: now}],
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key
    )

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Delete a persisted key. Best-effort; returns `:ok`."
  @spec delete(String.t() | atom()) :: :ok
  def delete(key) do
    Repo.delete_all(from(s in @table, where: s.key == ^to_string(key)))
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
