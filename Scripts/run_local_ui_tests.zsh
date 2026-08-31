#!/bin/zsh

set -euo pipefail

readonly script_dir=${0:A:h}
readonly repository_root=${script_dir:h}
readonly ui_lock_path=/tmp/attic-exclusive-ui.lock

usage() {
    /bin/cat <<'USAGE'
Usage: Scripts/run_local_ui_tests.zsh [options]

Builds a signed, uniquely identified ATTIC_LOCAL_ONLY macOS app and XCTest
runner, validates both products, then runs the real UI suite while holding the
shared exclusive UI lock.

Options:
  --app-bundle-id IDENTIFIER      Unique com.taha.Attic.* app identity.
  --ui-test-bundle-id IDENTIFIER  Separate unique UI-test bundle identity.
  --unit-test-bundle-id ID        Separate unit-test bundle identity.
  --product-name NAME             Unique path-safe app product/executable name.
  --display-name NAME             Isolated app display name.
  --derived-data PATH             Build root; defaults under /tmp.
  --result-bundle PATH            New xcresult path; defaults under /tmp.
  --only-testing TEST             Repeatable XCTest selection; defaults to AtticUITests.
  --signing-identity IDENTITY     Codesigning identity; default is ad hoc (-).
  --development-team TEAM        Optional local signing-team override.
  --project PATH                  Xcode project; default Attic.xcodeproj.
  --scheme NAME                   Scheme; default AtticUI.
  --configuration NAME            Configuration; default Local.
  --build-only                    Build, sign, validate, and emit provenance without UI.
  --dry-run                       Print resolved identities and commands only.
  --help                          Show this help.
USAGE
}

fail() {
    print -u2 -- "run_local_ui_tests: $*"
    exit 1
}

readonly commit_sha=$(/usr/bin/git -C "$repository_root" rev-parse HEAD)
readonly short_sha=${commit_sha[1,12]}
readonly unique_token="${short_sha}.${$}"

app_bundle_id="com.taha.Attic.ui.${unique_token}"
ui_test_bundle_id="com.taha.Attic.ui-tests.${unique_token}"
unit_test_bundle_id="com.taha.Attic.unit-tests.${unique_token}"
product_name="AtticUI${short_sha}${$}"
display_name="Attic UI ${short_sha} ${$}"
derived_data="/tmp/attic-ui-tests-derived-${short_sha}-${$}"
result_bundle="/tmp/attic-ui-tests-${short_sha}-${$}.xcresult"
signing_identity="-"
development_team=""
project_path="$repository_root/Attic.xcodeproj"
scheme="AtticUI"
configuration="Local"
dry_run=false
build_only=false
typeset -a only_testing
only_testing=()

while (( $# > 0 )); do
    case "$1" in
        --app-bundle-id)
            (( $# >= 2 )) || fail "--app-bundle-id requires a value"
            app_bundle_id=$2
            shift 2
            ;;
        --ui-test-bundle-id)
            (( $# >= 2 )) || fail "--ui-test-bundle-id requires a value"
            ui_test_bundle_id=$2
            shift 2
            ;;
        --unit-test-bundle-id)
            (( $# >= 2 )) || fail "--unit-test-bundle-id requires a value"
            unit_test_bundle_id=$2
            shift 2
            ;;
        --product-name)
            (( $# >= 2 )) || fail "--product-name requires a value"
            product_name=$2
            shift 2
            ;;
        --display-name)
            (( $# >= 2 )) || fail "--display-name requires a value"
            display_name=$2
            shift 2
            ;;
        --derived-data)
            (( $# >= 2 )) || fail "--derived-data requires a value"
            derived_data=$2
            shift 2
            ;;
        --result-bundle)
            (( $# >= 2 )) || fail "--result-bundle requires a value"
            result_bundle=$2
            shift 2
            ;;
        --only-testing)
            (( $# >= 2 )) || fail "--only-testing requires a value"
            only_testing+=("$2")
            shift 2
            ;;
        --signing-identity)
            (( $# >= 2 )) || fail "--signing-identity requires a value"
            signing_identity=$2
            shift 2
            ;;
        --development-team)
            (( $# >= 2 )) || fail "--development-team requires a value"
            development_team=$2
            shift 2
            ;;
        --project)
            (( $# >= 2 )) || fail "--project requires a value"
            project_path=$2
            shift 2
            ;;
        --scheme)
            (( $# >= 2 )) || fail "--scheme requires a value"
            scheme=$2
            shift 2
            ;;
        --configuration)
            (( $# >= 2 )) || fail "--configuration requires a value"
            configuration=$2
            shift 2
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        --build-only)
            build_only=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

(( ${#only_testing[@]} > 0 )) || only_testing=(AtticUITests)

validate_bundle_id() {
    local value=$1
    local label=$2
    [[ "$value" == com.taha.Attic.* ]] || fail "$label must use a unique com.taha.Attic.* identity"
    [[ "$value" != com.taha.Attic && "$value" != *..* && "$value" != *. ]] || fail "$label is not a valid isolated identity"
    [[ "$value" =~ '^[A-Za-z0-9.-]+$' ]] || fail "$label contains unsupported characters"
}

validate_bundle_id "$app_bundle_id" "app bundle ID"
validate_bundle_id "$ui_test_bundle_id" "UI-test bundle ID"
validate_bundle_id "$unit_test_bundle_id" "unit-test bundle ID"
[[ "$app_bundle_id" != "$ui_test_bundle_id" && "$app_bundle_id" != "$unit_test_bundle_id" && "$ui_test_bundle_id" != "$unit_test_bundle_id" ]] || fail "app and test bundle IDs must all be distinct"
[[ "$product_name" =~ '^[A-Za-z0-9._-]+$' ]] || fail "product name must be path-safe and contain no spaces"
[[ "$display_name" =~ '^[^/[:cntrl:]]+$' && "$display_name" != . && "$display_name" != .. ]] || fail "display name must be a single path-safe component"
[[ "$derived_data" == /* && "$result_bundle" == /* ]] || fail "DerivedData and result-bundle paths must be absolute"
[[ "$derived_data" != / && "$derived_data" != /Users && "$derived_data" != /Applications ]] || fail "DerivedData path is too broad"
[[ "$result_bundle" != / && "$result_bundle" != /Users && "$result_bundle" != /Applications ]] || fail "result-bundle path is too broad"
[[ -f "$project_path/project.pbxproj" ]] || fail "Xcode project not found at $project_path"

readonly build_products="$derived_data/Build/Products/$configuration"
readonly built_app="$build_products/$product_name.app"
readonly runner_app="$build_products/AtticUITests-Runner.app"
readonly test_bundle="$runner_app/Contents/PlugIns/AtticUITests.xctest"
readonly state_dir="$derived_data/UIHostState"
readonly app_entitlements="$state_dir/app-entitlements.plist"
readonly app_signature="$state_dir/app-signature.txt"
readonly runner_signature="$state_dir/runner-signature.txt"
readonly manifest="$state_dir/manifest.txt"
readonly attachment_owner_marker_name=.attic-test-root-owner

owned_attachment_parent=""
owned_attachment_root=""
owned_attachment_owner_token=""
owns_ui_lock=false
lock_owner=""

cleanup_test_attachment_root() {
    [[ -n "$owned_attachment_parent" && -n "$owned_attachment_root" ]] || return 0
    local marker="$owned_attachment_root/$attachment_owner_marker_name"
    local temporary_base=${TMPDIR:-/tmp}
    temporary_base=${temporary_base:A}
    local resolved_parent=${owned_attachment_parent:A}
    if [[ "$resolved_parent" == "$temporary_base"/* \
        && "${resolved_parent:t}" == attic-ui-attachments-${short_sha}.* \
        && "$owned_attachment_root" == "$owned_attachment_parent"/* \
        && -f "$marker" \
        && "$(<"$marker")" == "$owned_attachment_owner_token" ]]; then
        /usr/bin/find "$owned_attachment_parent" -depth -delete
        print -- "attachment_root_cleaned=$owned_attachment_root"
    else
        print -u2 -- "run_local_ui_tests: refused to clean unverified attachment root: $owned_attachment_root"
    fi
    owned_attachment_parent=""
    owned_attachment_root=""
    owned_attachment_owner_token=""
}

release_ui_lock() {
    if $owns_ui_lock && [[ -f "$ui_lock_path/owner" ]] && [[ "$(<"$ui_lock_path/owner")" == "$lock_owner" ]]; then
        /bin/rm "$ui_lock_path/owner"
        /bin/rmdir "$ui_lock_path"
    fi
    owns_ui_lock=false
}

cleanup_on_exit() {
    release_ui_lock
    cleanup_test_attachment_root
}

trap cleanup_on_exit EXIT
trap 'cleanup_on_exit; trap - EXIT; exit 130' INT
trap 'cleanup_on_exit; trap - EXIT; exit 143' TERM

typeset -a common_arguments selection_arguments
common_arguments=(
    -quiet
    -project "$project_path"
    -scheme "$scheme"
    -configuration "$configuration"
    -destination "platform=macOS"
    -derivedDataPath "$derived_data"
    "ATTIC_MACOS_BUNDLE_IDENTIFIER=$app_bundle_id"
    "ATTIC_MACOS_PRODUCT_NAME=$product_name"
    "ATTIC_MACOS_EXECUTABLE_NAME=$product_name"
    "ATTIC_MACOS_UNIT_TEST_BUNDLE_IDENTIFIER=$unit_test_bundle_id"
    "ATTIC_MACOS_UI_TEST_BUNDLE_IDENTIFIER=$ui_test_bundle_id"
    "ATTIC_DISPLAY_NAME=$display_name"
    "OTHER_SWIFT_FLAGS=\$(inherited) -DATTIC_LOCAL_ONLY"
    CODE_SIGNING_ALLOWED=YES
    CODE_SIGNING_REQUIRED=YES
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=$signing_identity"
)
if [[ -n "$development_team" ]]; then
    common_arguments+=("DEVELOPMENT_TEAM=$development_team")
fi
selection_arguments=()
for selection in "${only_testing[@]}"; do
    selection_arguments+=("-only-testing:$selection")
done

print_configuration() {
    print -- "sha=$commit_sha"
    print -- "display_name=$display_name"
    print -- "app_bundle_id=$app_bundle_id"
    print -- "ui_test_bundle_id=$ui_test_bundle_id"
    print -- "unit_test_bundle_id=$unit_test_bundle_id"
    print -- "product_name=$product_name"
    print -- "scheme=$scheme"
    print -- "derived_data=$derived_data"
    print -- "result_bundle=$result_bundle"
    print -- "app=$built_app"
    print -- "runner=$runner_app"
    print -- "ui_lock=$ui_lock_path"
    print -- "build_only=$build_only"
    if [[ -n "$owned_attachment_root" ]]; then
        print -- "attachment_root=$owned_attachment_root"
        print -- "attachment_root_owner_marker=$owned_attachment_root/$attachment_owner_marker_name"
    fi
}

if $dry_run; then
    print_configuration
    print -n -- "build_for_testing_command="
    printf '%q ' /usr/bin/xcodebuild "${common_arguments[@]}" "${selection_arguments[@]}" build-for-testing
    print
    print -n -- "test_without_building_command="
    printf '%q ' /usr/bin/xcodebuild "${common_arguments[@]}" "${selection_arguments[@]}" -resultBundlePath "$result_bundle" test-without-building
    print
    exit 0
fi

[[ ! -e "$result_bundle" ]] || fail "result bundle already exists: $result_bundle"
/bin/mkdir -p "$state_dir"

/usr/bin/xcodebuild "${common_arguments[@]}" "${selection_arguments[@]}" build-for-testing

[[ -d "$built_app" && -x "$built_app/Contents/MacOS/$product_name" ]] || fail "signed app build product is missing: $built_app"
[[ -d "$runner_app" && -d "$test_bundle" ]] || fail "signed XCTest runner build product is missing: $runner_app"

actual_app_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$built_app/Contents/Info.plist")
actual_test_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$test_bundle/Contents/Info.plist")
[[ "$actual_app_bundle_id" == "$app_bundle_id" ]] || fail "built app bundle ID does not match its isolated identity"
[[ "$actual_test_bundle_id" == "$ui_test_bundle_id" ]] || fail "built UI-test bundle ID does not match its isolated identity"

/usr/bin/codesign --verify --deep --strict "$built_app"
/usr/bin/codesign --verify --deep --strict "$runner_app"
/usr/bin/codesign -d --entitlements - --xml "$built_app" >"$app_entitlements" 2>/dev/null
/usr/bin/codesign -dv --verbose=4 "$built_app" >"$app_signature" 2>&1
/usr/bin/codesign -dv --verbose=4 "$runner_app" >"$runner_signature" 2>&1
if /usr/bin/grep -Eq 'com\.apple\.developer\.icloud|com\.apple\.developer\.ubiquity|aps-environment' "$app_entitlements"; then
    fail "Local UI host unexpectedly contains CloudKit, ubiquity, or APNs entitlements"
fi

app_hash=$(/usr/bin/shasum -a 256 "$built_app/Contents/MacOS/$product_name" | /usr/bin/awk '{print $1}')
runner_hash=$(/usr/bin/shasum -a 256 "$runner_app/Contents/MacOS/AtticUITests-Runner" | /usr/bin/awk '{print $1}')
if ! $build_only; then
    attachment_temporary_base=${TMPDIR:-/tmp}
    [[ "$attachment_temporary_base" == /* && "$attachment_temporary_base" != / ]] || fail "temporary attachment base is unsafe"
    owned_attachment_parent=$(/usr/bin/mktemp -d "${attachment_temporary_base%/}/attic-ui-attachments-${short_sha}.XXXXXX")
    owned_attachment_root="$owned_attachment_parent/owned-attachments"
    owned_attachment_owner_token="attic-ui-tests:${short_sha}:${$}:$RANDOM"
    /bin/mkdir "$owned_attachment_root"
    print -r -- "$owned_attachment_owner_token" >"$owned_attachment_root/$attachment_owner_marker_name"
fi
{
    print_configuration
    print -- "app_executable_sha256=$app_hash"
    print -- "runner_executable_sha256=$runner_hash"
    print -- "app_entitlements=$app_entitlements"
    print -- "app_signature=$app_signature"
    print -- "runner_signature=$runner_signature"
} >"$manifest"
/bin/cat "$manifest"

$build_only && exit 0

lock_owner="attic-ui-tests:${$}.$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"

if ! /bin/mkdir "$ui_lock_path" 2>/dev/null; then
    fail "live UI lock is owned by another task: $ui_lock_path"
fi
print -r -- "$lock_owner" >"$ui_lock_path/owner"
owns_ui_lock=true

ATTIC_TEST_ATTACHMENT_ROOT="$owned_attachment_root" \
ATTIC_TEST_ATTACHMENT_ROOT_OWNER_TOKEN="$owned_attachment_owner_token" \
    /usr/bin/xcodebuild "${common_arguments[@]}" "${selection_arguments[@]}" -resultBundlePath "$result_bundle" test-without-building
