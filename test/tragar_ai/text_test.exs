defmodule TragarAi.TextTest do
  use ExUnit.Case, async: true

  alias TragarAi.Text

  test "collapses runs of spaces and tabs to a single space" do
    assert Text.tidy("a    b\t\tc") == "a b c"
  end

  test "caps blank lines, strips trailing spaces, and trims" do
    assert Text.tidy("\n\nfoo\n\n\n\nbar  \n\n") == "foo\n\nbar"
  end

  test "normalises CRLF to LF" do
    assert Text.tidy("a\r\nb\rc") == "a\nb\nc"
  end

  test "never mangles a reference — the exact case that broke the old distiller" do
    out = Text.tidy("ITD0048113    delivery   to   Lusikisiki")
    assert out == "ITD0048113 delivery to Lusikisiki"
    assert out =~ "ITD0048113"
  end

  test "non-string input is returned unchanged" do
    assert Text.tidy(nil) == nil
    assert Text.tidy(123) == 123
  end
end
