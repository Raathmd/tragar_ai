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

        String.contains?(conn.request_path, "/waybills/DIS0124440") ->
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

    TragarAi.DataCase.warm_engine_sources()
    :ok
  end

  test "accepts the webhook and returns 202 immediately (work runs async)", %{conn: conn} do
    # The assist loop is slow; the webhook must not make Freshdesk wait on it. The
    # answer is delivered as a ticket note — see TicketResponderTest for that path.
    body = %{
      "ticket_id" => "55",
      "subject" => "Delivery query",
      "description" => "Where is load DIS0124440?"
    }

    resp = conn |> post(~p"/api/tickets/answer", body) |> json_response(202)

    assert resp["status"] == "accepted"
    assert resp["ticket_id"] == "55"
  end

  test "accepts a ticket_id with no content (the responder fetches the thread)", %{conn: conn} do
    # The sidebar app fires /answer with just the ticket_id (+ chosen attachments);
    # content is optional now that TicketResponder pulls the full thread itself.
    resp = conn |> post(~p"/api/tickets/answer", %{"ticket_id" => "55"}) |> json_response(202)
    assert resp["ticket_id"] == "55"
  end

  test "requires a ticket_id", %{conn: conn} do
    resp = conn |> post(~p"/api/tickets/answer", %{}) |> json_response(400)
    assert resp["error"] =~ "ticket_id"
  end

  test "lists only the readable attachments (images and other types omitted)", %{conn: conn} do
    Req.Test.stub(TragarAi.Freshdesk.Client, fn conn ->
      if String.contains?(conn.request_path, "/tickets/") do
        Req.Test.json(conn, %{
          "id" => 55,
          "attachments" => [
            %{
              "id" => 7,
              "name" => "loads.csv",
              "content_type" => "text/csv",
              "size" => 12,
              "attachment_url" => "https://f/loads.csv"
            },
            %{
              "id" => 8,
              "name" => "photo.png",
              "content_type" => "image/png",
              "size" => 99,
              "attachment_url" => "https://f/photo.png"
            }
          ]
        })
      else
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    resp = conn |> get(~p"/api/tickets/55/attachments") |> json_response(200)
    names = Enum.map(resp["attachments"], & &1["name"])
    assert "loads.csv" in names
    refute "photo.png" in names
  end
end
