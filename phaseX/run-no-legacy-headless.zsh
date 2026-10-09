#!/bin/zsh
# Whole unit suite while the owner is using the display. CI runs excluded cases.
set -euo pipefail
readonly root=${0:A:h:h}
readonly lock=/Users/taha/Developer/attic-redesign-assets/xcodebuild-locked.sh
cd "$root"
unset TEST_RUNNER_ATTIC_KEY_WINDOW_TESTS ATTIC_KEY_WINDOW_TESTS TEST_RUNNER_ATTIC_FKA_TESTS ATTIC_APPEARANCE_FULL
# No project assertions are disabled: only tests that present windows are excluded.
typeset -a exclusions=()
while IFS= read -r test; do
  [[ -z "$test" || "$test" == \#* ]] && continue
  exclusions+=(-skip-testing:AtticTests/$test)
done < phaseX/no-legacy-screen-exclusions.txt
"$lock" test -project Attic.xcodeproj -scheme Attic -configuration Local \
  -destination 'platform=macOS' -derivedDataPath .build/dd-o01 \
  -parallel-testing-enabled NO -only-testing:AtticTests "${exclusions[@]}" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  ATTIC_MACOS_UNIT_HOST_BUNDLE_IDENTIFIER=com.taha.Attic.preview.phase-x-o01-unit
