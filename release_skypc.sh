#!/bin/bash
# macOS Bash 3.2 compatible. See SkyPC_macOS_release_signing_guide_v2.md.
set +x
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
PLIST_SOURCE="$SCRIPT_DIR/template/Info.plist"
ICON="$SCRIPT_DIR/../skypc-app/assets/AppIcon.icns"
BACKGROUND="$SCRIPT_DIR/../skypc-app/assets/background.jpg"
LAYOUT_SCRIPT="$SCRIPT_DIR/dmg_layout.py"
FINDER_SCRIPT="$SCRIPT_DIR/finder_layout.applescript"
LAYOUT_PYTHON="${SKYPC_LAYOUT_PYTHON:-$SCRIPT_DIR/.venv/bin/python3}"
BINARY='' OUTPUT='' VERSION='' BUILD='' MINIMUM_OS='' PACKAGE_ARCH=''
ENTITLEMENTS="$SCRIPT_DIR/template/SkyPC.entitlements"
LAUNCH_AGENT_PLIST='' SOURCE_ARTIFACT=''
PREPARE_ONLY=0 SKIP_SMOKE=0 PROMPT_PASSWORD=0 INIT_ENV=0
RUN_DIR='' MOUNT='' DEVICE='' ATTACH_PLIST='' MOUNT_COUNT=0 STAGE='arguments'

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: ./release_skypc.sh /path/to/skypc [options]
  --init-env              Create private .env from .env.example, then exit
  --env FILE             Literal .env file (default: beside this script)
  --version X.Y.Z         Override template release version
  --build NUMBER         Override template build version
  --minimum-os VERSION   Override LSMinimumSystemVersion (for example 10.12)
  --output-dir DIR       New run root with build/ and dist/; must not exist
  --icon FILE.icns        App + volume icon (default: skypc-app/assets/AppIcon.icns)
  --background FILE      DMG artwork (default: skypc-app/assets/background.jpg)
  --plist FILE           Clean plist (default: template/Info.plist)
  --entitlements FILE    Reviewed camera/microphone entitlements
  --launch-agent-plist FILE
                         Embed a reviewed SMAppService LaunchAgent plist
  --source-artifact FILE Record the upstream build artifact in release evidence
  --prompt-password      Use Apple ID with a hidden password prompt
  --prepare-only         Validate and create unsigned bundle; no network/signing
  --skip-smoke-test      Skip interactive runtime test; record it as unverified
  -h, --help             Show help

One-time layout tools: python3 -m venv .venv
                      .venv/bin/python -m pip install -r dmg-layout-requirements.txt
Default output: releases/SkyPC-<version>-<build>-<UTC timestamp>.XXXXXX/
Success: dist/skypc_<version>-<build>_<arch>.dmg and its .sha256; logs/evidence in run root.
Drag SkyPC.app to Applications, then search SkyPC in Spotlight (Cmd+Space).
EOF
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --init-env) INIT_ENV=1; shift ;;
    --prepare-only) PREPARE_ONLY=1; shift ;;
    --skip-smoke-test) SKIP_SMOKE=1; shift ;;
    --prompt-password) PROMPT_PASSWORD=1; shift ;;
    --env|--version|--build|--minimum-os|--output-dir|--icon|--background|--plist|--entitlements|--launch-agent-plist|--source-artifact)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die "Missing value for $1"
      case "$1" in
        --env) ENV_FILE="$2" ;; --version) VERSION="$2" ;; --build) BUILD="$2" ;;
        --minimum-os) MINIMUM_OS="$2" ;;
        --output-dir) OUTPUT="$2" ;; --icon) ICON="$2" ;; --plist) PLIST_SOURCE="$2" ;;
        --background) BACKGROUND="$2" ;;
        --entitlements) ENTITLEMENTS="$2" ;;
        --launch-agent-plist) LAUNCH_AGENT_PLIST="$2" ;;
        --source-artifact) SOURCE_ARTIFACT="$2" ;;
      esac
      shift 2 ;;
    -*) die "Unknown option: $1" ;;
    *) [ -z "$BINARY" ] || die 'Only one input binary is supported'; BINARY="$1"; shift ;;
  esac
done
if [ "$INIT_ENV" -eq 1 ]; then
  (set -o noclobber; cat "$SCRIPT_DIR/.env.example" > "$ENV_FILE") || die '.env already exists or cannot be created'
  chmod 600 "$ENV_FILE"
  printf 'Created %s (mode 600). Fill in your Apple ID and app-specific password.\n' "$ENV_FILE"
  exit 0
fi
[ -n "$BINARY" ] || { usage; exit 1; }
[ "$(uname -s)" = Darwin ] || die 'Run on macOS with Xcode command-line tools'

# Deliberately do NOT source .env: values are literal, never shell commands.
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
if [ -f "$ENV_FILE" ]; then
  [ ! -L "$ENV_FILE" ] || die '.env must not be a symlink'
  [ "$(stat -f %u "$ENV_FILE")" = "$(id -u)" ] || die '.env must belong to the current user'
  case "$(stat -f %Lp "$ENV_FILE")" in 600|400) ;; *) die 'Run chmod 600 on your .env file' ;; esac
  line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1)); line="$(trim "$line")"
    case "$line" in ''|\#*) continue ;; esac
    case "$line" in *=*) ;; *) die "Invalid .env assignment at line $line_no" ;; esac
    key="$(trim "${line%%=*}")"; value="$(trim "${line#*=}")"
    case "$key" in
      APPLE_ID|APPLE_APP_SPECIFIC_PASSWORD|APPLE_TEAM_ID|SIGNING_IDENTITY|NOTARY_PROFILE|NOTARY_AUTH) ;;
      *) die "Unsupported .env key at line $line_no" ;;
    esac
    case "$value" in
      \"*\") value="${value:1:${#value}-2}" ;;
      \'*\') value="${value:1:${#value}-2}" ;;
      \"*|\'*) die "Unclosed quote in .env at line $line_no" ;;
    esac
    printf -v "$key" '%s' "$value"
  done < "$ENV_FILE"
  unset line value
elif [ "$ENV_FILE" != "$SCRIPT_DIR/.env" ]; then
  die 'Explicit --env file does not exist'
fi
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Sub2s Technology and Media Broadcasting Joint Stock Company (P4F9DNFZ68)}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-P4F9DNFZ68}"
NOTARY_PROFILE="${NOTARY_PROFILE:-SkyPC-Notary}"
NOTARY_AUTH="${NOTARY_AUTH:-keychain}"

absolute_file() {
  [ -f "$1" ] || die "Missing file: $1"
  printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")"
}
plist_get() { plutil -extract "$1" raw -o - "$2"; }
validate_oidc_url_metadata() {
  local plist="$1"
  [ "$(plist_get CFBundleURLTypes.0.CFBundleTypeRole "$plist")" = Viewer ] ||
    die 'OIDC URL handler must use CFBundleTypeRole Viewer'
  [ "$(plist_get CFBundleURLTypes.0.CFBundleURLName "$plist")" = com.sub2s.skypc.oidc ] ||
    die 'OIDC URL handler name must be com.sub2s.skypc.oidc'
  [ "$(plist_get CFBundleURLTypes.0.CFBundleURLSchemes.0 "$plist")" = skypc ] ||
    die 'OIDC URL handler must register the skypc scheme'
}
entitlement_get() {
  local escaped_key="${1//./\\.}"
  plutil -extract "$escaped_key" raw -o - "$2"
}
entitlement_has() {
  local escaped_key="${1//./\\.}"
  plutil -type "$escaped_key" "$2" >/dev/null 2>&1
}
BINARY="$(absolute_file "$BINARY")"
ICON="$(absolute_file "$ICON")"
BACKGROUND="$(absolute_file "$BACKGROUND")"
LAYOUT_SCRIPT="$(absolute_file "$LAYOUT_SCRIPT")"
FINDER_SCRIPT="$(absolute_file "$FINDER_SCRIPT")"
PLIST_SOURCE="$(absolute_file "$PLIST_SOURCE")"
ENTITLEMENTS="$(absolute_file "$ENTITLEMENTS")"
plutil -lint "$ENTITLEMENTS"
for required_entitlement in com.apple.security.device.camera com.apple.security.device.audio-input; do
  [ "$(entitlement_get "$required_entitlement" "$ENTITLEMENTS")" = true ] ||
    die "Required entitlement missing or false: $required_entitlement"
done
for unsupported_entitlement in \
  com.apple.security.app-sandbox \
  com.apple.security.network.client \
  com.apple.security.network.server \
  com.apple.security.device.usb \
  com.apple.security.device.bluetooth \
  com.apple.security.device.microphone \
  com.apple.security.cs.allow-jit \
  com.apple.security.cs.allow-unsigned-executable-memory \
  com.apple.security.cs.disable-library-validation; do
  ! entitlement_has "$unsupported_entitlement" "$ENTITLEMENTS" ||
    die "Unsupported or unreviewed entitlement must be removed: $unsupported_entitlement"
done
if [ -n "$LAUNCH_AGENT_PLIST" ]; then
  LAUNCH_AGENT_PLIST="$(absolute_file "$LAUNCH_AGENT_PLIST")"
  [ "$(basename "$LAUNCH_AGENT_PLIST")" = com.sub2s.skypc.login-agent.plist ] || die 'Unexpected LaunchAgent plist name'
  plutil -lint "$LAUNCH_AGENT_PLIST"
  [ "$(plist_get Label "$LAUNCH_AGENT_PLIST")" = com.sub2s.skypc.login-agent ] || die 'Unexpected LaunchAgent label'
  [ "$(plist_get BundleProgram "$LAUNCH_AGENT_PLIST")" = Contents/MacOS/skypc ] || die 'Unexpected LaunchAgent BundleProgram'
  [ "$(plist_get AssociatedBundleIdentifiers "$LAUNCH_AGENT_PLIST")" = com.sub2s.skypc ] || die 'LaunchAgent must be associated with com.sub2s.skypc'
fi
if [ -n "$SOURCE_ARTIFACT" ]; then SOURCE_ARTIFACT="$(absolute_file "$SOURCE_ARTIFACT")"; fi
for tool in file lipo otool iconutil plutil shasum ditto xattr sips; do
  command -v "$tool" >/dev/null || die "Missing tool: $tool"
done
file "$BINARY" | grep -q 'Mach-O.*executable' || die 'Input must be a Mach-O executable (arm64, x86_64 or universal)'
ARCHES="$(lipo -archs "$BINARY" 2>/dev/null || true)"
case "$ARCHES" in
  arm64) PACKAGE_ARCH=arm64 ;;
  x86_64) PACKAGE_ARCH=x86_64 ;;
  'arm64 x86_64'|'x86_64 arm64') PACKAGE_ARCH=universal ;;
  *) die "Unsupported Mach-O architecture set: ${ARCHES:-<unknown>}" ;;
esac
plutil -lint "$PLIST_SOURCE"
validate_oidc_url_metadata "$PLIST_SOURCE"
for required_privacy_key in NSCameraUsageDescription NSMicrophoneUsageDescription NSLocalNetworkUsageDescription; do
  [ -n "$(plist_get "$required_privacy_key" "$PLIST_SOURCE")" ] ||
    die "Missing template key: $required_privacy_key"
done
[ -n "$VERSION" ] || VERSION="$(plist_get CFBundleShortVersionString "$PLIST_SOURCE")"
[ -n "$BUILD" ] || BUILD="$(plist_get CFBundleVersion "$PLIST_SOURCE")"
[ -n "$MINIMUM_OS" ] || MINIMUM_OS="$(plist_get LSMinimumSystemVersion "$PLIST_SOURCE")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Version must be X.Y.Z'
[[ "$BUILD" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die 'Build must contain one to three numeric components'
[[ "$MINIMUM_OS" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die 'Minimum OS must be a dotted numeric version'
[ "$(plist_get CFBundleIdentifier "$PLIST_SOURCE")" = com.sub2s.skypc ] || die 'Expected release bundle ID com.sub2s.skypc'

# A binary-only release cannot satisfy Homebrew/local dependencies. Swift
# back-deployment overlays are allowed only through Apple's runtime path or the
# reviewed app-local Frameworks directory. Releases below macOS 11 must carry
# the app-local path and bundle the runtime into the application.
SWIFT_RPATHS="$(otool -l "$BINARY" | awk '
  $1 == "cmd" && $2 == "LC_RPATH" { want_path=1; next }
  want_path && $1 == "path" { print $2; want_path=0 }
')"
SWIFT_DEPENDENCIES="$(otool -L "$BINARY" | awk '/^[[:space:]]@rpath\/libswift.*\.dylib/ {print $1}')"
BUNDLE_SWIFT=0
while IFS= read -r runtime_path; do
  [ -z "$runtime_path" ] && continue
  case "$runtime_path" in
    /usr/lib/swift|@executable_path/../Frameworks) ;;
    *) die "Swift dependency has an unreviewed RPATH: $runtime_path" ;;
  esac
done <<< "$SWIFT_RPATHS"
otool -L "$BINARY" | awk '/^[[:space:]]/ {print $1}' | while IFS= read -r dependency; do
  case "$dependency" in
    /System/Library/*|/usr/lib/*|@rpath/libswift*.dylib) ;;
    *) die "Non-system dependency requires a reviewed bundle: $dependency" ;;
  esac
done
if [ -n "$SWIFT_DEPENDENCIES" ]; then
  if grep -Fxq '@executable_path/../Frameworks' <<< "$SWIFT_RPATHS"; then
    BUNDLE_SWIFT=1
  elif awk -v version="$MINIMUM_OS" 'BEGIN { split(version, part, "."); exit !((part[1] + 0) < 11) }'; then
    die 'A release below macOS 11 with Swift dependencies requires @executable_path/../Frameworks'
  elif [ "$SWIFT_RPATHS" != /usr/lib/swift ]; then
    die 'Swift dependency requires a reviewed runtime RPATH'
  fi
fi
if [ "$BUNDLE_SWIFT" -eq 1 ]; then
  command -v xcrun >/dev/null || die 'xcrun is required to bundle the Swift runtime'
  xcrun --find swift-stdlib-tool >/dev/null || die 'Missing Xcode swift-stdlib-tool'
fi

if [ "$PREPARE_ONLY" -eq 0 ]; then
  for tool in codesign security hdiutil osascript spctl xcrun; do command -v "$tool" >/dev/null || die "Missing tool: $tool"; done
  [ -x "$LAYOUT_PYTHON" ] || die 'Install layout tools as shown in --help first'
  "$LAYOUT_PYTHON" -c 'import ds_store, mac_alias' || die 'Install dmg-layout-requirements.txt into the layout virtual environment'
  for tool in SetFile GetFileInfo notarytool stapler; do xcrun --find "$tool" >/dev/null || die "Missing Xcode tool: $tool"; done
  case "$SIGNING_IDENTITY" in 'Developer ID Application: '*) ;; *) die 'A Developer ID Application identity is required' ;; esac
  security find-identity -v -p codesigning | grep -F '"'"$SIGNING_IDENTITY"'"' >/dev/null || die 'Signing identity/private key not available in the current Keychain'
  [ "$SKIP_SMOKE" -eq 1 ] || [ -t 0 ] || die 'Runtime test requires a terminal (or explicit --skip-smoke-test)'
  if [ "$PROMPT_PASSWORD" -eq 1 ]; then NOTARY_AUTH=apple-id; unset APPLE_APP_SPECIFIC_PASSWORD; fi
  case "$NOTARY_AUTH" in
    keychain) AUTH=(--keychain-profile "$NOTARY_PROFILE") ;;
    apple-id)
      if [ -z "${APPLE_ID:-}" ]; then
        [ -t 0 ] || die 'Set APPLE_ID in .env'
        read -r -p 'Apple ID: ' APPLE_ID
      fi
      if [ -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]; then
        [ -t 0 ] || die 'Set APPLE_APP_SPECIFIC_PASSWORD in .env or run in a terminal'
        read -r -s -p 'Apple app-specific password: ' APPLE_APP_SPECIFIC_PASSWORD; printf '\n'
      fi
      [ -n "$APPLE_ID" ] && [ -n "$APPLE_APP_SPECIFIC_PASSWORD" ] || die 'Apple ID and app-specific password are required'
      AUTH=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD")
      unset APPLE_APP_SPECIFIC_PASSWORD ;;
    *) die 'NOTARY_AUTH must be apple-id or keychain' ;;
  esac
fi

if [ -n "$OUTPUT" ]; then
  mkdir -p "$(dirname "$OUTPUT")"
  mkdir "$OUTPUT" || die 'Output directory already exists or cannot be created'
  RUN_DIR="$(cd "$OUTPUT" && pwd)"
else
  mkdir -p "$SCRIPT_DIR/releases"
  RUN_DIR="$(mktemp -d "$SCRIPT_DIR/releases/SkyPC-$VERSION-$BUILD-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
fi
# Read only this run's attach result; never guess /Volumes/SkyPC or detach it.
read_attachment() {
  local index entry point
  # `plutil -extract system-entities raw` happens to return an array length on
  # current macOS releases, but that is an implementation detail of plutil's
  # Swift mode and is not stable across macOS versions.  Walk the array by
  # keypath instead; an out-of-range index is the portable end-of-array
  # signal.  This also keeps the parser independent of XML/binary plist form.
  [ -s "$ATTACH_PLIST" ] || return 1
  DEVICE=''
  MOUNT=''
  MOUNT_COUNT=0
  index=0
  while plutil -type "system-entities.$index" "$ATTACH_PLIST" >/dev/null 2>&1; do
    entry="$(plist_get "system-entities.$index.dev-entry" "$ATTACH_PLIST" 2>/dev/null || true)"
    case "$entry" in /dev/disk*) [ -z "$DEVICE" ] && DEVICE="$entry" ;; esac
    point="$(plist_get "system-entities.$index.mount-point" "$ATTACH_PLIST" 2>/dev/null || true)"
    if [ -n "$point" ]; then MOUNT="$point"; MOUNT_COUNT=$((MOUNT_COUNT + 1)); fi
    index=$((index + 1))
  done
}
cleanup() {
  local rc=$?
  trap - EXIT
  # Also discover our device if interrupted immediately after hdiutil attached it.
  if [ -z "$DEVICE" ] && [ -n "$ATTACH_PLIST" ] && [ -s "$ATTACH_PLIST" ]; then read_attachment || true; fi
  if [ -n "$DEVICE" ]; then
    if ! hdiutil detach "$DEVICE" >> "$RUN_DIR/cleanup.log" 2>&1; then
      printf 'Could not detach own device: %s (see cleanup.log)\n' "$DEVICE" >&2
      rc=1
    fi
  fi
  if [ "$rc" -ne 0 ]; then
    printf 'FAILED at %s. Evidence/work retained: %s\n' "$STAGE" "$RUN_DIR" >&2
    printf 'FAILED stage=%s exit=%s\n' "$STAGE" "$rc" >> "$RUN_DIR/release-evidence.txt"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
step() { STAGE="$1"; printf '\n[%s]\n' "$STAGE"; printf 'stage=%s\n' "$STAGE" >> "$RUN_DIR/release-evidence.txt"; }
run() {
  local log="$1"; shift
  if "$@" > "$RUN_DIR/$log" 2>&1; then return 0; else
    local rc=$?; printf 'Command failed (%s); see %s/%s\n' "$rc" "$RUN_DIR" "$log" >&2; return "$rc"
  fi
}
BUILD_DIR="$RUN_DIR/build"
DIST_DIR="$RUN_DIR/dist"
STAGING="$BUILD_DIR/dmg-root"
APP="$BUILD_DIR/SkyPC.app"
PLIST="$APP/Contents/Info.plist"
CANDIDATE="$BUILD_DIR/SkyPC-candidate.dmg"
FINAL_DMG_NAME="skypc_${VERSION}-${BUILD}_${PACKAGE_ARCH}.dmg"
FINAL_DMG="$DIST_DIR/$FINAL_DMG_NAME"
mkdir -p "$BUILD_DIR" "$DIST_DIR"
{
  printf 'utc=%s\nversion=%s\nbuild=%s\narchitecture=%s\nartifact=%s\nminimum macOS=%s\n' "$(date -u +%FT%TZ)" "$VERSION" "$BUILD" "$PACKAGE_ARCH" "$FINAL_DMG_NAME" "$MINIMUM_OS"
  printf 'input '; shasum -a 256 "$BINARY"
  printf 'icon '; shasum -a 256 "$ICON"
  printf 'background '; shasum -a 256 "$BACKGROUND"
  printf 'layout script '; shasum -a 256 "$LAYOUT_SCRIPT"
  printf 'Finder script '; shasum -a 256 "$FINDER_SCRIPT"
  printf 'plist '; shasum -a 256 "$PLIST_SOURCE"
  printf 'script '; shasum -a 256 "$SCRIPT_DIR/release_skypc.sh"
  if [ -n "$SOURCE_ARTIFACT" ]; then printf 'source artifact '; shasum -a 256 "$SOURCE_ARTIFACT"; fi
  if [ -n "$LAUNCH_AGENT_PLIST" ]; then printf 'launch agent '; shasum -a 256 "$LAUNCH_AGENT_PLIST"; fi
  printf 'entitlements '; shasum -a 256 "$ENTITLEMENTS"
  file "$BINARY"
  sw_vers
  printf 'installed Finder/Dock/Spotlight=unverified\n'
} > "$RUN_DIR/release-evidence.txt"

step 'prepare bundle and full-resolution icon'
mkdir "$BUILD_DIR/background"
# Package existing artwork at 2x density; do not alter the source asset.
# TIFF retains DPI reliably; JPEG EXIF/JFIF densities can disagree even after sips succeeds.
run background-convert.log sips -s format tiff "$BACKGROUND" --out "$BUILD_DIR/background/background.tiff"
BACKGROUND_WIDTH="$(sips -g pixelWidth "$BUILD_DIR/background/background.tiff" | awk '/pixelWidth:/ {print $2}')"
BACKGROUND_HEIGHT="$(sips -g pixelHeight "$BUILD_DIR/background/background.tiff" | awk '/pixelHeight:/ {print $2}')"
[[ "$BACKGROUND_WIDTH" =~ ^[0-9]+$ ]] && [[ "$BACKGROUND_HEIGHT" =~ ^[0-9]+$ ]] || die 'Cannot read background dimensions'
[ "$BACKGROUND_WIDTH" -ge 600 ] && [ "$BACKGROUND_HEIGHT" -gt 0 ] || die 'Background must be at least 600 pixels wide'
CANVAS_WIDTH=900
[ "$BACKGROUND_WIDTH" -ge 900 ] || CANVAS_WIDTH="$BACKGROUND_WIDTH"
CANVAS_HEIGHT=$((BACKGROUND_HEIGHT * CANVAS_WIDTH / BACKGROUND_WIDTH))
[ "$CANVAS_HEIGHT" -ge 300 ] && [ "$CANVAS_HEIGHT" -le 700 ] || die 'Background aspect ratio must fit a 300–700 point high installer window'
BACKGROUND_DPI="$(awk -v width="$BACKGROUND_WIDTH" -v canvas="$CANVAS_WIDTH" 'BEGIN {printf "%.6f", 72 * width / canvas}')"
run background-density.log sips -s dpiWidth "$BACKGROUND_DPI" -s dpiHeight "$BACKGROUND_DPI" "$BUILD_DIR/background/background.tiff"
run background-readback.log sips -g pixelWidth -g pixelHeight -g dpiWidth -g dpiHeight "$BUILD_DIR/background/background.tiff"
awk -v width="$CANVAS_WIDTH" -v height="$CANVAS_HEIGHT" '
  /pixelWidth:/ {pw=$2} /pixelHeight:/ {ph=$2}
  /dpiWidth:/ {dx=$2} /dpiHeight:/ {dy=$2}
  END {
    if (pw<=0 || ph<=0 || dx<=0 || dy<=0) exit 1
    dw=pw*72/dx-width; dh=ph*72/dy-height
    if (dw < -0.05 || dw > 0.05 || dh < -0.05 || dh > 0.05) exit 1
  }' "$RUN_DIR/background-readback.log" || die 'Background logical size does not match Finder canvas'
printf 'dmg canvas=%sx%s points\n' "$CANVAS_WIDTH" "$CANVAS_HEIGHT" >> "$RUN_DIR/release-evidence.txt"
run icon-check.log iconutil -c iconset "$ICON" -o "$RUN_DIR/validated.iconset"
for size in 16 32 128 256 512; do
  for suffix in '' '@2x'; do
    [ -s "$RUN_DIR/validated.iconset/icon_${size}x${size}${suffix}.png" ] || die "Icon is missing ${size}x${size}${suffix}"
  done
done
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -X "$BINARY" "$APP/Contents/MacOS/skypc"
chmod 755 "$APP" "$APP/Contents" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/MacOS/skypc"
if [ "$BUNDLE_SWIFT" -eq 1 ]; then
  mkdir -p "$APP/Contents/Frameworks"
  run swift-runtime-copy.log xcrun swift-stdlib-tool --copy \
    --scan-executable "$APP/Contents/MacOS/skypc" \
    --destination "$APP/Contents/Frameworks" --platform macosx --strip-bitcode
  find "$APP/Contents/Frameworks" -type f -name 'libswift*.dylib' -print -quit | grep -q . ||
    die 'swift-stdlib-tool did not copy the required Swift runtime'
  chmod 755 "$APP/Contents/Frameworks" "$APP/Contents/Frameworks"/*.dylib
  {
    printf 'Swift runtime files:\n'
    find "$APP/Contents/Frameworks" -type f -name 'libswift*.dylib' -exec shasum -a 256 {} \;
  } >> "$RUN_DIR/release-evidence.txt"
fi
cp -X "$ICON" "$APP/Contents/Resources/SkyPC.icns"
cp -X "$PLIST_SOURCE" "$PLIST"
if [ -n "$LAUNCH_AGENT_PLIST" ]; then
  mkdir -p "$APP/Contents/Library/LaunchAgents"
  cp -X "$LAUNCH_AGENT_PLIST" "$APP/Contents/Library/LaunchAgents/com.sub2s.skypc.login-agent.plist"
  chmod 755 "$APP/Contents/Library" "$APP/Contents/Library/LaunchAgents"
  chmod 644 "$APP/Contents/Library/LaunchAgents/com.sub2s.skypc.login-agent.plist"
  cmp -s "$LAUNCH_AGENT_PLIST" "$APP/Contents/Library/LaunchAgents/com.sub2s.skypc.login-agent.plist" || die 'Embedded LaunchAgent plist differs from input'
  printf 'login item=SMAppService bundled LaunchAgent\n' >> "$RUN_DIR/release-evidence.txt"
fi
for key in CFBundleName CFBundleDisplayName; do plutil -replace "$key" -string SkyPC "$PLIST"; done
plutil -replace CFBundleExecutable -string skypc "$PLIST"
plutil -replace CFBundlePackageType -string APPL "$PLIST"
plutil -replace CFBundleIconFile -string SkyPC.icns "$PLIST"
# An asset-catalog name would take precedence over the supplied ICNS.
for key in CFBundleIconName CFBundleIcons LSUIElement LSBackgroundOnly; do
  if plutil -type "$key" "$PLIST" >/dev/null 2>&1; then plutil -remove "$key" "$PLIST"; fi
done
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$BUILD" "$PLIST"
plutil -replace LSMinimumSystemVersion -string "$MINIMUM_OS" "$PLIST"
plutil -replace NSHighResolutionCapable -bool YES "$PLIST"
validate_oidc_url_metadata "$PLIST"
for key in NSCameraUsageDescription NSMicrophoneUsageDescription NSLocalNetworkUsageDescription LSMinimumSystemVersion; do
  [ -n "$(plist_get "$key" "$PLIST")" ] || die "Missing template key: $key"
done
chmod 644 "$PLIST" "$APP/Contents/Resources/SkyPC.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"; chmod 644 "$APP/Contents/PkgInfo"
run plist-check.log plutil -lint "$PLIST"
cmp -s "$BINARY" "$APP/Contents/MacOS/skypc" || die 'Binary copy differs from input'
step 'clean and verify extended attributes before signing'
# -cr removes quarantine too, including the normal case where it is absent.
# Do not log attribute values: downloaded-file metadata may contain private URLs.
run clean-xattrs.log xattr -cr "$APP"
remaining_xattrs="$(xattr -r "$APP")"
if [ -n "$remaining_xattrs" ]; then
  # macOS may retain/recreate provenance even when xattr -cr returns success.
  # Quarantine, FinderInfo, resource forks, macl and all other leftovers stop signing.
  while IFS= read -r attribute; do
    [ "${attribute##*: }" = com.apple.provenance ] || die 'Bundle still has unexpected extended attributes; signing stopped'
  done <<< "$remaining_xattrs"
  printf 'pre-sign extended attributes=system provenance only (retained by macOS)\n' >> "$RUN_DIR/release-evidence.txt"
else
  printf 'pre-sign extended attributes=empty\n' >> "$RUN_DIR/release-evidence.txt"
fi
unset remaining_xattrs
if [ "$PREPARE_ONLY" -eq 1 ]; then
  printf 'preparation=passed\nsigning/notarization/runtime=unverified\n' >> "$RUN_DIR/release-evidence.txt"
  printf '\nPrepared unsigned bundle: %s\nNo release DMG was produced.\n' "$APP"
  exit 0
fi

step 'sign app with Hardened Runtime'
SIGN_ARGS=(--force --options runtime --timestamp --sign "$SIGNING_IDENTITY")
SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
if [ "$BUNDLE_SWIFT" -eq 1 ]; then
  : > "$RUN_DIR/sign-frameworks.log"
  while IFS= read -r framework; do
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$framework" \
      >> "$RUN_DIR/sign-frameworks.log" 2>&1
  done < <(find "$APP/Contents/Frameworks" -type f -name '*.dylib' -print)
fi
run sign-app.log codesign "${SIGN_ARGS[@]}" "$APP"
run verify-app.log codesign --verify --deep --strict --verbose=4 "$APP"
run signature-app.log codesign -dvvv "$APP"
grep -F "TeamIdentifier=$APPLE_TEAM_ID" "$RUN_DIR/signature-app.log" >/dev/null || die 'Signed app team does not match APPLE_TEAM_ID'
grep -F '(runtime)' "$RUN_DIR/signature-app.log" >/dev/null || die 'Hardened Runtime flag missing'
if ! codesign -d --entitlements :- "$APP" > "$RUN_DIR/signed-entitlements.plist" 2> "$RUN_DIR/signed-entitlements.log"; then
  die 'Cannot read signed app entitlements'
fi
run signed-entitlements-check.log plutil -lint "$RUN_DIR/signed-entitlements.plist"
for required_entitlement in com.apple.security.device.camera com.apple.security.device.audio-input; do
  [ "$(entitlement_get "$required_entitlement" "$RUN_DIR/signed-entitlements.plist")" = true ] ||
    die "Signed app is missing required entitlement: $required_entitlement"
done
if [ "$SKIP_SMOKE" -eq 0 ]; then
  step 'manual runtime smoke test'
  open -n "$APP"
  printf 'Test Google SSO browser callback (skypc://); Local Network/direct streaming; Accessibility keyboard/mouse grab; wired/Bluetooth gamepad input/output; USB list and real redirect; camera and microphone selection plus actual capture. Quit SkyPC when done.\n'
  printf 'If Camera is already denied for com.sub2s.skypc, enable SkyPC in System Settings > Privacy & Security > Camera before testing; do not PASS an Off-only list.\n'
  read -r -p 'Type PASS to continue, anything else to stop: ' answer
  [ "$answer" = PASS ] || die 'Runtime smoke test was not confirmed'
  printf 'runtime=operator-confirmed PASS\n' >> "$RUN_DIR/release-evidence.txt"
else
  printf 'runtime=unverified (--skip-smoke-test)\n' >> "$RUN_DIR/release-evidence.txt"
fi

step 'stage the signed app after runtime test'
mkdir "$STAGING"
run stage-app.log ditto "$APP" "$STAGING/SkyPC.app"
run verify-staged-app.log codesign --verify --deep --strict --verbose=4 "$STAGING/SkyPC.app"
diff -qr "$APP" "$STAGING/SkyPC.app" > "$RUN_DIR/staging-compare.log" || die 'Staged app differs from signed bundle'
ln -s /Applications "$STAGING/Applications"
cat > "$DIST_DIR/INSTALL.txt" <<'EOF'
Drag SkyPC.app to Applications, then eject this disk image.
Open SkyPC from Applications or search for SkyPC using Spotlight (Cmd+Space).
Allow camera/microphone access when using the corresponding feature.
Spotlight results depend on indexing being enabled for Applications.
EOF
chmod 755 "$STAGING"; chmod 644 "$DIST_DIR/INSTALL.txt"
mkdir "$STAGING/.background"
cp -X "$BUILD_DIR/background/background.tiff" "$STAGING/.background/background.tiff"
chmod 755 "$STAGING/.background"; chmod 644 "$STAGING/.background/background.tiff"

attach_image() {
  local rc=0
  ATTACH_PLIST="$RUN_DIR/${1%.log}.plist"
  hdiutil attach "$2" "$3" -nobrowse -noautoopen -plist > "$ATTACH_PLIST" 2> "$RUN_DIR/$1" || rc=$?
  read_attachment || die "Cannot parse own attach result: $ATTACH_PLIST; inspect it before retrying"
  [ "$rc" -eq 0 ] || die "Attach failed; see $RUN_DIR/$1"
  [ -n "$DEVICE" ] && [ "$MOUNT_COUNT" -eq 1 ] && [ -d "$MOUNT" ] || die 'Expected one mounted volume and a device in attach result'
}
detach_image() { run "$1" hdiutil detach "$DEVICE"; MOUNT=''; DEVICE=''; ATTACH_PLIST=''; }
check_volume() {
  cmp -s "$ICON" "$MOUNT/.VolumeIcon.icns" || die 'DMG volume icon mismatch'
  cmp -s "$ICON" "$MOUNT/SkyPC.app/Contents/Resources/SkyPC.icns" || die 'DMG app icon mismatch'
  [ "$(xcrun GetFileInfo -aC "$MOUNT")" = 1 ] || die 'Volume custom-icon flag missing'
  [ "$(xcrun GetFileInfo -aV "$MOUNT/.VolumeIcon.icns")" = 1 ] || die 'Volume icon is not hidden'
  [ "$(readlink "$MOUNT/Applications")" = /Applications ] || die 'Applications shortcut missing'
  cmp -s "$PLIST" "$MOUNT/SkyPC.app/Contents/Info.plist" || die 'DMG app metadata differs'
  if [ -n "$LAUNCH_AGENT_PLIST" ]; then
    cmp -s "$LAUNCH_AGENT_PLIST" "$MOUNT/SkyPC.app/Contents/Library/LaunchAgents/com.sub2s.skypc.login-agent.plist" || die 'DMG LaunchAgent plist mismatch'
  fi
  cmp -s "$BUILD_DIR/background/background.tiff" "$MOUNT/.background/background.tiff" || die 'DMG background image differs'
}
step 'create writable DMG'
run create-image.log hdiutil create -volname SkyPC -fs HFS+ -srcfolder "$STAGING" -format UDRW "$BUILD_DIR/SkyPC-rw.dmg"
attach_image attach-writable.log "$BUILD_DIR/SkyPC-rw.dmg" -readwrite
step 'save Finder background and drag-to-Applications layout'
run finder-layout.log osascript "$FINDER_SCRIPT" "$MOUNT" "$CANVAS_WIDTH" "$CANVAS_HEIGHT"
run verify-finder-layout-writable.log "$LAYOUT_PYTHON" "$LAYOUT_SCRIPT" verify "$MOUNT" "$CANVAS_WIDTH" "$CANVAS_HEIGHT"
cp -X "$MOUNT/.DS_Store" "$BUILD_DIR/finder.DS_Store"
step 'apply volume logo after Finder finalized the layout'
cp -X "$ICON" "$MOUNT/.VolumeIcon.icns"; chmod 644 "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a V "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a C "$MOUNT"
check_volume
sync
detach_image detach-writable.log
run convert-image.log hdiutil convert "$BUILD_DIR/SkyPC-rw.dmg" -format UDZO -o "$CANDIDATE"
run verify-image.log hdiutil verify "$CANDIDATE"

step 'sign release candidate DMG'
run sign-dmg.log codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$CANDIDATE"
run verify-dmg.log codesign --verify --verbose=4 "$CANDIDATE"
step 'submit to Apple and wait for Accepted'
submit_rc=0
# Do not echo this command: AUTH may contain the app-specific password.
xcrun notarytool submit "$CANDIDATE" "${AUTH[@]}" --wait --output-format plist > "$RUN_DIR/notary-result.plist" 2> "$RUN_DIR/notary-submit.log" || submit_rc=$?
notary_status="$(plist_get status "$RUN_DIR/notary-result.plist" 2>/dev/null || true)"
submission_id="$(plist_get id "$RUN_DIR/notary-result.plist" 2>/dev/null || true)"
printf 'notary_status=%s\nsubmission_id=%s\n' "$notary_status" "$submission_id" >> "$RUN_DIR/release-evidence.txt"
if [ "$submit_rc" -ne 0 ] || [ "$notary_status" != Accepted ]; then
  if [ -n "$submission_id" ]; then
    xcrun notarytool log "$submission_id" "${AUTH[@]}" "$RUN_DIR/notary-log.json" > "$RUN_DIR/notary-log-fetch.log" 2>&1 || true
  fi
  unset AUTH
  die 'Notarization did not complete with Accepted. Read retained notary result/log; do not distribute candidate'
fi
unset AUTH
step 'staple and assess final image and contained app'
run staple.log xcrun stapler staple "$CANDIDATE"
run validate-ticket.log xcrun stapler validate "$CANDIDATE"
run verify-final-image.log hdiutil verify "$CANDIDATE"
run verify-final-dmg.log codesign --verify --verbose=4 "$CANDIDATE"
run gatekeeper-dmg.log spctl --assess --type open --context context:primary-signature --verbose=4 "$CANDIDATE"
attach_image attach-final.log "$CANDIDATE" -readonly
check_volume
[ -s "$MOUNT/.DS_Store" ] || die 'Final DMG is missing its Finder layout'
run verify-finder-layout.log "$LAYOUT_PYTHON" "$LAYOUT_SCRIPT" verify "$MOUNT" "$CANVAS_WIDTH" "$CANVAS_HEIGHT"
cmp -s "$APP/Contents/MacOS/skypc" "$MOUNT/SkyPC.app/Contents/MacOS/skypc" || die 'DMG executable differs from signed app'
run verify-contained-app.log codesign --verify --deep --strict --verbose=4 "$MOUNT/SkyPC.app"
run gatekeeper-app.log spctl --assess --type execute --verbose=4 "$MOUNT/SkyPC.app"
detach_image detach-final.log
step 'final checksum and handoff'
(cd "$BUILD_DIR" && shasum -a 256 SkyPC-candidate.dmg > candidate.sha256 && shasum -a 256 -c candidate.sha256)
sed "s/ SkyPC-candidate\\.dmg$/ $FINAL_DMG_NAME/" "$BUILD_DIR/candidate.sha256" > "$FINAL_DMG.sha256"
mv "$CANDIDATE" "$FINAL_DMG"
printf 'automatic release gates=passed\n' >> "$RUN_DIR/release-evidence.txt"
printf '\nDMG: %s\nSHA-256: %s.sha256\nEvidence: %s/release-evidence.txt\n' "$FINAL_DMG" "$FINAL_DMG" "$RUN_DIR"
printf 'Installed Finder/Dock/Spotlight checks remain manual; see the guide.\n'
