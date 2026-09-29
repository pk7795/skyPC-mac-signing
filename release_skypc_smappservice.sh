#!/bin/bash
# Release a SkyPC binary that uses the bundled SMAppService login-agent flow.
set +x
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_SCRIPT="$SCRIPT_DIR/release_skypc.sh"
AGENT_PLIST="$SCRIPT_DIR/template/com.sub2s.skypc.login-agent.plist"
FLOW_MARKER='com.sub2s.skypc.login-agent.plist'

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: ./release_skypc_smappservice.sh /path/to/skypc [release_skypc.sh options]

The input must be a newly built binary containing the SMAppService login-agent
flow. This wrapper embeds the reviewed LaunchAgent plist and then runs the
existing Developer ID signing, DMG, notarization and verification pipeline.

Example:
  ./release_skypc_smappservice.sh ./skypc-0.9.37 --version 0.9.37 --build 10

Use --prepare-only to validate and inspect the unsigned bundle without signing
or contacting Apple. All remaining options are passed to release_skypc.sh.
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
plutil -lint "$AGENT_PLIST" >/dev/null || die "Invalid LaunchAgent plist: $AGENT_PLIST"

# The old 0.9.37 build writes a legacy plist on every launch. Refuse it here so
# a correctly packaged DMG cannot silently reproduce the company-name entry.
LC_ALL=C grep -a -F -q "$FLOW_MARKER" "$BINARY" ||
  die 'Binary does not contain the SMAppService login-item flow; rebuild skypc-app first'

exec "$RELEASE_SCRIPT" "$BINARY" --launch-agent-plist "$AGENT_PLIST" "$@"
