# Deploying Tragar AI to the on-prem mini (CI/CD)

Pull-based, outbound-only — the mini never needs an inbound port. CI on GitHub
tests and builds an image; a self-hosted runner **on the mini** pulls it,
migrates, and restarts.

```
push → GitHub Actions: test → build image → push to GHCR
                                   │
   mini's self-hosted runner ◄─────┘  (outbound)
        → docker compose pull → migrate → up -d → /health check
```

## One-time setup on the mini

### 1. Install Docker
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER   # re-login after this
```

### 2. App directory + files
```bash
mkdir -p ~/tragar && cd ~/tragar
# copy docker-compose.yml here (from the repo)
```

### 3. Create `.env` (secrets — never committed)
```dotenv
# Production release essentials
SECRET_KEY_BASE=        # generate: docker run --rm ghcr.io/raathmd/tragar_ai:latest /app/bin/tragar_ai eval 'IO.puts(:crypto.strong_rand_bytes(48) |> Base.encode64())'
PHX_HOST=tragar.local   # the host the app is served on
DATABASE_URL=ecto://postgres:postgres@db/tragar_ai_prod
POSTGRES_PASSWORD=<set a strong one, match DATABASE_URL>

# FreightWare (prod set) + flip the env
DOVETAIL_ENV=prod
DOVETAIL_PROD_BASE_URL=
DOVETAIL_PROD_USERNAME=
DOVETAIL_PROD_PASSWORD=
DOVETAIL_PROD_STATION=

# Vantage, Freshdesk, inbound API auth
VANTAGE_EMAIL=
VANTAGE_PASSWORD=
FRESHDESK_DOMAIN=
FRESHDESK_API_KEY=
TRAGAR_API_KEY=         # mint: openssl rand -hex 32
TRAGAR_API_ALLOWED_IPS=
```
(`docker-compose.yml` references `.env` via `env_file:` — `runtime.exs`'s dotenv
loader is dev-only; in the container these are real env vars.)

### 4. Register the GitHub Actions self-hosted runner
Repo → **Settings → Actions → Runners → New self-hosted runner** → follow the
Linux steps on the mini, then add the **label `tragar-mini`** (the deploy job
targets `runs-on: [self-hosted, tragar-mini]`). Install it as a service:
```bash
sudo ./svc.sh install && sudo ./svc.sh start
```

### 5. GHCR access
The deploy job `docker login`s to GHCR with the workflow token. Make sure the
package is linked to the repo (first successful `build` job creates + links it).
For a manual pull/test on the mini:
```bash
echo <a-read-PAT> | docker login ghcr.io -u <github-user> --password-stdin
docker compose pull
```

## Day-to-day flow
1. Open a PR → **CI** runs `mix test`.
2. Merge to `main` → **Deploy**: test → build image (GHCR `:latest` + `:<sha>`) →
   the mini's runner pulls, runs `/app/bin/migrate`, restarts, and checks `/health`.
3. If `/health` fails the job goes red; the previous container/image is still
   present for rollback.

## Rollback
```bash
cd ~/tragar
IMAGE=ghcr.io/raathmd/tragar_ai:<previous-sha> docker compose up -d app
```

## Backups (recommended)
Nightly `pg_dump` via cron on the mini:
```bash
0 2 * * * docker compose -f ~/tragar/docker-compose.yml exec -T db \
  pg_dump -U postgres tragar_ai_prod | gzip > ~/backups/tragar_$(date +\%F).sql.gz
```
