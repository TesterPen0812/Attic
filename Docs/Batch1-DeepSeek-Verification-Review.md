# Batch 1 — DeepSeek independent verification review

**Verdict: CHANGES_REQUIRED** — one P1 correctness gap and one documentation-overreach note. The six new tests are real, discriminating, and every snapshot/hash/build-provenance claim in `Docs/DeepAudit-Batch1-Implementation.md` reproduces exactly. The defect is in the CVD-02 fix itself: **board save failures still wipe undo history, cancel in-flight imports, and silently move the selected board**, contradicting the new in-code claim at `CanvasSession.swift:533` ("An invalid name or failed save must not cost undo history") and the audit's requirement to gate on successful board operations.

- **Review window:** 2026-09-15 10:19–12:05 BST (09:19–11:05 UTC). Active work ≈ 105 min; dedicated idle waiting for the other test host ≈ 0 min (see "Resource coordination").
- **Mode:** blind independent verification. No subagents. Shared checkout read-only; all builds/tests ran in private copies and private DerivedData/stores.
- **Owner:** this report plus `/tmp/deepseek-batch1-*` artifacts only.
- **Not performed:** any live UI launch, relaunch, physical input, CloudKit/APNs/iPhone/TestFlight validation, or user-store access. Native evidence remains PENDING.

---

## 1. Finding

### [P1] A failed board save still clears history, cancels imports, and moves the board — the CVD-02 gate misfires (confidence: high, unit-reproduced)

**Files/lines**
- `Attic/Canvas/CanvasSession.swift:530-536` (`createCanvas` gate) and `:553-565` (`deleteSelectedCanvas` gate).
- Root enabler (not edited by Batch 1, pre-existing dirty tree): `Attic/Services/CanvasStoreBoards.swift:44` sets `selectedCanvasID = id` **before** `save()` at `:45`; `:153-156` moves the selection **before** `save()` at `:161`. `save()` failure (`Attic/Services/CanvasStorePersistence.swift:73-83`) rolls back the context and reloads, but the reload re-applies whatever `selectedCanvasID` now holds (`CanvasStorePersistence.swift:429-430`), and for a rolled-back insert that id is not live, so resolution falls back to the **first board** (`CanvasStorePersistence.swift:156-159`).
- New test coverage that misses it: `AtticTests/CanvasSessionTests.swift:76-109` exercises only validation refusals (whitespace name, unknown id, last canvas). No persistence-failure path is covered anywhere in the suite.

**Trigger / reproducer** (deterministic; my private probe, in-memory store, failing `persist`)

1. `createCanvas("Alpha")`, `createCanvas("Beta")` → selected = Beta; draw a stroke (undo count 1).
2. Make persistence fail (`PersistenceGate.shouldFail = true`), call `createCanvas("Gamma")` → returns `nil` (correct), but:
   - session selection silently becomes **Alpha** (Beta is not restored; the store also reports Alpha),
   - `undoCommandCount` 1 → **0**, `canUndo` false,
   - `interactionCancellationEpoch` 2 → **3** (surface rebuilt), and an in-flight session image import is cancelled.
3. Same with `deleteSelectedCanvas()` on Beta: returns `false`, but selection moves to Alpha, history clears, epoch bumps, in-flight import cancels.

Observed (my probe build, private copy):

```
DIAG7 refused=nil selectedBeta=false selectedAlpha=true
DIAG7 undoBefore=1 undoAfter=0 epochBefore=2 epochAfter=3
DIAG5 refused=false selected=Alpha ... storeSelected=Alpha   (failed delete)
probe3: cancelled in-flight import = true; history 1→0; epoch 2→3
```

**Expected (per CVD-02, the implementation report §3.2, and the code's own comment):** a failed save changed nothing, so history, placement, selection, the native surface, and imports must survive. `renameSelectedCanvas` (`:541-549`) already shows the intended success-gated pattern.

**Actual:** because the gate is `succeeded || selectedCanvasID != previousCanvasID` (create `:534`, delete `:559`), the store's non-transactional selection move is read as a real board change. Consequence set for a *failed* operation: silent navigation to another (or the first) board, loss of undo/redo, surface rebuild, and image-import cancellation — the same CVD-01/RUN-001 symptom on an operation that changed nothing.

**Regression status:** for `createCanvas` this matches pre-edit behavior (pre-edit cleared unconditionally), so it is an **incomplete fix**, not a new regression. For `deleteSelectedCanvas` it is a **small regression**: pre-edit code cleared history only `if succeeded` (`/tmp/attic-batch1/pre/Attic/Canvas/CanvasSession.swift`), whereas the new `|| selectedCanvasID != id` clause clears it on save failure too.

**Suggested fix — validated end-to-end in my private copy (not applied to the shared tree)**

I implemented and tested the full remediation on `/tmp/deepseek-batch1-probe` (`dd3` build):

1. `CanvasSession.swift:534` → `let boardChanged = created != nil`; `:559` → run the reset block only `if succeeded` (matching `renameSelectedCanvas`).
2. `CanvasStoreBoards.swift`: capture the previous selection before `selectedCanvasID = id` (`:44`) and before the delete selection move (`:153-156`), and on `save()` failure restore it via a small helper (`selectedCanvasID = previous; refresh()` when the previous board is still live). This is required because the session gate alone cannot undo a selection the store already moved.
3. Regression test: failing `persist` during create/delete must preserve the selected board, history, placement parity, and epoch.

Validation results:
- Session gate alone: history, epoch, and import cancellation are fixed, but the silent board move **persists** (the store reports the new id) — so the store change is not optional.
- Session gate + store restore: all 7 of my probe classes pass (14 tests, the single residual failure is `probe3`, whose assertion deliberately checks for the *buggy* cancellation) and **80 existing tests pass with 0 failures** across `CanvasSessionTests`, `CanvasStoreTests`, `CanvasImageImportBatchTests`, the three new `CanvasDomainTests`, and `CanvasPerformanceGateTests`. Logs: `/tmp/deepseek-batch1-xctest/alt-gate.log`, `full-fix.log`, `full-fix-regress.log`.

**Why it is P1, not higher:** undo history is session-scoped and no persisted user data is lost; but the failure path is exactly the class CVD-02 was chartered to fix ("gate history reset and teardown on successful board operations", consolidated report Batch 1), it is deterministically reproducible, and it silently shows a different board.

### [P3] Report wording overstates refusal coverage (confidence: high, documentation-level)

`DeepAudit-Batch1-Implementation.md` §4.4 and the new test name both say **"Refused board operations"** keep history, and §3.2 says "A refused operation calls `synchronizeFromStore(clearHistory: false)`". That is true only for **validation refusals**. The audit finding is titled *"Failed Canvas select/create/delete work can erase undoability"*, and a save failure is a failed board operation. Either fix the code per the P1 finding or scope the report/test name explicitly to validation refusals.

---

## 2. Claims independently verified (all reproduced on my own build)

### 2.1 Snapshot and provenance (strongest part of the submission)

| Claim | Independent check | Result |
|---|---|---|
| HEAD `ae6418c…` unchanged, branch `codex/attic-task-panels-v2` | `git rev-parse HEAD` | EXACT |
| Status before 151 lines → after 153; only additions are the two new test files | line diff of `/tmp/attic-batch1/status-{before,after}.txt` | EXACT |
| Pre-edit reconstruction | `git archive HEAD` + `full-dirty-diff-before.patch` reproduces every one of the 11 owned snapshot hashes byte-for-byte | EXACT |
| `full-dirty-diff-before.patch` sha256 `f0e466…` | `shasum -a 256` | EXACT |
| `batch1-own.diff` sha256 `f565b4…`, 9 files, +333/−19 | `shasum`; `git apply --numstat` | EXACT |
| Full tree = pre-dirty + own diff, for all 65 tracked-modified files | applied both patches to a scratch `git archive HEAD` and compared all 65 | EXACT (0 mismatches) |
| Appendix diff identical to `batch1-own.diff` | line-level `difflib` over 513 hunk lines | 1.0000 similarity |
| `CanvasSurfaceMacHelpers.swift` reverted (pre hash == current) | hash + both helper patches `cmp` | EXACT |
| `AppCoordinator.swift` untouched | diff vs pre | EXACT |
| `AtticTests/CanvasSurfaceInteraction.swift` unchanged | hash | EXACT |

### 2.2 Builds and tests

| Claim | Independent check | Result |
|---|---|---|
| `TEST BUILD SUCCEEDED` on final tree, `Local`, `ATTIC_LOCAL_ONLY` | my fresh build into `/tmp/deepseek-batch1-build/dd`; verified `-DATTIC_LOCAL_ONLY` and `atticesUnitTestHost` alias in the compile command | CONFIRMED |
| App build succeeds, bundle id `com.taha.Attic`, not launched | my `Attic.app` build; PlistBuddy | CONFIRMED |
| 805 tests / 4 skips / 0 failures | my own windowless host run: `Executed 805 tests, with 4 tests skipped and 0 failures`, `exit_status=0` | CONFIRMED |
| 805 = 799 + 6 new, same class list as PERF-A1 | set-diff of every `AtticTests.*` test name between `perfa1-fixes-full-unit.log` and mine: exactly the six new tests added, none removed; 42 classes match every declared `XCTestCase` in `AtticTests/` | CONFIRMED |
| Mutant run: 5 tests, 40 failures, per-test 16/9/6/4/5 | my own mutant copy (scroll+pinch guards disabled, deinit cancellation restored, interruption bumps epoch, create always resets) → `Executed 5 tests, with 40 failures`, exactly 16/9/6/4/5 | CONFIRMED |
| PERF-A1 gates intact | my run: `Canvas decode stress: 96 images in 0.073s, max active 4`; `PERFGATE toggle=9.31 snapshot=36.97 lookup=0.0040` (threshold median < 120 ms) | CONFIRMED (values differ run-to-run, well inside gates) |
| Bundle hash differences vs Opus's log | my fresh build: host `2287db13…` identical; test bundle differs (`6cea98…` vs `43f7a7…`) because Swift debug info embeds the DerivedData path — expected | NOTED, not a discrepancy |
| Warning claim "no Swift warnings; only appintents" | final incremental build has exactly the appintents warning; the full build also carries two test-only warnings that **pre-date Batch 1** (`TaskStoreTests.swift:257` "code after throw", `PanelGeometryTests.swift:291` deprecation) | CONFIRMED with nuance |

### 2.3 Behavior (my own probes, private copies only)

New probes I wrote and ran on my fresh build (all in `/tmp/deepseek-batch1-probe`, never in the shared tree):

- Fresh phased scroll during image move → preview and delivery preserved: **pass**.
- Fresh phased scroll during shape drag → preview preserved, no viewport delivery: **pass**.
- Standalone wheel tick during image move → preserved: **pass**.
- Pinch began/changed during image move → ignored, viewport unchanged: **pass**.
- Scroll during eraser drag → `.erasing` retained, no pan: **pass**.
- The same image/shape probes **fail** on the mutant build → they discriminate the guard.
- `createCanvas` save-failure: history/selection/epoch — **fail on the fixed tree** (the P1 finding).
- `deleteSelectedCanvas` save-failure incl. cancellation-aware preparer: **fail on the fixed tree** (the P1 finding).

### 2.4 Requested specific coverage checks

- **Failure/rollback:** store-level rollback tests are extensive and untouched (`CanvasStoreTests`); the *session-level* gate on save failure is the uncovered case (the P1 finding). Store rollback leaves the selection moved — mechanism traced in §1.
- **Import completion:** `testSessionImportSurvivesTransientInterruptionAndSurfaceDismantle` genuinely survives a real `dismantleNSView` plus interruption with 2 gated images and 0 cancellations; `testBoardLifecycleCancellationStillCancelsSessionImports` genuinely cancels on create and on lifecycle cancellation and persists no rows. Both reproduce on my build; both fail on my mutant with the claimed failure counts. Escape/import-HUD cancellation paths remain wired (`CanvasSurfaceMac.swift:88-90, 1171-1174`, `CanvasPanelContent.swift:866-873`).
- **Viewport takeover:** every unguarded entry path in the audit (`scrollWheel` direct-began/catch-all, magnification `.began`/`.changed`/`.possible`) now passes through the active-pointer guard, and the guard itself covers ink/erase, pan, shape, image move/resize (`CanvasSurfaceMacHelpers.swift:756-763`). The prior "already-active viewport gesture" and pointer-down-takeover rules are unchanged and their regression tests pass.

---

## 3. Code reasoning vs. executed evidence

- **Executed here:** all my own builds, the focused runs, the full 805-test run, the mutant run, the image/shape/erase/pinch probes, and the save-failure probes. Logs under `/tmp/deepseek-batch1-xctest/` and `/tmp/deepseek-batch1-build/`.
- **Inspected only (Opus logs, not re-run):** `batch1-focused.log` history note (the two mis-prefixed IDs did not run in its focus set — their test names contain the wrong class prefix; both live in `CanvasDomainTests` and passed in the full suite, which I re-ran myself).
- **Read-only reasoning, not executed:** the store-side root cause of the P1 finding (`CanvasStoreBoards` ordering and rollback-reload interaction). The reproducer itself is executed evidence; the attribution to the store's selection-before-save ordering is code reasoning, supported by the printed `storeSelected=Alpha` diagnostic.
- **Not performed at all:** live app launch, physical trackpad/mouse input, real SwiftUI identity/dismantle timing, real file-promise providers, CloudKit/APNs/iPhone/TestFlight. No native pass is inferred from compilation or tests.

---

## 4. Test-quality assessment

The six new tests are meaningful, not tautological:

- They fail under a faithful mutant (my independent mutant reproduces the exact per-test failure profile), and they do not merely exercise the harness they were written in.
- `testTransientInterruptionReachesLiveSurfaceWithoutRebuildingIt` covers the text-editor commit policy, live-surface ink discard, epoch stability, observation teardown, and lifecycle rebuild in one flow; the `MainActor.assumeIsolated` sink is safe because the subject is sent only from main-actor session code.
- Residual test-design notes (non-blocking): the import-survival test asserts `cancellations == 0` on a gated preparer whose cancellation only runs if the task is cancelled — correct, but a stronger variant would also assert the two items land on the **captured** board, which the existing page-switch test already covers separately. The refused-operations test is correctly scoped to validations but is named/worded as if it covered all refusals (see P3).

---

## 5. Resource coordination and method integrity

- The SWE test-verifier thread `agent-bdf8c2a2c3b70e9e9050f2de282e3fac` was checked for **status only** (per instruction). It was observed terminal (`idle`/`completed`) before I launched any build or test host. No shared build output or log names were used; I built into `/tmp/deepseek-batch1-build`, `/tmp/deepseek-batch1-mutant` (my own), and `/tmp/deepseek-batch1-probe`, and ran through a private `xctestconfiguration` set in `/tmp/deepseek-batch1-xctest` using the existing runner binary (`/tmp/attic-offline-xctest/run.zsh` logic) without editing it.
- **Disclosure:** a status-only read returned a truncated preview of that thread's final assistant message. I did not read its report, transcript, or findings, and this review's verdict is independently derived and **disagrees** with the preview's `REVIEW_PASS`. The blind property is preserved in substance; the incidental exposure is recorded here for completeness.
- No source edits in the shared checkout; `git status` stayed at 154 lines with only `Docs/DeepAudit-Batch1-Implementation.md` untracked plus my own report added at the end. No user data store was opened (in-memory/synthetic only).
- Dedicated idle waiting: 0 min. Elapsed from first status check (09:19 UTC) to host launch (10:05 UTC) was spent on source/provenance review, not waiting.

## 6. Limits

- No physical-input or live-panel evidence: phase ordering from real trackpads, SwiftUI teardown timing during real hide/section changes, and real promise providers remain unverified (matching the report's own §5.6/§7).
- The P1 finding is proven with an injected persistence failure, which is the only deterministic way to reach that path in the windowless host; whether a real disk/permission failure behaves identically is inferred from the same `save()` code path, not observed live.
- Section-change cache churn (RUN-002 magnitude) remains unmeasured, as the report states.

**REVIEW_PASS or CHANGES_REQUIRED: CHANGES_REQUIRED** — fix the save-failure gate (and add its regression test), then the batch's remaining evidence stands as reviewed.
