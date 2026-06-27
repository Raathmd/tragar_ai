#!/bin/bash
# Native production deploy for the Mac Studio.
#
# Invoked by the GitHub Actions self-hosted runner (.github/workflows/deploy.yml)
# on merge to main — and safe to run by hand on the Studio.
#
# Incremental by design: it runs in the persistent app dir, so `_build/prod`
# survives between deploys and `mix compile` only rebuilds changed modules. The
# expensive optional steps (deps fetch, asset bundle, migrate) run ONLY when the
# files that affect them actually changed in the incoming commits. Use --full to
# force every step.
#
# Overridable via env (defaults match the Studio install):
#   TRAGAR_APP_DIR       app checkout / release dir
#   TRAGAR_LAUNCH_LABEL  launchd LaunchAgent label
#   TRAGAR_HEALTH_URL    URL polled to confirm the new release is serving
set -euo pipefail

APP_DIR="${TRAGAR_APP_DIR:-/Users/tragarai/apps/tragar_ai}"
LAUNCH_LABEL="${TRAGAR_LAUNCH_LABEL:-com.tragar.tragar_ai}"
HEALTH_URL="${TRAGAR_HEALTH_URL:-http://localhost:4000/health}"
FORCE="${1:-}"

# Make Homebrew/asdf-installed Elixir visible in a non-login shell (the runner).
[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
[ -f "$HOME/.asdf/asdf.sh" ] && . "$HOME/.asdf/asdf.sh"

cd "$APP_DIR"
export MIX_ENV=prod
RELEASE_BIN="_build/prod/rel/tragar_ai/bin/tragar_ai"

echo "==> Updating source to origin/main"
BEFORE="$(git rev-parse HEAD 2>/dev/null || echo none)"
git fetch --prune origin
git checkout main
git reset --hard origin/main
AFTER="$(git rev-parse HEAD)"

# Nothing new and a release already exists → no work to do.
if [ "$FORCE" != "--full" ] && [ "$BEFORE" = "$AFTER" ] && [ -x "$RELEASE_BIN" ]; then
  echo "==> Already at $AFTER with a built release; nothing to deploy."
  exit 0
fi

# What changed between the old and new HEAD? (Everything, on first build / --full.)
if [ "$FORCE" = "--full" ] || [ "$BEFORE" = "none" ] || [ ! -x "$RELEASE_BIN" ]; then
  CHANGED="__ALL__"
else
  CHANGED="$(git diff --name-only "$BEFORE" "$AFTER")"
fi
changed() { [ "$CHANGED" = "__ALL__" ] || grep -qE "$1" <<<"$CHANGED"; }

# Deps: only when the lockfile moved.
if changed '^mix\.lock$'; then
  echo "==> Fetching prod deps (mix.lock changed)"
  mix deps.get --only prod
else
  echo "==> Deps unchanged; skipping deps.get"
fi

# Assets: only when asset inputs or templates changed (Tailwind scans .ex/.heex,
# and colocated JS hooks live in .ex), so a code change that affects markup
# rebuilds them; pure config/doc changes don't.
if changed '^(assets/|mix\.exs$|.*\.(ex|heex)$)'; then
  echo "==> Building assets"
  mix assets.deploy
else
  echo "==> No asset/template changes; skipping assets.deploy"
fi

# Compile + assemble the release. Compilation is incremental against _build/prod;
# only changed modules recompile.
echo "==> Building release (incremental compile)"
mix release --overwrite

# Migrations: only when a migration file was added/changed.
if changed '^priv/repo/migrations/'; then
  echo "==> Running migrations (new migrations detected)"
  set -a
  # shellcheck disable=SC1091
  [ -f .env.prod ] && . ./.env.prod
  set +a
  "$RELEASE_BIN" eval "TragarAi.Release.migrate"
else
  echo "==> No new migrations; skipping migrate"
fi

echo "==> Restarting the service"
TARGET="gui/$(id -u)/${LAUNCH_LABEL}"
# kickstart if already loaded; otherwise bootstrap the agent for the first time.
launchctl kickstart -k "$TARGET" 2>/dev/null ||
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/${LAUNCH_LABEL}.plist"

echo "==> Health check ($HEALTH_URL)"
for _ in $(seq 1 30); do
  if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
    echo "✓ healthy — deploy complete ($AFTER)"
    exit 0
  fi
  sleep 2
done

echo "✗ health check failed at $HEALTH_URL after ~60s" >&2
exit 1
