#!/bin/zsh
# Run on the Air in the agents tmux session, with the Air screen lock owned by bugs2.
set -eu
[[ $(scutil --get ComputerName) == *Air* ]] || { print -u2 'Air only'; exit 2; }
[[ $(cat /tmp/attic-air-screen.lockdir/owner) == bugs2 ]] || { print -u2 'Acquire the Air screen lock first'; exit 2; }
(( $# == 2 )) || { print -u2 'usage: verify_corner_glass.zsh <AtticBugsTwo executable> <evidence dir>'; exit 2; }
[[ ! -e "$2/driver.log" ]] || { print -u2 'Use a fresh evidence directory for each run'; exit 2; }
root=${0:A:h:h}
driver="$root/.build/BugsTwoCheck.app"
mkdir -p "$driver/Contents/MacOS" "$2"
cat > "$driver/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.taha.bugs2-screen-check</string><key>CFBundleExecutable</key><string>BugsTwoCheck</string><key>CFBundleName</key><string>Bugs Two Check</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
xcrun swiftc "$root/Scripts/verify_corner_glass.swift" -o "$driver/Contents/MacOS/BugsTwoCheck"
xcrun swiftc "$root/Scripts/capture_corner_glass.swift" -o "$root/.build/bugs2-capture"
codesign --force --sign - "$driver"
open -n --stdout "$2/driver.log" --stderr "$2/driver-error.log" "$driver" --args "$1" "$2"
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
