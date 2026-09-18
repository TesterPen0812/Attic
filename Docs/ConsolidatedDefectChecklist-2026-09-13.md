# Consolidated Attic defect and repair checklist — 2026-09-13

This is the single repair list assembled from Taha's reports, the independent root audit, the first SWE source/native reviews, Astra's pinned visual audit, the earlier Luna review, the five-lane concurrent SWE-2 Max audit, and the existing Canvas/Notes resolution ledgers.

## Status and evidence rules

- **Confirmed current defect** means it was reproduced in the current preview or established directly in the current source.
- **Intermittent/current investigation** means a real failure was observed, but the trigger or root cause still needs isolation.
- **Regression gate** means the defect was reported earlier and a fix exists; it must be retested in the current build before being closed.
- An item closes only after the implementation is fixed, the relevant focused checks pass, and the actual rendered or physical interaction is checked where applicable.
- Build success and source inspection alone do not close visual, gesture, accessibility, drag-and-drop, or performance items.

## A. Fix now — confirmed current task-panel defects

- [ ] **TP-001 — Hide row overflow menus at rest.** Blue `•••` controls are visibly present on task and subtask rows without hover or keyboard focus. Reveal them only on row hover/focus, keep their layout space reserved, and keep visible pixels and accessibility semantics in sync.
- [ ] **TP-002 — Refine scrolling depth behind fixed chrome.** Updated by Taha on September 14: main-panel rows, subtask rows, and attachment cards should remain faintly visible as they scroll behind the top controls and bottom composer, following the Siri references. Preserve depth with enough mask/material separation for readable controls and inert obscured rows; completely hiding content before the controls does not satisfy this requirement. Verify long lists, galleries, expanded composer/error states, contrast settings, and actual scrolling.
- [ ] **TP-003 — Make neutral family-row hover non-navigational.** Hovering a task with subtasks currently opens its subpanel after roughly half a second. A neutral hover should only reveal the row surface/actions; opening the workspace must require a deliberate action.
- [ ] **TP-004 — Enforce a predictable Subtasks entry point.** The row menu's `Show attachments` action can open a new task panel directly in Attachments. A newly opened task workspace must begin on Subtasks; switching to Attachments happens from the control inside the subpanel.
- [ ] **TP-005 — Fix the invisible/offscreen attachment picker deadlock.** SWE reproduced an `NSOpenPanel` present in the window and accessibility lists but unavailable onscreen. It retained the picker-owner state, disabled other add-attachment actions, and made an enabled-looking subpanel action do nothing.
- [ ] **TP-006 — Fix the degraded ghost-panel state.** After a pin → drag → unpin → detach sequence, SWE reproduced stopped hover handling, a stuck help-tag accessibility tree, and a 272×246 ghost surface flickering in and out. Relaunch cleared it; the window/state lifecycle needs a causal fix.
- [ ] **TP-007 — Redesign attachment-failure presentation.** Long errors such as an oversized video currently expand inside the composer, wrap awkwardly, compete with the composer controls, and dominate the panel. Use a compact, readable, dismissible/recoverable message that preserves composer layout.
- [ ] **TP-008 — Replace the poor external file drag preview.** Dragging an attachment outside the panel produces a large dark filename pill with ugly multiline wrapping. Use a compact native-looking preview with a thumbnail/file icon, truncated name, and stable hotspot.
- [ ] **TP-009 — Remove attachment drag jank.** Dragging images/files into, across, and out of task panels is visibly laggy. Keep the drag preview, drop overlay, gallery insertion, scrolling, and panel state responsive throughout the interaction.

## B. Reproduce, isolate, and fix — intermittent/current panel failures

- [ ] **TP-010 — Eliminate general task-panel interaction lag.** Profile scrolling, revealing, hiding, switching views, resizing, and dragging with representative long lists and attachment sets. Establish frame pacing, CPU, wake-up, and memory baselines before and after the fix.
- [ ] **TP-011 — Stop per-scroll-frame subpanel refits.** Source review found row anchors republished during scrolling while the controller performs synchronous layout/fitting-size work and moves or animates windows. Refit only when content size changes and coalesce/throttle geometry updates.
- [ ] **TP-012 — Reduce pointer-monitor churn.** Source review found overlapping pointer-monitor paths plus a 50 ms sampler repeatedly updating mouse passthrough, geometry, and cursor rectangles. Skip unchanged work, consolidate responsibility, and invalidate cursor rectangles only when required.
- [ ] **TP-013 — Remove repeated per-row data work.** Cache/index task families instead of scanning all tasks repeatedly, decode attachment metadata once per render/update, avoid repeated `children` access, and use lazy row construction for larger lists. The audit measured about 357 ms for the current family lookup pattern at 6,000 tasks.
- [ ] **TP-014 — Prevent reveal-time main-actor refresh stalls.** Verify the current reveal path no longer performs redundant synchronous Task/Note/Canvas refreshes during the opening animation. Remove or defer any remaining duplicate full-view invalidation.
- [ ] **TP-015 — Smooth constrained subpanel resizing.** Investigate near-screen-edge cases where content-height animation and immediate window-frame correction may fight and cause a snap, overlap, or misplaced composer.
- [ ] **TP-016 — Fix intermittent unpinned main-panel auto-hide.** The main panel sometimes remains open while idle and unpinned even when no field or interaction should hold it open. Do not change the deliberate moved-subpanel latch behavior: a moved subpanel remains until the user clicks outside it.
- [ ] **TP-017 — Remove two-finger main-panel dismissal flicker.** Preserve the approved original motion with light polish while eliminating flicker during fast two-finger dismissal and cancellation.
- [ ] **TP-018 — Recheck transient-panel reachability around pinned panels.** Healthy-process corridor travel passed, but earlier sessions saw a newly opened transient panel disappear before the pointer arrived. Verify slow/diagonal travel across existing pinned windows and fix only if the current preview still fails.
- [ ] **TP-019 — Recheck simultaneous-panel placement.** Opening a second task subpanel previously placed it directly over the first. Verify collision-aware placement at all corners, screen edges, and with moved/pinned panels.
- [ ] **TP-020 — Recheck composer/list collision.** Luna captured a composer overlapping the next list row. Verify it independently from TP-002 and correct layout if it persists after the chrome masking fix.
- [ ] **TP-021 — Validate Clear-mode contrast.** Astra found a provisional concern that lower labels and composer text become too faint against a pale isolated surface. Reproduce in the normal desktop composition and fix the foreground/material pairing if confirmed.
- [ ] **TP-022 — Prevent under-composer hit-through during composer changes.** Native SWE evidence showed task subpanels opening for rows visually beneath the composer while targeting the paperclip and after removing a pending attachment collapsed the composer. Instrument mouse-down/up ownership and keep underlying rows inert for the entire interaction before treating this as confirmed rather than automation timing.
- [ ] **TP-023 — Clear every surface-owned confirmation mark on teardown.** `releaseFamilyInteractionState` clears deletion confirmation but omits `confirmingTaskCompletionID`. No reachable trigger was confirmed, but the inconsistency can strand the shared interaction lock if a new teardown path bypasses the current accidental defenses.
- [ ] **TP-024 — Preserve focus when a Notes close is refused.** Section switching clears quick-entry focus before `noteDraft.close()` can refuse the transition. Reorder the refusal check before state mutation and add a focused failure-path test.

## C. Task behavior and attachment regression gates

- [ ] **TASK-001 — Parent completion remains a confirmation, not a hard block.** Completing a task with unfinished subtasks must show a calm confirmation with working Cancel and Complete Anyway paths; never restore the large red blocking warning.
- [ ] **TASK-002 — Completed tasks sort below unfinished tasks.** Confirm the order persists after relaunch and while duplicate task records are present.
- [ ] **TASK-003 — Single-line titles remain stable.** Long titles stay on one row, fade at the trailing edge, preserve a stable row height, and expose the full text by hover/focus/editing.
- [ ] **TASK-004 — Metadata remains passive and compact.** Attachment previews/counts, subtask progress, and pinned status must read as secondary status rather than buttons, with no unnecessary title-to-metadata gap.
- [ ] **TASK-005 — Main-composer attachments remain complete.** Picker and drag-in both work; pending images/files appear before submission; the composer expands upward without covering tasks or controls.
- [ ] **TASK-006 — Task-level drops remain complete.** Files/images can be dropped onto a row or anywhere on its open subpanel, including while Subtasks is showing; the restrained drop state preserves the panel underneath, then switches to Attachments and animates the new item into place.
- [ ] **TASK-007 — Attachment gallery remains bounded and useful.** Images use compact thumbnails, documents use compact file cards, mixed items coexist, hover removal is quiet, preview/open works, and content scrolls after the shared maximum height.
- [ ] **TASK-008 — Exported task drags carry attachments.** Dragging a task outside Attic must reliably include its associated images/files without freezing the source panel.
- [ ] **TASK-009 — Pinned-panel identity remains correct.** One movable panel belongs to one task, retains its position, raises from the muted row pin indicator, and only the subpanel's actual control pins/unpins it.
- [ ] **TASK-010 — Subtasks/Attachments transition remains stable.** Every open starts on Subtasks; the internal destination switch is beside the composer; labels update correctly; content slide/crossfade and height changes are short, smooth, and keep the window anchored.
- [ ] **TASK-011 — Dynamic sizing remains correct.** Both views share the same sizing system, grow only to the existing maximum, scroll thereafter, and shrink/expand smoothly when switching between differently sized contents.
- [ ] **TASK-012 — Surface translucency affects surfaces only.** With translucency on or off, pin, complete, composer, view switch, and equivalent interactive controls remain Liquid Glass. Settings copy must explain this clearly.

## D. Panel input, shape, and visual regression gates

- [ ] **PANEL-001 — Header dragging never collapses the main panel.** One-finger/header movement only moves or docks the panel; collapse is reserved for the intended swipe/automatic-hide paths.
- [ ] **PANEL-002 — Docking target indicators stay outside the panel.** They must not collide with pin/complete/other controls and must remain readable during a fast drag.
- [ ] **PANEL-003 — Panel density is deliberate.** Re-evaluate the main panel, subpanels, text, icons, row spacing, and hit targets together; reduce size only where legibility, accessibility, and drag precision remain strong.
- [ ] **PANEL-004 — Popovers and notices stay calm.** Check success, warning, failure, destructive confirmation, attachment progress, and retry states for size, anchoring, contrast, dismissal, and interruption of the current task.
- [ ] **PANEL-005 — Physical gestures receive real-device UAT.** Test two-finger dismissal, cancellation, velocity threshold, pinned immunity, ordinary scroll coexistence, mouse/header drag, and Reduce Motion on the installed preview. Synthetic gestures alone do not close this.
- [ ] **PANEL-006 — Pointer and resize acquisition remain reliable.** Check every edge/corner, dense content, toolbar boundaries, transparent corners, and visible padding; visible panel areas must not pass clicks to underlying windows.

## E. Canvas defects and current-build regression gates

- [ ] **CANVAS-001 — Audit every bottom-toolbar control and state.** The toolbar redesign must be coherent, complete, hoverable, keyboard accessible, and every visible control must work.
- [ ] **CANVAS-002 — Make pencil aim precise and visible.** The pencil cursor must remain visible on dark and light content, expose an unambiguous drawing point, and begin the stroke exactly at that point.
- [ ] **CANVAS-003 — Restore the arrow over toolbar UI.** Drawing cursors and drawing behavior must yield to normal pointer/control interaction over the toolbar and other controls.
- [ ] **CANVAS-004 — Give Add Shape the same hover quality as peer controls.** Its hover/focus/pressed/disabled behavior must not feel like a separate design system.
- [ ] **CANVAS-005 — Keep Canvas full-panel.** The working surface should use the panel itself rather than appear inside an unnecessary inset box, while retaining safe space for floating controls.
- [ ] **CANVAS-006 — Make shape resizing reliable.** Verify every resize handle, all drag directions, minimum sizes, zoom levels, viewport edges, selection changes, and undo/redo.
- [ ] **CANVAS-007 — Make zoom reliable.** Verify trackpad pinch, toolbar zoom, fit/reset, momentum, large canvases, and simultaneous pan/draw/resize arbitration.
- [ ] **CANVAS-008 — Fix Canvas error presentation.** Long import/save/unsupported-file/corrupt-asset errors must not overlap the toolbar or canvas and must provide clear dismiss/retry/remove/export recovery where relevant.
- [ ] **CANVAS-009 — Remove large-image stalls.** Stress import, pan, zoom, cancel, and undo with large images; keep decoding and whole-payload/table work off interaction-critical main-actor paths where possible.
- [ ] **CANVAS-010 — Bound history by memory cost.** Undo history currently needs a byte-aware policy, not only an item count, so large image operations cannot grow memory unexpectedly.
- [ ] **CANVAS-011 — Finish file-drag failure/cancel behavior.** Test real Finder files and file promises, multiple items, unsupported types, progress, partial failure, and Escape cancellation.
- [ ] **CANVAS-012 — Handle missing/corrupt assets visibly.** Provide retry/remove/export/recovery rather than silently failing or leaving broken objects.
- [ ] **CANVAS-013 — Verify page/viewport persistence.** Page selection, viewport, content, undo expectations, and relaunch behavior need installed-app evidence.
- [ ] **CANVAS-014 — Resolve semantic-object expectations.** Shapes/text currently behave as ink or non-editable image content. Either implement the promised editable semantics or keep UI/copy truthful and document the chosen scope.
- [ ] **CANVAS-015 — Complete rapid-input/coalescing checks.** Confirm fast Pencil/mouse input remains accurate without event backlog, dropped endings, runaway allocations, or animation contention.
- [ ] **CANVAS-016 — Stop re-faulting every image blob after each Canvas mutation.** Presentation resolution touches and retains every current-board image payload after each save, so a stroke on an image-heavy board can reread the entire board. Keep payload bytes out of the hot presentation model and validate unchanged images by scalar digest/size metadata.
- [ ] **CANVAS-017 — Remove full accessibility rebuilds from pan/zoom frames.** `configure()` currently scans/sorts all objects and rebuilds accessibility elements on published viewport changes even without an accessibility client. Gate AX work by client/content revision, coalesce it, and precompute z-order indices.
- [ ] **CANVAS-018 — Remove per-pointer full image sorts.** Select-tool cursor hit-testing sorts all images on every mouse-move event and repeatedly rebuilds preview arrays during image transforms. Maintain a shared content-revision-sorted display/hit-test structure.

## F. Notes and saved-notes defects and regression gates

- [ ] **NOTES-001 — Prevent deleted text from returning.** Reproduce large selection deletion, continuous typing, focus changes, panel hide/reveal, and relaunch; make draft/persistence reconciliation preserve the user's latest edit.
- [ ] **NOTES-002 — Align Notes typography with the panel.** Text size, line height, placeholders, cards, and metadata must fit the compact panel without sacrificing readability.
- [ ] **NOTES-003 — Consolidate note actions.** Use a floating plus for attachments and a floating New Note action; automatic saving removes the old Save command, while Saved Notes remains a clear entry point.
- [ ] **NOTES-004 — Make file/image attachment entry reliable.** Picker, drag/drop, multi-item import, cancellation, progress, error, retry, and duplicate handling must work from both note and chat-like writing areas.
- [ ] **NOTES-005 — Use compact default attachment cards.** New images/files begin as compact cards like the supplied reference, then can be selected, moved between paragraphs/areas, and resized without becoming fixed in one place.
- [ ] **NOTES-006 — Finish inline attachment editing.** Verify placement before/after text, reordering, resize handles, scrolling, keyboard selection/deletion, undo/redo, persistence, and export/drag-out.
- [ ] **NOTES-007 — Finish the Saved Notes drawer.** Use the approved squircle panel with floating return/close/new-note controls, remove the large title and full-width return bar, and let notes scroll cleanly beneath floating chrome.
- [ ] **NOTES-008 — Restore editing session state.** Cursor, selection, and scroll position should survive appropriate hide/reveal and note switches without jumping or overwriting newer content.
- [ ] **NOTES-009 — Define autosave durability under continuous typing.** Establish and test a maximum unsaved interval, failed-save rollback/retry, quit/crash behavior, and accurate saved/failed/conflict status.
- [ ] **NOTES-010 — Centralize attachment lifecycle invariants.** Import, reference, replacement, deletion, deduplication, missing files, and cleanup must not leave orphaned files or broken cards.
- [ ] **NOTES-011 — Add missing/corrupt attachment recovery.** Broken note attachments need visible retry/remove/reveal/export choices.
- [ ] **NOTES-012 — Remove broad swipe/scroll ambiguity.** Narrow any global scroll monitoring so ordinary editing and attachment scrolling cannot accidentally navigate or dismiss the drawer.
- [ ] **NOTES-013 — Scale typing and large note libraries.** Eliminate whole-document signature copies, per-card full UTF-16 diffs, full paragraph-style rewrites, and unconditional card-host rerenders on each keystroke. Also avoid full-snapshot refreshes and repeated note sorting; measure typing, reveal, list scrolling, and switching with long notes, many cards, and large libraries.
- [ ] **NOTES-014 — Complete accessibility and theme checks.** Verify labels, announcements, tab order, full-keyboard access, hit targets, VoiceOver, dark/light/clear contrast, and Reduce Motion.
- [ ] **NOTES-015 — Eliminate late AppKit callbacks after teardown.** Stress rapid open/close/switch/import so stale delegates or callbacks cannot resurrect state, crash, or update the wrong note.

## G. Persistence and attachment findings from the concurrent audit

- [ ] **DATA-001 — Keep TaskStore CloudKit machinery dormant in local-only builds.** Unlike Notes and Canvas, TaskStore still registers remote/CloudKit observers and begins a `userInitiatedAllowingIdleSystemSleep` export activity after local saves. Gate observers, event handling, save-generation protection, activity tokens, and timeout tasks under the local-only policy; add the missing TaskStore dormancy test.
- [ ] **DATA-002 — Do not expose private note-attachment files to external editors.** Note attachment Open currently hands the digest-keyed private materialization to another app, after which Attic silently restores original bytes on later access. Use a disposable read-only copy or provide an explicit editing/import-back workflow so external edits cannot disappear without explanation.
- [ ] **DATA-003 — Report rejected pasted images and file promises.** Pasted image data and promised-file drops can be accepted and silently discarded while another import is active or the draft cannot flush. Present the same calm busy/conflict feedback as the URL-import path.
- [ ] **DATA-004 — Protect surviving references before deleting attachment files.** Delete, purge, and remove paths assume an attachment UUID belongs to only one logical task. Re-check replica-wide surviving references before removing the file so crafted/corrupt shared identities cannot break another task.

## H. Resource and quality gates

- [ ] **PERF-001 — Establish controlled baselines.** Measure true idle, main panel visible, long-list scroll, subpanel switch/resize, picker open, image drag, Canvas large-image pan/zoom, and continuous note typing. Record CPU, memory, wake-ups, allocations, and frame pacing on the same signed preview and dataset.
- [ ] **PERF-002 — Keep idle work close to zero.** No busy hover-close loops, orphaned pointer samplers, ghost windows, perpetual animation timelines, or repeated store refreshes may remain after interaction ends.
- [ ] **PERF-003 — Confirm memory stays bounded.** Exercise repeated large attachment import/remove, Canvas undo, note switching, task dragging, and panel open/close cycles; verify resources return and no callback/window/drag-provider cycles survive.
- [ ] **PERF-004 — Cut store-wide SwiftUI invalidation.** Per-character drafts, resize frames, store revisions, and other broad `@ObservedObject` publications currently re-evaluate unrelated task rows and multiply family scans/attachment decodes. Feed rows revision-stable value models and isolate high-frequency editing state.
- [ ] **PERF-005 — Predicate persistence fetches.** Task mutations perform multiple unpredicated full-table fetches on the main actor, Canvas replica helpers do the same, and NoteStore refresh fetches and rebuilds every note/attachment index. Fetch only relevant replicas/candidates while preserving mutate-every-replica correctness.
- [ ] **PERF-006 — Stop holding responsive energy policy while merely visible.** The corner monitor uses a 50 ms main-queue timer and a `userInitiatedAllowingIdleSystemSleep` activity assertion whenever the panel is visible or the pointer is near the corner. Narrow it to the actual reveal-decision window and prove idle visible panels have no periodic wakeups or App Nap suppression.
- [ ] **PERF-007 — Make Canvas revision synchronization incremental.** Every Canvas revision allocates and compares full signature arrays, republishes full object collections, and triggers downstream configure work. Publish changed keys/deltas while retaining a safe full-snapshot fallback.
- [ ] **PERF-008 — Bound Notes refresh and sorting work.** Memoize ordered notes per revision and avoid full attachment-index reconciliation after unrelated edits.
- [ ] **PERF-009 — Bound daily cleanup work.** Wake, activation, timezone, and midnight cleanup currently combine a full refresh with multi-pass task-family scans. Use revision/staleness checks and fetch only completion candidates.
- [ ] **QUALITY-001 — Preserve local-first durability.** All fixed flows must save locally, roll back failed saves cleanly, and avoid touching the former app container, CloudKit, APNs, or deferred iPhone behavior.
- [ ] **QUALITY-002 — Run focused and full regression checks.** Add meaningful focused tests for each causal fix, regenerate/verify the project when inputs change, run the relevant unit/UI tests, then review the final diff for unrelated changes.
- [ ] **QUALITY-003 — Capture every implemented visual state.** Reviewers must deliberately trigger rest, hover, focus, pressed, disabled, loading, empty, populated, overflow, success, warning, failure, retry, drag-over, drag-out, pinned, unpinned, Reduce Motion, dark/light/clear, and constrained-edge states that apply.
- [ ] **QUALITY-004 — Use reproducible visual evidence.** Every claimed visual pass needs a current screenshot/capture, state description, and reproducible transition. Accessibility-tree presence or source review alone is insufficient.
- [ ] **QUALITY-005 — Complete final independent reviews.** After repairs, run an independent source/architecture review and an independent native visual/interaction review against this checklist, fix all confirmed findings, and repeat until no confirmed defect remains.
- [ ] **QUALITY-006 — Integrate the in-progress independent Luna audit.** Add any unique confirmed Luna finding to the appropriate section without duplicating an existing item.
- [ ] **QUALITY-007 — Replace tests that encode obsolete behavior.** `testLongTaskTitleWrapsInsteadOfTruncating` asserts the old wrapping contract, while a new explicit-view test asserts that `Show attachments` opens directly on Attachments. Rewrite both around the current single-line and Subtasks-first requirements.
- [ ] **QUALITY-008 — Add measurable performance regression gates.** The suite has no `XCTMetric` or equivalent measurements, so task scaling, drag smoothness, Canvas payload work, Notes typing, wakeups, and memory bounds cannot currently close from tests.
- [ ] **QUALITY-009 — Audit compact icon hit targets.** Several visible icon controls use roughly 16–22 pt frames. Preserve compact visuals while providing comfortable pointer hit regions, focus rings, labels, and non-overlapping hit behavior.

## I. Already fixed protections — do not regress or re-fix without evidence

- [x] File-drop callback lifetime cycle was repaired in the prior source-review loop.
- [x] The expired hover-close deadline busy loop (about 70,000 callbacks/second in the old failure mode) was repaired in the prior source-review loop.
- [x] Surface translucency and Liquid Glass control styling were separated in the prior batch; TASK-012 verifies the current preview keeps it.
- [x] Full-title keyboard-focus disclosure and observer cleanup were added in the prior batch; TASK-003 rechecks the current behavior.
- [x] The parent-completion product behavior was changed from a hard block to confirmation; TASK-001 protects it while the stale UI expectation is corrected.
- [x] Healthy-process safe pointer-corridor travel passed SWE's native test; TP-018 remains a targeted intermittent regression check.
- [x] Synthetic two-finger dismissal passed for unpinned subpanels and pinned panels ignored it; PANEL-005 still requires physical trackpad verification.
- [x] Pin, move, persist, and raise worked in SWE's healthy-process run; TASK-009 guards the behavior while TP-006 addresses the degraded lifecycle sequence.

## Source evidence

- `Docs/TaskPanelV2QualityAudit-A.md` — SWE source/performance audit.
- `Docs/TaskPanelV2QualityAudit-B.md` — SWE native UI and interaction audit.
- `Docs/TaskPanelV2QualityAudit-Root.md` and `Docs/TaskPanelV2QualityAudit-Root-LiveAddendum.md` — independent root audit.
- `Docs/ConcurrentSWEReview-CodeCorrectness.md` — concurrent lane 1 architecture/lifecycle review.
- `Docs/ConcurrentSWEReview-Performance.md` — concurrent lane 2 performance/energy review.
- `Docs/ConcurrentSWEReview-DataAttachments.md` — concurrent lane 3 persistence/attachment review.
- `Docs/ConcurrentSWEReview-RequirementsTests.md` — concurrent lane 4 traceability/test review.
- `Docs/ConcurrentSWEReview-NativeUX-Partial.md` and `Docs/ConcurrentSWEReview-NativeUX-Evidence/` — lane 5 partial native review and 45 captures; the provider rate limit stopped finalization.
- `Docs/TaskPanelV2FinalAstraReview.md` — prior final source review and repaired defects.
- `Docs/UXRefinementLedger.md` — earlier user-reported Canvas, Notes, panel, and attachment work plus verification status.
- `Docs/AuditFixResolutionLedger-2026-08-31.md` — remaining Canvas, Notes, panel, accessibility, and performance gaps.
- `/Users/taha/.codex/visualizations/2026/09/13/01a09bf7-39b2-7481-b1aa-2d8986bc4e89/attic-independent-audit/AUDIT.md` — Astra pinned visual audit.
- `/Users/taha/.codex/attachments/184dbe5b-551b-4551-895c-0e2b2f253e8b/pasted-text.txt` — current 129-point product checklist.
