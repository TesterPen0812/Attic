# Concurrent SWE Review — Lane 5: Native UX (partial evidence report)

- **Checkout under review:** `/Users/taha/Developer/attic-task-panels-v2`, baseline `ae6418c1` plus the existing dirty tree.
- **Preview:** `AtticTaskPanelsV2.app`, process `AtticTaskPanelsV2`, bundle `com.taha.Attic.taskpanels.v2`.
- **Method:** Hands-on native interaction and screenshot capture by the assigned SWE-2 Max lane.
- **Completion limitation:** The provider stopped the lane after 153 messages with an overall Devin message-rate-limit error before it wrote its own final report. This document preserves only transcript-backed and screenshot-backed evidence; unfinished areas remain unverified.
- **Evidence directory:** `Docs/ConcurrentSWEReview-NativeUX-Evidence/` (45 screenshots).

## Confirmed defects

### N-01 — TP-001 — Overflow ellipses remain visible at rest — P2

Blue `•••` glyphs are visible on main task rows and subtask rows at rest. This contradicts both the latest interaction contract and the source lane's finding that opacity, hit-testing, and accessibility should be gated. The pixel/source disagreement must be resolved in the rendered hierarchy rather than accepted from source inspection.

Evidence: `20260913-210925-03-panel-live.png`, `20260913-211217-09-subpanel-entered.png`.

### N-02 — TP-003 — Neutral family hover opens the subpanel — P1

Hovering the family row `hbuhb` opened its task workspace without a click. This matches the source-level dwell path and violates the current deliberate-open requirement.

Evidence: `20260913-211148-08-hover-family-hbuhb.png`, `20260913-211217-09-subpanel-entered.png`.

### N-03 — TP-004 — Show attachments bypasses the Subtasks entry point — P2

Selecting `Show attachments` from a row menu opened a fresh workspace directly on the empty Attachments view. The internal switch back to Subtasks worked and the panel resized to fit.

Evidence: `20260913-211241-10-row-overflow-menu.png`, `20260913-211304-11-show-attachments-result.png`, `20260913-211406-13-switch-to-subtasks.png`.

### N-04 — TP-002 — Scrolling content visibly collides with fixed chrome — P1

Task rows and completed rows remain visible beneath the fixed top controls and bottom composer. Text, completion controls, attachment metadata, and ellipses collide with the composer region; hover help can trigger over composer chrome.

Evidence: `20260913-212016-21-mainpanel-scrolled.png`, `20260913-212017-22-mainpanel-scrolled2.png`, `20260913-212248-28-list-bottom.png`, `20260913-212312-29-list-very-bottom.png`, `20260913-212908-39-hbuhb-attachments.png`.

### N-05 — TP-007 — Oversized-file error is large, duplicated, and sticky — P2

One oversized import produced red inline error text inside the subpanel composer and a second large toast over the main list. It remained for more than 15 seconds, survived typing, and remained after a valid pending attachment was added. There was no visible dismissal or recovery control.

Evidence: `20260913-215218-44-oversize-error.png`, `20260913-215218-45-main-error-zoom.png`.

## Strong evidence requiring focused reproduction

### N-06 — Under-composer rows can receive unintended activation — P1 candidate

While the lane targeted the main-composer attachment action, a task panel opened for a completed row visually beneath the composer. Removing a pending attachment collapsed the composer and was followed by another underlying row panel opening. The captures prove the resulting state, while event-level instrumentation is still needed to separate a real hit-through defect from automation timing.

Evidence: `20260913-212346-31-attach-click-result.png`, `20260913-212739-37-pending-removed.png`, `20260913-212803-38-spurious-subpanel-after-remove.png`.

### N-07 — Subpanel attachment picker can sink behind foreground applications — P1 mechanism, environmental contribution unresolved

The file picker repeatedly remained present in `CGWindowList` and accessibility while becoming obscured behind ChatGPT/Synara. Main-composer presentation remained reachable more reliably. Source review independently confirmed that picker ownership has no watchdog if completion never arrives. Reproduce without the review harness foreground before attributing all z-order behavior to Attic.

## Live passes

- Parent completion with unfinished subtasks displayed `Complete anyway` and `Cancel`; cancellation preserved the task.
- Completed disposable task appeared in the Done section below unfinished work.
- Long task title remained one line with a soft trailing fade.
- Collision-aware placement put a second transient panel below the pinned panel.
- Slow diagonal travel and crossing an existing pinned panel both preserved the transient panel; clear departure dismissed it.
- Subtasks/Attachments switching worked and resized the panel.
- Pinning, persisted visibility, muted row pin indicator, and raising an existing panel worked.
- Subtask creation synchronized the parent progress count.
- Main-composer pending attachment card, hover remove control, and collapse were visible.
- Attachment gallery mixed image and file cards; Quick Look worked.

## Unfinished coverage

The provider stopped before completing drag-in/out frame pacing, physical two-finger dismissal, full Notes/Saved Notes, full Canvas, appearance modes, Reduce Motion, keyboard/VoiceOver traversal, and error recovery after a successful attachment. These remain unverified and must not be reported as passes.
