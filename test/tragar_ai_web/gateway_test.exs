defmodule TragarAiWeb.GatewayTest do
  @moduledoc "End-to-end tests for the REST + MCP gateway with account scoping."
  use TragarAiWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  alias TragarAi.Accounts
  alias TragarAi.Accounts.Registration

  @partner "test-partner-key"

  setup do
    Req.Test.set_req_test_to_shared()
    TragarAi.Dovetail.TokenStore.invalidate()

    {:ok, account} =
      Accounts.upsert_account(%{account_reference: "ACC1", email: "ops@acme.test", name: "Acme"})

    {:ok, key, _client} = Registration.provision_account_key(account)

    Req.Test.stub(TragarAi.Dovetail.Client, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/system/auth/login") ->
          conn
          |> Plug.Conn.put_resp_header("x-freightware", "tok")
          |> Req.Test.json(%{"response" => %{}})

        String.contains?(conn.request_path, "/waybills/WB999") ->
          Req.Test.json(conn, %{
            "response" => %{
              "waybillNumber" => "WB999",
              "statusDescription" => "In transit",
              "accountReference" => "ACC1"
            }
          })

        String.contains?(conn.request_path, "/trackAndTrace") ->
          Req.Test.json(conn, %{
            "response" => %{"events" => [%{"eventDescription" => "In transit"}]}
          })

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    %{account_key: key}
  end

  defp auth(conn, key), do: put_req_header(conn, "authorization", "Bearer #{key}")

  describe "auth" do
    test "rejects missing key", %{conn: conn} do
      assert conn |> get(~p"/api/v1/tools") |> json_response(401)
    end

    test "rejects bad key", %{conn: conn} do
      assert conn |> auth("nope") |> get(~p"/api/v1/tools") |> json_response(401)
    end
  end

  describe "REST tools (account key)" do
    test "lists tools", %{conn: conn, account_key: key} do
      body = conn |> auth(key) |> get(~p"/api/v1/tools") |> json_response(200)
      assert "track_shipment" in Enum.map(body["tools"], & &1["name"])
    end

    test "tracks an owned shipment", %{conn: conn, account_key: key} do
      body =
        conn
        |> auth(key)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/tools/track_shipment", %{"waybill_number" => "WB999"})
        |> json_response(200)

      assert body["result"]["status"] == "In transit"
    end

    test "partner key may not call customer tools", %{conn: conn} do
      body =
        conn
        |> auth(@partner)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/tools/track_shipment", %{"waybill_number" => "WB999"})
        |> json_response(403)

      assert body["error"]["code"] == "forbidden"
    end
  end

  describe "access requests (partner key)" do
    test "matching account emails a magic link, returns 202", %{conn: conn} do
      body =
        conn
        |> auth(@partner)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/access-requests", %{
          "account_reference" => "ACC1",
          "email" => "ops@acme.test"
        })
        |> json_response(202)

      assert body["status"] == "accepted"
      assert_email_sent(fn email -> assert email.text_body =~ "/activate/" end)
    end

    test "account-scoped key may not request access", %{conn: conn, account_key: key} do
      assert conn
             |> auth(key)
             |> put_req_header("content-type", "application/json")
             |> post(~p"/api/v1/access-requests", %{
               "account_reference" => "ACC1",
               "email" => "ops@acme.test"
             })
             |> json_response(403)
    end
  end

  describe "OpenAPI" do
    test "served without auth and lists tool paths", %{conn: conn} do
      body = conn |> get(~p"/api/openapi.json") |> json_response(200)
      assert body["openapi"] =~ "3."
      assert Map.has_key?(body["paths"], "/api/v1/tools/track_shipment")
    end
  end

  describe "MCP (account key)" do
    test "tools/call tracks an owned shipment", %{conn: conn, account_key: key} do
      body =
        conn
        |> auth(key)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "track_shipment", "arguments" => %{"waybill_number" => "WB999"}}
        })
        |> json_response(200)

      refute body["result"]["isError"]
      assert body["result"]["structuredContent"]["status"] == "In transit"
    end

    test "initialize works", %{conn: conn, account_key: key} do
      body =
        conn
        |> auth(key)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{}
        })
        |> json_response(200)

      assert body["result"]["serverInfo"]["name"] == "tragar-freightware-gateway"
    end
  end

  describe "activation page" do
    test "valid token reveals the key once", %{conn: conn} do
      {:ok, _account} =
        Accounts.upsert_account(%{account_reference: "ACC2", email: "two@acme.test"})

      :ok = Registration.request_access("ACC2", "two@acme.test")
      token = captured_token()

      html = conn |> get(~p"/activate/#{token}") |> html_response(200)
      assert html =~ "API access activated"
      assert html =~ "tgr_"
    end

    test "invalid token shows error", %{conn: conn} do
      assert conn |> get(~p"/activate/bogus") |> html_response(410) =~ "invalid or expired"
    end
  end

  defp captured_token do
    assert_email_sent(fn email ->
      assert [_, token] = Regex.run(~r{/activate/([^\s"]+)}, email.text_body)
      send(self(), {:token, token})
    end)

    receive do
      {:token, token} -> token
    after
      0 -> flunk("no token")
    end
  end
end
