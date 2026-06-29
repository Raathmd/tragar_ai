defmodule TragarAiWeb.TicketAnswerControllerTest do
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

        String.contains?(conn.request_path, "/trackAndTrace") ->
          Req.Test.json(conn, %{"response" => %{"esTrackAndTrace" => %{"TrackAndTrace" => []}}})

        String.contains?(conn.request_path, "/waybills/4821") ->
          Req.Test.json(conn, %{
            "response" => %{
              "esWaybills" => %{
                "Waybills" => [%{"waybillNumber" => "4821", "statusDescription" => "In transit"}]
              }
            }
          })

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    Req.Test.stub(TragarAi.Freshdesk.Client, fn conn ->
      cond do
        String.contains?(conn.request_path, "/notes") ->
          Req.Test.json(conn, %{"id" => 99})

        String.ends_with?(conn.request_path, "/ticket_fields") ->
          Req.Test.json(conn, [
            %{"name" => "subject", "label" => "Subject", "type" => "default_subject"},
            %{
              "name" => "cf_waybill_status",
              "label" => "Waybill status",
              "type" => "custom_dropdown",
              "choices" => ["In transit", "Delivered"]
            },
            %{"name" => "cf_waybill_number", "label" => "Waybill number", "type" => "custom_text"}
          ])

        String.contains?(conn.request_path, "/companies/") ->
          Req.Test.json(conn, %{
            "id" => 10,
            "custom_fields" => %{"freightware_accounts" => "ITD02"}
          })

        String.contains?(conn.request_path, "/tickets/") ->
          Req.Test.json(conn, %{"id" => 1, "company_id" => 10})

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    :ok
  end

  test "interprets the ticket, fetches the fact, and composes an answer", %{conn: conn} do
    body = %{
      "ticket_id" => "55",
      "subject" => "Delivery query",
      "description" => "Where is load 4821?",
      "post_reply" => true
    }

    resp = conn |> post(~p"/api/tickets/answer", body) |> json_response(200)

    assert resp["answer"] =~ "In transit"
    assert resp["account"] == "ITD02"
    assert resp["intent"] == "load_status"

    # Custom ticket fields pre-filled from the retrieved facts (assignment untouched).
    assert resp["filled_fields"]["cf_waybill_number"] == "4821"
    assert resp["filled_fields"]["cf_waybill_status"] == "In transit"
  end

  test "uses the account injected in the webhook body over the FD-derived one", %{conn: conn} do
    # The FD company stub would resolve ITD02; the body asserts ITD99, so the
    # webhook-supplied value must win (no API derivation).
    body = %{
      "ticket_id" => "55",
      "subject" => "Delivery query",
      "description" => "Where is load 4821?",
      "account" => "ITD99"
    }

    resp = conn |> post(~p"/api/tickets/answer", body) |> json_response(200)

    assert resp["account"] == "ITD99"
    assert resp["answer"] =~ "In transit"
  end

  test "requires ticket content", %{conn: conn} do
    resp = conn |> post(~p"/api/tickets/answer", %{"ticket_id" => "55"}) |> json_response(400)
    assert resp["error"] =~ "content"
  end
end
