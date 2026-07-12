defmodule TragarAi.CoreAI.StubTest do
  use ExUnit.Case, async: true

  alias TragarAi.CoreAI.Stub

  describe "interpret/1" do
    test "classifies a status question and extracts the waybill" do
      assert %{intent: :load_status, entities: %{waybill: "DIS0124440"}} =
               Stub.interpret("Where is load DIS0124440?")
    end

    test "classifies ETA, POD, invoice, route, stock, vehicle" do
      assert %{intent: :eta} = Stub.interpret("What's the ETA for waybill 5500?")
      assert %{intent: :pod} = Stub.interpret("proof of delivery for DIS0124440")
      assert %{intent: :invoice} = Stub.interpret("what is my account balance?")
      assert %{intent: :route} = Stub.interpret("what is the planned route distance?")
      assert %{intent: :stock} = Stub.interpret("how much stock is on hand?")
      assert %{intent: :vehicle_status} = Stub.interpret("is a vehicle available?")
    end

    test "unknown question" do
      assert %{intent: :unknown} = Stub.interpret("hello there")
    end

    test "classifies a delivery-price request as quick_quote" do
      assert %{intent: :quick_quote} =
               Stub.interpret("What is the delivery cost to transport a TV to Rendo's Audio?")

      assert %{intent: :quick_quote} = Stub.interpret("how much to ship a pallet to Durban?")
    end

    test "an existing quote number is still quote_lookup, not quick_quote" do
      assert %{intent: :quote_lookup, entities: %{quote: "7012"}} =
               Stub.interpret("what's the status of quote 7012?")
    end

    test "a price word without shipping context is not a quick_quote" do
      # "how much" alone must not hijack a stock lookup.
      assert %{intent: :stock} = Stub.interpret("how much stock is on hand?")
    end
  end

  describe "quote_extract/1" do
    test "reads service, collection, delivery and goods from a full request" do
      slots =
        Stub.quote_extract("I need an Overnight delivery from Menlyn to Durban, 53.4 kg")

      assert slots["service"] == "Overnight"
      assert slots["collection"] == "Menlyn"
      assert slots["delivery"] == "Durban"
      assert slots["goods"] =~ "53.4"
    end

    test "a leading verb ('to ship') is not mistaken for the destination" do
      slots = Stub.quote_extract("how much to ship from Sandton to Umhlanga?")

      assert slots["collection"] == "Sandton"
      assert slots["delivery"] == "Umhlanga"
    end

    test "empty when nothing is stated, and safe on non-binary input" do
      assert Stub.quote_extract("hello there") == %{}
      assert Stub.quote_extract(nil) == %{}
    end
  end

  describe "phrase/2" do
    test "load_status mentions waybill and status" do
      text = Stub.phrase(:load_status, %{"waybill_number" => "DIS0124440", "status" => "In transit"})
      assert text =~ "DIS0124440"
      assert text =~ "In transit"
    end

    test "pod with no record is honest" do
      assert Stub.phrase(:pod, %{"waybill_number" => "DIS0124440"}) =~ "no proof of delivery"
    end
  end
end
