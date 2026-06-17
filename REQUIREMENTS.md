# Tragar AI Gateway — Requirements

> Status: living document. Captures the agreed scope and the open decisions for
> the FreightWare→AI gateway. Implementation status is tracked per-section.

## 1. Purpose & context

Tragar AI is an **AI gateway that wraps FreightWare and exposes it to AI agents**
— primarily Freshdesk's **Freddy** — so customers can ask for shipment status in
their support channel and have it answered from live freight data.

- **FreightWare is the source of truth** for shipment status, waybills, quotes,
  and proof-of-delivery. It is hosted on Tragar's **Dovetail** servers, so
  "Dovetail" and "FreightWare" refer to the same REST API:
  - Prod: `https://tragar-db.dovetail.co.za/WebServices/web`
  - UAT: `https://tragar-db.dovetail.co.za/WebServicesUAT/web`
  - Auth: `POST /FreightWare/V2/system/auth/login` → token in the
    `X-FreightWare` response header → returned on every subsequent request.
  - Bodies use `request` / `response` envelopes.
- **Freshdesk is the client-facing channel.** Customers ask Freddy; Freddy calls
  this gateway. The gateway never exposes another customer's data.
- Predecessor: the Rust/WASM `tragar_quote_dioxus` project
  (github.com/Raathmd/tragar_quote_dioxus), whose FreightWare conventions are
  mirrored here.

## 2. Functional requirements

### 2.1 Tool surface (implemented)
AI-callable tools, defined once in `TragarAi.Tools` and exposed over two
transports:
- `track_shipment(waybill_number)` — status + tracking events + POD. Primary
  "where is my delivery" tool.
- `list_my_shipments()` — shipments for the caller's account.
- `list_service_types()` — FreightWare service types (reference data).
- `get_quick_quote(...)` — instant rate quote for the caller's account.

### 2.2 Transports (implemented)
- **REST + OpenAPI** — `GET /api/v1/tools`, `POST /api/v1/tools/:name`, and an
  OpenAPI 3.1 spec at `GET /api/openapi.json`. This is what Freshdesk Freddy
  imports as **custom actions**, and what other OpenAPI agents consume.
- **MCP** — `POST /mcp`, JSON-RPC 2.0 over Streamable HTTP (`initialize`,
  `tools/list`, `tools/call`, `ping`). For MCP-capable agents (Claude, etc.).

### 2.3 Caching (implemented)
- Customer queries read **Elixir's `Shipment` cache** (Postgres), not FreightWare
  directly.
- **Read-through:** cache hit → return; cache miss → fetch that single waybill
  from FreightWare, verify ownership, cache it, return.
- **Background refresh:** `TragarAi.Logistics.SyncWorker` (Oban cron, every 15
  minutes) refreshes all registered accounts so most reads are hits.

### 2.4 Identity, access & isolation (implemented)
- API key presented as `Authorization: Bearer <key>` (or `x-api-key`).
- **Partner keys** (Freddy) — configured via `GATEWAY_PARTNER_API_KEYS`. May
  request access on a customer's behalf; **may not read customer data**.
- **Account keys** — DB-backed `TragarAi.Accounts.ApiClient`, locked to one
  `account_reference`. Only the **SHA-256 hash** of the key is stored.
- **Account scoping:** every data tool verifies `waybill.accountReference ==
  caller account`; a mismatch returns **404** (never another account's data, and
  never even confirms the waybill exists).

### 2.5 Registration / magic-link flow (implemented)
1. Freddy (partner key) `POST /api/v1/access-requests {account_reference, email}`.
2. Gateway verifies the account exists **and** the email matches the
   authoritative `Account.email` (case-insensitive).
3. On match → create a `pending` `ApiClient` + email the customer a magic link.
   Always responds `202` regardless of match (anti-enumeration).
4. Customer opens `GET /activate/:token` → an API key is generated, shown
   **once**, and the client is activated.
5. Activated key is used by Freshdesk, constrained to that account.
- Admin/seed/test provisioning bypass: `Registration.provision_account_key/2`.

## 3. Non-functional requirements
- **Security:** secrets never logged or stored in plaintext (keys/tokens hashed);
  ownership enforced centrally in the tool layer; `/admin` (AshAdmin) behind
  dev-only routing until real auth is added; all external config via env at
  runtime.
- **Auditability:** every tool invocation is logged to `TragarAi.Gateway.ToolCall`
  (tool, transport, client, outcome, duration).
- **Resilience:** Dovetail token cached and auto-refreshed on 401; Req transient
  retries; auditing/caching failures never break a tool response.
- **Tech:** Elixir, Ash 3 + Phoenix, Postgres (AshPostgres), Oban, Req.

## 4. Freshdesk ⇄ partner integration (analysis — DECISION PENDING)

How Freshdesk authenticates the **end customer** (the session):
- Support portal via SSO (SAML / OIDC / **Simple SSO JWT**), or Help
  Widget / Freshchat via **JWT user identification** (HMAC with a shared secret).
  By the time Freddy is in a conversation, Freshdesk holds a verified requester
  identity (email / contact id).

How Freshdesk connects to a **partner system** (us):
- A **connection-level credential** configured once: **API key / Bearer**, or
  **OAuth 2.0** (client-credentials = app-level token; authorization-code =
  per-installation token). OAuth authenticates *the Freshdesk integration to us*
  — it does **not** identify the individual customer.
- **Per-request context injection:** each action call carries the authenticated
  requester's email/contact id, mapped from the session into the request.
- Surfaces & auth:
  - Freddy custom actions/APIs: None / API key / Bearer / Basic / **OAuth 2.0**.
  - Marketplace app (Platform SDK `request`): **OAuth 2.0** or encrypted iparams.
  - Automation webhooks: static headers / Basic (no OAuth).

**Key consequence:** OAuth alone cannot scope to a customer. Scoping always needs
either a **per-customer key** or a **per-request signed identity**.

### 4.1 Topology A — one shared Freshdesk (all customers are contacts)
- Connect: ONE partner credential (OAuth2 client-credentials or partner API key).
- Per query: Freddy sends partner credential + the requester identity (ideally a
  **signed JWT** of the email) → gateway verifies both → maps email →
  `account_reference` → scopes.
- Trust: two layers (system + customer). Customer-typed account numbers never
  trusted.
- Code delta: add a `Freshdesk.Identity` JWT verifier (`FRESHDESK_JWT_SECRET`)
  that resolves email → `:account` scope. The per-customer magic-link key becomes
  largely unnecessary.

### 4.2 Topology B — one Freshdesk per customer
- Connect: each customer's Freshdesk holds its own **account-scoped key** (the
  magic-link-issued key). One key = one Freshdesk = one account.
- Per query: key resolves to `account_reference`; no per-request identity needed.
- Trust: single layer (the key is the account).
- Code delta: **none** — this is exactly what is implemented today.

### 4.3 Open decision
Choose **A** (shared helpdesk → add OAuth-partner + requester-JWT, retire
per-customer keys) or **B** (per-customer helpdesk → keep current build). The
"customers register as users/contacts, constrained to their account" wording
leans toward **A**. Recommended identity proof in A: **signed JWT of the
requester** (not a plain injected email).

## 5. Implementation status
- ✅ Dovetail (FreightWare) client + cached token (`TragarAi.Dovetail.*`)
- ✅ Tool core + REST/OpenAPI + MCP transports
- ✅ Account-scoped auth, ownership enforcement, audit log
- ✅ Read-through cache + 15-min background sync
- ✅ Magic-link registration + activation + email
- ⏳ Freshdesk topology decision (§4) → then OAuth-partner + requester-JWT (if A)
- ⏳ `Account` sync from FreightWare base data (currently seeded/upserted)
- ⏳ `/admin` behind real authentication before any non-dev deployment
