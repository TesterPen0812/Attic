#!/bin/zsh
# Run on the Air, inside both air-slot.zsh and /tmp/attic-screen.lock.
# The first-touch log and every edited item belong to the disposable clicklag4 preview.
set -euo pipefail

cd "${0:A:h:h}"
hid=.build/clicklag4-hid
log="$HOME/Library/Containers/com.taha.Attic.preview.clicklag4/Data/Library/Application Support/Attic/Diagnostics/first-touch.jsonl"
captures=.build/clicklag4-captures
/bin/mkdir -p "$captures"

tap() { "$hid" tap "$1" 1 >/dev/null }
point() { "$hid" tap-point "$1" "$2" 1 >/dev/null }
capture() {
    /bin/cp "$log" "$captures/$1.jsonl"
    /bin/echo "CAPTURE $1 $(/usr/bin/wc -l < "$captures/$1.jsonl") records"
}

taskPass() {
    local label="$1"
    tap tasks-page-now
    for (( i=1; i<=20; i++ )); do point 1225 334; done
    capture "${label}-row-tick"
    for (( i=1; i<=20; i++ )); do point 1310 334; done
    capture "${label}-row-select"
    for (( i=1; i<=20; i++ )); do tap tasks-tag-bar-design; done
    capture "${label}-tag-filter"
    for (( i=1; i<=20; i++ )); do
        tap tasks-page-backlog
        tap tasks-page-now
    done
    capture "${label}-now-later"
    for (( i=1; i<=20; i++ )); do
        tap tasks-page-done
        tap tasks-page-now
    done
    capture "${label}-now-done"
}

notesPass() {
    local label="$1"
    for (( i=1; i<=20; i++ )); do
        tap notes-library-row
        tap notes-all-notes
    done
    capture "${label}-note-open-library"
    tap notes-library-row
    for (( i=1; i<=20; i++ )); do
        tap notes-format-button
        tap notes-format-row-close
    done
    capture "${label}-note-format"
    tap notes-all-notes
}

case "${1:-}" in
    tasks)
        taskPass steady
        tap panel-section-notes
        tap panel-section-tasks
        taskPass after-page-switch
        ;;
    notes)
        notesPass steady
        tap panel-section-tasks
        tap panel-section-notes
        notesPass after-page-switch
        ;;
    *) /bin/echo 'Usage: clicklag4_series.zsh tasks|notes' >&2; exit 2 ;;
esac
