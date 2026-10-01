#!/bin/zsh
set -euo pipefail
# Xcode's build-for-testing expands entitlements on every dependency, including
# tools that do not host XCTest. Restore the helper's pinned inheritance-only
# contract, then reseal the host preserving its existing test-host entitlements.
# Never disable the sandbox, runtime, or library validation.
HOST=$1
IDENTITY=${2:--}
ROOT=${0:A:h:h}
/usr/bin/codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
  --entitlements "$ROOT/AtticOperationCrashHelper/Helper.entitlements" \
  "$HOST/Contents/MacOS/AtticOperationCrashHelper"
/usr/bin/codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
  --preserve-metadata=identifier,entitlements "$HOST"
python3 "$ROOT/Scripts/verify_crash_harness_signature.py" "$HOST"
