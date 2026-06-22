defmodule TragarAi.QuoteIntakeTest do
  use TragarAi.DataCase, async: true

  alias TragarAi.QuoteIntake.{Flow, Server}

  defmodule FakeFreightWare do
    def create_quote(_params), do: {:ok, %{"quote_number" => "Q9001"}}
  end

  describe "Flow (pure)" do
    test "advances slot by slot then becomes ready" do
      assert {:ask, s1, q1} = Flow.advance(%{}, "Economy")
      assert s1["service"] == "Economy"
      assert q1 =~ "collecting from"

      assert {:ask, s2, _} = Flow.advance(s1, "Sandton 2196")
      assert {:ask, s3, q3} = Flow.advance(s2, "Durban 4001")
      assert q3 =~ "shipping"

      assert {:ready, slots, summary} = Flow.advance(s3, "3 pallets of tiles, 1200kg")
      assert summary =~ "ACCEPT"
      assert slots["goods"] =~ "tiles"
    end

    test "parses FreightWare params from gathered slots" do
      slots = %{
        "service" => "Economy",
        "collection" => "Sandton 2196",
        "delivery" => "Durban 4001",
        "goods" => "3 pallets of tiles, 1200kg"
      }

      params = Flow.to_quote_params(slots, "ITD02")

      assert params["account_reference"] == "ITD02"
      assert params["service_type"] == "Economy"
      assert params["consignor_postal_code"] == "2196"
      assert params["consignee_postal_code"] == "4001"
      assert [%{"mass" => "1200", "pieces" => "3"}] = params["items"]
    end
  end

  describe "Server (guided conversation)" do
    test "runs from opening question through to a created quote" do
      tid = "T-#{System.unique_integer([:positive])}"
      base = %{ticket_id: tid, account: "ITD02"}

      {:ok, r0} = Server.handle(Map.put(base, :message, "I need a quote"))
      assert r0.reply =~ "service"
      assert r0.status == "collecting"
      refute r0.complete

      {:ok, _} = Server.handle(Map.put(base, :message, "Economy"))
      {:ok, _} = Server.handle(Map.put(base, :message, "Sandton 2196"))
      {:ok, _} = Server.handle(Map.put(base, :message, "Durban 4001"))
      {:ok, ready} = Server.handle(Map.put(base, :message, "3 pallets, 1200kg"))

      assert ready.status == "ready"
      assert ready.reply =~ "ACCEPT"
      assert ready.quote_params["consignee_postal_code"] == "4001"

      {:ok, done} = Server.handle(Map.put(base, :message, "ACCEPT"), freightware: FakeFreightWare)
      assert done.status == "accepted"
      assert done.quote_number == "Q9001"
      assert done.complete
    end

    test "REJECT cancels the request" do
      tid = "T-#{System.unique_integer([:positive])}"
      base = %{ticket_id: tid, account: "ITD02"}

      Server.handle(Map.put(base, :message, "hi"))
      Server.handle(Map.put(base, :message, "Economy"))
      Server.handle(Map.put(base, :message, "Sandton 2196"))
      Server.handle(Map.put(base, :message, "Durban 4001"))
      Server.handle(Map.put(base, :message, "1 box, 5kg"))

      {:ok, done} = Server.handle(Map.put(base, :message, "REJECT"))
      assert done.status == "rejected"
      assert done.complete
    end
  end
end
