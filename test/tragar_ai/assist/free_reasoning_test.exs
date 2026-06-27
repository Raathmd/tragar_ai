defmodule TragarAi.Assist.FreeReasoningTest do
  @moduledoc "The `free_reasoning` flag: an empty/unmatched lookup reasons instead of refusing."
  use TragarAi.DataCase, async: false

  alias TragarAi.Assist.Engine

  test "without the flag, an unmatched question fails safe (clarify)" do
    {:ok, i} = Engine.answer("hello there", %{})
    assert i.status == :failed
    assert i.source != "reasoning"
  end

  test "with the flag, the same question reasons instead of short-circuiting" do
    {:ok, i} = Engine.answer("hello there", %{free_reasoning: true})
    assert i.status == :reasoned
    assert i.source == "reasoning"
    assert is_binary(i.draft_answer) and i.draft_answer != ""
    # The trace shows the reasoning call, not a clarify.
    assert Enum.any?(i.tool_log, &(&1["tool"] == "CoreAI.reason"))
  end
end
