#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/outputs/LiveProjectPacks.app"
EXECUTABLE="$APP/Contents/MacOS/LiveProjectPacks"
INFO_PLIST="$APP/Contents/Info.plist"
SOURCE_MAP="$ROOT/Sources/LiveProjectPacksObjC/SOURCE_MAP.md"

"$ROOT/build.sh"

if [ ! -x "$EXECUTABLE" ]; then
  echo "error: app executable is missing or not executable: $EXECUTABLE" >&2
  exit 1
fi

if [ ! -f "$INFO_PLIST" ]; then
  echo "error: Info.plist is missing: $INFO_PLIST" >&2
  exit 1
fi

if [ ! -f "$SOURCE_MAP" ]; then
  echo "error: source map is missing: $SOURCE_MAP" >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" >/dev/null
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST" >/dev/null
codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null

echo "Refactor check passed."
