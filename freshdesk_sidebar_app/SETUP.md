# Setting up the Tragar AI Freshdesk sidebar app

Step-by-step guide to build, install, and configure the ticket-sidebar chat app
that lets a Freshdesk agent talk to Tragar AI live about the open ticket.

- **Overview of what the app does:** see [`README.md`](./README.md).
- **App source:** this folder (`freshdesk_sidebar_app/`).

---

## 0. Prerequisites

**On the Tragar AI backend (must be live before the app can answer):**

1. **The answer + attachments endpoints are deployed** (`POST /api/tickets/answer`
   already exists; `GET /api/tickets/:id/attachments` ships with this app). They go
   live after `merge → CI → deploy` via the self-hosted runner. Verify the list
   endpoint with:
   ```bash
   curl -sS https://<tragar-domain>/api/tickets/<a-real-ticket-id>/attachments \
     -H "Authorization: Bearer $TRAGAR_API_KEY"
   ```
   A JSON body with an `attachments` array = ready.
2. **`TRAGAR_API_KEY` is set in prod** — the bearer the app sends. If the existing
   `POST /api/tickets/answer` webhook already works, this is already set; **reuse
   the same token**.
3. **Freshworks egress IPs are allowlisted** (`TRAGAR_API_ALLOWED_IPS`) — again,
   already true if the `/answer` webhook works, because both hit the same `/api`
   gate. No Cloudflare change is needed.

**On your dev machine (to build/upload the app):**

- **Node.js 18.13.0+**
- **FDK CLI** (Freshworks Developer Kit):
  ```bash
  npm install https://cdn.freshdev.freshworks.com/fdk/latest.tgz -g
  fdk version
  ```
  If that URL 404s, get the current install command from the
  [FDK setup guide](https://developers.freshworks.com/docs/app-sdk/v2.3/freshdesk/app-setup/).
- A Freshdesk account with **admin** access (to install custom apps).

---

## 1. Test locally (recommended before packing)

From this folder:

```bash
cd freshdesk_sidebar_app
fdk run
```

Then open a **real ticket** in your browser with the dev flag appended:

```
https://<your-subdomain>.freshdesk.com/a/tickets/<ticket-id>?dev=true
```

- The app renders in the **right sidebar**.
- On first run it prompts for the installation parameters — enter the same values
  as in step 3 below.
- Send a message (e.g. a waybill number from that ticket) and confirm a reply
  comes back.

> If the sidebar is empty, confirm the app server is running (`fdk run`) and that
> the URL has `?dev=true`.

---

## 2. Pack the app

You can either pack locally, or download a packed build from CI.

**Locally:**
```bash
./pack.sh        # runs fdk validate + fdk pack → dist/<app-name>.zip
# or manually:
fdk validate     # fix anything it reports (e.g. bump platform-version / fdk engine)
fdk pack         # produces dist/<app-name>.zip
```

**From CI (no local Node/FDK needed):** a ready-to-use GitHub Actions workflow
lives at [`ci/freshdesk-app.yml`](./ci/freshdesk-app.yml). **Copy it to
`.github/workflows/freshdesk-app.yml`** once (adding a workflow requires a
credential with GitHub's `workflow` scope — easiest via the GitHub web UI:
**Actions → New workflow → paste**). After that, every change under
`freshdesk_sidebar_app/**` (or **Actions → Freshdesk App → Run workflow**)
validates and packs the app; download the **`tragar-ai-sidebar-app`** artifact —
it's the packed `dist/*.zip`.

> **Why you still upload by hand:** Freshworks has **no API/CLI to publish a custom
> app** — it's GUI-only. CI (or `pack.sh`) validates and packs for you, but the
> upload in step 3 is a manual drag-and-drop.

`dist/<app-name>.zip` is the artifact you upload to Freshdesk.

---

## 3. Install into Freshdesk (Custom App)

This is a **private / custom** app — no marketplace submission. Use whichever path
matches your Freshdesk UI:

**Path A — inside Freshdesk:**

1. ⚙️ **Admin → Apps** (under "Helpdesk Productivity" / "Marketplace Apps").
2. **Get More Apps → Custom Apps → Upload App** (labels vary by plan/version).
3. Select `dist/<app-name>.zip`.
4. When prompted, enter the installation parameters (step below), then **Install**.

**Path B — Freshworks Developer Portal:**

1. Sign in at <https://developers.freshworks.com>.
2. **Custom Apps → Upload** the packed zip.
3. Install it onto your Freshdesk account and enter the parameters.

### Installation parameters (iparams)

| Parameter         | Value                                                                 |
|-------------------|-----------------------------------------------------------------------|
| `tragar_domain`   | Host **only** — e.g. `assist.tragar.ai` (no `https://`, no trailing path) |
| `tragar_api_key`  | The prod `TRAGAR_API_KEY` bearer (stored encrypted; never sent to the browser) |

---

## 4. Use it

Open a ticket → the **Tragar AI** panel appears in the right sidebar → click
**Ask Tragar AI**. If the ticket has attachments, tick the relevant ones and
click **Answer** (or **Answer without them**). Tragar AI extracts the chosen
attachments server-side, answers, and posts a **private note** on the ticket for
you to review — the same note flow as the automation, now driven by the app.

---

## How auth flows (why no Cloudflare change)

```
Agent's browser (sidebar app)
   └─ client.request.invokeTemplate("answer")       ← token NOT in the browser
        └─ Freshworks servers (Request Method proxy)  ← source IP = Freshworks egress
             └─ POST https://<tragar_domain>/api/tickets/answer
                  Authorization: Bearer <tragar_api_key>
                  └─ Tragar AI  :api pipeline → IpAllowlist (Freshworks egress) → ApiAuth (bearer)
```

Because the call is proxied server-side by Freshworks — the same origin and `/api`
path the existing `/answer` webhook already uses — it inherits the existing gates.
The only time a Cloudflare tweak would be needed is if Cloudflare **Access** or a
**WAF/bot challenge** is configured on `/api`; in that case add a bypass or service
token for `/api/*` — but the existing webhook already exercises that path, so it's
presumably handled.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Sidebar empty in `fdk run` | Missing `?dev=true`, or `fdk run` not running. |
| "Couldn't load the ticket context" | Open the app from within a ticket view (it needs `ticket` data). |
| Every message errors | Backend endpoint not deployed, wrong `tragar_domain` (must be host only), or wrong/absent `tragar_api_key`. |
| 401/403 from the backend | `tragar_api_key` doesn't match prod `TRAGAR_API_KEY`. |
| Request blocked / challenged | Cloudflare Access/WAF on `/api` — add a bypass or service token for `/api/*`. |
| "no waybill/quote found across the linked account(s)" | Working as intended — the reference isn't under the requester's entitled accounts. |
| `fdk validate` fails on version | Bump `platform-version` / `engines.fdk` in `manifest.json` to match your FDK. |
