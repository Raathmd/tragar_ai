defmodule TragarAi.Freight.StatusesTest do
  use ExUnit.Case, async: true
  alias TragarAi.Freight.Statuses

  test "real waybill status codes (DEL is Deleted, not Delivered)" do
    codes = Statuses.waybill_codes()

    assert "POD" in codes and "DLV" in codes and "TOD" in codes and "OND" in codes and
             "DEL" in codes

    assert {"DEL", "Deleted"} in Statuses.waybill()
  end

  test "delivered?/deleted? from code and description" do
    assert Statuses.delivered?(%{"status_code" => "POD"})
    assert Statuses.delivered?(%{"status_code" => "DLV"})
    assert Statuses.delivered?(%{"status" => "Delivered"})
    refute Statuses.delivered?(%{"status_code" => "TOD"})
    refute Statuses.delivered?(%{"status_code" => "DEL"})

    assert Statuses.deleted?(%{"status_code" => "DEL"})
    refute Statuses.deleted?(%{"status_code" => "POD"})
  end
end
