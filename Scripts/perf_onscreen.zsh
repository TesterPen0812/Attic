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
#   --max-seconds <n>    hard time box for the whole gate (default 170)
#   --quit-running       quit an instance of a build that is already running
#                        (otherwise the gate stops and touches nothing)
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
# baseline. No Instruments template is used.
set -u
setopt pipefail

readonly root=${0:A:h:h}
baseline="" candidate="" rounds=2 out="" sign=1 post=hid max_seconds=170 quit_running=0
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
        -h|--help) sed -n '2,32p' $0; exit 0 ;;
        *) print -u2 "unknown option $1"; exit 2 ;;
    esac
done
[[ -d $baseline && -d $candidate ]] || { print -u2 "usage: $0 --baseline <app> --candidate <app> [--rounds n]"; exit 2 }
[[ $post == hid || $post == pid ]] || { print -u2 "--post is hid or pid"; exit 2 }
[[ -n $out ]] || out=$root/.build/perf-onscreen/$(date +%Y%m%d-%H%M%S)
mkdir -p $out

bundle_id() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" }
readonly base_id=$(bundle_id $baseline) cand_id=$(bundle_id $candidate)
for id in $base_id $cand_id; do
    [[ $id == com.taha.Attic.preview.* ]] || { print -u2 "only preview identities (com.taha.Attic.preview.*), not $id"; exit 2 }
done

# The driver, built for this run.
readonly drive=$out/perf_onscreen_drive
swiftc -O -o $drive $root/Scripts/perf_onscreen_drive.swift || { print -u2 "could not build the driver"; exit 2 }

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

readonly started=$SECONDS
current_id=""
samplers=()
cleanup() {
    (( ${#samplers} )) && kill $samplers 2>/dev/null
    [[ -n $current_id ]] && $drive quit $current_id >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

# One run: launch, settle, drive, sample, quit.
run() {
    local label=$1 app=$2 id=$3
    local file=$out/$label
    current_id=$id
    # The picker opens after the drive (about 18 s after it starts), and
    # closes 1.5 s later.
    open -n --env ATTIC_UI_TESTING=1 --env ATTIC_UI_TEST_SEED=long --env ATTIC_FRAME_MONITOR=1 \
        --env ATTIC_UI_TEST_META=date@27 --env ATTIC_UI_TEST_META_CLOSE=1.5 \
        --stdout $file.frames --stderr /dev/null $app
    local pid=""
    for _ in {1..40}; do pid=$($drive pid $id 2>/dev/null) && break; sleep 0.25; done
    [[ -n $pid && $pid != NONE ]] || { print "$label: did not launch"; return 1 }
    sleep 4
    local ws=$(pgrep -x WindowServer | head -1)
    top -l 30 -s 1 -stats pid,command,cpu -o cpu -n 40 > $file.top &
    local top_job=$!
    ( for _ in {1..58}; do
          print -n "GPU $(perl -MTime::HiRes=time -e 'printf "%.3f", time') "
          ioreg -r -d 1 -c IOAccelerator | grep -o '"[A-Za-z]* Utilization %"=[0-9]*' | head -3 | tr '\n' ' '
          print
          sleep 0.5
      done ) > $file.gpu &
    local gpu_job=$!
    samplers=($top_job $gpu_job)
    sleep 1
    $drive drive $id $sign $post > $file.drive
    local drive_status=$?
    # The picker's open and close (the app's own seam), then the samplers end.
    sleep 9
    kill $top_job $gpu_job 2>/dev/null; wait $top_job $gpu_job 2>/dev/null
    samplers=()
    print "ws=$ws app=$pid" >> $file.drive
    $drive quit $id >/dev/null
    current_id=""
    print "$label: $(grep -E '^(DONE|ABORT|NO_)' $file.drive | head -1) (drive exit $drive_status)"
    sleep 1
}

for (( n = 1; n <= rounds; n++ )); do
    for pair in "baseline $baseline $base_id" "candidate $candidate $cand_id"; do
        set -- ${=pair}
        if (( SECONDS - started > max_seconds - 35 )); then
            print "time box reached ($max_seconds s): stopping before $1-$n"
            break 2
        fi
        run $1-$n $2 $3 || break 2
        if grep -q '^ABORT' $out/$1-$n.drive; then print "stopped: the panel was covered or moved"; break 2; fi
    done
done

print "\nBaseline:  $baseline ($base_id)\nCandidate: $candidate ($cand_id)\nRuns:      $out ($(( SECONDS - started )) s)"
python3 $root/Scripts/perf_onscreen_analyze.py $out baseline candidate | tee $out/table.md
