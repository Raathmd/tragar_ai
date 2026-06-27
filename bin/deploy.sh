#!/bin/bash
# Native production deploy for the Mac Studio.
#
# Invoked by the GitHub Actions self-hosted runner (.github/workflows/deploy.yml)
# on merge to main — and safe to run by hand on the Studio. Rebuilds the Mix
# release from the latest main and restarts the launchd-supervised service.
#
# Overridable via env (defaults match the Studio install):
#   TRAGAR_APP_DIR       app checkout / release dir
#   TRAGAR_LAUNCH_LABEL  launchd LaunchAgent label
#   TRAGAR_HEALTH_URL    URL polled to confirm the new release is serving
set -euo pipefail

APP_DIR="${TRAGAR_APP_DIR:-/Users/tragarai/apps/tragar_ai}"
LAUNCH_LABEL="${TRAGAR_LAUNCH_LABEL:-com.tragar.tragar_ai}"
HEALTH_URL="${TRAGAR_HEALTH_URL:-http://localhost:4000/health}"

# Make Homebrew/asdf-installed Elixir visible in a non-login shell (the runner).
[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
[ -f "$HOME/.asdf/asdf.sh" ] && . "$HOME/.asdf/asdf.sh"

cd "$APP_DIR"

echo "==> Updating source to origin/main"
git fetch --prune origin
git checkout main
git reset --hard origin/main

export MIX_ENV=prod

echo "==> Fetching prod deps"
mix deps.get --only prod

echo "==> Building assets + release"
mix assets.deploy
mix release --overwrite

echo "==> Running migrations"
# Load prod secrets (DATABASE_URL, …) only for the migrate step. .env.prod is
# untracked, so the git reset above never touches it.
set -a
# shellcheck disable=SC1091
[ -f .env.prod ] && . ./.env.prod
set +a
_build/prod/rel/tragar_ai/bin/tragar_ai eval "TragarAi.Release.migrate"

echo "==> Restarting the service"
TARGET="gui/$(id -u)/${LAUNCH_LABEL}"
# kickstart if already loaded; otherwise bootstrap the agent for the first time.
launchctl kickstart -k "$TARGET" 2>/dev/null ||
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/${LAUNCH_LABEL}.plist"

echo "==> Health check ($HEALTH_URL)"
for _ in $(seq 1 30); do
  if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
    echo "✓ healthy — deploy complete"
    exit 0
  fi
  sleep 2
done

echo "✗ health check failed at $HEALTH_URL after ~60s" >&2
exit 1
