defmodule TragarAi.Insight.Catalog do
  @moduledoc """
  The clickable inspection-query catalog for the `/_inspect` console.

  Claude Code (data-blind) authors read-only SELECTs into a JSON file at the
  configured path; the LiveView renders them as clickable cards you run yourself.
  Claude only ever WRITES this file — it never reads query results. The file is a
  JSON array of objects: `{"id", "title", "description", "sql"}`.

  The path defaults to `~/.fw-inspect/catalog.json` so it can be authored at
  runtime (no redeploy per query); override with
  `config :tragar_ai, TragarAi.Insight.Catalog, path: "…"`.
  """

  @doc "Absolute path to the catalog JSON file."
  @spec path() :: String.t()
  def path do
    Application.get_env(:tragar_ai, __MODULE__, [])
    |> Keyword.get(:path, Path.join(System.user_home!() || "/tmp", ".fw-inspect/catalog.json"))
  end

  @doc "Load the catalog entries (empty list if the file is missing/invalid)."
  @spec load() :: [map()]
  def load do
    with {:ok, body} <- File.read(path()),
         {:ok, list} when is_list(list) <- Jason.decode(body) do
      list
      |> Enum.filter(&entry?/1)
      |> Enum.with_index()
      |> Enum.map(fn {q, i} ->
        %{
          id: to_string(q["id"] || i),
          title: q["title"] || "(untitled)",
          description: q["description"] || "",
          sql: q["sql"],
          quote: q["quote"],
          quote_sql: q["quote_sql"],
          group: q["group"]
        }
      end)
    else
      _ -> []
    end
  end

  @doc "Find a catalog entry by id, or nil."
  @spec fetch(String.t()) :: map() | nil
  def fetch(id), do: Enum.find(load(), &(&1.id == id))

  @doc """
  Delete the catalog entry with the given id and rewrite the JSON file. Ids match
  `load/0`'s (explicit `"id"`, else positional index), so pass the id the console
  rendered. Deleting a missing id is a no-op `:ok`. A missing catalog file is also
  `:ok` (nothing to delete). Only touches the query definitions — still never
  reads results.
  """
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(id) do
    case File.read(path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, list} when is_list(list) -> list |> without(id) |> write()
          _ -> {:error, :invalid_catalog}
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Drop the entry whose id (explicit or positional) matches, mirroring load/0's
  # valid-entry filter + index derivation so the id the UI passes lines up.
  defp without(list, id) do
    list
    |> Enum.filter(&entry?/1)
    |> Enum.with_index()
    |> Enum.reject(fn {q, i} -> to_string(q["id"] || i) == to_string(id) end)
    |> Enum.map(&elem(&1, 0))
  end

  # A valid entry is a SQL query ("sql"), a static quick-quote case ("quote"), or a
  # real-data quick-quote case ("quote_sql" — a SELECT returning one form-shaped row).
  defp entry?(q) do
    is_map(q) and (is_binary(q["sql"]) or is_map(q["quote"]) or is_binary(q["quote_sql"]))
  end

  defp write(list) do
    file = path()

    with :ok <- File.mkdir_p(Path.dirname(file)),
         {:ok, json} <- Jason.encode(list, pretty: true) do
      File.write(file, json)
    end
  end
end
