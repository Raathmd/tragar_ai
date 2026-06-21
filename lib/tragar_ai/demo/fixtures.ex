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
      "subject" => "Where is my delivery on waybill 4821?",
      "status" => "Open",
      "priority" => "High",
      "requester_email" => "ap@acme.co.za"
    }
  end

  def service_types,
    do: ["Road Express", "Road Economy", "Overnight", "Same-day (metro)", "Abnormal load"]

  @doc """
  The cross-source provenance ledger — what **each source system** contributes to
  each entity, with a source-shaped `raw` payload (mimics the real systems) and
  the domain `data` pieces it owns. The whole thread is unified by account
  ACC1001 and waybill 4821. `TragarAi.Demo.seed/0` writes these as `SourceRecord`s
  and derives each domain record's `sources`/`source_data` from them.
  """
  def ledger do
    [
      # ── Shipment 4821 (in transit) — FreightWare + Vantage + Granite ──────────
      %{
        entity_type: "shipment",
        entity_key: "4821",
        source: "FreightWare",
        data: %{
          "status" => "In transit",
          "service_type" => "Road Express",
          "consignee" => "Acme Distributors"
        },
        raw: %{
          "waybillNumber" => "4821",
          "accountReference" => @account,
          "statusCode" => "INT",
          "statusDescription" => "In transit",
          "serviceType" => "Road Express",
          "consignorName" => "Tragar Johannesburg Depot",
          "consigneeName" => "Acme Distributors",
          "consigneeCity" => "Durban"
        }
      },
      %{
        entity_type: "shipment",
        entity_key: "4821",
        source: "Vantage",
        data: %{"current_location" => "N3 near Mooi River Toll", "eta" => "2026-06-22 07:30"},
        raw: routes()["4821"]
      },
      %{
        entity_type: "shipment",
        entity_key: "4821",
        source: "Granite",
        data: %{"dispatch_status" => "Picked & packed", "parcels" => 12},
        raw: %{
          "warehouse" => "JHB DC",
          "pickStatus" => "Picked",
          "packStatus" => "Packed",
          "parcels" => 12,
          "dispatchedAt" => "2026-06-21 08:55"
        }
      },

      # ── Shipment 4990 (delivered) — FreightWare + Granite POD ─────────────────
      %{
        entity_type: "shipment",
        entity_key: "4990",
        source: "FreightWare",
        data: %{"status" => "Delivered", "service_type" => "Road Economy"},
        raw: %{
          "waybillNumber" => "4990",
          "accountReference" => @account,
          "statusCode" => "DEL",
          "statusDescription" => "Delivered",
          "serviceType" => "Road Economy",
          "consigneeName" => "Acme Distributors",
          "consigneeCity" => "Cape Town"
        }
      },
      %{
        entity_type: "shipment",
        entity_key: "4990",
        source: "Granite",
        data: %{"pod_receiver" => "M. Naidoo", "pod_date" => "2026-06-18 11:27"},
        raw: %{
          "PODReceiver" => "M. Naidoo",
          "PODDate" => "2026-06-18 11:27",
          "numberofParcels" => 8,
          "PODImageURL" => "https://tragar-db.dovetail.co.za/FWO_UAT/views/viewImage.html?4990"
        }
      },

      # ── Quote 7012 — FreightWare ──────────────────────────────────────────────
      %{
        entity_type: "quote",
        entity_key: "7012",
        source: "FreightWare",
        data: %{"status" => "Accepted", "charged_amount" => "R 4 850.00"},
        raw: quotes()["7012"]
      },

      # ── Invoice INV-55012 — Pastel (accounting) ───────────────────────────────
      %{
        entity_type: "invoice",
        entity_key: "INV-55012",
        source: "Pastel",
        data: %{"status" => "Outstanding", "balance" => "R 48 230.00"},
        raw: %{
          "documentNumber" => "INV-55012",
          "debtorCode" => @account,
          "documentTotal" => "R 70 330.00",
          "outstanding" => "R 48 230.00",
          "terms" => "30 days",
          "lastPayment" => "R 22 100.00 on 2026-05-28",
          "ageing" => %{"current" => "R 26 100.00", "30days" => "R 22 130.00"},
          "documentDate" => "2026-06-05",
          "dueDate" => "2026-07-05"
        }
      },

      # ── Ticket 55 — Freshdesk (about waybill 4821) ────────────────────────────
      %{
        entity_type: "ticket",
        entity_key: "55",
        source: "Freshdesk",
        data: %{"status" => "Open", "subject" => "Where is my delivery on waybill 4821?"},
        raw: %{
          "id" => 55,
          "subject" => "Where is my delivery on waybill 4821?",
          "status" => 2,
          "priority" => 3,
          "requester" => "ap@acme.co.za",
          "custom_fields" => %{"account" => @account, "waybill" => "4821"}
        }
      }
    ]
  end
end
