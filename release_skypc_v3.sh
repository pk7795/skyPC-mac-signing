#!/bin/bash
# Consume outputs from skypc-app/build_mac_artifact.sh, verify both DMGs, then
# run the production legacy Developer ID release pipeline for each binary.
set +x
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${SKYPC_APP_DIR:-$SCRIPT_DIR/../skypc-app}"
LEGACY_RELEASE="$SCRIPT_DIR/release_skypc_v2.sh"
DEVICE='' MOUNT='' ATTACH_PLIST=''

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: ./release_skypc_v3.sh --from-build <arm64|x86_64|all> --build NUMBER [release options]

Consumes artifacts previously created by skypc-app/build_mac_artifact.sh,
validates each ad-hoc DMG and matching target architecture, then delegates the
target binaries to release_skypc_v2.sh for Developer ID signing, branded DMG
creation, notarization and final verification.

Examples:
  ./release_skypc_v3.sh --from-build all --build 13
  ./release_skypc_v3.sh --from-build arm64 --build 13 --skip-smoke-test

`--from-build all` consumes the two binaries and ad-hoc DMGs already produced by
`skypc-app/build_mac_artifact.sh all`; it does not invoke Cargo or rebuild them.
Version comes from skypc-app/Cargo.toml and cannot be overridden. Each
architecture receives its own signed DMG, release directory and runtime gate.
Final DMGs use the Ubuntu-aligned names
`skypc_<version>-<build>_<arch>.dmg` and the adjacent `.sha256` file, where
`<arch>` is `arm64`, `x86_64`, or `universal` for a direct universal input.
EOF
}
read_attachment() {
  local index entry point
  # Do not depend on `plutil -extract ... raw` returning an array length. That
  # behavior differs between macOS/plutil versions. Walking indexed keypaths
  # works for both XML and binary hdiutil attach plists.
  [ -s "$ATTACH_PLIST" ] || return 1
  DEVICE=''
  MOUNT=''
  mount_count=0
  index=0
  while plutil -type "system-entities.$index" "$ATTACH_PLIST" >/dev/null 2>&1; do
    entry="$(plutil -extract "system-entities.$index.dev-entry" raw -o - "$ATTACH_PLIST" 2>/dev/null)" || entry=''
    case "$entry" in /dev/disk*) [ -z "$DEVICE" ] && DEVICE="$entry" ;; esac
    point="$(plutil -extract "system-entities.$index.mount-point" raw -o - "$ATTACH_PLIST" 2>/dev/null)" || point=''
    if [ -n "$point" ]; then MOUNT="$point"; mount_count=$((mount_count + 1)); fi
    index=$((index + 1))
  done
}
cleanup() {
  local rc=$?
  trap - EXIT
  if [ -z "$DEVICE" ] && [ -n "$ATTACH_PLIST" ] && [ -s "$ATTACH_PLIST" ]; then read_attachment || true; fi
  if [ -n "$DEVICE" ]; then hdiutil detach "$DEVICE" >/dev/null 2>&1 || rc=1; fi
  if [ -n "$ATTACH_PLIST" ]; then rm -f "$ATTACH_PLIST"; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

command -v lipo >/dev/null || die 'lipo is required'
REQUESTED_ARCH=''
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --from-build)
    [ "$#" -ge 2 ] || die 'Provide arm64, x86_64 or all after --from-build'
    MODE=from-build
    REQUESTED_ARCH="$2"
    shift 2
    ;;
  '') usage; exit 1 ;;
  *) die 'Run ./build_mac_artifact.sh all first, then use --from-build all' ;;
esac

case "$REQUESTED_ARCH" in
  arm64|aarch64|apple-silicon) REQUESTED_ARCH=arm64 ;;
  x86_64|x64|intel) REQUESTED_ARCH=x86_64 ;;
  all) ;;
  *) die 'Use arm64, x86_64 or all after --from-build' ;;
esac

[ -x "$LEGACY_RELEASE" ] || die "Missing legacy release wrapper: $LEGACY_RELEASE"
command -v hdiutil >/dev/null || die 'hdiutil is required'
command -v plutil >/dev/null || die 'plutil is required'

BUILD_SEEN=0
EXPECT_BUILD_VALUE=0
for argument in "$@"; do
  if [ "$EXPECT_BUILD_VALUE" -eq 1 ]; then
    [[ "$argument" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die 'Build must contain one to three numeric components'
    EXPECT_BUILD_VALUE=0
    continue
  fi
  case "$argument" in
    --build)
      [ "$BUILD_SEEN" -eq 0 ] || die 'Specify --build only once'
      BUILD_SEEN=1
      EXPECT_BUILD_VALUE=1
      ;;
    --version) die 'Version is read from skypc-app/Cargo.toml in the v3 flow' ;;
    --launch-agent-plist) die 'The v3 legacy flow does not accept --launch-agent-plist' ;;
  esac
done
[ "$BUILD_SEEN" -eq 1 ] && [ "$EXPECT_BUILD_VALUE" -eq 0 ] || die 'An explicit --build NUMBER is required'

VERSION="$(awk '/^version = / {gsub(/"/, "", $3); print $3; exit}' "$APP_DIR/Cargo.toml")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Cannot read a semantic version from skypc-app/Cargo.toml'

configure_arch() {
  case "$1" in
    arm64)
      ARCH=arm64
      TARGET=aarch64-apple-darwin
      MINIMUM_OS=11.0
      BUILD_DMG="$APP_DIR/dist/skyPC-macOS-AppleSilicon.dmg"
      ;;
    x86_64)
      ARCH=x86_64
      TARGET=x86_64-apple-darwin
      MINIMUM_OS=10.12
      BUILD_DMG="$APP_DIR/dist/skyPC-macOS-Intel.dmg"
      ;;
    *) die "Unsupported architecture: $1" ;;
  esac
  TARGET_BINARY="$APP_DIR/target/$TARGET/release/skypc"
}

detach_build_artifact() {
  hdiutil detach "$DEVICE" >/dev/null
  DEVICE=''
  MOUNT=''
  rm -f "$ATTACH_PLIST"
  ATTACH_PLIST=''
}

validate_build_artifact() {
  local comparison_mode="$1" attach_rc=0 target_arch source_arch
  [ -f "$TARGET_BINARY" ] || die "Build did not produce: $TARGET_BINARY"
  [ -f "$BUILD_DMG" ] || die "Build did not produce: $BUILD_DMG"
  file "$TARGET_BINARY" | grep -q 'Mach-O.*executable' || die 'Built client is not a Mach-O executable'
  target_arch="$(SKYPC_EXPECTED_ARCH="$ARCH" lipo -archs "$TARGET_BINARY")"
  [ "$target_arch" = "$ARCH" ] || die "Built client must be a thin $ARCH executable"
  if [ "$comparison_mode" = signed ] && [ "$TARGET_BINARY" -nt "$BUILD_DMG" ]; then
    die "Build DMG is older than its target binary; rerun ./build_mac_artifact.sh $ARCH"
  fi
  if LC_ALL=C grep -a -F -q 'com.sub2s.skypc.login-agent.plist' "$TARGET_BINARY"; then
    die "The $ARCH binary still contains the paused SMAppService login flow"
  fi

  ATTACH_PLIST="$(mktemp /private/tmp/skypc-v3-attach.XXXXXX)"
  hdiutil attach "$BUILD_DMG" -readonly -nobrowse -noautoopen -plist > "$ATTACH_PLIST" || attach_rc=$?
  read_attachment || die 'Cannot parse the build DMG attach result'
  [ "$attach_rc" -eq 0 ] || die 'Could not attach the build DMG read-only'
  [ -n "$DEVICE" ] && [ "$mount_count" -ge 1 ] && [ -d "$MOUNT" ] || die "Expected at least one mounted filesystem from the build DMG (device=$DEVICE mount_count=$mount_count mount=$MOUNT)"

  SOURCE_APP="$MOUNT/skyPC.app"
  SOURCE_PLIST="$SOURCE_APP/Contents/Info.plist"
  SOURCE_BINARY="$SOURCE_APP/Contents/MacOS/skypc"
  [ -f "$SOURCE_PLIST" ] && [ -f "$SOURCE_BINARY" ] || die 'Build DMG is missing skyPC.app or its executable'
  [ "$(plutil -extract CFBundleIdentifier raw -o - "$SOURCE_PLIST")" = com.skypc.client ] || die 'Unexpected build-artifact bundle identifier'
  [ "$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw -o - "$SOURCE_PLIST")" = skypc ] || die 'Build artifact must register the skypc OIDC URL scheme'
  [ "$(plutil -extract CFBundleShortVersionString raw -o - "$SOURCE_PLIST")" = "$VERSION" ] || die 'Build-artifact version does not match Cargo.toml'
  [ "$(plutil -extract LSMinimumSystemVersion raw -o - "$SOURCE_PLIST")" = "$MINIMUM_OS" ] || die "Build-artifact minimum macOS must be $MINIMUM_OS for $ARCH"
  source_arch="$(SKYPC_EXPECTED_ARCH="$ARCH" lipo -archs "$SOURCE_BINARY")"
  [ "$source_arch" = "$ARCH" ] || die "Build DMG must contain a thin $ARCH executable"
  if [ "$comparison_mode" = exact ]; then
    cmp -s "$TARGET_BINARY" "$SOURCE_BINARY" || die 'DMG executable differs from the target release binary'
  else
    codesign --verify --deep --strict "$SOURCE_APP" || die 'Existing build DMG app has an invalid ad-hoc signature'
  fi
  detach_build_artifact
  printf 'Verified build artifact: %s\nRelease binary: %s\n' "$BUILD_DMG" "$TARGET_BINARY"
}

run_legacy_release() {
  local release_arch="$1" release_binary="$2" release_dmg="$3" minimum_os="$4" index
  shift 4
  local options=("$@")
  if [ "$REQUESTED_ARCH" = all ]; then
    for ((index=0; index<${#options[@]}; index++)); do
      if [ "${options[$index]}" = --output-dir ]; then
        [ $((index + 1)) -lt ${#options[@]} ] || die '--output-dir requires a path'
        options[$((index + 1))]="${options[$((index + 1))]}/$release_arch"
      fi
    done
  fi
  printf '\n[release existing %s build]\n' "$release_arch"
  "$LEGACY_RELEASE" "$release_binary" --version "$VERSION" --minimum-os "$minimum_os" --source-artifact "$release_dmg" "${options[@]}"
}

if [ "$REQUESTED_ARCH" = all ]; then
  configure_arch arm64
  validate_build_artifact signed
  ARM_BINARY="$TARGET_BINARY"
  ARM_DMG="$BUILD_DMG"
  ARM_MINIMUM_OS="$MINIMUM_OS"
  configure_arch x86_64
  validate_build_artifact signed
  INTEL_BINARY="$TARGET_BINARY"
  INTEL_DMG="$BUILD_DMG"
  INTEL_MINIMUM_OS="$MINIMUM_OS"
  run_legacy_release arm64 "$ARM_BINARY" "$ARM_DMG" "$ARM_MINIMUM_OS" "$@"
  run_legacy_release x86_64 "$INTEL_BINARY" "$INTEL_DMG" "$INTEL_MINIMUM_OS" "$@"
else
  configure_arch "$REQUESTED_ARCH"
  validate_build_artifact signed
  run_legacy_release "$ARCH" "$TARGET_BINARY" "$BUILD_DMG" "$MINIMUM_OS" "$@"
fi
