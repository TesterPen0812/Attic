#!/bin/zsh
# Run from the Air's authorized SSH session. Builds run in agents tmux.
set -eu
[[ $(scutil --get ComputerName) == *Air* ]] || { print -u2 'Air only'; exit 2; }
(( $# == 2 )) || { print -u2 'usage: verify_followup_surface.zsh <AtticFollowUp executable> <evidence dir>'; exit 2; }
[[ ! -e "$2/driver.log" ]] || { print -u2 'Use a fresh evidence directory for each run'; exit 2; }
root=${0:A:h:h}
evidence=$2
mkdir -p "$root/.build"
preview_info=${1:A:h:h}/Info.plist
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$preview_info") == com.taha.Attic.preview.followup ]] || { print -u2 'Attic Bugs Two identity only'; exit 2; }
owns_screen_lock=false
for attempt in {1..60}; do
    if mkdir /tmp/attic-air-screen.lockdir 2>/dev/null; then
        print followup > /tmp/attic-air-screen.lockdir/owner
        owns_screen_lock=true
        break
    fi
    sleep 1
done
$owns_screen_lock || { print -u2 'Air screen lock timed out'; exit 75; }
release_screen_lock() {
    if $owns_screen_lock && [[ $(cat /tmp/attic-air-screen.lockdir/owner 2>/dev/null) == followup ]]; then
        if [[ -f "$evidence/driver.log" ]] && ! grep -q RESULT "$evidence/driver.log"; then
            print -u2 'Driver did not finish; screen lock retained for cleanup'
            return
        fi
        mv /tmp/attic-air-screen.lockdir "$root/.build/followup-released-lock-$$"
    fi
}
trap release_screen_lock EXIT
front_bundle=$(osascript -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true')
if [[ $front_bundle != com.taha.Attic.preview.followup && $front_bundle != com.taha.followup-screen-check ]]; then
    print -u2 "Air screen is in use ($front_bundle); no app launched or input sent"
    exit 75
fi
driver="$root/.build/FollowupSurfaceCheck.app"
mkdir -p "$driver/Contents/MacOS" "$2"
cat > "$driver/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.taha.followup-screen-check</string><key>CFBundleExecutable</key><string>FollowupSurfaceCheck</string><key>CFBundleName</key><string>Followup Surface Check</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
xcrun swiftc "$root/Scripts/verify_followup_surface.swift" -o "$driver/Contents/MacOS/FollowupSurfaceCheck"
xcrun swiftc "$root/Scripts/capture_followup_surface.swift" -o "$root/.build/followup-capture"
codesign --force --sign - "$driver"
open -n --stdout "$2/driver.log" --stderr "$2/driver-error.log" "$driver" --args "$@"
# Explicit three-minute deadline; all driver waits are bounded too.
for i in {1..900}; do
    if [[ -f "$2/input-request" ]]; then
        mv "$2/input-request" "$2/input-in-progress"
        osascript -l JavaScript "$2/input-in-progress" >> "$2/input.log" 2>&1
        head -1 "$2/input-in-progress" > "$2/input-done"
    fi
    if [[ -f "$2/capture-request" ]]; then
        mv "$2/capture-request" "$2/capture-in-progress"
        "$root/.build/followup-capture" "$2/capture-in-progress" >> "$2/captures.log" 2>&1 || true
    fi
    [[ -f "$2/driver.log" ]] && grep -q RESULT "$2/driver.log" && break
    sleep 0.2
done
cat "$2/driver.log"
grep -q 'RESULT failures=0' "$2/driver.log"

python3 "$root/Scripts/verify_followup_samples.py" "$evidence"
