# Exposing `/api` to Freshdesk via Cloudflare Tunnel

Goal: **Freshworks' cloud can reach only `/api/*`, only from Freshworks' IPs, only
with our bearer token** — and the rest of the app (Dashboard, Console, Chat,
`/admin`) is never public; it stays on Tailscale/LAN.

The Studio makes an **outbound** connection to Cloudflare, which publishes a public
HTTPS hostname and forwards it back down the tunnel. No inbound ports are opened.

```
Freshdesk ──HTTPS──▶ Cloudflare edge ──tunnel──▶ Studio :4000  (/api/* only)
            (WAF: only Freshworks IPs)            (bearer + requester→account gate)
```

## Layered "only Freshdesk" controls
1. **Path** — the tunnel publishes only `/api/*`; all other paths/hosts → 404 publicly.
2. **Network** — a Cloudflare **WAF rule** allows only Freshworks' egress IPs.
3. **Credential** — the app's bearer token (`TRAGAR_API_KEY`) + the requester→account
   gate, behind Cloudflare as defense-in-depth.

The browser UIs keep working over Tailscale exactly as before — Cloudflare is only
the Freshdesk → API door.

---

## 1. Pick the public hostname
e.g. `tragar-api.tragar.co.za` (your domain must be on Cloudflare). Referred to as
`<API_HOST>` below.

## 2. Install cloudflared on the Studio
```bash
brew install cloudflared
cloudflared tunnel login          # browser → authorize the domain
```

## 3. Create the tunnel + DNS
```bash
cloudflared tunnel create tragar-api          # prints a UUID + writes ~/.cloudflared/<UUID>.json
cloudflared tunnel route dns tragar-api <API_HOST>
```

## 4. Config — publish ONLY `/api/*`
Copy [`cloudflared/config.yml.example`](../cloudflared/config.yml.example) to
`~/.cloudflared/config.yml` and fill in `<UUID>` + `<API_HOST>`.

## 5. Run it as a service (starts at boot)
```bash
sudo cloudflared --config /Users/tragarai/.cloudflared/config.yml service install
sudo launchctl print system/com.cloudflare.cloudflared | grep -i state
```
(macOS installs a LaunchDaemon — runs at boot, no GUI session needed.)

## 6. WAF rule — only Freshworks IPs (the key lock)
Cloudflare dashboard → **Security → WAF → Custom rules → Create**:

- **If:** `Hostname equals <API_HOST>` **AND NOT** `IP Source Address is in <freshworks list>`
- **Then:** **Block**

Best practice: create a Cloudflare **IP List** named `freshworks` with your region's
CIDRs (+ the two global IPs), then the rule expression is:

```
(http.host eq "<API_HOST>") and not (ip.src in $freshworks)
```

### Freshworks egress IPs
> ⚠️ Freshworks updates these periodically — **always reconcile against the live
> article** and keep the WAF list (and `TRAGAR_API_ALLOWED_IPS`) in sync, or new
> Freshworks IPs get blocked. Authoritative, region-specific list:
> <https://support.freshdesk.com/support/solutions/articles/50000005619-allowlist-nat-ips>

**Global (all regions, always include):** `162.159.140.147`, `172.66.0.145`

**EU (Frankfurt/Ireland) — recommended for South Africa (lowest latency)** *(snapshot 2026-06; verify):*
```
52.16.90.140, 52.17.38.68, 54.154.255.176/30, 54.154.255.186, 52.57.69.21,
52.28.165.113, 52.57.168.188, 18.184.214.37, 18.184.155.228, 18.197.138.225,
3.74.148.8/30, 35.158.67.243, 35.158.71.15, 35.156.130.117, 3.66.115.16,
18.197.225.139, 18.194.35.50, 18.194.199.3, 18.184.82.138
```

> The region must match **where your Freshdesk account actually lives** (Admin →
> Account → data centre), not a preference — the egress IPs come from that DC. If
> your account is US/India/Australia, use that region's set from the article instead.

## 7. App env (`/Users/tragarai/apps/tragar_ai/.env.prod`)
```dotenv
TRAGAR_API_KEY=<bearer secret>                 # openssl rand -hex 32
TRAGAR_API_CLIENT_IP_HEADER=cf-connecting-ip   # app reads the real client IP from Cloudflare
# TRAGAR_API_ALLOWED_IPS=<Freshworks CIDRs>    # optional belt-and-braces; WAF is primary
```
Restart: `launchctl kickstart -k gui/$(id -u)/com.tragar.tragar_ai`

## 8. Freshdesk automation
Trigger Webhook → `https://<API_HOST>/api/tickets/answer`, header
`Authorization: Bearer <TRAGAR_API_KEY>`.

## Optional — a second credential (Cloudflare Access service token)
Put **Cloudflare Access** on `<API_HOST>/api/*` and have the Freshdesk automation also
send `CF-Access-Client-Id` / `CF-Access-Client-Secret` headers. Then even a leaked
bearer + spoofed IP can't pass the edge. Recommended if you want belt-and-braces.

## Verify
```bash
# from a non-Freshworks IP → blocked at the edge
curl -i https://<API_HOST>/api/tickets/answer
# UI is not exposed publicly
curl -i https://<API_HOST>/                    # → 404
```

## Testing variant (no DNS/WAF, throwaway)
```bash
cloudflared tunnel --url http://localhost:4000   # prints a temporary https://<random>.trycloudflare.com
```
Use the temporary URL's `/api/tickets/answer` for a quick test, then switch to the
named tunnel + WAF rule for production.
