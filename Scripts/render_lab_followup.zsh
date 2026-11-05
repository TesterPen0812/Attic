#!/bin/zsh
set -euo pipefail

# Air-only. Started inside sshjobs tmux and serialized behind the existing
# renderlab-more screen experiment; never interact with another app identity.
readonly here=${0:A:h}
readonly app="$HOME/Projects/attic/attic-air/.build/render-dd/Build/Products/Local/AtticRenderLab.app"
cd "$here/.."
[[ "$(/bin/cat /tmp/attic-air-screen.lockdir/owner 2>/dev/null)" == renderlab ]] || exit 3

while /opt/homebrew/bin/tmux -L sshjobs has-session -t renderlab-more 2>/dev/null; do
    /bin/sleep 5
done
[[ "$(/usr/bin/tail -n 1 /tmp/renderlab-more-retry.log)" == STATUS=0 ]] || {
    print -u2 'Prior batch incomplete; refusing overlapping screen work'
    exit 4
}

print "FOLLOWUP start load=$(/usr/bin/uptime)"
/usr/bin/swiftc -O Scripts/render_lab_pixels.swift -o /tmp/render-lab-pixels

/tmp/render-lab-quit
/usr/bin/open -n --env ATTIC_UI_TESTING=1 --env ATTIC_UI_TEST_SEED=long "$app"
/bin/sleep 3
/tmp/render-lab-pixels --run --dump-all tasks-page-now 0 1 /tmp/render-lab/row-ids.csv panel-section-tasks > /tmp/renderlab-row-ids.txt
/tmp/render-lab-pixels --toggle tasks-find-button tasks-find-button 1 1 /tmp/render-lab/search-smoke.csv panel-section-tasks
/tmp/render-lab-quit

/usr/bin/open -n --env ATTIC_UI_TESTING=1 --env ATTIC_UI_TEST_SEED=long "$app"
/bin/sleep 3
/tmp/render-lab-pixels --dismiss tasks-new-task tasks-new-task 1 1 /tmp/render-lab/plus-smoke.csv panel-section-tasks
/tmp/render-lab-quit

print "SMOKE OK; reversing shadow order load=$(/usr/bin/uptime)"
ATTIC_LAB_PAIR_REVERSE=1 zsh Scripts/render_lab_pair.zsh island-shadow-reverse ATTIC_LAB_NO_ISLAND_SHADOW panel-section-notes panel-section-tasks 4
print "REVERSE COMPLETE; starting action paths load=$(/usr/bin/uptime)"
zsh Scripts/render_lab_matrix.zsh paths
print 'FOLLOWUP COMPLETE'
