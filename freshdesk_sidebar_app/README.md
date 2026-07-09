# Tragar AI — Freshdesk ticket-sidebar app

An interactive assist chat that renders in the Freshdesk **ticket sidebar**. The
agent asks Tragar AI about the open ticket (a waybill, a shipper reference, a
quote); each turn is answered **synchronously** and scoped, server-side, to the
ticket requester's entitled FreightWare accounts (with account cycling). Nothing
is posted to the ticket — this is a live agent tool, not the note automation.

## How it talks to Tragar AI

Calls **`POST /api/tickets/chat`** on the Tragar AI backend via the Freshworks
**Request Method** (`config/requests.json` → `tragarChat`), so the request is
proxied through Freshworks' servers (source IP = Freshworks egress, already in the
`/api` allowlist) and the bearer token stays server-side (never in the browser).

Request body: `{ "ticket_id": "55", "message": "where is 4821", "history": [...] }`
Response: `{ "ticket_id", "reply", "resolved", "options": [{ "value", "label" }] }`

## Layout

```
manifest.json          ticket_sidebar location + declared request template
config/iparams.json     install-time params: tragar_domain, tragar_api_key (secure)
config/requests.json    the secure POST /api/tickets/chat template
app/index.html          markup
app/scripts/app.js      chat logic (ticket context, send, render, options)
app/styles/style.css    styling
app/icon.svg            sidebar icon
```

## Develop & test

Requires Node 18.13+ and the [FDK CLI](https://developers.freshworks.com/docs/app-sdk/v2.3/freshdesk/app-development-process/).

```bash
fdk run
```

Then open a real ticket with the dev flag:
`https://<subdomain>.freshdesk.com/a/tickets/<id>?dev=true` — the app renders in
the sidebar. It will prompt for the iparams (`tragar_domain`, `tragar_api_key`)
on first run.

## Pack & install (private / custom app)

```bash
fdk validate
fdk pack        # -> dist/<app>.zip
```

In Freshdesk: **Admin → Apps → Get more apps → Custom Apps → Upload**, install,
and set:

- `tragar_domain` — host only, e.g. `assist.tragar.ai` (no scheme/path)
- `tragar_api_key` — the same bearer minted as `TRAGAR_API_KEY` for `/api`

## Notes

- No Cloudflare change is needed: this hits the same `/api` path/gates the
  existing `POST /api/tickets/answer` webhook already passes (IP allowlist +
  bearer). Only if Cloudflare Access/WAF is configured to challenge `/api` would
  you need a bypass/service-token — same as the existing webhook.
- `platform-version` / `engines.fdk` may need bumping to match your installed FDK
  version; run `fdk validate` and follow its guidance.
