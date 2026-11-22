#!/usr/bin/env bash
set -euo pipefail

# Keep the desktop Run action on the same isolated preview path as the CLI.
# Never kill or overwrite another branch's preview.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKTREE_TOKEN="$(printf '%s' "$ROOT_DIR" | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-12)"
PROCESS_NAME="AtticLocal${WORKTREE_TOKEN}"
DERIVED_DATA="$ROOT_DIR/.build/LocalPreview"
MODE=run
case "${1:-run}" in
  run|debug|--debug|logs|--logs|telemetry|--telemetry|verify|--verify)
    MODE="${1:-run}"
    MODE="${MODE#--}"
    if (( $# > 0 )); then shift; fi
    ;;
esac
# --release-like (passed through to the launcher) builds Release.
CONFIGURATION=Local
for argument in "$@"; do
  if [[ "$argument" == --release-like ]]; then CONFIGURATION=Release; fi
done
APP_PRODUCT="$DERIVED_DATA/Build/Products/$CONFIGURATION/$PROCESS_NAME.app"
APP_BINARY="$APP_PRODUCT/Contents/MacOS/$PROCESS_NAME"

PREVIEW_ARGS=(
  --display-name "Attic Local ${WORKTREE_TOKEN}"
  --bundle-id "com.taha.Attic.local.${WORKTREE_TOKEN}"
  --executable-name "$PROCESS_NAME"
  --derived-data "$DERIVED_DATA"
)
if [[ "$MODE" == debug ]]; then
  PREVIEW_ARGS+=(--build-only)
fi
"$ROOT_DIR/Scripts/launch_local_preview.zsh" "${PREVIEW_ARGS[@]}" "$@"

# Dry runs and build-only invocations must not start a process or log stream.
for argument in "$@"; do
  case "$argument" in --dry-run|--build-only|--help|-h) exit 0 ;; esac
done

case "$MODE" in
  debug) exec /usr/bin/xcrun lldb -- "$APP_BINARY" ;;
  logs|telemetry)
    exec /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  verify)
    /usr/bin/codesign --verify --deep --strict "$APP_PRODUCT"
    PREVIEW_PID="$(<"$DERIVED_DATA/PreviewState/process.pid")"
    [[ "$(/bin/ps -p "$PREVIEW_PID" -o command=)" == "$APP_BINARY"* ]]
    ;;
esac
