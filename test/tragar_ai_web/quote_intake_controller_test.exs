defmodule TragarAiWeb.QuoteIntakeControllerTest do
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
                  %{"code" => "ECO", "name" => "Economy", "serviceClass" => "ECO"}
                ]
              }
            }
          })

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    # Freshdesk: the ticket's requester company maps to account ITD02.
    Req.Test.stub(TragarAi.Freshdesk.Client, fn conn ->
      cond do
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

  test "starts a guided quote conversation, deriving the account from Freshdesk", %{conn: conn} do
    body = %{
      "ticket_id" => "FD-#{System.unique_integer([:positive])}",
      "message" => "I want to ship pallets"
    }

    conn = post(conn, ~p"/api/quotes/intake", body)
    resp = json_response(conn, 200)

    assert resp["status"] == "collecting"
    assert resp["account"] == "ITD02"
    assert resp["reply"] =~ "service"
    refute resp["complete"]
  end

  test "exposes the quote workflow descriptor as a tool", %{conn: conn} do
    resp = conn |> get(~p"/api/quotes/workflow") |> json_response(200)

    assert resp["name"] == "create_quote"
    assert resp["account_source"] == "derived_from_freshdesk_ticket_company"
    keys = Enum.map(resp["steps"], & &1["key"])
    assert keys == ["service", "collection", "delivery", "goods"]
    assert Enum.all?(resp["steps"], &Map.has_key?(&1, "freightware_fields"))
    assert resp["runner"]["endpoint"] =~ "/api/quotes/intake"
  end

  test "requires a ticket_id", %{conn: conn} do
    conn = post(conn, ~p"/api/quotes/intake", %{"message" => "hi"})
    assert json_response(conn, 400)["error"] =~ "ticket_id"
  end

  describe "bearer auth (when a key is configured)" do
    setup do
      Application.put_env(:tragar_ai, :api_key, "s3cret")
      on_exit(fn -> Application.delete_env(:tragar_ai, :api_key) end)
    end

    test "rejects a missing/wrong token", %{conn: conn} do
      assert conn |> get(~p"/api/quotes/workflow") |> json_response(401)

      assert conn
             |> put_req_header("authorization", "Bearer nope")
             |> get(~p"/api/quotes/workflow")
             |> json_response(401)
    end

    test "accepts the correct bearer token", %{conn: conn} do
      resp =
        conn
        |> put_req_header("authorization", "Bearer s3cret")
        |> get(~p"/api/quotes/workflow")
        |> json_response(200)

      assert resp["name"] == "create_quote"
    end
  end
end
