defmodule TragarAi.QuoteIntakeTest do
  use TragarAi.DataCase, async: true

  alias TragarAi.QuoteIntake.{Flow, Server}

  defmodule FakeFreightWare do
    def resolve_service_type(_text), do: {:ok, %{"code" => "ECO", "name" => "ECONOMY"}}
    def quick_quote(_params), do: {:ok, [%{"service_type" => "ECO", "total_charge" => "1234.00"}]}
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

  # Pass the fake FreightWare on every turn so the :ready step rates against it
  # instead of the live API.
  defp step(base, msg),
    do: Server.handle(Map.put(base, :message, msg), freightware: FakeFreightWare)

  describe "Server (guided conversation)" do
    test "runs from opening question, resolves the service code, rates, and creates the quote" do
      tid = "T-#{System.unique_integer([:positive])}"
      base = %{ticket_id: tid, account: "ITD02"}

      {:ok, r0} = step(base, "I need a quote")
      assert r0.reply =~ "service"
      assert r0.status == "collecting"
      refute r0.complete

      {:ok, _} = step(base, "Economy")
      {:ok, _} = step(base, "Sandton 2196")
      {:ok, _} = step(base, "Durban 4001")
      {:ok, ready} = step(base, "3 pallets, 1200kg")

      assert ready.status == "ready"
      assert ready.reply =~ "ACCEPT"
      # Live rate is surfaced, and the resolved service code replaces "Economy".
      assert ready.rate == "1234.00"
      assert ready.reply =~ "1234.00"
      assert ready.quote_params["service_type"] == "ECO"
      assert ready.quote_params["consignee_postal_code"] == "4001"

      {:ok, done} = step(base, "ACCEPT")
      assert done.status == "accepted"
      assert done.quote_number == "Q9001"
      assert done.complete
    end

    test "REJECT cancels the request" do
      tid = "T-#{System.unique_integer([:positive])}"
      base = %{ticket_id: tid, account: "ITD02"}

      step(base, "hi")
      step(base, "Economy")
      step(base, "Sandton 2196")
      step(base, "Durban 4001")
      step(base, "1 box, 5kg")

      {:ok, done} = step(base, "REJECT")
      assert done.status == "rejected"
      assert done.complete
    end
  end
end
