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
  --verify                     Build and launch nothing: check that exactly one
                               launchd-owned process runs this preview and
                               that it maps the on-disk executable and debug
                               dylib, then print that provenance.
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
verify_only=false
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
        --verify)
            verify_only=true
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
readonly launch_provenance_file="$state_dir/launch-provenance.txt"
# Bounded waits: a new instance must appear, map its images and then stay up.
readonly launch_appear_timeout_seconds=20
readonly launch_stability_seconds=3

# PIDs running exactly this preview executable. An instance whose PID record
# was overwritten keeps the replaced binary mapped, so inspecting it after a
# rebuild silently exercises stale code.
preview_executable_pids() {
    local resolved=${preview_executable:A}
    /bin/ps -axo pid=,command= | while read -r pid command; do
        if [[ "$command" == "$resolved" || "$command" == "$resolved "* \
            || "$command" == "$preview_executable" || "$command" == "$preview_executable "* ]]; then
            print -r -- "$pid"
        fi
    done
}

# The stub executable is small and byte-identical across builds; with a debug
# dylib the app's code lives there. Both are identified by inode, size and
# SHA-256 so a running process can be tied to the exact bytes on disk.
file_identity() {
    local file=$1
    if [[ -f "$file" ]]; then
        print -r -- "$(/usr/bin/stat -f '%i %z' "$file") $(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{print $1}')"
    else
        print -r -- "absent"
    fi
}

# "inode size" of the file PID maps at exactly PATH, or nothing.
mapped_identity() {
    local pid=$1 file=$2 inode="" size="" line
    /usr/sbin/lsof -a -p "$pid" -d txt -F isn 2>/dev/null | while read -r line; do
        case "$line" in
            s*) size=${line#s} ;;
            i*) inode=${line#i} ;;
            n*)
                if [[ "${line#n}" == "$file" ]]; then
                    print -r -- "$inode $size"
                    return 0
                fi
                ;;
        esac
    done
}

# Verifies PID as the sole, launchd-owned instance mapping the current images
# and writes its provenance to stdout. Returns nonzero with a reason on stderr.
verify_preview_process() {
    local pid=$1
    local executable=${preview_executable:A}
    local dylib="${executable}.debug.dylib"
    /bin/kill -0 "$pid" 2>/dev/null || { print -u2 -- "PID $pid is not running"; return 1; }
    local -a running
    running=($(preview_executable_pids))
    (( ${#running} == 1 )) && [[ "${running[1]}" == "$pid" ]] \
        || { print -u2 -- "expected only PID $pid to run $executable, found: ${running[*]:-none}"; return 1; }
    local ppid
    ppid=$(/bin/ps -o ppid= -p "$pid" | /usr/bin/tr -d ' ')
    [[ "$ppid" == 1 ]] || { print -u2 -- "PID $pid is not launchd-owned (parent $ppid)"; return 1; }
    local stub_disk dylib_disk stub_mapped dylib_mapped
    stub_disk=$(file_identity "$executable")
    dylib_disk=$(file_identity "$dylib")
    stub_mapped=$(mapped_identity "$pid" "$executable")
    [[ -n "$stub_mapped" && "$stub_disk" == "$stub_mapped "* ]] \
        || { print -u2 -- "PID $pid maps executable '${stub_mapped:-nothing}', on disk '$stub_disk'"; return 1; }
    if [[ "$dylib_disk" != absent ]]; then
        dylib_mapped=$(mapped_identity "$pid" "$dylib")
        [[ -n "$dylib_mapped" && "$dylib_disk" == "$dylib_mapped "* ]] \
            || { print -u2 -- "PID $pid maps debug dylib '${dylib_mapped:-nothing}', on disk '$dylib_disk'"; return 1; }
    fi
    # The files must not have been replaced while they were hashed.
    [[ "$(file_identity "$executable")" == "$stub_disk" && "$(file_identity "$dylib")" == "$dylib_disk" ]] \
        || { print -u2 -- "preview images changed during verification"; return 1; }
    print -- "verified_at=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
    print -- "pid=$pid"
    print -- "parent_pid=$ppid"
    print -- "started=$(/bin/ps -o lstart= -p "$pid")"
    print -- "command=$(/bin/ps -o command= -p "$pid")"
    print -- "executable=$executable"
    print -- "executable_inode_size_sha256=$stub_disk"
    print -- "executable_mapped_inode_size=$stub_mapped"
    print -- "debug_dylib=$dylib"
    print -- "debug_dylib_inode_size_sha256=$dylib_disk"
    print -- "debug_dylib_mapped_inode_size=${dylib_mapped:-not applicable}"
    if [[ -f "$process_pid_file" ]]; then
        print -- "recorded_pid=$(<"$process_pid_file")"
    fi
}

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

if $verify_only; then
    typeset -a verify_pids
    verify_pids=($(preview_executable_pids))
    (( ${#verify_pids} == 1 )) || fail "expected one running instance of $preview_executable, found: ${verify_pids[*]:-none}"
    verify_preview_process "${verify_pids[1]}" || fail "running preview could not be verified"
    exit 0
fi

if $dry_run; then
    print_resolved_configuration
    print -n -- "build_command="
    printf '%q ' /usr/bin/xcodebuild "${build_arguments[@]}" build
    print
    if [[ -n "$appearance" ]]; then
        print -- "appearance_command=explicit isolated defaults update for $bundle_id ($appearance)"
    fi
    $build_only || print -- "launch_command=/usr/bin/open -n $preview_app"
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
    print -- "executable_inode_size_sha256=$(file_identity "$built_executable")"
    print -- "debug_dylib=${built_executable}.debug.dylib"
    print -- "debug_dylib_inode_size_sha256=$(file_identity "${built_executable}.debug.dylib")"
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

stop_preview_process() {
    local pid=$1
    /bin/kill -TERM "$pid" 2>/dev/null || return 0
    for _ in {1..20}; do
        /bin/kill -0 "$pid" 2>/dev/null || return 0
        /bin/sleep 0.1
    done
    /bin/kill -KILL "$pid" 2>/dev/null || true
}

if [[ -f "$process_pid_file" && -f "$process_path_file" ]]; then
    previous_pid=$(<"$process_pid_file")
    previous_executable=$(<"$process_path_file")
    if [[ "$previous_pid" =~ '^[0-9]+$' ]] && /bin/kill -0 "$previous_pid" 2>/dev/null; then
        actual_command=$(/bin/ps -p "$previous_pid" -o command=)
        if [[ "$actual_command" == "$previous_executable" || "$actual_command" == "$previous_executable "* ]]; then
            stop_preview_process "$previous_pid"
        else
            print -u2 -- "Not stopping PID $previous_pid: command does not match the exact recorded executable."
        fi
    fi
fi

for stale_pid in $(preview_executable_pids); do
    print -u2 -- "Stopping unrecorded instance PID $stale_pid of $preview_executable."
    stop_preview_process "$stale_pid"
done

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
/bin/rm -f "$process_pid_file" "$process_path_file" "$launch_provenance_file"
# Launch through LaunchServices so launchd owns the app. A plain background
# child of this shell is an unmanaged process tied to the caller: in the
# Batch 4 integration run, PID 9983 passed a 1.5 s health check and was torn
# down as the invoking command returned, while a LaunchServices launch of the
# same bundle (PID 10135) stayed up.
/usr/bin/open -n --stdout "$stdout_log" --stderr "$stderr_log" "$preview_app" \
    || fail "LaunchServices could not open $preview_app"

launched_pid=""
for (( attempt = 0; attempt < launch_appear_timeout_seconds * 4; attempt++ )); do
    typeset -a launched_pids
    launched_pids=($(preview_executable_pids))
    (( ${#launched_pids} <= 1 )) || fail "more than one instance is running $preview_executable: ${launched_pids[*]}"
    if (( ${#launched_pids} == 1 )) && [[ -n "$(mapped_identity "${launched_pids[1]}" "$canonical_preview_executable")" ]]; then
        launched_pid=${launched_pids[1]}
        break
    fi
    /bin/sleep 0.25
done
[[ -n "$launched_pid" ]] || fail "no instance of $preview_executable appeared within ${launch_appear_timeout_seconds}s; see $stderr_log"
print -r -- "$launched_pid" >"$process_pid_file"
print -r -- "$canonical_preview_executable" >"$process_path_file"

# Loading the debug dylib can trail the executable; then the process must stay
# the sole verified instance across the whole stability window.
for (( attempt = 0; attempt < launch_appear_timeout_seconds * 4; attempt++ )); do
    verify_preview_process "$launched_pid" >/dev/null 2>&1 && break
    /bin/kill -0 "$launched_pid" 2>/dev/null || break
    /bin/sleep 0.25
done
for (( attempt = 0; attempt <= launch_stability_seconds * 4; attempt++ )); do
    verify_preview_process "$launched_pid" >/dev/null \
        || fail "launched preview PID $launched_pid did not stay verified; see $stderr_log"
    (( attempt == launch_stability_seconds * 4 )) || /bin/sleep 0.25
done
verify_preview_process "$launched_pid" >"$launch_provenance_file" \
    || fail "launched preview PID $launched_pid could not be verified; see $stderr_log"
/bin/cat "$launch_provenance_file"
print -- "launched_pid=$launched_pid"
print -- "launch_provenance=$launch_provenance_file"
print -- "stdout_log=$stdout_log"
print -- "stderr_log=$stderr_log"
print -- "Launch provenance proves identity at launch only; run --verify again before live checks."
