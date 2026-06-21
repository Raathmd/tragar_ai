defmodule TragarAi.Demo.Fixtures do
  @moduledoc """
  Canonical demo dataset — realistic Tragar facts in the **domain shape** the
  adapters/mappers produce, so the assist loop, the phraser and the console chips
  behave exactly as they will against live sources. Used by `TragarAi.Demo` for
  demo-mode fact-checking and seeding. Replace with live adapters when the
  systems come online; nothing else changes.
  """

  @account "ACC1001"

  def account_reference, do: @account

  @doc "Shipments keyed by waybill number."
  def shipments do
    %{
      "4821" => %{
        "waybill_number" => "4821",
        "account_reference" => @account,
        "status" => "In transit",
        "service_type" => "Road Express",
        "consignor" => "Tragar Johannesburg Depot",
        "consignee" => "Acme Distributors",
        "consignee_city" => "Durban",
        "eta" => "2026-06-22",
        "route" => "N3 via Harrismith",
        "distance" => 568,
        "last_event" => %{
          "event_description" => "Departed Johannesburg hub",
          "event_date" => "2026-06-21 14:03"
        },
        "events" => [
          %{
            "event_description" => "Collected from consignor",
            "event_date" => "2026-06-21 09:10"
          },
          %{
            "event_description" => "Departed Johannesburg hub",
            "event_date" => "2026-06-21 14:03"
          }
        ]
      },
      "4990" => %{
        "waybill_number" => "4990",
        "account_reference" => @account,
        "status" => "Delivered",
        "service_type" => "Road Economy",
        "consignor" => "Tragar Johannesburg Depot",
        "consignee" => "Acme Distributors",
        "consignee_city" => "Cape Town",
        "eta" => "2026-06-18",
        "pod" => %{
          "receiver" => "M. Naidoo",
          "date" => "2026-06-18 11:27",
          "image_url" => "https://tragar-db.dovetail.co.za/FWO_UAT/views/viewImage.html?4990"
        },
        "last_event" => %{"event_description" => "Delivered", "event_date" => "2026-06-18 11:27"},
        "events" => [
          %{"event_description" => "Out for delivery", "event_date" => "2026-06-18 08:40"},
          %{"event_description" => "Delivered", "event_date" => "2026-06-18 11:27"}
        ]
      }
    }
  end

  @doc "Vantage telematics route/position, keyed by waybill."
  def routes do
    %{
      "4821" => %{
        "waybill_number" => "4821",
        "vehicle" => "CA 123-456",
        "route" => "N3 Johannesburg → Durban via Harrismith",
        "distance" => 568,
        "distance_remaining" => 212,
        "current_location" => "N3 near Mooi River Toll",
        "next_stop" => "Durban depot",
        "speed" => "92 km/h",
        "eta" => "2026-06-22 07:30"
      }
    }
  end

  @doc "Quotes keyed by quote number."
  def quotes do
    %{
      "7012" => %{
        "quote_number" => "7012",
        "account_reference" => @account,
        "status" => "Accepted",
        "service_type" => "Road Express",
        "consignor" => "Acme Distributors",
        "consignee" => "Pick n Pay DC, Durban",
        "charged_amount" => "R 4 850.00",
        "items" => [%{"description" => "12 pallets dry goods", "mass" => "9 600 kg"}],
        "sundries" => []
      }
    }
  end

  @doc "Harmonized customer (FreightWare account + Pastel debtor)."
  def customer do
    %{
      "account_reference" => @account,
      "name" => "Acme Distributors",
      "email" => "ap@acme.co.za",
      "description" => "30-day terms · Gauteng + KZN lanes",
      "sources" => ["FreightWare", "Pastel"]
    }
  end

  @doc "Harmonized vehicle (Pastel asset + Vantage tracking + FleetIT availability)."
  def vehicle do
    %{
      "registration" => "CA 123-456",
      "status" => "En route to Durban",
      "available" => false,
      "description" => "Volvo FH16 6x4 truck-tractor",
      "sources" => ["Pastel", "Vantage", "FleetIT"]
    }
  end

  @doc "Outstanding invoice / debtor position for the demo account (Pastel)."
  def invoice do
    %{
      "invoice_number" => "INV-55012",
      "account_reference" => @account,
      "status" => "Outstanding",
      "balance" => "R 48 230.00",
      "terms" => "30 days",
      "last_payment" => "R 22 100.00 on 2026-05-28",
      "due_date" => "2026-07-05"
    }
  end

  @doc "Freshdesk ticket context."
  def ticket do
    %{
      "id" => "55",
      "subject" => "Where is my delivery?",
      "status" => "Open",
      "requester_email" => "ap@acme.co.za"
    }
  end

  def service_types,
    do: ["Road Express", "Road Economy", "Overnight", "Same-day (metro)", "Abnormal load"]
end
