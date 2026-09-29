#!/bin/bash
set -euo pipefail
CHECK_DIR=/private/tmp/skypc-signing-image-check-20260922
ICON=/Users/khoakheu/SkyPC-workspace/Mac-signing/SkyPC.icns
MOUNT="$CHECK_DIR/mount"
mkdir -p "$MOUNT"
mounted=0
cleanup() { if [ "$mounted" = 1 ]; then hdiutil detach "$MOUNT"; fi; }
trap cleanup EXIT
hdiutil attach "$CHECK_DIR/test-rw.dmg" -readwrite -nobrowse -noautoopen -mountpoint "$MOUNT"
mounted=1
cp "$ICON" "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a V "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a C "$MOUNT"
test "$(xcrun GetFileInfo -aC "$MOUNT")" = 1
test "$(xcrun GetFileInfo -aV "$MOUNT/.VolumeIcon.icns")" = 1
hdiutil detach "$MOUNT"
mounted=0
hdiutil convert "$CHECK_DIR/test-rw.dmg" -format UDZO -o "$CHECK_DIR/test-readonly.dmg"
hdiutil verify "$CHECK_DIR/test-readonly.dmg"
hdiutil attach "$CHECK_DIR/test-readonly.dmg" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT"
mounted=1
test "$(xcrun GetFileInfo -aC "$MOUNT")" = 1
test "$(xcrun GetFileInfo -aV "$MOUNT/.VolumeIcon.icns")" = 1
cmp "$ICON" "$MOUNT/.VolumeIcon.icns"
cmp "$ICON" "$MOUNT/SkyPC.app/Contents/Resources/SkyPC.icns"
test "$(readlink "$MOUNT/Applications")" = /Applications
plutil -lint "$MOUNT/SkyPC.app/Contents/Info.plist"
hdiutil detach "$MOUNT"
mounted=0
shasum -a 256 "$CHECK_DIR/test-readonly.dmg"
printf 'PASS: real unsigned UDRW -> volume flags -> UDZO -> verify -> remount icon/shortcut/plist checks.\n'
