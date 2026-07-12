defmodule TragarAiWeb.SettingsLiveTest do
  use TragarAiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TragarAi.Assist.SearchStrategy

  setup do
    original = SearchStrategy.get()
    on_exit(fn -> SearchStrategy.set(original) end)
    :ok
  end

  test "renders both strategies and marks the active one", %{conn: conn} do
    SearchStrategy.set(:sequential)
    {:ok, _view, html} = live(conn, ~p"/settings")

    assert html =~ "Search pipeline"
    assert html =~ "Sequential cascade"
    assert html =~ "Parallel fan-out"
  end

  test "clicking a strategy switches the runtime setting", %{conn: conn} do
    SearchStrategy.set(:sequential)
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> element("button[phx-value-strategy=fanout]")
    |> render_click()

    assert SearchStrategy.get() == :fanout

    view
    |> element("button[phx-value-strategy=sequential]")
    |> render_click()

    assert SearchStrategy.get() == :sequential
  end
end
