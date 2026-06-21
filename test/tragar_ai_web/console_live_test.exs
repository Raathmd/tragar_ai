defmodule TragarAiWeb.ConsoleLiveTest do
  use TragarAiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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
          Req.Test.json(conn, %{
            "response" => %{"esTrackAndTrace" => %{"TrackAndTrace" => []}}
          })

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

    :ok
  end

  test "renders the console", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/console")
    assert html =~ "Support Assist"
  end

  test "asking drafts an answer the agent can relay", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/console")

    html =
      view |> form("form[phx-submit=ask]", %{question: "Where is load 4821?"}) |> render_submit()

    assert html =~ "In transit"
    assert html =~ "FreightWare"

    html =
      view
      |> form("form[phx-submit=relay]", %{final_answer: "It is in transit."})
      |> render_submit()

    assert html =~ "relayed"
  end
end
