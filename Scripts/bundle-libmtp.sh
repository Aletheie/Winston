#!/bin/bash
# Bundle the Homebrew libmtp + libusb dylibs into the app and re-sign them.
set -euo pipefail

LIBMTP_SRC="/opt/homebrew/opt/libmtp/lib/libmtp.9.dylib"
LIBUSB_SRC="/opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib"

FRAMEWORKS_DIR="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}"
EXECUTABLE="${BUILT_PRODUCTS_DIR}/${EXECUTABLE_PATH}"

mkdir -p "$FRAMEWORKS_DIR"

cp -f "$(readlink -f "$LIBMTP_SRC")" "$FRAMEWORKS_DIR/libmtp.9.dylib"
cp -f "$(readlink -f "$LIBUSB_SRC")" "$FRAMEWORKS_DIR/libusb-1.0.0.dylib"
chmod u+w "$FRAMEWORKS_DIR/libmtp.9.dylib" "$FRAMEWORKS_DIR/libusb-1.0.0.dylib"

install_name_tool -id @rpath/libusb-1.0.0.dylib \
    "$FRAMEWORKS_DIR/libusb-1.0.0.dylib" 2>/dev/null

install_name_tool -id @rpath/libmtp.9.dylib \
    -change "$LIBUSB_SRC" @rpath/libusb-1.0.0.dylib \
    "$FRAMEWORKS_DIR/libmtp.9.dylib" 2>/dev/null

# debug builds split into a stub + Winston.debug.dylib, so patch every Mach-O
for binary in "$(dirname "$EXECUTABLE")"/*; do
    if file "$binary" | grep -q "Mach-O"; then
        install_name_tool -change "$LIBMTP_SRC" @rpath/libmtp.9.dylib \
            "$binary" 2>/dev/null || true
    fi
done

# library validation wants the same signing identity as the app
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --timestamp=none "$FRAMEWORKS_DIR/libusb-1.0.0.dylib"
codesign --force --sign "$IDENTITY" --timestamp=none "$FRAMEWORKS_DIR/libmtp.9.dylib"

# install_name_tool invalidated the signatures (Xcode re-signs the main binary later)
for binary in "$(dirname "$EXECUTABLE")"/*.dylib; do
    [ -f "$binary" ] || continue
    codesign --force --sign "$IDENTITY" --timestamp=none "$binary"
done
