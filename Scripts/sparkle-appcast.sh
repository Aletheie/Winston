#!/bin/bash
# Sign release archives and generate appcast.xml (key comes from the login Keychain).
#
# Usage: Scripts/sparkle-appcast.sh <releases-folder> [download-url-prefix]
# Then upload the archives + appcast.xml to wherever SUFeedURL points.
set -euo pipefail

RELEASES_DIR="${1:?Usage: sparkle-appcast.sh <releases-folder> [download-url-prefix]}"
URL_PREFIX="${2:-}"

TOOL="${SPARKLE_BIN:-}"
if [ -z "$TOOL" ]; then
    TOOL=$(ls -t "$HOME"/Library/Developer/Xcode/DerivedData/*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast 2>/dev/null | head -1 || true)
fi
if [ -z "$TOOL" ] || [ ! -x "$TOOL" ]; then
    echo "error: generate_appcast not found. Build the app once (so SPM resolves" >&2
    echo "       Sparkle), or set SPARKLE_BIN to the generate_appcast path." >&2
    exit 1
fi

if [ -n "$URL_PREFIX" ]; then
    "$TOOL" --download-url-prefix "$URL_PREFIX" "$RELEASES_DIR"
else
    "$TOOL" "$RELEASES_DIR"
fi

echo
echo "✓ appcast.xml written to: $RELEASES_DIR/appcast.xml"
echo "  Next: upload the archives + appcast.xml to the host SUFeedURL points at."
