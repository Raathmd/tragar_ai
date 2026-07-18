defmodule TragarAiWeb.DashboardLiveTest do
  use TragarAiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TragarAi.Assist

  setup :register_and_log_in_admin

  test "groups AI responses by ticket and shows the response time", %{conn: conn} do
    {:ok, _} =
      Assist.create_interaction(%{
        question: "Where is waybill DIS0124440?",
        intent: "load_status",
        source: "FreightWare",
        status: :drafted,
        ticket_id: "T-555",
        duration_ms: 1234,
        entities: %{"account" => "ITD02"}
      })

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Integration monitor"
    # ticket grouping + account + latency rendered
    assert html =~ "T-555"
    assert html =~ "ITD02"
    assert html =~ "1.2s"
  end

  test "ad-hoc interactions without a ticket_id are not listed", %{conn: conn} do
    {:ok, _} =
      Assist.create_interaction(%{
        question: "console lookup",
        status: :drafted
      })

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "No ticket-linked AI responses yet"
  end
end
