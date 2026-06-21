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
  defp lookup(:ticket_context, _), do: Fixtures.ticket()
  defp lookup(:service_types, _), do: %{"service_types" => Fixtures.service_types()}
  defp lookup(:stock, _), do: %{"item" => "Demo SKU", "on_hand" => 120, "location" => "JHB DC"}
  defp lookup(_, _), do: nil

  defp waybill(e), do: e[:waybill] || e["waybill"]
  defp quote_no(e), do: e[:quote] || e["quote"]

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
  Seed the harmonized Customer and Vehicle into the domain resources, each
  assembled from multiple sources (demonstrates the no-override harmonization).
  """
  def seed do
    c = Fixtures.customer()

    {:ok, _} =
      TragarAi.Customers.contribute(c["account_reference"], "FreightWare", %{name: c["name"]})

    {:ok, _} =
      TragarAi.Customers.contribute(
        c["account_reference"],
        "Pastel",
        %{email: c["email"], description: c["description"]},
        raw: %{"terms" => "30 days"}
      )

    v = Fixtures.vehicle()

    {:ok, _} =
      TragarAi.Fleet.contribute(v["registration"], "Pastel", %{description: v["description"]})

    {:ok, _} = TragarAi.Fleet.contribute(v["registration"], "Vantage", %{status: v["status"]})

    {:ok, _} =
      TragarAi.Fleet.contribute(v["registration"], "FleetIT", %{available: v["available"]})

    :ok
  end
end
