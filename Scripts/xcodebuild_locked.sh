#!/bin/sh
# Same machine-wide lock as the local redesign-assets wrapper; CI also serializes hosts.
exec /usr/bin/lockf -k /tmp/attic-xcodebuild.lock /usr/bin/xcodebuild "$@"
