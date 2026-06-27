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
end
