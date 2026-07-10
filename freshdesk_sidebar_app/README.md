# Tragar AI — Freshdesk ticket-sidebar app

> **Setup / install instructions:** see [`SETUP.md`](./SETUP.md) for the full
> build → pack → upload → configure walkthrough. This README is an overview.

The **trigger** for the Tragar AI assist answer, rendered in the Freshdesk
**ticket sidebar** — it replaces the automation checkbox. The agent clicks **Ask
Tragar AI**; if the ticket has **readable** attachments (CSV / Excel / PDF —
images and other types are omitted entirely), a **picker** appears so they choose
which to ingest (some are irrelevant); then the app fires the existing answer
webhook with the chosen ids. Tragar AI extracts those attachments server-side,
folds their text into the answer, and posts it as a **private note** — the same
note flow as today, plus the attachments.

## How it talks to Tragar AI

Two secure calls via the Freshworks **Request Method** (`config/requests.json`),
proxied through Freshworks' servers (source IP = Freshworks egress, already in the
`/api` allowlist; bearer stays server-side):

1. `listAttachments` → **`GET /api/tickets/:id/attachments`** → `{ attachments: [{ id, name, content_type, size, supported }] }` for the picker.
2. `answer` → **`POST /api/tickets/answer`** with `{ "ticket_id": "55", "attachment_ids": [12, 34] }` → `202` (the answer is delivered as a private note, asynchronously).

No attachments → step 1 returns none and the app fires `answer` directly.

## Layout

```
manifest.json          ticket_sidebar location + declared request templates
config/iparams.json     install-time params: tragar_domain, tragar_api_key (secure)
config/requests.json    the secure listAttachments + answer templates
app/index.html          markup
app/scripts/app.js      trigger + picker logic
app/styles/style.css    styling
app/icon.svg            sidebar icon
ci/freshdesk-app.yml    GitHub Actions template (copy to .github/workflows/)
pack.sh                 local validate + pack
```

## Develop & test

Requires **Node.js 24** and **FDK 10** (platform v3.0) — see the [FDK CLI docs](https://developers.freshworks.com/docs/app-sdk/v3.0/freshdesk/app-development-process/).

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
