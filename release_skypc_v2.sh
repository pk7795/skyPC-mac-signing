#!/bin/bash
# Release a SkyPC binary using the legacy per-user LaunchAgent login flow.
set +x
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_SCRIPT="$SCRIPT_DIR/release_skypc.sh"
SMAPP_MARKER='com.sub2s.skypc.login-agent.plist'

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: ./release_skypc_v2.sh /path/to/skypc [release_skypc.sh options]

Release a binary built from the legacy login-startup source. This wrapper does
not embed the SMAppService LaunchAgent and delegates signing, DMG creation,
notarization and verification to release_skypc.sh.

Example:
  ./release_skypc_v2.sh ./skypc-0.9.38 --version 0.9.38 --build 13

Rebuild skypc-app after stashing the SMAppService source change. The wrapper
rejects binaries that still contain that flow. Use --prepare-only to validate
the unsigned bundle without signing or contacting Apple.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage; exit 1 ;;
  -*) die 'The input binary must be the first argument' ;;
esac

BINARY="$1"
shift
[ -f "$BINARY" ] || die "Missing binary: $BINARY"
[ -x "$RELEASE_SCRIPT" ] || die "Missing release engine: $RELEASE_SCRIPT"

for argument in "$@"; do
  [ "$argument" != --launch-agent-plist ] ||
    die 'release_skypc_v2.sh does not accept --launch-agent-plist'
done

# Require a rebuild from the stashed legacy source. Merely omitting the bundled
# plist from a new-flow binary would leave different startup behavior in place.
if LC_ALL=C grep -a -F -q "$SMAPP_MARKER" "$BINARY"; then
  die 'Binary still contains the SMAppService login flow; rebuild skypc-app after applying the legacy source state'
fi

exec "$RELEASE_SCRIPT" "$BINARY" "$@"
