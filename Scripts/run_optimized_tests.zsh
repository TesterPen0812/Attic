#!/bin/zsh
# Runs unit tests in an optimized (-O, whole-module) hosted build, to measure
# what the app costs as a release would run it (round 11). Usage:
#
#   Scripts/run_optimized_tests.zsh AtticTests/TasksFrameCostTests [more identifiers]
#
# The optimized test host is signed with the hardened runtime, which enforces
# library validation: an ad-hoc signed test bundle then fails to load ("mapping
# process and mapped file (non-platform) have different Team IDs", round 10).
# A Debug host is not hardened, so only this build turns it off, for the test
# host alone; the app and the previews keep it. Local-only, ad-hoc signed,
# derived data in `.build/dd-opt`, every xcodebuild through the machine lock.
set -euo pipefail
readonly root=${0:A:h:h}
readonly lock=/Users/taha/Developer/attic-redesign-assets/xcodebuild-locked.sh
cd "$root"
(( $# > 0 )) || { print -u2 "usage: $0 <test identifier>..."; exit 2 }

typeset -a flags=(
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
    SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule ENABLE_DEBUG_DYLIB=NO GCC_OPTIMIZATION_LEVEL=s
    ENABLE_TESTABILITY=YES ENABLE_HARDENED_RUNTIME=NO
)
typeset -a common=(-project Attic.xcodeproj -scheme Attic -configuration Local -destination 'platform=macOS'
                   -derivedDataPath .build/dd-opt)
typeset -a only=()
for identifier in "$@"; do only+=(-only-testing:$identifier); done

xcodebuild_command=$lock
[[ -x $xcodebuild_command ]] || xcodebuild_command=xcodebuild
$xcodebuild_command build-for-testing "${common[@]}" "${flags[@]}"
$xcodebuild_command test-without-building "${common[@]}" "${flags[@]}" "${only[@]}"
