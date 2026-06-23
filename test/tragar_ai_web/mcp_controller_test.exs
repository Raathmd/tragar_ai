defmodule TragarAiWeb.McpControllerTest do
  use TragarAiWeb.ConnCase, async: false

  setup do
    Req.Test.set_req_test_to_shared()
    TragarAi.Dovetail.TokenStore.invalidate()

    Req.Test.stub(TragarAi.Dovetail.Client, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/system/auth/login") ->
          conn
          |> Plug.Conn.put_resp_header("x-freightware", "tok")
          |> Req.Test.json(%{"response" => %{}})

        String.contains?(conn.request_path, "/serviceTypes") ->
          Req.Test.json(conn, %{
            "response" => %{
              "esServiceTypes" => %{
                "ServiceTypes" => [
                  %{"serviceTypeCode" => "ECO", "serviceTypeDescription" => "Economy"}
                ]
              }
            }
          })

        String.contains?(conn.request_path, "/trackAndTrace") ->
          Req.Test.json(conn, %{"response" => %{"esTrackAndTrace" => %{"TrackAndTrace" => []}}})

        String.contains?(conn.request_path, "/waybills/") ->
          Req.Test.json(conn, %{
            "response" => %{
              "esWaybills" => %{
                "Waybills" => [
                  %{
                    "waybillNumber" => "WBX",
                    "accountReference" => "ITD02",
                    "statusDescription" => "In transit"
                  }
                ]
              }
            }
          })

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    Req.Test.stub(TragarAi.Freshdesk.Client, fn conn ->
      cond do
        String.contains?(conn.request_path, "/companies/") ->
          Req.Test.json(conn, %{"id" => 10, "custom_fields" => %{"cf_account" => "ITD02"}})

        String.contains?(conn.request_path, "/tickets/") ->
          Req.Test.json(conn, %{"id" => 1, "company_id" => 10})

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    :ok
  end

  defp rpc(method, params, headers \\ []) do
    conn =
      Enum.reduce(headers, build_conn(), fn {k, v}, c -> put_req_header(c, k, v) end)

    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
    post(conn, ~p"/mcp", body)
  end

  test "tool calls require an MCP session (must initialize first)" do
    resp = rpc("tools/list", %{}) |> json_response(200)
    assert resp["error"]["code"] == -32000
    assert resp["error"]["message"] =~ "initialize"
  end

  test "initialize issues a session; then tools/list and quote_intake work" do
    init = rpc("initialize", %{"protocolVersion" => "2025-06-18", "capabilities" => %{}})
    assert json_response(init, 200)["result"]["serverInfo"]["name"] == "tragar-quote-intake"
    [session] = get_resp_header(init, "mcp-session-id")
    hdr = [{"mcp-session-id", session}]

    # tools/list — quote tools plus the read/fact tools.
    tools = rpc("tools/list", %{}, hdr) |> json_response(200)
    names = Enum.map(tools["result"]["tools"], & &1["name"])
    assert "quote_workflow" in names and "quote_intake" in names

    assert "load_status" in names and "pod" in names and "quote_lookup" in names and
             "service_types" in names

    # A read tool returns the live facts.
    st =
      rpc("tools/call", %{"name" => "service_types", "arguments" => %{}}, hdr)
      |> json_response(200)

    refute st["result"]["isError"]
    assert hd(st["result"]["content"])["text"] =~ "Economy"

    # quote_intake derives the account from Freshdesk and asks the first question.
    call =
      rpc(
        "tools/call",
        %{
          "name" => "quote_intake",
          "arguments" => %{
            "ticket_id" => "FD-#{System.unique_integer([:positive])}",
            "message" => "hi"
          }
        },
        hdr
      )
      |> json_response(200)

    result = call["result"]
    refute result["isError"]
    assert hd(result["content"])["text"] =~ "service"
    assert result["structuredContent"]["status"] == "collecting"
    assert result["structuredContent"]["account"] == "ITD02"
  end

  test "read tools enforce account scope from the ticket" do
    init = rpc("initialize", %{"protocolVersion" => "2025-06-18", "capabilities" => %{}})
    [session] = get_resp_header(init, "mcp-session-id")
    hdr = [{"mcp-session-id", session}]

    # No ticket_id → no validated scope → an account-bearing fact is refused.
    no_scope =
      rpc("tools/call", %{"name" => "load_status", "arguments" => %{"waybill" => "WBX"}}, hdr)
      |> json_response(200)

    assert no_scope["result"]["isError"]
    assert hd(no_scope["result"]["content"])["text"] =~ "Not authorized"

    # With a ticket whose company maps to ITD02 (= the waybill's account), allowed.
    scoped =
      rpc(
        "tools/call",
        %{"name" => "load_status", "arguments" => %{"waybill" => "WBX", "ticket_id" => "55"}},
        hdr
      )
      |> json_response(200)

    refute scoped["result"]["isError"]
    assert hd(scoped["result"]["content"])["text"] =~ "WBX"
  end
end
