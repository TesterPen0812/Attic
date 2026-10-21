#!/bin/bash
# Only disposable hosted CI runners may change the keyboard setting.
set -euo pipefail
if [[ ${GITHUB_ACTIONS:-} != true || ${RUNNER_ENVIRONMENT:-} != github-hosted ]]; then
  echo '::error::Input-mode changes require a GitHub-hosted CI runner.' >&2
  exit 2
fi
case ${1:-} in
  normal) wanted=0 ;;
  fka) wanted=3 ;;
  *) echo 'Expected input mode normal or fka.' >&2; exit 2 ;;
esac
shift
[[ $# -gt 0 ]]
record=${RUNNER_TEMP:?}/attic-input-modes.log
log() { printf '%s\n' "$*" | tee -a "$record"; }
old_exists=0
if old=$(defaults read -g AppleKeyboardUIMode 2>/dev/null); then old_exists=1; else old=absent; fi
restore() {
  status=$?
  trap - EXIT
  if [[ $old_exists == 1 ]]; then
    if ! defaults write -g AppleKeyboardUIMode -int "$old"; then status=1; fi
    actual=$(defaults read -g AppleKeyboardUIMode 2>/dev/null || true)
    if [[ $actual != "$old" ]]; then
      log "::error::Keyboard mode restore failed: wanted=$old actual=$actual"; status=1
    else log "CI_INPUT_MODES restored keyboard=$actual"; fi
  else
    if ! defaults delete -g AppleKeyboardUIMode; then status=1; fi
    if defaults read -g AppleKeyboardUIMode >/dev/null 2>&1; then
      log '::error::Keyboard mode restore failed: expected absent'; status=1
    else log 'CI_INPUT_MODES restored keyboard=absent'; fi
  fi
  exit "$status"
}
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
log "CI_INPUT_MODES before keyboard=$old requested=$wanted command=$1"
defaults write -g AppleKeyboardUIMode -int "$wanted"
actual=$(defaults read -g AppleKeyboardUIMode)
if [[ $actual != "$wanted" ]]; then
  log "::error::Keyboard mode verification failed: wanted=$wanted actual=$actual"
  exit 1
fi
log "CI_INPUT_MODES verified keyboard=$actual; host must verify AXEnhancedUserInterface=0"
export ATTIC_CI_INPUT_MODES_ACTIVE=1
export TEST_RUNNER_ATTIC_CI_INPUT_MODES=1
export TEST_RUNNER_ATTIC_CI_KEYBOARD_MODE="$wanted"
"$@"
