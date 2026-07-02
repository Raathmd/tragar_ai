defmodule TragarAi.QuoteIntake.FlowTest do
  use ExUnit.Case, async: true

  alias TragarAi.QuoteIntake.Flow

  describe "seed_from_text/1" do
    test "reads an explicitly named service type" do
      assert %{"service" => "Overnight"} =
               Flow.seed_from_text("I need an Overnight delivery to Durban")

      assert %{"service" => "Road Express"} = Flow.seed_from_text("road express please")
    end

    test "reads the spaced 'same day' variant" do
      assert %{"service" => "Same-day"} = Flow.seed_from_text("can you do same day?")
    end

    test "does not guess places or goods from free text" do
      # A verb 'to transport' and a place 'Moffett On Main' must not be mis-read as
      # a delivery slot — only the (absent) service is considered.
      seed =
        Flow.seed_from_text(
          "What is the delivery cost to transport a TV to Rendo's Audio at Moffett On Main on Friday?"
        )

      assert seed == %{}
    end

    test "empty when no signal, and safe on non-binary input" do
      assert Flow.seed_from_text("hello there") == %{}
      assert Flow.seed_from_text(nil) == %{}
    end
  end
end
