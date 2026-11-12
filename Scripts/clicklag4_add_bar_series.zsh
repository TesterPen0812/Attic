#!/bin/zsh
# Real HID on the isolated clicklag4 demo preview. Caller holds Air slot and screen lock.
set -euo pipefail
cd "${0:A:h:h}"
hid=.build/clicklag4-hid
log="$HOME/Library/Containers/com.taha.Attic.preview.clicklag4/Data/Library/Application Support/Attic/Diagnostics/first-touch.jsonl"
captures=.build/clicklag4-captures

tap() { "$hid" tap "$1" 1; }
pass() {
    local label="$1"
    tap tasks-new-task
    tap composer-title
    for i in {1..20}; do
        "$hid" type "CL4 disposable $label task $i"
        "$hid" return 1
    done
    /bin/cp "$log" "$captures/$label-add-bar.jsonl"
    echo "CAPTURE $label-add-bar $(/usr/bin/wc -l < "$captures/$label-add-bar.jsonl") records"
}

tap panel-section-tasks
pass steady
tap panel-section-notes
tap panel-section-tasks
pass after-page-switch
