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

    :ok
  end

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

  test "exposes the quote workflow descriptor as a tool", %{conn: conn} do
    resp = conn |> get(~p"/api/quotes/workflow") |> json_response(200)

    assert resp["name"] == "create_quote"
    assert resp["account_source"] == "freshdesk_request_body"
    keys = Enum.map(resp["steps"], & &1["key"])
    assert keys == ["service", "collection", "delivery", "goods"]
    assert Enum.all?(resp["steps"], &Map.has_key?(&1, "freightware_fields"))
    assert resp["runner"]["endpoint"] =~ "/api/quotes/intake"
  end

  test "requires an account in the body", %{conn: conn} do
    conn = post(conn, ~p"/api/quotes/intake", %{"ticket_id" => "FD-1"})
    assert json_response(conn, 400)["error"] =~ "account"
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
