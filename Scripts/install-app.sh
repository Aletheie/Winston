#!/bin/bash
# Build Winston in Release and install it into /Applications as a standalone app.
#
# Signing note: automatic signing from the CLI has no Release provisioning profile and
# falls back to ad-hoc. An ad-hoc app under hardened runtime refuses to load the ad-hoc
# libmtp/libusb dylibs (library validation compares Team IDs), so the app aborts at launch
# with "Library not loaded: @rpath/libmtp.9.dylib". Signing explicitly with the Apple
# Development identity gives the app and the dylibs the same Team ID.
set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY="${WINSTON_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | awk -F'"' '/Apple Development/ {print $2; exit}')}"

if [ -z "$IDENTITY" ]; then
    echo "No Apple Development identity in the keychain — refusing to build an ad-hoc app" >&2
    echo "that cannot load libmtp. Renew the certificate in Xcode > Settings > Accounts." >&2
    exit 1
fi

echo "Signing identity: $IDENTITY"

tuist generate --no-open

xcodebuild -workspace Winston.xcworkspace -scheme Winston -configuration Release \
    -derivedDataPath build/DD \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    DEVELOPMENT_TEAM=4F4YMTN4C5 \
    build

APP="build/DD/Build/Products/Release/Winston.app"
codesign --verify --deep --strict "$APP"

osascript -e 'tell application "Winston" to quit' 2>/dev/null || true
rm -rf /Applications/Winston.app
cp -R "$APP" /Applications/Winston.app
xattr -cr /Applications/Winston.app 2>/dev/null || true

echo "Installed /Applications/Winston.app"
open -a /Applications/Winston.app
