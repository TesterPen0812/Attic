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
    "baseline-1"$'\t'"$dir/Attic Base A.app"$'\t'"com.taha.Attic.preview.base"$'\t'
    "candidate-1"$'\t'"$dir/Attic Cand B.app"$'\t'"com.taha.Attic.preview.cand"$'\t'
    "baseline-2"$'\t'"$dir/Attic Base A.app"$'\t'"com.taha.Attic.preview.base"$'\t'
    "candidate-2"$'\t'"$dir/Attic Cand B.app"$'\t'"com.taha.Attic.preview.cand"$'\t'
)
for i in 1 2 3 4; do check "plan row $i is not split on spaces" is "${rows[$i]}" "${want[$i]}"; done
check "a dry run creates and compiles nothing" test ! -e "$tmp/out"
check "the plan names a new run directory under --out" test -n "$(print -r -- $plan | grep -E "^Runs in:   $tmp/out/[0-9]{8}-[0-9]{6}-[0-9]+\$")"

# 1b. Extra environment for one side: quoted whole, ATTIC_UI_TEST_* only.
plan=$("$gate" --baseline "$dir/Attic Base A.app" --candidate "$dir/Attic Cand B.app" --rounds 1 --out "$tmp/out" --dry-run \
    --candidate-env "ATTIC_UI_TEST_SCROLL_EDGES=clean" --candidate-env "ATTIC_UI_TEST_NOTE=two words; \$HOME" --baseline-env ATTIC_UI_TEST_X=1 2>&1)
check "extra environment is accepted" is $? 0
check "the candidate row carries its variables, whole" test -n "$(print -r -- $plan | grep -F $'candidate-1\t'"$dir/Attic Cand B.app"$'\tcom.taha.Attic.preview.cand\tATTIC_UI_TEST_SCROLL_EDGES=clean ATTIC_UI_TEST_NOTE=two words; $HOME')"
check "the baseline row carries only its own" test -n "$(print -r -- $plan | grep -F $'baseline-1\t'"$dir/Attic Base A.app"$'\tcom.taha.Attic.preview.base\tATTIC_UI_TEST_X=1')"
for bad in "ATTIC_FRAME_MONITOR=1" "HOME=/tmp" "ATTIC_UI_TESTING=1" "ATTIC_UI_TEST_SEED=short" "ATTIC_UI_TEST_META=tags" "ATTIC_UI_TEST_META_CLOSE=2" "ATTIC_UI_TEST_x=1" "ATTIC_UI_TEST_=1" "ATTIC_UI_TEST_A" "ATTIC_UI_TEST_A=1"$'\n'"B=2"; do
    "$gate" --baseline "$dir/Attic Base A.app" --candidate "$dir/Attic Cand B.app" --dry-run --candidate-env "$bad" >/dev/null 2>&1
    check "environment '${bad//$'\n'/\\n}' is refused (exit 2)" is $? 2
done

# 1c. --no-picker is shown in the plan, and the default is the picker.
check "the picker is on by default" test -n "$(print -r -- $plan | grep -E '^Picker:    on$')"
plan_off=$("$gate" --baseline "$dir/Attic Base A.app" --candidate "$dir/Attic Cand B.app" --out "$tmp/out" --dry-run --no-picker 2>&1)
check "--no-picker turns it off" test -n "$(print -r -- $plan_off | grep -E '^Picker:    off$')"

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

# 5. The deadline also stops a step that blocks in what used to be the
# foreground: here the driver's `pid` query (the stand-in driver sleeps).
printf '#!/bin/sh\nout=\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done\nprintf "#!/bin/sh\\nexec sleep 31.9\\n" > "$out"; chmod +x "$out"\n' > "$tmp/bin/swiftc"
pkill -f "sleep 31.9" 2>/dev/null
start=$SECONDS
gate_run --max-seconds 2 >/dev/null 2>&1; code=$?
check "a blocked driver query is cut by the deadline (124)" is $code 124
check "within seconds, not the query's 32" test $(( SECONDS - start )) -lt 8
check "and leaves no query behind" test -z "$(pgrep -f 'sleep 31.9')"

# 6. Each invocation has its own new directory; nothing existing is touched.
mkdir -p "$tmp/sig/20200101-000000-1"; print old > "$tmp/sig/20200101-000000-1/baseline-1.drive"
before=$(ls "$tmp/sig" | wc -l)
gate_run --max-seconds 2 >/dev/null 2>&1
gate_run --max-seconds 2 >/dev/null 2>&1
check "two invocations made two new directories" is $(( $(ls "$tmp/sig" | wc -l) - before )) 2
check "an existing run directory is left as it was" is "$(cat "$tmp/sig/20200101-000000-1/baseline-1.drive")" old
check "and nothing of this invocation lands in --out itself" test -z "$(ls "$tmp/sig" | grep -v -E '^[0-9]{8}-[0-9]{6}-[0-9]+$')"

# 7. No step runs in the foreground, scratch-file creation included: with
# stand-ins for mktemp, date, rm, mkdir and cat that block, the gate is still
# cut at the deadline (the stand-ins that it runs are tracked children).
for tool in mktemp date rm mkdir cat; do
    printf '#!/bin/sh\nexec sleep 31.4\n' > "$tmp/bin/$tool"; chmod +x "$tmp/bin/$tool"
done
pkill -f "sleep 31.4" 2>/dev/null
start=$SECONDS
gate_run --max-seconds 2 --out "$tmp/blocked" >/dev/null 2>&1; code=$?
check "blocked helper tools are cut by the deadline (124)" is $code 124
check "within seconds" test $(( SECONDS - start )) -lt 8
check "and leave nothing behind" test -z "$(pgrep -f 'sleep 31.4')"
for tool in mktemp date rm mkdir cat; do rm -f "$tmp/bin/$tool"; done

print
if (( failures )); then print "$failures check(s) failed"; exit 1; fi
print "all checks passed"
