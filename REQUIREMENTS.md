# Tragar AI — Requirements

> Derived from the Master Document (*Tragar · On-Premises AI System*) and the
> *Implementation Plan*. Living document; implementation status per section.

## 1. Purpose

An **on-premises AI system** running on one Mac mini at Tragar. It pulls live
facts from Tragar's source systems, hosts a small local AI model, computes
business knowledge, and answers questions — staff, management and (via agents)
customers. No cloud; data never leaves the building (POPIA). Survives
loadshedding (UPS + Postgres + Oban).

## 2. Architecture

**One front door → three lanes**, with a small local model as the interpreter:

| Lane | Question type | How it answers | Freshness |
|---|---|---|---|
| Live facts | "Where is load 4821?" | Elixir fetches live, fills a template | Instant |
| Batch intelligence | "How are we doing?" | Pre-computed findings from Postgres | Scheduled |
| Live reasoning | "Why did Durban slip?" | Local model over live data + findings | On demand |

**The safe loop:** `question → Core AI interprets → structured request → Elixir
VALIDATES (allowed? exists? permitted?) → fetches read-only fact → Core AI
phrases → agent reviews/edits → relays`. The model is **only** interpreter and
phraser — never the authority on a fact, never touching source systems, never
speaking to the customer directly.

**Core AI** = a small local model reached over local HTTP (the Swift sidecar);
swappable for a larger model on a Mac Studio with no architecture change.

**Six read-only sources:** FreightWare (load status/ETA/waybill/POD), Vantage
(route/ETA/distance), Granite/WMS (stock/pick-pack/receipts), Pastel
(invoice/balance/payment), FleetIT (vehicle cost/availability — own-fleet CPK),
Freshdesk (ticket context + customer).

**Resilience:** durable state in Postgres; work-to-do in Oban (re-runs on
restart); UPS clean shutdown; in-memory data disposable.

## 3. Implementation Plan (phases)

1. **Support assist** — live facts, interpret & phrase, agent console.
2. **Knowledge layer** — event-driven operating-state findings
   (change-detection, dirty-and-reconcile via Oban, findings store; dated
   dataset versioning).
3. **Descriptive analytics** — gross margin & route scorecard (Nx/Scholar),
   conversational retrieval over findings.
4. **Predict & prescribe** (optional) — sentiment (two-stage), forecasting,
   HiGHS optimisation; training-management layer only when a prediction project
   is committed.

## 4. Analytics objectives (operating state — Phases 2–4)

A continuously-reconciled operating state across four dimensions (per lane / per
customer / per vehicle-cost / per area-rate), surfaced three ways: describe
(computation), project (optional training), act (HiGHS).

- **Gross margin** (computation) — per-waybill revenue (area-rate billing;
  chargeable_kg = max(actual, volumetric); kg charge floored at area minimum,
  grossed by fuel surcharge, then document fee + address surcharges added flat)
  minus cost by who moved it (own-fleet CPK from FleetIT / owner-driver /
  3rd-party from Pastel AP). Effective-dated rates; report standard vs realised.
- **Problematic routes** (computation) — per-lane scorecard: profitability,
  reliability, empty-running, standing time, vehicle availability, trend. New
  data: promised/SLA time, directional flow, FleetIT maintenance/downtime.
- **Customer sentiment** (pre-trained model + computation) — Stage 1: model
  scores Freshdesk ticket text → sentiment + themes; Stage 2: Nx rolls up per
  customer, joins to margin/value, correlates with churn.

Computation is correct-by-construction (dataset versioning, no training layer);
training is added only for prediction/custom classifier.

## 5. Hardware

Mac mini (M4 Pro, 64 GB, 1 TB) + UPS (~R33–38k once-off), runs every phase.
Optional: Mac Studio (larger local model, Phase 4) or MacBook M5 Max (training
pipeline) — both keep data on-premises.

## 6. Implementation status

**Phase 1 — Support assist ✅ (this build)**
- Core AI client `TragarAi.CoreAI` with `:stub` (deterministic in-process
  interpret/phrase) and `:http` (local sidecar) modes — identical contract.
- Validate-before-act `TragarAi.Assist.Validator`.
- Safe loop `TragarAi.Assist.Engine`; audit/history `TragarAi.Assist.Interaction`.
- Connector behaviour + registry `TragarAi.Connectors`; FreightWare + Freshdesk
  wired; Vantage/Granite/Pastel/FleetIT declared + `:not_available` until access.
- LiveView agent console `TragarAiWeb.ConsoleLive` at `/console` (agent-in-the-loop).
- 21 tests; `mix compile --warnings-as-errors` clean.

**Pending / next**
- Provision read-only access for Vantage, Granite, Pastel, FleetIT (Phase 1 audit
  per plan §5.5; confirm capture mechanism per source).
- Stand up the real Core AI Swift sidecar; flip `CORE_AI_MODE=http`.
- Phase 2: change-detection + findings store (operating state).
- Auth on `/console` and `/admin` before non-dev use.
