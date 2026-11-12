#!/bin/zsh
# Air only. Caller holds air-slot.zsh and /tmp/attic-screen.lock.
set -euo pipefail
cd "${0:A:h:h}"
hid=.build/clicklag4-hid
log="$HOME/Library/Containers/com.taha.Attic.preview.clicklag4/Data/Library/Application Support/Attic/Diagnostics/first-touch.jsonl"
captures=.build/clicklag4-captures

tap() { "$hid" tap "$1" 1; }
menu() {
    tap panel-more-button
    "$hid" tap-point 1290 "$1" 1
}
capture() {
    /bin/cp "$log" "$captures/$1.jsonl"
    echo "CAPTURE $1 $(/usr/bin/wc -l < "$captures/$1.jsonl") records"
}
ensureEventVisible() {
    local event=calendar-event-clicklag4-2-0 line position y
    for attempt in {1..8}; do
        line=$("$hid" inspect-all | /usr/bin/grep "id=$event |" | /usr/bin/head -1)
        [[ -n "$line" ]] || { echo "EVENT_NOT_IN_ACCESSIBILITY" >&2; return 1; }
        position=${line##*\(}
        y=${position#*, }
        y=${y%%,*}
        y=${y%%.*}
        if (( y >= 345 && y <= 610 )); then return 0; fi
        if (( y > 610 )); then "$hid" scroll 1390 518 -30
        else "$hid" scroll 1390 518 30; fi
    done
    echo "EVENT_NOT_VISIBLE after scroll" >&2
    return 1
}
pass() {
    local label=$1
    # Native menu options visually verified at this anchored panel location.
    menu 342 # Week
    tap calendar-day-2026-11-11
    ensureEventVisible
    "$hid" tap calendar-event-clicklag4-2-0 20
    capture "${label}-calendar-event"
    for i in {1..20}; do
        tap calendar-day-2026-11-12
        tap calendar-day-2026-11-11
    done
    capture "${label}-calendar-day"
    for i in {1..20}; do
        menu 375 # Day
        menu 342 # Week
    done
    capture "${label}-calendar-view"
}

pass steady
tap panel-section-notes
tap panel-section-calendar
pass after-page-switch
