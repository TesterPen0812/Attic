# Batch 2 Review — R5 (GLM): cross-batch integration, fix interactions, claim consistency

**Date:** 2026-09-15
**Reviewer:** R5 (independent; different model family from other reviewers; no coordination, no other reviewer reports read)
**Assignment:** cross-batch integration, interaction between fixes, claim consistency
**Verdict: REVIEW_PASS** (no confirmed defects; one minor documentation-accuracy note; native UAT remains an open gate, unchanged from the implementation record's own limitation list)

## 1. Inputs and reconstruction

- Snapshot `/tmp/attic-b2-snapshot-20260915T1845Z` verified before use:
  `shasum -a 256 -c MANIFEST.sha256` → 598 entries OK, 0 failures, 0 mismatches.
  `MANIFEST.sha256` file hash measured `9af3fc17a070842e7ce8a4975cd66efa7b4ce5a3b297b79bfd5371a5380ca339` — matches the frozen expectation.
- Private reconstruction: `git archive ae6418c1af690e29d15a20344cdb9765a23d3f85` into `/tmp/attic-b2-review-r5`, then overlaid `worktree/` from the snapshot. Committed privately (`e12e9c5`) so the reviewed content is pinned. The live checkout and the snapshot were never modified; all builds used private DerivedData (`/tmp/attic-b2-r5-dd`, `/tmp/attic-b2-r5-mut-dd`).
- Live repo HEAD confirmed `ae6418c1af690e29d15a20344cdb9765a23d3f85` on `codex/attic-task-panels-v2`, nothing committed.

## 2. Whole-diff discipline (re-measured, not trusted)

- All 330 paths in `baseline/all-hashes-before.txt` were re-hashed against the snapshot `worktree/`: exactly 6 changed — `CanvasImageTypes.swift`, `CanvasSession.swift`, `CanvasSurfaceMac.swift`, `CanvasPanelContent.swift`, `CanvasDomainTests.swift`, `CanvasSessionTests.swift` — all six are Batch 2-owned and were already dirty at baseline. The other 324 inherited paths are byte-identical; 0 missing.
- Post-fix SHA-256 of all 9 owned files re-measured in the reconstruction; all 9 match the implementation record's table exactly (e.g. `CanvasSession.swift` `c268412d…`, `CanvasSurfaceRenderer.swift` `48c81ecf…`).
- Baseline→final owned diff independently measured: **+524/−27 across exactly the 9 owned files** — matches the record's `batch2-owned.patch` diffstat claim. Per-file: CanvasEditCommandRoute +11/−5, CanvasImageTypes +1/−1, CanvasSession +18/−10, CanvasSurfaceMac +1/−1, CanvasSurfaceRenderer +10/−4, CanvasPanelContent +18/−6, CanvasDomainTests +272/0, CanvasRenderCacheTests +89/0, CanvasSessionTests +104/0.
- `diff baseline/status-before.txt status-after.txt` adds exactly: 3 owned clean files (`CanvasEditCommandRoute.swift`, `CanvasSurfaceRenderer.swift`, `CanvasRenderCacheTests.swift`), the Batch 2 report itself, and `Docs/Native-Verification-Playbook.md` (untracked, another actor, consistent with the record's disclosure).
- No earlier work was reverted or duplicated: the 6 already-dirty owned files carry Batch 1's changes intact (verified by reading the HEAD→baseline diff for `CanvasSession.swift` and `CanvasSurfaceMac.swift`; Batch 1's history-byte-budget, `interactionInterruptions`, `fit(in:excluding:)`, and CVD-02 selection changes are all present and untouched by Batch 2's hunks, which do not overlap them).

## 3. Fix-by-fix interaction analysis (the assigned surface)

### 3.1 CVD-03 × CVD-04 (retry fan-out vs decode cache/cancellation) — coherent

The two fixes split one pipeline at two layers and do not cancel each other:

- Session side (`CanvasSession.swift:374-388`): `retryFailedImageDecodes()` now sends `Set(images.map(\.id)).intersection(failedImageIDs)`; `retryImageDecode(_:)` wraps a single ID into the same set-typed request. The request type (`CanvasImageTypes.swift:3-6`) carries `imageIDs: Set<UUID>` + a fresh `attemptID`, so each request is consumed once (`view.lastDecodeRetryRequest != request` guard, `CanvasSurfaceMac.swift:151-157`).
- Bridge side (`CanvasSurfaceMac.swift:154-156`): fans the set out over `view.images`, which holds **all** placed images (not just candidates), so off-screen failures in the set do reach `retryDecode(for:)`. The off-screen view test (`CanvasDomainTests.swift:1101`) proves this end-to-end with the off-screen image at x=3000 outside the candidate set (`CanvasImageDecodeCandidatePolicy`, margin 192 view-points).
- Cache side (`CanvasSurfaceRenderer.swift`): `retryKeys` survives `prepare`'s candidate pruning (line 142), exempts retry keys from active-cancel (line 144), and `finishDecode` keeps a non-visible retried result via the `retried` term (lines 282, 291-293). `removeAll()` still clears `retryKeys` (line 191), so board-switch teardown (`CanvasSurfaceMac.swift:445`) and page/lifecycle cancellation remain total.
- Boundedness holds: a key enters `retryKeys` only from the bounded failure memo, leaves on `finishDecode` or `removeAll()`, and `rebuildQueueOrder` still ranks visible candidates first. Worker concurrency is untouched. No new retention path found: a retry key cannot outlive its attempt (`finishDecode` removes it first, before any early return).

Negative control I ran that the implementation record did **not** include: reverting the **bridge** fan-out (`CanvasSurfaceMac.swift:154`) to `first(where:)` while leaving the session fix intact. Result: `testRetryFailedImageDecodesRequeuesEveryVisibleFailure` and `testRetryFailedImageDecodesRequeuesOffScreenFailure` fail (3 assertion failures, exit 1), while the cache unit test still passes — the exact mirror of the record's session-side mutant M1. This proves both halves of the CVD-03/CVD-04 pipeline are load-bearing and discriminated by the view tests, and that the bridge fan-out is not redundant with the session fix.

### 3.2 CVD-08 × CVX-06 (text refit vs keyboard minimum) — compose correctly

- `resizeSelectedSemanticObject(by:)` (`CanvasSession.swift:1353-1358`) now floors at `CanvasImagePlacement.minimumDimension` (48, `CanvasImageTypes.swift:439`), matching `resizedTransform`'s floor, then delegates to `transformSemanticObject`, which applies the CVD-08 refit for text. Composition is correct: floor first, then `max(proposed, textSize.height)`, and `textSize` itself never returns below 48 (`CanvasSemanticRenderer.swift:62`), so the two floors cannot fight.
- The refit reuses `CanvasSemanticRenderer.textSize(content, width:)` — the same function `editSemanticObject` uses (line 1324) — and shifts `center.y` by half the growth with the identical formula `editSemanticObject` uses (line 1327). The resize path therefore cannot disagree with the edit path about what "fits" means; both anchor the same edge (tests assert `worldRect.minX/minY` preserved, `CanvasSessionTests.swift:294-295`, `CanvasDomainTests.swift:1301-1302`).
- Trigger condition is correctly guarded: pure moves (`movedTransform` keeps width/height) and z-order changes do not trigger the refit (width/height unchanged); shapes cannot misfire because `CanvasSemanticContent.isValid` enforces text XOR shape and `CanvasSemanticObject.init(_:)` drops invalid payloads on decode, so `content.text != nil` implies a text object.
- The refit-back-to-current no-op case (proposed height below fit at unchanged width) correctly returns `false` and records nothing — asserted by the squash negative control (`CanvasSessionTests.swift:313-318`).
- Undo records the refitted `after` (read back from the store, line 1302-1305), so undo/redo restore exact transforms — asserted in both narrowing tests. Batch 1's byte-budget history accounting (`HistoryEntry.cost` for `.changeSemantic`) handles the refitted payload without changes; no interaction defect.

Known limitations here are accurately documented in the record (§6.2 top-edge anchoring on top-handle drags, §6.3 drag preview still clips, §6.4 grow-only, §6.5 legacy clipped objects). I verified each against the code: the refit runs only in `transformSemanticObject` (commit path), the drag preview (`previewImageTransform`, `CanvasSurfaceMac.swift:819`) is unrefitted by design, and undo/redo restore via `.changeSemantic` snapshots without refit.

### 3.3 CVD-06 × session lifecycle/history — coherent, with one honest residual

- Toolbar (`CanvasPanelContent.swift:366-373`) and Add ▸ Edit menu (lines 477-485) route through `CanvasEditCommandRoute.undo/redo(session:section:)`; disabled state is `session.canX || route.canX(...)` (lines 28-35). I grepped all view/app/window call sites: no `session.undo()/redo()` callers remain outside the route (the only remaining direct undo references are comments/labels).
- The route's fallback is `session.undo()/redo()`, which now runs through Batch 1's `HistoryEntry` byte accounting — no conflict; the route adds no history manipulation of its own.
- The `focusedResponder` seam (tests-first patch) defaults to `{ NSApp.keyWindow?.firstResponder }` — byte-identical expression to the five previous inline lookups — and the fix-only patch does not touch it. Behavior-neutral seam confirmed.
- The session term in the disabled state is deliberate and correct: typing in the AppKit editor does not republish `CanvasSession`, so a route-only disabled state could stick. The OR keeps the pre-batch enabled behavior for canvas history (documented §6.1 with the residual stale-disabled case for empty canvas history — accurately disclosed, pre-existing).
- Scope completeness: the accessibility retry action (`CanvasSurfaceMacHelpers.swift:480-491`) intentionally stays single-image and calls `retryDecode` directly plus `onRetryImageDecode`; it guards on `state == .failed`, so it cannot resurrect a removed object. Consistent with the record's claim.

### 3.4 Cross-cutting checks that found no defects

- `retryFailedImageDecodes()` on a stale banner after image removal: `ids` empties → returns `false`, no request published (asserted by the quiet-session negative control, `CanvasDomainTests.swift:1094-1097`).
- Board switch mid-retry: `imageCache.removeAll()` (canvasID change) clears `retryKeys` and cancels active work; a pending request consumed by a new view intersects by UUID against the new board's images, so it cannot resurrect foreign images. `synchronizeFromStore` intersects `failedImageIDs` with current image IDs (line 1693-1695).
- Duplicate-content images share a `contentToken`; a second `retryDecode` for the same token no-ops (failure memo already drained) while the first decode serves both — no double decode.
- `transformSemanticObject` refit requires finite width/height before calling `textSize`; `isValid` still runs after the refit, so a refit that lands back on the current transform records nothing (verified by the squash control).
- Panel wiring regression surface: the owned `CanvasPanelContent.swift` diff is exactly 2 computed properties + 4 call sites; the banner, dismiss, export, and `CanvasSurface` bridge wiring are untouched. `CanvasSurfaceIOS.swift` has no consumer of `imageDecodeRetryRequest` (grep-verified), so the request-type change cannot break the dormant iOS surface; the cache API it uses is unchanged.

## 4. Batch 1 × Batch 2 combined coherence

- Shared files: Batch 1's `CanvasSession.swift` changes (history byte budget, `interactionInterruptions`, `storeSynchronizationCount`) and Batch 2's changes occupy disjoint regions; the combined file compiles and the full suite passes. Batch 1's `interruptTransientInteraction` (surface keeps caches alive by design) does not cancel queued retries — `retryKeys` only clears on `removeAll()`/`finishDecode`, matching the documented lifecycle.
- Batch 1's `fit(in:excluding:)` and Batch 2's toolbar changes coexist in the same toolbar block without overlap; the Fit button still routes through Batch 1's excluded-rects signature (`CanvasPanelContent.swift:374`).
- Batch 1's history budget interacts safely with CVD-08: a refitted resize records one `.changeSemantic` command whose cost is the text bytes (bounded by the 64 KB content cap), well inside the 64 MB budget; no eviction-behavior change.

## 5. Independent test execution (all numbers re-measured)

Environment: reconstruction at `/tmp/attic-b2-review-r5`, configuration `Local`, `CODE_SIGNING_ALLOWED=NO`, private DerivedData, offline XCTest injection into `AtticUnitTestHost` using the snapshot's own runner (`run.zsh`/`makeconfig` copied to `/tmp/attic-b2-r5-xctest`).

| Run | Command (abbreviated) | Result |
|---|---|---|
| Build for testing (fixed tree) | `xcodebuild build-for-testing -project Attic.xcodeproj -scheme Attic -configuration Local -derivedDataPath /tmp/attic-b2-r5-dd -only-testing:AtticTests CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO` | exit 0, `** TEST BUILD SUCCEEDED **` |
| 7 new tests | `run.zsh r5-new-tests 600 <7 ids>` | `Executed 7 tests, with 0 failures`, exit 0 |
| Focused Canvas suite (17 classes) | `run.zsh r5-focused 900 <17 classes>` | **Executed 205 tests, with 0 failures**, exit 0 — matches the record's 205 |
| Full Local unit suite (42 classes) | `run.zsh r5-full-unit 1200 <42 classes>` | **Executed 820 tests, with 4 tests skipped and 0 failures**, exit 0; `Canvas decode stress: 96 images in 0.074s, max active 4` — matches the record |
| Mutant R5-M-bridge (my own, not in the record): `CanvasSurfaceMac.swift:154` fan-out → `first(where:)` | rebuild + run 3 retry tests | `Executed 3 tests, with 3 failures`, exit 1; cache unit test unaffected — the view tests discriminate the bridge, no false positives |
| Test-count reconciliation | `diff` of snapshot `b1-tests.txt` (811) vs `b2-tests.txt` (820) | exactly 9 additions: 7 Batch 2 tests + 2 inherited `CanvasStoreTests` tests (`testFailedPreparationOn{Create,Delete}Canvas…`, present in the baseline tree, absent from HEAD — consistent with the record; `CanvasStoreTests.swift` hash `a586501c…` matches the record) |
| Class-list claim | 42 classes in `full-classes.txt` vs `XCTestCase` classes declared in `AtticTests/` | identical lists (42 = 42) |

## 6. Findings

### CONFIRMED DEFECTS

None. I could not produce a reproducer for any correctness defect in the five fixes, their callers, or their interaction.

### SUSPICIONS (not defects; verified context, low severity)

- **S1 — "No Swift warnings" claim holds only for incremental builds.** The record's §5 claims the fixed-repo build has no Swift warnings. A *fresh* `build-for-testing` of the reconstructed tree emits 2 Swift warnings in **inherited, non-owned** test files: `AtticTests/TaskStoreTests.swift:257` ("code after 'throw' will never be executed") and `AtticTests/PanelGeometryTests.swift:291` (`CGWindowListCreateImage` deprecation). Both files are byte-identical to their pre-Batch-2 state (hash-verified), so this is not a Batch 2 regression and the claim is true for the owned surface; but the blanket wording overstates a fresh-build property. Suggested fix: reword to "no warnings in owned files" or note the inherited warnings. Severity: documentation accuracy only.
- **S2 — Stale banner entry if a failure memo entry is trimmed.** `trimFailureHistory` (512-entry cap) can drop a non-visible failure from the cache-side memo without emitting `onDecodeFailuresChanged`, leaving `session.failedImageIDs` (and the banner) listing an image whose `retryDecode` will now no-op while still returning `true`. Requires 512+ distinct failed images on one board; pre-existing semantics that Batch 2 does not worsen (the retry path removes the memo entry before the banner can observe it). No action required for this batch.
- **S3 — "Latest request wins" retry semantics.** `imageDecodeRetryRequest` is a single published value; a second retry request (e.g. accessibility retry) before the bridge consumes the first silently supersedes it. Pre-existing design, recoverable by clicking again, and unchanged by Batch 2 (the set-valued request actually shrinks the window where this mattered). No action required.

### OPTIONAL IMPROVEMENTS

- **O1** — `CanvasSession.swift:379-381` doc comment ("The renderer only honours a retry for an image it is currently tracking") predates CVD-04; "tracking" now includes explicit off-screen retries. Rewording would prevent a future reader from re-adding a visibility gate believing it is load-bearing.
- **O2** — `CanvasImageDecodeCache.retryDecode` inserts into `retryKeys` only when the key was actually queued (`queued[key] != nil`). If a future refactor enqueues lazily, a retry of an off-screen key could silently skip the `retryKeys` guard. A debug assertion that the key is queued-or-active when inserted into `retryKeys` would lock the invariant the mutants M2b/M2c protect.

### Documentation claim audit (re-measured where possible)

| Claim in `DeepAudit-Batch2-Implementation.md` | Re-measured | Result |
|---|---|---|
| Manifest hash `9af3fc17…` | matches | OK |
| Owned post-fix hashes (9 files) | all 9 match | accurate |
| Owned diffstat +524/−27 | measured +524/−27 | accurate |
| Only 6 inherited paths changed; 324 untouched | verified | accurate |
| Status adds 3 owned + report + playbook | verified | accurate |
| 7 new tests, unfixed 34 failures / fixed 0 | 0 failures re-measured (unfixed run not repeated; before-log and 34-failure evidence in snapshot consistent) | plausible, not re-derived |
| Focused 205/0 | **205/0 re-measured** | accurate |
| Full suite 820, 4 skipped, 0 failures | **820/4/0 re-measured** | accurate |
| 811 → 820 reconciliation, 9 named additions, none removed | verified via `b1-tests.txt`/`b2-tests.txt` diff | accurate |
| 42-class full-suite list = declared `XCTestCase` classes | verified identical | accurate |
| Mutant table (M1-M5) | not re-run; my independent bridge mutant reproduces the M1 failure signature (3 failures, cache test exempt) | consistent |
| "No app launched / no native UAT" | consistent with constraints; native UAT remains an open gate | accurate |

## 7. Not covered / limits

- No native UAT, no app launch, no real key-panel responder-chain exercise (the toolbar/menu test injects `focusedResponder`; the record itself flags real-responder-chain UAT as a separate gate). No CloudKit/APNs/iPhone/Production claims are made or tested, per the development contract.
- The record's five mutants (M1-M5) were not re-run; I ran one independent mutant at a site the record's mutant set does not cover (the view-bridge fan-out). The tests-first unfixed run (34 failures) was not reproduced; its evidence lives in the snapshot logs.
- iOS surface (`CanvasSurfaceIOS.swift`) reviewed for compile/API compatibility only; it is dormant deferred scope.
- Elapsed time: ~25 minutes, ~55 tool steps (within budget).

## 8. Verdict

**REVIEW_PASS.** The five Batch 2 fixes are individually correct, mutually coherent, and coherent with the Batch 1 work in the same tree; the whole-diff discipline holds (only the 9 owned files changed relative to the pre-Batch-2 baseline, all hashes re-verified); the new tests discriminate their mechanisms (bridge-side mutant killed with the expected failure pattern); and the re-measured test counts (7 new, 205 focused, 820 full / 4 skipped / 0 failures) match the record. The only findings are two low-severity observations and one documentation-accuracy note (S1), none of which block the batch. Native UAT remains open and is explicitly not claimed by this review.
