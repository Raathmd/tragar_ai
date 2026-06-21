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

  defp lookup(intent, e) when intent in [:load_status, :track, :eta, :pod, :route],
    do: Fixtures.shipments()[waybill(e)]

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
