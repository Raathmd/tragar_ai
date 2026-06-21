defmodule TragarAi.DemoTest do
  @moduledoc "Demo mode runs the full assist loop against fixtures, and seeds harmonized resources."
  use TragarAi.DataCase, async: false

  alias TragarAi.Assist.Engine
  alias TragarAi.{Customers, Finance, Fleet, Logistics, Sources, Support}

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

    test "records the AI and source tool calls (with data) in the log" do
      {:ok, i} = Engine.answer("Where is load 4821?", %{demo: true})

      tools = Enum.map(i.tool_log, & &1["tool"])
      assert "CoreAI.interpret" in tools
      assert "FreightWare.load_status" in tools
      assert "CoreAI.phrase" in tools

      source_call = Enum.find(i.tool_log, &(&1["kind"] == "source"))
      assert source_call["params"]["waybill"] == "4821"
      assert source_call["result"]["status"] == "In transit"
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
    test "populates every entity, unified by account ACC1001 and waybill 4821" do
      :ok = TragarAi.Demo.seed()

      # Customer & Vehicle — harmonized
      assert {:ok, customer} = Customers.get_customer("ACC1001")
      assert customer.name == "Acme Distributors"
      assert Enum.sort(customer.sources) == ["FreightWare", "Pastel"]

      assert {:ok, vehicle} = Fleet.get_vehicle("CA 123-456")
      assert vehicle.available == false
      assert Enum.sort(vehicle.sources) == ["FleetIT", "Pastel", "Vantage"]

      # Shipments — 4821 carries FreightWare + Vantage + Granite
      assert {:ok, shipment} = Logistics.get_shipment_by_waybill("4821")
      assert shipment.account_reference == "ACC1001"
      assert Enum.sort(shipment.sources) == ["FreightWare", "Granite", "Vantage"]

      # Quote, Invoice (Pastel accounting), Ticket (about 4821) — all on ACC1001
      assert {:ok, quote} = Logistics.get_quote_by_number("7012")
      assert quote.account_reference == "ACC1001"
      assert {:ok, invoice} = Finance.get_invoice("INV-55012")
      assert invoice.account_reference == "ACC1001"
      assert invoice.sources == ["Pastel"]
      assert {:ok, ticket} = Support.get_ticket("55")
      assert ticket.account_reference == "ACC1001"
      assert ticket.subject =~ "4821"

      # The cross-source ledger is in source_records
      assert {:ok, recs} = Sources.source_records_for("shipment", "4821")
      assert Enum.map(recs, & &1.source) |> Enum.sort() == ["FreightWare", "Granite", "Vantage"]
    end
  end
end
