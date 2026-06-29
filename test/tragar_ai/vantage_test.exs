defmodule TragarAi.VantageTest do
  use TragarAi.DataCase, async: false

  @trip %{
    "id" => 450_574,
    "uuid" => "u1",
    "status" => "In Progress",
    "trip" => %{
      "referenceNumber" => "TRAGJHB-1928",
      "status" => "In Progress",
      "tripDistance" => 37.4,
      "vehicle" => %{"fleetNumber" => "TRA4T012"},
      "mobile" => %{"lastSeen" => %{"latitude" => -26.15, "longitude" => 28.22}},
      "stops" => [
        %{
          "node" => %{"externalReference" => "TRAGAR JHB"},
          "orders" => [%{"orderNumber" => "JHB-00099980"}],
          "tripStopExecution" => %{"revisedEta" => nil}
        },
        %{
          "node" => %{"externalReference" => "MEGA MAGIC"},
          "orders" => [],
          "tripStopExecution" => %{"revisedEta" => "2026-06-30T10:00:00Z"}
        }
      ]
    }
  }

  setup do
    Req.Test.set_req_test_to_shared()
    TragarAi.Vantage.TokenStore.invalidate()
    :persistent_term.erase({TragarAi.Vantage, :cache})

    Req.Test.stub(TragarAi.Vantage.Client, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/api/auth/login") ->
          # Token comes back under "auth_token" (the real Vantage shape).
          Req.Test.json(conn, %{"auth_token" => "vtok"})

        String.contains?(conn.request_path, "/master_trip/created_since") ->
          Req.Test.json(conn, %{"items" => [@trip], "hasNext" => false, "page" => 1, "pages" => 1})

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    :ok
  end

  test "configured? reflects credentials" do
    assert TragarAi.Vantage.configured?()
  end

  test "trips_since authenticates (auth_token) and returns the paginated items" do
    assert {:ok, [%{"trip" => %{"referenceNumber" => "TRAGJHB-1928"}}]} =
             TragarAi.Vantage.trips_since("20251208050018")
  end

  test "find_trip_by_waybill matches a stop order's orderNumber and normalizes it" do
    assert {:ok, slice} = TragarAi.Vantage.find_trip_by_waybill("JHB-00099980")
    assert slice["waybill_number"] == "JHB-00099980"
    assert slice["vehicle"] == "TRA4T012"
    assert slice["current_location"] == "-26.15, 28.22"
    assert slice["route"] == "TRAGAR JHB → MEGA MAGIC"
    assert slice["next_stop"] == "MEGA MAGIC"
    assert slice["eta"] == "2026-06-30T10:00:00Z"
  end

  test "the route adapter serves the normalized trip for a waybill" do
    assert {:ok, %{"waybill_number" => "JHB-00099980", "vehicle" => "TRA4T012"}} =
             TragarAi.Adapters.Vantage.fetch(:route, %{waybill: "JHB-00099980"})
  end

  test "vehicle_tracking adapter serves the trip for a fleet registration" do
    assert {:ok, %{"registration" => "TRA4T012", "current_location" => "-26.15, 28.22"}} =
             TragarAi.Adapters.Vantage.fetch(:vehicle_tracking, %{registration: "TRA4T012"})
  end

  test "an unknown waybill is not found" do
    assert {:error, :not_found} = TragarAi.Vantage.find_trip_by_waybill("NOPE-999")
  end
end
