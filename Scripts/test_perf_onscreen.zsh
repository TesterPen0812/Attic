#!/bin/zsh
# Headless checks of the on-screen gate's shell and driver
# (`Scripts/perf_onscreen.zsh`). Nothing here launches an app, posts input
# or touches the screen: the run plan is printed with --dry-run, the driver is
# only asked to refuse, and the signal and deadline paths run against a
# stand-in compiler that just sleeps.
#
#   Scripts/test_perf_onscreen.zsh
set -u
readonly root=${0:A:h:h}
readonly gate=$root/Scripts/perf_onscreen.zsh
tmp=$(mktemp -d); tmp=${tmp:A}  # the gate resolves paths (/var is /private/var)
trap 'rm -rf $tmp' EXIT
failures=0
check() { # check <description> <command...>
    local what=$1; shift
    if "$@"; then print "ok   $what"; else print "FAIL $what"; failures=$(( failures + 1 )); fi
}
is() { [[ $1 == $2 ]] }
differs() { [[ $1 != $2 ]] }

# Two copies of a stand-in app bundle, in a directory whose names hold spaces.
fake_app() { # fake_app <path> <bundle id>
    mkdir -p "$1/Contents"
    cat > "$1/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>$2</string></dict></plist>
PLIST
}
dir="$tmp/Apps With Spaces"
fake_app "$dir/Attic Base A.app" com.taha.Attic.preview.base
fake_app "$dir/Attic Cand B.app" com.taha.Attic.preview.cand

# 1. The plan keeps every path and identifier whole.
plan=$("$gate" --baseline "$dir/Attic Base A.app" --candidate "$dir/Attic Cand B.app" --rounds 2 --out "$tmp/out" --dry-run 2>&1)
check "a dry run exits 0" is $? 0
rows=("${(@f)$(print -r -- $plan | grep -E '^(baseline|candidate)-')}")
check "four runs are planned, A B A B" is "${#rows}" 4
want=(
    "baseline-1"$'\t'"$dir/Attic Base A.app"$'\t'"com.taha.Attic.preview.base"
    "candidate-1"$'\t'"$dir/Attic Cand B.app"$'\t'"com.taha.Attic.preview.cand"
    "baseline-2"$'\t'"$dir/Attic Base A.app"$'\t'"com.taha.Attic.preview.base"
    "candidate-2"$'\t'"$dir/Attic Cand B.app"$'\t'"com.taha.Attic.preview.cand"
)
for i in 1 2 3 4; do check "plan row $i is not split on spaces" is "${rows[$i]}" "${want[$i]}"; done
check "a dry run creates and compiles nothing" test ! -e "$tmp/out"

# 2. Only preview identities.
fake_app "$dir/Official.app" com.taha.Attic
fake_app "$dir/Bare Prefix.app" com.taha.Attic.preview.
for bad in "Official.app" "Bare Prefix.app"; do
    "$gate" --baseline "$dir/$bad" --candidate "$dir/Attic Cand B.app" --dry-run >/dev/null 2>&1
    check "$bad as the baseline is refused (exit 2)" is $? 2
    "$gate" --baseline "$dir/Attic Base A.app" --candidate "$dir/$bad" --dry-run >/dev/null 2>&1
    check "$bad as the candidate is refused (exit 2)" is $? 2
done

# 3. The driver refuses every command for any other identity (nothing is
# looked up, quit or driven).
swiftc -O -o "$tmp/drive" "$root/Scripts/perf_onscreen_drive.swift" 2>/dev/null
check "the driver compiles" test -x "$tmp/drive"
for id in "" com.taha.Attic com.apple.finder com.taha.Attic.preview. com.taha.Attic.previewish; do
    for command in pid quit drive; do
        out=$("$tmp/drive" $command "$id" 2>&1); code=$?
        check "driver '$command' refuses '$id'" is "$code:${out%%:*}" "2:REFUSED"
    done
done
"$tmp/drive" pid com.taha.Attic.preview.no-such-build >/dev/null 2>&1
check "a preview identity that is not running is just not found (exit 1)" is $? 1

# 4. Signals and the deadline, with a stand-in compiler: the gate is killed
# while it waits for it, and must clean up and leave nothing behind.
mkdir -p "$tmp/bin"
printf '#!/bin/sh\nexec sleep 31.7\n' > "$tmp/bin/swiftc"; chmod +x "$tmp/bin/swiftc"
gate_run() { PATH="$tmp/bin:$PATH" "$gate" --baseline "$dir/Attic Base A.app" --candidate "$dir/Attic Cand B.app" --out "$tmp/sig" "$@" }
pkill -f "sleep 31.7" 2>/dev/null
# (A background job of a non-interactive shell ignores SIGINT, so python
# starts the gate and signals it.)
signal_gate() { # signal_gate <INT|TERM> -> the gate's exit status
    PATH="$tmp/bin:$PATH" python3 - "$1" "$gate" "$dir/Attic Base A.app" "$dir/Attic Cand B.app" "$tmp/sig" <<'PY'
import signal, subprocess, sys, time
name, gate, base, cand, out = sys.argv[1:]
gate = subprocess.Popen([gate, "--baseline", base, "--candidate", cand, "--out", out],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1.5)
gate.send_signal(getattr(signal, "SIG" + name))
sys.exit(gate.wait(timeout=30))
PY
}
for signal_case in "INT:130" "TERM:143"; do
    name=${signal_case%%:*} expected=${signal_case##*:}
    signal_gate $name; code=$?
    check "$name stops the gate with $expected" is $code $expected
    check "$name leaves no compiler behind" test -z "$(pgrep -f 'sleep 31.7')"
done
start=$SECONDS
gate_run --max-seconds 2 >/dev/null 2>&1; code=$?
check "the hard deadline stops the gate with 124 (it covers the compilation)" is $code 124
check "the deadline stops it at once, not after the compiler" test $(( SECONDS - start )) -lt 12
check "the deadline leaves no compiler behind" test -z "$(pgrep -f 'sleep 31.7')"

print
if (( failures )); then print "$failures check(s) failed"; exit 1; fi
print "all checks passed"
