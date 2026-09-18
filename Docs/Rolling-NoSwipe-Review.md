# Rolling No-Subpanel-Swipe — Independent Review

Date: 2026-09-14
Reviewer: independent SWE-2 Max (read-only; owns only this file)
Scope: settled six-file change vs hash-verified baseline at `/tmp/attic-noswipe-baseline`
Implementation report: `Docs/Rolling-NoSwipe-Implementation.md` (ends `IMPLEMENTATION_READY`)

## Verdict

**No confirmed source or test defect.** The removal is complete, surgical, and
correctly scoped; preserved behaviors are intact in source and covered by
replaced regression tests. Residual risks are live-only validation gaps owed
to the Sol Low native pass. `REVIEW_PASS` at end.

## Method

- Read `AGENTS.md`/`claude.md` contract, `Docs/PersonalChromeCheckpoint-2026-09-14.md`,
  `Docs/RollingWork-2026-09-14.md`, `Docs/Rolling-NoSwipe-Implementation.md`,
  and the review prompt `Docs/RollingEvidence-2026-09-14/NoSwipe-Synara-Review-Prompt.md`.
- Diffed all six files against `/tmp/attic-noswipe-baseline`; independently
  recomputed SHA-256 of each baseline file — all six match the recorded digests
  (`fc778ecc…b25e4c`, `47a06254…82962e`, `c197b96b…ce936d`, `8f0070c7…46af4f`,
  `ea5f60fc…82d9be`, `c32adcc5…28ebe2`). The `SubtaskPanelLayout` summary hash
  was indeed a 63-char truncation; the recorded prefix matches the true digest.
- Grepped `Attic/`, `AtticTests/`, `AtticUITests/`, `AtticMobile/`,
  `AtticMobileTests/`, `AtticMobileUITests/`, `AtticUnitTestHost/`, `Scripts/`,
  `Attic.xcodeproj/` for every removed symbol: zero references outside Docs
  evidence logs (which quote the removed code — expected).
- Checked filesystem mtimes repo-wide: the only files modified after the
  ~04:05 snapshot are the six claimed files (04:08–04:12) plus Docs/evidence.
  Main-panel swipe files (`AtticPanel.swift` Sep 13, `PanelGeometry.swift`
  03:11, `AtticPanelController.swift` Sep 13, `PanelUIState.swift` Sep 13,
  `NotesPanelContent.swift` Sep 13, `PanelGeometryTests.swift` 02:46) all
  predate the edit window — untouched.
- `git diff --check` re-verified clean (read-only; no builds/tests run).

## Confirmed removals (all complete)

- `Attic/Window/PanelSurfaceHostingView.swift` (361→119 lines): `swipeDismissal`
  hook + didSet cancel, `swipeTracker`, `swipeSession`, `swipeReducesMotion`,
  `swipePresented`, `swipeGeneration`, `swipeInterruptions`/`swipeModifiers`,
  `sendEvent` interception, `resignKey`/`orderOut` overrides,
  `cancelSwipeDismissal`, `isSwipeDismissalPresented`, `completeSwipeDismissal`,
  `isDirectSwipeSample`, `contentOwnsHorizontalScrolling`, `swipePhase`,
  `PanelSurfaceSwipeDismissal`, `PanelSurfaceMotionContainer`. `sendEvent` is
  now a pure forward through the `eventForwardingForTesting` seam
  (`PanelSurfaceHostingView.swift:38-44`); `self.contentView = contentView`
  directly (`:27`) — no motion layer remains to leave residue.
- `Attic/Window/SubtaskPanelController.swift` (1184→1126): `swipeDismissal`
  wiring in `configureSurface`, `SwipePresentationKey` tracking in `syncState()`,
  `invalidateTransientSwipe()` in the already-open branch of `openFamilyPanel`,
  and the whole `Trackpad dismissal (R7)` section (`canBeginSwipeDismissal`,
  `swipeDismissalSession`, `completeSwipeDismissal`, `transientSwipeRevision`,
  `SwipePresentationKey`, `invalidateTransientSwipe`). Doc comment corrected.
- `Attic/Services/SubtaskPanelLayout.swift` (733→557): `SubtaskSwipeDismissTracker`
  removed wholesale; seam at `:507-510` is clean; `hypot`/`CoreGraphics` imports
  still used (`:125`, `:324`); every remaining helper still has live callers.
- Tests: `PanelSurfaceHostingViewTests` 284→198 (6 swipe tests → 4 no-swipe
  regression tests), `SubtaskPanelControllerTests` 1419→1403 (3 → 3),
  `SubtaskPanelTests` 630→531 (tracker section + 3 dangling MARK comments
  removed; 28 remaining tests byte-identical to baseline).

## Confirmed preserved behaviors (source-inspected, callers verified)

- **Main-panel swipe**: `AtticPanel.swift:58-148` routing, `PanelGeometry`
  tracker types, `AtticPanelController` `.panelSwipe` lock + container motion,
  `NotesHorizontalSwipeView`/`notesSwipeTarget` — all present and untouched
  (31 refs in `Attic/`). Notes main-panel navigation intact.
- **Ordinary scrolling/momentum**: `sendEvent` forwards every event class;
  no phase/momentum/modifier/precision gating remains.
- **Escape**: `keyDown` → `onEscape` (`PanelSurfaceHostingView.swift:30-36`)
  → `closePinned`/`closeTransientSurface` per mode (`SubtaskPanelController.swift:781-784`).
- **Outside-click dismissal**: `updateOutsideClickMonitoring`/`noteOutsideMouseDown`
  (`:948-1000`) incl. control-rect pairing and edit/menu deference.
- **Immediate task-click open/switch**: `openFamilyPanel` intact (`:366-409`);
  callers in `TaskRowView.swift:287,432,437,527` and `AtticPanelView`/
  `AtticPanelController` unchanged.
- **Explicit close/toggle/section-switch/hide**: `toggleFamilyPanel` (`:480`),
  `dismissTransient` (`:503`), `selectSection` sink (`:83-86`),
  `mainPanelDidHide` (`:622`), `closePinned` (`:613`), `windowWillClose` (`:1040`).
- **Pin/unpin/move/detach**: `pinFamily` (`:556`), `unpinPinned` (`:580` incl.
  pinned→transient window reuse), `detachTransient` (`:193`), header-drag via
  `PanelSurfaceDragGeometry` + `onBeginWindowDrag` (`:777-778`).
- **Resizing/refit**: `refreshSurfaceSizes`, `repositionTransient`,
  `resizeDetachedSurface`, `applyFrame`/`stopFrameAnimation` — all present.
- **Editing/busy**: `surfaceInteractionBusy` still live at `:583` (unpin
  eviction guard) and `noteOutsideMouseDown:991`; `releaseFamilyInteractionState`
  intact. Not dead code.
- **Subtasks/Attachments switching**: `showPanelView` (`:420`) + view-retention
  pruning in `syncState` (`:693-695`) — the fresh-open-on-Subtasks invariant
  the removed `SwipePresentationKey` used to force is preserved by
  `panelViews.retain(presented)` and now covered by a dedicated test.

No call site of any removed API survives; `SubtaskPanelContent.swift`'s 14
`subtaskPanels.*` call sites all resolve to surviving methods. Untracked
`PanelSurfaceHostingView.swift`/`…Tests.swift` are in `project.pbxproj`
(10 references); no project-input change was needed — consistent with the
successful `build-for-testing`.

## Regression tests: strength and false-confidence assessment

Strong: `testSwipeShapedScrollStaysWithTheContentAndNeverDismisses` would fail
if interception were reintroduced (swipe tracking consumed events; the test
requires 1:1 forwarding in both directions plus `.cancelled`), and
`assertSurfaceUntouched`'s `contentView === content` identity check proves no
motion wrapper. `testEveryScrollFlavourReachesTheContentUnconsumed` exercises
exactly the old exclusion classes (imprecise, phase-less, momentum,
modifier-bearing). `testEveryPreservedClosePathStillDismisses` covers five
real close paths; `testReopenAfterDismissalIsAFreshStablePresentation` covers
the view-reset invariant plus deferred-close absence.

Limitations (acceptable, noted not as defects):
- `eventForwardingForTesting` replaces `super.sendEvent`, so the tests prove
  the window *forwards*, not that AppKit delivers to the hosted scroll view.
  Inherent seam limit — live check owed.
- `testInterruptedSequencesLeaveNoGestureStateBehind` is a reintroduction
  guard: with no gesture state existing, its assertions are trivially true.
- `testScrollAndDragResidueNeverDismissesTheLatchedSurface` exercises scroll
  *consequences* (anchor/viewport republish, detach, sibling pin) at lifecycle
  level with `presentationEnabled=false`; event-level coverage sits in the
  window suite. Name slightly overclaims; coverage is real but indirect.
- `testEscapeKeyStillRoutesToTheOwner` calls `keyDown(with:)` directly rather
  than dispatching through `sendEvent`.
- No explicit pinned-surface scroll test (same window class; pinned never had
  interception — low value).

## Build/test evidence review (not rerun, per mandate)

Reported: `build-for-testing` Local exit 0; offline harness 183 tests / 2
skips / 0 failures (PanelGeometryTests 71, PanelSurfaceHostingViewTests 7,
PanelUIStateTests 12, SubtaskPanelControllerTests 65, SubtaskPanelTests 28);
PanelGeometryTests isolated 71/71; TaskPerformanceGateTests 4/4. Conversation
log corroborates each line; suite counts match the file contents I read.

**First-run flake classification — accepted, with one honest caveat.** The
first combined run failed 6 assertions in 4 `PanelGeometryTests` main-panel
swipe cases (`testNotesNavigationAndPanelHidingHaveOneDirectionOwner`,
`testPanelRoutesPreciseTrackpadSwipeToInteractiveHideCallback`,
`testPanelSwipeCannotFinishAfterLosingKeyWindow`,
`testReregisteredNotesTargetRequiresFreshSwipe`), all `0 != 1` = gesture never
recognized. Classification as shared-host event-routing flake is supported:
the suite exercises `AtticPanel`/`PanelGeometry`, which share no code with the
change and were untouched; it passed standalone and on an identical combined
retry; and the checkpoint documents the same signature
(`testInterruptedSwipeRestoresOnceAndRequiresAnotherBegin` under concurrent
native pointer input — production routing consults `NSEvent.pressedMouseButtons`).
Caveat: the specific environmental trigger at 09:48 was not identified;
"shared-host event routing" is inferred from the failure signature, not
proven. That is a pre-existing harness sensitivity, not a defect in this
change.

## Findings

**Confirmed source/test defects: none.**

Observations (informational, no action required):
1. Historical docs (`Docs/ConcurrentSWEReview-RequirementsTests.md`) cite the
   deleted subpanel swipe tests as TP-017 coverage — superseded by
   `Docs/Rolling-Requirements-Audit.md`, which already classifies no-swipe as
   implemented pending this review and native validation. No doc edit owed by
   this change.
2. `SubtaskPanelLayout.swift` doc comment still says "transient hover panel"
   — pre-existing wording, untouched by this diff.

## Residual risks and exact native checks owed (Sol Low)

1. Real trackpad two-finger horizontal pan over the open subpanel: content
   scrolls/rubber-bands, panel never moves, fades, or dismisses — in both
   directions, including over the Attachments gallery.
2. Momentum tail after finger lift mid-pan; sequence interrupted by a button
   press or panel hide — no stuck or residual presentation state.
3. Main-panel two-finger swipe-to-dismiss and Notes library swipe still work
   physically (TP-017/PANEL-005 stay open per the requirements audit).
4. Single task-row click opens the subpanel promptly; a second family's click
   switches it; count-control toggle closes it; Escape closes while idle and
   still reverts an in-progress rename (field-editor path); outside click
   dismisses; pin→unpin→move→resize all behave.
5. Rapid open/close/pin cycles leave no faded or scaled artifact (motion
   layer is gone; confirm visually anyway).
6. VoiceOver spot-check on open/close affordances — never exercised.

Visual handoff for the native reviewer:

If the task sub-panel does not open, open it manually using double-click, then “Add Task.” This setup may be necessary before the panel becomes available for inspection.

REVIEW_PASS
