#!/bin/zsh
set -u
job="$HOME/Projects/attic/attic-air/.build/jobs/attic-px-iphone-taskselect"
cd "$job" || exit 2
log="$job/.build/backdrop-spike-open-run.log"
"$HOME/Projects/attic/attic-air/.build/air-slot.zsh" /bin/zsh Spikes/backdrop/run-air.zsh --launchservices > "$log" 2>&1
exit_code=$?
print "JOB_EXIT=$exit_code" >> "$log"
exit $exit_code
