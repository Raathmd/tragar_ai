defmodule TragarAi.Markdown do
  @moduledoc """
  Minimal, **safe** markdown→HTML for the model's answers — shared by the
  Freshdesk note (`Assist.TicketResponder`) and the console/chat UIs so an answer
  reads the same everywhere: clickable links, bold, bullet lists, and paragraphs.

  Source text is HTML-escaped first (the model's output is untrusted markup), then
  a small set of markdown constructs is rendered. The result is safe to drop into
  a Freshdesk note body or a LiveView via `raw/1`.
  """

  @link_re ~r/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/
  @bold_re ~r/\*\*([^*]+)\*\*/
  @bullet_re ~r/^\s*[-*•]\s+/

  @doc "Render the model's markdown-ish answer as safe HTML."
  @spec to_html(term()) :: String.t()
  def to_html(text) when is_binary(text) do
    text
    |> escape()
    |> String.split(~r/\n{2,}/, trim: true)
    |> Enum.map_join("\n", &block/1)
  end

  def to_html(_), do: ""

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  # A block is either a bullet list (every line is a bullet) or a paragraph with
  # single newlines rendered as line breaks.
  defp block(block) do
    lines = String.split(block, "\n")

    if Enum.all?(lines, &bullet?/1) do
      "<ul>#{Enum.map_join(lines, "", &"<li>#{inline(strip_bullet(&1))}</li>")}</ul>"
    else
      "<p>#{Enum.map_join(lines, "<br>\n", &inline/1)}</p>"
    end
  end

  defp bullet?(line), do: Regex.match?(@bullet_re, line)
  defp strip_bullet(line), do: Regex.replace(@bullet_re, line, "")

  # Inline markdown → HTML: [text](url) links and **bold**.
  defp inline(text) do
    text
    |> then(&Regex.replace(@link_re, &1, ~s(<a href="\\2">\\1</a>)))
    |> then(&Regex.replace(@bold_re, &1, "<strong>\\1</strong>"))
  end
end
