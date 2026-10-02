#!/bin/zsh
# The on-screen performance gate (owner, 2026-10-01: performance is a
# headline feature; headless timing tests are only an early warning). It
# needs the screen for about two minutes: run it only when nobody is using
# the Mac. It never runs as part of a build or a test.
#
#   Scripts/perf_onscreen.zsh --baseline <app> --candidate <app> [options]
#
#   --baseline <app>     the last accepted build (an optimized preview .app)
#   --candidate <app>    the build under test
#   --rounds <n>         interleaved rounds, baseline then candidate (2: A B A B)
#   --out <dir>          the parent of the runs (default .build/perf-onscreen). Each
#                        invocation makes its own new child, <out>/<time>-<pid>,
#                        and the table reads only that: files of an earlier
#                        invocation can never count for this one, and none is
#                        ever deleted
#   --baseline-env KEY=VALUE, --candidate-env KEY=VALUE
#                        an extra environment variable for that side's app, so
#                        one build can be A/B-ed against itself (for instance
#                        --candidate-env ATTIC_UI_TEST_SCROLL_EDGES=clean).
#                        Repeatable. Only ATTIC_UI_TEST_* keys, and not the
#                        ones the gate sets itself (_SEED, _META, _META_CLOSE)
#   --swipe-sign <1|-1>  which horizontal sign is "next page" (1 by default)
#   --post <hid|pid>     events through the HID tap (as a trackpad, default) or
#                        to the app's process only
#   --max-seconds <n>    hard deadline for the whole gate, setup and the
#                        driver's compilation included (default 170): a
#                        watchdog started first stops everything, and the preview
#                        is quit within a bounded 8 s
#   --no-picker          do not open a row's date picker during the run
#                        (ATTIC_UI_TEST_META is not set), for a fair comparison
#                        with a build that ignores it
#   --quit-running       quit an instance of a build that is already running
#                        (otherwise the gate stops and touches nothing)
#   --dry-run            resolve the two bundle identifiers and print the run
#                        plan, then stop: nothing is compiled, launched or
#                        sampled, and the screen is not touched
#
# Exit status: 0 only when every required paired run was valid; 1 when the
# comparison is INCOMPLETE (a run aborted, saw no input, or lacked frames or
# GPU samples: see the analyzer); 2 for a bad invocation; 3 at a locked
# screen; 124 at the hard deadline; 130 and 143 when interrupted.
#
# Each run launches one build by path with ATTIC_UI_TESTING=1 (an in-memory
# store, the panel kept on screen), ATTIC_UI_TEST_SEED=long and
# ATTIC_FRAME_MONITOR=1 (a display-link frame log on standard output), then
# `perf_onscreen_drive` (compiled here) posts phased trackpad scrolls and
# page swipes over that build's panel, found by its bundle identifier, and
# the app opens a row's date picker by itself (`ATTIC_UI_TEST_META`) and
# closes it. Meanwhile `top -l` samples the app's and WindowServer's CPU and
# `ioreg` the GPU's utilization every 0.5 s. The app is quit afterwards, by
# its bundle identifier. The table: missed frames, worst frame, p95, the
# picker's worst frame, app and WindowServer CPU, GPU mean and peak, per run,
# per build with the run-to-run spread, and the candidate against the
# baseline. A run counts only if the driver exited 0, both phases were
# marked, frames and GPU samples were recorded and the app echoed input;
# any other run is shown as a diagnostic and kept out of the means and deltas.
# No Instruments template is used.
set -u
setopt pipefail extendedglob
zmodload zsh/datetime

readonly root=${0:A:h:h}
readonly started=$SECONDS
baseline="" candidate="" rounds=2 out="" sign=1 post=hid max_seconds=170 quit_running=0 dry_run=0 no_picker=0
baseline_env=() candidate_env=()   # "--env" "KEY=VALUE" pairs, ready for `open`
gate_keys=(ATTIC_UI_TEST_SEED ATTIC_UI_TEST_META ATTIC_UI_TEST_META_CLOSE)

# An extra environment variable for one side: ATTIC_UI_TEST_* only, none of
# the gate's own, a single line.
extra_env() { # extra_env <baseline|candidate> <KEY=VALUE>
    local pair=$2 key=${2%%=*}
    [[ $pair == *=* && $key == ATTIC_UI_TEST_[A-Z0-9_]## && $pair != *$'\n'* ]] \
        || { print -u2 -- "--$1-env takes KEY=VALUE with an ATTIC_UI_TEST_* key, not '$pair'"; exit 2 }
    (( ${gate_keys[(Ie)$key]} )) && { print -u2 -- "--$1-env: $key is set by the gate itself"; exit 2 }
    if [[ $1 == baseline ]]; then baseline_env+=(--env "$pair"); else candidate_env+=(--env "$pair"); fi
}

while (( $# > 0 )); do
    case $1 in
        -h|--help) sed -n '2,58p' $0; exit 0 ;;
        --quit-running) quit_running=1; shift; continue ;;
        --dry-run) dry_run=1; shift; continue ;;
        --no-picker) no_picker=1; shift; continue ;;
        --baseline|--candidate|--rounds|--out|--swipe-sign|--post|--max-seconds|--baseline-env|--candidate-env)
            (( $# >= 2 )) || { print -u2 -- "$1 needs a value"; exit 2 } ;;
        *) print -u2 "unknown option $1"; exit 2 ;;
    esac
    case $1 in
        --baseline) baseline=${2:A} ;;
        --candidate) candidate=${2:A} ;;
        --rounds) rounds=$2 ;;
        --out) out=${2:A} ;;
        --swipe-sign) sign=$2 ;;
        --post) post=$2 ;;
        --max-seconds) max_seconds=$2 ;;
        --baseline-env) extra_env baseline "$2" ;;
        --candidate-env) extra_env candidate "$2" ;;
    esac
    shift 2
done

readonly drive_name=perf_onscreen_drive
drive="" driver_pid="" watchdog_pid="" current_id=""
samplers=() children=()

# Everything the gate started, stopped in this order: the driver first (no
# synthetic input outlives the gate), then the samplers and any other child,
# then the preview, quit by its bundle identifier within a bounded 8 s (what
# is started here inherits the ignored signals, so it is stopped with KILL).
# Runs on every exit.
cleanup() {
    trap '' INT TERM USR1
    [[ -n $driver_pid ]] && kill $driver_pid 2>/dev/null
    (( ${#samplers} )) && kill $samplers 2>/dev/null
    (( ${#children} )) && kill $children 2>/dev/null
    [[ -n $watchdog_pid ]] && kill $watchdog_pid 2>/dev/null
    if [[ -n $current_id && -x $drive ]]; then
        $drive quit $current_id >/dev/null 2>&1 &
        local quitter=$!
        ( sleep 8; kill -KILL $quitter 2>/dev/null ) >/dev/null 2>&1 &
        local timer=$!
        wait $quitter 2>/dev/null
        kill -KILL $timer 2>/dev/null
    fi
    return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'print -u2 "hard deadline ($max_seconds s) reached: stopped, the preview quit"; exit 124' USR1

# The hard deadline, started before any slow step: it covers everything from
# the start of the gate, the driver's compilation included.
(
    trap - EXIT INT TERM USR1
    while (( SECONDS < started + max_seconds )); do sleep 1; done
    kill -USR1 $$
) &
watchdog_pid=$!

# zsh runs a trap only when a foreground command ends, so no step that can
# block runs in the foreground: each is a tracked child the gate waits for, and
# a signal (the deadline's included) is handled at once and cancels it.
wait_for() {
    "$@" &
    local child=$!
    children+=($child)
    wait $child
    local status_of_child=$?
    children=(${children:#$child})
    return $status_of_child
}
nap() { wait_for sleep $1 }
# capture <variable> <command...>: the command's output, from a tracked child.
# Nothing here runs in the foreground: the scratch file's name is made by the
# shell, it is read by a builtin, and its removal is a tracked child too.
capture_count=0
capture() {
    local variable=$1; shift
    local file=${TMPDIR:-/tmp}/perf_onscreen.$$.$(( ++capture_count ))
    wait_for "$@" > $file 2>/dev/null
    local status_of_command=$?
    typeset -g $variable="$(<$file)"
    wait_for rm -f $file
    return $status_of_command
}

[[ -d $baseline && -d $candidate ]] || { print -u2 "usage: $0 --baseline <app> --candidate <app> [--rounds n]"; exit 2 }
[[ $post == hid || $post == pid ]] || { print -u2 "--post is hid or pid"; exit 2 }
[[ $rounds == <1-> && $max_seconds == <1-> ]] || { print -u2 "--rounds and --max-seconds are positive integers"; exit 2 }
[[ -n $out ]] || out=$root/.build/perf-onscreen

bundle_id() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" }
capture base_id bundle_id $baseline
capture cand_id bundle_id $candidate
for id in $base_id $cand_id; do
    [[ $id == com.taha.Attic.preview.?* ]] || { print -u2 "only preview identities (com.taha.Attic.preview.*), not '$id'"; exit 2 }
done

# The two builds by name, so a path or an identifier is never split on
# whitespace: every use below quotes its element.
typeset -A app_of=(baseline "$baseline" candidate "$candidate")
typeset -A id_of=(baseline "$base_id" candidate "$cand_id")
# This invocation's own, new directory: nothing of an earlier invocation is
# ever read by it, and nothing is ever deleted.
strftime -s stamp %Y%m%d-%H%M%S $EPOCHSECONDS
readonly run_dir=$out/$stamp-$$

if (( dry_run )); then
    print "Baseline:  $baseline ($base_id)\nCandidate: $candidate ($cand_id)\nRuns in:   $run_dir\nPicker:    $( (( no_picker )) && print off || print on)\nPlan (label, app, bundle identifier, extra environment; tab-separated):"
    for (( n = 1; n <= rounds; n++ )); do
        for who in baseline candidate; do
            env_name=${who}_env
            extra=("${(@P)env_name}")
            print -r -- "$who-$n"$'\t'"${app_of[$who]}"$'\t'"${id_of[$who]}"$'\t'"${(j: :)${(@)extra:#--env}}"
        done
    done
    exit 0
fi
wait_for mkdir -p $out && wait_for mkdir $run_dir || { print -u2 "could not make a new run directory $run_dir"; exit 2 }
readonly drive=$run_dir/$drive_name

# The driver, built for this run.
wait_for swiftc -O -o $drive $root/Scripts/perf_onscreen_drive.swift || { print -u2 "could not build the driver"; exit 2 }

for id in $base_id $cand_id; do
    if wait_for $drive pid $id >/dev/null 2>&1; then
        if (( quit_running )); then wait_for $drive quit $id >/dev/null
        else print -u2 "$id is running: quit it first (or pass --quit-running)"; exit 2; fi
    fi
done

# A locked screen takes no synthetic input and idles the GPU: the table would
# be empty but look like a pass.
screen_locked() {
    local info
    capture info ioreg -n Root -d1 -a
    [[ $info == *CGSSessionScreenIsLocked'</key>'[[:space:]]#'<true/>'* ]]
}
if screen_locked; then print -u2 "the screen is locked: run the gate at an unlocked, idle Mac"; exit 3; fi

# One run: launch, settle, drive, sample, quit. Returns the driver's status
# (0 only for a complete drive), or 1 when it never got that far.
run() {
    local label=$1 app=$2 id=$3 who=${1%-*}
    local file=$run_dir/$label
    local env_name=${who}_env
    local -a extra=("${(@P)env_name}")
    current_id=$id
    # The picker (unless --no-picker) opens after the drive (about 18 s after
    # it starts), and closes 1.5 s later.
    local -a picker=(--env ATTIC_UI_TEST_META=date@27 --env ATTIC_UI_TEST_META_CLOSE=1.5)
    (( no_picker )) && picker=()
    wait_for open -n --env ATTIC_UI_TESTING=1 --env ATTIC_UI_TEST_SEED=long --env ATTIC_FRAME_MONITOR=1 \
        "${picker[@]}" "${extra[@]}" \
        --stdout $file.frames --stderr /dev/null "$app"
    local pid=""
    for _ in {1..40}; do capture pid $drive pid $id && break; nap 0.25; done
    [[ -n $pid && $pid != NONE ]] || { print "$label: did not launch"; return 1 }
    nap 4
    local ws
    capture ws pgrep -x WindowServer
    ws=${ws%%$'\n'*}
    [[ -n $ws ]] || { print "$label: no WindowServer process"; return 1 }
    # Both processes in one top (it takes -pid twice): a process that is
    # not in a sample is a missing value for the analyzer, never a zero.
    top -l 30 -s 1 -stats pid,command,cpu -pid $pid -pid $ws > $file.top &
    local top_job=$!
    ( trap - EXIT INT TERM USR1
      for _ in {1..58}; do
          print -n "GPU $(perl -MTime::HiRes=time -e 'printf "%.3f", time') "
          ioreg -r -d 1 -c IOAccelerator | grep -o '"[A-Za-z]* Utilization %"=[0-9]*' | head -3 | tr '\n' ' '
          print
          sleep 0.5
      done ) > $file.gpu &
    local gpu_job=$!
    samplers=($top_job $gpu_job)
    nap 1
    $drive drive $id $sign $post > $file.drive &
    driver_pid=$!
    wait $driver_pid
    local drive_status=$?
    driver_pid=""
    # The picker's open and close (the app's own seam), then the samplers end.
    nap 9
    kill $top_job $gpu_job 2>/dev/null; wait $top_job $gpu_job 2>/dev/null
    samplers=()
    print "ws=$ws app=$pid drive_exit=$drive_status" >> $file.drive
    wait_for $drive quit $id >/dev/null
    current_id=""
    local outcome
    capture outcome grep -E '^(DONE|ABORT|NO_)' $file.drive
    print "$label: ${outcome%%$'\n'*} (drive exit $drive_status)"
    nap 1
    return $drive_status
}

for (( n = 1; n <= rounds; n++ )); do
    for who in baseline candidate; do
        if (( SECONDS - started > max_seconds - 35 )); then
            print "time box reached ($max_seconds s): stopping before $who-$n"
            break 2
        fi
        run "$who-$n" "${app_of[$who]}" "${id_of[$who]}" || { print "stopped: $who-$n did not complete (the panel was covered or moved, or the app did not start)"; break 2 }
    done
done

print "\nBaseline:  $baseline ($base_id)${baseline_env:+ with ${(j: :)${(@)baseline_env:#--env}}}\nCandidate: $candidate ($cand_id)${candidate_env:+ with ${(j: :)${(@)candidate_env:#--env}}}\nRuns:      $run_dir ($(( SECONDS - started )) s)"
wait_for python3 $root/Scripts/perf_onscreen_analyze.py $run_dir baseline candidate --rounds $rounds > $run_dir/table.md
analysis=$?
wait_for cat $run_dir/table.md
exit $analysis
