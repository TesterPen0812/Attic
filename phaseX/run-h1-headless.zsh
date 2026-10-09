#!/bin/zsh
# Normal: 3,000 × 24 operations; --long: 20,000 × 120; --area: full engine and backend suites too.
# All hosts are local-only and isolated; no window or general-pasteboard tests.
set -euo pipefail
readonly root=${0:A:h:h}
readonly lock=/Users/taha/Developer/attic-redesign-assets/xcodebuild-locked.sh
cd "$root"
typeset mode=${1:-normal}
typeset -a only=(
  -only-testing:AtticTests/PhaseXHunt1ReproTests
  -only-testing:AtticTests/PhaseXHunt1bTests
  -only-testing:AtticTests/PhaseXHunt1GeneratedTests
  -only-testing:AtticTests/PhaseXHunt1TaskInvariantTests
)
case "$mode" in
  normal) ;;
  --long)
    export TEST_RUNNER_ATTIC_PHASEX_LONG=1
    only=(-only-testing:AtticTests/PhaseXHunt1GeneratedTests/testSeededEditorSequencesAgreeAfterEveryOperation)
    ;;
  --area)
    for suite in NoteEditorEngineTests NoteDocumentStoreTests NoteFormatTests NotesMigrationAcceptanceTests NoteStoreTests TaskStoreTests DailyCleanupServiceTests SubtaskTests; do
      only+=(-only-testing:AtticTests/$suite)
    done
    ;;
  *) print -u2 'usage: phaseX/run-h1-headless.zsh [--long|--area]'; exit 2 ;;
esac
mkdir -p .build/hunt1
"$lock" test -project Attic.xcodeproj -scheme Attic -configuration Local \
  -destination 'platform=macOS' -derivedDataPath .build/dd-hunt1 "${only[@]}" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  ATTIC_MACOS_UNIT_HOST_BUNDLE_IDENTIFIER=com.taha.Attic.preview.hunt1host
