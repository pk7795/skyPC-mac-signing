#!/bin/bash
# Local-only background rehearsal. Reuse existing signed app; do not sign/upload.
set -euo pipefail
ROOT=/Users/khoakheu/SkyPC-workspace/Mac-signing
RUN_DIR=/private/tmp/skypc-background-recheck/image
BUILD_DIR=/private/tmp/skypc-background-recheck/prepared/build
APP="$ROOT/releases/SkyPC-0.9.27-4-20260922T152816Z.hTZCBP/build/SkyPC.app"
PLIST="$APP/Contents/Info.plist"
ICON="$ROOT/../skypc-app/assets/AppIcon.icns"
MOUNT='' DEVICE='' ATTACH_PLIST='' MOUNT_COUNT=0 STAGE='local background rehearsal'
mkdir "$RUN_DIR"
die() { printf '%s\n' "$*" >&2; exit 1; }
plist_get() { plutil -extract "$1" raw -o - "$2"; }
for helper in read_attachment cleanup run attach_image check_volume; do
    sed -n "/^${helper}() {/,/^}/p" "$ROOT/release_skypc.sh" >> "$RUN_DIR/production-helpers.sh"
done
sed -n '/^detach_image()/p' "$ROOT/release_skypc.sh" >> "$RUN_DIR/production-helpers.sh"
source "$RUN_DIR/production-helpers.sh"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$RUN_DIR/staging/.background"
ditto "$APP" "$RUN_DIR/staging/SkyPC.app"
ln -s /Applications "$RUN_DIR/staging/Applications"
cp -X "$BUILD_DIR/background/background.tiff" "$RUN_DIR/staging/.background/background.tiff"
chmod 755 "$RUN_DIR/staging/.background"
chmod 644 "$RUN_DIR/staging/.background/background.tiff"
run create.log hdiutil create -volname SkyPC -fs HFS+ -srcfolder "$RUN_DIR/staging" -format UDRW "$RUN_DIR/background-rw.dmg"
attach_image attach-writable.log "$RUN_DIR/background-rw.dmg" -readwrite
cp -X "$ICON" "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a V "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a C "$MOUNT"
check_volume
"$ROOT/.venv/bin/python" "$ROOT/dmg_layout.py" configure "$MOUNT" 900 351
sync
detach_image detach-writable.log
run convert.log hdiutil convert "$RUN_DIR/background-rw.dmg" -format UDZO -o "$RUN_DIR/background-preview.dmg"
run verify-image.log hdiutil verify "$RUN_DIR/background-preview.dmg"
attach_image attach-final.log "$RUN_DIR/background-preview.dmg" -readonly
check_volume
"$ROOT/.venv/bin/python" "$ROOT/dmg_layout.py" verify "$MOUNT" 900 351
codesign --verify --deep --strict --verbose=4 "$MOUNT/SkyPC.app"
"$ROOT/.venv/bin/python" - "$MOUNT" "$RUN_DIR/background.alias" <<'PY'
from ds_store import DSStore
from pathlib import Path
import sys
with DSStore.open(sys.argv[1]+'/.DS_Store','r') as store:
    Path(sys.argv[2]).write_bytes(store['.']['icvp']['backgroundImageAlias'])
PY
swift -module-cache-path /private/tmp/skypc-swift-module-cache /private/tmp/skypc-image-size.swift "$MOUNT/.background/background.tiff"
swift -module-cache-path /private/tmp/skypc-swift-module-cache /private/tmp/skypc-background-recheck/resolve.swift "$RUN_DIR/background.alias"
detach_image detach-final.log
shasum -a 256 "$RUN_DIR/background-preview.dmg"
printf 'PASS: real readonly DMG background scale + alias + layout, icon assets, preserved app signature. Outer image unsigned, not notarized, not for distribution.\n'
