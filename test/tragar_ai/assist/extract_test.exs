defmodule TragarAi.Assist.ExtractTest do
  use ExUnit.Case, async: true

  alias TragarAi.Assist.Extract

  test "extracts CSV rows to text (by MIME)" do
    csv = "waybill,status\nITD0048113,In transit\n"
    assert {:ok, text} = Extract.extract(csv, "text/csv", "loads.csv")
    assert text =~ "ITD0048113"
    assert text =~ "In transit"
  end

  test "dispatches by extension when the MIME type is generic" do
    assert {:ok, text} = Extract.extract("a,b\n1,2\n", "application/octet-stream", "data.csv")
    assert text =~ "1 | 2"
  end

  test "skips unsupported types" do
    assert {:skip, :unsupported} = Extract.extract(<<0, 1, 2>>, "image/png", "photo.png")
  end

  test "skips when there's no extractable text" do
    assert {:skip, :empty} = Extract.extract("", "text/csv", "empty.csv")
  end

  test "supported?/2 reflects the extractable types" do
    assert Extract.supported?("text/csv", "x.csv")
    assert Extract.supported?("application/pdf", "x.pdf")
    assert Extract.supported?("", "x.xlsx")
    refute Extract.supported?("image/png", "x.png")
  end
end
