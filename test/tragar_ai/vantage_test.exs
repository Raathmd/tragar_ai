defmodule TragarAi.VantageTest do
  use TragarAi.DataCase, async: false

  setup do
    Req.Test.set_req_test_to_shared()
    TragarAi.Vantage.TokenStore.invalidate()

    Req.Test.stub(TragarAi.Vantage.Client, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/api/auth/login") ->
          Req.Test.json(conn, %{"Authentication-Token" => "vtok"})

        String.contains?(conn.request_path, "/master_trip/created_since") ->
          Req.Test.json(conn, [%{"id" => 1, "waybill" => "4821", "status" => "en route"}])

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    :ok
  end

  test "configured? reflects credentials" do
    assert TragarAi.Vantage.configured?()
  end

  test "trips_since authenticates and returns trips" do
    assert {:ok, [%{"waybill" => "4821"}]} = TragarAi.Vantage.trips_since("20251208050018")
  end

  test "find_trip_by_waybill matches a recent trip" do
    assert {:ok, %{"waybill" => "4821", "status" => "en route"}} =
             TragarAi.Vantage.find_trip_by_waybill("4821")
  end

  test "the route adapter serves the trip for a waybill" do
    assert {:ok, %{"waybill" => "4821"}} =
             TragarAi.Adapters.Vantage.fetch(:route, %{waybill: "4821"})
  end
end
