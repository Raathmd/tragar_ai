defmodule TragarAi.FreightTest do
  use TragarAi.DataCase, async: false

  alias TragarAi.Freight
  alias TragarAi.Logistics
  alias TragarAi.Logistics.Cache

  setup do
    Req.Test.set_req_test_to_shared()
    TragarAi.Dovetail.TokenStore.invalidate()

    Req.Test.stub(TragarAi.Dovetail.Client, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/system/auth/login") ->
          conn
          |> Plug.Conn.put_resp_header("x-freightware", "tok")
          |> Req.Test.json(%{"response" => %{}})

        String.contains?(conn.request_path, "/trackAndTrace") ->
          Req.Test.json(conn, %{
            "response" => %{
              "esTrackAndTrace" => %{"TrackAndTrace" => [%{"eventDescription" => "In transit"}]}
            }
          })

        String.contains?(conn.request_path, "/waybills/WB7") ->
          Req.Test.json(conn, %{
            "response" => %{
              "esWaybills" => %{
                "Waybills" => [
                  %{
                    "waybillNumber" => "WB7",
                    "statusDescription" => "In transit",
                    "accountReference" => "ACC9"
                  }
                ]
              }
            }
          })

        String.contains?(conn.request_path, "/waybills/") ->
          Req.Test.json(conn, %{
            "response" => %{
              "esWaybills" => %{
                "Waybills" => [%{"waybillNumber" => "WB7"}, %{"waybillNumber" => "WB8"}],
                "wtPaging" => [%{"totalRecords" => "2"}]
              }
            }
          })

        String.contains?(conn.request_path, "/quotes/Q1") ->
          Req.Test.json(conn, %{
            "response" => %{
              "esQuotes" => %{
                "Quotes" => [
                  %{"quoteNumber" => "Q1", "serviceType" => "ON", "statusDescription" => "Open"}
                ]
              }
            }
          })

        String.contains?(conn.request_path, "/baseData/serviceTypes") ->
          Req.Test.json(conn, %{
            "response" => %{
              "esServiceTypes" => %{
                "ServiceTypes" => [
                  %{"serviceTypeCode" => "ON", "serviceTypeDescription" => "Overnight"}
                ]
              }
            }
          })

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"response" => %{}})
      end
    end)

    :ok
  end

  test "search_waybills returns normalized waybills + paging" do
    assert {:ok, %{"waybills" => waybills, "paging" => paging}} =
             Freight.search_waybills(%{account_reference: "ACC9"})

    assert Enum.map(waybills, & &1["waybill_number"]) == ["WB7", "WB8"]
    assert paging["total_records"] == "2"
  end

  test "get_quote returns a normalized quote" do
    assert {:ok, %{"quote_number" => "Q1", "service_type" => "ON"}} = Freight.get_quote("Q1")
  end

  test "service_types returns reference data" do
    assert {:ok, [%{"code" => "ON", "name" => "Overnight"}]} = Freight.service_types()
  end

  describe "Cache" do
    test "fetch_shipment caches the waybill as a Shipment resource" do
      assert {:ok, %{"waybill" => wb}} = Cache.fetch_shipment("WB7")
      assert wb["status_description"] == "In transit"

      assert {:ok, shipment} = Logistics.get_shipment_by_waybill("WB7")
      assert shipment.account_reference == "ACC9"
      assert shipment.status_description == "In transit"
    end

    test "second fetch is served from the cache (no live call needed)" do
      assert {:ok, _} = Cache.fetch_shipment("WB7")

      # Replace the stub so any live call errors; fresh cache hit should still succeed.
      Req.Test.stub(TragarAi.Dovetail.Client, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end)

      assert {:ok, %{"waybill" => wb}} = Cache.fetch_shipment("WB7")
      assert wb["waybill_number"] == "WB7"
    end
  end
end
