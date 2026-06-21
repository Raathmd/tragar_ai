defmodule TragarAi.Demo do
  @moduledoc """
  Demo source. In demo mode the assist loop fact-checks against
  `TragarAi.Demo.Fixtures` instead of the live adapters, so the whole
  interpret → validate → fetch → phrase flow can be demonstrated before any
  source system is connected. `fetch/2` mirrors `TragarAi.Adapters.fetch/2`
  (same intents, same domain-shaped facts), so swapping back to live is a flag.

  `seed/0` additionally writes the demo customer and vehicle into the real
  domain resources via the cross-source `contribute` path, so AshAdmin shows the
  harmonized records and their `SourceRecord`s.
  """

  alias TragarAi.Demo.Fixtures

  @doc "Fetch demo facts for an intent. Same contract as `Adapters.fetch/2`."
  @spec fetch(atom(), map()) :: {:ok, map()} | {:error, :not_found}
  def fetch(intent, entities) do
    case lookup(intent, entities) do
      nil -> {:error, :not_found}
      facts -> {:ok, facts}
    end
  end

  defp lookup(intent, e) when intent in [:load_status, :track, :eta, :pod],
    do: Fixtures.shipments()[waybill(e)]

  defp lookup(:route, e), do: Fixtures.routes()[waybill(e)]
  defp lookup(:quote_lookup, e), do: Fixtures.quotes()[quote_no(e)]
  defp lookup(:customer_lookup, _), do: Fixtures.customer()
  defp lookup(:vehicle_status, _), do: Fixtures.vehicle()
  defp lookup(:invoice, _), do: Fixtures.invoice()
  defp lookup(:ticket_context, e), do: Fixtures.tickets()[ticket_id(e)] || Fixtures.ticket()
  defp lookup(:service_types, _), do: %{"service_types" => Fixtures.service_types()}
  defp lookup(:stock, _), do: %{"item" => "Demo SKU", "on_hand" => 120, "location" => "JHB DC"}
  defp lookup(_, _), do: nil

  defp waybill(e), do: e[:waybill] || e["waybill"]
  defp quote_no(e), do: e[:quote] || e["quote"]
  defp ticket_id(e), do: e[:ticket_id] || e["ticket_id"]

  @doc """
  What the demo can answer, grouped by the source system the question reaches
  into. Each entry is a ready-to-run prompt plus a note of what it surfaces — the
  console renders these so an agent can see the available data and prompt it.
  """
  def catalog do
    [
      %{
        source: "FreightWare",
        question: "Where is load 4821?",
        entities: %{waybill: "4821"},
        surfaces: "Waybill 4821 — In transit to Durban, ETA 22 Jun"
      },
      %{
        source: "FreightWare",
        question: "Proof of delivery for 4990",
        entities: %{waybill: "4990"},
        surfaces: "Waybill 4990 — delivered, signed by M. Naidoo"
      },
      %{
        source: "FreightWare",
        question: "What is the ETA for load 4821?",
        entities: %{waybill: "4821"},
        surfaces: "Estimated arrival date for 4821"
      },
      %{
        source: "FreightWare",
        question: "Show me quote 7012",
        entities: %{quote: "7012"},
        surfaces: "Quote 7012 — accepted, R 4 850.00"
      },
      %{
        source: "FreightWare",
        question: "What service types do you offer?",
        entities: %{},
        surfaces: "Road Express, Economy, Overnight, Same-day, Abnormal"
      },
      %{
        source: "Vantage",
        question: "Show the route for load 4821",
        entities: %{waybill: "4821"},
        surfaces: "On the N3 near Mooi River — 212 km to go, ETA 07:30"
      },
      %{
        source: "Pastel",
        question: "What is the balance on account ACC1001?",
        entities: %{account: "ACC1001"},
        surfaces: "Invoice INV-55012 — outstanding R 48 230.00, terms 30 days"
      },
      %{
        source: "FreightWare + Pastel",
        question: "Who is the customer on ACC1001?",
        entities: %{account: "ACC1001"},
        surfaces: "Acme Distributors — harmonized account + debtor"
      },
      %{
        source: "Vantage + FleetIT + Pastel",
        question: "Is the truck available?",
        entities: %{},
        surfaces: "CA 123-456 — en route (Vantage), unavailable (FleetIT), Volvo FH16 (Pastel)"
      },
      %{
        source: "Freshdesk",
        question: "Show me ticket 55",
        entities: %{ticket_id: "55"},
        surfaces: "Ticket 55 — “Where is my delivery?”"
      },
      %{
        source: "Granite (WMS)",
        question: "What stock is on hand?",
        entities: %{},
        surfaces: "Demo SKU — 120 units at JHB DC"
      }
    ]
  end

  @doc """
  Seed every domain resource from the fixtures, unified by account ACC1001 and
  waybill 4821, and write the cross-source `SourceRecord` ledger. After this the
  AshAdmin tables (customers, vehicles, shipments, quotes, invoices, tickets and
  source_records) mimic the live systems with one coherent thread.
  """
  def seed do
    seed_customer()
    seed_vehicle()
    Enum.each(Fixtures.shipments(), fn {_wb, s} -> seed_shipment(s) end)
    seed_quote()
    seed_invoice()
    seed_tickets()
    seed_ledger()
    :ok
  end

  defp seed_customer do
    c = Fixtures.customer()

    {:ok, _} =
      TragarAi.Customers.contribute(c["account_reference"], "FreightWare", %{name: c["name"]})

    {:ok, _} =
      TragarAi.Customers.contribute(
        c["account_reference"],
        "Pastel",
        %{email: c["email"], description: c["description"]},
        raw: %{"debtorCode" => c["account_reference"], "terms" => "30 days"}
      )
  end

  defp seed_vehicle do
    v = Fixtures.vehicle()

    {:ok, _} =
      TragarAi.Fleet.contribute(v["registration"], "Pastel", %{description: v["description"]})

    {:ok, _} = TragarAi.Fleet.contribute(v["registration"], "Vantage", %{status: v["status"]})

    {:ok, _} =
      TragarAi.Fleet.contribute(v["registration"], "FleetIT", %{available: v["available"]})
  end

  defp seed_shipment(s) do
    {sources, source_data} = provenance_for("shipment", s["waybill_number"])

    {:ok, _} =
      TragarAi.Logistics.upsert_shipment(%{
        waybill_number: s["waybill_number"],
        account_reference: s["account_reference"],
        status: s["status"],
        service_type: s["service_type"],
        consignor: s["consignor"],
        consignee: s["consignee"],
        consignee_city: s["consignee_city"],
        events: s["events"] || [],
        pod: s["pod"],
        sources: sources,
        source_data: source_data,
        cached_at: DateTime.utc_now()
      })
  end

  defp seed_quote do
    q = Fixtures.quotes()["7012"]
    {sources, source_data} = provenance_for("quote", "7012")

    {:ok, _} =
      TragarAi.Logistics.upsert_quote(%{
        quote_number: q["quote_number"],
        account_reference: q["account_reference"],
        status: q["status"],
        service_type: q["service_type"],
        consignor: q["consignor"],
        consignee: q["consignee"],
        charged_amount: q["charged_amount"],
        items: q["items"] || [],
        sundries: q["sundries"] || [],
        sources: sources,
        source_data: source_data,
        cached_at: DateTime.utc_now()
      })
  end

  defp seed_invoice do
    i = Fixtures.invoice()
    {sources, source_data} = provenance_for("invoice", i["invoice_number"])

    {:ok, _} =
      TragarAi.Finance.upsert_invoice(%{
        invoice_number: i["invoice_number"],
        account_reference: i["account_reference"],
        amount: "R 70 330.00",
        balance: i["balance"],
        status: i["status"],
        invoice_date: "2026-06-05",
        sources: sources,
        source_data: source_data,
        cached_at: DateTime.utc_now()
      })
  end

  defp seed_tickets do
    Enum.each(Fixtures.tickets(), fn {_id, t} ->
      raw = %{
        "id" => t["id"],
        "subject" => t["subject"],
        "status" => t["status"],
        "priority" => t["priority"],
        "requester" => t["requester_email"],
        "custom_fields" => %{"account" => t["account"], "waybill" => t["waybill"]}
      }

      {:ok, _} =
        TragarAi.Support.upsert_ticket(%{
          ticket_id: t["id"],
          subject: t["subject"],
          status: t["status"],
          priority: t["priority"],
          requester_email: t["requester_email"],
          account_reference: t["account"],
          waybill_reference: t["waybill"],
          received_at: t["received_at"],
          sources: ["Freshdesk"],
          source_data: %{"Freshdesk" => raw},
          cached_at: DateTime.utc_now()
        })

      {:ok, _} =
        TragarAi.Sources.put_source_record(%{
          entity_type: "ticket",
          entity_key: t["id"],
          source: "Freshdesk",
          data: %{"status" => t["status"], "subject" => t["subject"]},
          raw: raw,
          synced_at: DateTime.utc_now()
        })
    end)
  end

  # Write the cross-source SourceRecord ledger (shipment/quote/invoice/ticket).
  defp seed_ledger do
    Enum.each(Fixtures.ledger(), fn e ->
      {:ok, _} =
        TragarAi.Sources.put_source_record(%{
          entity_type: e.entity_type,
          entity_key: e.entity_key,
          source: e.source,
          data: e.data,
          raw: e.raw,
          synced_at: DateTime.utc_now()
        })
    end)
  end

  # Derive an entity's sources list + source_data map from the ledger.
  defp provenance_for(entity_type, key) do
    entries =
      Enum.filter(Fixtures.ledger(), &(&1.entity_type == entity_type and &1.entity_key == key))

    sources = entries |> Enum.map(& &1.source) |> Enum.uniq()
    source_data = Map.new(entries, fn e -> {e.source, e.raw} end)
    {sources, source_data}
  end
end
