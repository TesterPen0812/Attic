#!/bin/zsh
set -euo pipefail

# Deliberate local daily releases. The ordinary Run/preview launcher never
# delegates here and still rejects the official bundle identifier.
readonly repository_root=${0:A:h:h}
readonly target_app='/Applications/Attic Daily.app'
readonly bundle_id='com.taha.Attic'
readonly executable_name='AtticDaily'
readonly project_team_id='ZGZWS73268'
readonly derived_data="$repository_root/.build/Daily"
readonly state_dir="$derived_data/ReleaseState"
readonly built_app="$derived_data/Build/Products/Local/$executable_name.app"
readonly data_library="/Users/$(/usr/bin/id -un)/Library/Containers/$bundle_id/Data/Library"
readonly releases_root="/Users/$(/usr/bin/id -un)/Library/Application Support/AtticDailyReleases"
readonly lock_path='/tmp/attic-exclusive-ui.lock'

fail() { print -u2 -- "install_daily_app: $*"; exit 1; }
usage() {
    print -- 'Usage: Scripts/install_daily_app.zsh --dry-run'
    print -- '       Scripts/install_daily_app.zsh --install --expected-sha FULL_COMMIT_SHA [--no-launch]'
    print -- '         [--development-team TEAM_ID --signing-identity CERTIFICATE_SHA1]'
    print -- 'Builds a clean, pinned local-only daily release, backs up the previous daily app/data,'
    print -- 'then installs only /Applications/Attic Daily.app. Never touches the former owner store.'
}

mode=''
expected_sha=''
launch=true
team_id=$project_team_id
signing_identity=''
while (( $# )); do
    case "$1" in
        --dry-run|--install)
            [[ -z "$mode" ]] || fail 'choose exactly one mode'
            mode=$1; shift ;;
        --expected-sha)
            (( $# >= 2 )) || fail '--expected-sha requires a value'
            expected_sha=$2; shift 2 ;;
        --development-team)
            (( $# >= 2 )) || fail '--development-team requires a value'
            team_id=$2; shift 2 ;;
        --signing-identity)
            (( $# >= 2 )) || fail '--signing-identity requires a value'
            signing_identity=$2; shift 2 ;;
        --no-launch) launch=false; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
done
[[ -n "$mode" ]] || { usage; exit 0; }
[[ "$team_id" =~ '^[A-Z0-9]{10}$' ]] || fail 'team ID must be ten uppercase letters/digits'
[[ -z "$signing_identity" || "$signing_identity" =~ '^[A-Fa-f0-9]{40}$' ]] || fail 'signing identity must be a certificate SHA-1, not an ad-hoc or fuzzy identity'
readonly source_sha=$(/usr/bin/git -C "$repository_root" rev-parse HEAD)
readonly source_branch=$(/usr/bin/git -C "$repository_root" branch --show-current)
if [[ -n "$expected_sha" ]]; then
    [[ "$expected_sha" =~ '^[0-9a-f]{40}$' ]] || fail 'expected SHA must be a full 40-character commit'
    [[ "$expected_sha" == "$source_sha" ]] || fail 'expected SHA does not match the current source commit'
fi
if [[ "$mode" == --install ]]; then
    [[ -n "$expected_sha" ]] || fail 'installation requires --expected-sha'
    [[ -z "$(/usr/bin/git -C "$repository_root" status --porcelain --untracked-files=all)" ]] \
        || fail 'daily installation requires a clean source tree'
fi

print -- "source_branch=$source_branch"
print -- "source_sha=$source_sha"
print -- "target_app=$target_app"
print -- "bundle_id=$bundle_id"
print -- "project_team_id=$project_team_id"
print -- "local_signing_team=$team_id"
print -- 'configuration=Local'
print -- 'compile_flags=ATTIC_LOCAL_ONLY ATTIC_DAILY'
print -- 'entitlements=Attic/AtticNotesLocal.entitlements (sandbox and network only)'
print -- 'store_environment=Development (local-only, never the production store)'
print -- "backups=$releases_root"
[[ "$mode" != --dry-run ]] || exit 0

# A different app at this exact path is never overwritten.
build_number=1
if [[ -e "$target_app" ]]; then
    [[ ! -L "$target_app" && -d "$target_app" ]] || fail 'installed app path is not a regular bundle'
    installed_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target_app/Contents/Info.plist")
    [[ "$installed_id" == "$bundle_id" ]] || fail 'existing daily app has a different bundle ID'
    previous_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$target_app/Contents/Info.plist")
    [[ "$previous_build" =~ '^[0-9]+$' ]] || fail 'existing build number needs manual review'
    build_number=$(( previous_build + 1 ))
fi

# A certificate's parenthesized display-name suffix is not its team ID. Select
# an exact installed certificate, then require the actual signed TeamIdentifier
# below to match the project team or the explicit local override.
available_identities=$(/usr/bin/security find-identity -v -p codesigning)
if [[ -z "$signing_identity" ]]; then
    signing_identity=$(print -r -- "$available_identities" | /usr/bin/awk '/Apple Development:/ {print $2; exit}')
fi
[[ -n "$signing_identity" ]] || fail 'no Apple Development signing identity is available'
print -r -- "$available_identities" | /usr/bin/awk -v expected="$signing_identity" \
    'toupper($2) == toupper(expected) && /Apple Development:/ {found=1} END {exit !found}' \
    || fail 'requested development certificate is not installed or valid'

owns_lock=false
stage_dir=''
release_dir=''
cleanup() {
    local cleanup_status=$?
    if [[ -n "$stage_dir" && -d "$stage_dir" ]]; then
        # If installing the staged app failed after moving the old one, restore
        # the old bundle. Never roll back a data store automatically.
        if (( cleanup_status != 0 )) && [[ -d "$stage_dir/Previous.app" && -e "$target_app" ]]; then
            /bin/mv "$target_app" "$stage_dir/Failed.app"
        fi
        if [[ ! -e "$target_app" && -d "$stage_dir/Previous.app" ]]; then
            /bin/mv "$stage_dir/Previous.app" "$target_app"
        fi
        [[ "$stage_dir" == /Applications/.AtticDaily-install-* ]] && /bin/rm -R "$stage_dir"
    fi
    if $owns_lock && [[ "$(<"$lock_path/owner")" == "attic-daily:${$}" ]]; then
        /bin/rm "$lock_path/owner"
        /bin/rmdir "$lock_path"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
/bin/mkdir "$lock_path" 2>/dev/null || fail "another UI/build task owns $lock_path"
print -r -- "attic-daily:${$}" > "$lock_path/owner"
owns_lock=true

/bin/mkdir -p "$state_dir"
/bin/cp "$repository_root/Attic/Info.plist" "$state_dir/Info.plist"
/usr/bin/plutil -insert AtticSourceCommit -string "$source_sha" "$state_dir/Info.plist"
/usr/bin/plutil -insert AtticReleaseChannel -string daily "$state_dir/Info.plist"
/usr/bin/plutil -insert AtticCloudKitEnvironment -string Development "$state_dir/Info.plist"
/usr/bin/xcodebuild -quiet -project "$repository_root/Attic.xcodeproj" \
    -scheme Attic -configuration Local -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    "CONFIGURATION_BUILD_DIR=$derived_data/Build/Products/Local" \
    ATTIC_MACOS_BUNDLE_IDENTIFIER="$bundle_id" \
    ATTIC_MACOS_PRODUCT_NAME="$executable_name" \
    ATTIC_MACOS_EXECUTABLE_NAME="$executable_name" \
    ATTIC_DISPLAY_NAME='Attic Daily' \
    CURRENT_PROJECT_VERSION="$build_number" \
    INFOPLIST_FILE="$state_dir/Info.plist" \
    'OTHER_SWIFT_FLAGS=$(inherited) -DATTIC_LOCAL_ONLY -DATTIC_DAILY' \
    CODE_SIGN_ENTITLEMENTS=Attic/AtticNotesLocal.entitlements \
    CODE_SIGN_STYLE=Manual CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_IDENTITY="$signing_identity" DEVELOPMENT_TEAM="$team_id" build

/usr/bin/codesign --verify --deep --strict "$built_app"
/usr/bin/codesign -d --entitlements - --xml "$built_app" > "$state_dir/entitlements.plist" 2>/dev/null
/usr/bin/codesign -dv --verbose=4 "$built_app" > "$state_dir/signature.txt" 2>&1
if /usr/bin/grep -Eq 'icloud|ubiquity|aps-environment' "$state_dir/entitlements.plist"; then
    fail 'daily build contains forbidden CloudKit/APNs entitlements'
fi
/usr/bin/grep -qx "TeamIdentifier=$team_id" "$state_dir/signature.txt" || fail 'signed team does not match'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$state_dir/entitlements.plist")" == true ]] || fail 'sandbox entitlement missing'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$built_app/Contents/Info.plist")" == "$bundle_id" ]] || fail 'built bundle ID mismatch'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$built_app/Contents/Info.plist")" == "$executable_name" ]] || fail 'built executable mismatch'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :AtticCloudKitEnvironment' "$built_app/Contents/Info.plist")" == Development ]] || fail 'store environment mismatch'
[[ "$(/usr/bin/git -C "$repository_root" rev-parse HEAD)" == "$source_sha" \
    && -z "$(/usr/bin/git -C "$repository_root" status --porcelain --untracked-files=all)" ]] || fail 'source changed during the build'

# Stop only the daily app at the expected install path, using its normal quit
# action so in-flight edits can save. Never force-kill or target another preview.
daily_pids=(${(f)$(/usr/bin/pgrep -x "$executable_name" || true)})
for pid in "${daily_pids[@]}"; do
    [[ "$(/bin/ps -p "$pid" -o comm=)" == "$target_app/Contents/MacOS/$executable_name" ]] \
        || fail 'an AtticDaily process from another location is running; quit it first'
done
if (( ${#daily_pids} )); then
    /usr/bin/osascript -e 'tell application "/Applications/Attic Daily.app" to quit'
    for _ in {1..50}; do
        /usr/bin/pgrep -x "$executable_name" >/dev/null || break
        /bin/sleep 0.1
    done
    /usr/bin/pgrep -x "$executable_name" >/dev/null && fail 'daily app has not quit; no replacement was made'
fi

/bin/mkdir -p "$releases_root"
release_dir=$(/usr/bin/mktemp -d "$releases_root/release-${source_sha[1,12]}-XXXXXX")
if [[ -d "$target_app" ]]; then
    /usr/bin/ditto --rsrc --extattr "$target_app" "$release_dir/Previous.app"
fi
for component in 'Application Support' Preferences 'Saved Application State'; do
    source_data="$data_library/$component"
    [[ ! -L "$source_data" ]] || fail "refusing to back up a symlinked data directory: $source_data"
    if [[ -d "$source_data" ]]; then
        /usr/bin/ditto --rsrc --extattr "$source_data" "$release_dir/DataBackup/Library/$component"
    fi
done

stage_dir=$(/usr/bin/mktemp -d /Applications/.AtticDaily-install-XXXXXX)
/usr/bin/ditto --rsrc --extattr --noqtn "$built_app" "$stage_dir/Attic Daily.app"
/usr/bin/codesign --verify --deep --strict "$stage_dir/Attic Daily.app"
if [[ -e "$target_app" ]]; then /bin/mv "$target_app" "$stage_dir/Previous.app"; fi
/bin/mv "$stage_dir/Attic Daily.app" "$target_app"
/usr/bin/codesign --verify --deep --strict "$target_app"
{
    print -- "source_sha=$source_sha"
    print -- "source_branch=$source_branch"
    print -- "build_number=$build_number"
    print -- "bundle_id=$bundle_id"
    print -- "installed_app=$target_app"
    print -- "executable=$target_app/Contents/MacOS/$executable_name"
    print -- "team_id=$team_id"
    print -- "project_team_id=$project_team_id"
    print -- "signing_identity=$signing_identity"
    print -- 'local_only=true'
    print -- 'store_environment=Development'
    print -- "executable_sha256=$(/usr/bin/shasum -a 256 "$target_app/Contents/MacOS/$executable_name" | /usr/bin/awk '{print $1}')"
    print -- "backup=$release_dir"
} > "$release_dir/manifest.txt"
/bin/cp "$state_dir/entitlements.plist" "$state_dir/signature.txt" "$release_dir/"
/bin/cat "$release_dir/manifest.txt"
# An immutable local tag keeps this daily baseline reachable as development
# continues. This does not push or publish anything.
release_tag="attic-daily-${build_number}-${source_sha[1,12]}"
if /usr/bin/git -C "$repository_root" rev-parse --verify "refs/tags/$release_tag" >/dev/null 2>&1; then
    [[ "$(/usr/bin/git -C "$repository_root" rev-parse "refs/tags/$release_tag")" == "$source_sha" ]] || fail 'release tag points to another commit'
else
    /usr/bin/git -C "$repository_root" tag "$release_tag" "$source_sha"
fi
print -- "release_tag=$release_tag"
# Release staging before launching; a later runtime failure is diagnosed using
# the retained previous app and data backup, not an automatic store rollback.
cleanup
stage_dir=''
owns_lock=false
if $launch; then /usr/bin/open "$target_app"; fi
