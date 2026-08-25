#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
PROCESS_NAME="AtticNotesLocal"
DISPLAY_NAME="Attic Notes Local"
BUNDLE_ID="com.qasimwaseem363.AtticNotesLocal"
SIGNING_IDENTITY="12F1981F20A99BA8CC316439D7A04ACE14643BC0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/AtticNotesLocal"
BUILT_APP="$DERIVED_DATA/Build/Products/Local/$PROCESS_NAME.app"
INSTALL_APP="/Applications/$DISPLAY_NAME.app"
APP_BINARY="$INSTALL_APP/Contents/MacOS/$PROCESS_NAME"

pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true

xcrun xcodebuild \
  -project "$ROOT_DIR/Attic.xcodeproj" \
  -scheme Attic \
  -configuration Local \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$DERIVED_DATA" \
  "PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID" \
  "PRODUCT_NAME=$PROCESS_NAME" \
  "ATTIC_DISPLAY_NAME=$DISPLAY_NAME" \
  "CODE_SIGNING_ALLOWED=NO" \
  "OTHER_SWIFT_FLAGS=-DATTIC_LOCAL_ONLY" \
  "ONLY_ACTIVE_ARCH=YES" \
  "ENABLE_DEBUG_DYLIB=NO" \
  build

test -d "$BUILT_APP"
security find-identity -v -p codesigning | grep -F "$SIGNING_IDENTITY" >/dev/null
RUN_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/attic-notes-local.XXXXXX")"
trap 'rm -rf "$RUN_TEMP_DIR"' EXIT
STAGED_APP="$RUN_TEMP_DIR/$PROCESS_NAME.app"
/usr/bin/ditto --norsrc "$BUILT_APP" "$STAGED_APP"
xattr -cr "$STAGED_APP"
codesign \
  --force \
  --options runtime \
  --timestamp=none \
  --entitlements "$ROOT_DIR/Attic/AtticNotesLocal.entitlements" \
  --sign "$SIGNING_IDENTITY" \
  "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
/usr/bin/ditto --norsrc "$STAGED_APP" "$INSTALL_APP"

open_app() {
  /usr/bin/open -n "$INSTALL_APP"
}

verify_process() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if pgrep -f "$APP_BINARY" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "$DISPLAY_NAME did not remain running after launch." >&2
  return 1
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --verify|verify)
    open_app
    verify_process
    codesign -dvv --entitlements :- "$INSTALL_APP"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
