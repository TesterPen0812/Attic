#!/bin/sh
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
