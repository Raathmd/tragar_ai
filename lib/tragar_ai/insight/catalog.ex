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
      |> Enum.filter(&(is_map(&1) and is_binary(&1["sql"])))
      |> Enum.with_index()
      |> Enum.map(fn {q, i} ->
        %{
          id: to_string(q["id"] || i),
          title: q["title"] || "(untitled)",
          description: q["description"] || "",
          sql: q["sql"]
        }
      end)
    else
      _ -> []
    end
  end

  @doc "Find a catalog entry by id, or nil."
  @spec fetch(String.t()) :: map() | nil
  def fetch(id), do: Enum.find(load(), &(&1.id == id))
end
