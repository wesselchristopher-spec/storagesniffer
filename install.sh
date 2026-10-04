#!/bin/bash
# Installs the latest Storage Sniffer release into /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/wesselchristopher-spec/storagesniffer/main/install.sh | bash
#
# Downloading with curl (rather than a browser) means macOS doesn't flag the app as
# "downloaded from the internet", so it opens without a Gatekeeper warning.
set -euo pipefail

REPO="wesselchristopher-spec/storagesniffer"
APP_NAME="Storage Sniffer.app"
URL="https://github.com/$REPO/releases/latest/download/StorageSniffer.zip"

fail() { echo "Error: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Storage Sniffer only runs on macOS."
[ "$(uname -m)" = "arm64" ] || fail "Storage Sniffer needs an Apple Silicon Mac (M1 or later)."
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$MAJOR" -ge 15 ] || fail "Storage Sniffer needs macOS 15 (Sequoia) or later."

# Install for everyone if possible, otherwise just for this user.
DEST="/Applications"
if [ ! -w "$DEST" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Storage Sniffer…"
curl -fL --progress-bar "$URL" -o "$TMP/StorageSniffer.zip" || fail "Download failed from $URL"
ditto -x -k "$TMP/StorageSniffer.zip" "$TMP"
[ -d "$TMP/$APP_NAME" ] || fail "The download didn't contain $APP_NAME."

# Replace any running or previous copy.
osascript -e 'quit app "Storage Sniffer"' >/dev/null 2>&1 || true
rm -rf "$DEST/$APP_NAME"
ditto "$TMP/$APP_NAME" "$DEST/$APP_NAME"
xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null || true

echo "Installed to $DEST/$APP_NAME"
echo "Tip: turn on Full Disk Access for Storage Sniffer in System Settings › Privacy & Security for complete results."
open "$DEST/$APP_NAME"
