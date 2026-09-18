# Task panel V2 — batch 4 (R6 corridor/travel + R7 swipe + fixes) independent review (SWE-B)

Reviewer scope: `.build/batch4.diff` (sha256 `b0f03819…`, verified on disk)
covering 14 files between prefix tree `b619b8f0…` and current tree
`b9c9bf43…` at HEAD `ae6418c`; `PROVENANCE.md`, `live-p1-evidence.txt`, and
both build/harness logs were read. The diff captures all content change
regardless of dirty-state at prefix (tree-hash snapshots), so unrelated
worktree modifications are excluded. Callers were traced rather than the
checklist: `TaskFamilyView.onHover` → `noteRowHover` → pending open/close →
`pointerSampleAtMaturity` → `pointerCoverage`/`TransientTravel` →
`transientClickIsInside` (consumed by both outside-click dismissal and
`AtticPanelController` auto-hide keep-alive); `PanelSurfaceWindow.sendEvent`
→ `SubtaskSwipeDismissTracker` → `motionContainer`; `pinFamily`/
`presentPinned`/`unpinPinned` → `configureSurface` → `swipeDismissal`.

## Verdict

**Approve with one P2 to fix before acceptance.** The R6 corridor/latch
implementation is internally consistent and every ledger claim checked out
in source: the corridor follows actual placement via a convex hull with a
source-facing half-plane, on-route pinned crossings become transit while
off-route ones don't, the latch survives neutral hover and source scroll-out
and dies only to outside click (matching the root ruling), and R7's
unpinned-only precise-swipe path is correctly gated with velocity and
Reduce Motion. One real defect: an un-finalized swipe sequence can leave a
"ghost" surface — faded/scaled and click-dead — in `PanelSurfaceWindow`'s
sendEvent glue, which is also the least-tested code (compiled, never
executed). Remaining items are P3. Evidence interpretation per instruction:
local + test builds pass; standalone real `SubtaskPanelTests` 48/48 is the
only executed suite; XCTest stalled at zero suites (180s, no retry), so
controller/drop/window XCTest remain unexecuted; live-p1 is a stale-process
diagnosis, not rendered validation; preview was not rebuilt or relaunched.

## Findings

### P2 — Un-finalized swipe leaves a ghost surface (faded, scaled, click-dead)

`Attic/Window/PanelSurfaceHostingView.swift:46-87` — specifically the
`momentumPhase.isEmpty` guard at :66 and the tracker-only reset at :57.

Causal trigger, two paths to the same state:

1. A `.ended`/`.cancelled` scroll event that carries a non-empty
   `momentumPhase` fails the guard at :66 and is passed to `super`
   without reaching `swipeTracker.update` — so the tracker never
   finalizes. `AtticPanel.sendEvent` explicitly tolerates this shape
   (`event.momentumPhase.isEmpty || event.phase.contains(.ended)`), so
   it is a real event shape the main panel already handles and this one
   drops.
2. If the terminal event simply never arrives (key loss mid-gesture —
   `PanelSurfaceWindow` has no `resignKey` cancel, unlike `AtticPanel`),
   the tracker likewise stays mid-gesture.

Once stuck: `motionContainer.allowsContentInteraction` stays `false`
(:80) and the faded/scaled presentation (:81) sticks. The next `.began`
runs `swipeTracker.cancel()` (:57) — a tracker-only reset that does not
restore the container — after which the non-scroll interrupt at :48 can no
longer heal (`isTracking` is false). From then, clicks inside the frame
hit `motionContainer.hitTest == nil` and are swallowed by the window; for
a latched surface an on-surface click is "inside" per
`transientClickIsInside` so it neither dismisses nor interacts. Recovery
exists (Escape, outside click, pointer-leave close for hover-governed,
`orderOut`), but the user-visible state is wrong.

Narrow fix: at `.began` call `cancelSwipeDismissal(animated: false)`
instead of `swipeTracker.cancel()` so any new sequence also restores
presentation/interaction; admit `.ended`/`.cancelled` through the
`momentumPhase` guard (mirror the `AtticPanel` condition) so terminal
events always finalize; optionally cancel on `resignKey`/`.flagsChanged`
to match the main panel's interrupt set.

Evidence: guard divergence vs `AtticPanel.sendEvent`; restore path
`cancelSwipeDismissal` (:96-108) is only reachable via `.cancel` update,
`orderOut`, or the click-interrupt — none of which fire in the stuck
sequence. This path has zero executed coverage (window sendEvent is
compiled-only; the 48/48 harness covers the pure tracker type, not the
wiring).

### P3 — `canBegin` sampled only at `.began`; not re-validated mid-gesture

`PanelSurfaceHostingView.swift:58` + `SubtaskPanelController.swift:997,
1005`. Eligibility is computed once at `.began`; `AtticPanel.sendEvent`
re-checks `canBeginTrackpadSwipe` (and `pressedMouseButtons`) per event.
A `surfaceInteractionBusy` lock engaging mid-gesture doesn't cancel, and
`completeSwipeDismissal` re-guards family/pin but not
`surfaceInteractionBusy`. Narrow trigger — the locks normally start via a
click that already cancels the gesture — and `closeTransientSurface`
releases interaction state anyway. Also `.flagsChanged`/`.rotate`/
`.swipe` aren't in the interrupt list, a parity gap vs the main panel.
Fix: re-check `swipeDismissal?.canBegin()` per event; extend the
non-scroll interrupt set to match `AtticPanel`.

### P3 — `@MainActor` static read from nonisolated context (Swift 6 error)

`Attic/Views/Panel/TaskAttachmentDrop.swift:35` —
`internalMarkerTypes` references `NoteInlineCardsLayout.dragType`, which
is `@MainActor` (`NoteInlineCards.swift:171-173`). Both build logs emit
the warning; `SWIFT_VERSION = 5.0` keeps it a warning today but it is an
error in Swift 6 language mode. Narrow fix: hoist the pasteboard-type
constant to a non-isolated scope (it's a `let` string), or isolate
`internalMarkerTypes`/`classify` — all callers are already main-actor.

### P3 — `recordProgress` threshold is per-check, not cumulative

`Attic/Services/SubtaskPanelLayout.swift:750-753`. Progress counts only
when distance drops ≥2 pt between consecutive maturity checks (~0.075 s),
i.e. ~≥27 pt/s steady-state is fine but a slow-but-continuous approach
below ~2 pt/check never renews the 0.6 s budget and the surface closes
mid-travel. "Creeping ≈ parked" is defensible, but if the intent is
"net approach over the transit", compare distance against the
`noteTravelStart` seed or a rolling window instead of last-check.

### P3 — Manifest still hashes only the stub executable

`Scripts/launch_local_preview.zsh:258` writes `executable_sha256` of the
~41 KB Mach-O stub; the P1 diagnosis showed implementation code lives in
`AtticTaskPanelsV2.debug.dylib` (~20 MB) and the stub hash is
build-invariant. The launcher now fixes process identity (PID sweep,
executable match, post-launch alive/singleton), but the manifest still
can't distinguish which build is running. One-line fix: add a
`debug_dylib_sha256` (and ideally the mapped-inode check the ledger
already recommends for future live reports).

### Note — `run-1.log` is identical to `run-2.log`

`.build/batch4/policy-harness/run-1.log` == `run-2.log` (both all-pass).
The ledger's "first run exposed two wrong inputs in new tests, corrected"
failing run isn't preserved in the artifacts — no evidence either way,
just a provenance nit. Harness fidelity itself is good: the test file is
the real `SubtaskPanelTests` minus `@testable import`, compiled against
the real sources, and the hand-copied stub constants match the real
values exactly.

### Note — `openFamilyPanel` alreadyPresented path skips `rescheduleTimers()`

`SubtaskPanelController.swift:559-560`. Armed pending work fires once and
no-ops via the pending-record guards; a transit observation can leave a
stale `deadline`/`closestDistance` in `travel` until the next `reset()`.
Self-correcting, cosmetic.

## Verified behavior (source + executed evidence)

- **R6 corridor follows actual placement** — `pointerCoverage`
  (`SubtaskPanelLayout.swift:95-157`) builds the convex hull of source row
  + positioned surface with one-row (32 pt) padding and a source-facing
  half-plane cut; moved-clear-of-pinned placement is honored.
- **Pinned crossing** — on-route pinned panels (SAT test against the
  hull, `crossingFrames`) count as transit; off-route pinned panels don't
  extend the corridor.
- **Neighbor-row vs dwell** — resting on another row is a normal hover →
  pendingOpen → dwell; traveling *toward* the current surface defers the
  switch/close via `switchDecision`; arriving cancels. `commitPendingClose`
  (:345) re-arms only while `.deferred`.
- **Latch** — `openTransient(latched: true)` from explicit open/drag;
  `noteRowHover` neutral hover can't downgrade; `closeTransientForLostAnchor`
  (:225) closes hover-governed only; `updateOutsideClickMonitoring` (:1173)
  installs the monitor only while latched; `noteOutsideMouseDown` (:1192)
  correctly excludes surface, ≤`sideGap` near-gap, source row, owned
  windows/sheets, popup/status menus, edit/menu locks, and count-control
  down/up pairs.
- **Pin identity** — `pinFamily`/`presentPinned` re-runs
  `configureSurface(mode: .pinned)` which nils `swipeDismissal` → pinned
  surface can't swipe-dismiss; same window/host retained, so moved
  position and view state persist; `unpinPinned` keeps the window.
- **R7 swipe** — precise-only, no modifiers/buttons/momentum,
  horizontal-dominance + direction gate, content-owned horizontal scroll
  pass-through, unpinned-only, velocity-aware completion, cancel restores
  content, Reduce Motion path — `SubtaskSwipeDismissTracker` is executed
  (48/48 harness); `PanelSurfaceWindow` wiring is compiled-only.
- **Drop routing** — `perform` clears targets + `panelTarget?.end()`
  before acceptance; task/files/card/unsupported arms stay distinct;
  task drop begins before async payload load.
- **Symlink cleanup** — `isDirectory` now requires non-link (`lstat`);
  links are never traversed or removed in `removeUnreferencedMaterializations`,
  `cleanOrphans`, or staging cleanup; post-fix symlink harness all-pass.
- **Composer width** — `composerAttachWidth = 28` is shared between the
  unconditional paperclip frame and `TaskEntryBarLayout.textFieldWidth`;
  worst-case field ≥120 pt per the layout model.
- **Stale-process diagnosis** — verified: PID 69452 mapped replaced
  inodes vs the on-disk bundle; on-disk `debug.dylib` contains the
  paperclip strings; recorded PID dead; no crash report. Launcher
  verified by reading: exact-executable PID sweep, recorded-path match,
  post-launch alive + singleton checks. Main-panel motion untouched in
  batch4.diff.

## Unverified / unmet gates

- **XCTest** stalled at zero suites after 180 s — controller/drop/window
  XCTest suites compiled but unexecuted. No retry per instruction. The
  48/48 harness is the real `SubtaskPanelTests` (pure layout/lifecycle/
  travel/tracker) with real sources — NOT equivalent to XCTest; the
  controller, sendEvent, drop-delegate, and file-store glue have
  source-review + compile evidence only. The P2 finding lives precisely
  in that unexecuted glue.
- **Preview/live** — not rebuilt or relaunched; `live-p1-evidence.txt` is
  a stale-process diagnosis, not rendered validation. All R6 corridor
  behavior at real pointer speed, R7 gesture feel/Reduce Motion, composer
  paperclip/picker/pending-card/upward-growth/submit, and launcher
  end-to-end run remain owed to the exclusive live owner.
- **Process** — per the stated model/process note, this interim review is
  `User2SWE`; final `AstraHigh` review and `Opus` fixes are still owed.
