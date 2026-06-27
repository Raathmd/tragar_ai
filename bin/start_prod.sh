#!/bin/bash
# Launched by com.tragar.tragar_ai LaunchAgent. Sources prod env, waits for
# Postgres to accept connections, then execs the release in the foreground so
# launchd can supervise it (KeepAlive restarts it if it dies).
set -euo pipefail

APP_DIR="/Users/tragarai/apps/tragar_ai"
cd "$APP_DIR"

# Load prod environment (DATABASE_URL, SECRET_KEY_BASE, PHX_SERVER, PORT, ...).
set -a
# shellcheck disable=SC1091
source "$APP_DIR/.env.prod"
set +a

# Wait for Postgres to be ready (it auto-starts via its own LaunchAgent, but
# ordering between agents is not guaranteed).
for _ in $(seq 1 60); do
  if /opt/homebrew/opt/postgresql@17/bin/pg_isready -h localhost -q; then
    break
  fi
  sleep 1
done

exec "$APP_DIR/_build/prod/rel/tragar_ai/bin/tragar_ai" start
