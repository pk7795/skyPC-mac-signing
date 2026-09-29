#!/bin/bash
set -euo pipefail

ROOT='/Users/khoakheu/SkyPC-workspace/Mac-signing'
DMG="$ROOT/releases/SkyPC-0.9.27-7-20260922T165900Z.j9MO8b/dist/SkyPC.dmg"
OUT="$ROOT/tests/evidence/2026-09-23-build7-finder.png"
WORK="$(mktemp -d /private/tmp/skypc-build7-visual.XXXXXX)"
DEVICE=''
MOUNT=''

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$MOUNT" ]; then
    osascript -e 'tell application "Finder" to close every window whose name is "SkyPC"' >/dev/null 2>&1 || true
  fi
  if [ -n "$DEVICE" ]; then hdiutil detach "$DEVICE" > "$WORK/detach.log" 2>&1 || rc=1; fi
  printf 'work=%s\n' "$WORK"
  exit "$rc"
}
trap cleanup EXIT

hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -plist > "$WORK/attach.plist"
eval "$(python3 - "$WORK/attach.plist" <<'PY'
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

open "$MOUNT"
sleep 4
osascript - "$MOUNT" > "$WORK/finder-window.txt" <<'APPLESCRIPT'
on run argv
    set rootAlias to POSIX file (item 1 of argv) as alias
    tell application "Finder"
        activate
        set targetWindow to front window
        set target of targetWindow to rootAlias
        set bounds of targetWindow to {100, 100, 1000, 451}
        update rootAlias without registering applications
        delay 2
        return (name of targetWindow) & "|" & (bounds of targetWindow as text)
    end tell
end run
APPLESCRIPT
screencapture -x -R100,100,900,351 "$OUT"
sips -g pixelWidth -g pixelHeight "$OUT"
cat "$WORK/finder-window.txt"
printf 'screenshot=%s\n' "$OUT"
