#!/bin/zsh
set -euo pipefail

# Only run under attic-air/.build/jobs/attic-px-iphone-taskselect, via air-slot.zsh.
job="$HOME/Projects/attic/attic-air/.build/jobs/attic-px-iphone-taskselect"
[[ "$PWD" == "$job" ]] || { print -u2 'Wrong Air job folder'; exit 2; }
free_kib=$(df -k / | awk 'NR==2 {print $4}')
(( free_kib > 8 * 1024 * 1024 )) || { print -u2 'Air has less than 8 GiB free'; exit 3; }

export PATH=/opt/homebrew/opt/ruby/bin:/opt/homebrew/bin:$PATH
out="$job/.build/backdrop-spike"
app="$out/BackdropProbe.app"
mkdir -p "$app/Contents/MacOS"
cp Spikes/backdrop/Info.plist "$app/Contents/Info.plist"

xcrun swiftc -swift-version 5 -O -D ATTIC_LOCAL_ONLY \
  -framework AppKit -framework ApplicationServices -framework ImageIO \
  -o "$app/Contents/MacOS/BackdropProbe" Spikes/backdrop/Probe.swift
codesign --force --sign - --entitlements Attic/AtticNotesLocal.entitlements "$app"
codesign -d --entitlements :- "$app" > "$out/signature-entitlements.plist" 2> "$out/signature.log"
plutil -lint "$out/signature-entitlements.plist"

# LaunchServices gives the app its own GUI responsibility/TCC identity, while
# direct execution from SSH can inherit the SSH caller's privacy state.
if [[ "${1:-}" == '--launchservices' ]]; then
  own="$HOME/Library/Containers/org.atticbackdrop.probeNoConsent20261111/Data/backdrop-spike-observations.json"
  /usr/bin/open -n -a "$app"
  for attempt in {1..18}; do
    [[ -s "$own" ]] && break
    /bin/sleep 1
  done
  [[ -s "$own" ]] || { print -u2 'LaunchServices probe did not write its own sandbox evidence'; exit 7; }
  cp "$own" "$out/observations-launchservices.json"
  for attempt in {1..12}; do
    /usr/bin/pgrep -x BackdropProbe >/dev/null || break
    /bin/sleep 1
  done
  /usr/bin/pgrep -x BackdropProbe >/dev/null && { print -u2 'Probe still running'; exit 8; }
else
  "$app/Contents/MacOS/BackdropProbe"
fi
df -h /
