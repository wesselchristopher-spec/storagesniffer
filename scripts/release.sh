#!/bin/bash
# Builds the app and publishes it as a GitHub release that install.sh downloads.
# Usage: scripts/release.sh 2.0.0
# Needs the GitHub CLI (brew install gh) signed in with `gh auth login`.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Usage: scripts/release.sh <version>}"
command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh" >&2; exit 1; }

VERSION="$VERSION" scripts/bundle.sh
ZIP="build/StorageSniffer.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "build/Storage Sniffer.app" "$ZIP"

gh release create "v$VERSION" "$ZIP" \
    --title "Storage Sniffer $VERSION" \
    --notes "Install or update with:

\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/wesselchristopher-spec/storagesniffer/main/install.sh | bash
\`\`\`

Requires an Apple Silicon Mac with macOS 15 or later."
echo "Released v$VERSION"
