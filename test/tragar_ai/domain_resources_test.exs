defmodule TragarAi.DomainResourcesTest do
  @moduledoc "Ticket (Freshdesk) and Customer (FreightWare accounts) domain resources + adapter routing."
  use TragarAi.DataCase, async: false

  alias TragarAi.Adapters
  alias TragarAi.Customers
  alias TragarAi.Fleet
  alias TragarAi.Sources
  alias TragarAi.Support

  setup do
    Req.Test.set_req_test_to_shared()
    TragarAi.Dovetail.TokenStore.invalidate()

    Req.Test.stub(TragarAi.Freshdesk.Client, fn conn ->
      cond do
        String.contains?(conn.request_path, "/tickets/55") ->
          Req.Test.json(conn, %{
            "id" => 55,
            "subject" => "Late delivery",
            "status" => 2,
            "email" => "a@b.test"
          })

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    Req.Test.stub(TragarAi.Dovetail.Client, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/system/auth/login") ->
          conn
          |> Plug.Conn.put_resp_header("x-freightware", "tok")
          |> Req.Test.json(%{"response" => %{}})

        String.contains?(conn.request_path, "/baseData/accounts") ->
          Req.Test.json(conn, %{
            "response" => %{
              "esAccounts" => %{
                "Accounts" => [%{"accountReference" => "ACC9", "accountName" => "Acme Ltd"}]
              }
            }
          })

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"response" => %{}})
      end
    end)

    :ok
  end

  describe "Ticket (Freshdesk)" do
    test "read-through caches a domain Ticket with provenance" do
      assert {:ok, domain} = Support.Cache.ticket("55")
      assert domain["subject"] == "Late delivery"

      assert {:ok, ticket} = Support.get_ticket("55")
      assert ticket.requester_email == "a@b.test"
      assert ticket.sources == ["Freshdesk"]
    end

    test "served via the adapter registry" do
      assert {:ok, %{"subject" => "Late delivery"}} =
               Adapters.fetch(:ticket_context, %{ticket_id: "55"})
    end
  end

  describe "Customer (FreightWare accounts)" do
    test "read-through caches a domain Customer with provenance" do
      assert {:ok, %{"name" => "Acme Ltd"}} = Customers.Cache.customer("ACC9")

      assert {:ok, customer} = Customers.get_customer("ACC9")
      assert customer.name == "Acme Ltd"
      assert customer.sources == ["FreightWare"]
    end

    test "served via the adapter registry" do
      assert {:ok, %{"account_reference" => "ACC9"}} =
               Adapters.fetch(:customer_lookup, %{account: "ACC9"})
    end

    test "a customer is harmonized across sources; each is its own SourceRecord, no overrides" do
      # FreightWare contributes name.
      assert {:ok, _} = Customers.Cache.customer("ACC9")

      # Pastel contributes its slice: a billing email (new field) AND a name
      # (already owned by FreightWare — must NOT override).
      assert {:ok, _} =
               Customers.contribute(
                 "ACC9",
                 "Pastel",
                 %{email: "billing@acme.test", name: "ACME (Pty) Ltd"},
                 raw: %{"debtorCode" => "ACC9", "terms" => "30 days"}
               )

      assert {:ok, customer} = Customers.get_customer("ACC9")
      # kept from FreightWare (higher priority)
      assert customer.name == "Acme Ltd"
      # added by Pastel
      assert customer.email == "billing@acme.test"
      assert Enum.sort(customer.sources) == ["FreightWare", "Pastel"]

      # Each source is its own related record.
      assert {:ok, records} = Sources.source_records_for("customer", "ACC9")
      assert Enum.map(records, & &1.source) |> Enum.sort() == ["FreightWare", "Pastel"]
    end
  end

  describe "Vehicle (cross-source via SourceRecord)" do
    test "a vehicle is assembled from each source's pieces with no overrides" do
      # Pastel: the asset description. Vantage: live status. FleetIT: availability + a
      # status it does NOT own (Vantage has higher priority for status).
      assert {:ok, _} = Fleet.contribute("CA12345", "Pastel", %{description: "Volvo FH16"})
      assert {:ok, _} = Fleet.contribute("CA12345", "Vantage", %{status: "moving"})

      assert {:ok, _} =
               Fleet.contribute("CA12345", "FleetIT", %{available: true, status: "in service"})

      assert {:ok, vehicle} = Fleet.get_vehicle("CA12345")
      # Pastel's piece
      assert vehicle.description == "Volvo FH16"
      # Vantage owns status (higher priority than FleetIT)
      assert vehicle.status == "moving"
      # FleetIT's piece
      assert vehicle.available == true
      assert Enum.sort(vehicle.sources) == ["FleetIT", "Pastel", "Vantage"]

      assert {:ok, records} = Sources.source_records_for("vehicle", "CA12345")
      assert length(records) == 3
    end
  end
end
