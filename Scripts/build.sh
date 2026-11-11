#!/bin/bash
# Build Agnomen.app (arm64, release, ad-hoc signed with App Sandbox and NO network entitlement).
# --install copies it to /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release 1>&2

APP="dist/Agnomen.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Agnomen "$APP/Contents/MacOS/Agnomen"
cp Support/Info.plist "$APP/Contents/Info.plist"
[ -f Support/AppIcon.icns ] && cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --entitlements Support/Agnomen.entitlements "$APP" 1>&2
echo "built $APP" 1>&2

if [ "${1:-}" = "--install" ]; then
    TARGET="/Applications/Agnomen.app"
    osascript -e 'tell application "Agnomen" to quit' >/dev/null 2>&1 || true
    pkill -x Agnomen 2>/dev/null || true
    sleep 0.5
    rm -rf "$TARGET"
    ditto "$APP" "$TARGET"
    echo "installed $TARGET" 1>&2
    open "$TARGET"
fi
