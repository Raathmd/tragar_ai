defmodule TragarAiWeb.DashboardLiveTest do
  use TragarAiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TragarAi.Assist

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

  test "the reasoning-model control switches the active model", %{conn: conn} do
    original = Application.get_env(:tragar_ai, TragarAi.CoreAI)

    Application.put_env(:tragar_ai, TragarAi.CoreAI,
      mode: :stub,
      model: "qwen3:14b",
      reason_model: "qwen3:30b-a3b"
    )

    on_exit(fn ->
      Application.put_env(:tragar_ai, TragarAi.CoreAI, original)
      :persistent_term.erase({TragarAi.CoreAI, :active_reason_model})
    end)

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Reason free"
    assert html =~ "qwen3:30b-a3b"

    view |> element("button", "Deep · qwen3:30b-a3b") |> render_click()
    assert TragarAi.CoreAI.reasoning().active == "qwen3:30b-a3b"

    view |> element("button", "Fast · qwen3:14b") |> render_click()
    assert TragarAi.CoreAI.reasoning().active == "qwen3:14b"
  end
end
