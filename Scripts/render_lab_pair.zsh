#!/bin/zsh
set -euo pipefail

# On the Air only: alternate single 30-second idle trials, relaunching the
# same isolated app for A, B, A, B ... so each trial has the requested flags.
readonly here=${0:A:h}
readonly app="$HOME/Projects/attic/attic-air/.build/render-dd/Build/Products/Local/AtticRenderLab.app"
readonly capture=/tmp/render-lab-pixels
readonly quit=/tmp/render-lab-quit
readonly bundle=com.taha.Attic.preview.renderlab
readonly lock=/tmp/attic-air-screen.lockdir/owner

if [[ $# -lt 5 || $# -gt 7 ]]; then
    print -u2 'usage: render_lab_pair.zsh NAME FLAG TARGET_ID WARM_ID CYCLES [SETUP_PAGE_ID] [run|scroll|toggle|dismiss]'
    exit 2
fi
readonly name="$1" flag="$2" target="$3" warm="$4" cycles="$5" setup="${6:-}" mode="${7:-run}"
[[ -f "$lock" && "$(/bin/cat "$lock")" == renderlab ]] || { print -u2 'Render lab does not own screen lock'; exit 3; }
[[ "$cycles" == <-> && "$cycles" -ge 2 && "$cycles" -le 12 ]] || exit 2
[[ "$mode" == run || "$mode" == scroll || "$mode" == toggle || "$mode" == dismiss ]] || exit 2
[[ -x "$capture" && -x "$quit" && -d "$app" ]] || exit 3
readonly out="/tmp/render-lab/$name"
/bin/mkdir -p "$out"
for index in $(/usr/bin/seq 1 $((cycles * 2))); do
    condition=base
    if (( index % 2 == 0 )); then condition=off; fi
    # An independent reverse-order batch checks for session/order confounding.
    if [[ "${ATTIC_LAB_PAIR_REVERSE:-0}" == 1 ]]; then
        if [[ "$condition" == base ]]; then condition=off; else condition=base; fi
    fi
    print "RUN name=$name index=$index condition=$condition load=$(/usr/bin/uptime)" | /usr/bin/tee -a "$out/sequence.log"
    "$quit" >> "$out/sequence.log" 2>&1
    launch_args=(--env ATTIC_UI_TESTING=1 --env ATTIC_UI_TEST_SEED=long
             --env ATTIC_PAGE_BENCH=1 --env ATTIC_FRAME_MONITOR=1 --env ATTIC_MOTION_BENCH=1)
    # FLAG is the complete environment variable; the combined trial uses
    # ATTIC_LAB_ALL_OFF while single-site trials use ATTIC_LAB_NO_... .
    if [[ "$condition" == off ]]; then launch_args+=(--env "$flag=1"); fi
    /usr/bin/open -n "${launch_args[@]}" "$app"
    /bin/sleep 3
    result="$out/${index}-${condition}.csv"
    args=("--$mode" "$target" "$warm" 30 1 "$result")
    if [[ -n "$setup" ]]; then args+=("$setup"); fi
    "$capture" "${args[@]}" >> "$out/sequence.log" 2>&1
done
"$quit" >> "$out/sequence.log" 2>&1
print "FINISHED name=$name files=$out" | /usr/bin/tee -a "$out/sequence.log"
