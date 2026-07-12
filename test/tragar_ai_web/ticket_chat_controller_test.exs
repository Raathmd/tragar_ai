defmodule TragarAiWeb.TicketChatControllerTest do
  use TragarAiWeb.ConnCase, async: false

  import TragarAi.FreightWareStub

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
          Req.Test.json(conn, %{"response" => %{"esTrackAndTrace" => %{"TrackAndTrace" => []}}})

        waybill_number?(conn, "DIS0124440") ->
          Req.Test.json(conn, %{
            "response" => %{
              "esWaybills" => %{
                "Waybills" => [
                  %{"waybillNumber" => "DIS0124440", "statusDescription" => "In transit"}
                ]
              }
            }
          })

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    # Freshdesk — requester's company carries the entitled account ITD02.
    Req.Test.stub(TragarAi.Freshdesk.Client, fn conn ->
      cond do
        String.contains?(conn.request_path, "/companies/") ->
          Req.Test.json(conn, %{
            "id" => 10,
            "custom_fields" => %{"freightware_accounts" => "ITD02"}
          })

        String.contains?(conn.request_path, "/tickets/") ->
          Req.Test.json(conn, %{"id" => 55, "company_id" => 10})

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    TragarAi.DataCase.warm_engine_sources()
    :ok
  end

  test "answers a ticket question synchronously, scoped to the entitled account", %{conn: conn} do
    body = %{"ticket_id" => "55", "message" => "Where is load DIS0124440?"}
    resp = conn |> post(~p"/api/tickets/chat", body) |> json_response(200)

    assert resp["ticket_id"] == "55"
    assert resp["reply"] =~ "In transit"
    assert resp["resolved"] == true
    assert resp["accounts"] == ["ITD02"]
  end

  test "requires ticket_id and message", %{conn: conn} do
    resp = conn |> post(~p"/api/tickets/chat", %{"ticket_id" => "55"}) |> json_response(400)
    assert resp["error"] =~ "message"
  end
end
