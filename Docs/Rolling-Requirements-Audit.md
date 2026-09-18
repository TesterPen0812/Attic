# Rolling Requirements Audit — 2026-09-14

Requirements reconciliation for the Attic working tree. Read-only audit lane
(direct-Devin session `1421` per `Docs/RollingWork-2026-09-14.md`); owns only
this document.

## Scope and validation limits

- **Checkout:** `/Users/taha/Developer/attic-task-panels-v2`, branch
  `codex/attic-task-panels-v2`, HEAD `ae6418c` plus a large intentionally
  dirty worktree (60+ files, ~9.5k insertions).
- **Method:** source and test inspection plus ledger/checkpoint/review-document
  reconciliation only. No builds, no test execution, no app launch, no native
  pointer use. Anything whose truth lives in rendered pixels, physical
  gestures, VoiceOver, or measured CPU/memory/energy is **unverified** here
  even where the implementation looks correct.
- **Moving baseline warning.** The no-swipe implementer worker (session
  `15187`) edited this checkout during the audit: `PanelSurfaceHostingView.swift`,
  `SubtaskPanelController.swift`, `SubtaskPanelLayout.swift`,
  `SubtaskPanelTests.swift`, `SubtaskPanelControllerTests.swift`, and
  `PanelSurfaceHostingViewTests.swift` carry mtimes 04:08–04:12 local. Every
  swipe-related claim below was re-verified against the post-edit state; other
  files were read earlier and are unchanged per that mtime sweep.
- **Stale-evidence rule applied.** `Docs/ConsolidatedDefectChecklist-2026-09-13.md`
  items are all unchecked, but unchecked ≠ current defect. The five concurrent
  review lanes and the native captures in `ConcurrentSWEReview-NativeUX-Evidence/`
  predate the fix batches and root's Sep-14 chrome work; each item was re-judged
  against current source. Conversely, the checkpoint's recorded test run
  (`chrome-final-serial.log`: 182 tests, 2 skipped, exit 0 across
  PanelGeometryTests, PanelSurfaceHostingViewTests, SubtaskPanelControllerTests,
  SubtaskPanelTests, TaskPerformanceGateTests) **predates the swipe-removal
  edits** — "tested" below means a focused test exists in the current tree, not
  that it has run since.
- **Sibling lanes in flight.** The performance audit
  (`Docs/Rolling-Performance-Audit.md`) and reliability audit
  (`Docs/Rolling-Reliability-Audit.md`) belong to other workers and were pending
  at audit time; nothing here substitutes for them.
- The historical checkpoint's "stop before delegating implementation"
  instruction is superseded by the resumed continuous workflow, as directed.

## P0 — Current direction: remove task-subpanel swipe, keep main-panel swipe

**Status: implemented in source (in-flight edit observed), unverified.**

Post-edit evidence (re-verified after the worker's writes):

- `Attic/Window/PanelSurfaceHostingView.swift` — `PanelSurfaceWindow` is now a
  plain key-capable panel: "every scroll event reaches the content untouched."
  `swipeDismissal`, `PanelSurfaceSwipeDismissal`, `SubtaskSwipeDismissTracker`,
  `PanelSurfaceMotionContainer`, session/generation tracking, and the
  scrollWheel gesture router are all gone.
- `Attic/Window/SubtaskPanelController.swift` — zero swipe references remain;
  header doc now reads "outside click, Escape, or an explicit close." All
  `swipeDismissal`/`canBeginSwipeDismissal`/`completeSwipeDismissal`/
  `invalidateTransientSwipe`/`SwipePresentationKey` code removed; no dangling
  callers anywhere in `Attic/`, `AtticTests/`, `AtticUITests/`.
- `Attic/Services/SubtaskPanelLayout.swift` — the tracker definition is gone.
- New negative tests encode the contract:
  `PanelSurfaceHostingViewTests.testSwipeShapedScrollStaysWithTheContentAndNeverDismisses`,
  `testEveryScrollFlavourReachesTheContentUnconsumed`;
  `SubtaskPanelControllerTests.testScrollAndDragResidueNeverDismissesTheLatchedSurface`,
  `testEveryPreservedClosePathStillDismisses`. `SubtaskPanelTests` tracker tests
  are removed.
- **Main-panel swipe is preserved:** `Attic/Window/AtticPanel.swift` still routes
  phased precise scroll input through `PanelTrackpadDismissTracker` to `.hide`,
  `.notes`, or `.content`; `AtticPanelController` keeps
  `canBeginTrackpadSwipe`/`interactiveSwipeStartProgress`/`setCollapseProgress`;
  `PanelGeometry.swift` keeps `PanelTrackpadSwipe*` types and
  `PanelCollapseGeometry`; `PanelUIState.panelSwipe` lock and the Settings copy
  ("Swipe with two fingers toward the attached screen edge to hide the panel")
  are intact. The Notes-library horizontal swipe (`NotesHorizontalSwipeView` →
  `PanelNotesSwipeTarget`) is main-panel-routed and likewise retained.
- Preserved-dismissal matrix retained in source: outside-click monitor,
  Escape via `onEscape`, count-control toggle with same-click suppression,
  section-switch and main-panel-hide dismissal, pinned-window close.

**Still owed:** `Docs/Rolling-NoSwipe-Implementation.md` (absent at audit
time), `/tmp/attic-noswipe-baseline` diff record, a post-removal build and
focused test run, the independent reviewer (dispatch only after
`IMPLEMENTATION_READY`), and Sol Low's native pass — specifically: subpanel
scrolling is ordinary, no gesture dismisses a subpanel, main-panel two-finger
dismissal unchanged. Minor residue for the reviewer: the comment "Guard shared
by hover dwell…" at `SubtaskPanelController.swift:316` outlived its caller
(hover dwell no longer exists); harmless but should be reworded.

## A. Fix-now panel defects

| Item | Classification | Evidence |
| --- | --- | --- |
| TP-001 overflow menus at rest | **Implemented but unverified** | `TaskRowView.swift:535-549` `RowActionsAffordance`: opacity 0 + `allowsHitTesting(false)` + `accessibilityHidden` at rest, revealed by `showsRowAffordances` (hover or focused control), footprint reserved; `Menu`→plain `Button`+`NSHostingMenu` rework (`:381-409`) removes the AppKit accent-tinted label that painted blue `•••`. Shared `TaskRowView` covers main and subtask rows. Lane-5 captures showing visible ellipses predate the fix — needs one fresh native screenshot to close. |
| TP-002 scroll depth behind chrome | **Implemented but unverified** | `TaskScrollMaskLayout` (`PanelGeometry.swift:573-639`): single static gradient, under-chrome opacity 0.16, zero under Reduce Transparency/increased contrast; inert `Color.clear` shields over both chrome bands in `AtticPanelView.swift:107-128` and `SubtaskPanelContent.swift:149-161`; header underlay quieter (`×0.4`, `SubtaskPanelContent.swift:438-441`). Root visually verified an earlier preview revision; the final lower header-opacity state is explicitly still an open native item (checkpoint §"Validation"), and the full matrix (long lists, galleries, expanded composer/error, contrast) is owed. |
| TP-003 neutral hover non-navigational | **Implemented but unverified** | Hover-open machinery fully removed: `noteRowHover`/`pendingOpen`/`openDwell` absent everywhere in `Attic/`; `TaskFamilyView` has no `.onHover` reporting at all. Opens require `openFamilyPanel` (click/keyboard/VoiceOver/menu). Tests: `testAnchorsAndViewportsNeverOpenASurfaceWithoutADeliberateAction`, `testOpenIsDeliberateAndStaysUntilClosed`, UITest `testNeutralHoverNeverOpensAndAClickDoes` (`SubtaskHoverPinnedUITests.swift:267`). Checkpoint: one-click dispatch ~24 ms verified live in the earlier preview. Lane-5's hover-open capture predates removal. Owed: one native resting-hover no-open pass on the final build. |
| TP-004 predictable Subtasks entry | **Implemented but unverified** | `TaskActionsMenu` no longer contains "Show attachments" at all; the only remaining use is a subtask-legacy-attachments popover (`TaskRowView.swift:426-428`). `openFamilyPanel` documents and enforces "a fresh open always starts on Subtasks, whatever `view` asks" (`SubtaskPanelController.swift:361-365`); import reveal still switches deliberately after opening (`revealImportedAttachments`, `:457`). Tests assert fresh-open-on-Subtasks even with `view: .attachments` (`testFreshOpenStartsOnSubtasks…`, `testExplicitViewRequests…`). The attachments-first test cited in QUALITY-007/F2 was rewritten to the new contract. |
| TP-005 invisible/offscreen picker deadlock | **Implemented but unverified** | `TaskAttachmentPickerSession` (`TaskImageAttachments.swift:111-231`): single idempotent `finish` converging OK/cancel/willClose/never-visible/stranded-offscreen/owner-teardown; `NSApp.activate(ignoringOtherApps:)` for the background-accessory focus failure; floating+2 window level; 0.4 s `presentationCheckDelay` → `ensureReachable` recenters or finishes-as-cancel; `PanelUIState.reconcileTaskIDs` cancels a deleted owner's picker. Unit seam `isSessionActiveForTesting`; test `testPickerAndChildPopoverKeepSeparateMarksAndNeitherSilentlyBlocks`. Owed: native repro of the original present-but-unreachable state (display change/Space move), which may be environment-dependent. |
| TP-006 degraded ghost-panel state | **Implemented but unverified** | The window/state lifecycle was rewritten onto the `SubtaskPanelLifecycle` value type (`SubtaskPanelLayout.swift:463-508`) with single-owner transient/pinned maps, `releaseFamilyInteractionState` teardown, weak surface frame-animation targets, and drop-target weak captures. Focused tests cover unpin/detach/close/`testDismantledFamilySurfaceReleasesTheOwnersItsDropTargetCaptured`/`testControllerWithAnOpenSurfaceStillDeallocates`. The reported sequence (pin → drag → unpin → detach → ghost 272×246 surface + dead hover + stuck help-tag tree) has no unit analog — it needs the original native reproduction. |
| TP-007 attachment-failure presentation | **Implemented but unverified** | `SubtaskPanelContent.swift:523,709-747`: compact notice *below* the composer row, 2-line tail-truncated, dismiss control (`subtask-panel-error-dismiss-*`), family-scoped via `store.lastErrorOwnerID`, clears on next success. Main panel keeps the separate `errorBanner` overlay. Owed: native check with an oversized video (the original repro) across panel sizes. |
| TP-008 external file drag preview | **Implemented but unverified** | `TaskImageAttachments.swift:445-451`: compact `Label(filename, systemImage:)` on `.regularMaterial` capsule replaces the large dark pill. Two residual gaps to check natively: the label uses a generic `photo`/`doc` symbol rather than the file-type icon/thumbnail the item asks for, and no explicit `lineLimit`/truncation is set — a very long name would produce a very wide pill rather than a truncated one. Owed: native drag-out capture with long and short names. |
| TP-009 attachment drag jank | **Implemented but unverified** | Drag-time work is now minimal by construction: `validateDrop`/`dropUpdated` classify by type conformance only (`TaskAttachmentDrop.swift:45-70`); all provider loading is deferred to `TaskDroppedFiles.stage` after the drop; card drags resolve through the own-process marker + `TaskAttachmentCardDrag` record instead of file I/O. Owed: actual frame-pacing/CPU capture during in/across/out drags — smoothness cannot close from source. |

## B. Intermittent and performance items

| Item | Classification | Evidence |
| --- | --- | --- |
| TP-010 general interaction lag | **Open investigation** | The dominant measured costs (family scans, decode) are fixed at source level (TP-013), and event-driven sampling replaced the always-on timer (TP-012), but the item's own demand — frame-pacing/CPU/wake-up/memory baselines under representative load — is unmet. Belongs to the in-flight performance audit. |
| TP-011 per-scroll-frame refits | **Implemented but unverified** | `updateTaskRowFrames`/`updateTaskListViewport` (`SubtaskPanelController.swift:206-231`) now skip unchanged inputs and coalesce to one reposition per run-loop turn; detached panels skip entirely; `transientRepositionCount` test seam; test `testRowAnchorPublicationsCoalesceIntoOneRepositionPerTurn`. Owed: scroll profiling with a surface open. |
| TP-012 pointer-monitor churn | **Implemented but unverified** | `CornerHoverMonitor` is now cadence-driven: visible panel = `eventDriven` = **no repeating timer** (`CornerHoverStateMachine.swift:36-64`), pointer bursts coalesce to ≤30/s with a trailing sample, hidden far = 1 s idle timer, hidden near-corner = 50 ms responsive timer. `updateMousePassthrough` duplication removed from the sampling path (`CornerHoverMonitor.swift:229-236`). |
| TP-013 per-row data work | **Passed by specific evidence (source + bounded gates; last run predates swipe edits)** | `TaskStore.familyIndex` (`:225-296`): revision-keyed `id→task` + `parent→ordered children` built once per mutation with precomputed `SubtaskSortKey`s — `task(withID:)`/`subtasks(of:)` are O(1); attachment decode is memoized per payload (`TaskItem.attachments`). `TaskPerformanceGateTests` encode absolute bounds incl. the audited shape (1,000 parents/6,000 tasks, 3 lookups each → <25 ms vs measured 357 ms before) with `XCTClockMetric` measures. Recorded green in the checkpoint's final serial run; not re-run after the swipe edits (which did not touch these files). |
| TP-014 reveal-time refresh stalls | **Passed by specific evidence (source)** | `RevealRefreshPolicy.current` returns `.inProcessAuthoritative` under `ATTIC_LOCAL_ONLY` (`CornerHoverMonitor.swift:5-39`): reveal performs zero store reloads; `refreshesOnReveal` is false; the same policy gates `DailyCleanupService`'s refresh. Deferred-sync refreshes remain behind the non-local path. |
| TP-015 constrained subpanel resizing | **Implemented but unverified** | `SubtaskPanelLayout.pinnedResizedFrame` clamps growth inside the display; tests `testPinnedGrowthBelowDisplayEdgeClampsInside`, `testPinnedGrowthTallerThanDisplayShrinksToFit`. Owed: near-edge content-height animation vs. frame-correction race on a live screen edge. |
| TP-016 intermittent unpinned auto-hide | **Implemented but unverified** | `MainPanelAutoHidePolicy.isInteractionLocked` (`CornerHoverStateMachine.swift:3-18`) now expires `quickEntryFocus`/`notesEditorFocus` locks once the pointer is outside and 1.5 s have passed without keyboard input; drafts/menus/selections keep independent protection. Owed: live idle-unpinned observation across the stale-lock scenarios. |
| TP-017 two-finger dismissal flicker | **Unverified — mechanism retained, needs physical UAT** | Main-panel swipe path is intact (`AtticPanel.sendEvent` routing, `interactiveSwipeStartProgress` resume, `cancelTrackpadSwipe` on interruption). Flicker is a rendered-motion defect; no source-only classification is honest. Physical trackpad fast-dismiss/cancel under PANEL-005 remains the gate. |
| TP-018 transient reachability | **Implemented but unverified** | The original failure mode (panel gone before the pointer arrived) was a hover-corridor artifact; surfaces are now deliberately opened and latched — pointer position can neither open nor close them (`SubtaskPanelLifecycle` docs, `openTransient` has no unlatched path). The corridor survives only as the inside/outside classifier for outside-click dismissal (`transientClickIsInside`). Lane-5 passed corridor travel in the older model. Recheck remains listed because placement/behavior changed. |
| TP-019 simultaneous-panel placement | **Passed by specific evidence (older build) + recheck owed** | `SubtaskPanelLayout.avoidingOverlap` is fed `occupiedFrames: visiblePinnedFrames` plus the panel frame (`SubtaskPanelController.swift:805,851`); lane-5 natively observed a second transient placed below the pinned panel. Recheck all corners/edges/moved panels on the current build. |
| TP-020 composer/list collision | **Implemented but unverified** | The TP-002 mask + shields make under-composer rows invisible and inert; composer/list geometry is now measured-chrome driven. Owed: independent native check (distinct from TP-002 verification). |
| TP-021 Clear-mode contrast | **Implemented but unverified** | `AtticClearGlassReadabilityPolicy` + `atticClearGlassForegroundReadability()` applied to secondary text, glyphs, captions, errors throughout the panel/surfaces. Owed: reproduce Astra's pale-isolated-surface composition in the normal desktop context. |
| TP-022 under-composer hit-through | **Implemented but unverified** | Shields (`AtticPanelView.swift:113-128`, `SubtaskPanelContent.swift:153-160`) cover the exact "press lands beside the pin/in the fade/on the composer" case; the surface host's `hitTest` owns all presses inside the painted shape; `eventForwardingForTesting` is the instrumentation seam. Owed: native mouse-down/up ownership evidence separating real hit-through from automation timing. |
| TP-023 stranded `confirmingTaskCompletionID` | **Passed by specific evidence** | `releaseFamilyInteractionState` now clears it for surface-hosted children (`SubtaskPanelController.swift:721-722` post-edit — re-verified after the swipe removal); focused test `testTeardownReleasesChildCompletionConfirmation` exists. |
| TP-024 Notes close-refusal focus loss | **Implemented but unverified** | Refusal is decided before any mutation in both switch paths: `AtticPanelView.selectSection` (`:800-807`, comment states the ordering rule) and `CornerHoverMonitor.preparePresentation` (`:197-201`). Gap: no dedicated refusal-order test was found by name — the checklist asks for one. |

## C. Task behavior and attachment gates

Passed with recorded native/unit evidence in older builds (re-verify on final):
TASK-001 (lane-5 saw working Cancel + Complete Anyway), TASK-002 (lane-5;
`SubtaskSortKey` sorts done last), TASK-019 placement (see TP-019).

Implemented in source, need final-build verification: TASK-003 (one-line title,
fade, focus disclosure, `.help`; stale wrapping UI test deleted — QUALITY-007),
TASK-004 (passive glyphs/metadata; attachment preview clicks fall through to the
row), TASK-005 (composer attachments via `TaskComposerAttachments` + pending
strip + plus menu), TASK-006 (`TaskFileDropTarget` whole-surface drop incl.
Subtasks view + per-row `TaskRowDropDelegate`), TASK-007 (`TaskAttachmentGallery`
bounded LazyVGrid, quiet hover remove, Quick Look preview), TASK-008
(`TaskDragPayload` `FileRepresentation` folder export; `TaskImageTests` cover
export), TASK-009 (pinned identity: raise-not-duplicate, only the surface's own
control pins), TASK-010 (`FamilyPanelViewState` view memory, fresh opens on
Subtasks, directional slide/crossfade), TASK-011 (shared
`SubtaskPanelLayout.contentHeight` for both views), TASK-012 (surface
translucency separated from Liquid Glass controls; settings copy not re-inspected
this pass — verify the wording itself).

## D. Panel input/shape gates

- PANEL-001: **implemented but unverified** — header drags only reposition
  (`PanelSurfaceDragGeometry`, `PanelSurfaceHostingView.mouseDown` →
  `performDrag`; `PanelGeometry.swift:321-322` documents collapse reserved to
  swipe/auto-hide).
- PANEL-002: **implemented but unverified** — docking indicator is a separate
  `NSPanel` placed outside the panel frame and `avoidingOverlap`-positioned
  (`AtticPanelController.swift:248-275`), `ignoresMouseEvents`, 28 pt.
- PANEL-003 density, PANEL-004 popovers/notices, PANEL-005 physical gestures,
  PANEL-006 pointer/resize acquisition: **open — live passes owed.** PANEL-005
  explicitly requires a real trackpad; PANEL-006 has the squircle hit-test +
  custom resize-grip machinery (`AtticPanelResizePolicy`) but needs the
  edge/corner/transparent-corner sweep.

## E. Canvas and F. Notes sections

Not exhaustively re-verified this pass (separate lanes/audits own depth). Items
with concrete current-source evidence:

- **CANVAS-008** error presentation has an in-source fix reference
  (`CanvasSession.swift:392` — placement that must not overlap the toolbar);
  native matrix still owed.
- **CANVAS-016** **implemented but unverified** — `CanvasStoreReplicaResolution`
  compares scalar `payloadVersion`/`payload` metadata first and touches blob
  bytes only when they differ (`:12-15, 88-92, 121-146`), ending the
  re-fault-every-image pattern.
- **CANVAS-010** undo history — a byte-aware policy claim was not re-verified;
  keep open pending the reliability/performance audits.
- **CANVAS-017/018** (AX rebuilds on pan/zoom, per-pointer image sorts):
  not re-verified in `CanvasSurface.swift` (only thin AX declarations there);
  the sort/AX logic lives in the Mac interaction files — keep open.
- Remaining CANVAS-001…015: stand as gates for a dedicated canvas pass; the
  earlier ledgers record partial fixes I did not re-audit.
- **NOTES-001** (deleted text returning): `NoteDraftController` now keeps a
  `PersistedSnapshot`, refuses writes on remote-change/missing-original
  conflict, flushes before transitions — **implemented but unverified**; the
  reproduction matrix (selection delete, typing, focus change, hide/reveal,
  relaunch) is owed.
- **NOTES-003/004**: plus/importer/tray flows exist in `NotesPanelContent` —
  partially verified only.
- **NOTES-009**: debounced autosave + flush + conflict/save-error state and
  recovery checkpoint (`checkpointRecovery`) implemented; max-unsaved-interval
  and crash-durability measurement owed.
- **NOTES-012**: notes swipe is scoped to swipes that *begin inside* the notes
  swipe view and route by library state (`AtticPanel.swift:99-104, 118-148`) —
  narrower than the reported ambiguity; live matrix owed.
- **NOTES-013** **implemented but unverified** — `NoteTextReplacement`/
  `NoteInlineAnchor` give O(1) anchor rebasing; diffing is "the fallback for
  external replacements, never the typing path"; per-keystroke full-diff/card
  rerender shape is gone at the model layer.
- Remaining NOTES items (typography, drawer chrome, session state, lifecycle
  invariants, missing-asset recovery, accessibility/theme sweep, late-callback
  stress): stand as gates; several have supporting machinery I did not fully
  trace.

## G. Persistence/attachment findings — all four repaired in source

| Item | Classification | Evidence |
| --- | --- | --- |
| DATA-001 TaskStore CloudKit dormancy | **Passed by specific evidence (source + test; run predates swipe edits)** | `init` gates both observers under `#if !ATTIC_LOCAL_ONLY` (`TaskStore.swift:255-261`); `save()` gates `noteLocalSave`/`reconcileProtectedCloudSyncActivity` (`:1072-1075`); `handleCloudSyncEvent` early-returns under local-only (`:1191-1195`). Dormancy test `TaskStoreTests.swift:106-126` asserts nil observations/tokens after save + synthetic event. |
| DATA-002 private note-attachment exposure | **Passed by specific evidence** | `NoteAttachmentPlatformSupport.openableCopy` hands external editors a disposable read-only copy (`:17-24, 57-75`); task attachments use `TaskImageFiles.openableCopy` with tamper refusal (test: "a changed private copy is refused rather than handed out"). |
| DATA-003 silent paste/promise rejection | **Implemented but unverified** | `importUnavailableMessage()` cites DATA-003 and surfaces busy/conflict/save-error verbatim through `noteStore.setAttachmentError` (`NotesPanelContent.swift:555-590`); `NoteAttachmentImportOutcome.busy` propagates. Owed: a live rejected-paste capture. |
| DATA-004 file deletion vs. surviving references | **Passed by specific evidence** | `TaskStore.swift:731-744` removes files only for references no surviving replica still holds (`storedAttachmentIDs(excludingTaskIDs:)`); test "an attachment held by two tasks is refused" (`TaskAttachmentDropTests.swift:485`). |

## H. Resource/quality gates

- PERF-001 baselines, PERF-003 memory cycles: **open** — owned by the in-flight
  performance audit; no measurements exist yet.
- PERF-002 idle work: **implemented but unverified** — no timer while visible,
  follow-up work is deadline-scheduled; idle-wakeup proof owed.
- PERF-004 broad invalidation: **partially implemented** — snapshot/family-index
  revision caching and per-draft isolation (`TaskRenameField` observes only the
  draft); remaining per-revision fan-out needs profiling.
- PERF-005 predicated fetches: **implemented but unverified** — task replica
  mutations use `#Predicate` id-list fetches (`TaskStore.swift:1136-1150`);
  Note/Canvas refresh paths not fully re-audited.
- PERF-006 energy while visible: **implemented but unverified** — the
  `userInitiatedAllowingIdleSystemSleep` assertion is held only in the
  `.responsive` (hidden, near-corner) cadence
  (`CornerHoverMonitor.swift:413-429`, `CornerHoverStateMachine.swift:58`).
- PERF-007 Canvas incremental sync: not re-verified — keep open.
- PERF-008 Notes refresh/sorting bounds: partially addressed (snapshot +
  index); not re-verified — keep open.
- PERF-009 daily cleanup: **implemented but unverified** —
  `purgeCompleted(before:)` is a predicated fetch (`TaskStore.swift:843-880`)
  and cleanup skips the pre-refresh entirely under `inProcessAuthoritative`
  (`DailyCleanupService.swift:69-80`).
- QUALITY-001 local-first durability: **preserved** — every checked write path
  keeps single-save + rollback + fresh-context reload; deferred-sync machinery
  is dormant in all three stores.
- QUALITY-007 stale tests: **passed** — `testLongTaskTitleWrapsInsteadOfTruncating`
  no longer exists anywhere; the explicit-view test now asserts the
  Subtasks-first contract.
- QUALITY-008 measurable gates: **partially passed** — `TaskPerformanceGateTests`
  and `CanvasPerformanceGateTests` add `XCTClockMetric` + absolute bounds for
  the audited hot paths; drag smoothness, Notes typing, and wakeup/memory gates
  still have no `XCTMetric` coverage.
- QUALITY-009 hit targets: **partially implemented** — compact glyphs get 24 pt
  hit regions via `contentShape` (e.g., pinned-status 8 pt glyph / 24 pt target);
  a full icon-target audit is still owed.
- QUALITY-002…006: process gates — apply to every fix above; the independent
  source + native reviews (QUALITY-005) are the next scheduled step after the
  no-swipe work settles.

## I. Already-fixed protections

Unchanged in current source: drop-callback lifetime repair, expired-deadline
busy-loop repair (the whole hover timer engine is now gone with hover-open),
translucency/glass separation, title-focus disclosure, completion-confirmation
behavior, corridor travel and synthetic dismissal passes (pre-removal; the
dismissal side is re-covered by the new no-swipe tests), pin/move/persist/raise.

## Prioritized next work (bounded)

1. **Land the no-swipe removal.** Wait for `Docs/Rolling-NoSwipe-Implementation.md`
   ending `IMPLEMENTATION_READY`, then: diff vs `/tmp/attic-noswipe-baseline`,
   build + focused suites (`PanelSurfaceHostingViewTests`,
   `SubtaskPanelControllerTests`, `SubtaskPanelTests`, `PanelGeometryTests`),
   independent reviewer dispatch, then native verification that subpanel
   scrolling/pin/move/Escape/outside-click/click-open all behave and main-panel
   swipe is untouched.
2. **One native verification batch over the implemented-but-unverified Section-A
   items** on a single fresh preview: TP-001 resting-row screenshot, TP-002 full
   scroll matrix incl. final header underlay, TP-003 resting hover + click-open,
   TP-005 picker repro attempt, TP-006 pin→drag→unpin→detach repro, TP-007
   oversized-file error, TP-008 drag preview (long names), TP-022 hit-through
   with event instrumentation.
3. **Gesture/interaction UAT:** TP-016 idle-unpinned auto-hide, TP-017
   fast-dismiss flicker, TP-015 edge-resize, TP-018/019 placement/corridor
   recheck, PANEL-005/006 physical sweep.
4. **Measured baselines** (coordinate with the in-flight perf audit, do not
   duplicate): TP-010/PERF-001/002/003 — idle wakeups, scroll frame pacing,
   drag jank capture (TP-009), memory cycles.
5. **Small gaps:** add the TP-024 refusal-order focused test; reword the stale
   "hover dwell" comment at `SubtaskPanelController.swift:316`; decide whether
   TP-008's preview needs an explicit truncation/type-icon; verify TASK-012
   settings copy text.
6. **Deferred section passes, not this round:** CANVAS-001…015 native/toolbar/
   zoom/resize sweep and NOTES typography/drawer/session-state verification —
   schedule as their own lanes rather than expanding this audit.
7. **Update `Docs/ConsolidatedDefectChecklist-2026-09-13.md`** checkboxes only
   after each item's required evidence class lands (native for visual/gesture
   items, measured for perf items) — do not mass-check from this source audit.
