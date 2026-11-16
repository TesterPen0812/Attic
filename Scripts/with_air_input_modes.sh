#!/bin/bash
# Full Keyboard Access for one test run on the owner's Air, the one machine
# allowed it outside CI (RULES.md §4 and §6). The Air is not disposable, so:
# - a state file a killed run left behind is restored first, before anything
#   else, and a run whose leftover cannot be restored runs nothing;
# - the previous value is written to the state file before anything changes;
# - it is restored on exit and on INT, TERM and HUP, and the state file goes
#   only once the restore is verified.
# Only the global AppleKeyboardUIMode is ever read or written. Hosted CI uses
# with_ci_input_modes.sh. `restore` restores a leftover and runs nothing.
set -euo pipefail
if [[ ${ATTIC_AIR_INPUT_MODES:-} != 1 || $(scutil --get LocalHostName 2>/dev/null || true) != Tahas-MacBook-Air ]]; then
  echo 'error: keyboard-mode changes outside CI are allowed only for an ATTIC_AIR_INPUT_MODES=1 run on the Air.' >&2
  exit 2
fi
state=${ATTIC_AIR_INPUT_MODES_STATE:-$HOME/Library/Application Support/AtticTestRuns/keyboard-mode.state}

# Puts back `old` ("absent" or a number) and checks it took.
put_back() {
  local old=$1 actual
  if [[ $old == absent ]]; then
    defaults delete -g AppleKeyboardUIMode >/dev/null 2>&1 || true
    if defaults read -g AppleKeyboardUIMode >/dev/null 2>&1; then return 1; fi
  else
    defaults write -g AppleKeyboardUIMode -int "$old" || return 1
    actual=$(defaults read -g AppleKeyboardUIMode 2>/dev/null || true)
    [[ $actual == "$old" ]] || return 1
  fi
}

# Restores what the state file holds; it is removed only after a verified restore.
restore_state() {
  local old
  [[ -f $state ]] || return 0
  old=$(<"$state")
  [[ $old == absent || $old =~ ^-?[0-9]+$ ]] || { echo "AIR_INPUT_MODES unreadable state file: $state" >&2; return 1; }
  if put_back "$old"; then
    rm -f "$state"
    echo "AIR_INPUT_MODES restored keyboard=$old"
  else
    echo "AIR_INPUT_MODES restore failed: wanted keyboard=$old; state kept at $state" >&2
    return 1
  fi
}

if [[ -f $state ]]; then
  echo 'AIR_INPUT_MODES found a leftover from a run that did not finish'
  restore_state || exit 1
fi
case ${1:-} in
  restore) exit 0 ;;
  normal) wanted=0 ;;
  fka) wanted=3 ;;
  *) echo 'Expected input mode normal, fka or restore.' >&2; exit 2 ;;
esac
shift
[[ $# -gt 0 ]] || { echo 'Expected a command to run.' >&2; exit 2; }

if old=$(defaults read -g AppleKeyboardUIMode 2>/dev/null); then :; else old=absent; fi
mkdir -p "$(dirname "$state")"
printf '%s\n' "$old" > "$state.new"
mv -f "$state.new" "$state"

child=
finish() {
  local status=$?
  trap - EXIT INT TERM HUP
  if [[ -n $child ]]; then kill -TERM "$child" 2>/dev/null || true; fi
  restore_state || status=1
  exit "$status"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

echo "AIR_INPUT_MODES before keyboard=$old requested=$wanted command=$1"
defaults write -g AppleKeyboardUIMode -int "$wanted"
actual=$(defaults read -g AppleKeyboardUIMode 2>/dev/null || true)
if [[ $actual != "$wanted" ]]; then
  echo "AIR_INPUT_MODES verification failed: wanted=$wanted actual=$actual" >&2
  exit 1
fi
echo "AIR_INPUT_MODES verified keyboard=$actual"
export ATTIC_CI_INPUT_MODES_ACTIVE=1
export TEST_RUNNER_ATTIC_CI_INPUT_MODES=1
export TEST_RUNNER_ATTIC_CI_KEYBOARD_MODE="$wanted"
# In the background, so a signal reaches the trap at once, not after the run.
"$@" &
child=$!
status=0
wait "$child" || status=$?
child=
exit "$status"
