# Task panel V2 Batch 4 — Fix delta review (SWE-B: launcher/travel/provenance)

Scope: independent read-only review of `.build/batch4-fixes.diff`
(sha256 `1347631001c3bb3bfa8025264e5993523fb43258cbfee423139f2db801a16296` —
recomputed on disk, matches `PROVENANCE.md`), prefix tree `c08decbe…` →
current tree `a1cd645d…`, exactly 9 files, all implementer-owned.
`prefix-status.txt` and `current-status.txt` are byte-identical
(sha256 `2b1d4b88…`), so no reviewer/orchestrator/live file moved between
snapshots. My primary scope per dispatch: LaunchServices launcher lifecycle
and PID/image provenance, cumulative pointer travel, latch cleanup, the low
warning fixes, unrelated regressions, and independent verification of the
reported test evidence. I also traced the gesture/session rework far enough
to confirm coverage and callers. No source, test, UI, data or preview
mutation; no commits; no runner attempts.

## Verdict

**APPROVED.** Every actionable finding from Batch4SWE-A (F1–F4) and
Batch4SWE-B (P2 + four P3s + the rescheduleTimers note) is fixed correctly
in source, with real executed tests that were proven to fail on the
pre-fix behaviour by an actual mutation check. The offline in-host XCTest
evidence is legitimate: 351/351 in 11 real suites ran in the real
`AtticUnitTestHost` against the final on-disk images — verified by hash —
and this is a real XCTest run minus the IDE session, not a harness or an
xcresult claim. Remaining exposure is the honestly-disclosed unexercised
paths (new `open -n` launch never run end-to-end; physical gestures;
AtticUITests) and two narrow residual states noted below — no P0/P1/P2.

## Evidence legitimacy (independently established, not taken on report)

- **The gate log is real XCTest output.** `final-gate-1.log` contains
  per-case `started`/`passed` lines with real test names and plausible
  timings (the five RunLoop-waiting window tests run 0.319–0.641 s,
  matching `waitPastCompletion` = `completionDuration` 0.16 + 0.15 s).
  Suite math checks: 22+43+4+57+10+68+49+24+21+13+40 = **351, 0 failures,
  0 skipped**, exit 0.
- **The tested image is the final source.** The log header's
  `host_sha256`, `host_debug_dylib_sha256` and `bundle_binary_sha256`
  (`2287db13…`, `324607c8…`, `9f00dfcc…`) match the on-disk products at
  `.build/DerivedData/Build/Products/Local` — I re-hashed all three.
- **The mechanism is the real injection path, not a reimplementation.**
  `run.zsh` launches the real host with
  `DYLD_INSERT_LIBRARIES=libXCTestBundleInject.dylib` and
  `XCTestConfigurationFilePath` pointing at an `XCTestConfiguration`
  written by `makeconfig.m` through real `XCTestCore` classes. The
  archived config is a genuine NSKeyedArchiver bplist with
  `reportResultsToIDE=false`, `testsDrivenByIDE=false`,
  `testsMustRunOnMainThread=true`, `testsToRun` = the 11 suites. This is
  the same bundle-injection mechanism testmanagerd drives, minus the IDE
  handshake that was stalling — so "no IDE" is the point, not a
  workaround. Limit stands: it produces stderr logs, not an `.xcresult`.
- **Mutation check is real and correctly designed.** `mutation-1.log`
  shows a *different* host debug-dylib hash (`76682586…`) than the final
  image — proof mutated production code was compiled and injected — and
  fails exactly the 6 expected tests with real assertion output citing
  the final test file's line numbers. `mutation-2-momentum-only.log`
  isolates M4 after the round-1 masking was noticed: only
  `testTerminalEventCarryingMomentumStillFinalizes` fails
  (`("[]") is not equal to ("[1]")` — no completion). 6+1 = the claimed
  **7 mutation-killed tests**; the other 3 new tests are baseline guards
  and passed, as disclosed.
- **No weakened tests.** The only adapted test
  (`testSwipeDismissalIsOfferedOnlyToTheFamilysUnpinnedIdleSurface`)
  keeps every original assertion and *adds* `XCTAssertNil(session)` for
  the pinned case. All other delta to test files is additive.
- **Builds:** `build-local-1.log` BUILD SUCCEEDED;
  `build-for-testing-2.log` TEST BUILD SUCCEEDED on final source with one
  infrastructure warning only. The pre-fix `dragType` Swift-6 warning
  (seen in `batch4/build-for-testing-2.log` at `TaskAttachmentDrop.swift:35`)
  is gone — and `TaskAttachmentDrop.swift` *was* recompiled post-fix
  (4 compile steps in `build-for-testing-1.log`), so this is verified at
  the use site, not just by incremental-build silence. The identical test
  bundle hash between `focused-1` and `final-gate-1` is consistent: the
  warning fix is a `@MainActor` annotation with identical `-Onone` codegen.
- `zsh -n Scripts/launch_local_preview.zsh` parses clean (verified here).

## Findings → fixes (verified in source, callers traced)

### SWE-A F1 (medium) — stale 160 ms completion closes a re-presented/latched surface: **fixed, two independent layers**

- `PanelSurfaceWindow` now passes a **session token**: `swipeDismissal`
  carries `session: () -> UInt64?` and `complete: (UInt64) -> Bool`
  (`PanelSurfaceHostingView.swift:209-216`); the owner returns
  `transientSwipeRevision` only while `canBeginSwipeDismissal` passes
  (`SubtaskPanelController.swift:1023-1034`). The asyncAfter completion
  calls `complete(session)` and restores on decline.
- Revision bumps via `invalidateTransientSwipe()`
  (`SubtaskPanelController.swift:1048-1051`) on (a) every
  `SwipePresentationKey` change — family, latch, detach — in `syncState`
  (:897-906), and (b) every deliberate `openFamilyPanel` of the on-screen
  family (:559-569), which also now `travel.reset()`s and
  `rescheduleTimers()` — fixing SWE-B's stale-travel note as a bonus.
- `swipeDismissal.didSet` cancels unconditionally (:12), so any
  `configureSurface` reuse kills the pending completion via the
  generation bump; `DispatchQueue.asyncAfter` replaces the CA completion
  block that also fired on removal (:155-162).
- Every lifecycle-mutating path reaches `syncState()` or explicit
  invalidation (detach :193-198, dismiss :685-692, unpin→transient
  :795-822, closePinned :825-831, closeTransientSurface :956-965);
  `mainPanelDidHide` bypasses syncState but `orderOut` cancels and
  `complete()`'s family re-check declines. Even a hypothetical
  syncState-skipping mutation still fails `canBeginSwipeDismissal`'s
  family/pinned/busy re-check at completion time — defence in depth is
  real, not cosmetic.
- Covered by `testStaleSwipeCompletionNeverClosesAReopenedLatchedOrReplacedSurface`
  (controller: hover-latch, latched re-open, cross-family reuse,
  close/reopen — and a *current* session still completes) plus
  `testReconfiguringDuringTheCompletionDelayDropsTheStaleCompletion` and
  `testCompletionDeclinedForAStaleSessionRestoresTheSurface` (window).
  All three were mutation-killed.

### SWE-B P2 — ghost surface (faded, scaled, click-dead): **fixed on both causal paths**

- Terminal `.ended`/`.cancelled` events now count as direct samples even
  with non-empty `momentumPhase` (`isDirectSwipeSample`,
  `PanelSurfaceHostingView.swift:176-183`) — the divergence from
  `AtticPanel.sendEvent`'s tolerance is closed (verified at
  `AtticPanel.swift:73-75`).
- A new `.began` cancels when `swipeSession != nil || swipePresented`
  (:79), so a fresh sequence restores a surface the previous gesture left
  mid-motion — the tracker-only reset is gone.
- `resignKey` cancels an unfinished sequence (:62-65); interrupts key off
  `swipeSession` (not tracker state), so they still heal after the
  tracker resets (:68-73).
- Covered by `testTerminalEventCarryingMomentumStillFinalizes`
  (mutation-killed in isolation) and
  `testNewSequenceAndLostKeyRestoreAnUnfinishedGesture`.

### SWE-A F2 / SWE-B P3 — mid-gesture lock/pin not honoured: **fixed**

Eligibility is re-read per event: `swipeDismissal?.session() == session`
at :93 embeds `canBeginSwipeDismissal` — transient-family match,
unpinned, `!surfaceInteractionBusy` (edit, delete/complete confirmations,
attachment picker, `menuTracking`; :488-490). A lock engaging
mid-gesture cancels **and forwards the event to content** (:94-96);
`completeSwipeDismissal` re-checks the same predicate at completion.
Covered by `testSwipeCompletionRechecksBusyAndPinnedEligibility` —
mutation-killed — and the lock-acquisition arm of
`testModifierLockOrIndirectSampleMidGestureCancelsAndReachesTheContent`.

### SWE-A F3 — modifiers/indirect samples: **fixed**

`.flagsChanged`, `.smartMagnify`, `.rotate`, `.swipe` join the interrupt
set (:32-35); modifiers, pressed buttons, imprecise, phase-less and
non-terminal momentum samples are re-gated per event (:93) and now reach
the content instead of being swallowed — closing F3's dropped-tick nit.
Interrupt parity with `AtticPanel.swift:65` confirmed.

### SWE-B P3 — `recordProgress` per-check threshold: **fixed (cumulative)**

`closestDistance` is now the distance at the last *renewal*, not the
all-time min updated every sample (`SubtaskPanelLayout.swift:754-767`).
A ~1.2 pt/0.075 s creep now accumulates against the fixed reference and
renews the transit budget; progress remains monotone and bounded, and
`noteStart` seeding is unchanged. `testSlowContinuousApproachAccumulatesProgress`
asserts exactly this — deferred through 3 budgets of sub-threshold steps,
then proves parked jitter cannot renew (`.proceed` after the budget) —
mutation-killed. R6 "generous enough for normal travel" intent met.

### SWE-A F4 — dead `switchDecision` deadline: **fixed**

The `deadline` write is removed (:737-742); deferral is bounded by
monotone progress alone; `closeDecision` keeps its own deadline. The new
test asserts `travel.deadline == nil` after switch deferrals.

### Lows

- **`dragType` isolation (B P3):** `nonisolated static let`
  (`NoteInlineCards.swift:174`) — correct minimal fix for a `let`
  constant; use site recompiled clean. Swift 6 error pre-empted.
- **Manifest/stub provenance (B P3):** manifest now records
  inode+size+SHA-256 for both the stub and `*.debug.dylib`
  (script :363-369); stub-only hashing is gone.
- **alreadyPresented timers (B note):** `travel.reset()` +
  `rescheduleTimers()` on the latch/raise path (:567-568) — and
  `openTransient` already clears pending records (:604-605), so the
  re-arm cancels cleanly rather than firing to no-op.
- **`run-1 == run-2` provenance nit:** historical, disclosed as such.

## Launcher lifecycle — primary scope, verified line by line

- **Root cause is correctly evidenced, and the evidence file is honest
  about inference:** `launcher-lifecycle-evidence.txt` shows PID 9983 as
  `com.apple.xpc.launchd.unmanaged` dying 1.46 s after first log line —
  exactly the health-window end — vs PID 10135 as a launchd
  `application.com.taha.Attic.taskpanels.v2` job staying up. The file
  explicitly says teardown-by-invoking-command is *inferred* (signal
  sender unlogged for unmanaged processes), not proven. That is the
  right epistemics; the fix is correct regardless because LaunchServices
  ownership is strictly more durable.
- **The fix:** `/usr/bin/open -n --stdout/--stderr` (:456) → bounded
  20 s appear loop requiring the process to *already map the executable*
  via lsof inode+size (:460-469) → sole-instance + parent-1 +
  mapped-stub-and-dylib verification across a 3 s stability window with
  re-stat TOCTOU check (:476-487) → `launch-provenance.txt` written and
  printed. PID/path files are cleared before launch (:450) so a failed
  launch can't leave stale records. `verify_preview_process` fails
  closed on every mismatch.
- **`--verify` is genuinely read-only and was proven live:** it exits
  before the build, the UI lock and any signal (:320-327);
  `launcher-verify-live-10135.txt` shows exit 0 against the running
  preview — sole instance, ppid 1, mapped inode/size matching on-disk
  stub (`139292913`/41008) and dylib (`139292911`/20452688,
  `5e68f56f…`) — and it correctly surfaced the stale `recorded_pid=9983`.
- **Honest limit, disclosed in PROVENANCE and ledger:** the new `open -n`
  launch path itself has never run — `--verify` was exercised against a
  manually-`open`-launched instance (the same mechanism). The appear /
  stability / fail branches are source-verified only.

## Notes (non-blocking)

- **Committed dismissal is not click-cancellable.** Once `.ended` clears
  `swipeSession`, non-scroll interruptions during the 160 ms completion
  window do not cancel — the close lands unless a surface-affecting
  change (latch, re-open, reconfigure, family switch) bumps revision or
  generation, in which case the window restores. Same semantics as
  pre-fix, and arguably correct ("the swipe was committed"); flagged for
  awareness, not action.
- **Residual stuck-state narrowed, not zero.** A sequence abandoned with
  literally no further event still leaves the surface presented — but any
  subsequent `.began`, interrupt, `resignKey` or click now heals it
  (clicks heal via the interruption list rather than being swallowed).
  Acceptable.
- **`mapped_identity` compares lsof `txt` names literally.** Works on
  this layout (live-verified); a path-alias mismatch would fail closed —
  safe direction.
- **Latched-but-unpinned remains swipe-dismissable** — `canBegin` doesn't
  check the latch, preserving pre-existing R7 semantics ("unpinned
  subpanel"). Consistent; only worth revisiting if the latch ruling was
  meant to bind deliberate gestures too.
- **Test-seam limit:** `eventForwardingForTesting` replaces
  `super.sendEvent` — routing is verified, AppKit delivery is not; the
  window is offscreen so `isVisible == false` takes the duration-0
  restore path, and `orderOut`/animated restore are unexercised.
  `contentOwnsHorizontalScrolling` is defence-only (no horizontal scroll
  region exists). All consistent with the disclosed limits.

## Regression check

Delta is confined to the 9 disclosed files; `AtticPanel`/main-panel motion
untouched; no other `PanelSurfaceSwipeDismissal` producers exist (the
type is instantiated only in `SubtaskPanelController.swift:1003` and the
test fixture). Vertical/normal scrolling still routes through the tracker
to `passThrough`→forward; pinned surfaces keep `swipeDismissal = nil` →
zero interception. No unrelated source moved between prefix and current.

## Remaining gates (carried, honestly disclosed)

1. New `open -n` launch path unexercised end-to-end; preview PID 10135
   runs the **pre-fix** image — rebuild/relaunch + `--verify` owed by the
   live owner.
2. `AtticUITests` still unexecuted (testmanagerd-dependent); physical
   R6/R7 gesture UAT and the batch-4 live checklist remain manual.
3. Offline gate should be re-run on integrated source at Batch 5; it is
   real XCTest but produces logs, not `.xcresult`.

No deferred CloudKit/APNs/iPhone/TestFlight/Production claims. No commits
or data changes. This review is `User2SWE`-level; `AstraHigh` final and
`Opus` follow-ups per orchestration remain ahead.
