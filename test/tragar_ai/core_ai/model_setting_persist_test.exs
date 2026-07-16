defmodule TragarAi.CoreAI.ModelSettingPersistTest do
  @moduledoc "The active model / reasoning toggle persist across a restart."
  use TragarAi.DataCase, async: false

  alias TragarAi.CoreAI.ModelSetting

  @model_key :core_ai_active_model
  @reasoning_key :core_ai_reasoning_enabled

  setup do
    ModelSetting.reset()
    on_exit(fn -> ModelSetting.reset() end)
    :ok
  end

  # Drop the in-memory cache but leave the durable store intact.
  defp simulate_restart do
    Application.delete_env(:tragar_ai, @model_key)
    Application.delete_env(:tragar_ai, @reasoning_key)
  end

  test "a model switch is persisted and restored after a restart" do
    assert {:ok, "qwen3:14b"} = ModelSetting.set("qwen3:14b")
    assert ModelSetting.get() == "qwen3:14b"

    simulate_restart()
    # Cache gone → back to the default selection…
    assert ModelSetting.get() == "claude"

    # …until boot re-hydrates from the durable store.
    ModelSetting.load_persisted()
    assert ModelSetting.get() == "qwen3:14b"
  end

  test "the reasoning toggle persists across a restart" do
    {:ok, true} = ModelSetting.set_reasoning_enabled(true)

    simulate_restart()
    refute ModelSetting.reasoning_enabled?()

    ModelSetting.load_persisted()
    assert ModelSetting.reasoning_enabled?()
  end

  test "reset clears the durable store too" do
    ModelSetting.set("qwen2.5:14b-instruct")
    ModelSetting.reset()

    simulate_restart()
    ModelSetting.load_persisted()
    # Nothing persisted → the default selection.
    assert ModelSetting.get() == "claude"
  end
end
