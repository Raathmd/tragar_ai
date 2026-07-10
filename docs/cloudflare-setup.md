# Public access via Cloudflare Tunnel (two hostnames)

**Two public hostnames**, both pointing at the same Studio app through one tunnel,
kept apart at the edge by their **own** policies:

- **`csd.tragarai.net`** — the **Freshdesk API** (machine traffic).
- **`tragarai.net`** — the **management UI** (humans).

The Studio makes an **outbound** connection to Cloudflare (no inbound ports):

```
csd.tragarai.net ─┐            ┌─ csd → WAF (Freshworks IPs only) + app bearer, no SSO   ← Freshdesk
                  ├──tunnel────┤
tragarai.net ─────┘            └─ apex → Access: Allow @tragar.co.za (Entra SSO)          ← management
                                        ↓
                                   Studio :4000
```

Each hostname is a **separate tunnel public hostname** and gets its **own edge
policy** — Access is per-hostname, so the API host must *not* inherit the UI's SSO
(and vice-versa). The internal Tailscale/LAN access keeps working unchanged.

## Controls per hostname
| Hostname | Who | Edge control | App control |
|---|---|---|---|
| `csd.tragarai.net` | Freshdesk (machine) | **WAF**: only Freshworks IPs (no Access SSO) | bearer token + requester→account gate |
| `tragarai.net` | management (humans) | Access **Allow** `@tragar.co.za` via Entra SSO | — (Access is the auth) |

`csd.tragarai.net` is IP-locked by the WAF *and* the app's own allowlist, so a
signed-in manager can't reach it from a home IP either.

---

## 1. Hostname
Use the dedicated domain **`tragarai.net`** (registered just for this — no email,
nothing else depends on it, so `tragar.co.za` is never touched). If you registered
it through **Cloudflare Registrar** it's already on Cloudflare; otherwise add
`tragarai.net` to a Cloudflare account and switch its nameservers (a fresh, empty
zone → zero risk).

> Management's Microsoft 365 / Entra sign-in is unaffected — Cloudflare Access
> authenticates the person's `@tragar.co.za` work account regardless of the app's
> domain.

## 2. Install cloudflared on the Studio
```bash
brew install cloudflared
cloudflared tunnel login          # browser → authorize the domain
```

## 3. Create the tunnel + DNS
```bash
cloudflared tunnel create tragar          # prints a UUID + writes ~/.cloudflared/<UUID>.json
cloudflared tunnel route dns tragar tragarai.net
```

## 4. Config — forward the whole host
Copy [`cloudflared/config.yml.example`](../cloudflared/config.yml.example) to
`~/.cloudflared/config.yml` and fill in `<UUID>` + `tragarai.net`.

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
- **Domain:** `tragarai.net` (leave path blank = whole host)
- **Policy:** *Allow* → Include → **Emails ending in** `@tragar.co.za` (or list the
  2–5 specific addresses). Identity provider: the Entra method from (a).
- Session duration to taste (e.g. 24h).

**c. The API host `csd.tragarai.net` (so Freshdesk isn't challenged)** — the
cleanest option is to **create no Access app for `csd`** at all, so it has no SSO;
it's gated by the WAF IP rule + the app bearer instead. Only add an Access app for
`csd.tragarai.net` if you want an explicit **Bypass → Everyone** policy on record.
> Because Access is per-hostname, a policy on `tragarai.net` does **not** cover
> `csd.tragarai.net` — the API host is independent by default.

So `csd.tragarai.net` carries no SSO (WAF + bearer only), while `tragarai.net`
requires an `@tragar.co.za` Entra login.

## 7. WAF rule — `/api` only from Freshworks IPs
This is **two steps in two different places** — the IP List lives at the **account**
level, the rule that uses it lives at the **zone (domain)** level.

**7a. Create the IP List (account level).**
`dash.cloudflare.com` → pick the account → **Manage Account → Configurations → Lists**
→ **Create new list** → type **IP List** → name it `freshworks` → add your region's
CIDRs + the two globals (below) → **Save**.
> Lists are under *Manage Account*, **not** under the domain — that's the easy thing to miss.

**7b. Create the WAF rule (zone level).**
Select the domain **tragarai.net** → **Security → WAF → Custom rules → Create rule**.
Since the whole `csd` subdomain is the API, match by host alone (no path check):
- **Expression:** `(http.host eq "csd.tragarai.net" and not ip.src in $freshworks)`
- **Action:** **Block** → **Deploy**.
> The `$freshworks` reference autocompletes once the List from 7a exists. If you don't
> see **Custom rules**, avoid **WAF → Tools → IP Access Rules** — those are zone-wide and
> would also hit the UI hostname; the custom rule above is path-scoped on purpose.

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
PHX_HOST=tragarai.net                            # canonical host; allows the LiveView socket origin
TRAGAR_API_KEY=<bearer secret>                 # openssl rand -hex 32
TRAGAR_API_CLIENT_IP_HEADER=cf-connecting-ip   # app reads the real client IP from Cloudflare
TRAGAR_API_ALLOWED_IPS=<Freshworks CIDRs>      # belt-and-braces for /api; WAF is primary
```
Restart: `launchctl kickstart -k gui/$(id -u)/com.tragar.tragar_ai`

(Internal Tailscale/LAN access is unaffected — those hosts are still served over
HTTP and allowed as socket origins.)

## 9. Freshdesk automation
Trigger Webhook → `https://csd.tragarai.net/api/tickets/answer`, header
`Authorization: Bearer <TRAGAR_API_KEY>`.

## Verify
```bash
# Management UI: opening it in a browser redirects to Microsoft sign-in, then loads.
open https://tragarai.net/

# API host from a non-Freshworks IP → blocked at the WAF (403)
curl -i https://csd.tragarai.net/api/tickets/answer
```

## Testing variant (throwaway, no DNS/WAF/Access)
```bash
cloudflared tunnel --url http://localhost:4000   # prints a temporary https://<random>.trycloudflare.com
```
Use it to smoke-test `/api/tickets/answer`, then switch to the named tunnel +
Access + WAF for production.
