defmodule TragarAiWeb.ChatLiveTest do
  use TragarAiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "renders the chat and answers a prompt", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/chat")
    assert html =~ "Local AI chat"
    # The nav links back to the console (root).
    assert view |> element(~s{nav a[href="/"]}) |> has_element?()

    # The prompt is echoed immediately; the answer arrives via async.
    submitted =
      view
      |> form("form[phx-submit=send]", %{message: "hello there"})
      |> render_submit()

    assert submitted =~ "hello there"

    # Await the async model call, then the safe-fail answer is shown.
    html = render_async(view, 5000)
    assert html =~ "failed"
  end

  test "the 'reason freely' toggle answers instead of refusing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/chat")

    view |> element("input[phx-click=toggle_reasoning]") |> render_click()

    view
    |> form("form[phx-submit=send]", %{message: "hello there"})
    |> render_submit()

    html = render_async(view, 5000)
    assert html =~ "reasoned"
    refute html =~ "failed"
  end
end
