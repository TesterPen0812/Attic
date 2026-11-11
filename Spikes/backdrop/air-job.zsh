#!/bin/zsh
set -u
job="$HOME/Projects/attic/attic-air/.build/jobs/attic-px-iphone-taskselect"
cd "$job" || exit 2
log="$job/.build/backdrop-spike-run.log"
"$HOME/Projects/attic/attic-air/.build/air-slot.zsh" /bin/zsh Spikes/backdrop/run-air.zsh > "$log" 2>&1
exit_code=$?
if (( exit_code == 0 )); then
  sed -n 's/^EVIDENCE_JSON=//p' "$log" > "$job/.build/backdrop-spike/observations.json"
fi
print "JOB_EXIT=$exit_code" >> "$log"
exit $exit_code
