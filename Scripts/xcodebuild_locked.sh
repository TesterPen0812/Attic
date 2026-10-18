#!/bin/sh
# Informational only: old/prebuilt hosts and UI runners may lack the unit-host
# boundary. Explicit visible runs remain the caller's choice.
if [ "${GITHUB_ACTIONS:-}" != true ]; then
  for argument in "$@"; do
    case "$argument" in
      test|test-without-building)
        if [ "${TEST_RUNNER_ATTIC_KEY_WINDOW_TESTS:-${ATTIC_KEY_WINDOW_TESTS:-}}" = 1 ] ||
           [ "${TEST_RUNNER_ATTIC_VISIBLE_TESTS:-${ATTIC_VISIBLE_TESTS:-}}" = 1 ]; then
          echo 'NOTE: Attic local tests explicitly allow visible windows and keyboard focus.' >&2
        else
          echo 'NOTE: Local tests require the invisible AtticUnitTestHost policy. Older/prebuilt hosts and UI-test runners may show UI or take the keyboard; this wrapper does not enforce invisibility.' >&2
        fi
        break
        ;;
    esac
  done
fi
# Same machine-wide lock as the local redesign-assets wrapper; CI also serializes hosts.
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  for argument in "$@"; do
    case "$argument" in
      test|test-without-building)
        script_dir=$(cd "$(dirname "$0")" && pwd)
        exec /usr/bin/lockf -k /tmp/attic-xcodebuild.lock \
          "$script_dir/with_ci_input_modes.sh" "${ATTIC_CI_KEYBOARD_MODE:-normal}" /usr/bin/xcodebuild "$@"
        ;;
    esac
  done
fi
exec /usr/bin/lockf -k /tmp/attic-xcodebuild.lock /usr/bin/xcodebuild "$@"
