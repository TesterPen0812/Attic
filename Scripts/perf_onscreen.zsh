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
#   --out <dir>          where the runs and the table go (default .build/perf-onscreen/<time>)
#   --swipe-sign <1|-1>  which horizontal sign is "next page" (1 by default)
#   --post <hid|pid>     events through the HID tap (as a trackpad, default) or
#                        to the app's process only
#   --max-seconds <n>    hard deadline for the whole gate, setup and the
#                        driver's compilation included (default 170): a
#                        watchdog stops everything and quits the preview
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
setopt pipefail

readonly root=${0:A:h:h}
baseline="" candidate="" rounds=2 out="" sign=1 post=hid max_seconds=170 quit_running=0 dry_run=0
readonly started=$SECONDS
while (( $# > 0 )); do
    case $1 in
        --baseline) baseline=${2:A}; shift 2 ;;
        --candidate) candidate=${2:A}; shift 2 ;;
        --rounds) rounds=$2; shift 2 ;;
        --out) out=${2:A}; shift 2 ;;
        --swipe-sign) sign=$2; shift 2 ;;
        --post) post=$2; shift 2 ;;
        --max-seconds) max_seconds=$2; shift 2 ;;
        --quit-running) quit_running=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) sed -n '2,44p' $0; exit 0 ;;
        *) print -u2 "unknown option $1"; exit 2 ;;
    esac
done
[[ -d $baseline && -d $candidate ]] || { print -u2 "usage: $0 --baseline <app> --candidate <app> [--rounds n]"; exit 2 }
[[ $post == hid || $post == pid ]] || { print -u2 "--post is hid or pid"; exit 2 }
[[ $rounds == <1-> && $max_seconds == <1-> ]] || { print -u2 "--rounds and --max-seconds are positive integers"; exit 2 }
[[ -n $out ]] || out=$root/.build/perf-onscreen/$(date +%Y%m%d-%H%M%S)

bundle_id() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" }
readonly base_id=$(bundle_id $baseline) cand_id=$(bundle_id $candidate)
for id in $base_id $cand_id; do
    [[ $id == com.taha.Attic.preview.?* ]] || { print -u2 "only preview identities (com.taha.Attic.preview.*), not '$id'"; exit 2 }
done

# The two builds by name, so a path or an identifier is never split on
# whitespace: every use below quotes its element.
typeset -A app_of=(baseline "$baseline" candidate "$candidate")
typeset -A id_of=(baseline "$base_id" candidate "$cand_id")

if (( dry_run )); then
    print "Baseline:  $baseline ($base_id)\nCandidate: $candidate ($cand_id)\nOut:       $out\nPlan (label, app, bundle identifier; tab-separated):"
    for (( n = 1; n <= rounds; n++ )); do
        for who in baseline candidate; do
            print -r -- "$who-$n"$'\t'"${app_of[$who]}"$'\t'"${id_of[$who]}"
        done
    done
    exit 0
fi
mkdir -p $out

readonly drive=$out/perf_onscreen_drive
driver_pid="" watchdog_pid="" current_id=""
samplers=() children=()

# Everything the gate started, stopped in this order: the driver first (no
# synthetic input outlives the gate), then the samplers and any other child,
# then the preview, quit by its bundle identifier. Runs on every exit.
cleanup() {
    trap '' INT TERM USR1
    [[ -n $driver_pid ]] && kill $driver_pid 2>/dev/null
    (( ${#samplers} )) && kill $samplers 2>/dev/null
    (( ${#children} )) && kill $children 2>/dev/null
    [[ -n $watchdog_pid ]] && kill $watchdog_pid 2>/dev/null
    [[ -n $current_id && -x $drive ]] && $drive quit $current_id >/dev/null 2>&1
    return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'print -u2 "hard deadline ($max_seconds s) reached: stopped, the preview quit"; exit 124' USR1

# The hard deadline covers everything from the start of the gate, the
# driver's compilation included, and does not wait for a foreground command.
(
    trap - EXIT INT TERM USR1
    while (( SECONDS < started + max_seconds )); do sleep 1; done
    kill -USR1 $$
) &
watchdog_pid=$!

# zsh runs a trap only when a foreground command ends: run what can take
# time in the background and wait for it, so a signal is handled at once.
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

# The driver, built for this run.
wait_for swiftc -O -o $drive $root/Scripts/perf_onscreen_drive.swift || { print -u2 "could not build the driver"; exit 2 }

for id in $base_id $cand_id; do
    if $drive pid $id >/dev/null 2>&1; then
        if (( quit_running )); then $drive quit $id >/dev/null
        else print -u2 "$id is running: quit it first (or pass --quit-running)"; exit 2; fi
    fi
done

# A locked screen takes no synthetic input and idles the GPU: the table would
# be empty but look like a pass.
screen_locked() { ioreg -n Root -d1 -a 2>/dev/null | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>' }
if screen_locked; then print -u2 "the screen is locked: run the gate at an unlocked, idle Mac"; exit 3; fi

# One run: launch, settle, drive, sample, quit. Returns the driver's status
# (0 only for a complete drive), or 1 when it never got that far.
run() {
    local label=$1 app=$2 id=$3
    local file=$out/$label
    current_id=$id
    # The picker opens after the drive (about 18 s after it starts), and
    # closes 1.5 s later.
    open -n --env ATTIC_UI_TESTING=1 --env ATTIC_UI_TEST_SEED=long --env ATTIC_FRAME_MONITOR=1 \
        --env ATTIC_UI_TEST_META=date@27 --env ATTIC_UI_TEST_META_CLOSE=1.5 \
        --stdout $file.frames --stderr /dev/null "$app"
    local pid=""
    for _ in {1..40}; do pid=$($drive pid $id 2>/dev/null) && break; nap 0.25; done
    [[ -n $pid && $pid != NONE ]] || { print "$label: did not launch"; return 1 }
    nap 4
    local ws=$(pgrep -x WindowServer | head -1)
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
    $drive quit $id >/dev/null
    current_id=""
    print "$label: $(grep -E '^(DONE|ABORT|NO_)' $file.drive | head -1) (drive exit $drive_status)"
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

print "\nBaseline:  $baseline ($base_id)\nCandidate: $candidate ($cand_id)\nRuns:      $out ($(( SECONDS - started )) s)"
python3 $root/Scripts/perf_onscreen_analyze.py $out baseline candidate --rounds $rounds | tee $out/table.md
exit ${pipestatus[1]}
