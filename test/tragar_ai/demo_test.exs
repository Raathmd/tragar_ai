defmodule TragarAi.DemoTest do
  @moduledoc "Demo mode runs the full assist loop against fixtures, and seeds harmonized resources."
  use TragarAi.DataCase, async: false

  alias TragarAi.Assist.Engine
  alias TragarAi.{Customers, Fleet, Sources}

  describe "demo-mode assist loop (facts from fixtures)" do
    test "load_status: AI combines the facts into the draft" do
      {:ok, i} = Engine.answer("Where is load 4821?", %{demo: true})

      assert i.status == :drafted
      assert i.source == "FreightWare"
      assert i.facts["status"] == "In transit"
      # The draft already weaves the facts together (agent then adds chips).
      assert i.draft_answer =~ "4821"
      assert i.draft_answer =~ "In transit"
      assert i.draft_answer =~ "2026-06-22"
    end

    test "proof of delivery comes from the fixture" do
      {:ok, i} = Engine.answer("Proof of delivery for 4990", %{demo: true})

      assert i.status == :drafted
      assert i.facts["pod"]["receiver"] == "M. Naidoo"
      assert i.draft_answer =~ "M. Naidoo"
    end

    test "vehicle status is drafted from the harmonized fixture" do
      {:ok, i} = Engine.answer("Is a truck available?", %{demo: true})

      assert i.intent == "vehicle_status"
      assert i.draft_answer =~ "CA 123-456"
      assert i.draft_answer =~ "not currently available"
    end

    test "route comes from Vantage telematics" do
      {:ok, i} =
        Engine.answer("Show the route for load 4821", %{demo: true, entities: %{waybill: "4821"}})

      assert i.intent == "route"
      assert i.source == "Vantage"
      assert i.facts["current_location"] == "N3 near Mooi River Toll"
      assert i.draft_answer =~ "Mooi River"
      assert i.draft_answer =~ "212 km to go"
    end

    test "every catalog prompt runs and drafts an answer" do
      for {entry, _i} <- Enum.with_index(TragarAi.Demo.catalog()) do
        {:ok, i} = Engine.answer(entry.question, %{demo: true, entities: entry.entities})
        assert i.status == :drafted, "expected #{entry.question} to draft, got #{i.error}"
      end
    end

    test "service types list is phrased" do
      {:ok, i} = Engine.answer("What service types do you offer?", %{demo: true})

      assert i.draft_answer =~ "We offer:"
      assert i.draft_answer =~ "Road Express"
    end

    test "customer lookup uses the agent-supplied account" do
      {:ok, i} =
        Engine.answer("Who is the customer here?", %{demo: true, entities: %{account: "ACC1001"}})

      assert i.intent == "customer_lookup"
      assert i.draft_answer =~ "Acme Distributors"
      assert i.draft_answer =~ "ap@acme.co.za"
    end

    test "unknown waybill in demo fails safe" do
      {:ok, i} = Engine.answer("Where is load 9999?", %{demo: true})
      assert i.status == :failed
      assert i.error == "not_found"
    end
  end

  describe "seed/0" do
    test "writes harmonized customer & vehicle from the same fixtures" do
      :ok = TragarAi.Demo.seed()

      assert {:ok, customer} = Customers.get_customer("ACC1001")
      assert customer.name == "Acme Distributors"
      assert Enum.sort(customer.sources) == ["FreightWare", "Pastel"]

      assert {:ok, vehicle} = Fleet.get_vehicle("CA 123-456")
      assert vehicle.description == "Volvo FH16 6x4 truck-tractor"
      assert vehicle.available == false
      assert Enum.sort(vehicle.sources) == ["FleetIT", "Pastel", "Vantage"]

      assert {:ok, records} = Sources.source_records_for("vehicle", "CA 123-456")
      assert length(records) == 3
    end
  end
end
