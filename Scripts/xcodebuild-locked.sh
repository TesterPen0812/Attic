#!/bin/zsh
# Runs xcodebuild while holding a machine-wide lock, so parallel Phase 0
# streams never run two xcodebuild commands (or two test hosts) at once.
exec /usr/bin/lockf -k /tmp/attic-xcodebuild.lock /usr/bin/xcodebuild "$@"
