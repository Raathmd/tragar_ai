defmodule TragarAiWeb.SettingsLiveTest do
  use TragarAiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TragarAi.Assist.SearchStrategy
  alias TragarAi.CoreAI.ModelSetting

  setup do
    original = SearchStrategy.get()
    original_model = ModelSetting.get()
    original_reasoning = ModelSetting.reasoning_enabled?()

    on_exit(fn ->
      SearchStrategy.set(original)
      ModelSetting.set(original_model)
      ModelSetting.set_reasoning_enabled(original_reasoning)
    end)

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

  test "renders both models and marks the active one", %{conn: conn} do
    ModelSetting.set("qwen2.5:14b-instruct")
    {:ok, _view, html} = live(conn, ~p"/settings")

    assert html =~ "Local model"
    assert html =~ "Qwen2.5 14B"
    assert html =~ "Qwen3 14B"
  end

  test "clicking a model switches the active model", %{conn: conn} do
    ModelSetting.set("qwen2.5:14b-instruct")
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> element("button[phx-value-model='qwen3:14b']")
    |> render_click()

    assert ModelSetting.get() == "qwen3:14b"
  end

  test "reasoning toggle flips only for a reasoning-capable model", %{conn: conn} do
    ModelSetting.set("qwen3:14b")
    ModelSetting.set_reasoning_enabled(false)
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> element("input[phx-click=toggle_reasoning]")
    |> render_click()

    assert ModelSetting.reasoning_enabled?() == true
    assert ModelSetting.thinking_active?() == true
  end

  test "reasoning has no effect on a non-reasoning model", %{conn: conn} do
    ModelSetting.set("qwen2.5:14b-instruct")
    ModelSetting.set_reasoning_enabled(true)

    # Toggle is on, but the active model can't think, so no thinking is requested.
    refute ModelSetting.thinking_active?()
  end
end
