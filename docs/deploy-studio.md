# Deploying Tragar AI to the Mac Studio (CI/CD)

The Studio runs the app as a **native Mix release supervised by launchd** — no
Docker. On merge to `main`, GitHub Actions runs the test gate, then a
**self-hosted runner on the Studio** rebuilds the release and restarts the
service.

```
push → GitHub Actions (ubuntu): mix test
                                   │  (on success)
   Studio self-hosted runner ◄─────┘
        → git reset origin/main → mix release → migrate → launchctl restart → /health
```

The whole rebuild/restart lives in [`bin/deploy.sh`](../bin/deploy.sh); the
deploy job just invokes it, so you can also run it by hand on the Studio.

## One-time setup on the Studio

### 1. Toolchain + app checkout
Install Erlang/Elixir (matching `.tool-versions` / the CI versions) and Postgres
(e.g. `postgresql@17` via Homebrew), then clone the repo to the app dir:
```bash
git clone https://github.com/Raathmd/tragar_ai.git /Users/tragarai/apps/tragar_ai
```

### 2. Secrets — `/Users/tragarai/apps/tragar_ai/.env.prod` (never committed)
Sourced by `bin/start_prod.sh` and the migrate step. `.env.prod` is gitignored,
so `git reset --hard` during deploy never touches it.
```dotenv
PHX_SERVER=true                 # REQUIRED — without it the release boots but doesn't serve
PORT=4000
PHX_HOST=tragar.local           # advertised host for URL/HTTPS (LAN + tailnet served over HTTP)
SECRET_KEY_BASE=                # generate: mix phx.gen.secret
DATABASE_URL=ecto://USER:PASS@localhost/tragar_ai_prod

# FreightWare (prod set) + flip the env
DOVETAIL_ENV=prod
DOVETAIL_PROD_BASE_URL=
DOVETAIL_PROD_USERNAME=
DOVETAIL_PROD_PASSWORD=
DOVETAIL_PROD_STATION=

# Core AI — run the model chain on the Studio (Ollama local models + optional
# Claude cloud tier). CORE_AI_MODE must be `ollama` for any model to engage.
CORE_AI_MODE=ollama
CORE_AI_URL=http://127.0.0.1:11434
CORE_AI_MODEL=qwen3:30b          # active inference model. Set to `claude` to default to Claude.

# Claude (Anthropic) cloud tier — OPT-IN. Off unless BOTH are set. When on and
# selected (CORE_AI_MODEL=claude) it is the primary engine, falling back to the
# local model then the stub. Private values are redacted to [[N]] tokens before
# any request leaves the box. Omit both lines to keep inference fully local.
# CORE_AI_CLOUD_ENABLED=true
# CORE_AI_CLOUD_API_KEY=          # sk-ant-… (the Anthropic key)
# CORE_AI_CLOUD_MODEL=claude-haiku-4-5   # optional; this is the default

# Vantage, Freshdesk, inbound API auth
VANTAGE_EMAIL=
VANTAGE_PASSWORD=
FRESHDESK_DOMAIN=
FRESHDESK_API_KEY=
TRAGAR_API_KEY=                 # mint: openssl rand -hex 32
TRAGAR_API_ALLOWED_IPS=
```
(`runtime.exs`'s dotenv loader is dev-only; in prod these must be real env vars,
which `bin/start_prod.sh` / `bin/deploy.sh` load from `.env.prod`.)

### 3. launchd service
Create `~/Library/LaunchAgents/com.tragar.tragar_ai.plist` that runs
`bin/start_prod.sh` with `KeepAlive` (auto-restart), then load it once:
```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tragar.tragar_ai.plist
```
See [deploy-studio.md → operating the service](#operating-the-service) for
start/stop/status commands.

### 4. First build
```bash
cd /Users/tragarai/apps/tragar_ai
./bin/deploy.sh        # build release, migrate, (re)start, health-check
```

### 5. GitHub Actions self-hosted runner
Repo → **Settings → Actions → Runners → New self-hosted runner** → macOS steps on
the Studio, **running as the `tragarai` user** (it needs the app dir and the
`gui/<uid>` launchd domain). Add the label **`tragar-studio`** (the deploy job
targets `runs-on: [self-hosted, tragar-studio]`). If the app dir differs from the
default, set `TRAGAR_APP_DIR` in the runner's environment.

## Day-to-day flow
1. Open a PR → **CI** (`ci.yml`) runs `mix test`.
2. Merge to `main` → **Deploy** (`deploy.yml`): `mix test` on ubuntu, then the
   Studio runner runs `bin/deploy.sh`.
3. If `/health` doesn't come up the job goes red; the previous release is still
   on disk for rollback.

### Incremental builds
`bin/deploy.sh` runs in the **persistent** app dir, so `_build/prod` survives
between deploys and `mix release` only **recompiles the modules that changed** —
not the whole project. It also skips the heavy optional steps unless the incoming
commits touched the files that matter:

| Step | Runs only when |
|---|---|
| `mix deps.get --only prod` | `mix.lock` changed |
| `mix assets.deploy` | `assets/**`, `mix.exs`, or any `*.ex` / `*.heex` changed |
| `TragarAi.Release.migrate` | a file under `priv/repo/migrations/` changed |
| `mix release` (incremental compile) | always (only changed modules recompile) |

If `main` has no new commits and a release already exists, it exits early without
rebuilding or restarting. Force a clean, do-everything run with:
```bash
./bin/deploy.sh --full
```
(Use `--full` after changing toolchain versions or if `_build` ever gets into a
bad state.)

## Operating the service
```bash
# start / restart (preferred — keeps KeepAlive supervision)
launchctl kickstart -k gui/$(id -u)/com.tragar.tragar_ai
# status
launchctl print gui/$(id -u)/com.tragar.tragar_ai | grep -i state
# stop
launchctl bootout gui/$(id -u)/com.tragar.tragar_ai

# is it serving?
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:4000/health   # 200 = up
lsof -nP -iTCP:4000 -sTCP:LISTEN                                         # beam.smp bound to 4000
```

## Manual deploy / rollback
```bash
cd /Users/tragarai/apps/tragar_ai

# deploy latest main by hand
./bin/deploy.sh

# rollback: check out a known-good commit, rebuild, restart
git checkout <previous-good-sha>
MIX_ENV=prod mix release --overwrite
launchctl kickstart -k gui/$(id -u)/com.tragar.tragar_ai
```

## Networking notes
- The prod endpoint binds `0.0.0.0:$PORT` (default 4000), reachable over the LAN
  and Tailscale.
- `force_ssl` upgrades public traffic to HTTPS but serves LAN (`*.local`, private
  IPs) and Tailscale (`100.64.0.0/10`, `*.ts.net`) hosts over plain HTTP — see
  `TragarAiWeb.SSLExclude`. The tailnet is already encrypted.

## Backups (recommended)
Nightly `pg_dump` via cron on the Studio:
```bash
0 2 * * * /opt/homebrew/opt/postgresql@17/bin/pg_dump tragar_ai_prod \
  | gzip > ~/backups/tragar_$(date +\%F).sql.gz
```
