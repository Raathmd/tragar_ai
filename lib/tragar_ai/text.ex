defmodule TragarAi.Text do
  @moduledoc """
  Small, deterministic text helpers.

  `tidy/1` strips *unnecessary* whitespace from ticket contents while keeping them
  readable. It only ever removes or collapses whitespace — it never touches a
  non-whitespace character — so reference numbers (waybills, quotes, accounts) are
  preserved exactly. This is the safe alternative to LLM summarisation, which can
  glue tokens together (e.g. "ITD0048113" -> "ITD0048113-Lusikisiki").
  """

  @doc """
  Collapse redundant whitespace in `text`, preserving words, line breaks, and
  paragraph structure:

    * CRLF / CR normalised to LF,
    * runs of spaces/tabs collapsed to a single space,
    * trailing spaces on each line removed,
    * three or more blank lines collapsed to a single blank line,
    * leading/trailing whitespace trimmed.

  Non-string input is returned unchanged.
  """
  @spec tidy(term()) :: term()
  def tidy(text) when is_binary(text) do
    text
    |> String.replace(~r/\r\n?/, "\n")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/ *\n/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  def tidy(other), do: other
end
