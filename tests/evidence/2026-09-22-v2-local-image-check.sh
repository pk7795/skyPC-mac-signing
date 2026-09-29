#!/bin/bash
# Retained local check: real ad-hoc bundle and disk services; no Apple submission.
set -euo pipefail
SCRIPT=/Users/khoakheu/SkyPC-workspace/Mac-signing/release_skypc.sh
ICON=/Users/khoakheu/SkyPC-workspace/Mac-signing/SkyPC.icns
APP=/private/tmp/skypc-v2-preparation-pass/build/SkyPC.app
PLIST="$APP/Contents/Info.plist"
RUN_DIR=/private/tmp/skypc-v2-image-check-pass
MOUNT='' DEVICE='' ATTACH_PLIST='' MOUNT_COUNT=0 STAGE='v2 real image check'
mkdir "$RUN_DIR"
printf 'Ad-hoc-only image test. Developer ID/notarization/Gatekeeper unverified.\n' > "$RUN_DIR/release-evidence.txt"
die() { printf '%s\n' "$*" >&2; exit 1; }
plist_get() { plutil -extract "$1" raw -o - "$2"; }
# Exercise the actual production mount/parser/cleanup/icon helpers.
for helper in read_attachment cleanup run attach_image check_volume; do
  sed -n "/^${helper}() {/,/^}/p" "$SCRIPT" >> "$RUN_DIR/production-helpers.sh"
done
sed -n '/^detach_image()/p' "$SCRIPT" >> "$RUN_DIR/production-helpers.sh"
source "$RUN_DIR/production-helpers.sh"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$RUN_DIR/dmg-root"
ditto "$APP" "$RUN_DIR/dmg-root/SkyPC.app"
codesign --verify --deep --strict --verbose=4 "$RUN_DIR/dmg-root/SkyPC.app"
ln -s /Applications "$RUN_DIR/dmg-root/Applications"
run create.log hdiutil create -volname SkyPC -fs HFS+ -srcfolder "$RUN_DIR/dmg-root" -format UDRW "$RUN_DIR/test-rw.dmg"
attach_image attach-writable.log "$RUN_DIR/test-rw.dmg" -readwrite
printf 'Writable mount discovered: %s (%s)\n' "$MOUNT" "$DEVICE"
cp -X "$ICON" "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a V "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a C "$MOUNT"
check_volume
sync
detach_image detach-writable.log
run convert.log hdiutil convert "$RUN_DIR/test-rw.dmg" -format UDZO -o "$RUN_DIR/test-readonly.dmg"
run verify-image.log hdiutil verify "$RUN_DIR/test-readonly.dmg"
attach_image attach-final.log "$RUN_DIR/test-readonly.dmg" -readonly
printf 'Readonly mount discovered: %s (%s)\n' "$MOUNT" "$DEVICE"
check_volume
codesign --verify --deep --strict --verbose=4 "$MOUNT/SkyPC.app"
cmp "$APP/Contents/MacOS/skypc" "$MOUNT/SkyPC.app/Contents/MacOS/skypc"
detach_image detach-final.log
shasum -a 256 "$RUN_DIR/test-readonly.dmg"
printf 'PASS: v2 production mount helpers, signed staging, real UDRW/UDZO, both icons/flags, app signature, executable, plist, Applications shortcut; mounts detached.\n'
