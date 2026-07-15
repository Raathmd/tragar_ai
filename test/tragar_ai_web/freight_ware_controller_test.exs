defmodule TragarAiWeb.FreightWareControllerTest do
  use TragarAiWeb.ConnCase, async: false

  test "POST /fw/login re-authenticates and redirects back with a flash", %{conn: conn} do
    Req.Test.set_req_test_to_shared()

    Req.Test.stub(TragarAi.Dovetail.Client, fn c ->
      c
      |> Plug.Conn.put_resp_header("x-freightware", "tok")
      |> Req.Test.json(%{"response" => %{}})
    end)

    TragarAi.Dovetail.TokenStore.invalidate()

    conn =
      conn |> put_req_header("referer", "http://localhost/collections") |> post(~p"/fw/login")

    # Returns to the page it was clicked from (path only).
    assert redirected_to(conn) == "/collections"
    # A flash is always set (either success or the exact error).
    assert Phoenix.Flash.get(conn.assigns.flash, :info) ||
             Phoenix.Flash.get(conn.assigns.flash, :error)
  end
end
