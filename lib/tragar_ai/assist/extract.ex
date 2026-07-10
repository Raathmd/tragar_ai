defmodule TragarAi.Assist.Extract do
  @moduledoc """
  Deterministic, MODEL-FREE text extraction from ticket attachments, so a
  waybill/reference inside a spreadsheet or PDF flows into the assist prompt.

  - **CSV / Excel** — parsed purely in memory (`nimble_csv`, `xlsx_reader`);
    never touches disk.
  - **PDF** — `pdftotext` (poppler) via a temp file that is deleted immediately,
    even on error (the only path that briefly touches disk). If `pdftotext` isn't
    installed the PDF is reported as unavailable, not fatal.
  - **Images / unknown** — skipped (listed in the UI, not read).

  Guards: inputs over `@max_bytes` are skipped; output text is truncated to
  `@max_text` so a large document can't blow the prompt.
  """

  alias NimbleCSV.RFC4180, as: CSV

  @max_bytes 20 * 1024 * 1024
  @max_text 50_000

  @type result :: {:ok, String.t()} | {:skip, atom()} | {:error, term()}

  @doc "Extract text from `bin`, dispatching on MIME type then filename extension."
  @spec extract(binary(), String.t(), String.t()) :: result()
  def extract(bin, content_type, name) when is_binary(bin) do
    if byte_size(bin) > @max_bytes do
      {:skip, :too_large}
    else
      bin |> do_extract(kind(content_type, name)) |> cap()
    end
  end

  @doc "Whether this attachment's type is one we can extract (for the UI list)."
  @spec supported?(String.t(), String.t()) :: boolean()
  def supported?(content_type, name), do: kind(content_type, name) != :unsupported

  # Decide the extractor from MIME first, then the filename extension.
  defp kind(content_type, name) do
    ct = String.downcase(content_type || "")
    ext = name |> to_string() |> Path.extname() |> String.downcase()

    cond do
      ct =~ "csv" or ext == ".csv" -> :csv
      ct =~ "spreadsheetml" or ext in [".xlsx", ".xlsm"] -> :xlsx
      ct =~ "pdf" or ext == ".pdf" -> :pdf
      true -> :unsupported
    end
  end

  defp cap({:ok, text}) do
    case String.trim(text) do
      "" -> {:skip, :empty}
      trimmed -> {:ok, String.slice(trimmed, 0, @max_text)}
    end
  end

  defp cap(other), do: other

  defp do_extract(bin, :csv) do
    rows = CSV.parse_string(bin, skip_headers: false)
    {:ok, Enum.map_join(rows, "\n", &Enum.join(&1, " | "))}
  rescue
    e -> {:error, {:csv, Exception.message(e)}}
  end

  defp do_extract(bin, :xlsx) do
    with {:ok, package} <- XlsxReader.open(bin, source: :binary),
         {:ok, sheets} <- XlsxReader.sheets(package) do
      text =
        Enum.map_join(sheets, "\n\n", fn {sheet, rows} ->
          body = Enum.map_join(rows, "\n", fn row -> Enum.map_join(row, " | ", &to_string/1) end)
          "# #{sheet}\n#{body}"
        end)

      {:ok, text}
    else
      {:error, reason} -> {:error, {:xlsx, reason}}
    end
  rescue
    e -> {:error, {:xlsx, Exception.message(e)}}
  end

  defp do_extract(bin, :pdf) do
    case pdftotext() do
      nil ->
        {:error, :pdftotext_unavailable}

      exe ->
        tmp = Path.join(System.tmp_dir!(), "tragar-att-#{System.unique_integer([:positive])}.pdf")

        try do
          File.write!(tmp, bin)

          # "-" = write extracted text to stdout. stderr is left uncaptured so it
          # can't pollute the text.
          case System.cmd(exe, [tmp, "-"]) do
            {out, 0} -> {:ok, out}
            {_out, code} -> {:error, {:pdftotext, code}}
          end
        after
          File.rm(tmp)
        end
    end
  rescue
    e -> {:error, {:pdf, Exception.message(e)}}
  end

  defp do_extract(_bin, :unsupported), do: {:skip, :unsupported}

  # Resolve pdftotext robustly — a launchd service PATH may miss Homebrew. Config
  # override first, then PATH, then common install locations.
  defp pdftotext do
    Application.get_env(:tragar_ai, :pdftotext_path) ||
      System.find_executable("pdftotext") ||
      Enum.find(
        ["/opt/homebrew/bin/pdftotext", "/usr/local/bin/pdftotext", "/usr/bin/pdftotext"],
        &File.exists?/1
      )
  end
end
