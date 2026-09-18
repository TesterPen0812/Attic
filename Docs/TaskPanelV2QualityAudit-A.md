# Task Panel V2 — quality audit A (independent, read-only)

Date: 2026-09-13. Reviewer: SWE-A. Worktree `/Users/taha/Developer/attic-task-panels-v2`,
branch `codex/attic-task-panels-v2`, HEAD `ae6418c1af690e29d15a20344cdb9765a23d3f85`
plus the intentional dirty baseline. Contract: `Docs/TaskPanelV2QualityChecklist.txt`
(read in full, 15 sections). Prior ledger and `TaskPanelV2FinalAstraReview.md` read
selectively. Source hashes for every cited file: `.build/quality-audit/a/source-hashes.txt`.

This audit made **no** production/test edits, no commits, no store resets, no UI/pointer
interaction (reviewer B owns that). It owns only this report and `.build/quality-audit/a`.

## Verdict summary

**Not a clean pass.** Two items are definite contract failures under the latest
checklist wording (neutral-hover panel navigation, row-menu → Attachments shortcut),
one section-2 item has prior native evidence of failure (persistent ••• in subpanel
rows, per root's live addendum), and the lag report is best explained by
interaction-time work that this audit localizes to four measurable paths. Idle CPU
is *not* the problem — verified twice (below). Most visual/native items are
**Partial**: source + unit tests support them, but this audit did not drive the UI
and prior approvals do not substitute for fresh native evidence.

## Runtime evidence collected (`.build/quality-audit/a/`)

- `sample-idle-1.txt`, `sample-idle-2.txt`: two `sample` captures of preview PID
  38614 (verified via `Scripts/launch_local_preview.zsh --verify`; sole instance,
  launchd-owned, mapped `AtticTaskPanelsV2.debug.dylib` SHA-256
  `dba63f07…f679b` matches the on-disk final-fixes build; all source mtimes
  predate the build, so the running binary reflects the dirty source).
- Result: ~1.5% instantaneous CPU, ~3:02 CPU-time over ~3h wall time (the earlier
  `ps` 57.4% was a lifetime average, not current burn). Main thread is ~99%
  blocked in AppKit `nextEventMatchingMask`. The only periodic main-thread work is
  `CornerHoverMonitor.applySamplingCadence → samplePointer →
  AtticPanelController.updateMousePassthrough` at the 1 s idle cadence.
  Corroborated by B's `cpu-idle.txt` (avg 0.54%, n=10).
- Footprint: ~142 MB physical, dominated by 103 MB Malloc Small — unremarkable for
  a SwiftUI/AppKit preview.
- Preview store scale (row counts only, no content read): ~38 tasks, ~8 subtasks.
  **This matters:** O(n²) store paths cannot explain the user's observed lag at
  this data scale — the lag source must be per-event / per-frame work.

## Prioritized findings (lag root-cause hypotheses, all measurable)

Ordered by expected contribution to the *observed* lag. None of A-01…A-04 claim
proof of the user's specific lag; each has an exact reproduction/profile method.

### A-01 — Per-scroll-frame synchronous auxiliary-panel refit (P1, strongest hypothesis)

`AtticPanelView.swift:163-165` republishes every row anchor on every scroll frame
via `TaskRowAnchorPreferenceKey`. `SubtaskPanelController.updateTaskRowFrames`
(`SubtaskPanelController.swift:210-216`) calls `repositionTransient` (`:1138`),
which calls `fittingSize(of:)` (`:1239`) = `host.layoutSubtreeIfNeeded()` +
`host.fittingSize` — a full SwiftUI sizing/layout pass of the entire subpanel
hierarchy — plus `SubtaskPanelLayout.transientFrame` and `applyFrame` →
`animator().setFrame` (`:1200-1228`). `mainPanelFrameDidChange` (`:883`) runs the
same path on every panel drag/resize event. `resizeDetachedSurface` (`:1182-1191`)
additionally calls `NSScreen.screens.map(\.visibleFrame)` per surface per refit.

So: while a transient is open, every scroll frame → one synchronous SwiftUI layout
pass of a second view hierarchy + a window move. Every main-panel drag tick → the
same for every pinned surface via `refreshSurfaceSizes` (`:1170-1180`). This is
the classic "second hierarchy relayout per event" pattern that produces visible
jank on complex SwiftUI content (the subpanel contains a LazyVStack, gallery,
header chrome, and preference plumbing).

Profile method: `sample 38614 5` (or Instruments Time Profiler) while scrolling the
task list with a transient panel open; filter stacks for `repositionTransient` /
`fittingSize` / `layoutSubtreeIfNeeded`. Expect them on the main thread per scroll
frame. Fix direction: only re-fit when content actually changed (compare a
measured-size preference rather than refitting on anchor moves); coalesce anchor
updates to the runloop's display link or throttle `updateTaskRowFrames` to
visible-range changes.

### A-02 — Dual pointer-monitor stacks + main-queue sampling on every pointer event (P2)

Two independent monitor stacks both live on the main thread:

- `AtticPanelController.swift:1137-1156`: local + global monitors over
  `.mouseMoved` and drag masks; every event calls `updateMousePassthrough`
  (`:316`), which runs `containsScreenPoint`, squircle containment, resize-edge
  acquisition math, `panel.ignoresMouseEvents` toggling,
  `panel.invalidateCursorRects(for:)` and `NSCursor…set()` (`:346-356`).
- `CornerHoverMonitor.swift`: separate local + global monitors feeding
  `samplePointer` (`:179`), plus a `DispatchSourceTimer` on the main queue at 50 ms
  while visible / 1 s idle (`:279-300`), wrapped in a
  `ProcessInfo.userInitiatedAllowingIdleSystemSleep` activity (`:309-320`).

Every physical mouse move while the panel is visible therefore runs the passthrough
hit-test at least twice (once per monitor type when the app is active, plus the
50 ms sampler). Individually cheap; under trackpad-speed event rates the
`invalidateCursorRects` + `ignoresMouseEvents` churn can force extra hit-test and
display passes. This is an event-driven cost — invisible in idle samples, matching
the observation that lag appears during interaction.

Profile method: Time Profiler the preview while waving the pointer over the panel
edge/resize zone; count `updateMousePassthrough` samples per second and look for
`invalidateCursorRects` → `_needsDisplay` storms. Fix direction: skip passthrough
work when the computed `shouldIgnoreMouseEvents` and cursor state are unchanged
(it already early-outs for the bool but still recomputes geometry every event);
debounce cursor-rect invalidation.

### A-03 — Synchronous triple store refresh on the main actor during reveal (P2)

`CornerHoverMonitor.refreshStoreForReveal` (`CornerHoverMonitor.swift:377-393`)
calls `store.refresh()`, `noteStore.refresh()`, `canvasStore.refresh()`
synchronously at reveal, then schedules a second refresh after a retry delay.
`TaskStore.refresh` → `reloadTasks` builds a fresh `ModelContext`, fetches **all**
tasks, dedupes replicas, bumps `revision` — which re-evaluates
`AtticPanelView` section snapshots and `reconcileTaskIDs` mid-reveal-animation.
At 38 tasks this is small; at a real store it is a synchronous fetch + diff +
full-view invalidation landing inside the 240 ms show animation.

Profile method: `sample` during panel reveal; look for `ModelContext` fetch /
`snapshot(for:)` / `visibleUniqueTasks` on the main thread inside the show window.
Fix direction: refresh off the critical path (pre-warm on hover-intent, or fetch
on a background context and publish the diff), and drop the unconditional second
refresh when the first succeeded.

### A-04 — Per-row redundant computation in body evaluation (P2, confirmed by benchmark)

`TaskFamilyView.swift:15-21` — `children` is a computed property calling
`TaskStore.subtasks(of:)` (`TaskStore.swift:721`), which filters all tasks and, per
candidate, runs `parent(of:)` (`:716`) — a linear `tasks.first` scan — then sorts:
O(n·k) ≈ O(n²). One `TaskFamilyView` body evaluation touches `children` up to four
times (`summary` isEmpty+filter+count, `canPresentPanel`, `isFamilyPresented`
context). `snapshot(for:)` is revision-memoized (good) but its rebuild is also
O(n²) via `orderedTasks` × `parent(of:)`.

`TaskItem.swift:25-28` — `attachments` JSON-decodes `imageReferencesData` on every
access; `TaskRowView` reads it at lines 84, 142, 289, 295-296, 311 and again in
drag-payload construction — ~5 decodes per row per body evaluation.

Independent benchmark evidence (root's, this auditor verified the harness):
`family-summary-benchmark.txt` — 100 parents/600 tasks = **4.6 ms** per pass,
300/1800 = **33 ms**, 1000/6000 = **357 ms** (median, `swiftc -O`, actual method
bodies). `attachment-decode-benchmark.txt` — 100 rows ≈ **5.1 ms**, 300 rows ≈
**12.8 ms** per pass. At preview scale both are sub-millisecond — consistent with
idle samples — but they scale linearly/quadratically with the user's real data and
compound with A-01 (every refit re-runs row bodies).

Fix direction: revision-scoped children index (compute once per revision, not per
access), decode `attachments` once per body (single local), and consider a cached
decoded-reference property on the model.

### A-05 — Eager rows + per-eval allocations in section list (P3)

`TaskSectionView.swift` instantiates all rows of a section in a plain `VStack`
(outer `LazyVStack` only defers at section granularity) and applies
`.animation(AtticMotion.spring, value: tasks.map(\.id))` (`:70`) — an array
allocation on every body evaluation plus spring-animated relayout of the whole
section on any membership change. `TaskRowView` adds `ViewThatFits` (`:218`) + a
hidden ideal-width title measurement (`:234`) ≈ 3 title layouts per row. Not the
lag driver at 38 tasks; contributes under A-01/A-04 load and on large sections.

### A-06 — Height-only vs immediate frame application can snap (P3, investigation)

`applyFrame` (`SubtaskPanelController.swift:1200-1215`) animates only when the
top/x/width are unchanged; any clamp-driven position change applies instantly.
`SubtaskPanelLayout.pinnedResizedFrame` / `transientFrame` can produce such
changes near display edges or beside pinned neighbors. Whether it *looks* abrupt
is a native-behavior question — flag for B's run (grow a panel at the screen
bottom / adjacent to a pinned panel). Not asserted as a defect.

## Contract findings (definite)

### A-F1 — Neutral hover opens/switches family panels → Section 13 FAIL

`TaskFamilyView.swift:57-62` calls `subtaskPanels.noteRowHover` on `.onHover`;
`SubtaskPanelController.noteRowHover` (`:238-245`) → `rescheduleTimers` →
`commitPendingOpen` (`:297-350`) → `presentTransient` after `openDwell` 0.35 s
(`familySwitchDwell` 0.075 s when a surface is open). A resting pointer on a
family row therefore navigates UI state — contradicting checklist items "Hover
does not cause unexpected panel navigation" and "Neutral task-row hover only
highlights the row". This is a designed behavior defended by tests
(`testHoverOpenRequiresDwellToMature`, `testFamilySwitchUsesFastDwellWhileASurfaceIsOpen`,
`testFirstOpenStillPaysTheDiscoveryDwell`) — i.e. the tests encode the *old*
contract. Per the explicit instruction not to reinterpret the stricter wording:
**Fail**. Decision needed: either Section 13 wins (gate hover-open behind an
explicit gesture/setting) or the checklist is amended; B's `hover-open-latency.txt`
(~0.55 s ≈ 0.35 dwell + show animation) confirms the behavior is live, not dead
code. One caveat for fairness: hover-open is the *only* transient trigger wired
into `.onHover` — removing it changes how Section 9/10 transient scenarios are
reached, so this is a design decision, not a bug fix.

### A-F2 — Row menu "Show attachments" opens the panel on Attachments → Section 3 discrepancy

`TaskRowView.swift:399-400` calls `openFamilyPanel(…, view: .attachments)`;
`SubtaskPanelController` honors the requested view on present/switch (`:579-629`).
Section 3 says "Opening a task subpanel starts on Subtasks by default." The strict
reading (root's ROOT-04) marks this a failure; the permissive reading treats a
menu item literally named "Show attachments" as a deliberate control — the same
category the contract preserves. This audit records it as a **discrepancy
requiring a contract ruling**, not silently reinterpreted either way. The
attachment-import reveal exception (`:697`, `freshAttachmentLifetime`) is
explicitly sanctioned by Section 7 ("drop … then switches the panel to
Attachments") and is not disputed.

### A-F3 — Persistent ••• affordance in subpanel rows → Section 2 item FAIL (prior native evidence)

Root's live addendum (`TaskPanelV2QualityAudit-Root-LiveAddendum.md`) captured
native screenshots of the pinned subpanel showing blue ellipses on **all three
rows simultaneously** with no pointer on them — `TaskRowView` puts the opacity on
the `Image` inside a native `Menu` label, which appears not to be honored by the
bridged AppKit menu control. This audit independently confirms the source pattern
(`TaskRowView.swift` actions-menu label, `.menuIndicator(.hidden)` at `:373`) but
did not re-photograph it. Verdict for "••• is hidden at rest": **Fail** in
subpanel rows pending re-verification in the main panel.

## Checklist matrix

Verdicts: **Pass** only where source settles the item unambiguously (label text,
structural facts) or fresh native evidence exists; **Partial** where source +
tests support but native behavior is unverified by this auditor; **Fail** where
contradicted. "Native check needed" = B-ownership items.

### 1. Main task panel — files: `AtticPanelView.swift`, `TaskRowView.swift`, `TaskSectionView.swift`, `TaskFamilyView.swift`, `AtticPanel.swift`

| Item | Verdict | Notes |
|---|---|---|
| Proportions/silhouette/spacing/dark language preserved | Partial | Source reuses `AtticStyle`/`AtticTheme`; needs native screenshot |
| Liquid Glass controls | Partial | `SettingsPresentationTests.testTranslucencyChangesSurfaceOnlyWhileControlsStayLiquidGlass`; native check needed |
| Hover uses subtle superellipse surface | Partial | `PanelSquircleGeometryTests`, `PanelSquircleSettingsTests`; native check needed |
| Titles one line only | Pass | `TaskRowView` fixed-height row + `lineLimit(1)` title path; `testKeyboardFocusDisclosesOnlyClippedTitlesOutsideEditing` |
| Long titles: soft trailing fade | Partial | fade mask in `TaskRowView`; B's `rowtail.png`/`rowtail-big.png` may cover |
| Long titles don't change row height | Pass | fixed `AtticStyle.rowHeight`; title measured in `ViewThatFits` overlay, not layout-affecting |
| Full text via intentional interaction | Partial | `TaskTitleExpansion` child-window path; `testTitleExpansionObservesOnlyWhilePresentedInWindow`; native check needed |
| Title↔metadata spacing compact/intentional | Partial | source layout compact; visual judgment needs screenshot |
| Metadata visually secondary | Pass | metadata rendered at 9-10 pt medium secondary (source-verified styling) |
| Metadata passive, not buttons | Pass | metadata `Text`/`Image` only; no gesture handlers on indicators |
| No misleading pointer cursor / button hover on metadata | Partial | source has none; native cursor check needed |

### 2. Task-row actions — `TaskRowView.swift`

| Item | Verdict | Notes |
|---|---|---|
| ••• hidden at rest | **Fail** (subpanel) / Partial (main) | Root live addendum: all subpanel rows show ellipses simultaneously; main panel unverified |
| ••• appears on hover | Partial | `isHovering`-gated opacity in source; native check needed |
| ••• appears on keyboard focus | Partial | focus-state path in source; needs FKA verification |
| Showing ••• doesn't shift title/metadata | Partial | reserved 24-pt trailing area in source; jitter needs native check |
| Stable trailing action area, no layout jitter | Partial | reserved-space pattern in source |
| Hover surface + ••• feel coordinated | Partial | single `AtticMotion.quick` animation drives both; feel is native |
| ••• not permanently visible down the list | **Fail** (subpanel) | same native evidence as above |

### 3. Task subpanel — `SubtaskPanelController.swift`, `SubtaskPanelContent.swift`, `SubtaskPanelLayout.swift`

| Item | Verdict | Notes |
|---|---|---|
| One movable subpanel per task | Pass | single transient + per-family pinned windows; `testOpenForPinnedFamilyDoesNotCreateTransient`, `testToggleOnPinnedFamilyKeepsTransientAlone` |
| Subpanel can be pinned | Pass | `testPinUnpinAndPinnedRevealKeepTheSamePanelView`; B's `pinned-panel.png`, `pinned-moved.png` |
| Opens on Subtasks by default | Partial — **discrepancy A-F2** | fresh opens default Subtasks (`testFreshOpenStartsOnSubtasksAndMovementKeepsTheChosenView`), but row-menu "Show attachments" opens Attachments directly; needs contract ruling |
| Exactly two primary views (Subtasks / Attachments) | Pass | `FamilyPanelView` two cases only |
| Users switch views deliberately from inside panel | Pass | `viewSwitch` control (`SubtaskPanelContent.swift:540-546`) → `showPanelView`; `testExplicitViewRequestsAndSubtaskEntryChooseTheirView` |
| Attachment previews / 2-11 don't auto-switch views | Pass | `testFreshOpenStartsOnSubtasksAndMovementKeepsTheChosenView`; no metadata→view-switch path in source |
| View-switch control beside bottom composer | Pass | `viewSwitch` in bottom chrome next to composer (source layout); B's `attachments-view.png` |
| Subtasks composer says "Add subtask…" | Pass | `SubtaskPanelContent.swift:615,642` exact strings |
| Attachments composer says "Add attachment…" | Pass | `SubtaskPanelContent.swift:521` exact string |
| Switch button/icon represents destination | Partial | `viewSwitch` labels destination; icon correctness needs native check (`testViewSwitchNamesItsDestination` covers naming) |

### 4. Subtasks ↔ Attachments transition — `SubtaskPanelContent.swift:447-473`, `SubtaskPanelController.swift:1182-1228`

| Item | Verdict | Notes |
|---|---|---|
| Starts immediately after explicit switch | Partial | `showPanelView` → transition in same body pass; native timing check needed |
| Short smooth slide/crossfade | Partial | `viewTransition` slide+opacity (`:447-451`), `viewSwitchDuration` 0.22 s; `testViewSwitchPagesBothLayersTheSameWay` |
| Panel anchored while body changes | Partial | top-anchored frame policy; native check |
| Height animates smoothly with transition | Partial | `applyFrame` height-only path animates at same duration; see A-06 edge cases |
| Many→few smoothly shrinks | Partial | same path; B's scroll/open screenshots; edge-clamp snap question in A-06 |
| Few→many smoothly expands | Partial | same |
| No flashing/flicker/snap-back/duplicated content | Partial | only active view kept in hierarchy (single-layer switch); native check needed — this is a "feel" item, cannot Pass from code |
| Reduce Motion simplified | Pass | opacity-only branch gated on `accessibilityReduceMotion`; `testDismissalPresentationIsSubtleAndReduceMotionKeepsOnlyTheFade` |

### 5. Dynamic panel sizing — `SubtaskPanelLayout.swift`, `SubtaskPanelContent.swift`, `SubtaskPanelController.swift:1170-1246`

| Item | Verdict | Notes |
|---|---|---|
| Same sizing system both views | Pass | shared `fittingSize` + `panelWidth`/`maximumListHeight`; `testBothViewsShareTheListMaximumAndSizeToTheirContent` |
| Height follows content | Partial | measured-content fitting; `testPanelContentIdealHeightFollowsTheActiveView`; native check |
| Small content → smaller panel | Partial | `minimumContentHeight` 112 floor; native check |
| More content grows panel | Partial | same |
| Growth stops at approved maximum | Pass | `maximumListHeight` 240 enforced in layout; `testSurfaceSizeStaysInsideTheSpecifiedBounds` |
| Content scrolls at maximum | Partial | ScrollView inside measured body; native check |
| Header stable while body scrolls | Partial | header outside scrolling region (source structure); native check |
| Bottom composer/switch stable while scrolling | Partial | same |

### 6. Attachments view — `TaskImageAttachments.swift`, `SubtaskPanelContent.swift`, `TaskAttachmentDrop.swift`

| Item | Verdict | Notes |
|---|---|---|
| Images + files in one view | Pass | gallery renders both reference kinds |
| Images as compact thumbnails | Partial | `galleryCardHeight` 100 / `galleryPreviewHeight` 56, 2 columns; B's `attachments-view.png`; native check |
| Files as compact cards | Partial | same grid path |
| Single image doesn't dominate | Partial | fixed card size; native check |
| Readable at small and large counts | Partial | `LazyVStack` grid + max height + scroll; large-count behavior needs native check; A-02/A-04 scaling notes apply |
| One Add attachment action for both | Pass | single `Add attachment…` path (`:521`) + shared staging |
| Hover reveals small remove × | Partial | hover-gated affordance in source; native check |
| Remove controls not permanently visible | Partial | same — verify no equivalent of A-F3 leak on the × |
| No unnecessary permanent toolbar | Pass | no Save/Remove/Quick-Look toolbar in source |
| Click opens/previews via intended behavior | Partial | open path exists; native check |
| Attachments belong to parent only | Pass | references stored on parent `TaskItem`; `testGalleryCardCopiesIntoAnotherTaskButNeverIntoItsOwnOwner` |

### 7. Drag and drop — `TaskAttachmentDrop.swift`, `TaskRowView.swift:142`, `SubtaskPanelContent.swift`

| Item | Verdict | Notes |
|---|---|---|
| Tasks draggable/reorderable | Partial | `.draggable` payload (`:142`); native drag check needed |
| Images/files draggable from attachments | Partial | card drag payloads in source; native check |
| File dropped on task attaches to it | Partial | `testDroppedFilesAttachToTheParentAndDiscardOnlyTheirStaging`, `testDropContentSeparatesTaskRowsGalleryCardsFilesAndText`; native check |
| Drop anywhere on open subpanel attaches to parent | Partial | whole-surface drop target in `SubtaskPanelContent`; `testGalleryCardDroppedOnTheComposerBecomesAPendingCopy` family; native check |
| Works while panel shows Subtasks | Partial | drop target wraps the surface, not the gallery; native check |
| Restrained drop state while dragging | Partial | `isDropTargeted` + `AtticMotion.quick` highlight; native check |
| Drop state communicates "Drop to attach to …" | Partial | labeled overlay in source; native check |
| Content visible under drop state | Partial | overlay pattern in source |
| Successful drop adds attachment | Partial | staging→attach covered by `testPromisedGeneralDocumentsStageWithTheirTypeAndAttach` et al.; native check |
| Successful drop switches to Attachments | Pass | `freshAttachment` reveal path (`SubtaskPanelController.swift:697`); `testImportedAttachmentsRevealOnlyWhereTheUserStillExpectsThem`; sanctioned Section-7 exception |
| New attachment animates into gallery | Partial | `freshAttachmentEntranceDelay`/stagger constants; native check |
| Dragging doesn't break scrolling | Partial | scroll-phase ownership in `PanelSurfaceHostingView`; native check |
| Dragging doesn't interfere with pointer interactions | Partial | monitor coverage audited; native check |

### 8. Pinned panels — `SubtaskPanelController.swift`, `TaskRowView.swift`

| Item | Verdict | Notes |
|---|---|---|
| Pinned panel stays with its task | Pass | family-keyed `pinnedSurfaces`; `testPinPromotesTransientAndSuppressesHoverReopen` |
| Moving pinned panel preserves location | Partial | detached-surface frame retention; `testPinnedGrowthBelowDisplayEdgeClampsInside`; B's `pinned-moved.png` |
| Row shows muted pinned indicator | Partial | indicator in row metadata; B's `pinned-panel.png`; native check |
| Indicator reads as status, not big button | Partial | small muted styling in source |
| Hovering indicator explains "Panel pinned" | Partial | help text on indicator; native check |
| Activating indicator focuses existing panel | Partial | `openFamilyPanel` re-raises pinned surface; `testRowActivationForChildlessParentOpensAndPinnedFamilyRaisesWithoutDuplicate` |
| No duplicate panel for pinned task | Pass | `testOpenForPinnedFamilyDoesNotCreateTransient`; `testPinnedSurfaceDraftNeverLocksMain` |
| Pin/unpin controls on the panel itself | Pass | header pin control in `SubtaskPanelContent` |
| Pinned Liquid Glass consistent | Partial | styling in source; native check |

### 9. Transient panel reachability — `SubtaskPanelLayout.swift` (corridor/SAT), `SubtaskPanelController.swift:260-352`

| Item | Verdict | Notes |
|---|---|---|
| Transient reachable while another pinned | Partial | corridor uses actual surface geometry incl. pinned obstacles; `testPointerCoverageSeparatesSurfaceTransitAndOutside`; native check needed — and note A-F1: this whole scenario is entered via hover-open |
| No unusually fast pointer needed | Partial | `corridorTransitBudget` 0.6 s + `corridorMinimumProgress` + `corridorApproachHold` 0.1 s; `testTravelDefersACloseWithinABudgetThatOnlyProgressRenews`, `testSlowContinuousApproachAccumulatesProgress`; real pointer-speed check needed |
| Safe travel corridor / hover-intent region | Partial | convex-hull + SAT corridor in `SubtaskPanelLayout`; `testCorridorTransitDefersThenClosesOnExitWithoutAnyHoverCallback`; native check |
| Crossing pinned panel doesn't dismiss | Partial | occupied-frames-aware corridor; `testCorridorTransitDefersASwitchOnlyWhileTheHandApproachesTheSurface`; native check |
| Entering panel cancels pending dismissal | Pass | `noteTransientPointer(inside:)` resets budget + cancels close; `testPointerReachingTheSurfaceCancelsTheCloseOutright` |
| Dismissal only after clear departure | Partial | closeGrace 0.14 s + coverage classification; `testRowLeaveSchedulesCancellableCloseGrace`, `testPendingCloseMaturesAfterGrace`; native check |
| Works above/below/beside | Partial | geometry-directional corridor; `testSurfaceContainmentFollowsTheConfiguredCorner`; native check |

### 10. Two-finger subpanel dismissal — `PanelSurfaceHostingView.swift`, `SubtaskPanelLayout.swift`

| Item | Verdict | Notes |
|---|---|---|
| Unpinned dismissible via two-finger gesture | Partial | swipe session in hosting view; `testHorizontalSwipeFollowsTheFingersInEitherDirection`; physical-trackpad check needed |
| Collapse/recede inward | Partial | scale+opacity presentation, no snapshot; `testDismissalPresentationIsSubtleAndReduceMotionKeepsOnlyTheFade` |
| Subtle scale + opacity | Partial | same |
| No snapshot/funnel effect | Pass | live `setCollapseProgress`-style presentation; explicitly no snapshot path in source |
| Follows fingers, not release-only | Partial | `scrollWheel` phase tracking; `testCompletionIsVelocityAware` |
| Velocity-aware threshold | Pass | `testCompletionIsVelocityAware` |
| Cancel restores smoothly | Partial | cancel path in source; native check |
| Pinned panels ignore gesture | Pass | pinned surfaces not enrolled in swipe dismissal |
| Vertical scrolling never triggers | Pass | axis/phase gating; `testVerticalAndDiagonalScrollingNeverDismisses` |
| Reduce Motion simplified | Pass | fade-only under Reduce Motion; same test |

### 11. Main task composer attachments — `AtticPanelView.swift`, `TaskComposerAttachments`, `TaskAttachmentDrop.swift`

| Item | Verdict | Notes |
|---|---|---|
| Add attachments while creating task | Pass | composer pending-attachment path; `testComposerAttachmentsBindToTheNewTaskInItsSingleSave` |
| Picker supports images + files | Pass | shared staging accepts both; `testStagingReadsFinderOriginalsInPlaceAndCopiesProvidedContentIntoItsOwnedDirectory` |
| Drag into composer adds to draft | Partial | drop routing to composer; `testGalleryCardDroppedOnTheComposerBecomesAPendingCopy`; native check |
| Composer expands upward with pending items | Partial | dynamic composer height in `AtticPanelView`; native check |
| Pending attachments visible pre-submit | Pass | pending strip rendered in composer |
| Expanded composer follows design language | Partial | styling in source; visual check |
| Removing pending attachment works | Partial | `testRemovingOrCancellingDeletesOnlyTheComposersOwnCopies`; native check |
| Returns to normal size when cleared | Partial | `testFailedSubmitKeepsTheDraftItemsAndTheirCopiesForRetry`, count-limit test; native check |

### 12. Appearance settings — `AppearanceSettingsView`, `AtticStyle.swift`, `AtticTheme.swift`

| Item | Verdict | Notes |
|---|---|---|
| Settings separate surface vs control styling | Pass | `testTranslucencyChangesSurfaceOnlyWhileControlsStayLiquidGlass`, `testSettingsSectionsHaveStableLocalOnlyOrderAndIdentifiers` |
| Translucency affects only panel surface | Pass | surface-material split; `testClearIsAvailableOnlyForOriginalAndEffectiveDarkAppearance` |
| ON → approved translucent surface | Partial | material in source; native visual check |
| OFF → approved solid surface | Partial | same |
| Liquid Glass controls in both modes | Pass | test above + `testGlassDefaultsAndLegacyStableMigrationRemainCompatible` |
| Includes pin/completion/composer/submit/switch controls | Partial | control enumeration in source; native check per control |
| Settings copy explains distinction | Pass | `testPanelThemeChooserHasStablePresentationOrderAndIdentifiers`, copy reviewed in `SettingsPresentationTests` |

### 13. Visual hierarchy and polish

| Item | Verdict | Notes |
|---|---|---|
| Title most prominent in row | Pass | 13-pt regular title vs 9-10 pt secondary metadata |
| Metadata quieter than title | Pass | same |
| Menus/actions hidden or subdued until needed | Partial — see A-F3 | hover/focus-gated •••; subpanel leak contradicts "hidden" |
| Hover does not cause unexpected panel navigation | **Fail** | A-F1: 0.35 s dwell opens panel on resting hover |
| Neutral task-row hover only highlights the row | **Fail** | A-F1 |
| Padding deliberate and consistent | Partial | `AtticStyle` constants; visual check |
| No new control louder than content | Partial | view-switch + pin are small glyphs; visual check |
| No generic segmented/pills/alien language | Pass | custom control styling throughout; no segmented control in source |

### 14. Regression checks

| Item | Verdict | Notes |
|---|---|---|
| Task completion works | Partial | store status paths tested (`TaskStoreTests`); native check |
| Task reordering works | Partial | `nextManualOrder` + drag payload; native check |
| Subtask creation/completion works | Partial | `SubtaskTests`, entry-activation tests; native check |
| Pin/unpin works | Partial | extensive pin tests; native check |
| Panel movement works | Partial | `testPinnedGrowthTallerThanDisplayShrinksToFit` family; native check |
| Scrolling works smoothly | Partial — see A-01 | biggest lag surface; needs interaction profiling, not just a pass/fail glance |
| Task menus work | Partial | menu coverage in source; native check |
| Attachment preview/open works | Partial | open path in source; native check |
| No data lost during migration | Partial | replica-safe mutation + rollback tested (`testLaunchSweep…` family); no migration event exercised here |
| No duplicate panels | Pass | `testOpenForPinnedFamilyDoesNotCreateTransient`, latch tests |
| No hover-induced layout jitter | Partial — see A-F3 | reserved-space pattern exists, but the subpanel ••• evidence shows a related affordance-state bug live |
| No new animation flicker/snap-back | Partial — see A-06 | feel item; native check |

### 15. Evidence the AI should provide

| Item | Verdict | Notes |
|---|---|---|
| Pass/Fail/Partial per item | Pass | this matrix |
| Responsible files | Pass | per section headers + findings |
| Screenshot/native evidence where visual | Partial | B owns interaction; cross-referenced B's `evidence/` shots and root's live addendum rather than duplicating |
| Automated test names | Pass | named throughout; none rerun by this audit (per cost constraint) |
| Remaining discrepancy | Pass | A-F1, A-F2, A-F3, A-06 flagged |
| Unrequested changes | Pass | **none** — read-only pass; only this report + `.build/quality-audit/a/` added |

## Cross-audit comparison (for the orchestrator)

Independent convergence with root's report (written before this one, read only
after my source map was complete): ROOT-01 ≈ A-04 (family scans), ROOT-02 ≈ A-04
(attachment decode), ROOT-03 = A-F1, ROOT-04 = A-F2, ROOT-05 ≈ A-06. Two auditors
reaching the same five findings independently raises confidence. Findings unique
to this audit: A-01 (per-scroll-frame refit — the strongest *interaction-lag*
hypothesis), A-02 (dual monitor stacks), A-03 (reveal-time synchronous refresh),
A-05 (eager rows + per-eval allocations). Root's benchmarks are cited as
algorithm-level evidence, not app frame times.

## Reproduction / profiling plan for the lag report

1. `Scripts/launch_local_preview.zsh --verify`; confirm sole PID + mapped dylib
   SHA matches disk (done for PID 38614, `dba63f07…`).
2. Baseline: `sample <pid> 5` at rest — expect ~1-2% CPU, main thread in
   `nextEventMatchingMask` (done: `sample-idle-2.txt`).
3. **A-01 test:** pin one panel, hover-open a transient, scroll the task list
   continuously for 5 s while `sample <pid> 5` runs. Look for
   `repositionTransient`/`fittingSize`/`layoutSubtreeIfNeeded`/`setFrame` on the
   main thread each frame. Compare against scrolling with no panel open.
4. **A-02 test:** drag the pointer back and forth across the panel edge / resize
   zone for 5 s under Time Profiler; count `updateMousePassthrough` and
   `invalidateCursorRects` invocations.
5. **A-03 test:** `sample` during panel reveal; look for `TaskStore.refresh` /
   `ModelContext` fetch / `visibleUniqueTasks` inside the show window.
6. **A-04 test (scale):** seed a throwaway store with ~300 parents/1800 tasks in
   an isolated preview (do not touch the official store), then scroll and
   measure. Root's standalone benchmarks already bound the algorithmic cost:
   33 ms/pass at that size.
7. **A-06 check:** grow a panel at screen-bottom / beside a pinned panel; watch
   for immediate (non-animated) frame application.

## Limits of this audit

- No UI was driven (reviewer B's exclusive ownership). Every "Partial" marked
  "native check needed" requires B's run or a fresh interactive pass.
- No test suite was rerun (cost constraint); cited tests are existing coverage,
  not new evidence.
- Idle samples prove no runaway at rest; they cannot exonerate or convict
  interaction-time paths — that's why A-01…A-04 carry explicit profile methods
  rather than verdicts of guilt.
- Preview store is small; scale findings are projections bounded by standalone
  benchmarks, not app-side measurements at scale.
