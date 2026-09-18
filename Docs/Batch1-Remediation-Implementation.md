# Batch 1 Reviewer Remediation — Implementation Record

**Status: IMPLEMENTATION_READY** (unit and integration evidence only). **Native evidence (physical input, live panel) is still PENDING.** Nothing was launched, and nothing was committed, pushed, or released.

- **Branch / HEAD:** `codex/attic-task-panels-v2` at `ae6418c1af690e29d15a20344cdb9765a23d3f85`, with an inherited dirty tree on top (Batch 1 and earlier work). Built bundle ID `com.taha.Attic` (not launched).
- **Inputs read:**
  - `Docs/Batch1-Reviewer-Comparison.md`
  - `Docs/Batch1-Counterexample-Validation.md`
  - `Docs/Batch1-DeepSeek-Verification-Review.md`
  - `Docs/Batch1-SWE-Interaction-Review.md`
  - `Docs/DeepAudit-Batch1-Implementation.md`
  - `AGENTS.md`
- **Scope:**
  1. **P1:** failed create/delete persistence rollback.
  2. **Low:** a foreign scroll or pinch tail resumes after cancellation.
  3. **Doc correction:** validation-refusal coverage versus injected-persistence-failure coverage.
- **Not touched:**
  - the setup worker's mini-SWE tooling and `Docs/MiniSWE-Setup-Smoke.md`, which appeared during this work;
  - the backlog and UI;
  - `CanvasSession.swift` and `CanvasSurfaceMacHelpers.swift`;
  - the project inputs (no files added, no regeneration needed).

## 1. Baseline (captured before any edit)

All private artifacts are in `/tmp/attic-b1rem/`.

| Item | Value |
|---|---|
| Dirty status | `status-before.txt` (`git status --porcelain --untracked-files=all`) |
| Full inherited dirty diff | `full-dirty-diff-before.patch`, sha256 `37379733aeb10a873b4ea616b2b95bf25fa97aef84cae641f73ace7d26f75389` (67 files, +10096/−3076) |
| Hashes of every modified/untracked file | `all-hashes-before.txt` |
| Pre-edit copies of owned files | `baseline/` (HEAD plus the inherited patch; the untracked audit doc was reconstructed). Every hash matches `all-hashes-before.txt`. `CanvasStoreBoards.swift` was clean at HEAD. |

Pre-edit sha256 of the owned files:

| File | sha256 before |
|---|---|
| `Attic/Services/CanvasStoreBoards.swift` | `5679b9c8c5a510aed6c442bfd378898f541ab0dacd98c927d22b5c19f2c88970` |
| `Attic/Services/CanvasStorePersistence.swift` | `ad3301ecc210b53f49ecb433ead63edaf053cc9ed2bda90f1392e0e0e83a85f3` |
| `Attic/Canvas/CanvasSurfaceMac.swift` | `e1d4187626d45f8280f12ac21a89b68ce307d63143467b5bd2831a6f6e34f602` |
| `AtticTests/CanvasDomainTests.swift` | `4977c9fecc37863a32e42268baea06f77d389d6b9dfc1cefdccd031dce6e05e7` |
| `AtticTests/CanvasStoreTests.swift` | `30690cba35b878816c66d124fb6f66a5f9a8154a7c01b6e293f028b29664de72` |
| `AtticTests/CanvasImageTests.swift` | `6395e9d374d01d450b0472d8305683f8ff56e8495f0bd6847698e838cfed2bba` |
| `Docs/DeepAudit-Batch1-Implementation.md` | `1dcf7180738593fc704f5354ead5ca02b7d9f3804675658d5594a795d9773db7` |

**After the run.** A hash comparison against `all-hashes-before.txt` shows that only the owned files changed. The only new entries in `git status` are the owned `CanvasStoreBoards.swift`, this document, and the setup worker's `Docs/MiniSWE-Setup-Smoke.md` (not mine).

## 2. Hypotheses and discriminating evidence

The tests were written first (copies in `/tmp/attic-b1rem/tests-first/`; the final test files are byte-identical to them). They were built against the **unfixed** source.

**Before run** — log `/tmp/attic-b1rem/xctest/before-new-tests.log`, host debug dylib `4839c859…`: `Executed 6 tests, with 37 failures`, `exit_status=1`.

| Test | Before | After |
|---|---|---|
| `CanvasStoreTests/testFailedCreateAndDeleteSavesRestorePreviousSelectionAndKeepSaveError` | 4 failures | pass |
| `CanvasStoreTests/testFailedBoardSaveFallsBackWhenPreviousSelectionIsNoLongerLive` | pass (preservation) | pass |
| `CanvasImageImportBatchTests/testFailedBoardSavesKeepSelectionHistoryEpochAndSessionImports` | 14 failures | pass |
| `CanvasImageImportBatchTests/testFailedBoardSaveThatLosesItsBoardStillClearsStaleHistoryAndImports` | pass (preservation) | pass |
| `CanvasDomainTests/testCancellationKeepsIncidentalScrollTailSuppressedUntilItsSequenceEnds` | 11 failures | pass |
| `CanvasDomainTests/testCancellationKeepsIncidentalPinchTailSuppressedUntilANewPinch` | 8 failures | pass |

### P1 — failed create/delete save silently changes board (confirmed)

**Cause.**

1. `CanvasStore.createCanvas` sets `selectedCanvasID = id`, and `deleteCanvas` moves the selection off the deleted board. Both do this **before** `save()`.
2. When the save fails, `save()` calls `context.rollback()` and then `reloadCanvas()`.
3. Presentation resolution finds the requested ID not live: the rolled-back new board, or a board that is still live but no longer selected. It falls back to the first live board.
4. `CanvasSession` then sees `store.selectedCanvasID != previous` and correctly treats it as a board change.

**Unfixed behavior**, observed with `PersistenceGate.shouldFail` on Alpha/Beta with Beta selected:

- The store selected Alpha and showed Alpha's empty strokes.
- The session changed as follows:
  - undo count went from 2 to 0 and `canUndo` became false;
  - the epoch went 2 → 3 → 4;
  - `selectedImageID` and the pending text placement were cleared;
  - the in-flight session import was cancelled (count 1) and its image never landed.

**Discriminating fixtures:**

- The injected failure is `PersistenceGate` (a real `persist` throw), not a validation refusal.
- Imports use `ControlledCanvasImagePreparer`, which is cancellation-aware (`waitUntilStarted`, `release`, `cancellationCount`).
- The error is asserted **exactly**:
  - store: `PersistenceGate.Failure().localizedDescription`;
  - session: `CanvasSession.compactErrorMessage` of the same message.

### Low — cancellation releases a foreign scroll/pinch tail (confirmed)

**Cause.**

1. The CVD-05 guards set `suppressesScrollSequence` / `suppressesMagnification` while a pointer interaction owns input.
2. `cancelInteraction()`, used by transient interruption and Escape, called `resetViewportGestureRouting(suppressScroll: interruptedScroll, suppressMagnification: interruptedMagnification)`. That unconditionally **overwrote** both flags with `false`, because no viewport gesture was active.
3. With the flags cleared, the tail of the foreign sequence reached the catch-all delta path and the `.changed` path.

**Unfixed behavior.**

- **Scroll:** after ink, then phase 1, then `cancelInteraction()`, the direct-changed, Command-changed, ended, and momentum tail began a pan. The viewport moved (`y` −21) with 5 deliveries.
- **Pinch:** after ink, then began/changed, then cancel, the changed/ended tail zoomed to 1.5125.

## 3. Fixes

### 3.1 Store: transactional selection restore on failed save

- `save(restoringSelectionOnFailure previousSelection: UUID? = nil)`:
  - Both failure paths (presentation preparation and `persist`) now call `rollBackFailedSave(restoringSelection:)`. That helper runs `context.rollback()` and then reinstates `previousSelection` **before** the failure `reloadCanvas()`.
  - The original error-message construction is unchanged, including the `saveError · warning` and `Reload failed` forms. `refresh()` is not used because it would overwrite `lastErrorMessage`.
- `createCanvas` and `deleteCanvas` capture `previousSelection` before mutating and pass it through. All other `save()` callers keep the default `nil`, so their behavior is unchanged.
- **Defensive fallback retained.** If the previous board is no longer live (for example, tombstoned by another context), normal resolution still falls back to the first live board.
- The `deleteCanvas` pre-save `catch` path (`discardPendingChanges`) is unchanged. Its last throwing call (`tombstoneAllContent`) runs before the selection mutation, so that path cannot observe a moved selection.

### 3.2 Session guards: deliberately unchanged

`CanvasSession.createCanvas` (`created != nil || store.selectedCanvasID != previousCanvasID`) and `deleteSelectedCanvas` (`succeeded || selectedCanvasID != id`) are kept.

**Mutant proof.**

- **Setup:**
  - private copy `/tmp/attic-b1rem-mutant` with both guards narrowed to success-only (patch `/tmp/attic-b1rem/mutant-narrow-guards.patch`);
  - the store and view fixes are present;
  - built into `/tmp/attic-b1rem-mutant-dd` (host debug dylib `0d7e5807…`).
- **Result:** log `/tmp/attic-b1rem/xctest/mutant-narrow-guards.log`: `Executed 8 tests, with 8 failures`, `exit_status=1`.
  - All 8 failures are in `testFailedBoardSaveThatLosesItsBoardStillClearsStaleHistoryAndImports`, for both create and delete: undo count 1≠0, `canUndo`, epoch 2≠3, and import not cancelled.
  - The other 7 tests passed, including the validation-refusal and lifecycle-cancellation tests.
- **Conclusion:** narrowing the guards would keep old-board history and imports on a different board.

### 3.3 View: keep foreign suppression across cancellation

`CanvasNSView.cancelInteraction()` now resets routing with `suppressScroll: interruptedScroll || suppressesScrollSequence` and `suppressMagnification: interruptedMagnification || suppressesMagnification`.

The existing boundaries still release suppression:

- **Scroll:**
  - `directBegan` (a new sequence takes over even with no terminal event);
  - momentum end;
  - a standalone wheel tick once no pointer interaction is active.
- **Pinch:** `.began` (a new pinch), `.ended`, `.cancelled`, `.failed`.

A sequence whose tail was lost stays suppressed only until the next such event. This is the same behavior as the uncancelled CVD-05 path.

### 3.4 Owned diff (source)

Separate from inherited dirty work; full patch `/tmp/attic-b1rem/owned/owned-source.patch`.

```diff
--- a/Attic/Services/CanvasStoreBoards.swift
+++ b/Attic/Services/CanvasStoreBoards.swift
@@ createCanvas
+        let previousSelection = selectedCanvasID
         context.insert(CanvasBoardItem(
@@
         selectedCanvasID = id
-        guard save().succeeded else { return nil }
+        guard save(restoringSelectionOnFailure: previousSelection).succeeded else { return nil }
@@ deleteCanvas
+        let previousSelection = selectedCanvasID
         do {
@@
-        return save().succeeded
+        return save(restoringSelectionOnFailure: previousSelection).succeeded
--- a/Attic/Services/CanvasStorePersistence.swift
+++ b/Attic/Services/CanvasStorePersistence.swift
-    func save() -> CanvasSaveOutcome {
+    func save(restoringSelectionOnFailure previousSelection: UUID? = nil) -> CanvasSaveOutcome {
@@ preparation failure and persist failure (both)
-            context.rollback()
+            rollBackFailedSave(restoringSelection: previousSelection)
@@
+    private func rollBackFailedSave(restoringSelection previousSelection: UUID?) {
+        context.rollback()
+        if let previousSelection, selectedCanvasID != previousSelection {
+            selectedCanvasID = previousSelection
+        }
+    }
--- a/Attic/Canvas/CanvasSurfaceMac.swift
+++ b/Attic/Canvas/CanvasSurfaceMac.swift
@@ cancelInteraction()
         resetViewportGestureRouting(
-            suppressScroll: interruptedScroll,
-            suppressMagnification: interruptedMagnification
+            suppressScroll: interruptedScroll || suppressesScrollSequence,
+            suppressMagnification: interruptedMagnification || suppressesMagnification
         )
```

A doc comment and an inline comment are also added (see the patch).

**Owned test diff:** `/tmp/attic-b1rem/owned/owned-tests.patch`, +280 lines and no deletions. Only new tests were added; no existing test was weakened (`testIncidentalPinchCannotDiscardBufferedInk` gained one strengthening assertion, which cannot produce a false pass).

**Owned doc diff:** `/tmp/attic-b1rem/owned/owned-docs.patch`.

## 4. New tests (what each proves)

| Test | Proves |
|---|---|
| **Store:** `testFailedCreateAndDeleteSavesRestorePreviousSelectionAndKeepSaveError` | With Alpha/Beta, Beta selected, and a stroke on Beta, a failed create returns nil and a failed delete of Beta returns false. Both keep the Beta selection, `[alpha, beta]`, and the stroke, and set `lastErrorMessage` to exactly the save error. Persisted rows are not tombstoned. |
| **Store:** `testFailedBoardSaveFallsBackWhenPreviousSelectionIsNoLongerLive` | For create and delete, when another context tombstones Beta before the failing save, the store falls back to Alpha, `canvases == [alpha]`, and the error is exactly the save error. |
| **Session:** `testFailedBoardSavesKeepSelectionHistoryEpochAndSessionImports` | Failed create and failed delete each keep the board, canvases, strokes, undo count, `canUndo`, epoch, compact error, selected image, and pending text placement. The in-flight import is not cancelled and lands on Beta once released. Undo stays bounded and fully works. A later successful create bumps the epoch by exactly 1 and clears history and placement. |
| **Session:** `testFailedBoardSaveThatLosesItsBoardStillClearsStaleHistoryAndImports` | For create and delete, if the failed save lands on a different board (Beta was tombstoned externally), history is cleared, the epoch bumps exactly once, and the in-flight import is cancelled. This guards against narrowing the session guards. |
| **View:** `testCancellationKeepsIncidentalScrollTailSuppressedUntilItsSequenceEnds` | **Segment 1:** ink, then phase-1 scroll, then `cancelInteraction()`. The tail (changed, Command-changed, ended, momentum begin/continue) is ignored with no active gesture, no delivery, and an unchanged viewport. Momentum end releases suppression, and a new sequence pans. **Segment 2:** `interruptTransientInteraction()` mid-sequence. The tail is ignored, and a new `began` with no terminal event takes over and pans. |
| **View:** `testCancellationKeepsIncidentalPinchTailSuppressedUntilANewPinch` | **Segment 1:** ink, then pinch began/changed, then `cancelInteraction()`. The changed tail is ignored and `.ended` releases suppression. A new pinch zooms to 1.25. **Segment 2:** transient interruption, then the tail is ignored. A new `.began` zooms to 1.5. |

## 5. Verification

**Environment:**

- private DerivedData `/tmp/attic-b1rem-dd`;
- `Local` configuration (`ATTIC_LOCAL_ONLY`), `CODE_SIGNING_ALLOWED=NO`;
- tests run through `/tmp/attic-b1rem/xctest/run.zsh`, an offline XCTest injection into the windowless `AtticUnitTestHost`;
- in-memory or synthetic stores only, no UI launch.

| Gate | Result | Log |
|---|---|---|
| `xcodebuild build-for-testing … -derivedDataPath /tmp/attic-b1rem-dd -only-testing:AtticTests` (unfixed, tests first) | `** TEST BUILD SUCCEEDED **` | `/tmp/attic-b1rem/build-before.log` |
| Same command, after the fix | `** TEST BUILD SUCCEEDED **`; no Swift warnings | `/tmp/attic-b1rem/build-after.log` |
| `xcodebuild build … -destination 'platform=macOS'` | `** BUILD SUCCEEDED **`; `Attic.app` bundle ID `com.taha.Attic`, **not launched** | `/tmp/attic-b1rem/build-app-after.log` |
| 6 new tests, unfixed source | 37 failures, `exit_status=1` | `/tmp/attic-b1rem/xctest/before-new-tests.log` |
| 6 new tests, fixed source (host debug dylib `d05b4a67…`) | 0 failures, `exit_status=0` | `/tmp/attic-b1rem/xctest/after-new-tests.log` |
| Focused: all of `CanvasStoreTests`, `CanvasSessionTests`, `CanvasDomainTests`, `CanvasImageImportBatchTests` | 107 tests, 0 failures | `/tmp/attic-b1rem/xctest/after-focused.log` |
| Full unit suite (the same 42-class list as `batch1-full-unit-2`; it matches every `XCTestCase` class declared in `AtticTests/`) | **811 tests, 4 skipped, 0 failures** (805 + 6 new) | `/tmp/attic-b1rem/xctest/after-full-unit.log` |
| Guard-narrowing mutant | 8 failures, all in the lost-board test | `/tmp/attic-b1rem/xctest/mutant-narrow-guards.log` |
| `git diff --check` on the owned tracked files | clean | — |

**Notes on the focused and full runs:**

- The focused run covers the existing related tests:
  - `testRefusedBoardOperationsKeepHistoryPlacementAndSurface`
  - `testBoardLifecycleCancellationStillCancelsSessionImports`
  - `testSessionImportSurvivesTransientInterruptionAndSurfaceDismantle`
  - `testIncidentalScroll…` / `testIncidentalPinch…`
  - `testCancelledMagnificationTailCannotRestartUntilNewBegan`
  - `testNewPinchTakesOverScrollWithoutTerminalEventAndIgnoresMomentumTail`
  - `testInterruptedScrollMomentum*`
  - `testFocusLossCancellationCannotCancelANewerViewportGesture`
  - `testCommandScrollUsesReentrantCanvasZoomPath`
  - `testTrackpad*`
- In the full run, the performance gates passed: `Canvas decode stress: 96 images in 0.075s, max active 4`; `PERFGATE toggle=9.17 snapshot=34.56 lookup=0.0039`.

## 6. Documentation corrections

In `Docs/DeepAudit-Batch1-Implementation.md`, marked *Remediation correction*:

- **Scope list and H2:** the original CVD-02 reproductions and coverage were **validation refusals** that never reach `save()`. Injected persistence failure was not covered.
- **§3.2:** "A refused operation calls `synchronizeFromStore(clearHistory: false)`" is now qualified. It held only for validation refusals; a failed create/delete save had already moved the selection.
- **§3.3:** "a pinch that outlives the stroke stays ignored until its next `.began`" held only when no cancellation intervened.
- **§4.2 table:** `testRefusedBoardOperationsKeepHistoryPlacementAndSurface` is now labelled validation refusals only. The §4.3 mutant row is labelled likewise.
- **§5.4:** CVD-02 was not complete for injected persistence failures; this record now covers it.

No test was renamed.

## 7. Unresolved risks and limitations

1. **No native evidence.**
   - Scroll and pinch evidence uses synthetic CGEvent phases and a driven `NSMagnificationGestureRecognizer`. Real trackpad phase and momentum ordering, including a sequence whose terminal event goes to another view after cancellation, is unverified.
   - Handoff: in a uniquely named local-only preview, start a stroke, begin a two-finger scroll or pinch, press Escape or trigger a transient interruption while the fingers are still moving, and confirm the viewport does not move until a new gesture begins.
2. **Stale suppression after a lost terminal event.** If a suppressed sequence's terminal event never arrives, suppression lasts until the next `directBegan`, standalone wheel tick, or pinch `.began`/`.ended`. A real new gesture always starts with one of these, so no stuck state is expected, but it is not natively verified. The same was already true on the uncancelled CVD-05 path.
3. **Restoring the selection publishes it twice.** `selectedCanvasID` is `@Published`. A failed create/delete publishes the provisional ID and then the restored ID within one synchronous main-actor call, before the session synchronizes. No `$selectedCanvasID` subscriber exists in `Attic/`, and SwiftUI coalesces `objectWillChange`. Avoiding the provisional publication would need a larger change to presentation resolution (outside the bounded scope).
4. **Preparation-failure path — now covered.** The `resolveCanvasPresentation` preparation-failure path gets the same restore, and it is now driven by tests: `testFailedPreparationOnCreateCanvasRestoresPreviousSelectionAndKeepsPreparationError` and `testFailedPreparationOnDeleteCanvasRestoresPreviousSelectionAndKeepsPreparationError` in `AtticTests/CanvasStoreTests.swift`, using the existing injectable `loadReplicas` closure on `CanvasStore.init`. No production change was required; `CanvasStorePersistence.swift` is byte-identical to the reviewed snapshot. With the restore removed, both tests fail on selection and strokes.
5. **Deferred iOS.** The iOS advisory (O-1: iOS transient callers still use lifecycle cancellation) is unchanged and out of scope. No CloudKit, APNs, or iPhone claim is made.
6. **Other workers.** The setup worker's `Docs/MiniSWE-Setup-Smoke.md` and tooling appeared during this work. They were not read, edited, or validated.

## 8. Review snapshot

The immutable snapshot is outside the repository, read-only, with no `.git`. Its path and manifest are recorded in `/tmp/attic-b1rem/SNAPSHOT_LOCATION.txt` and in the final report. It contains:

- `worktree/`: every modified and untracked file from `git status --porcelain --untracked-files=all`, at post-fix content. Overlay it on a checkout of `ae6418c` to reproduce.
- `baseline/`: pre-edit owned files.
- `patches/`:
  - the inherited before-patch;
  - the full after-diff of tracked files;
  - the owned source, test, and doc patches;
  - the mutant patch.
- `logs/`: build logs, xctest logs, configurations, and `run.zsh`/`makeconfig`.
- `status-before.txt` / `status-after.txt`, `all-hashes-before.txt`, `tests-first/`.
- `MANIFEST.sha256`: covers every file in the snapshot.
