#!/bin/zsh
# Run from the Air's authorized SSH session. Builds run in agents tmux.
set -eu
[[ $(scutil --get ComputerName) == *Air* ]] || { print -u2 'Air only'; exit 2; }
(( $# == 2 || $# == 3 )) || { print -u2 'usage: verify_corner_glass.zsh <AtticBugsTwo executable> <evidence dir> [glass|solid]'; exit 2; }
[[ ! -e "$2/driver.log" ]] || { print -u2 'Use a fresh evidence directory for each run'; exit 2; }
root=${0:A:h:h}
evidence=$2
preview_info=${1:A:h:h}/Info.plist
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$preview_info") == com.taha.Attic.preview.bugs2 ]] || { print -u2 'Attic Bugs Two identity only'; exit 2; }
owns_screen_lock=false
for attempt in {1..60}; do
    if mkdir /tmp/attic-air-screen.lockdir 2>/dev/null; then
        print bugs2 > /tmp/attic-air-screen.lockdir/owner
        owns_screen_lock=true
        break
    fi
    [[ $(cat /tmp/attic-air-screen.lockdir/owner 2>/dev/null) == bugs2 ]] && break
    sleep 1
done
[[ $(cat /tmp/attic-air-screen.lockdir/owner 2>/dev/null) == bugs2 ]] || { print -u2 'Air screen lock timed out'; exit 2; }
release_screen_lock() {
    if $owns_screen_lock && [[ $(cat /tmp/attic-air-screen.lockdir/owner 2>/dev/null) == bugs2 ]]; then
        if [[ -f "$evidence/driver.log" ]] && ! grep -q RESULT "$evidence/driver.log"; then
            print -u2 'Driver did not finish; screen lock retained for cleanup'
            return
        fi
        mv /tmp/attic-air-screen.lockdir "$root/.build/bugs2-released-lock-$$"
    fi
}
trap release_screen_lock EXIT
driver="$root/.build/BugsTwoCheck.app"
mkdir -p "$driver/Contents/MacOS" "$2"
cat > "$driver/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.taha.bugs2-screen-check</string><key>CFBundleExecutable</key><string>BugsTwoCheck</string><key>CFBundleName</key><string>Bugs Two Check</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
xcrun swiftc "$root/Scripts/verify_corner_glass.swift" -o "$driver/Contents/MacOS/BugsTwoCheck"
xcrun swiftc "$root/Scripts/capture_corner_glass.swift" -o "$root/.build/bugs2-capture"
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
        "$root/.build/bugs2-capture" "$2/capture-in-progress" >> "$2/captures.log" 2>&1 || true
    fi
    [[ -f "$2/driver.log" ]] && grep -q RESULT "$2/driver.log" && break
    sleep 0.2
done
cat "$2/driver.log"
grep -q 'RESULT failures=0' "$2/driver.log"
