#!/bin/zsh
# Recheck only the confirmed Draw library fix on the same seeded board.
# Caller holds the Air slot and screen lock; all taps verify live AX targets.
set -euo pipefail
cd "${0:A:h:h}"
hid=.build/clicklag4-hid
log="$HOME/Library/Containers/com.taha.Attic.preview.clicklag4/Data/Library/Application Support/Attic/Diagnostics/first-touch.jsonl"
captures=.build/clicklag4-captures-fixed
/bin/mkdir -p "$captures"

tap() { "$hid" tap "$1" 1; }
pass() {
    local label="$1"
    for i in {1..20}; do
        tap draw-title
        tap draw-library-row-canvas-
    done
    /bin/cp "$log" "$captures/$label-draw-library.jsonl"
    echo "CAPTURE $label-draw-library $(/usr/bin/wc -l < "$captures/$label-draw-library.jsonl") records"
}

tap panel-section-canvas
pass steady
tap panel-section-tasks
tap panel-section-canvas
pass after-page-switch
