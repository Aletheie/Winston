#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT/build/DD/Build/Products/Release/Winston.app}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "Winston.app not found at: $APP_PATH" >&2
    echo "Build Release first or pass the app path as the first argument." >&2
    exit 66
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
OUTPUT_PATH="${2:-$ROOT/build/release/Winston-$VERSION-arm64.dmg}"
VOLUME_NAME="Winston $VERSION"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/winston-dmg.XXXXXX")"
STAGING_DIR="$WORK_DIR/source"
RW_DMG="$WORK_DIR/Winston-rw.dmg"
VOLUME_ICON_ICNS="$WORK_DIR/VolumeIcon.icns"
MOUNT_DIR=""
DEVICE=""

cleanup() {
    if [[ -n "$DEVICE" ]]; then
        hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$(dirname "$OUTPUT_PATH")"
rm -f "$OUTPUT_PATH"
mkdir -p "$STAGING_DIR/.background"

ditto "$APP_PATH" "$STAGING_DIR/Winston.app"
ln -s /Applications "$STAGING_DIR/Applications"
swift -module-cache-path "$WORK_DIR/module-cache" \
    "$ROOT/Scripts/render-dmg-background.swift" \
    "$STAGING_DIR/.background/background.tiff"

if [[ -f "$APP_PATH/Contents/Resources/AppIcon.icns" ]]; then
    APP_ICON="$APP_PATH/Contents/Resources/AppIcon.icns"
    VOLUME_ICON_PNG="$WORK_DIR/volume-icon.png"
    VOLUME_ICONSET="$WORK_DIR/VolumeIcon.iconset"
    mkdir "$VOLUME_ICONSET"
    swift -module-cache-path "$WORK_DIR/module-cache" \
        "$ROOT/Scripts/render-dmg-volume-icon.swift" \
        "$APP_ICON" \
        "$VOLUME_ICON_PNG"
    for size in 16 32 128 256 512; do
        doubleSize="$((size * 2))"
        sips -z "$size" "$size" "$VOLUME_ICON_PNG" \
            --out "$VOLUME_ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z "$doubleSize" "$doubleSize" "$VOLUME_ICON_PNG" \
            --out "$VOLUME_ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$VOLUME_ICONSET" -o "$VOLUME_ICON_ICNS"
fi

hdiutil create \
    -srcfolder "$STAGING_DIR" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -volname "$VOLUME_NAME" \
    -format UDRW \
    -ov "$RW_DMG" >/dev/null

ATTACH_OUTPUT="$(hdiutil attach "$RW_DMG" \
    -mountrandom /Volumes \
    -readwrite \
    -noverify \
    -noautoopen \
    -nobrowse)"
DEVICE="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/Apple_(HFS|APFS)/ { print $1; exit }')"
MOUNT_DIR="$(printf '%s\n' "$ATTACH_OUTPUT" | sed -n 's|^.*\(/Volumes/.*\)$|\1|p' | tail -1)"

if [[ -z "$DEVICE" || -z "$MOUNT_DIR" ]]; then
    echo "Could not mount the writable disk image." >&2
    exit 1
fi

SetFile -a V "$MOUNT_DIR/.background"

MOUNTED_VOLUME_NAME="${MOUNT_DIR##*/}"
sleep 5
osascript - "$MOUNTED_VOLUME_NAME" <<'APPLESCRIPT'
on run arguments
    set volumeName to item 1 of arguments
    tell application "Finder"
        tell disk (volumeName as string)
            open
            tell container window
                set current view to icon view
                set toolbar visible to false
                set statusbar visible to false
                set bounds to {160, 120, 820, 540}
            end tell
            set viewOptions to icon view options of container window
            tell viewOptions
                set icon size to 160
                set text size to 12
                set arrangement to not arranged
                set shows item info to false
                set shows icon preview to false
            end tell
            set background picture of viewOptions to file ".background:background.tiff"
            set extension hidden of item "Winston.app" to true
            set position of item "Winston.app" to {180, 170}
            set position of item "Applications" to {480, 170}
            close
            open
            update without registering applications
            delay 1
            set bounds of container window to {160, 120, 810, 530}
            delay 1
            set bounds of container window to {160, 120, 820, 540}
            update without registering applications
            delay 2
        end tell
    end tell
end run
APPLESCRIPT

sync

for _ in {1..20}; do
    [[ -f "$MOUNT_DIR/.DS_Store" ]] && break
    sleep 1
done

if [[ ! -f "$MOUNT_DIR/.DS_Store" ]]; then
    echo "Finder did not save the DMG layout." >&2
    exit 1
fi

if [[ -f "$VOLUME_ICON_ICNS" ]]; then
    cp "$VOLUME_ICON_ICNS" "$MOUNT_DIR/.VolumeIcon.icns"
    SetFile -c icnC "$MOUNT_DIR/.VolumeIcon.icns"
    if [[ ! -f "$MOUNT_DIR/.VolumeIcon.icns" ]]; then
        echo "The custom volume icon was not written to the disk image." >&2
        exit 1
    fi
    SetFile -a C "$MOUNT_DIR"
fi

chmod -Rf go-w "$MOUNT_DIR" >/dev/null 2>&1 || true

hdiutil detach "$DEVICE" >/dev/null
DEVICE=""

hdiutil convert "$RW_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$OUTPUT_PATH" >/dev/null

echo "Created $OUTPUT_PATH"
