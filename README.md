# Tragar AI

An Elixir / [Ash Framework](https://ash-hq.org) + Phoenix application that
integrates **Freshdesk** (customer support) with **Tragar's Dovetail system**
— the FreightWare logistics API hosted at `tragar-db.dovetail.co.za`.

It is the spiritual successor to the Rust/WASM `tragar_quote_dioxus` project,
reusing the same Dovetail/FreightWare REST conventions (token auth via the
`X-FreightWare` header, `request`/`response` envelopes) in an OTP application.

## What it does

- **Dovetail client** (`TragarAi.Dovetail.Client`) — quotes, waybills,
  track-and-trace, base data, and POD images, with a cached session token
  (`TragarAi.Dovetail.TokenStore`).
- **Freshdesk client** (`TragarAi.Freshdesk.Client`) — tickets, contacts, and
  companies over the Freshdesk REST API v2.
- **Integration glue** (`TragarAi.Integration.Sync`) — pulls shipment/tracking
  data from Dovetail, mirrors Freshdesk tickets locally, links the two, and can
  raise Freshdesk tickets for shipment exceptions. Every operation is audited in
  `sync_events`.
- **Inbound webhooks** — `POST /webhooks/freshdesk` queues ticket payloads
  (Oban) for off-request processing.
- **Admin UI** — AshAdmin at `/admin` (dev only) to browse the mirrored data.

## Architecture

| Layer | Module(s) |
|-------|-----------|
| Dovetail HTTP | `TragarAi.Dovetail.Client`, `TragarAi.Dovetail.TokenStore` |
| Freshdesk HTTP | `TragarAi.Freshdesk.Client` |
| Logistics domain (Ash) | `TragarAi.Logistics`, `…Logistics.Shipment` |
| Support domain (Ash) | `TragarAi.Support`, `…Support.Ticket` |
| Integration domain (Ash) | `TragarAi.Integration`, `…Integration.SyncEvent` |
| Orchestration | `TragarAi.Integration.Sync`, `…IngestTicketWorker` (Oban) |
| Web | `TragarAiWeb.WebhookController`, AshAdmin |

All persisted state lives in Postgres via `AshPostgres`. The `Shipment` and
`Ticket` resources are *caches/mirrors* of upstream data keyed by waybill number
and Freshdesk id respectively; the `raw` column always retains the full payload.

## Setup

```bash
# 1. Configure credentials
cp .env.example .env   # then fill in Dovetail + Freshdesk values
# load them into your shell (e.g. with direnv, or `set -a; source .env; set +a`)

# 2. Install deps, create DB, run migrations
mix setup

# 3. Start the server
mix phx.server
```

- App: <http://localhost:4000>
- Admin: <http://localhost:4000/admin> (dev only)
- LiveDashboard: <http://localhost:4000/dev/dashboard>

## Configuration

All external configuration is read at runtime in
[`config/runtime.exs`](config/runtime.exs) from environment variables — see
[`.env.example`](.env.example). Nothing secret is compiled in.

## Usage examples

```elixir
# Track a shipment from Dovetail and cache it locally
{:ok, shipment} = TragarAi.Integration.Sync.track_shipment("WB1234567")

# Mirror a Freshdesk ticket payload (also done automatically via the webhook)
{:ok, ticket} = TragarAi.Integration.Sync.ingest_ticket(payload)

# Raise a Freshdesk ticket for a shipment exception
{:ok, ticket} = TragarAi.Integration.Sync.raise_ticket_for_shipment(shipment)

# Direct client calls
{:ok, rates} = TragarAi.Dovetail.Client.quick_quote(%{...})
{:ok, tickets} = TragarAi.Freshdesk.Client.list_tickets(%{updated_since: "2026-01-01T00:00:00Z"})
```

## Freshdesk webhook

Create a Freshdesk automation / webhook that POSTs ticket JSON to:

```
POST https://<your-host>/webhooks/freshdesk
x-webhook-token: <FRESHDESK_WEBHOOK_SECRET>
```

(or pass `?token=<secret>`). The endpoint returns `202 Accepted` and processes
the payload via an Oban job.

## Status / next steps

This is the project scaffold. Likely follow-ups once the precise integration
flow is confirmed:

- Tighten the waybill-number detection regex to Tragar's real format
  (`TragarAi.Integration.Sync.scan_for_waybill/1`).
- Add `AshOban` triggers for scheduled reconciliation instead of ad-hoc calls.
- Map more FreightWare response fields onto `Shipment` columns as needed.
- Put `/admin` behind real authentication before any non-dev deployment.
