#!/usr/bin/env bash
set -euo pipefail

# Builds a distributable zip.
#
# Without a Developer ID this produces an ad-hoc signed app: it runs, but macOS
# shows "Apple could not verify..." on first open and each friend has to approve
# it once in System Settings (see INSTALL.txt, written alongside the zip).
#
# To ship it with no warning at all, join the Apple Developer Program, then:
#   export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   xcrun notarytool store-credentials PacksNotaryProfile --apple-id you@email.com \
#       --team-id TEAMID --password <app-specific-password>
#   export NOTARY_PROFILE=PacksNotaryProfile
#   REQUIRE_NOTARIZATION=1 ./package.sh

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/outputs/LiveProjectPacks.app"
DIST="$ROOT/outputs/dist"
ZIP="$DIST/LiveProjectPacks.zip"
ENTITLEMENTS="$ROOT/Config/Release.entitlements"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-0}"

fail() {
  echo "error: $*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

require_tool xcrun
require_tool codesign
require_tool security

"$ROOT/build.sh"

if [ -n "${DEVELOPER_ID:-}" ]; then
  echo "Signing with: $DEVELOPER_ID"
  security find-identity -v -p codesigning | grep -F "$DEVELOPER_ID" >/dev/null \
    || fail "Developer ID identity is not installed in this keychain: $DEVELOPER_ID"
  codesign --force \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEVELOPER_ID" \
    "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  if [ "$REQUIRE_NOTARIZATION" = "1" ]; then
    fail "DEVELOPER_ID is required for a notarized release"
  fi
  echo "No DEVELOPER_ID set - shipping the ad-hoc signed build."
fi

mkdir -p "$DIST"
rm -f "$ZIP"
# ditto keeps the bundle structure and the signature intact; zip(1) does not.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "Submitting for notarization..."
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=4 "$APP"
  rm -f "$ZIP"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  echo "Notarized, stapled, and packaged."
elif [ "$REQUIRE_NOTARIZATION" = "1" ]; then
  fail "NOTARY_PROFILE is required for a notarized release"
fi

if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  rm -f "$DIST/INSTALL.txt"
else
  cat > "$DIST/INSTALL.txt" <<'NOTE'
Installing Live Project Packs
=============================

This app is not notarized by Apple, so macOS blocks it the first time and says
"Apple could not verify 'LiveProjectPacks' is free of malware." That is expected.
You only have to do this once.

1. Unzip and drag LiveProjectPacks.app to your Applications folder.
2. Double-click it. You will get the warning. Click Done (or Cancel).
3. Open System Settings > Privacy & Security.
4. Scroll down to the Security section. You will see a line about
   LiveProjectPacks being blocked, with an "Open Anyway" button. Click it.
   (That button only appears for about an hour after step 2. If it is gone,
   double-click the app again and go back to Settings.)
5. Confirm with Touch ID or your password. It opens from now on.

Note: on macOS 15 and later, the old "right-click > Open" trick no longer works
for un-notarized apps. You have to use System Settings as described above.

The app runs in the menu bar - look for Volt, the little robot, floating on your
screen. Click him to open your Pack; press Command+Shift+P from anywhere.
NOTE
fi

echo
echo "Built: $ZIP"
[ -f "$DIST/INSTALL.txt" ] && echo "Send INSTALL.txt with it: $DIST/INSTALL.txt"
