defmodule TragarAi.CoreAI.StubTest do
  use ExUnit.Case, async: true

  alias TragarAi.CoreAI.Stub

  describe "interpret/1" do
    test "classifies a status question and extracts the waybill" do
      assert %{intent: :load_status, entities: %{waybill: "4821"}} =
               Stub.interpret("Where is load 4821?")
    end

    test "classifies ETA, POD, invoice, route, stock, vehicle" do
      assert %{intent: :eta} = Stub.interpret("What's the ETA for waybill 5500?")
      assert %{intent: :pod} = Stub.interpret("proof of delivery for 4821")
      assert %{intent: :invoice} = Stub.interpret("what is my account balance?")
      assert %{intent: :route} = Stub.interpret("what is the planned route distance?")
      assert %{intent: :stock} = Stub.interpret("how much stock is on hand?")
      assert %{intent: :vehicle_status} = Stub.interpret("is a vehicle available?")
    end

    test "unknown question" do
      assert %{intent: :unknown} = Stub.interpret("hello there")
    end
  end

  describe "phrase/2" do
    test "load_status mentions waybill and status" do
      text = Stub.phrase(:load_status, %{"waybill_number" => "4821", "status" => "In transit"})
      assert text =~ "4821"
      assert text =~ "In transit"
    end

    test "pod with no record is honest" do
      assert Stub.phrase(:pod, %{"waybill_number" => "4821"}) =~ "no proof of delivery"
    end
  end
end
