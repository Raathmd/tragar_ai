defmodule TragarAiWeb.QuoteIntakeControllerTest do
  use TragarAiWeb.ConnCase, async: true

  test "starts a guided quote conversation from a Freshdesk ticket", %{conn: conn} do
    body = %{
      "account" => "ITD02",
      "ticket_id" => "FD-#{System.unique_integer([:positive])}",
      "message" => "I want to ship pallets"
    }

    conn = post(conn, ~p"/api/quotes/intake", body)
    resp = json_response(conn, 200)

    assert resp["status"] == "collecting"
    assert resp["reply"] =~ "service"
    refute resp["complete"]
  end

  test "requires an account in the body", %{conn: conn} do
    conn = post(conn, ~p"/api/quotes/intake", %{"ticket_id" => "FD-1"})
    assert json_response(conn, 400)["error"] =~ "account"
  end
end
