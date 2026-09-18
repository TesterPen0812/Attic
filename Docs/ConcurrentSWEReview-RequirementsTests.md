# Concurrent SWE Review — Requirements Traceability, Regression Tests, Accessibility Contracts, Cross-Feature Integration

**Lane:** 4 of 5 (requirements ↔ tests ↔ accessibility ↔ integration)
**Checkout:** `/Users/taha/Developer/attic-task-panels-v2`, branch `codex/attic-task-panels-v2`
**Baseline HEAD:** `ae6418c1af690e29d15a20344cdb9765a23d3f85` (+ dirty working tree, ~7.6k insertions / 2.1k deletions across 51 tracked files plus untracked sources and tests)
**Requirement sources:**
- `Docs/ConsolidatedDefectChecklist-2026-09-13.md` (sections A–H)
- `pasted-text.txt` task-panel UX checklist (15 sections)
- `AGENTS.md` / `CLAUDE.md` local-first development contract

**Lane constraints honored:** read-only review; no macOS pointer use, no Attic GUI operation, no app launch, no Xcode builds, no broad test suites; no source/test edits; unrelated dirty-tree changes preserved. Evidence classes used: `CONFIRMED` (established directly in source/tests), `STRONG EVIDENCE` (causal fix + meaningful focused tests, native check still owed), `CANDIDATE` (plausible fix, insufficient or contradictory evidence), `PASS` (requirement satisfied at the level this lane can judge), `UNVERIFIED` (cannot be judged without native/rendered evidence this lane was forbidden to gather).

**Primary evidence limitation:** this lane inspects source and test intent only. Every claim whose truth lives in rendered pixels, physical gestures, VoiceOver speech, or measured CPU/memory is marked `UNVERIFIED` even where the implementation looks correct. A separate lane (`Docs/ConcurrentSWEReview-NativeUX-Evidence/`) is capturing native screenshots; those artifacts exist but were not produced or audited here.

---

## 1. Findings

Findings are deduplicated by cause. Severity: P0 = release-blocking/data-loss, P1 = named checklist defect unresolved or requirements contradiction, P2 = real gap with bounded blast radius, P3 = polish.

### F1 — TP-003 vs. implemented hover-open: unresolved requirements contradiction (P1, CONFIRMED)

**Where:** `Attic/Window/SubtaskPanelController.swift:238-245` (`noteRowHover` schedules open), `Attic/Services/SubtaskPanelLayout.swift:22` (`openDwell = 0.35`), `:26` (`familySwitchDwell = 0.075`), `Attic/Views/Panel/TaskFamilyView.swift:57-62` (row `.onHover` reports to controller when family can present).

**Causal chain:** `TaskFamilyView.onHover` → `noteRowHover` → `lifecycle.noteRowHover` schedules `pendingOpen` → `rescheduleTimers` fires `commitPendingOpen` after a 0.35 s dwell → transient subpanel opens. Hovering a task with subtasks still navigates after roughly the "half a second" TP-003 describes.

**The conflict:** TP-003 requires that "a neutral hover should only reveal the row surface/actions; opening the workspace must require a deliberate action," and pasted §13 restates "Neutral task-row hover only highlights the row" and "Hover does not cause unexpected panel navigation." The dirty tree instead implements and tests an elaborate hover-browsing system: ~90 focused controller tests, `AtticUITests/SubtaskHoverPinnedUITests.swift:testHoverDwellOpensTransientAndBriefHoverDoesNot`, corridor-travel physics, and pin promotion — all encoding hover-open as the designed feature.

**Assessment:** This is almost certainly a stale checklist item — the v2 subpanel architecture (dwell, corridor, latch, pinned promotion, pasted §9 "transient panel reachability") presumes hover-open exists. But the checklists as supplied were never amended, so as written the implementation violates TP-003 and pasted §13 literally. The suite cannot simultaneously satisfy "hover opens panels" and "neutral hover only highlights the row."

**Impact:** If TP-003 is still operative, the shipped behavior IS the reported defect. If it is stale, the checklist misleads every reviewer and regression gate that reads it.

**Recommended repair:** Adjudicate explicitly — either amend TP-003/pasted §13 to record hover-dwell-open as approved (the overwhelmingly likely correct resolution), or remove hover-open and gate panels behind deliberate actions only. Do not let the contradiction ship silently.

**Validation required:** product-owner ruling recorded in the checklist; native UAT of the approved behavior.

### F2 — TP-004 violated; new dirty-tree test codifies the violation (P1, CONFIRMED)

**Where:** `Attic/Views/Panel/TaskRowView.swift:399-401` (`"Show attachments"` → `openFamilyPanel(for: task.id, focusEntry: false, view: .attachments)`), `AtticTests/SubtaskPanelControllerTests.swift:1316-1319` (`"Show attachments" opens straight onto Attachments`, asserted `panelView == .attachments`).

**Causal chain:** row `•••` menu → `Show attachments` → `openFamilyPanel(view: .attachments)` → a brand-new task workspace presents on Attachments, not Subtasks.

**The defect:** TP-004 names this exact action: "The row menu's `Show attachments` action can open a new task panel directly in Attachments. A newly opened task workspace must begin on Subtasks." Pasted §3 agrees ("starts on Subtasks by default… users switch views deliberately from inside the subpanel"). The dirty diff *added* the test assertion (verified via `git diff HEAD`: line 933-934 of the diff is `+` — this is newly authored expectation, not a stale leftover). `testMeasuredChromeRequestsARefitForAnAttachmentsFirstPanel` (SubtaskPanelControllerTests.swift:1446) similarly bakes in attachments-first panels.

**Charitable reading:** "Show attachments" is itself a deliberate choice. Rejected — TP-004 explicitly adjudicated that action as the defect, and the checklist's stated rationale is a *predictable entry point*, not "deliberate vs. automatic."

**Impact:** Named defect preserved; the regression suite now makes the eventual fix red. Reviewers reading the test as spec will conclude the wrong contract.

**Recommended repair:** Route `Show attachments` to a Subtasks-first open (or have it open and immediately exercise the in-panel switch per the approved transition), and update the test to assert the approved flow; or get the checklist amended in writing if attachments-first is intended.

**Validation required:** focused test asserting fresh-open-on-Subtasks from every entry path (menu, hover, pin-reveal); native check of the actual first-presented view.

### F3 — Stale UI test asserts the pre-v2 title contract, opposite of TASK-003 (P2, CONFIRMED)

**Where:** `AtticUITests/AtticUITests.swift:613-627`, `testLongTaskTitleWrapsInsteadOfTruncating`: creates a long title and asserts `XCTAssertGreaterThan(title.frame.height, 20)` — i.e., it *requires* multi-line wrapping.

**Causal chain:** TASK-003 + pasted §1 require one-line titles with a trailing fade and stable row height. Current implementation (`TaskRowView.swift:253-261`, `lineLimit(1)` + `fixedSize` + `ViewThatFits` fade mask at `:217-229`) satisfies that, so this test should fail if executed — and more importantly, it encodes the regression it was meant to prevent: if the code ever regresses back to wrapping, this test goes green.

**Why it's a test-quality finding, not a pass:** the test is not part of the dirty diff (stale leftover from before the v2 contract), was never updated to match the new requirement, and its name actively documents the wrong behavior. It is a trap for future reviewers.

**Impact:** A suite reader sees "tested: long titles wrap" while the contract says "never wrap." If it currently fails, it likely gets flagged as noise rather than a contract violation; if it were fixed to pass, the fix would violate TASK-003.

**Recommended repair:** rewrite as a one-line assertion — rendered height stays at row height (`≤` a bound), title is clipped (compare AX label full text vs. visible element width), and fade/full-text access exists — or delete and rely on `testKeyboardFocusDisclosesOnlyClippedTitlesOutsideEditing` + `testTitleExpansionObservesOnlyWhilePresentedInWindow` plus a native screenshot.

**Validation required:** run the focused UI test; capture a screenshot of the clipped-title row.

### F4 — TP-013 family lookup remains O(n·m) per row; only the section snapshot was memoized (P2, STRONG EVIDENCE)

**Where:** `Attic/Services/TaskStore.swift:721-733` (`subtasks(of:)` = `tasks.filter` over all tasks, plus `parent(of:)` at `:716-719` which is a `tasks.first` linear scan *per child*), `Attic/Views/Panel/TaskFamilyView.swift:15-22` (`children` + `summary` computed properties evaluated per body), `Attic/Views/Panel/SubtaskPanelContent.swift:49-51` (same pattern per surface render), `Attic/Views/Panel/TaskRowView.swift:140,406,419,436,446` (five more `subtasks(of:)` call sites in row logic).

**Causal chain:** every `TaskFamilyView` body evaluation filters all tasks for `parentID` and then runs a full `tasks.first` scan for each child found (to validate the parent link). Cost per row ≈ O(n) + O(children·n). With R rendered rows each render pass is O(R·n) minimum; the audit measured ~357 ms for this pattern at 6,000 tasks. `snapshot(for:)` is memoized per `revision` (TaskStore.swift:735-758) but covers only section lists — no revision-keyed family index exists.

**What improved:** `snapshot(for:)` memoization (test `testSnapshotMemoizationStaysCoherentAcrossMutations`, `testScopeSnapshotIsTheSingleSourceForSectionsAndCounts`) removes repeated root-list scans. `LazyVStack` bounds rendered rows.

**What did not:** the specific pattern the audit timed — per-row `subtasks(of:)` + per-child `parent(of:)` scans — is unchanged in structure. `parent(of:)` has no id→task index.

**Impact:** scroll/render cost grows with library size; TP-013's stated "cache/index task families" remedy is only half-delivered.

**Recommended repair:** maintain a revision-keyed `parentID → ordered children` index built in one pass per revision (like `snapshotCache`), and an `id → task` dictionary for `parent(of:)`; then point `subtasks(of:)`/row summaries at it.

**Validation required:** XCTMetric or Instruments timing of row-render at ≥6,000 tasks before/after; focused test that the index invalidates on every mutation path.

### F5 — No performance measurement infrastructure exists; PERF-001/002/003 cannot close (P1, CONFIRMED gap)

**Where:** entire test suite — `grep -rln "XCTMetric|measure(|XCTMemoryMetric|XCTCPUMetric|XCTClockMetric|XCTStorageMetric" AtticTests/ AtticUITests/` returns zero files.

**The gap:** PERF-001 demands controlled baselines (CPU, memory, wake-ups, allocations, frame pacing) across eight named workloads on a signed preview; PERF-002 demands idle≈0; PERF-003 demands bounded memory under repeated heavy workflows. There is no mechanism in the suite that could produce, record, or regress on any of those numbers.

**What exists instead (partial credit):** structural bounded-work tests — `CanvasRenderCacheTests.swift:testDecodeSchedulerStressKeepsNinetySixImagesWithinFourWorkers` (concurrency bound), `testMacViewportCandidatesPreventOffscreenRedecodeChurn` (culling), `NoteDraftControllerTests.swift:testContinuousTypingHasBoundedDurabilityCheckpoint` (bounded write coalescing), `testNativePreviewDemandTracksVisibleCardsWithoutPublishingEveryScrollSample` (scroll-sample discipline), `CornerHoverStateMachineTests.swift:testHiddenFarSamplingIsIdleAndDoesNotHoldResponsivenessActivity` and `testFarPointerMovementDoesNotRequestFullMainThreadSample` (idle-sampling bounds), `SubtaskPanelControllerTests.swift:testWaitingCloseNeverOutlivesReplacementPinDetachOrTeardown` (no lingering timer work). These assert *structural* bounding, never measured cost.

**Impact:** TP-010/TP-011/TP-012/PERF items can accumulate "fixed" labels with no measurement; regressions in CPU/memory/idle wake-ups have no tripwire.

**Recommended repair:** add XCTMetric-based performance tests (or an Instruments-driven measurement harness with recorded baselines in `Docs/`) for the PERF-001 workload list; at minimum a documented `xctrace`/sample-based capture procedure per release.

**Validation required:** recorded baseline artifacts (numbers, not assertions) on the signed preview; rerun protocol documented.

### F6 — CANVAS-010: undo history bound is count-only; byte-aware policy absent and untested (P2, CONFIRMED gap)

**Where:** `Attic/Canvas/CanvasSession.swift` — `maximumHistoryCount = 100` (item count); no byte accounting anywhere in history storage.

**Causal chain:** 100 history entries × large `CanvasPlacedImage` payloads (imported images are stored per-history-command) → memory grows with image size, not count. CANVAS-010 explicitly requires "a byte-aware policy, not only an item count."

**Test coverage:** none — no test asserts history eviction at all (searched `maximumHistory`/byte terms across CanvasSessionTests/CanvasDomainTests; only unrelated `100` constants).

**Impact:** repeated large-image undo/redo cycles — exactly the PERF-003 workload — can grow memory unboundedly within the 100-item window.

**Recommended repair:** track per-command byte cost (image payload dominates) and evict on a total-byte budget in addition to the count; add a focused test asserting eviction order under a forced small byte budget.

**Validation required:** the new focused test plus PERF-003 measurement (F5).

### F7 — TP-007 attachment-failure presentation bounded but still embedded in the composer footer (P3, CANDIDATE)

**Where:** `Attic/Views/Panel/SubtaskPanelContent.swift:663-672` (`errorRow`: 11 pt `systemRed` text, `lineLimit(3)`, `fixedSize(vertical: true)`, rendered inside the footer `VStack` capsule at `:487,497`).

**Causal chain:** store `lastErrorMessage` → `errorRow` inside composer capsule → message is capped at 3 lines (was: unbounded expansion dominating the panel). Improvement is real but partial: the error still competes with composer controls inside the same capsule, uses un-themed `systemRed` (contrast on Clear/translucent surfaces unverified), and has no explicit dismiss affordance — it clears only on the next store state change.

**Impact:** residual crowding on worst-case long errors; possible contrast issue on Clear.

**Recommended repair:** verify the 3-line cap renders acceptably on all themes; consider a dismiss affordance or relocation per TP-007's "compact, readable, dismissible/recoverable" language.

**Validation required:** native screenshot of a long (oversized-video-class) error on each theme.

### F8 — Several icon controls fall below comfortable pointer hit targets (P3, CONFIRMED; mitigated)

**Where:** `TaskComposerAttachments.swift:255-256` (remove × = 16×16), `TaskImageAttachments.swift:354-355` (card remove × = 18×18), `TaskRowView.swift:268-274` (pinned indicator = 16×16). By contrast the note/subpanel chrome controls are 30-40 pt.

**Mitigations present (real):** chip/card removal is reachable via Delete key and VoiceOver `accessibilityActions`; the × is deliberately `.focusable(false)` so it can't steal focus; pinned indicator has label+hint. The deficit is pointer-target size only, not keyboard/VO operability.

**Impact:** fine-grained pointer precision required for destructive-ish actions on transient surfaces.

**Recommended repair:** expand `contentShape`/hit region to ≥24 pt without enlarging the glyph.

**Validation required:** native pointer UAT on the smallest targets; VoiceOver rotor check.

### F9 — Visual/physical items this lane cannot close (UNVERIFIED cluster, P1 gate)

The following have real implementation and/or focused-test evidence, but their pass/fail lives in rendered pixels, physical input, or runtime behavior that this lane was forbidden to exercise. None should be marked passed on source alone:

- **TP-002 chrome masking** — main list gets a top/bottom fade mask (`AtticPanelView.swift:443-461`, `taskScrollMask` LinearGradient; bottom obscured height `taskEntryHeight + 34`); subpanel header gets a 0.92-opacity `windowBackgroundColor` gradient backdrop (`SubtaskPanelContent.swift:147-151`) plus `headerHeight`/`footerHeight` scroll padding (`:600-601`). Structurally correct — whether "text and controls never collide" holds on Clear/translucent themes and during bounce scroll is rendered truth. **UNVERIFIED.**
- **TP-006 ghost panel** — teardown/lifecycle tests exist (`testWaitingCloseNeverOutlivesReplacementPinDetachOrTeardown`, `testControllerWaitingOnALockStillDeallocates`, `testTeardownClearsStaleEntryFocusPointer`, `testDismantledFamilySurfaceReleasesTheOwnersItsDropTargetCaptured`, `testFrameAnimationTargetsBelongToTheirLiveSurfaceOnly`), and the window/state lifecycle has real causal work. The reported repro (pin → drag → unpin → detach → 272×246 ghost + stuck help-tag AX tree) is a live-window failure; must be re-run on the installed build. **CANDIDATE→UNVERIFIED.**
- **TP-008/TP-009 drag preview/jank** — previews are now compact (`TaskImageAttachments.swift:326-332` capsule label w/ icon; `TaskRowView.swift:314-328` material card). Jank is a frame-pacing property; no measurement (F5). **UNVERIFIED.**
- **TP-016 auto-hide** — causal fix present: `CornerHoverStateMachine` strips `.quickEntryFocus`/`.notesEditorFocus` once the pointer is out ≥1.5 s after keyboard input; focused tests `testIdleMainEditorFocusDoesNotPinButDraftAndSubpanelLocksStillProtect`, `testCleanPresentedTaskComposerAllowsAutoHide`; UI tests `testMainPanelIdleRetainsTaskDraftThenHidesCleanEditor`, `testMainPanelIdleHidesAutosavedNoteWithEditorFocus`. Intermittent-live-hide bug class → **STRONG EVIDENCE**, needs soak-time UAT.
- **TP-017 flicker** — `PanelSurfaceHostingViewTests` cover swipe-consumption, completion delay, stale-session restore (`testDecidedSwipeIsConsumedAndCompletesOnlyAfterTheDelay`, `testCompletionDeclinedForAStaleSessionRestoresTheSurface`, `testNewSequenceAndLostKeyRestoreAnUnfinishedGesture`). Rendered flicker is a pixel property. **UNVERIFIED.**
- **TP-018/TP-019 reachability/placement** — corridor transit budget/approach tests (`testCorridorTransitDefersThenClosesOnExitWithoutAnyHoverCallback`, `testPointerReachingTheSurfaceCancelsTheCloseOutright`, `testCrossingPanelsCountOnlyWhereTheyLieOnTheRoute`) and placement tests (`testTransientPlacementAvoidsPinnedFamilyWithoutMovingIt`, all-corner/edge variants) are strong. Physical pointer travel remains to be re-checked. **STRONG EVIDENCE / UNVERIFIED native.**
- **TP-021 Clear-mode contrast** — `atticClearGlassForegroundReadability` is applied pervasively and gated by `AtticClearGlassReadabilityPolicy` (`SubtaskPanelContent.swift:194-201`); SettingsPresentationTests cover Clear availability rules. Contrast *ratios* are a rendered property. **UNVERIFIED.**
- **PANEL-001/002** — drag-to-move is AppKit `performDrag` on `SubtaskWindowDragHandle`/`PanelSurfaceHostingView` hit-routing (`testEveryHeaderPointExceptControlsRoutesToTheHost`); docking indicator is a separate `NSPanel` positioned at the target corner (`AtticPanelController.swift:245-275`), structurally outside the panel. **STRONG EVIDENCE**, native drag check owed.
- **PANEL-005 physical gestures** — sendEvent-level swipe routing (`AtticPanel.swift:63-196`) with intent accumulation, velocity awareness, cancellation, pinned immunity, notes-route arbitration — all unit-tested (`testVerticalAndDiagonalScrollingNeverDismisses`, `testHorizontalSwipeFollowsTheFingersInEitherDirection`, `testCompletionIsVelocityAware`, `testDismissalPresentationIsSubtleAndReduceMotionKeepsOnlyTheFade`, `testPinnedOrIneligibleSurfaceLeavesEveryScrollWithTheContent`). The checklist itself says synthetic gestures don't close this. **UNVERIFIED** by rule.
- **PANEL-006 pointer/resize acquisition** — `AtticPanelResizePolicy` has squircle-aware edge/corner classification with docked-edge locking (`AtticPanel.swift:320-472`) and `PanelGeometryTests`/`PanelSurfaceHostingViewTests` cover routing. Physical edge cases need native UAT. **STRONG EVIDENCE / UNVERIFIED.**
- **Appearance modes** — light/dark/clear palettes resolve via `panelThemePalette`/`surfaceTreatment` with tests (`testTranslucencyChangesSurfaceOnlyWhileControlsStayLiquidGlass`, `testClearIsAvailableOnlyForOriginalAndEffectiveDarkAppearance`, `testAppearanceThemesResolveClearAndGradientControls` UI). Rendered contrast/gradient coverage → **UNVERIFIED.**

### F10 — Cross-feature integration: substantially wired, two residual watch-items (STRONG EVIDENCE overall)

**Verified integration seams (source + focused tests):**

- **Interaction locks compose across features:** `NotesComposerInteractionSnapshot.lockReasons` (`NotesPanelContent.swift:12-24`) maps editor focus/library/importer/blocking-save onto shared `PanelInteractionLockReason`s consumed by `CornerHoverStateMachine` (`testInteractionLockKeepsPanelVisible`, `testNotesComposerInteractionSnapshotSeparatesPresentationFromWork`, `testNotesPresentationLocksOnlyForExplicitWorkReasons`). Picker/composer picker marks (`PanelUIState.swift:51-53`) keep the panel alive and prevent a second picker (`testPickerAndChildPopoverKeepSeparateMarksAndNeitherSilentlyBlocks` — TP-005's causal fix, see below).
- **Swipe routing arbitrates notes vs. panel-dismissal vs. content:** `AtticPanel.swift:63-228` — per-sequence route decided once (`swipeRoute`), notes area swipes go to `notesSwipeTarget` only when direction matches open/close intent (`:144`), Canvas and horizontal-scrollable content are exempted (`contentOwnsHorizontalScrolling`, `:215-228`), `canBeginTrackpadSwipe` re-validates mid-sequence (`:113`). NOTES-012's "narrow scroll monitoring" is delivered as an explicit router rather than a broad monitor.
- **Notes library keeps editor mounted** (selection/scroll/undo preserved) — `NotesPanelContent.swift:137-139` design comment + `allowsHitTesting`/`accessibilityHidden` overlay swap; `NoteDraftController` session fencing makes late AppKit/await callbacks land only on the initiating `editorSession` (`:344-372`, `:196-199`) — NOTES-015's causal fix. Tests: `testQueuedFocusRequestCannotOverrideNewerIntentInSameSession`, `testRapidSwitchRejectsStaleQueuedExternalReplacement`, `testPromisedFileReceiverRetainsInitiatingNoteAfterEditorSwitch`, `testRejectedPromiseCaptureCannotFallBackToCurrentEditor`.
- **Attachment lifecycle invariants** (NOTES-010/TASK): launch sweep with replica-awareness (`testLaunchSweepRemovesOnlyOldUnreferencedCopiesAndKeepsEveryReplicasFiles`, `testLaunchSweepDoesNothingWhenAReplicaIsUnreadableOrAnImportIsRunning`), symlink confinement (`testOwnedFileCleanupNeverActsThroughSymbolicLinks`, `testMaterializedPathConfinesUntrustedFilenameToAttachmentDirectory`), mixed-batch rollback (`testMixedBatchFailureRollsBackEarlierMaterializations`), cancel-cleans-temps (`testCancelledImportDoesNotCreateOwnedFiles`, `testPromisedFileBatchCancellationRemovesLateDeliveredDirectory`), corrupt-repair (`testOnDemandAccessRepairsSameSizeContentCorruption`, `testMissingAttachmentReportsRecoveryAndLocateRejectsDifferentContents`), composer batch generation-fencing (`TaskComposerAttachments.swift:56-75`).
- **Local-first contract (QUALITY-001):** `#if ATTIC_LOCAL_ONLY` → `cloudSyncEnabled: false` (`AppCoordinator.swift:210-216`); CloudKit dev-schema init gated to `DEBUG && !ATTIC_LOCAL_ONLY` (`:188-195`); tests `testLocalOnlyStoreCreatesNoDeferredCloudInfrastructure`, `testLocalOnlyNotesDoNotStartDeferredCloudActivity`, `testLocalOnlyRevealRefreshUsesOneImmediatePassWithoutCloudRetry`, `testCloudConfigurationsUseSeparateEnvironmentStores`, `testDevelopmentFallbackWithoutCloudKitKeepsDevelopmentStore`. Rollback-on-failure is tested at every store seam (`testFailedAddRollsBackAndDoesNotExposeUnpersistedInk`, `testFailedSaveRestoresNote`, `testFailedEditsRestorePersistedValues`, `testFailedSubmitKeepsTheDraftItemsAndTheirCopiesForRetry`). **PASS at source/test level.**
- **Duplicate-UUID safety (contract rule):** presentation dedupes, mutations/deletes apply to every physical replica (`testRefreshHidesDuplicateApplicationIDsWithoutDeletingEitherRow`, `testMutationsAndDeleteApplyToEveryPhysicalDuplicate`, `testSemanticDuplicateMutationFailureDeletionAndRestoreAffectEveryReplica`, `testEqualTimestampDuplicatesAreHiddenWithoutCrossDeviceDeletion`). Done-cleanup uses `completedAt` vs local day (`DailyCleanupServiceTests`). **PASS.**

**Watch-items:**

1. `updateTaskRowFrames` → `repositionTransient` runs `fittingSize` = `host.layoutSubtreeIfNeeded()` synchronously on *every* row-frames publication while a transient is open (`SubtaskPanelController.swift:1138-1162`, `:1239-1244`). `applyFrame` diffs before moving the window, and measured-height refits are threshold-gated (`noteMeasuredListHeight`, `:929-937`), but the expensive layout call itself is uncoalesced and unconditional — the residual core of **TP-011**. **STRONG EVIDENCE of remaining gap** (folded into F4-family perf findings; see §2 TP-011 row).
2. `TaskAttachmentsPopover` (`TaskImageAttachments.swift:383-399`) still surfaces legacy subtask-owned attachments via a headed popover — intentional and keeps old data reachable, but it is a second, differently-styled surface pattern reviewers should recognize as deliberate, not a TP-001-style leftover.

---

## 2. Checklist A–H traceability

Format: item → implementation (files) → tests (meaningful ones named) → status + note.

### A. Confirmed task-panel defects

| Item | Implementation | Tests | Status |
|---|---|---|---|
| **TP-001** hide `•••` at rest | `TaskRowView.swift` reserved 24×24 action footprint, glyph opacity by hover/focus, `.allowsHitTesting(showsRowAffordances)`, `.accessibilityHidden(!showsRowAffordances)` — pixels & AX kept in sync | UI `testCompactComposerAndSubtaskPanels` hovers then asserts `task-actions-*` exists; controller focus tests | STRONG EVIDENCE — pixel-vs-AX sync verified in source; rest-state invisibility needs one screenshot |
| **TP-002** chrome masking | `AtticPanelView.swift:443-461` gradient mask; `SubtaskPanelContent.swift:147-151,600-601` gradient backdrop + chrome padding | none that observe pixels | CANDIDATE — causal mechanism real; "never collide" is rendered |
| **TP-003** neutral hover non-navigational | hover-dwell-open still fully wired (`SubtaskPanelLayout.openDwell=0.35`) | `testHoverDwellOpensTransientAndBriefHoverDoesNot` + ~90 controller tests encode hover-open | **CONTRADICTED — F1** |
| **TP-004** Subtasks entry point | `"Show attachments"` opens directly on `.attachments` (`TaskRowView.swift:400`) | new test asserts the violation (`SubtaskPanelControllerTests.swift:1316`) | **FAIL — F2** |
| **TP-005** picker deadlock | one `NSOpenPanel` at a time via `isPresenting`/`isAvailable` (`TaskImageAttachments.swift:55-115`); owner marks = interaction locks; `panel.begin` + `NSApp.activate()` | `testPickerAndChildPopoverKeepSeparateMarksAndNeitherSilentlyBlocks` | STRONG EVIDENCE — the "enabled-looking dead action" path is closed structurally; offscreen-presentation edge needs native |
| **TP-006** ghost panel | lifecycle teardown ordering, stale-completion gating, drop-target weak capture | `testWaitingCloseNeverOutlivesReplacementPinDetachOrTeardown`, `testControllerWaitingOnALockStillDeallocates`, `testTeardownClearsStaleEntryFocusPointer`, `testDismantledFamilySurfaceReleasesTheOwnersItsDropTargetCaptured` | CANDIDATE — needs the exact pin→drag→unpin→detach repro natively |
| **TP-007** failure presentation | `errorRow` 3-line cap in footer capsule (`SubtaskPanelContent.swift:663-672`) | none observing layout | CANDIDATE — F7 |
| **TP-008** external drag preview | capsule label w/ type icon (`TaskImageAttachments.swift:326-332`); task-drag material card (`TaskRowView.swift:314-328`) | none observing drag image | UNVERIFIED — looks compact in source; rendered truth needed |
| **TP-009** drag jank | staging/copies off main path in `TaskAttachmentDrop`; reveal-context gating | `testStagingReadsFinderOriginalsInPlaceAndCopiesProvidedContentIntoItsOwnedDirectory` etc. | UNVERIFIED — frame pacing unmeasured (F5) |

### B. Intermittent/perf panel items

| Item | Implementation | Tests | Status |
|---|---|---|---|
| **TP-010** interaction lag | structural bounding throughout | none measure | UNVERIFIED — blocked by F5 |
| **TP-011** per-scroll refits | `noteMeasuredListHeight` ≥0.5 pt gate + async refit; `applyFrame` diffs; BUT `fittingSize→layoutSubtreeIfNeeded` still runs per row-frames publication (`SubtaskPanelController.swift:1138-1162`) | `testMeasuredChromeRequestsARefitForAnAttachmentsFirstPanel`, `testPanelContentIdealHeightFollowsTheActiveView` | STRONG EVIDENCE of residual gap — P2 |
| **TP-012** pointer-monitor churn | single monitor w/ 1000 ms idle / 50 ms responsive cadence, event-driven promotion, timer epochs (`CornerHoverMonitor`) | `testHiddenFarSamplingIsIdleAndDoesNotHoldResponsivenessActivity`, `testFarPointerMovementDoesNotRequestFullMainThreadSample`, `testNearCornerHysteresisAvoidsCadenceThrashAndSamplesOnExit`, `testCancelledOrReplacedTimerEpochRejectsStaleHandlers` | STRONG EVIDENCE |
| **TP-013** per-row data work | `snapshot(for:)` memoized per revision; `subtasks(of:)`/`parent(of:)` still O(n) scans per row | `testSnapshotMemoizationStaysCoherentAcrossMutations` | PARTIAL — F4, P2 |
| **TP-014** reveal-time refresh stalls | `RevealRefreshPolicy.singleEventDrivenPass` local-only | `testLocalOnlyRevealRefreshUsesOneImmediatePassWithoutCloudRetry` | STRONG EVIDENCE |
| **TP-015** constrained resize | `refreshSurfaceSizes` re-fits + re-clamps all surfaces; docked-edge-locked resize (`allowedResizeEdges`) | `testPinnedGrowthBelowDisplayEdgeClampsInside`, `testPinnedGrowthTallerThanDisplayShrinksToFit` | STRONG EVIDENCE / native recheck owed |
| **TP-016** unpinned auto-hide | editor-focus locks expire after pointer-out + 1.5 s keyboard quiet (`CornerHoverStateMachine`) | `testIdleMainEditorFocusDoesNotPinButDraftAndSubpanelLocksStillProtect`, UI `testMainPanelIdleRetainsTaskDraftThenHidesCleanEditor`, `testMainPanelIdleHidesAutosavedNoteWithEditorFocus` | STRONG EVIDENCE — soak UAT owed |
| **TP-017** dismissal flicker | swipe consumed & completed after delay; stale-completion restore | `testDecidedSwipeIsConsumedAndCompletesOnlyAfterTheDelay` + 5 sibling tests | UNVERIFIED pixels |
| **TP-018** transient reachability | corridor transit budget + approach progress + arrival cancel | `testCorridorTransitDefersThenClosesOnExitWithoutAnyHoverCallback`, `testPointerReachingTheSurfaceCancelsTheCloseOutright`, UI `testPointerCorridorAndInsideHoverKeepTransientOpen`, `testExitingTheGapWithoutEnteringSurfaceStillCloses` | STRONG EVIDENCE |
| **TP-019** simultaneous placement | `transientFrame` uses `occupiedFrames` (pinned) for collision avoidance; all-corner clamps | `testTransientPlacementAvoidsPinnedFamilyWithoutMovingIt`, `testTransientFrame*` ×5 | STRONG EVIDENCE |
| **TP-020** composer/list collision | list bottom padding `contentInsets.bottom + taskEntryHeight + 54` (`AtticPanelView.swift:428`) + mask | — | CANDIDATE — geometry in source; visual recheck owed |
| **TP-021** Clear contrast | `atticClearGlassForegroundReadability` policy-gated | `testClearIsAvailableOnlyForOriginalAndEffectiveDarkAppearance` | UNVERIFIED — contrast ratios are rendered |

### C. Task behavior regression gates

| Item | Implementation | Tests | Status |
|---|---|---|---|
| **TASK-001** calm completion confirm | `.alert("Complete this task?")` w/ Complete anyway + Cancel (`TaskRowView.swift:119-131`) | UI `testCreateAdvanceCompleteAndOpenContextMenu` path exercises menus | PASS (source) — rendered calmness trivial to eyeball natively |
| **TASK-002** completed sort | sections group by status; `subtasks(of:)` sorts done last (`TaskStore.swift:724-725`) | `testOrderingUsesPriorityThenMostRecentUpdate`, `testDropIntoSectionChangesStatusOnlyAcrossSections`, `testTaskTransitionsAndRestoreMaintainCompletionDate` | PASS |
| **TASK-003** one-line titles | `lineLimit(1)` + `fixedSize` + fade mask + `TaskTitleExpansion` focus disclosure + `.help` tooltip + AX label (`TaskRowView.swift:202-261`) | `testKeyboardFocusDisclosesOnlyClippedTitlesOutsideEditing`, `testTitleExpansionObservesOnlyWhilePresentedInWindow`; **stale `testLongTaskTitleWrapsInsteadOfTruncating` contradicts — F3** | PASS (source) + stale-test finding |
| **TASK-004** passive metadata | `subtaskProgress` plain `Text` w/ help + AX value (`TaskRowView.swift:330-339`); attachment preview `.fixedSize()` non-button | UI test asserts `app.buttons["subtask-progress-*"].exists == false` (AtticUITests.swift:461) — direct negative assertion | PASS (source+UI intent) |
| **TASK-005** composer attachments | `TaskComposerAttachments` gen-fenced batches, limits, cancel; strip above text row (`TaskComposerAttachments.swift`, `AtticPanelView.swift:488-490`) | `testComposerAttachmentsBindToTheNewTaskInItsSingleSave`, `testFailedSubmitKeepsTheDraftItemsAndTheirCopiesForRetry`, `testRemovingOrCancellingDeletesOnlyTheComposersOwnCopies`, `testComposerLimitsCountItemsAlreadyPending` | PASS (source) — upward growth rendered check owed |
| **TASK-006** task-level drops | `TaskFileDropTarget` on rows + whole surface; `TaskDropOverlay` w/ message; drop latches hover panel (`SubtaskPanelContent.swift:283-298`) | `testDroppedFilesAttachToTheParentAndDiscardOnlyTheirStaging`, `testImportedAttachmentsRevealOnlyWhereTheUserStillExpectsThem`, `testEndingADropClearsEveryPanelHighlightSource`, `testEveryRowDropEndsThePanelHighlightIncludingReorders` | STRONG EVIDENCE — restrained-overlay look + scroll non-interference are visual |
| **TASK-007** bounded gallery | 2-col `LazyVGrid`, compact cards, hover/focus ×, max-height scroll | `testGalleryCardCopiesIntoAnotherTaskButNeverIntoItsOwnOwner`, `testGalleryCardDropRevalidatesTheMarkerAndTheVerifiedSource` | PASS (source) |
| **TASK-008** export drags carry attachments | `TaskDragPayload(taskID:title:imageReferences:)` (`TaskRowView.swift:142`) | `testTaskDragPayloadExportsInternalDataAndPlainText`, `testExternalDragStartsPendingTasksWithoutReopeningDoneTasks` | STRONG EVIDENCE — actual Finder-drop materialization is native |
| **TASK-009** pinned identity | pin/unpin only on panel chrome; row pin indicator = quiet status revealing existing window | `testRowActivationForChildlessParentOpensAndPinnedFamilyRaisesWithoutDuplicate`, UI `testPinnedFamilyShowsQuietStatusThatRevealsPanel`, `testPinnedWindowDragsAndRepinsAtCurrentPopoverPosition` | PASS (source+UI) |
| **TASK-010** stable transition | per-family `FamilyPanelViewState`; fresh opens on `.subtasks`; view switch beside composer w/ destination icon | `testFreshOpenStartsOnSubtasksAndMovementKeepsTheChosenView`, `testViewSwitchPagesBothLayersTheSameWay`, `testViewSwitchNamesItsDestination`, `testBrowsingToAnotherFamilyOpensItOnSubtasks` — **but see F2 for the attachments-first exception** | PASS except entry-point carve-out (F2) |
| **TASK-011** dynamic sizing | shared `SubtaskPanelLayout.contentHeight` for both views; max list height 240 + scroll | `testBothViewsShareTheListMaximumAndSizeToTheirContent`, `testClampedListHeightBounds`, `testSurfaceSizeStaysInsideTheSpecifiedBounds`, UI `testLargeFamilyKeepsSurfaceHeightBounded` | PASS (source) — smoothness rendered |
| **TASK-012** translucency surfaces-only | `panelSurfaceTreatment` vs. `atticGlassControl` separation; settings copy "Changes the panel surface. Controls always use Liquid Glass." | `testTranslucencyChangesSurfaceOnlyWhileControlsStayLiquidGlass` | PASS (source+test) — rendered check owed |

### D. Panel input/shape gates

| Item | Implementation | Tests | Status |
|---|---|---|---|
| **PANEL-001** header drag never collapses | `SubtaskWindowDragHandle.mouseDownCanMoveWindow` + drag-geometry excludes controls; collapse only via swipe/hide paths | `testHeaderDragRegionExcludesItsControls`, `testHeaderDragRegionFollowsCornerAwarePadding`, `testUnmeasuredHeaderDoesNotStealAControlPress`, UI `testPinnedHeaderControlPressDoesNotDragTheWindow` | STRONG EVIDENCE |
| **PANEL-002** dock indicators outside panel | separate `NSPanel` at target corner (`AtticPanelController.swift:245-275`) | none observing | STRONG EVIDENCE (structural) / native look owed |
| **PANEL-003** deliberate density | consistent `AtticStyle` metrics; hit sizes 30-40 mostly | — | CANDIDATE — subjective, native review; small-target outliers in F8 |
| **PANEL-004** calm notices | bounded errorRow, conflict controls, recovery warning, delete/completion alerts | — | CANDIDATE — F7; needs rendered sweep of all notice states |
| **PANEL-005** physical gestures | sendEvent router + intent/velocity/cancel (`AtticPanel.swift:63-236`) | `testVerticalAndDiagonalScrollingNeverDismisses`, `testHorizontalSwipeFollowsTheFingersInEitherDirection`, `testCompletionIsVelocityAware`, `testDismissalPresentationIsSubtleAndReduceMotionKeepsOnlyTheFade`, `testPinnedOrIneligibleSurfaceLeavesEveryScrollWithTheContent`, UI `testEscapeDismissesSurfacesOutsideFieldEditing` | UNVERIFIED — checklist requires real-device UAT |
| **PANEL-006** acquisition | squircle-aware resize policy, docked-edge locking, transparent-corner exclusion | `PanelGeometryTests`, `testEveryHeaderPointExceptControlsRoutesToTheHost`, `testEmptySurfaceOwnsEveryPaintedPointAcrossCornerSizes`, UI `testPinnedSurfaceAbsorbsInertPaddingInsteadOfPassingThrough`, `testTransientCornerIsOutsideAndPaddingIsInside` | STRONG EVIDENCE |

### E. Canvas

| Item | Implementation | Tests | Status |
|---|---|---|---|
| **CANVAS-001** toolbar audit | `CanvasPanelContent` tools w/ AX identifiers, `v/p/e` shortcuts | UI `testModeDockExpandsOnHoverAndCollapsesAfterPointerLeaves`, `testModeDockExposesExactlyOneAccessibilitySelectionAcrossTransitions` | STRONG EVIDENCE / native audit owed |
| **CANVAS-002** precise pencil | two-tone cross cursor, hotspot = draw point (`CanvasSurfaceMacHelpers.swift:528-551`) | `testToolbarUsesArrowAndRejectsDrawingEvenWhenPenIsSelected` (hotspot assert), `testCanvasCursorRoleFollowsToolAndPlacementMode` | STRONG EVIDENCE — visibility on dark/light content is rendered but the two-tone design is inherently high-contrast |
| **CANVAS-003** arrow over toolbar | `excludedControlRects` → `.arrow` + drawing rejected (`CanvasSurfaceMacHelpers.swift:606`, `CanvasSurfaceMac.swift:534-535`) | `testToolbarUsesArrowAndRejectsDrawingEvenWhenPenIsSelected` | PASS (source+test) |
| **CANVAS-004** Add Shape hover parity | needs visual comparison — controls share `atticGlassControl` pattern | — | UNVERIFIED |
| **CANVAS-005** full-panel surface | `CanvasPanelContent` fills workspace w/ explicit `mainControlRects` exclusion (`AtticPanelView.swift:384-397`) | — | STRONG EVIDENCE |
| **CANVAS-006** shape resize | handle hit-testing post-zoom/pan, shift-aspect, min sizes | `testResizeHandleHitTestingUsesViewCoordinatesAfterZoomAndPan`, `testSemanticShapeResizesFreelyAndShiftPreservesAspectRatio`, `testDefaultPlacementPreservesExtremeAspectRatio`, `testResizePreservesAspectRatioAndOppositeCorner` | STRONG EVIDENCE |
| **CANVAS-007** zoom | `CanvasViewport` 0.25-8 bounds, finite guards, anchor-preserving zoom, pinch/scroll arbitration | extensive viewport/domain tests (`CanvasDomainTests`, `CanvasSessionTests`) | STRONG EVIDENCE — momentum/physical pinch native |
| **CANVAS-008** error presentation | `CanvasPanelContent` error banner + retry affordance `bottomOverlayInset` clears controls | `testImportReportsProgressAfterEveryCompletedFile`-style domain tests | CANDIDATE — placement coded; rendered overlap check owed |
| **CANVAS-009** large-image stalls | decode scheduler bounded to 4 workers, viewport culling, memoized failures | `testDecodeSchedulerStressKeepsNinetySixImagesWithinFourWorkers`, `testMacViewportCandidatesPreventOffscreenRedecodeChurn`, `testDecodeFailureIsMemoizedAndRetryInvalidatesStablePlaceholder` | STRONG EVIDENCE — true stalls need measurement (F5) |
| **CANVAS-010** byte-bound history | count-only (`maximumHistoryCount=100`) | none | **FAIL — F6** |
| **CANVAS-011** drag fail/cancel | import task tracking + cancel, generation fencing | `testCancellationStopsInFlightPreparationCleansTemporaryFilesAndDoesNotSave`, `testOutOfOrderCompletionIsBoundedStableAndPersistsSuccessfulItemsOnce`, `testDeliveryFailureKeepsStablePerItemResultAndCleansBatchResources`, `testDecodeCompletionAfterPageSwitchPersistsOnlyToCapturedTarget` | STRONG EVIDENCE — real Finder promises native |
| **CANVAS-012** missing/corrupt assets | failed-image tracking, retry request state, malformed payload retained-not-rendered | `testMalformedPayloadIsRetainedButNotRendered`, `testInvalidImageSnapshotIsRejectedWithoutPersistingIt`, `testDecodeFailureIsMemoizedAndRetryInvalidatesStablePlaceholder` | STRONG EVIDENCE — recovery UI rendered check owed |
| **CANVAS-013** viewport persistence | viewport state in session persistence; per-page content | `testCanvasSwitchFlushesPendingHistoryAndSelection`, UI `testCompletedInkSurvivesSectionsSettingsAndRelaunch`, `testSemanticTextAndShapesEditTransformUndoAndSurviveRelaunch` | STRONG EVIDENCE — checklist wants installed-app evidence |
| **CANVAS-014** semantic objects | editable semantic text/shapes implemented (not ink) — decision doc `CanvasSemanticObjectsDecision.md` | `CanvasDomainTests` semantic suite (~40 tests) + UI `testSemanticTextAndShapesEditTransformUndoAndSurviveRelaunch` | PASS (implemented semantics path chosen) |
| **CANVAS-015** rapid input | buffered gesture coalescing, exactly-one-completion | `testLongGestureCompactsWithoutLosingItsEndpoints`, `testPointerUpCompletesExactlyOneBufferedOperation` | STRONG EVIDENCE — backlog under real input is runtime |

### F. Notes

| Item | Implementation | Tests | Status |
|---|---|---|---|
| **NOTES-001** deleted text returning | persisted-snapshot compare before every write → conflict instead of silent overwrite; autosave gen-fencing; flush before all transitions (`NoteDraftController.swift:387-468`) | `testSelectionDeletionSurvivesReentrantRenderBeforeTextDidChange`, `testSwitchingNotesFlushesThePreviousDraftToItsOwnRecord`, `testCancelledAutosaveCannotWriteThePreviousDraftIntoTheNewSelection`, `testRemoteDeletionPreservesDirtyDraftWithoutResurrectingTheNote` | STRONG EVIDENCE — original repro is race-shaped; native soak owed |
| **NOTES-002** typography | title 19 pt, status 9.5 pt, compact rows/cards | — | CANDIDATE — needs rendered pass vs. panel language |
| **NOTES-003** consolidated actions | 3 floating glass controls: Saved notes / Attach / New note (`NotesPanelContent.swift:401-437`); no Save command (autosave) | — | PASS (source) |
| **NOTES-004** attachment entry | `fileImporter` multi + `dropDestination` + promised-file receiver + cancel | `testImportPreservesFinderOrderAndDuplicateFilenames`, `testImportRejectsDirectoriesAndSymbolicLinks`, `testImportEnforcesPerFileAggregateAndCountLimits`, `testPromisedFileBatchTimesOutOnceAndRemovesTemporaryDirectory` | STRONG EVIDENCE |
| **NOTES-005** compact cards | `NoteInlineCard` w/ `displayHeight ?? 56`, `NoteMovableAttachmentCard` | `testInlineCardReservesSpaceBetweenParagraphsWithoutChangingText`, `testInlineCardIsAHitTestableDocumentSibling` | STRONG EVIDENCE — "compact like reference" rendered |
| **NOTES-006** inline editing | `NoteInlineAnchor.moved` re-anchors on text edits; placeAttachment offsets | `testPlacementReorderingResizingAndBodyEditsPersistTogether`, `testAnchorsFollowTextInsertionsDeletionAndUnicode` | STRONG EVIDENCE — keyboard selection/drag-out native |
| **NOTES-007** Saved Notes drawer | squircle-36 surface, floating controls, notes scroll beneath chrome, no title bar (`NotesPanelContent.swift:708-775`) | — | PASS (source) — rendered check owed |
| **NOTES-008** session state | `editorViewStates` per note (selection + scrollY) + `sessionDefaults` restore + mounted-under-overlay | `testSavedEditorSessionRestoresNoteSelectionAndScrollWithoutWritingNoteTextToDefaults` | STRONG EVIDENCE |
| **NOTES-009** autosave durability | 500 ms trailing debounce + 5 s maximum cap (unmoved by typing) + recovery file + conflict status + retry | `testContinuousTypingHasBoundedDurabilityCheckpoint`, `testFailedSaveKeepsDraftAndExposesRetryUntilSuccess`, `testNeverSavedDraftSurvivesFailedSaveAndControllerRelaunch`, `testInaccessibleRecoveryDirectoryIsNotTreatedAsMissing` | PASS (defined + tested) |
| **NOTES-010** lifecycle invariants | sweep/reconcile/orphan cleanup central in `NoteStore`/`AttachmentFileStore` | `testReconcileRemovesOnlyUnreferencedMaterializations`, `testMalformedReplicaDoesNotAbortValidRepairOrOrphanCleanup`, `testSourceCanDisappearAfterImportAndMissingMaterializationIsRebuilt` | STRONG EVIDENCE |
| **NOTES-011** corrupt recovery | `reportUnavailableAttachment`, locate-with-verify, recovery error w/ Retry | `testMissingAttachmentReportsRecoveryAndLocateRejectsDifferentContents`, `testLocateRejectsChangedMetadataInFreshContextBeforeRestoringPayload`, `testOnDemandAccessRepairsSameSizeContentCorruption` | STRONG EVIDENCE — choice UX rendered |
| **NOTES-012** swipe ambiguity | `notesSwipeTarget` + route arbitration (`AtticPanel.swift:118-148`) — swipe in notes area toggles library, never dismisses | UI-level via `testNotesEditorKeepsDraftWhileBrowsingSavedNotes` | STRONG EVIDENCE — physical swipe native |
| **NOTES-013** large-library scale | `orderedNotes()`/`attachments(for:)` recompute per render (same O(n) family as F4); preview demand limited to visible cards | `testNativePreviewDemandTracksVisibleCardsWithoutPublishingEveryScrollSample`, `testPreviewDemandStopsForHiddenWindowOcclusionAndLibraryWithoutScrolling`, `testEditorReadabilitySkipsFullRangeWorkForUnchangedTypingState` | PARTIAL — structural bounding good; no measurement (F5); `orderedNotes()` not memoized |
| **NOTES-014** a11y/theme | labels/identifiers pervasive; conflict/recovery/save-status have AX ids | — | UNVERIFIED — see §3 |
| **NOTES-015** late callbacks | `editorSession` generation fencing; `recordEditorViewState`/`completeAttachmentImport` session-gated; import task cancelled on disappear | `testEditorSessionIsStableWhileTypingAndAdvancesOnReplacement`, `testQueuedFocusRequestCannotOverrideNewerIntentInSameSession`, `testRapidSwitchRejectsStaleQueuedExternalReplacement`, `testPromisedFileReceiverRetainsInitiatingNoteAfterEditorSwitch` | STRONG EVIDENCE |

### G/H. Resource & quality gates + fixed protections

| Item | Evidence | Status |
|---|---|---|
| **PERF-001/002/003** | no measurement infra (F5); structural bounds only | **FAIL as gate — cannot close** |
| **QUALITY-001** local-first | `ATTIC_LOCAL_ONLY` gating + local stores + rollback tests everywhere | PASS (source/tests) |
| **QUALITY-002** focused+full regression | extensive focused tests exist for every fix family; project-gen verification per contract (not run in this lane) | PASS (process) |
| **QUALITY-003/004** visual evidence | lane-5 `ConcurrentSWEReview-NativeUX-Evidence/` has 22 captures from 2026-09-13 21:08–21:20 | UNVERIFIED here — belongs to the native lane |
| **QUALITY-005** independent reviews | this is one of them | in progress |
| **QUALITY-006** Luna integration | checklist itself consolidates Luna items (TP-020) | PASS (doc) |
| **H protections** | file-drop callback lifetime (weak capture, `configureFileDrop`), hover-close busy-loop (wait-once + pointer-judge), translucency/control split | protected by tests `testProtectedHoverCloseWaitsWithoutRetryingAndClosesOnceTheLockLifts`, `testRepeatedProtectedDeadlinesEachWaitOnceAndResumeJudgesThePointer`, `testFamilyDropCallbacksKeepRoutingWithoutRetainingTheirTarget` | PASS |

---

## 3. Pasted UX checklist traceability (sections 1–15)

| § | Verdict | Evidence |
|---|---|---|
| 1 Main panel | PASS w/ UNVERIFIED visuals | single-line + fade (`TaskRowView.swift:217-229`); full text via tooltip/AX/focus-disclosure/editing; compact passive metadata; glass controls. Rendered polish owed. |
| 2 Row actions | STRONG EVIDENCE | reserved 24×24 footprint, opacity+AX synced reveal on hover/focus; UI hover test. |
| 3 Task subpanel | PASS **except** entry-point carve-out (F2) and two-primary-views satisfied (`Subtasks`/`Attachments`, switch beside composer, destination icon, per-view composer labels `Add subtask…`/`Add attachment…`). |
| 4 Transition | STRONG EVIDENCE | directional slide+opacity 0.22 s; Reduce Motion → opacity only (`SubtaskPanelContent.swift:447-452`); `testViewSwitchPagesBothLayersTheSameWay`. Flicker-free is rendered. |
| 5 Dynamic sizing | PASS (source) | shared `contentHeight`, max 240 + scroll, stable header/footer via padding model; `testBothViewsShareTheListMaximumAndSizeToTheirContent`. |
| 6 Attachments view | PASS (source) | unified gallery, 2-col compact thumbs+file cards, hover ×, no permanent toolbar, Quick Look/Open via verified copies. |
| 7 Drag & drop | STRONG EVIDENCE | row+surface drops to parent incl. while Subtasks shows; restrained `TaskDropOverlay` "Drop to attach to X" keeps content visible; switch+entrance animation; drop target tests thorough. Scroll non-interference rendered. |
| 8 Pinned panels | PASS (source+UI) | quiet 16 pt pin indicator w/ label+hint reveals existing window; no duplicate panel (`testRowActivationForChildlessParentOpensAndPinnedFamilyRaisesWithoutDuplicate`); UI `testPinnedFamilyShowsQuietStatusThatRevealsPanel`. Small target noted (F8). |
| 9 Transient reachability | STRONG EVIDENCE | corridor transit budget, approach progress, arrival cancel, crossing-pinned counting; controller + UI tests. Physical recheck owed (TP-018). |
| 10 Two-finger dismissal | STRONG EVIDENCE / UNVERIFIED physical | finger-tracking scale+fade, velocity-aware, cancellable, pinned-immune, vertical-scroll safe, Reduce Motion fade-only — all unit-tested; real-device owed per PANEL-005. |
| 11 Composer attachments | PASS (source) | picker+drag-in, pending strip grows upward, chips removable pre-submit, gen-fenced cancel, single-save bind, collapse on `didBind`. |
| 12 Appearance settings | PASS (source+test) | surface-vs-control split + explicit settings copy; `testTranslucencyChangesSurfaceOnlyWhileControlsStayLiquidGlass`. |
| 13 Hierarchy/polish | **CONTRADICTED on the hover clause** (F1) — "neutral hover only highlights the row" vs implemented hover-open. Other clauses (title prominence, quiet metadata, subdued actions) satisfied in source. |
| 14 Regressions | STRONG EVIDENCE | completion/reorder/subtask/pin/move/scroll/menus/preview/open all have focused or UI tests; duplicate-safe mutation preserved; drop cleanup tested. Native sweep owed. |
| 15 Evidence contract | PARTIAL | this report supplies per-item status + responsible files + test names; screenshots belong to the native lane; unrequested changes: none by this lane. The stale/contradictory tests (F2, F3) are discrepancies the authors should have flagged per §15 — they were not flagged in-tree. |

---

## 4. Test-suite quality assessment

**Overall:** ~23.3k lines of focused tests across 28 unit files + 3 UI files. The suite is unusually behavior-oriented — tests assert outcomes (rollback, fencing, ordering, eligibility) rather than implementation internals, and the UI tests use stable `accessibilityIdentifier`s to exercise the real app. Specific quality judgments:

**Meaningful (judge as real coverage):**
- Rollback/durability tests assert persisted state after injected failures (`testFailedAddRollsBackAndDoesNotExposeUnpersistedInk`, `testFailedFlushKeepsDraftActiveAndPreventsSwitching`) — behavior, not mirroring.
- Fencing tests use session/generation identity (`testDecodeCompletionAfterPageSwitchPersistsOnlyToCapturedTarget`, `testEditorSessionIsStableWhileTypingAndAdvancesOnReplacement`) — they would genuinely fail if the guard were removed.
- Eligibility tests (`testPinnedOrIneligibleSurfaceLeavesEveryScrollWithTheContent`, `testSwipeDismissalIsOfferedOnlyToTheFamilysUnpinnedIdleSurface`) cover the negative space, not just happy paths.
- UI test `testCompactComposerAndSubtaskPanels` asserts `app.buttons["subtask-progress-*"].exists == false` — a rare real check that metadata is passive.
- Cancellation/timeout branches exist where checklist demanded: `testPromisedFileBatchTimesOutOnceAndRemovesTemporaryDirectory`, `testPromisedFileBatchCancellationRemovesLateDeliveredDirectory`, `testCancelledImportDoesNotCreateOwnedFiles`.

**Weak or flagged:**
- **Stale:** `testLongTaskTitleWrapsInsteadOfTruncating` (F3) — asserts the opposite contract.
- **Contradictory:** `testExplicitViewRequestsAndSubtaskEntryChooseTheirView` (F2) and `testMeasuredChromeRequestsARefitForAnAttachmentsFirstPanel` — newly authored tests that encode the TP-004 defect.
- **Cannot observe claimed UI:** all rendered claims (fade mask, gradient chrome, drop overlay look, Clear contrast, transition smoothness, drag preview) rest on source + AX-identifier presence. The suite has zero pixel/render assertions; the only geometry-observing UI test (`frame.height` assertions) is the stale one.
- **Missing negative branches:** no test asserts hover-open is *prevented* for non-hover-worthy families at the UI level (controller tests cover `canPresentPanel` gating; a UI-level "hover on childless row does nothing" is absent — minor); no test for picker-cancel path of `TaskAttachmentPicker.present` (completion-with-empty is covered implicitly by `guard !urls.isEmpty`, but no focused test).
- **Missing perf bounds:** entire class (F5).
- **Mirroring risk (low):** some layout tests assert constants against the same constants (`testTimingBudgetsStayWithinTheIntendedFeel` compares `openDwell`/`familySwitchDwell`/`closeGrace` relationships — acceptable because the asserted relationships are the contract, not the values).

---

## 5. Accessibility contracts

**Reduce Motion:** `reduceMotion ? nil : …` gating is pervasive and *consistent in policy* — transitions degrade to opacity (`SubtaskPanelContent.swift:448`, drawer at `NotesPanelContent.swift:188-192`), dismissal keeps only the fade (`testDismissalPresentationIsSubtleAndReduceMotionKeepsOnlyTheFade`), `accessibilityDisplayShouldReduceMotion` also gates AppKit window animations (`SubtaskPanelController.swift:1213`). **STRONG EVIDENCE** — this is the one accessibility contract that is testable and tested.

**VoiceOver/AX:** identifiers and labels are pervasive and intentional (`task-row-*`, `subtask-panel-*`, `note-*`, `canvas-*`, `quick-entry-*`); `accessibilityHidden` mirrors visual hidden state for `•••` (TP-001's "visible pixels and accessibility semantics in sync" is literally coded); row exposes `accessibilityActions` for keyboard/VO activation; pinned indicator has label+hint; conflict/error/recovery states have stable ids for test reachability. **Not verifiable here:** rotor order, announcement quality, help-tag behavior (relevant to TP-006's stuck help-tag), actual VoiceOver traversal. **UNVERIFIED.**

**Keyboard / Full Keyboard Access:** `v/p/e` canvas shortcuts, `⌘⇧L` notes library, Escape semantics layered correctly (field-level `onExitCommand` cancel vs. window dismissal — `testEscapeDismissesSurfacesOutsideFieldEditing`), Space/Return previews, Delete removes, `.focusable(false)` on decorative × prevents focus theft, `focusedControl` enum drives row-level focus disclosure. **STRONG EVIDENCE** for the contract; physical FKA traversal owed.

**Hit targets:** mostly 30–40 pt; three 16–18 pt outliers (F8).

**Appearance/contrast:** theme palettes, Clear-glass readability policy, `colorSchemeContrast` increased-contrast strokes, `reduceTransparency` honored in treatment resolution. Ratios unverifiable without rendering. **UNVERIFIED.**

---

## 6. Important areas that passed

Recorded per the audit contract — these are not just "present," they have causal implementation plus focused tests:

1. **Local-first durability (QUALITY-001):** `ATTIC_LOCAL_ONLY` → `cloudSyncEnabled:false`; no dormant CloudKit infrastructure starts locally; rollback-on-failure tested at every store seam (task, note, canvas, attachments).
2. **Duplicate-UUID safety:** presentation dedupe + all-replica mutation/deletion + divergent-duplicate cleanup guard — tested (`testMutationsAndDeleteApplyToEveryPhysicalDuplicate`, `testSemanticDuplicateMutationFailureDeletionAndRestoreAffectEveryReplica`, `testEqualTimestampDuplicatesAreHiddenWithoutCrossDeviceDeletion`).
3. **Autosave durability definition (NOTES-009):** 500 ms debounce + 5 s hard cap + recovery journal + conflict states — the requirement was to *define and test* a bound; it is defined and tested.
4. **Session/generation fencing (NOTES-015, TP-006 class):** editor-session and surface-generation identities gate every late callback — the most important correctness pattern in the diff, and it is tested end to end.
5. **Idle-work bounding (PERF-002 structural half):** event-driven pointer monitoring, no busy loops (the 70k-callback/s failure mode is now a tested wait-once policy), no perpetual animation timelines found.
6. **Subpanel hover/pin state machine:** ~90 controller tests + 16 UI tests covering dwell, corridor, latch, pin promotion, multiple pinned families, teardown — whichever way F1 resolves, the machinery itself is deeply verified.
7. **Attachment lifecycle invariants:** staging→private-copy→bind flow with generation-fenced cancellation, launch sweep, symlink confinement, corrupt-repair — NOTES-010's "centralize invariants" is real.
8. **Swipe router (AtticPanel.sendEvent):** single-decision routing across hide/notes/content with mid-gesture invalidation — the right architecture for NOTES-012 + PANEL-005; unit-tested.
9. **Canvas domain correctness:** bounded decode concurrency, viewport culling, generation-fenced imports, malformed-payload retention, per-page isolation — strong test wall.
10. **Two-primary-view subpanel contract:** exactly Subtasks/Attachments, deliberate switch beside composer, destination-icon control, per-view composer labels, shared sizing — matches pasted §3-5 (minus the F2 entry-point exception).

---

## 7. Required follow-up validation (handoff to native/measurement lanes)

1. **Adjudicate F1 (TP-003)** before any verdict on the subpanel feature — the checklist and the code disagree about whether hover-open may exist.
2. **Fix or adjudicate F2 (TP-004)** — named defect with a new test encoding it.
3. **Rewrite the stale title test (F3)** to assert the single-line contract.
4. **Create performance measurement (F5)** — PERF-001/002/003 cannot close without numbers; TP-009/TP-010/CANVAS-009/NOTES-013 inherit this block.
5. **Byte-bound Canvas history (F6).**
6. **Native sweep** for the F9 cluster: TP-002 chrome masking on all themes, TP-006 exact ghost-panel repro, TP-008/009 drag preview/jank, TP-015-019 physical checks, TP-020 composer collision, TP-021 Clear contrast, PANEL-002/005/006, appearance modes, VoiceOver + FKA traversal.
7. **Verify `testLongTaskTitleWrapsInsteadOfTruncating` current pass/fail state** when the suite next runs — if green, the title contract silently regressed; if red, it's a standing false alarm either way it must be rewritten.

---

*Review completed against source and tests only. Nothing in this report was verified against rendered output, a running app, or measured resource use; classifications mark exactly how far each claim is established.*
