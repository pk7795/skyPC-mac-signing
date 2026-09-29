#!/bin/bash
set -euo pipefail

ROOT='/Users/khoakheu/SkyPC-workspace'
RUN="$ROOT/Mac-signing/releases/SkyPC-0.9.27-6-20260922T163303Z.s0pOx8"
IMAGE="${1:-$RUN/build/SkyPC-candidate.dmg}"
SOURCE="$ROOT/skypc-app/assets/AppIcon.icns"
LAYOUT_PYTHON="$ROOT/Mac-signing/.venv/bin/python"
LAYOUT_SCRIPT="$ROOT/Mac-signing/dmg_layout.py"
OUT='/private/tmp/skypc-build6-icon-diagnosis'
PLIST="$OUT/attach.plist"
DEVICE=''
MOUNT=''

mkdir -p "$OUT"
cleanup() {
  if [ -n "$DEVICE" ]; then
    hdiutil detach "$DEVICE" > "$OUT/detach.log" 2>&1 || true
  fi
}
trap cleanup EXIT

hdiutil attach "$IMAGE" -readonly -nobrowse -noautoopen -plist > "$PLIST" 2> "$OUT/attach.log"
eval "$(python3 - "$PLIST" <<'PY'
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

find "$MOUNT" -maxdepth 1 -print > "$OUT/root-files.txt"
cp -X "$MOUNT/SkyPC.app/Contents/Resources/SkyPC.icns" "$OUT/AppIcon.icns"
if [ -f "$MOUNT/.VolumeIcon.icns" ]; then
  cp -X "$MOUNT/.VolumeIcon.icns" "$OUT/VolumeIcon.icns"
else
  rm -f "$OUT/VolumeIcon.icns"
fi
{
  printf 'image=%s\nmount=%s\ndevice=%s\n' "$IMAGE" "$MOUNT" "$DEVICE"
  cat "$OUT/root-files.txt"
  "$LAYOUT_PYTHON" "$LAYOUT_SCRIPT" verify "$MOUNT" 900 351
  shasum -a 256 "$SOURCE" "$OUT/AppIcon.icns"
  wc -c "$SOURCE" "$OUT/AppIcon.icns"
  file "$SOURCE" "$OUT/AppIcon.icns"
  if [ -f "$OUT/VolumeIcon.icns" ]; then
    shasum -a 256 "$OUT/VolumeIcon.icns"
    wc -c "$OUT/VolumeIcon.icns"
    file "$OUT/VolumeIcon.icns"
    printf 'volume_cmp='; cmp -s "$SOURCE" "$OUT/VolumeIcon.icns" && echo PASS || echo FAIL
  else
    echo 'volume_icon=missing'
  fi
  printf 'app_cmp='; cmp -s "$SOURCE" "$OUT/AppIcon.icns" && echo PASS || echo FAIL
  printf 'volume_custom_icon_flag=C%s\n' "$(xcrun GetFileInfo -aC "$MOUNT")"
  if [ -f "$MOUNT/.VolumeIcon.icns" ]; then
    printf 'volume_icon_hidden_flag=V%s\n' "$(xcrun GetFileInfo -aV "$MOUNT/.VolumeIcon.icns")"
    printf 'volume_icon_xattrs:\n'; xattr -l "$MOUNT/.VolumeIcon.icns" || true
  fi
  printf 'volume_root_xattrs:\n'; xattr -l "$MOUNT" || true
  printf 'source_icon_xattrs:\n'; xattr -l "$SOURCE" || true
} > "$OUT/diagnosis.txt" 2>&1

rm -rf "$OUT/source.iconset" "$OUT/volume.iconset" "$OUT/app.iconset"
iconutil -c iconset "$SOURCE" -o "$OUT/source.iconset"
if [ -f "$OUT/VolumeIcon.icns" ]; then iconutil -c iconset "$OUT/VolumeIcon.icns" -o "$OUT/volume.iconset"; fi
iconutil -c iconset "$OUT/AppIcon.icns" -o "$OUT/app.iconset"
find "$OUT/source.iconset" -type f -print0 | sort -z | xargs -0 shasum -a 256 > "$OUT/source-iconset.sha256"
if [ -d "$OUT/volume.iconset" ]; then find "$OUT/volume.iconset" -type f -print0 | sort -z | xargs -0 shasum -a 256 > "$OUT/volume-iconset.sha256"; fi
find "$OUT/app.iconset" -type f -print0 | sort -z | xargs -0 shasum -a 256 > "$OUT/app-iconset.sha256"

python3 - "$OUT" >> "$OUT/diagnosis.txt" <<'PY'
from pathlib import Path
import hashlib, sys
root = Path(sys.argv[1])
sets = {name: root / f'{name}.iconset' for name in ('source', 'volume', 'app') if (root / f'{name}.iconset').is_dir()}
def hashes(path):
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(path.iterdir())}
h = {name: hashes(path) for name, path in sets.items()}
print('source_files=' + ','.join(h['source']))
print('volume_files=' + ','.join(h.get('volume', {})))
print('app_files=' + ','.join(h['app']))
print('source_volume_iconset_equal=' + str(h['source'] == h.get('volume')))
print('source_app_iconset_equal=' + str(h['source'] == h['app']))
for name in sorted(set(h['source']) | set(h.get('volume', {}))):
    if h['source'].get(name) != h.get('volume', {}).get(name):
        print(f'volume_difference={name}:{h["source"].get(name)}:{h.get("volume", {}).get(name)}')
PY

cat "$OUT/diagnosis.txt"
