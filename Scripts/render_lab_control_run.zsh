#!/bin/zsh
set -euo pipefail

# Run only in an Air SSH-started tmux; captures the small control's window.
readonly lock=/tmp/attic-air-screen.lockdir/owner
[[ -f "$lock" && "$(/bin/cat "$lock")" == renderlab ]] || exit 3
readonly control=/tmp/render-lab-control/RenderLabControl.app
readonly capture=/tmp/render-lab-pixels
readonly idle="${1:-30}"
readonly rounds="${2:-5}"
[[ -d "$control" && -x "$capture" ]] || exit 3
[[ "$idle" == <-> && "$idle" -le 60 && "$rounds" == <-> && "$rounds" -ge 1 && "$rounds" -le 12 ]] || exit 2

trap '/tmp/render-lab-quit --control || true' EXIT
/tmp/render-lab-quit
/usr/bin/open -n "$control"
/bin/sleep 3
ATTIC_LAB_CONTROL=1 "$capture" --run render-control-toggle render-control-toggle "$idle" "$rounds" "/tmp/render-lab/control.csv"
