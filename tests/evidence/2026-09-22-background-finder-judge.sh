#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE="$ROOT/releases/SkyPC-0.9.27-5-20260922T154416Z.AT8wpY/build/SkyPC-rw.dmg"
SOURCE_ROOT="$ROOT/releases/SkyPC-0.9.27-5-20260922T154416Z.AT8wpY/build/dmg-root"
PYTHON="$ROOT/.venv/bin/python"
WORK="$(mktemp -d /private/tmp/skypc-finder-judge.XXXXXX)"
IMAGE="$WORK/judge.dmg"
PLIST="$WORK/attach.plist"
DEVICE=''
MOUNT=''
RECONFIGURE="${RECONFIGURE:-0}"
FINDER_CONFIGURE="${FINDER_CONFIGURE:-0}"
FRESH="${FRESH:-0}"
FINALIZE="${FINALIZE:-0}"
JUDGE_VOLUME_NAME="${JUDGE_VOLUME_NAME:-SkyPC-JUDGE}"

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$DEVICE" ]; then
    hdiutil detach "$DEVICE" > "$WORK/detach.log" 2>&1 || rc=1
  fi
  printf 'judge_work=%s\n' "$WORK"
  exit "$rc"
}
trap cleanup EXIT

if [ "$FRESH" = 1 ]; then
  mkdir "$WORK/root"
  ditto "$SOURCE_ROOT" "$WORK/root"
  rm -f "$WORK/root/.DS_Store"
  hdiutil create -volname "$JUDGE_VOLUME_NAME" -fs HFS+ -srcfolder "$WORK/root" -format UDRW "$IMAGE" > "$WORK/create.log"
else
  cp "$SOURCE" "$IMAGE"
fi
hdiutil attach -readwrite -nobrowse -plist "$IMAGE" > "$PLIST"
count="$(plutil -extract system-entities raw -o - "$PLIST")"
for ((index=0; index<count; index++)); do
  entry="$(plutil -extract "system-entities.$index.dev-entry" raw -o - "$PLIST" 2>/dev/null || true)"
  point="$(plutil -extract "system-entities.$index.mount-point" raw -o - "$PLIST" 2>/dev/null || true)"
  if [ -z "$DEVICE" ]; then
    case "$entry" in /dev/disk*) DEVICE="$entry" ;; esac
  fi
  if [ -n "$point" ]; then MOUNT="$point"; fi
done
[ -n "$DEVICE" ] && [ -n "$MOUNT" ]

if [ "$RECONFIGURE" = 1 ]; then
  diskutil rename "$DEVICE" SkyPC-JUDGE > "$WORK/rename.log"
  MOUNT='/Volumes/SkyPC-JUDGE'
  [ -d "$MOUNT" ]
  "$PYTHON" "$ROOT/dmg_layout.py" configure "$MOUNT" 900 351 --volume-name SkyPC-JUDGE
  sync
fi

printf 'judge_device=%s\njudge_mount=%s\n' "$DEVICE" "$MOUNT"
if [ -f "$MOUNT/.DS_Store" ]; then cp "$MOUNT/.DS_Store" "$WORK/DS_Store.before"; fi
"$PYTHON" - "$MOUNT/.DS_Store" > "$WORK/records-before.txt" <<'PY'
import sys
from pathlib import Path
from ds_store import DSStore
import ds_store.store as ds_store_store
ds_store_store.codecs.pop(b'pBBk', None)
if not Path(sys.argv[1]).is_file():
    print('no .DS_Store')
    raise SystemExit(0)
with DSStore.open(sys.argv[1], 'r') as store:
    for record in store:
        print(record.filename, record.code.decode('ascii'))
PY

if [ "$FINDER_CONFIGURE" = 1 ]; then
  osascript "$ROOT/finder_layout.applescript" "$MOUNT" 900 351
  sleep 5
  "$PYTHON" "$ROOT/dmg_layout.py" verify "$MOUNT" 900 351 --volume-name "$JUDGE_VOLUME_NAME"
fi

open "$MOUNT"
sleep 5

cp "$MOUNT/.DS_Store" "$WORK/DS_Store.after"
"$PYTHON" - "$MOUNT/.DS_Store" > "$WORK/records-after.txt" <<'PY'
import sys
from ds_store import DSStore
import ds_store.store as ds_store_store
ds_store_store.codecs.pop(b'pBBk', None)
with DSStore.open(sys.argv[1], 'r') as store:
    records = [(record.filename, record.code.decode('ascii')) for record in store]
for record in records:
    print(*record)
bookmarks = [record for record in records if record[1] in ('pBBk', 'pBB0')]
print('bookmark_records', bookmarks)
if not bookmarks:
    raise SystemExit('Finder did not resolve the background alias')
PY

printf 'PASS: Finder resolved the background alias and wrote bookmark records\n'

if [ "$FINALIZE" = 1 ]; then
  hdiutil detach "$DEVICE" > "$WORK/detach-writable.log"
  DEVICE=''
  MOUNT=''
  hdiutil convert "$IMAGE" -format UDZO -o "$WORK/background-preview.dmg" > "$WORK/convert.log"
  PLIST="$WORK/attach-final.plist"
  hdiutil attach -readonly -nobrowse -plist "$WORK/background-preview.dmg" > "$PLIST"
  count="$(plutil -extract system-entities raw -o - "$PLIST")"
  for ((index=0; index<count; index++)); do
    entry="$(plutil -extract "system-entities.$index.dev-entry" raw -o - "$PLIST" 2>/dev/null || true)"
    point="$(plutil -extract "system-entities.$index.mount-point" raw -o - "$PLIST" 2>/dev/null || true)"
    if [ -z "$DEVICE" ]; then
      case "$entry" in /dev/disk*) DEVICE="$entry" ;; esac
    fi
    if [ -n "$point" ]; then MOUNT="$point"; fi
  done
  [ -n "$DEVICE" ] && [ -n "$MOUNT" ]
  "$PYTHON" "$ROOT/dmg_layout.py" verify "$MOUNT" 900 351 --volume-name "$JUDGE_VOLUME_NAME"
  open "$MOUNT"
  sleep 5
  shasum -a 256 "$WORK/background-preview.dmg"
  printf 'preview=%s/background-preview.dmg\n' "$WORK"
fi
