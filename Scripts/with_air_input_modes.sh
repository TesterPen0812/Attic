#!/bin/bash
# Full Keyboard Access for one test run on the owner's Air, the one machine
# allowed it outside CI (RULES.md §4 and §6). The Air is not disposable, and
# the wrapper owns the run it starts:
# - it takes the machine-wide build lock itself, before anything else, and
#   holds it until the run's whole process group has ended. As under lockf(1),
#   the run does not inherit the lock, so nothing the run leaves behind can
#   pin it. Never start the wrapper under lockf on the same file: it would
#   wait for itself. xcodebuild_locked.sh calls it directly.
# - a state file a killed run left behind is restored under that lock, so
#   never beneath a run that is still alive, and a run whose leftover cannot
#   be restored runs nothing;
# - the previous value is written to the state file before anything changes;
# - the command runs as its own process group; on HUP, INT or TERM the signal
#   goes to the whole group, the wrapper waits (bounded, then KILL) for the
#   group to end, and only then restores and exits. A group that outlives a
#   normal finish is ended the same way.
# - `restore` puts a leftover back and runs nothing; it refuses while the
#   build lock is held, since a run that is still alive owns that leftover.
# Only the global AppleKeyboardUIMode is ever read or written. Hosted CI uses
# with_ci_input_modes.sh, which this file never touches.
set -euo pipefail
if [[ ${ATTIC_AIR_INPUT_MODES:-} != 1 || $(scutil --get LocalHostName 2>/dev/null || true) != Tahas-MacBook-Air ]]; then
  echo 'error: keyboard-mode changes outside CI are allowed only for an ATTIC_AIR_INPUT_MODES=1 run on the Air.' >&2
  exit 2
fi
state=${ATTIC_AIR_INPUT_MODES_STATE:-$HOME/Library/Application Support/AtticTestRuns/keyboard-mode.state}
lock=${ATTIC_AIR_INPUT_MODES_LOCK:-/tmp/attic-xcodebuild.lock}
grace=${ATTIC_AIR_INPUT_MODES_GRACE:-60}

case ${1:-} in
  restore) wanted= ;;
  normal) wanted=0 ;;
  fka) wanted=3 ;;
  *) echo 'Expected input mode normal, fka or restore.' >&2; exit 2 ;;
esac
shift
[[ -z $wanted || $# -gt 0 ]] || { echo 'Expected a command to run.' >&2; exit 2; }

# The same flock lockf(1) takes, on fd 9 of this shell, so it lasts until the
# wrapper exits. `try` returns 75 at once if another holder has it.
take_lock() {
  exec 9>>"$lock"
  /usr/bin/python3 -c '
import fcntl, sys
try: fcntl.flock(9, fcntl.LOCK_EX | (fcntl.LOCK_NB if sys.argv[1] == "try" else 0))
except BlockingIOError: sys.exit(75)' "$1"
}

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

if [[ -z $wanted ]]; then
  [[ -f $state ]] || { echo 'AIR_INPUT_MODES nothing to restore'; exit 0; }
  if take_lock try; then :; else
    echo "AIR_INPUT_MODES refusing to restore: the build lock is held, so the run that owns $state may still be alive" >&2
    exit 75
  fi
  restore_state || exit 1
  exit 0
fi

if ! take_lock try; then
  echo "AIR_INPUT_MODES waiting for the build lock $lock"
  take_lock wait
fi
if [[ -f $state ]]; then
  echo 'AIR_INPUT_MODES found a leftover from a run that did not finish'
  restore_state || exit 1
fi

if old=$(defaults read -g AppleKeyboardUIMode 2>/dev/null); then :; else old=absent; fi
mkdir -p "$(dirname "$state")"
printf '%s\n' "$old" > "$state.new"
mv -f "$state.new" "$state"

# Sends `signal` to the run's group if any of it is left, then waits for the
# group to end: `grace` seconds, then KILL and a few seconds more.
end_group() {
  local signal=$1 deadline
  kill -0 -- "-$child" 2>/dev/null || return 0
  echo "AIR_INPUT_MODES sending $signal to the run's process group $child"
  kill -s "$signal" -- "-$child" 2>/dev/null || true
  deadline=$((SECONDS + grace))
  while kill -0 -- "-$child" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      echo "AIR_INPUT_MODES the group did not end within ${grace}s; sending KILL"
      kill -KILL -- "-$child" 2>/dev/null || true
      deadline=$((SECONDS + 5))
      while kill -0 -- "-$child" 2>/dev/null && (( SECONDS < deadline )); do sleep 0.2; done
      kill -0 -- "-$child" 2>/dev/null && echo "AIR_INPUT_MODES process group $child survived KILL" >&2
      return 0
    fi
    sleep 0.2
  done
}

child=
signal=
finish() {
  local status=$?
  trap '' HUP INT TERM
  trap - EXIT
  [[ -n $child ]] || child=$(jobs -p 2>/dev/null | head -n 1)
  if [[ -n $child ]]; then end_group "${signal:-TERM}"; fi
  restore_state || status=1
  exit "$status"
}
trap finish EXIT
trap 'signal=HUP; exit 129' HUP
trap 'signal=INT; exit 130' INT
trap 'signal=TERM; exit 143' TERM

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
# Its own process group, in the background, so a signal reaches the trap at
# once and can be sent on to everything the run started.
set -m
"$@" </dev/null 9>&- &
child=$!
set +m
status=0
wait "$child" || status=$?
exit "$status"
