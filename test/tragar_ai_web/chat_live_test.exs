defmodule TragarAiWeb.ChatLiveTest do
  use TragarAiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "renders the chat and answers a prompt", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/chat")
    assert html =~ "Local AI chat"

    html =
      view
      |> form("form[phx-submit=send]", %{message: "hello there"})
      |> render_submit()

    # The prompt is echoed and the local AI's (safe-fail) answer is shown.
    assert html =~ "hello there"
    assert html =~ "failed"
  end

  test "the 'reason freely' toggle answers instead of refusing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/chat")

    view |> element("input[phx-click=toggle_reasoning]") |> render_click()

    html =
      view
      |> form("form[phx-submit=send]", %{message: "hello there"})
      |> render_submit()

    assert html =~ "reasoned"
    refute html =~ "failed"
  end
end
