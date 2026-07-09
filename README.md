# Tragar AI

An **on-premises AI system** for Tragar, built per the Master Document and
Implementation Plan. One Mac mini runs everything — it pulls live facts from
Tragar's source systems, hosts a small local AI model, and helps support agents
answer customers. No cloud; data never leaves the building (POPIA). Elixir / Ash
+ Phoenix, Postgres, Oban — one runtime that survives loadshedding.

## Architecture (the safe loop)

```
question → Core AI interprets → structured request
         → Elixir VALIDATES (allowed? exists? permitted?)
         → fetches the live fact (read-only)
         → Core AI phrases → draft answer → agent reviews/edits → relays
```

The local model is **only** an interpreter and phraser — never the authority on
a fact, never touching the source systems, never speaking to the customer
directly. Elixir validates every model-proposed request before any lookup.

## Phase 1 — Support assist (this build)

A LiveView agent console at **`/console`**: an agent enters a customer question
(optionally a waybill / ticket / account), the system drafts an answer from live
source-system facts, and the agent reviews, edits and relays it.

| Component | Module |
|---|---|
| Core AI (local model, Swift sidecar) | `TragarAi.CoreAI` (+ `…CoreAI.Stub`) |
| Validate-before-act | `TragarAi.Assist.Validator` |
| Safe loop orchestration | `TragarAi.Assist.Engine` |
| Interaction history / audit | `TragarAi.Assist.Interaction` |
| Connector behaviour + registry | `TragarAi.Connectors` (+ `…Connectors.Source`) |
| Agent console | `TragarAiWeb.ConsoleLive` |

### Source connectors (read-only)

| Source | Live facts | Status |
|---|---|---|
| FreightWare (Dovetail) | load/consignment status, ETA, waybill, POD | **wired** |
| Freshdesk | ticket context + customer | **wired** |
| Vantage | planned route, ETA, distance | stub (access pending) |
| Granite (WMS) | stock, pick/pack, receipts | stub (access pending) |
| Pastel | invoice, balance, payment | stub (access pending) |
| FleetIT | vehicle status / availability | stub (access pending) |

A stubbed source returns `:not_available`, and the loop fails safe with a
message the agent can replace.

### Core AI modes

`config :tragar_ai, TragarAi.CoreAI, mode: :stub | :http`.

- `:stub` (default) — a deterministic rule/template interpreter+phraser runs
  in-process, so the whole loop works today **without a model**.
- `:http` — POST to the local sidecar at `CORE_AI_URL` (`/interpret`, `/phrase`).
  Swap in the real local model with no other change.

## Setup

```bash
mix setup          # deps, create DB, migrate, build assets
mix phx.server     # http://localhost:4000
```

- Agent console: <http://localhost:4000/console>
- Admin (dev): <http://localhost:4000/admin> · Dashboard: <http://localhost:4000/dev/dashboard>

Source credentials are read at runtime from env (see `.env.example`):
FreightWare (`DOVETAIL_*`), Freshdesk (`FRESHDESK_*`), Core AI (`CORE_AI_MODE`,
`CORE_AI_URL`).

## Freshdesk ticket-sidebar app

An in-Freshdesk agent chat (a Freshworks app) talks to Tragar AI via
`POST /api/tickets/chat`. Source and setup: [`freshdesk_sidebar_app/`](freshdesk_sidebar_app/)
— [overview](freshdesk_sidebar_app/README.md) · [install guide](freshdesk_sidebar_app/SETUP.md).

## Roadmap (Implementation Plan)

- **Phase 1 — Support assist** ✅ (this build): live facts, interpret & phrase.
- **Phase 2 — Knowledge layer**: event-driven operating-state findings
  (change-detection, dirty-and-reconcile via Oban, findings store).
- **Phase 3 — Descriptive analytics**: gross margin & route scorecard (Nx /
  Scholar), conversational retrieval over findings.
- **Phase 4 — Predict & prescribe** (optional): sentiment, forecasting, HiGHS
  optimisation.

See `REQUIREMENTS.md` for the full spec and the detailed analytics objectives.
