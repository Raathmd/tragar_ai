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
# Stamp of the commit the current release was actually built from. We compare it
# to the deployed HEAD (not just "does a release exist") so a stale release — or
# a dir whose HEAD was advanced out-of-band (e.g. a manual pull) — can never cause
# a silent no-op that leaves old code serving.
BUILT_STAMP="_build/prod/rel/tragar_ai/BUILT_COMMIT"

echo "==> Updating source to origin/main"
BEFORE="$(git rev-parse HEAD 2>/dev/null || echo none)"
git fetch --prune origin
git checkout main
git reset --hard origin/main
AFTER="$(git rev-parse HEAD)"
BUILT="$( [ -f "$BUILT_STAMP" ] && cat "$BUILT_STAMP" || echo none )"

# Skip ONLY when the existing release was built from exactly the target commit.
if [ "$FORCE" != "--full" ] && [ -x "$RELEASE_BIN" ] && [ "$BUILT" = "$AFTER" ]; then
  echo "==> Release already built from $AFTER; nothing to deploy."
  exit 0
fi

# What changed since the release was last built? (Everything, on first build /
# --full / unknown baseline.) Using BUILT (not BEFORE) means a no-op'd or
# out-of-band HEAD can't hide migration/asset changes from the diff.
if [ "$FORCE" = "--full" ] || [ "$BUILT" = "none" ] || [ ! -x "$RELEASE_BIN" ]; then
  CHANGED="__ALL__"
else
  CHANGED="$(git diff --name-only "$BUILT" "$AFTER")"
fi
changed() { [ "$CHANGED" = "__ALL__" ] || grep -qE "$1" <<<"$CHANGED"; }

# Deps: when the deps manifest OR the lockfile moved. We key on mix.exs (not just
# mix.lock) because the committed lock can't be auto-regenerated here (adding a
# workflow needs a scope this runner's token lacks, and mix can't run locally), so
# a new/removed dep shows up as a mix.exs change and `deps.get` resolves it.
if changed '^mix\.(exs|lock)$'; then
  echo "==> Fetching prod deps (mix.exs/mix.lock changed)"
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

# Record the commit this release was built from, so the next run's skip check is
# accurate even if the dir HEAD is later advanced out-of-band.
echo "$AFTER" > "$BUILT_STAMP"

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
