defmodule TragarAi.MarkdownTest do
  use ExUnit.Case, async: true

  alias TragarAi.Markdown

  test "renders links, bold, bullet lists and paragraphs" do
    html =
      Markdown.to_html("Status: **In transit**.\n\nSee [POD](http://x.co/p).\n\n- one\n- two")

    assert html =~ "<strong>In transit</strong>"
    assert html =~ ~s(<a href="http://x.co/p">POD</a>)
    assert html =~ "<ul><li>one</li><li>two</li></ul>"
    assert html =~ "<p>"
  end

  test "escapes HTML in the source text (safe for raw rendering)" do
    html = Markdown.to_html("a < b & c <script>x</script>")

    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;"
  end

  test "safe on non-binary / blank input" do
    assert Markdown.to_html(nil) == ""
    assert Markdown.to_html("") == ""
  end
end
