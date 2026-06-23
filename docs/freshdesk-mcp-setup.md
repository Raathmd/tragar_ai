# Freshdesk ↔ Tragar quote-intake: setup & security

The quote workflow is exposed two ways, both on the `/api` surface and behind the
same gates:

- **REST**: `GET /api/quotes/workflow`, `POST /api/quotes/intake`
- **MCP** (for Freddy): `POST /api/mcp` (JSON-RPC 2.0) — tools `quote_workflow`, `quote_intake`

## Security gates (all enforced on `/api/*`)

| Gate | Question | Mechanism |
|---|---|---|
| IP allowlist | Is it from Freshworks' network? | `Plugs.IpAllowlist` — `TRAGAR_API_ALLOWED_IPS` |
| Bearer token | Is it Freshworks' credential? | `Plugs.ApiAuth` — `Authorization: Bearer $TRAGAR_API_KEY` |
| MCP session | Did it handshake? | `Mcp-Session-Id` from `initialize` (MCP only) |
| Requester/email | Is it a real customer of that account? | account derived from the ticket's Freshdesk Company `cf_account` |

A request must pass **all** of them. The account is **never** taken from the
request body — it's derived from the verified requester.

## Environment

```
TRAGAR_API_KEY=<random secret>            # the bearer Freddy sends; mint with: openssl rand -hex 32
TRAGAR_API_ALLOWED_IPS=<csv of CIDRs>     # Freshworks egress (see below). Unset = allow all (dev only)
TRAGAR_API_CLIENT_IP_HEADER=cf-connecting-ip   # behind Cloudflare Tunnel — read real client IP from this header
TRAGAR_API_TRUST_XFF=1                     # alternative: plain proxy/LB (reads right-most X-Forwarded-For)
FRESHDESK_DOMAIN=<sub>                      # e.g. "tragar"  → https://tragar.freshdesk.com
FRESHDESK_API_KEY=<freshdesk agent key>    # our app -> Freshdesk (read ticket / post reply)
FRESHDESK_ACCOUNT_FIELD=cf_account         # Company custom field holding the account code(s)
DOVETAIL_BASE_URL / DOVETAIL_USERNAME / DOVETAIL_PASSWORD / DOVETAIL_STATION   # FreightWare
```

## Freshworks egress IPs (snapshot 2026-06 — verify against the live article)

Authoritative, region-specific list: <https://support.freshdesk.com/support/solutions/articles/50000005619-allowlist-nat-ips>.
Use **your account's region**. The plug accepts bare IPs (treated as `/32`) and
CIDRs; ranges shown as `x-y` are a contiguous block (e.g. `44.206.73.232-239` =
`44.206.73.232/29`). Always include the two global IPs.

- **Global (all regions):** `162.159.140.147`, `172.66.0.145`
- **US:** 52.70.237.175, 18.233.117.211, 54.172.69.206, 54.152.41.238, 54.175.228.53, 52.86.96.27, 34.202.174.188, 35.168.222.30, 52.203.5.138, 44.206.73.232/29, 34.198.193.174, 34.199.167.230, 54.227.64.103, 54.221.106.6, 54.165.99.40, 54.146.103.253, 44.216.174.188, 34.230.240.236, 3.234.114.191, 3.208.162.241
- **EU (Frankfurt/Ireland):** 52.16.90.140, 52.17.38.68, 54.154.255.176/30, 54.154.255.186, 52.57.69.21, 52.28.165.113, 52.57.168.188, 18.184.214.37, 18.184.155.228, 18.197.138.225, 3.74.148.8/30, 35.158.67.243, 35.158.71.15, 35.156.130.117, 3.66.115.16, 18.197.225.139, 18.194.35.50, 18.194.199.3, 18.184.82.138
- **India, Australia, Middle East, EU-North:** see the article.

> ⚠️ Freshworks updates this list periodically — re-check the article and keep
> `TRAGAR_API_ALLOWED_IPS` in sync, or new Freshworks IPs will get a `403`.

## Register the MCP server in Freshdesk

1. **AI Agent Studio → MCP Gateway** → add a **Remote / HTTP MCP server**.
2. **URL:** `https://<your-public-host>/api/mcp` (Freddy is cloud-hosted — must be a public HTTPS URL; use `ngrok http 4000` for testing).
3. **Authentication:** **Bearer Token** = `TRAGAR_API_KEY`.
4. Save & connect — Freshworks discovers `quote_workflow` + `quote_intake`.
5. In the Agent's workflow, call `quote_intake` with `ticket_id = {{ticket.id}}` and the customer message; post the tool's `reply` back; loop until `structuredContent.complete`.

## Freshdesk data setup

- Tag each **Company** with custom field `cf_account` = the FreightWare account code(s) (`ITD02`, or `ITD01, ITD02` for multiple — the flow then asks which).
- Add customer emails as **Contacts** in that Company (auto-associate by domain, or manually). A requester with no linked Company/account is refused.

---

# Exposing `/api` from on-prem — firewall / DMZ spec

The MCP endpoint must be reachable from Freshworks' cloud (Freddy → our MCP). Two
ways; pick one. The app's own gates (IP allowlist → bearer → MCP session → email)
run **behind** whichever you choose, as defense-in-depth.

## Option A — Firewall / DMZ appliance (full on-prem ownership)

### Spec to hand a reseller / IT provider
> "NGFW to **publish a single internal HTTPS app** to the internet, **restricted by
> source IP**, with **reverse-proxy / WAF** and a **DMZ** segment — small office."

Suitable all-in-one boxes (available in SA): **Sophos XGS 87/107**, **FortiGate
40F/60F/70F**, **SonicWall TZ**, or **MikroTik + a Caddy/nginx reverse-proxy host**
(budget). Buy box **+ subscription/licence** (enables WAF/IPS/updates).

### Firewall rules
1. **Published service (reverse proxy / VIP / WAF):**
   - Public hostname: `tools.tragar.co.za` → internal `http(s)://<tragar-ai-host>:4000`
   - **Path allowlist:** forward **only** `/api/` (and `/api/mcp`). Block `/console`, `/admin`, `/dev`, `/`.
   - **TLS:** terminate at the appliance (Let's Encrypt or a purchased cert for the hostname). Inbound **443 only**.
2. **Source-IP policy (the key control):** allow inbound to that service **only from
   Freshworks NAT egress IPs** (your region's set — see list above). Deny all other sources.
3. **DMZ segmentation:** publish from a DMZ zone; the only path from DMZ → internal LAN
   is to `<tragar-ai-host>:4000`. No other internal access from the published service.
4. (Optional) Rate-limit the published service to blunt abuse.

### App env behind the appliance (so its IP allowlist sees the real client)
The appliance reverse-proxies, so set the forwarded-IP header on it and tell the app:
```
TRAGAR_API_TRUST_XFF=1                  # appliance sets X-Forwarded-For with the client IP
# (or) TRAGAR_API_CLIENT_IP_HEADER=<header the appliance uses>
TRAGAR_API_ALLOWED_IPS=<Freshworks NAT CIDRs>   # belt-and-braces; the appliance is primary
TRAGAR_API_KEY=<bearer>
```
If the appliance already enforces the Freshworks source-IP policy, the app's
`TRAGAR_API_ALLOWED_IPS` is optional (redundant defense) — but harmless to keep.

## Option B — Cloudflare Tunnel (no inbound ports, no hardware)

1. Install `cloudflared` on (or near) the Tragar AI host; create a tunnel to a Cloudflare hostname.
2. Cloudflare config:
   - Route **only** `/api/*` to `http://localhost:4000`; TLS is automatic at Cloudflare.
   - **WAF rule:** allow only Freshworks NAT IPs; block the rest.
3. App env:
```
TRAGAR_API_CLIENT_IP_HEADER=cf-connecting-ip    # real client IP from Cloudflare
TRAGAR_API_KEY=<bearer>
```
No inbound firewall ports are opened; the box stays fully private.

## Either way — register in Freshdesk
Use the public hostname for the MCP server URL: `https://tools.tragar.co.za/api/mcp`
(Option A) or `https://<name>.<cloudflare-domain>/api/mcp` (Option B), with Bearer
auth = `TRAGAR_API_KEY`.
