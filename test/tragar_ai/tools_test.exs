defmodule TragarAi.ToolsTest do
  @moduledoc "Tests the account-scoped tool core against a stubbed FreightWare API."
  use TragarAi.DataCase, async: false

  alias TragarAi.Accounts
  alias TragarAi.Accounts.Registration
  alias TragarAi.Tools

  setup do
    Req.Test.set_req_test_to_shared()
    TragarAi.Dovetail.TokenStore.invalidate()

    {:ok, account} =
      Accounts.upsert_account(%{account_reference: "ACC1", email: "ops@acme.test", name: "Acme"})

    %{account: account, ctx: [scope: :account, account_reference: "ACC1"]}
  end

  defp stub_dovetail(handlers) do
    Req.Test.stub(TragarAi.Dovetail.Client, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/system/auth/login") ->
          conn
          |> Plug.Conn.put_resp_header("x-freightware", "tok")
          |> Req.Test.json(%{"response" => %{}})

        handler = find_handler(handlers, conn.request_path) ->
          handler.(conn)

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "not stubbed"})
      end
    end)
  end

  defp find_handler(handlers, path) do
    Enum.find_value(handlers, fn {suffix, fun} -> if String.contains?(path, suffix), do: fun end)
  end

  defp waybill_stub(account_ref) do
    [
      {"/waybills/WB123",
       fn conn ->
         Req.Test.json(conn, %{
           "response" => %{
             "waybillNumber" => "WB123",
             "statusDescription" => "Delivered",
             "statusCode" => "DEL",
             "accountReference" => account_ref,
             "consigneeName" => "Receiver Inc"
           }
         })
       end},
      {"/trackAndTrace",
       fn conn ->
         Req.Test.json(conn, %{
           "response" => %{
             "events" => [%{"eventDescription" => "Delivered", "eventDate" => "2026-06-15"}]
           }
         })
       end}
    ]
  end

  describe "track_shipment/2 (account scope)" do
    test "returns and caches a waybill owned by the caller's account", %{ctx: ctx} do
      stub_dovetail(waybill_stub("ACC1"))

      assert {:ok, result} = Tools.call("track_shipment", %{"waybill_number" => "WB123"}, ctx)
      assert result["status"] == "Delivered"
      assert result["account_reference"] == "ACC1"

      # cached
      assert {:ok, shipment} = TragarAi.Logistics.get_shipment_by_waybill("WB123")
      assert shipment.account_reference == "ACC1"
    end

    test "hides a waybill belonging to another account (404, not a leak)", %{ctx: ctx} do
      stub_dovetail(waybill_stub("OTHER"))

      assert {:error, %{code: :not_found}} =
               Tools.call("track_shipment", %{"waybill_number" => "WB123"}, ctx)

      # nothing cached for the caller
      assert {:ok, []} = TragarAi.Logistics.list_shipments_for_account("ACC1")
    end

    test "is forbidden for a partner-scoped key" do
      assert {:error, %{code: :forbidden}} =
               Tools.call("track_shipment", %{"waybill_number" => "WB123"}, scope: :partner)
    end

    test "second call is served from cache (no second live fetch)", %{ctx: ctx} do
      stub_dovetail(waybill_stub("ACC1"))
      assert {:ok, _} = Tools.call("track_shipment", %{"waybill_number" => "WB123"}, ctx)

      # Replace the stub so any live call would error; cache hit should still work.
      Req.Test.stub(TragarAi.Dovetail.Client, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "should not be called"})
      end)

      assert {:ok, result} = Tools.call("track_shipment", %{"waybill_number" => "WB123"}, ctx)
      assert result["status"] == "Delivered"
    end
  end

  describe "list_my_shipments/2" do
    test "returns only the caller's cached shipments", %{account: account, ctx: ctx} do
      TragarAi.Logistics.upsert_shipment!(%{
        waybill_number: "WB1",
        account_reference: "ACC1",
        status_description: "In transit",
        view: %{
          "waybill_number" => "WB1",
          "status" => "In transit",
          "account_reference" => "ACC1"
        }
      })

      # another account's shipment must not appear
      TragarAi.Logistics.upsert_shipment!(%{
        waybill_number: "WB2",
        account_reference: "OTHER",
        view: %{"waybill_number" => "WB2", "account_reference" => "OTHER"}
      })

      _ = account
      assert {:ok, %{"shipments" => shipments}} = Tools.call("list_my_shipments", %{}, ctx)
      assert Enum.map(shipments, & &1["waybill_number"]) == ["WB1"]
    end
  end

  test "provision_account_key issues a usable key", %{account: account} do
    assert {:ok, "tgr_" <> _ = key, _client} = Registration.provision_account_key(account)
    assert {:ok, client} = Registration.resolve(key)
    assert client.account_reference == "ACC1"
    assert client.scope == :account
  end

  test "unknown tool" do
    assert {:error, %{code: :unknown_tool}} = Tools.call("nope", %{})
  end
end
