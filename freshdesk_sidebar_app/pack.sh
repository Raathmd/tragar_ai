#!/usr/bin/env bash
# Validate + pack the Tragar AI sidebar app locally → dist/*.zip
# (The upload to Freshdesk is GUI-only — see SETUP.md step 3.)
set -euo pipefail
cd "$(dirname "$0")"

command -v fdk >/dev/null 2>&1 || {
  echo "FDK CLI not found. Install it first — see SETUP.md section 0." >&2
  exit 1
}

fdk validate --skip-update-check
fdk pack --skip-update-check

echo "Packed:"
ls -1 dist/*.zip
