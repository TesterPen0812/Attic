# Task Panel V2 — Batch 4 Independent Review (SWE-A)

Reviewer scope: `.build/batch4.diff` (prefix `b619b8f` → worktree `b9c9bf4`), post-change
source, callers, tests, provenance, and live evidence in
`/Users/taha/Developer/attic-task-panels-v2`. Read-only; no source, test, UI, data, or
preview mutation. Requirements R6 (pointer travel/pinning) and R7 (trackpad dismissal)
per `Docs/TaskPanelV2Requirements.md`; ruling: clicked/dragged (latched) panels persist
until outside click; main-panel accepted motion unchanged.

## Verdict

Batch 4 is well built. The classifier, corridor, latch lifecycle, motion host, drop, and
symlink paths are correct under source-level trace, with one real race in surface reuse
(medium), two low-severity gesture-gate divergences from the main panel's own policy,
and one dead-state nit. Local and test builds pass; the only executed tests are the
48/48 standalone real-source `SubtaskPanelTests` harness and the symlink harness — the
controller/drop/window XCTest suites never ran (runner stalled before suite discovery),
and no physical gesture or rendered-frame verification exists for Batch 4.

## Evidence interpretation (explicit)

| Evidence | Status |
| --- | --- |
| Source review | Full trace of diff + callers, this report |
| Local build | `build-local-2.log` — BUILD SUCCEEDED |
| Test build | `build-for-testing-2.log` — TEST BUILD SUCCEEDED |
| XCTest | `unit-focused-1.log` — host launched, **zero suites discovered**, stalled 180 s, stopped, no retry. Controller/drop/window/surface/geometry suites compiled but **unexecuted** |
| Standalone harness | Real `SubtaskPanelLayout.swift` + real `SubtaskPanelTests.swift`, stubbed constants/XCTest only — **48/48 pass** |
| Symlink harness | Pre-fix reproduced traversal/skip failures; post-fix all cases pass |
| Live preview | **Not rebuilt, relaunched, or driven for Batch 4.** Frozen preview (PID 69452) still maps the pre-Batch-3 image; Batch 3 paperclip P1 was a stale process, not source. Rendered appearance and all physical gestures remain unverified |

## Findings

### F1 — Medium: stale swipe-completion callback closes a newly presented/latched surface

- **File/lines:** `Attic/Window/PanelSurfaceHostingView.swift:9-11`, `:110-128`;
  `Attic/Window/SubtaskPanelController.swift:987-990`, `:1005-1010`, `:557-575`.
- **Causal trigger:** when a swipe completes, `completeSwipeDismissal()` animates for
  `completionDuration` (0.16 s) and only then calls `self.swipeDismissal?.complete()`
  — the dismissal value **current at callback time**, not the one the gesture began
  with. `swipeDismissal.didSet` cancels an in-flight gesture only when set to `nil`;
  `configureSurface` installs a new closure on every family reconfigure without
  bumping `swipeGeneration`. Two reachable cases inside the 160 ms window:
  - Cross-family: `presentTransient(B)` (row click that falls through the
    interaction-disabled surface, `toggleFamilyPanel`, `revealImportedAttachments`
    at `SubtaskPanelController.swift:636`) reuses `transientPanel`; the stale
    callback invokes B's `complete()` → `completeSwipeDismissal(for: B)` matches
    `lifecycle.transientFamilyID == B` → `closeTransientSurface()` kills B's
    just-presented panel.
  - Same-family latch: `openFamilyPanel(A)` hits the `alreadyPresented` raise path
    (:557-575) — no reconfigure — yet the stale `complete()` still matches A and
    closes the panel the user just latched. `swipeGeneration` (:121) only guards
    against a *new gesture*, not lifecycle/reconfigure changes.
- **Narrow fix:** invalidate the pending completion on any surface-affecting change —
  call `cancelSwipeDismissal(animated: false)` unconditionally in `didSet` (no-op when
  idle, also guarantees a clean transform on reuse) **and** cancel the in-flight
  completion when `openFamilyPanel` latches the dismissing family (or capture the
  latched/family state at gesture start and decline in `completeSwipeDismissal` when
  it changed).
- **Evidence:** direct trace of the callback, `didSet`, `configureSurface`, and both
  `openFamilyPanel` paths above. No test exercises window reuse across the completion
  window; the controller XCTests that would cover it were never executed.

### F2 — Low: mid-gesture lock acquisition is not honored; `complete()` never rechecks busy

- **File/lines:** `PanelSurfaceHostingView.swift:58` (`canBegin()` evaluated once at
  `.began`); `SubtaskPanelController.swift:1005-1010` (`completeSwipeDismissal` lacks a
  `surfaceInteractionBusy` guard). Contrast `AtticPanel.swift:113`, which re-evaluates
  `canBeginTrackpadSwipe` on **every** scroll event and cancels if it turns false.
- **Causal trigger:** a family lock arising mid-gesture via a non-event path —
  `familyEditBusy` covers `editingTaskID`, delete/complete confirmations,
  `presentedTaskAttachmentsID`, `taskAttachmentPickerOwnerID`
  (`SubtaskPanelController.swift:417-428`) — can be set programmatically or by Combine
  sinks without a click/key that would cancel the gesture. The swipe then completes
  and tears down a surface hosting a live edit/confirmation.
- **Narrow fix:** add `!surfaceInteractionBusy(familyID)` to `completeSwipeDismissal`,
  or recheck `canBegin` on `.changed` events mirroring `AtticPanel`.
- **Evidence:** source; most lock paths do route through mouse/key events that cancel,
  hence Low.

### F3 — Low: modifier presses mid-gesture neither cancel nor re-gate

- **File/lines:** `PanelSurfaceHostingView.swift:61` (`modifierFlags` checked only at
  `.began`), `:48-49` (`.flagsChanged` absent from the cancel list). Contrast
  `AtticPanel.swift:65` (`.flagsChanged` cancels) and `:74-84` (modifier-bearing scroll
  events cancel + pass through).
- **Causal trigger:** pressing ⌘/⌃/⌥/⇧ mid-swipe keeps the dismissal tracking; on
  devices where ⇧ remaps the scroll axis the tracker then ingests axis-flipped deltas.
  Related nit: an imprecise or phase-less scroll event mid-gesture ends tracking via
  `finish(cancelled:)` (`SubtaskPanelLayout.swift:830-833`) but is **consumed** at
  `PanelSurfaceHostingView.swift:84-85` rather than forwarded to content as the main
  panel does — one dropped scroll tick per occurrence.
- **Narrow fix:** add `.flagsChanged` to the cancel list; on modifier gain or
  non-precise/`.none` events mid-sequence, cancel and `super.sendEvent(event)`.
- **Evidence:** source diff between the two sendEvent implementations; harmless in the
  common case since modifiers at `.began` are gated and reversal semantics bound the
  damage.

### F4 — Nit: `TransientTravel.switchDecision` writes a deadline it never enforces

- **File/line:** `SubtaskPanelLayout.swift:737`.
- **Causal trigger:** `deadline` is stored but never read (contrast `closeDecision`
  :713-721, which uses it to bound corridor parking). Deferral stays bounded in
  practice — each pending-open maturity re-samples coverage and non-progress returns
  `.proceed` — so this is dead state, not a hang.
- **Narrow fix:** delete the write, or consult it to cap total switch deferral.
- **Evidence:** read of `TransientTravel`; `deadline` has no consumer on the switch path.

## Verified-clean categories (source trace; physical verification still owed)

- **Classifier precision** (`SubtaskSwipeDismissTracker`, `SubtaskPanelLayout.swift:829-935`):
  6 pt intent distance, 1.5× dominance required on the first nonzero delta *and* cumulative
  displacement *and* sign consistency — vertical/diagonal intent rejects permanently for the
  sequence; initial-direction lock via `tracking(sign:)`; reversal subtracts distance and
  `velocity <= -450` cancels outright; flick ≥450 pt/s completes from 12% progress, otherwise
  50%; `.ended` in `undecided` passes through; non-precise/non-finite/phase-less samples end
  the gesture; momentum gated at both window (:66) and tracker. Correct.
- **Pinned/edit locks:** pinned surfaces get `swipeDismissal = nil` — zero interception
  (`SubtaskPanelController.swift:987`); `canBegin` requires transient-family match + unpinned
  + not busy; locks are family-scoped; composer lock binds only the live transient's
  focused/drafted entry; unrelated main-panel state cannot hold a transient open; pinned
  panels never lock the main composer. Correct.
- **Normal-scroll immunity:** undecided/rejected samples forward to content; horizontal-scroll
  ownership checked at `.began` (`:130-142`; no horizontal scroll regions exist in
  `SubtaskPanelContent`, so it is defensive-only); mouse wheels/momentum stay with content;
  a sequence decided as dismissal is consumed, never half-delivered. Correct.
- **Reduce Motion:** `presentation` (:895-899) drops opacity to 0.2 with scale floor 0.995
  (fade-dominant) vs 0.45/0.94 normally; cancellation restores over `cancelDuration`; sampled
  per-gesture at `.began`. Correct.
- **Motion host / hit testing:** transform lives on a dedicated `motionView` layer AppKit does
  not lay out; `hitTest` (:184-188) routes to untransformed content and honors
  `allowsContentInteraction`; squircle-corner pass-through preserved
  (`PanelSurfaceHostingView.hitTest` :240-248); `orderOut` (:91-94) force-restores so a reused
  window never reopens faded; `swipeGeneration` correctly lets a *new gesture* supersede a
  pending completion — but not a reconfigure (see F1). Transform math (:902-908) scales about
  the visual center independent of anchorPoint. Correct apart from F1.
- **Pointer corridor / pinning:** hull spans source row → actual placed transient frame
  including avoidance displacement; pinned frames extend coverage only while the point is
  inside the hull; transit budget renews only on real progress (≥ `corridorMinimumProgress`)
  or within `corridorApproachHold`; parking is bounded by `corridorTransitBudget`; `.surface`
  (squircle) arrival cancels immediately; points beyond the surface half-plane are `.outside`.
  Correct.
- **Latch ruling:** latched (clicked/dragged) transient ignores neutral hover and survives
  anchor scroll-out; unlatched closes on anchor loss; outside-click monitor installed only
  while latched (`:1174`); explicit outside clicks — including main-composer and pinned-panel
  clicks — close a latched transient. Correct.
- **Task drop:** row drops and surface drops resolve children to the parent, latch a
  hover-opened transient first, `fileDrop.end()` clears every targeted source before attach,
  and failures do not report success. Correct at source level; XCTest unexecuted.
- **Symlink cleanup:** `.isSymbolicLinkKey` requested; staging/UUID/digest link entries and
  link-typed children skipped rather than traversed or removed; linked files outside the
  store survive launch sweep and orphan cleanup. Post-fix harness green.
- **Main panel:** separate `PanelTrackpadDismissTracker`/`AtticPanel.sendEvent`; accepted
  animation untouched. Correct.
- **Other fixes:** launcher process matching is exact-path + unique-PID verified (safe);
  `composerAttachWidth` is a shared constant consumed by both model and view (consistent);
  `PanelSurfaceDragGeometry` merging/measured-control exclusion sound.

## Unmet gates

1. **XCTest never ran.** `xcodebuild test-without-building` stalled 180 s before suite
   discovery; stopped, not retried. Compiled-but-unverified: `SubtaskPanelControllerTests`
   (incl. the new latch/swipe tests and 4 adapted latch tests), `TaskAttachmentDropTests`
   (2 new), `PanelSurfaceHostingViewTests` (motion container unexercised),
   `PanelSquircleGeometryTests` (composer width). The 48/48 harness covers layout/lifecycle/
   tracker policy only — it is not a substitute for controller/window integration tests.
2. **No live verification.** Preview not rebuilt/relaunched/driven; physical two-finger
   gestures, corridor travel, hit-testing under motion, Reduce Motion rendering, and the
   Batch 3 paperclip render check all remain manual UAT. The frozen preview still maps a
   pre-Batch-3 image.
3. **Provenance gap:** the recorded executable SHA hashed a 41 KB stub; future live reports
   must record the debug-dylib hash and the running PID's mapped image/inode.
4. **F1–F3 fixes** pending implementation + tests.

No deferred CloudKit/APNs/iPhone/TestFlight/Production behavior is claimed. No broad
baseline duplicate audit performed, per scope.
