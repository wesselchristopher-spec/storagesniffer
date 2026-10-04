#!/bin/bash
# Builds a release StorageSniffer.app in ./build.
# Usage: [VERSION=x.y.z] scripts/bundle.sh [--open]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product StorageSniffer
BIN="$(swift build -c release --show-bin-path)/StorageSniffer"

APP="build/Storage Sniffer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/StorageSniffer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Sign with a Developer ID if one is configured, otherwise ad hoc. Ad-hoc builds change
# identity on every build, so macOS asks for Full Disk Access again after rebuilding.
IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --options runtime --sign "$IDENTITY" "$APP"

echo "Built $APP"
if [ "${1:-}" = "--open" ]; then
    open "$APP"
fi
