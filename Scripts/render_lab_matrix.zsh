#!/bin/zsh
set -euo pipefail

# Air only. Each experiment alternates baseline/flagged 30-second idle clicks.
# Keep finished batches when this script is restarted after a disconnect.
readonly root=${0:A:h:h}
cd "$root"

run_pair() {
    local name="$1"
    shift
    if [[ -f "/tmp/render-lab/$name/sequence.log" ]] &&
        /usr/bin/grep -q '^FINISHED ' "/tmp/render-lab/$name/sequence.log"; then
        print "SKIPPED completed $name"
        return
    fi
    print "BEGIN $name load=$(/usr/bin/uptime)"
    zsh Scripts/render_lab_pair.zsh "$name" "$@"
}

case "${1:-}" in
    core)
        run_pair calendar-mask-scroll ATTIC_LAB_NO_CALENDAR_MASK calendar-scroll calendar-scroll 4 panel-section-calendar scroll
        run_pair panel-shadow ATTIC_LAB_NO_PANEL_SHADOW tasks-page-backlog tasks-page-now 4 panel-section-tasks
        run_pair panel-clip ATTIC_LAB_NO_PANEL_CLIP tasks-page-backlog tasks-page-now 4 panel-section-tasks
        run_pair page-motion ATTIC_LAB_NO_PAGE_MOTION panel-section-notes panel-section-tasks 4
        ;;
    more)
        run_pair tag-mask ATTIC_LAB_NO_TAG_MASK tasks-tag-bar-design-team tasks-tag-bar-all 4 panel-section-tasks
        run_pair control-shadow ATTIC_LAB_NO_CONTROL_SHADOW tasks-page-backlog tasks-page-now 4 panel-section-tasks
        run_pair island-shadow ATTIC_LAB_NO_ISLAND_SHADOW panel-section-notes panel-section-tasks 4
        run_pair island-mask ATTIC_LAB_NO_ISLAND_MASK panel-section-notes panel-section-tasks 4
        run_pair top-row-delay ATTIC_LAB_NO_TOP_ROW_DELAY panel-section-notes panel-section-tasks 4
        run_pair tag-layout ATTIC_LAB_NO_TAG_LAYOUT tasks-tag-bar-design-team tasks-tag-bar-all 4 panel-section-tasks
        ;;
    paths)
        run_pair tasks-search ATTIC_LAB_NO_CONTROL_SHADOW tasks-find-button tasks-find-button 4 panel-section-tasks toggle
        run_pair tasks-plus ATTIC_LAB_NO_COMPOSER_CLIP tasks-new-task tasks-new-task 4 panel-section-tasks toggle
        run_pair tasks-plus-return ATTIC_LAB_NO_BOTTOM_ROW_DELAY tasks-new-task tasks-new-task 4 panel-section-tasks dismiss
        run_pair notes-search ATTIC_LAB_NO_CONTROL_SHADOW notes-search-button notes-search-button 4 panel-section-notes toggle
        run_pair notes-plus ATTIC_LAB_NO_COMPOSER_CLIP notes-new-note notes-new-note 4 panel-section-notes toggle
        run_pair calendar-search ATTIC_LAB_NO_CONTROL_SHADOW calendar-search-button calendar-search-button 4 panel-section-calendar toggle
        run_pair calendar-plus ATTIC_LAB_NO_COMPOSER_CLIP calendar-new-task calendar-new-task 4 panel-section-calendar toggle
        run_pair tasks-scroll ATTIC_LAB_NO_PANEL_CLIP tasks-scroll-viewport tasks-scroll-viewport 4 panel-section-tasks scroll
        run_pair menu-mask ATTIC_LAB_NO_MENU_MASK panel-more-button panel-more-button 4 panel-section-tasks toggle
        ;;
    extras)
        run_pair task-row ATTIC_LAB_NO_PANEL_CLIP task-row-first task-row-first 4 panel-section-tasks cold-only
        ATTIC_LAB_SEED=tasknote run_pair notes-layout ATTIC_LAB_NO_NOTES_LAYOUT_MOTION notes-layout-board notes-layout-list 4 panel-section-notes
        run_pair composer-layout ATTIC_LAB_NO_COMPOSER_GROW_LAYOUT tasks-new-task tasks-new-task 4 panel-section-tasks toggle
        run_pair all-v2 ATTIC_LAB_ALL_OFF panel-section-notes panel-section-tasks 4
        ATTIC_LAB_PAIR_REVERSE=1 run_pair tag-layout-reverse ATTIC_LAB_NO_TAG_LAYOUT tasks-tag-bar-design-team tasks-tag-bar-all 4 panel-section-tasks
        ATTIC_LAB_SETTINGS=1 run_pair settings-mask-scroll ATTIC_LAB_NO_SETTINGS_MASK settings-page-panel settings-page-panel 4 settings-nav-panel scroll
        ATTIC_LAB_SETTINGS=1 run_pair settings-preview-shadow ATTIC_LAB_NO_SETTINGS_PREVIEW_SHADOW setting-appearance-light setting-appearance-system 4 settings-nav-appearance
        ;;
    dropdowns)
        run_pair dropdown-insertion-chip ATTIC_LAB_NO_DROPDOWN_INSERTION_MASK composer-chip-tags composer-chip-tags 4 'panel-section-tasks>tasks-new-task' toggle
        run_pair dropdown-content-chip ATTIC_LAB_NO_DROPDOWN_CONTENT_MASK composer-chip-tags composer-chip-tags 4 'panel-section-tasks>tasks-new-task' toggle
        run_pair dropdown-viewport-chip ATTIC_LAB_NO_DROPDOWN_VIEWPORT_MASK composer-chip-tags composer-chip-tags 4 'panel-section-tasks>tasks-new-task' toggle
        run_pair dropdown-reveal-chip ATTIC_LAB_NO_DROPDOWN_REVEAL composer-chip-tags composer-chip-tags 4 'panel-section-tasks>tasks-new-task' toggle
        ;;
    *) print -u2 'usage: render_lab_matrix.zsh core|more|paths|extras|dropdowns'; exit 2 ;;
esac
