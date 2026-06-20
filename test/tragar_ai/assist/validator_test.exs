defmodule TragarAi.Assist.ValidatorTest do
  use ExUnit.Case, async: true

  alias TragarAi.Assist.Validator

  test "passes when required entities are present" do
    assert :ok = Validator.validate(%{intent: :load_status, entities: %{waybill: "4821"}})
  end

  test "rejects missing required entities" do
    assert {:error, {:missing_entities, [:waybill]}} =
             Validator.validate(%{intent: :load_status, entities: %{}})
  end

  test "rejects unknown intent" do
    assert {:error, :not_understood} = Validator.validate(%{intent: :unknown, entities: %{}})

    assert {:error, {:unknown_intent, :frobnicate}} =
             Validator.validate(%{intent: :frobnicate, entities: %{}})
  end

  test "intents without required entities pass" do
    assert :ok = Validator.validate(%{intent: :stock, entities: %{}})
  end
end
