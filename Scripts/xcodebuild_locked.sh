#!/bin/zsh
# Portable equivalent of the shared local build lock, including CI runners.
set -euo pipefail
exec /usr/bin/lockf -k /tmp/attic-xcodebuild.lock /usr/bin/xcodebuild "$@"
