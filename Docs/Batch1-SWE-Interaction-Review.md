# Batch 1 — SWE Interaction-State Review

**Verdict: CHANGES_REQUIRED** — one confirmed low-severity defect in the new
suppression machinery, plus one deferred-platform observation. The core fix is
correct; the finding is a boundary gap, not a design error.

- **Reviewer:** root session, no subagents. Read-only source/artifact audit —
  no edits, commits, pushes, builds, test hosts, UI launches, or relaunches.
- **Scope:** `RUN-001`, `RUN-002`, `CVD-01`, `CVD-02`, `CVD-05` per
  `Docs/DeepAudit-Batch1-Implementation.md` against
  `Docs/DeepAudit-Consolidated-2026-09-15.md` and the source audits.
- **Provenance:** verified independently — `batch1-own.diff` applied to the
  reconstructed `/tmp/attic-batch1/pre` snapshots reproduces all 9 changed
  files byte-for-byte; before/after sha256 tables match; no changes outside
  the owned diff; unrelated dirty work preserved.
- **Native QA:** owned separately by Sol Low. Nothing here is physical-input
  or live-panel evidence.

## 1. Confirmed finding

### F-1 (Low) — `cancelInteraction()` wipes suppression held by a foreign in-flight scroll/pinch sequence

**Where:** `Attic/Canvas/CanvasSurfaceMac.swift:1265-1281` calling
`resetViewportGestureRouting` (`Attic/Canvas/CanvasSurfaceMacHelpers.swift:988-996`);
interacts with the new CVD-05 guards at `CanvasSurfaceMac.swift:914-922` and
`:1019-1029`.

**Mechanism:** `resetViewportGestureRouting` unconditionally assigns
`suppressesScrollSequence = suppressScroll` and
`suppressesMagnification = suppressMagnification`, where the arguments only
describe whether the *interaction just cancelled* was itself a scroll/magnify
gesture. The new guards now set those same flags for a *different* reason — a
physical scroll/pinch sequence suppressed because a pointer interaction owns
the pointer. When `cancelInteraction()` runs while such a foreign-suppressed
sequence is still delivering events, the flag is cleared and the sequence's
remaining deltas resume mid-sequence.

**Reproducer (source-level):**
1. Begin a stroke (`mouseDown` → `machine.state == .drawing`).
2. Two-finger scroll `.began` arrives → guard at `:914` sets
   `suppressesScrollSequence = true`, returns. Sequence is dead per the
   documented contract.
3. Any cancellation fires — Escape (`:1172`), Space (`:1167`), transient
   interrupt (`:1293` via `interruptTransientInteraction`), first-responder
   loss (`:1244`), app/window resign (`:360`, `:567`) — `cancelInteraction()`
   computes `interruptedScroll = false` (no active viewport gesture,
   `pendingScrollMomentumMode` was nil'd by the guard) →
   `resetViewportGestureRouting(suppressScroll: false)` clears the flag.
4. The same physical sequence's `.changed` deltas arrive → the guard no
   longer applies (`hasActivePointerInteraction` is false post-cancel) →
   `beginViewportGestureSequence(.scroll, …)` succeeds →
   `applyViewportPan`/`applyViewportZoom` runs. The pinch analog applies via
   `.changed` → `beginViewportGestureSequence(.magnification, .zoom)` once
   `suppressesMagnification` is similarly cleared.

**Impact:** bounded viewport drift from a gesture the implementation record
says should "stay ignored until it ends" — the first deltas were dropped, so
the tail applies a *partial* gesture (arbitrary pan/zoom). No work loss is
possible: the pointer interaction is already gone when the tail applies.
Pre-Batch-1 behavior in the same interleaving was strictly worse (ink
destroyed by the scroll itself plus the full pan), so this is an incomplete
boundary in the new mechanism, not a regression versus the old code.

**Suggested fix:** preserve foreign suppression across the reset, e.g.
`resetViewportGestureRouting(suppressScroll: interruptedScroll || suppressesScrollSequence, suppressMagnification: interruptedMagnification || suppressesMagnification)`.
This cannot wedge: each flag is still cleared by its own sequence's terminal
event (`momentumEnded`, pinch `.ended`/`.cancelled`) and by the next
`directBegan`/pinch `.began`. A discriminating test would be: suppressed
scroll `.began` during ink → `cancelInteraction()` → `.changed` with delta →
assert viewport unchanged.

## 2. Observation (deferred platform, advisory)

**O-1 — iOS `cancelActiveInteraction` callers now synchronously cancel image
imports.** `CanvasSession.cancelActiveInteraction` gained
`cancelAllImageImportBatches()` (`CanvasSession.swift:1431-1435`). The iOS
callers — `AtticMobile/Views/MobileAppRoot.swift:51` (scene background),
`:56` (leaving canvas section), `MobileCanvasScreen.swift:63` (view
disappear) — are transient-class events in the new taxonomy but have no
`interactionInterruptions` subscriber (`CanvasSurfaceIOS.swift` has no sink),
so they cannot use the transient variant without new wiring. Before this
batch these calls rebuilt the view but left session imports running; now they
abort them — an undocumented cross-platform semantic change. iOS is deferred
and not a Batch 1 gate, but the divergence should be recorded in the
implementation record's §5 so the reactivation plan knows the mapping is
deliberately unmade.

## 3. Verified correct — checklist results

| Item | Result |
|---|---|
| Transient vs lifecycle split | Correct. `interruptActiveInteraction()` (`CanvasSession.swift:1440-1443`) flushes view state + synchronous `PassthroughSubject` send; no epoch, no import cancel. `cancelActiveInteraction()` (`:1431-1435`) adds synchronous `cancelAllImageImportBatches()` + epoch bump. |
| Zoom / hide / section transitions preserve imports | Verified. `deactivateRepresentation` (`CanvasSurfaceMac.swift:1300-1308`) cancels only view-owned file-promise batches; imports are session-owned and survive view dismantle. `importImageBatch` re-checks `Task.isCancelled` before persisting and the store validates `canvasID`/`boardGeneration` targets. |
| Native view stays alive on transient | Verified — `.id(interactionCancellationEpoch)` (`CanvasSurface.swift:25`) unchanged; transient sends don't bump it. Sink installed once per live view, `[weak view]`, cleared on deactivate; a dismantled view cannot be re-interrupted; rebuilds re-subscribe cleanly. |
| Lifecycle events still rebuild/cancel | `deleteSelectedCanvas` success (`CanvasSession.swift:561`), `synchronizeFromStore(clearHistory: true)` (`:1711`), `AppCoordinator.stop()`/`prepareForTermination()` (`:375,392`). |
| Scroll/pinch defer during ink, erase, image move/resize, shape drag, pointer pan | Verified — `hasActivePointerInteraction` (`CanvasSurfaceMacHelpers.swift:756-763`) covers `machine.state != .idle`, `panLastPoint`, `shapePointerMode`, `imagePointerMode` (which also backs semantic-object drags). |
| Suppression reset on end/cancel/momentum/new-began | Sound for the normal lifecycle — except for the F-1 boundary. No wedge states found: `directBegan` clears scroll suppression (`:931`), pinch `.began`/`.ended`/`.cancelled` clear magnification suppression (`:1033,:1059,:1063`), `momentumEnded` clears (`:1005,:916-917`). |
| Post-interrupt stale pointer / stale mouse events | Safe. `machine.append` refuses from `.idle`; `finishPointerInteraction` no-ops; `continuePan` requires `panLastPoint`; `beginInk` requires `.idle`. A held Space re-arms only via fresh `keyDown`. |
| Failed board ops preserve history/placement/selection/surface/epoch | Verified — `boardChanged` gating in `selectCanvas`/`createCanvas`/`deleteSelectedCanvas`; every store refusal branch publishes `lastErrorMessage`; refusal path runs `synchronizeFromStore(clearHistory: false)`. Outgoing-board view state still flushes before adoption (`:1661-1670`). |
| Successful board ops reset | Unchanged — `synchronizeFromStore(clearHistory: true)` path preserved. |
| Cross-feature callers | All classified correctly; programmatic section change via `CornerHoverMonitor.preparePresentation` (`:201`) bypasses `interruptActiveInteraction` but relies on dismantle — parity with pre-batch, and imports now survive there too. |
| Accessibility routing | No a11y code touched (`CanvasSurfaceMacHelpers.swift`, `CanvasSurfaceInteraction.swift` hashes unchanged); keyDown Tab/Shift-Tab navigation, object press/delete, `performKeyEquivalent` viewport shortcut focus gating all verified unchanged in own-diff. |
| No-swipe subpanel contract | `AtticPanel.swift` untouched — `pressedMouseButtons == 0` (`:95`) blocks swipes during ink; `contentOwnsHorizontalScrolling` recognizes `CanvasNSView` (`:219`); mid-sequence button press cancels (`:113`). |
| Original intended gestures preserved | Space-drag/right-drag/other-drag `beginPan` still takes ownership and discards ink by documented design ("viewport gestures own the interaction exclusively"); Space keyDown ink discard is disclosed as CVX-04 in §5.2. ⌘-scroll zoom and pinch resume normally once the pointer interaction ends. |
| Unintended changes | None — own-diff is the complete change; 9 files only. |

## 4. Evidence evaluation

- Implementer's logs verified on disk: `batch1-focused` 15/15; `batch1-mutant`
  5 tests / 40 failures (each new test detects its mutation);
  `batch1-full-unit` 805 with exactly the 3 disclosed
  `testCommandScrollUsesReentrantCanvasZoomPath` failures at the pre-update
  lines; `batch1-full-unit-2` 805/4-skip/0-fail, `exit_status=0`.
- The Command-scroll test rewrite is legitimate — it still proves the
  reentrant zoom path and viewport delivery while asserting the new
  CVD-05-correct interim behavior.
- `Docs/Batch1-SWE-Verification-Review.md` (separate scope) independently
  reproduced the 805-gate on a private build. I did not rerun builds/tests —
  prohibited for this audit.
- **Coverage gap (non-blocking):** the new guard tests exercise ink only; no
  test covers scroll/pinch during image move/resize, shape drag, or erase,
  and none covers the F-1 cancel-during-suppressed-sequence interleaving.

## 5. Not verified here (native QA — Sol Low's scope)

Physical trackpad phase ordering and momentum tails; real
`NSMagnificationGestureRecognizer` delivery; SwiftUI identity/teardown timing
on actual section swaps; live panel hide/show; VoiceOver; real file-promise
providers; `.possible`-state recognizer behavior on hardware. Unit-level
synthetic events cannot establish any of these.

**CHANGES_REQUIRED**
