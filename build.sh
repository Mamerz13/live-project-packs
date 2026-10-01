#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"

mkdir -p "$ROOT/outputs/LiveProjectPacks.app/Contents/MacOS"
mkdir -p "$ROOT/outputs/LiveProjectPacks.app/Contents/Resources"
mkdir -p "$BUILD"
mkdir -p "$BUILD/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$BUILD/ModuleCache"
"$ROOT/work/make_icon.sh"
OBJC_SOURCES=()
for source in "$ROOT"/Sources/LiveProjectPacksObjC/LPP*.m; do
  [ -e "$source" ] && OBJC_SOURCES+=("$source")
done
OBJC_SOURCES+=("$ROOT/Sources/LiveProjectPacksObjC/main.m")

# The "Explain This" feature calls Apple's on-device Foundation Models
# framework, which is Swift-only (no ObjC header). This compiles the small
# bridge in AIExplainer.swift into an object file plus a generated
# Objective-C header (AIExplainer-Swift.h) that main.m imports directly.
swiftc -parse-as-library \
  -emit-module -emit-module-path "$BUILD/LPPSwift.swiftmodule" \
  -emit-objc-header-path "$BUILD/AIExplainer-Swift.h" \
  -module-name LPPSwift \
  -c "$ROOT/Sources/LiveProjectPacksObjC/AIExplainer.swift" \
  -o "$BUILD/AIExplainer.o"

# arm64-only now: Foundation Models / Apple Intelligence requires Apple
# Silicon, so a universal x86_64 slice no longer makes sense here.
clang -fobjc-arc \
  -arch arm64 \
  -mmacosx-version-min=26.0 \
  -I "$BUILD" \
  -framework Cocoa \
  -framework QuartzCore \
  -framework Carbon \
  -framework QuickLookThumbnailing \
  -framework Vision \
  -framework ScreenCaptureKit \
  -framework ApplicationServices \
  -framework FoundationModels \
  "${OBJC_SOURCES[@]}" \
  "$BUILD/AIExplainer.o" \
  -L /usr/lib/swift \
  -o "$ROOT/outputs/LiveProjectPacks.app/Contents/MacOS/LiveProjectPacks"

cat > "$ROOT/outputs/LiveProjectPacks.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>LiveProjectPacks</string>
  <key>CFBundleIdentifier</key>
  <string>com.local.liveprojectpacks</string>
  <key>CFBundleName</key>
  <string>Live Project Packs</string>
  <key>CFBundleIconFile</key>
  <string>LiveProjectPacks</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleShortVersionString</key>
  <string>0.22</string>
  <key>CFBundleVersion</key>
  <string>22</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
  <key>NSAppleEventsUsageDescription</key>
  <string>Packs reads the address of the page you are viewing so it can save that link to your Pack.</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSMultipleInstancesProhibited</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$ROOT/outputs/LiveProjectPacks.app/Contents/PkgInfo"
chmod +x "$ROOT/outputs/LiveProjectPacks.app/Contents/MacOS/LiveProjectPacks"
if [ -f "$ROOT/outputs/LiveProjectPacks.icns" ]; then
  cp "$ROOT/outputs/LiveProjectPacks.icns" "$ROOT/outputs/LiveProjectPacks.app/Contents/Resources/LiveProjectPacks.icns"
fi
if [ -f "$ROOT/outputs/LiveProjectPacks-icon.png" ]; then
  cp "$ROOT/outputs/LiveProjectPacks-icon.png" "$ROOT/outputs/LiveProjectPacks.app/Contents/Resources/LiveProjectPacks-icon.png"
fi
for mascot in volt-mascot-idle volt-mascot-catching volt-mascot-success; do
  cp "$ROOT/Resources/$mascot.png" "$ROOT/outputs/LiveProjectPacks.app/Contents/Resources/$mascot.png"
done
for stale in packs-mascot-sitting-cursor packs-mascot-catching-file; do
  stale_path="$ROOT/outputs/LiveProjectPacks.app/Contents/Resources/$stale.png"
  [ ! -f "$stale_path" ] || /bin/unlink "$stale_path"
done
"$ROOT/outputs/LiveProjectPacks.app/Contents/MacOS/LiveProjectPacks" --self-test
xattr -cr "$ROOT/outputs/LiveProjectPacks.app" 2>/dev/null || true
codesign --force --sign - "$ROOT/outputs/LiveProjectPacks.app" >/dev/null 2>&1 || true
echo "Built outputs/LiveProjectPacks.app"
