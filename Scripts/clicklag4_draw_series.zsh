#!/bin/zsh
# Real HID, disposable clicklag4 preview only. Hold air-slot and screen lock.
set -euo pipefail
cd "${0:A:h:h}"
hid=.build/clicklag4-hid
log="$HOME/Library/Containers/com.taha.Attic.preview.clicklag4/Data/Library/Application Support/Attic/Diagnostics/first-touch.jsonl"
captures=.build/clicklag4-captures
tap() { "$hid" tap "$1" 1; }
capture() {
    /bin/cp "$log" "$captures/$1.jsonl"
    echo "CAPTURE $1 $(/usr/bin/wc -l < "$captures/$1.jsonl") records"
}
pass() {
    local label="$1"
    tap draw-tool-select
    for i in {1..20}; do
        tap draw-tool-eraser
        tap draw-tool-select
    done
    capture "${label}-draw-tool"

    # The seeded 2,000-object board is an actual existing canvas row.
    for i in {1..20}; do
        tap draw-title
        tap draw-library-row-canvas-
    done
    capture "${label}-draw-library"

    # Create a single disposable dot per Undo, keeping the 2,000 objects.
    tap draw-tool-pen
    for i in {1..20}; do
        "$hid" tap-point 1360 430 1
        tap draw-undo
    done
    capture "${label}-draw-undo"
}

tap panel-section-canvas
pass steady
tap panel-section-tasks
tap panel-section-canvas
pass after-page-switch
