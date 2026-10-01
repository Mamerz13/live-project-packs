#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

if [ -z "${DEVELOPER_ID:-}" ]; then
  cat >&2 <<'NOTE'
Set DEVELOPER_ID first, for example:
  export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
NOTE
  exit 1
fi

if [ -z "${NOTARY_PROFILE:-}" ]; then
  cat >&2 <<'NOTE'
Set NOTARY_PROFILE first. Create it once with:
  xcrun notarytool store-credentials PacksNotaryProfile --apple-id you@email.com --team-id TEAMID --password app-specific-password

Then:
  export NOTARY_PROFILE=PacksNotaryProfile
NOTE
  exit 1
fi

REQUIRE_NOTARIZATION=1 "$ROOT/package.sh"
