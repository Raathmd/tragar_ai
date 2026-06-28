# Public access via Cloudflare Tunnel (one domain)

One public hostname — e.g. **`app.tragar.co.za`** — serves **both** the management
UI and the Freshdesk API. The Studio makes an **outbound** connection to
Cloudflare (no inbound ports), and **Cloudflare Access + WAF split the host by
path at the edge**:

```
                         ┌─ /api/*  → Access: Bypass + WAF (Freshworks IPs only) + app bearer   ← Freshdesk
app.tragar.co.za ──tunnel┤
                         └─ /*      → Access: Allow @tragar.co.za (Microsoft Entra SSO)          ← management
                                        ↓
                                   Studio :4000
```

The tunnel just forwards the whole host to the app; the **edge policies** decide
who reaches what. The internal Tailscale/LAN access keeps working unchanged.

## Controls per path
| Path | Who | Edge control | App control |
|---|---|---|---|
| `/api/*` | Freshdesk (machine) | Access **Bypass** + **WAF**: only Freshworks IPs | bearer token + requester→account gate |
| everything else | management (humans) | Access **Allow** `@tragar.co.za` via Entra SSO | — (Access is the auth) |

`/api` is IP-locked by the WAF *and* the app's own allowlist, so a signed-in
manager can't reach it from a home IP either.

---

## 1. Hostname
Pick `<APP_HOST>` (e.g. `app.tragar.co.za`); your domain must be on Cloudflare.

## 2. Install cloudflared on the Studio
```bash
brew install cloudflared
cloudflared tunnel login          # browser → authorize the domain
```

## 3. Create the tunnel + DNS
```bash
cloudflared tunnel create tragar          # prints a UUID + writes ~/.cloudflared/<UUID>.json
cloudflared tunnel route dns tragar <APP_HOST>
```

## 4. Config — forward the whole host
Copy [`cloudflared/config.yml.example`](../cloudflared/config.yml.example) to
`~/.cloudflared/config.yml` and fill in `<UUID>` + `<APP_HOST>`.

## 5. Run it as a service (starts at boot)
```bash
sudo cloudflared --config /Users/tragarai/.cloudflared/config.yml service install
sudo launchctl print system/com.cloudflare.cloudflared | grep -i state
```

## 6. Cloudflare Access — Microsoft Entra SSO for the UI
In **Cloudflare Zero Trust** dashboard (one-time Entra wiring, then two apps):

**a. Add the identity provider** — Settings → Authentication → Login methods →
Add **Azure AD / Microsoft Entra ID**. You'll register an app in Entra (Azure
portal → App registrations) and paste its **Application (client) ID**, a
**client secret**, and **Directory (tenant) ID** into Cloudflare; grant the
Graph `User.Read` / `email`, `openid`, `profile` permissions. Test the connection.

**b. Access app for the UI** — Access → Applications → Add a **Self-hosted** app:
- **Domain:** `<APP_HOST>` (leave path blank = whole host)
- **Policy:** *Allow* → Include → **Emails ending in** `@tragar.co.za` (or list the
  2–5 specific addresses). Identity provider: the Entra method from (a).
- Session duration to taste (e.g. 24h).

**c. Access app for `/api` (so Freshdesk isn't challenged)** — add a **second**
Self-hosted app, more specific so it's matched first:
- **Domain:** `<APP_HOST>`, **Path:** `/api`
- **Policy:** *Bypass* → Include → **Everyone**. (No SSO on `/api`; it's gated by
  the WAF IP rule + the app bearer instead.)

Cloudflare evaluates the path app first, so `/api/*` bypasses SSO and everything
else requires an `@tragar.co.za` Entra login.

## 7. WAF rule — `/api` only from Freshworks IPs
Security → WAF → Custom rules → Create:
- **Expression:** `(http.host eq "<APP_HOST>") and starts_with(http.request.uri.path, "/api") and not (ip.src in $freshworks)`
- **Action:** **Block**

Create a Cloudflare **IP List** named `freshworks` with your region's CIDRs + the
two globals.

> ⚠️ Freshworks updates these periodically — reconcile against the live article and
> keep the list (and `TRAGAR_API_ALLOWED_IPS`) in sync:
> <https://support.freshdesk.com/support/solutions/articles/50000005619-allowlist-nat-ips>

**Global (always include):** `162.159.140.147`, `172.66.0.145`

**EU (Frankfurt/Ireland) — lowest latency for South Africa** *(snapshot 2026-06; verify):*
```
52.16.90.140, 52.17.38.68, 54.154.255.176/30, 54.154.255.186, 52.57.69.21,
52.28.165.113, 52.57.168.188, 18.184.214.37, 18.184.155.228, 18.197.138.225,
3.74.148.8/30, 35.158.67.243, 35.158.71.15, 35.156.130.117, 3.66.115.16,
18.197.225.139, 18.194.35.50, 18.194.199.3, 18.184.82.138
```
> The region must match **where your Freshdesk account lives** (Admin → Account →
> data centre), not a preference. If it's US/India/Australia, use that set instead.

## 8. App env (`/Users/tragarai/apps/tragar_ai/.env.prod`)
```dotenv
PHX_HOST=<APP_HOST>                            # canonical host; allows the LiveView socket origin
TRAGAR_API_KEY=<bearer secret>                 # openssl rand -hex 32
TRAGAR_API_CLIENT_IP_HEADER=cf-connecting-ip   # app reads the real client IP from Cloudflare
TRAGAR_API_ALLOWED_IPS=<Freshworks CIDRs>      # belt-and-braces for /api; WAF is primary
```
Restart: `launchctl kickstart -k gui/$(id -u)/com.tragar.tragar_ai`

(Internal Tailscale/LAN access is unaffected — those hosts are still served over
HTTP and allowed as socket origins.)

## 9. Freshdesk automation
Trigger Webhook → `https://<APP_HOST>/api/tickets/answer`, header
`Authorization: Bearer <TRAGAR_API_KEY>`.

## Verify
```bash
# Management UI: opening it in a browser redirects to Microsoft sign-in, then loads.
open https://<APP_HOST>/

# /api from a non-Freshworks IP → blocked at the WAF (403)
curl -i https://<APP_HOST>/api/tickets/answer
```

## Testing variant (throwaway, no DNS/WAF/Access)
```bash
cloudflared tunnel --url http://localhost:4000   # prints a temporary https://<random>.trycloudflare.com
```
Use it to smoke-test `/api/tickets/answer`, then switch to the named tunnel +
Access + WAF for production.
