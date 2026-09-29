#!/bin/bash
set -euo pipefail

ROOT='/Users/khoakheu/SkyPC-workspace'
SIGNING="$ROOT/Mac-signing"
RUN="$SIGNING/releases/SkyPC-0.9.27-6-20260922T163303Z.s0pOx8"
SOURCE="$RUN/build/SkyPC-rw.dmg"
ICON="$ROOT/skypc-app/assets/AppIcon.icns"
PYTHON="$SIGNING/.venv/bin/python"
WORK="$(mktemp -d /private/tmp/skypc-post-finder-icon.XXXXXX)"
RW="$WORK/SkyPC-rw.dmg"
FINAL="$WORK/SkyPC-preview.dmg"
DEVICE=''
MOUNT=''

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$DEVICE" ]; then hdiutil detach "$DEVICE" > "$WORK/cleanup.log" 2>&1 || rc=1; fi
  printf 'work=%s\n' "$WORK"
  exit "$rc"
}
trap cleanup EXIT

read_attach() {
  eval "$(python3 - "$1" <<'PY'
import plistlib, shlex, sys
with open(sys.argv[1], 'rb') as f:
    entities = plistlib.load(f).get('system-entities', [])
devices = [e.get('dev-entry') for e in entities if e.get('dev-entry')]
mounts = [e.get('mount-point') for e in entities if e.get('mount-point')]
if not devices or len(mounts) != 1:
    raise SystemExit('unexpected attach result')
print('DEVICE=' + shlex.quote(devices[0]))
print('MOUNT=' + shlex.quote(mounts[0]))
PY
)"
}

cp "$SOURCE" "$RW"
hdiutil attach "$RW" -readwrite -nobrowse -noautoopen -plist > "$WORK/attach-writable.plist"
read_attach "$WORK/attach-writable.plist"

# Reproduce the production ordering after the fix: Finder first, volume icon last.
osascript "$SIGNING/finder_layout.applescript" "$MOUNT" 900 351
"$PYTHON" "$SIGNING/dmg_layout.py" verify "$MOUNT" 900 351
cp -X "$ICON" "$MOUNT/.VolumeIcon.icns"
chmod 644 "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a V "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a C "$MOUNT"
cmp "$ICON" "$MOUNT/.VolumeIcon.icns"
[ "$(xcrun GetFileInfo -aC "$MOUNT")" = 1 ]
[ "$(xcrun GetFileInfo -aV "$MOUNT/.VolumeIcon.icns")" = 1 ]
sync
hdiutil detach "$DEVICE" > "$WORK/detach-writable.log"
DEVICE=''; MOUNT=''

hdiutil convert "$RW" -format UDZO -o "$FINAL" > "$WORK/convert.log"
hdiutil attach "$FINAL" -readonly -nobrowse -noautoopen -plist > "$WORK/attach-final.plist"
read_attach "$WORK/attach-final.plist"
cmp "$ICON" "$MOUNT/.VolumeIcon.icns"
[ "$(xcrun GetFileInfo -aC "$MOUNT")" = 1 ]
[ "$(xcrun GetFileInfo -aV "$MOUNT/.VolumeIcon.icns")" = 1 ]
"$PYTHON" "$SIGNING/dmg_layout.py" verify "$MOUNT" 900 351
shasum -a 256 "$FINAL"
printf 'PASS: Finder background and post-Finder volume icon survive UDZO conversion\npreview=%s\n' "$FINAL"
