# Task Panel V2 — Batch 4 fix delta, independent review (SWE-A)

Scope: `.build/batch4-fixes.diff` (sha256 `13476310…`; independently reproduced byte-identical via
`git diff --binary` between provenance trees `c08decbe` → `a1cd645d` — exactly 9 implementer-owned
files), the post-change source and its callers, `PROVENANCE.md`, `MUTATIONS.md`, and the
`offline-xctest/` evidence in `.build/batch4-fixes/`. Read-only: the worktree still matches the
current snapshot (porcelain identical to `current-status.txt`). This reviews the fix delta against
Batch4SWE-A F1–F4 and Batch4SWE-B P2/P3 findings plus the launcher lifecycle change — not a repeat
baseline audit; no build or runner was attempted.

## Verdict

**Approve.** Every actionable finding is fixed at the correct layer with real, executed test
coverage. The stale-completion defect (F1) is closed at both owner and window layers; per-event
eligibility/directness rechecks (F2, F3), ghost-surface recovery on new-began/key-loss/
momentum-terminal events (B P2), cumulative approach progress, `nonisolated dragType`, the
latch-path `travel.reset`/`rescheduleTimers`, and manifest dylib identity all verified in source.
No test was weakened — the adapted dismissal test keeps its assertions; the new tests genuinely
fail when the fixes are reverted (mutation evidence below). No regressions found in the touched
code; `AtticPanel` and main-panel motion are untouched by this delta. Findings: none above
nit level; two informational nits and an honest set of remaining limits.

## Evidence legitimacy (independently established)

- **Diff/provenance.** Tree-hash snapshots reproduced the diff byte-for-byte; sha256 matches
  `PROVENANCE.md`; prefix/current status files identical; unrelated worktree state excluded.
- **Builds.** `build-local-1.log` BUILD SUCCEEDED; `build-for-testing-2.log` TEST BUILD SUCCEEDED
  on final source; remaining warnings are benign appintents noise only.
- **final-gate-1.log is genuine real-host XCTest, not a harness.** The header pins host stub,
  host `debug.dylib` and test-bundle SHA-256 — all three match the on-disk products I hashed
  myself (`2287db13…`, `324607c8…`, `9f00dfcc…`), and the test bundle's mtime (11:23:04) precedes
  the run start (11:23:10), tying the log to the final-source build. Per-suite executed counts
  sum to 351 (22+43+4+57+10+68+49+24+21+13+40); all 7 new window tests, both new controller
  tests, the adapted dismissal test, and the new travel test appear as started→passed;
  0 skipped; `exit_status=0`. The configuration is a real archived `XCTestConfiguration`
  (`testsToRun` = the 11 suites, `reportResultsToIDE=NO`, `testsDrivenByIDE=NO`,
  `testsMustRunOnMainThread=YES`, `testTimeoutsEnabled=NO`) injected via Xcode's own
  `libXCTestBundleInject.dylib` into the real `AtticUnitTestHost` — i.e. real XCTest running in
  the real host with unmodified assertions, honestly documented as *not* an xcodebuild/xcresult
  run. Legitimate.
- **Mutation evidence is genuine.** Real `xcodebuild build-for-testing` runs in an isolated
  `/tmp/attic-b4f-mutation` copy (distinct dylib SHAs `76682586…`, `205b5505…` prove mutated code
  was actually compiled). Round 1 (M1–M7 combined): 6 of 12 tests failed, each with assertion
  messages matching its fix's semantics at the expected lines. The one masking interaction
  (`testTerminalEventCarryingMomentum…` passed because M6 removed the guard M4 mutates) was
  correctly identified and isolated in round 2, where it failed alone. Total: all 7
  mutation-targeted tests fail without their fix; the 3 baseline/fake-owner tests passing under
  mutation is expected and correctly explained. Attribution is credible.
- **Launcher evidence.** The unified-log diagnosis (unmanaged PID 9983 dying ~1.46 s in vs the
  LaunchServices job 10135, parent 1, surviving) is real and properly hedged — "inferred from
  timing and ownership, not proven" is the right standard since unmanaged exits log no sender.
  `--verify` ran read-only against live PID 10135: sole instance, parent 1, mapped inode+size
  matching disk for stub *and* `debug.dylib`.
- **Provenance nit (cosmetic):** `focused-1.log` is described as a pre-warning-fix build yet
  records image SHAs identical to final-gate. The fix was a test-file `@MainActor` attribute
  under `SWIFT_VERSION=5.0`, which does not change codegen — a byte-identical bundle is expected.
  Consistent; no action.

## Fix verification

**F1 (medium) — stale swipe completion: fixed at both layers, verified end to end.**

- Owner side (`SubtaskPanelController.swift:1003-1051`): `swipeDismissalSession(for:)` returns
  `transientSwipeRevision` only while `canBeginSwipeDismissal` holds (transient match, unpinned,
  not busy). The revision is bumped by `syncState`'s `SwipePresentationKey` (family/latch/detach)
  — every lifecycle mutator funnels through `syncState` (verified: hover open :341-342, hover
  close :386-387, explicit open :586-587, latch path :569, detach :193-198, pin :779-782,
  unpin :799-821, closePinned :826-829, dismissTransient :684-689, `closeTransientSurface`
  :956-965), plus an explicit `invalidateTransientSwipe()` in `openFamilyPanel`'s
  already-on-screen branch (:559-562) covering both the latch upgrade and deliberate re-open.
  `completeSwipeDismissal(for:session:)` declines any non-current session, so a stale callback
  cannot close a re-latched or replaced surface.
- Window side (`PanelSurfaceHostingView.swift`): `swipeDismissal.didSet` cancels unconditionally
  (:11-13) so any reconfigure drops an in-flight gesture *and* its pending completion; the
  completion is now a generation-guarded `asyncAfter` (:143-163) instead of the CA completion
  block — a real improvement since the CA block also fired on animation removal; a new `.began`
  cancels whatever the previous sequence left presented (:76-84).
- Coverage: `testStaleSwipeCompletionNeverClosesAReopenedLatchedOrReplacedSurface` (hover→latch,
  latched re-open, cross-family reuse, close/reopen, and a still-current session completing),
  `testReconfiguringDuringTheCompletionDelayDropsTheStaleCompletion`,
  `testCompletionDeclinedForAStaleSessionRestoresTheSurface` — executed in the gate; the first
  two are mutation-killed, the third correctly passes under mutation (window-side behavior with a
  fake owner performing the session check).
- Trace: a cross-family re-present during the 160 ms window is killed twice — `didSet` bumps the
  generation, and `complete(B, oldSession)` declines against B's current revision; the surface
  then restores via `cancelSwipeDismissal`. Same-family latch is killed twice — explicit
  `invalidateTransientSwipe` plus the key-change bump in `syncState`.

**F2 — busy/eligibility recheck: fixed.** The window re-reads `swipeDismissal?.session()` for
every routed event (`:93`); a lock engaging mid-gesture yields nil → cancel + the event reaches
content. At completion, `swipeDismissalSession` repeats the full `canBegin` set including
`surfaceInteractionBusy` (familyEditBusy + menuTracking, :488-490). Executed coverage:
`testSwipeCompletionRechecksBusyAndPinnedEligibility` (edit, delete confirmation, menu tracking,
pin) — mutation-killed under M3.

**F3 — modifiers/indirect samples: fixed.** `.flagsChanged` joins the interruptions, now a
*superset* of `AtticPanel`'s list (adds `.smartMagnify`, `.rotate`, `.swipe`; `:32-35` vs
`AtticPanel.swift:65`). Modifier-bearing, imprecise, phase-less, button-held and momentum
mid-sequence samples all fail `isDirectSwipeSample` (`:176-183`) → cancel + `forward` — the
previously dropped scroll tick now reaches content. Executed coverage:
`testModifierLockOrIndirectSampleMidGestureCancelsAndReachesTheContent` — mutation-killed under M6.

**B P2 — ghost surface: fixed.** Terminal `.ended`/`.cancelled` events count as direct samples
even with momentum (`:177-180`) — a superset of `AtticPanel:74`, which tolerates `.ended` only —
so the tracker always finalizes; a new `.began` runs the full restore (`cancelSwipeDismissal`)
rather than a tracker-only reset; `resignKey` cancels an unfinished sequence (`:62-65`);
interrupts key off the routed session, not tracker state, so they still heal after the tracker
resets. Executed coverage: `testTerminalEventCarryingMomentumStillFinalizes` (mutation-killed,
isolated round 2), `testNewSequenceAndLostKeyRestoreAnUnfinishedGesture` (mutation-killed under
M5/M6).

**TransientTravel (B P3 + A F4): fixed.** `recordProgress` (`SubtaskPanelLayout.swift:755-767`)
now measures net approach against the last renewal reference — sub-minimum steps accumulate
instead of reading as parked; jitter cannot renew since the reference only moves on ≥minimum
progress; monotonicity preserved so the bound holds (`closeDecision` keeps its
`corridorTransitBudget` deadline, :716-725). `switchDecision` no longer writes the deadline it
never enforced — and no longer leaves one for a later close to inherit (F4). Executed coverage:
`testSlowContinuousApproachAccumulatesProgress` — mutation-killed under M7.

**Lows:** `nonisolated static let dragType` (`NoteInlineCards.swift:174`) clears the Swift 6
isolation warning (both final builds clean of it). `openFamilyPanel`'s already-presented branch
now `travel.reset()` + `rescheduleTimers()` (:566-568) so latching drops hover-governed pending
work (B note). The manifest and `launch-provenance.txt` now record inode/size/SHA-256 for both
the stub and `debug.dylib` (B P3). The `run-1==run-2` artifact note is correctly declared
historical.

**Launcher lifecycle:** `open -n` hands the app to launchd; PID discovery by exact executable
within a bounded 20 s wait, sole-instance + parent-1 + mapped-inode/size verification across a
3 s stability window with post-hash re-check, provenance file, and a read-only `--verify` mode —
verified against live PID 10135 without touching it. The `fail`-on-multiple-instances guard is
the right behavior for a per-branch preview. The new launch path itself is unexercised (live
owner's gate) — honestly flagged.

## Findings

None at actionable severity. Two informational nits:

- **Nit — key loss during the completion window cannot un-commit a dismissal.**
  `PanelSurfaceHostingView.swift:62-65` and the interruption check at `:69` are gated on
  `swipeSession != nil`, but `swipeSession` is cleared at `:102` before the completion delay — so
  a `resignKey`/mousedown arriving inside the 160 ms completion does nothing (the mousedown is
  additionally swallowed by `allowsContentInteraction == false`). This matches "a decided swipe
  completes" and `AtticPanel`, which likewise cannot un-commit; if a cancel-on-interrupt-during-
  completion is ever wanted, gate on `swipePresented` instead. No action required.
- **Nit — `.endGesture`/`.gesture` are absent from `swipeInterruptions`** — parity with
  `AtticPanel.swift:65`, which also omits them. No action.
- **Coverage note (not a defect):** `NSEvent.pressedMouseButtons` inside `isDirectSwipeSample`
  cannot be exercised by the synthesized CGEvents — the button-held recheck has source-review
  coverage only.

## Remaining limits (owed, consistent with the ledger)

- `AtticUITests` incl. `SubtaskHoverPinnedUITests`: never executed (need testmanagerd/UI
  automation).
- The gate ran the 11 suites named in `testsToRun`; the `AtticTests` bundle contains ~27 further
  XCTestCase classes (canvas/agent/settings/notes periphery) that did not execute. Untouched by
  this delta, but a full-bundle unit run is still owed at integration.
- No IDE result bundle; `testTimeoutsEnabled=NO` (externally watchdog-bounded) and no coverage
  data — acceptable trade for unblocking the gate, worth restating.
- The window↔controller seam is tested on both sides (fake owner driving real `sendEvent`; direct
  `swipeDismissalSession`/`completeSwipeDismissal` calls on the real controller) but not as one
  end-to-end flow.
- Physical/live verification is still owed on a preview rebuilt from this source: trackpad feel,
  real momentum delivery, click-mid-swipe, Reduce Motion rendering, corridor at real pointer
  speed — via the new launcher path (itself unexercised; run `--verify` before live checks).

No deferred CloudKit/APNs/iPhone/TestFlight/Production behavior is claimed or implied.
