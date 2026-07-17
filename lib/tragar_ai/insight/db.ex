defmodule TragarAi.Insight.Db do
  @moduledoc """
  In-beam, read-only bridge to the FreightWare OpenEdge replica.

  There is no pure-Elixir OpenEdge driver, so a query runs through a short-lived
  Java process (the DataDirect JDBC driver shipped in `priv/db_inspect/`) opened
  as a `Port`. The port is owned and supervised by a process this module spawns,
  so it lives and dies inside this release — the same BEAM, one deploy. Results
  stream back to the subscriber line-by-line as they arrive.

  This is deliberately minimal and read-only: `stream/2` refuses anything that
  isn't a single `SELECT` (defence in depth on top of the read-only DB login).

  Messages sent to the subscriber, tagged with the returned `ref`:

    * `{:db_row, ref, line}`      — one output line (header, row, or footer)
    * `{:db_done, ref, :ok}`      — the query finished cleanly
    * `{:db_done, ref, {:error, reason}}` — it failed / was refused
  """

  require Logger

  @max_line 1_048_576

  @doc """
  Run `sql` and stream results to `subscriber` (default: the caller). Returns a
  `ref` used to tag every message, or `{:error, :not_select}` if `sql` isn't a
  read-only single SELECT.
  """
  @spec stream(String.t(), pid(), keyword()) :: reference() | {:error, :not_select}
  def stream(sql, subscriber \\ self(), opts \\ []) when is_binary(sql) and is_pid(subscriber) do
    if select_only?(sql) do
      ref = make_ref()
      spawn(fn -> run(ref, subscriber, sql, opts) end)
      ref
    else
      {:error, :not_select}
    end
  end

  @doc "Whether `sql` is a single read-only SELECT (no `;`, no DML/DDL keywords)."
  @spec select_only?(String.t()) :: boolean()
  def select_only?(sql) do
    trimmed = sql |> String.trim() |> String.trim_trailing(";")
    upper = String.upcase(trimmed)

    String.starts_with?(upper, "SELECT") and
      not String.contains?(trimmed, ";") and
      not Regex.match?(
        ~r/\b(INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|TRUNCATE|GRANT|REVOKE|MERGE|CALL)\b/,
        upper
      )
  end

  @doc """
  Run `sql` and return the parsed result synchronously — for the in-app ETL, not
  the streaming console. Returns `{:ok, [row_map]}` where each row is a map of
  lowercased column name => string value, or `{:error, reason}`. Keep result sets
  small (aggregations); this buffers the whole result.
  """
  @spec query_rows(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def query_rows(sql, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    limit = Keyword.get(opts, :limit, 5_000_000)

    case stream(sql, self(), limit: limit) do
      ref when is_reference(ref) -> collect(ref, [], timeout)
      {:error, _} = err -> err
    end
  end

  defp collect(ref, acc, timeout) do
    receive do
      {:db_row, ^ref, line} -> collect(ref, [line | acc], timeout)
      {:db_done, ^ref, :ok} -> {:ok, parse(Enum.reverse(acc))}
      {:db_done, ^ref, {:error, reason}} -> {:error, reason}
    after
      timeout -> {:error, :timeout}
    end
  end

  # The Java Query tool prints `col | col`, a `---` rule, ` val | val` rows, then a
  # `(N rows)` footer. Turn that into a list of column=>value maps.
  defp parse([]), do: []

  defp parse([header | rest]) do
    keys = header |> split() |> Enum.map(&String.downcase/1)

    rest
    |> Enum.reject(&separator_or_footer?/1)
    |> Enum.map(fn line -> keys |> Enum.zip(split(line)) |> Map.new() end)
  end

  defp separator_or_footer?(line) do
    String.match?(line, ~r/^-+$/) or String.match?(line, ~r/^\(\d+ rows?\)$/)
  end

  defp split(line), do: line |> String.split(" | ") |> Enum.map(&String.trim/1)

  defp run(ref, subscriber, sql, opts) do
    cfg = config()
    limit = Keyword.get(opts, :limit, cfg.limit)

    port =
      Port.open({:spawn_executable, cfg.java}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, @max_line},
        args: ["-cp", cfg.classpath, "Query"],
        env: env(cfg, sql, limit)
      ])

    forward(ref, subscriber, port, "")
  rescue
    error ->
      send(subscriber, {:db_done, ref, {:error, Exception.message(error)}})
  end

  defp forward(ref, subscriber, port, acc) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        send(subscriber, {:db_row, ref, acc <> line})
        forward(ref, subscriber, port, "")

      {^port, {:data, {:noeol, chunk}}} ->
        forward(ref, subscriber, port, acc <> chunk)

      {^port, {:exit_status, 0}} ->
        if acc != "", do: send(subscriber, {:db_row, ref, acc})
        send(subscriber, {:db_done, ref, :ok})

      {^port, {:exit_status, status}} ->
        if acc != "", do: send(subscriber, {:db_row, ref, acc})
        send(subscriber, {:db_done, ref, {:error, "exit #{status}"}})
    end
  end

  defp env(cfg, sql, limit) do
    [
      {~c"FWDB_HOST", to_charlist(cfg.host)},
      {~c"FWDB_PORT", to_charlist(cfg.port)},
      {~c"FWDB_NAME", to_charlist(cfg.name)},
      {~c"FWDB_USER", to_charlist(cfg.user)},
      {~c"FWDB_PW", to_charlist(cfg.password || "")},
      {~c"FWDB_LIMIT", to_charlist(Integer.to_string(limit))},
      {~c"FWDB_SQL", to_charlist(sql)}
    ]
  end

  defp config do
    c = Application.get_env(:tragar_ai, __MODULE__, [])
    dir = Path.join(to_string(:code.priv_dir(:tragar_ai)), "db_inspect")

    %{
      java: Keyword.get(c, :java, "/opt/homebrew/opt/openjdk/bin/java"),
      classpath: Path.join(dir, "openedge.jar") <> ":" <> dir,
      host: Keyword.get(c, :host, "tragar-db.dovetail.co.za"),
      port: Keyword.get(c, :port, "9007"),
      name: Keyword.get(c, :name, "fwdb"),
      user: Keyword.get(c, :user, "fwsqllive"),
      password: Keyword.get(c, :password),
      limit: Keyword.get(c, :limit, 500)
    }
  end
end
