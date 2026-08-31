#!/bin/zsh

set -euo pipefail

readonly script_dir=${0:A:h}
readonly repository_root=${script_dir:h}
readonly ui_lock_path=/tmp/attic-exclusive-ui.lock

usage() {
    /bin/cat <<'USAGE'
Usage: Scripts/launch_local_preview.zsh [options]

Builds and optionally launches a signed ATTIC_LOCAL_ONLY macOS preview without
touching the official bundle, store, /Applications, or an unrelated process.

Options:
  --display-name NAME          Finder/menu display name.
  --bundle-id IDENTIFIER       Must be a com.taha.Attic.* preview identifier.
  --executable-name NAME       Unique executable/product name (no spaces).
  --derived-data PATH          Build root (defaults to /tmp).
  --install-dir PATH           Optional copy destination. The build product is
                               launched in place when this is omitted.
  --allow-applications-install Permit an explicitly requested /Applications copy.
  --signing-identity IDENTITY  Codesigning identity; default is ad hoc (-).
  --development-team TEAM      Optional signing team override.
  --project PATH               Xcode project path.
  --scheme NAME                Scheme; default Attic.
  --configuration NAME         Configuration; default Local.
  --appearance MODE            Explicit isolated override: system, light, or dark.
  --build-only                 Build and emit provenance without launching.
  --dry-run                    Print resolved settings and build command only.
  --help                       Show this help.
USAGE
}

fail() {
    print -u2 -- "launch_local_preview: $*"
    exit 1
}

branch_name=$(/usr/bin/git -C "$repository_root" branch --show-current)
commit_sha=$(/usr/bin/git -C "$repository_root" rev-parse HEAD)
short_sha=${commit_sha[1,12]}
source_status=clean
if ! /usr/bin/git -C "$repository_root" diff --quiet \
    || ! /usr/bin/git -C "$repository_root" diff --cached --quiet \
    || [[ -n "$(/usr/bin/git -C "$repository_root" ls-files --others --exclude-standard)" ]]; then
    source_status=dirty
fi

display_name="Attic Preview ${short_sha}"
bundle_id="com.taha.Attic.preview.${short_sha}"
executable_name="AtticPreview${short_sha}"
derived_data="/tmp/attic-preview-derived-${short_sha}"
install_dir=""
signing_identity="-"
development_team=""
project_path="$repository_root/Attic.xcodeproj"
scheme="Attic"
configuration="Local"
appearance=""
build_only=false
dry_run=false
allow_applications_install=false

while (( $# > 0 )); do
    case "$1" in
        --display-name)
            (( $# >= 2 )) || fail "--display-name requires a value"
            display_name=$2
            shift 2
            ;;
        --bundle-id)
            (( $# >= 2 )) || fail "--bundle-id requires a value"
            bundle_id=$2
            shift 2
            ;;
        --executable-name)
            (( $# >= 2 )) || fail "--executable-name requires a value"
            executable_name=$2
            shift 2
            ;;
        --derived-data)
            (( $# >= 2 )) || fail "--derived-data requires a value"
            derived_data=$2
            shift 2
            ;;
        --install-dir)
            (( $# >= 2 )) || fail "--install-dir requires a value"
            install_dir=$2
            shift 2
            ;;
        --allow-applications-install)
            allow_applications_install=true
            shift
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
        --appearance)
            (( $# >= 2 )) || fail "--appearance requires a value"
            appearance=$2
            shift 2
            ;;
        --build-only)
            build_only=true
            shift
            ;;
        --dry-run)
            dry_run=true
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

[[ -n "$display_name" ]] || fail "display name cannot be empty"
[[ "$display_name" =~ '^[^/[:cntrl:]]+$' && "$display_name" != . && "$display_name" != .. ]] || fail "display name must be a single path-safe component"
[[ "$bundle_id" != com.taha.Attic ]] || fail "the official com.taha.Attic identity is not a preview identity"
[[ "$bundle_id" == com.taha.Attic.* ]] || fail "bundle ID must use a unique com.taha.Attic.* identity"
[[ "$bundle_id" != *..* && "$bundle_id" != *. ]] || fail "bundle ID contains an empty component"
[[ "$bundle_id" =~ '^[A-Za-z0-9.-]+$' ]] || fail "bundle ID contains unsupported characters"
[[ "$executable_name" =~ '^[A-Za-z0-9._-]+$' ]] || fail "executable name must be path-safe and contain no spaces"
[[ "$derived_data" == /* ]] || fail "DerivedData path must be absolute"
[[ "$derived_data" != / && "$derived_data" != /Users && "$derived_data" != /Applications ]] || fail "DerivedData path is too broad"
[[ -f "$project_path/project.pbxproj" ]] || fail "Xcode project not found at $project_path"
[[ "$appearance" == "" || "$appearance" == system || "$appearance" == light || "$appearance" == dark ]] || fail "appearance must be system, light, or dark"

if [[ -n "$install_dir" ]]; then
    [[ "$install_dir" == /* ]] || fail "install directory must be absolute"
    [[ "$install_dir" != / && "$install_dir" != /Users && "$install_dir" != /System ]] || fail "install directory is too broad"
    if [[ "$install_dir" == /Applications || "$install_dir" == /Applications/* ]]; then
        $allow_applications_install || fail "an /Applications copy requires --allow-applications-install"
    fi
fi

readonly build_products="$derived_data/Build/Products/$configuration"
readonly built_app="$build_products/$executable_name.app"
readonly built_executable="$built_app/Contents/MacOS/$executable_name"
if [[ -n "$install_dir" ]]; then
    preview_app="$install_dir/$display_name.app"
else
    preview_app="$built_app"
fi
readonly preview_app
readonly preview_executable="$preview_app/Contents/MacOS/$executable_name"
readonly state_dir="$derived_data/PreviewState"
readonly process_pid_file="$state_dir/process.pid"
readonly process_path_file="$state_dir/process.path"
readonly stdout_log="$state_dir/stdout.log"
readonly stderr_log="$state_dir/stderr.log"
readonly manifest_file="$state_dir/manifest.txt"
readonly entitlements_file="$state_dir/entitlements.plist"
readonly signature_file="$state_dir/signature.txt"
readonly preview_info_plist="$state_dir/Info.plist"

typeset -a build_arguments
build_arguments=(
    -quiet
    -project "$project_path"
    -scheme "$scheme"
    -configuration "$configuration"
    -destination "platform=macOS,arch=arm64"
    -derivedDataPath "$derived_data"
    "CONFIGURATION_BUILD_DIR=$build_products"
    "PRODUCT_BUNDLE_IDENTIFIER=$bundle_id"
    "PRODUCT_NAME=$executable_name"
    "EXECUTABLE_NAME=$executable_name"
    "INFOPLIST_FILE=$preview_info_plist"
    "OTHER_SWIFT_FLAGS=\$(inherited) -DATTIC_LOCAL_ONLY"
    CODE_SIGNING_ALLOWED=YES
    CODE_SIGNING_REQUIRED=YES
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=$signing_identity"
)
if [[ -n "$development_team" ]]; then
    build_arguments+=("DEVELOPMENT_TEAM=$development_team")
fi

print_resolved_configuration() {
    print -- "branch=$branch_name"
    print -- "sha=$commit_sha"
    print -- "source_status=$source_status"
    print -- "display_name=$display_name"
    print -- "bundle_id=$bundle_id"
    print -- "executable_name=$executable_name"
    print -- "derived_data=$derived_data"
    print -- "preview_app=$preview_app"
    print -- "signing_identity=$signing_identity"
    print -- "appearance=${appearance:-unchanged}"
}

if $dry_run; then
    print_resolved_configuration
    print -n -- "build_command="
    printf '%q ' /usr/bin/xcodebuild "${build_arguments[@]}" build
    print
    if [[ -n "$appearance" ]]; then
        print -- "appearance_command=explicit isolated defaults update for $bundle_id ($appearance)"
    fi
    $build_only || print -- "launch_command=$preview_executable"
    exit 0
fi

/bin/mkdir -p "$state_dir"
/bin/cp "$repository_root/Attic/Info.plist" "$preview_info_plist"
/usr/bin/plutil -replace CFBundleDisplayName -string "$display_name" "$preview_info_plist"

/usr/bin/xcodebuild "${build_arguments[@]}" build
[[ -d "$built_app" && -x "$built_executable" ]] || fail "expected build product is missing: $built_app"
actual_display_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$built_app/Contents/Info.plist")
actual_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$built_app/Contents/Info.plist")
actual_executable_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$built_app/Contents/Info.plist")
[[ "$actual_display_name" == "$display_name" ]] || fail "built display name does not match the requested identity"
[[ "$actual_bundle_id" == "$bundle_id" ]] || fail "built bundle ID does not match the requested identity"
[[ "$actual_executable_name" == "$executable_name" ]] || fail "built executable name does not match the requested identity"

/usr/bin/codesign --verify --deep --strict "$built_app"
/usr/bin/codesign -d --entitlements - --xml "$built_app" >"$entitlements_file" 2>/dev/null
/usr/bin/codesign -dv --verbose=4 "$built_app" >"$signature_file" 2>&1

if /usr/bin/grep -Eq 'com\.apple\.developer\.icloud|com\.apple\.developer\.ubiquity|aps-environment' "$entitlements_file"; then
    fail "Local preview unexpectedly contains CloudKit, ubiquity, or APNs entitlements"
fi

executable_hash=$(/usr/bin/shasum -a 256 "$built_executable" | /usr/bin/awk '{print $1}')
{
    print_resolved_configuration
    print -- "executable=$built_executable"
    print -- "executable_sha256=$executable_hash"
    print -- "entitlements=$entitlements_file"
    print -- "signature=$signature_file"
} >"$manifest_file"

/bin/cat "$manifest_file"
print -- "entitlements_begin"
/bin/cat "$entitlements_file"
print -- "entitlements_end"

$build_only && exit 0

lock_owner="attic-preview:${$}:$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
owns_ui_lock=false
release_ui_lock() {
    if $owns_ui_lock && [[ -f "$ui_lock_path/owner" ]] && [[ "$(<"$ui_lock_path/owner")" == "$lock_owner" ]]; then
        /bin/rm "$ui_lock_path/owner"
        /bin/rmdir "$ui_lock_path"
    fi
}
trap release_ui_lock EXIT
trap 'release_ui_lock; exit 130' INT
trap 'release_ui_lock; exit 143' TERM

if ! /bin/mkdir "$ui_lock_path" 2>/dev/null; then
    fail "live UI lock is owned by another task: $ui_lock_path"
fi
print -r -- "$lock_owner" >"$ui_lock_path/owner"
owns_ui_lock=true

if [[ -f "$process_pid_file" && -f "$process_path_file" ]]; then
    previous_pid=$(<"$process_pid_file")
    previous_executable=$(<"$process_path_file")
    if [[ "$previous_pid" =~ '^[0-9]+$' ]] && /bin/kill -0 "$previous_pid" 2>/dev/null; then
        actual_command=$(/bin/ps -p "$previous_pid" -o command=)
        if [[ "$actual_command" == "$previous_executable" || "$actual_command" == "$previous_executable "* ]]; then
            /bin/kill -TERM "$previous_pid"
            for _ in {1..20}; do
                /bin/kill -0 "$previous_pid" 2>/dev/null || break
                /bin/sleep 0.1
            done
            if /bin/kill -0 "$previous_pid" 2>/dev/null; then
                /bin/kill -KILL "$previous_pid"
            fi
        else
            print -u2 -- "Not stopping PID $previous_pid: command does not match the exact recorded executable."
        fi
    fi
fi

if [[ -n "$install_dir" ]]; then
    /bin/mkdir -p "$install_dir"
    if [[ -e "$preview_app" ]]; then
        existing_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$preview_app/Contents/Info.plist" 2>/dev/null || true)
        [[ "$existing_bundle_id" == "$bundle_id" ]] || fail "refusing to replace an app with a different bundle ID at $preview_app"
        /bin/rm -R "$preview_app"
    fi
    /usr/bin/ditto --rsrc --extattr --noqtn "$built_app" "$preview_app"
    /usr/bin/codesign --verify --deep --strict "$preview_app"
fi

case "$appearance" in
    dark)
        /usr/bin/defaults write "$bundle_id" AppleInterfaceStyle -string Dark
        ;;
    light)
        /usr/bin/defaults write "$bundle_id" AppleInterfaceStyle -string Light
        ;;
    system)
        /usr/bin/defaults delete "$bundle_id" AppleInterfaceStyle 2>/dev/null || true
        ;;
esac

canonical_preview_executable="$(cd "${preview_executable:h}" && pwd -P)/${preview_executable:t}"
"$canonical_preview_executable" >"$stdout_log" 2>"$stderr_log" &
launched_pid=$!
disown "$launched_pid" 2>/dev/null || true
print -r -- "$launched_pid" >"$process_pid_file"
print -r -- "$canonical_preview_executable" >"$process_path_file"
print -- "launched_pid=$launched_pid"
print -- "stdout_log=$stdout_log"
print -- "stderr_log=$stderr_log"
