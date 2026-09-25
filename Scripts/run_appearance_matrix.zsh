#!/bin/zsh

set -euo pipefail

readonly script_dir=${0:A:h}
readonly repository_root=${script_dir:h}

usage() {
    /bin/cat <<'USAGE'
Usage: Scripts/run_appearance_matrix.zsh [options] [-- extra xcodebuild settings]

Runs the design system's full appearance matrix (every family in every
combination of mode, surface, palette, Tint, Increase Contrast and Reduce
Transparency, rendered at 2x and checked by code, with glyph contrast read
from pixels and corner radii fitted from pixels) and writes the 15 contact
sheets plus appearance-check.txt. The ordinary unit-test run keeps only the
fast model checks and a representative render subset; this is the separate,
slow gate (a few minutes).

Options:
  --output DIR           Where to copy the sheets and report
                         (default: .build/appearance).
  --derived-data PATH    Build root (default: .build/dd).
  --skip-build           Reuse an existing build-for-testing.
  --help                 Show this help.

Environment:
  XCODEBUILD             The xcodebuild to run (default: xcodebuild), for
                         example a wrapper that serialises builds.

Anything after `--` is passed to xcodebuild, typically signing settings:

  Scripts/run_appearance_matrix.zsh -- CODE_SIGNING_ALLOWED=YES \
      CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- \
      DEVELOPMENT_TEAM=
USAGE
}

output=$repository_root/.build/appearance
derived_data=$repository_root/.build/dd
skip_build=false
extra=()
while (( $# > 0 )); do
    case $1 in
        --output) output=${2:A}; shift 2 ;;
        --derived-data) derived_data=${2:A}; shift 2 ;;
        --skip-build) skip_build=true; shift ;;
        --help) usage; exit 0 ;;
        --) shift; extra=("$@"); break ;;
        *) print -u2 "Unknown option: $1"; usage >&2; exit 64 ;;
    esac
done

xcodebuild_command=${XCODEBUILD:-xcodebuild}
common=(
    -project "$repository_root/Attic.xcodeproj"
    -scheme Attic
    -configuration Local
    -destination platform=macOS
    -derivedDataPath "$derived_data"
)

if [[ $skip_build == false ]]; then
    "$xcodebuild_command" build-for-testing "${common[@]}" "${extra[@]}"
fi

log=$(mktemp -t attic-appearance)
trap 'rm -f "$log"' EXIT
# TEST_RUNNER_ variables reach the test host without the prefix.
set +e
TEST_RUNNER_ATTIC_APPEARANCE_FULL=1 "$xcodebuild_command" test-without-building "${common[@]}" \
    -only-testing:AtticTests/AtticAppearanceMatrixTests "${extra[@]}" 2>&1 | tee "$log"
result=${pipestatus[1]}
set -e

# The test host is sandboxed: it writes into its own container and prints
# where. Copy the sheets and the report out, whether or not the check passed.
source_dir=$(/usr/bin/sed -n 's/^ATTIC_APPEARANCE_OUTPUT=//p' "$log" | /usr/bin/tail -n 1)
if [[ -n $source_dir && -d $source_dir ]]; then
    /bin/mkdir -p "$output"
    /bin/cp "$source_dir"/*.png "$source_dir"/appearance-check.txt "$output"/
    print "Appearance matrix output: $output"
else
    print -u2 "The appearance matrix wrote no output (see the log above)."
    (( result == 0 )) && result=1
fi
exit $result
