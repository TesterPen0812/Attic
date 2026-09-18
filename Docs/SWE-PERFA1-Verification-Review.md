# SWE verification review — PERF-A1 review fixes

Date: 2026-09-14
Checkout: `/Users/taha/Developer/attic-task-panels-v2`
Branch/HEAD: `codex/attic-task-panels-v2` / `ae6418c1af690e29d15a20344cdb9765a23d3f85` (dirty shared checkout, nothing committed)
Reviewed: `Docs/Opus-PERFA1-Review-Fixes.md` against `Docs/Sol-Canvas-PERFA1-Review.md` (two P1, one P2) and `Docs/Opus-Implementation-Report.md`.
Baselines: `/tmp/attic-perf-a1-snapshot-135140` (pre-PERF-A1), `/tmp/attic-perfa1-fixes-snapshot-141831` (pre-fixes).
Scope: independent verification review only. No source edits, no commit/push/release, no native UI, no preview interaction (Luna screenshot task owns the pointer; the running `AtticChromeCheckpoint` preview was not touched).

## Verdict

All three Sol findings are fixed, and every checkable claim in `Docs/Opus-PERFA1-Review-Fixes.md` reproduced under independent verification: source hashes, diffs, build results, instrumentation symbol counts, log contents, and focused plus full-suite test reruns. No defects found in the reviewed diffs.

## Finding status

### Sol P1 — replica fetch counter in shipped hot paths: FIXED (verified)

`Attic/Services/CanvasStore.swift:66-118`: `enum CanvasReplicaFetchCounter` and both `ModelContext` helper bodies are `#if DEBUG`-gated; `#else` is a plain `fetch`/`fetchCount`. Grep confirms the only other references are inside the `#if DEBUG` half of the perf-gate test (`AtticTests/CanvasPerformanceGateTests.swift:586-687`), so non-`DEBUG` builds cannot reference it.

Independently verified:

- Build settings: `Local` sets `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` and `ENABLE_TESTABILITY = YES`; `Release` has no `DEBUG` and `ENABLE_TESTABILITY = NO` (`xcodebuild -showBuildSettings`, scheme `Attic`).
- `nm | grep -c CanvasReplicaFetchCounter`: Release `Attic.app` binary = **0**; non-`DEBUG` `AtticUnitTestHost`, `.debug.dylib`, and `AtticTests` bundle = **0** each; `DEBUG` `AtticUnitTestHost.debug.dylib` = **24**. Matches the report exactly.
- My non-`DEBUG` rerun (verified bundle `/tmp/attic-perfa1-fixes-nodebug-dd`): the perf gate reports `Test skipped - CanvasReplicaFetchCounter is compiled only in DEBUG builds.` at `CanvasPerformanceGateTests.swift:685`; the other six focused tests still pass without the counter.
- All three Opus build logs end in `TEST BUILD SUCCEEDED` / `BUILD SUCCEEDED` with no `error:` lines.

### Sol P1 — `TaskImageTests.swift:334` wrong `NSItemProvider` contract: FIXED (verified, not weakened)

`AtticTests/TaskImageTests.swift:336` now asserts `suggestedName == "Picture"`, matching `TaskAttachmentDragItem.suggestedName` (`Attic/Models/TaskDragPayload.swift:28-38`), which strips the extension exactly when the content type would re-add it. The test keeps both halves of the contract: inside the awaited `loadFileRepresentation` completion it still asserts `XCTAssertNil(error)`, `XCTAssertNotNil(url)`, copy ≠ private URL, and `Data(contentsOf: url) == Data(contentsOf: image)`, and now also `url.lastPathComponent == "Picture.png"` (line 354). The `expectation`/`fulfillment` pair means the load actually ran — the basename check executed against a real delivered URL. Both my `DEBUG` and non-`DEBUG` reruns pass the test.

### Sol P2 — pending-context predicate premise was probe-only: FIXED (verified)

New durable test `CanvasStoreTests.testCanvasScopedReplicaReadsSeeUnsavedChangesInTheContext` (`AtticTests/CanvasStoreTests.swift:960-1037`). It covers every predicate form the finding named: unsaved insert, `canvasID` move into and out of a predicate, pending tombstone, via `fetch`, `idList.contains`, and `fetchCount`, plus the production `store.storedStrokeReplicas(matching:)` on the pending context.

Discrimination is real, not assumed: `context.hasChanges` is asserted, and before `context.save()` a separate `ModelContext(container)` still sees B = `[existing]` and `hasUnboardedLegacyDefaultContent == true`, so the pending assertions can only pass if predicated reads see unsaved state. The same assertions are then re-run on a fresh post-save context. Passed in both my `DEBUG` and non-`DEBUG` reruns.

## Hash and snapshot verification

- Both snapshots are internally consistent: every entry in both `SHA256SUMS` verifies `OK` against the snapshotted files.
- Current worktree vs `/tmp/attic-perfa1-fixes-snapshot-141831`: exactly the four files Opus reports changing differ (`CanvasStore.swift`, `CanvasStoreTests.swift`, `CanvasPerformanceGateTests.swift`, `TaskImageTests.swift`); `CanvasStorePersistence.swift`, `CanvasStoreImages.swift`, `CanvasStoreSemanticObjects.swift`, `TaskDragPayload.swift` are `cmp`-identical.
- Current worktree vs `/tmp/attic-perf-a1-snapshot-135140` (23 files): exactly the six PERF-A1-owned files differ — consistent with both reports chained.
- All eight reported "after" SHA-256 values match the current files on disk, including `CanvasStore.swift` `c6a23302…` and `TaskImageTests.swift` `83f3dd21…`.
- Reported diff sizes (`+14/−1`, `+84/−0`, `+6/−0`, `+4/−1`) match the actual diffs hunk-for-hunk. Whitespace clean (`git diff --check` on tracked, `diff --check` on untracked).
- All 15 `FetchDescriptor<Canvas…>` sites in `Attic/` route through `fetchCanvasReplicas`/`countCanvasReplicas`; no unpredicated replica read bypasses the helpers. `backfillLegacyImagePayloadMetadata`'s `contentDigest == ""` predicate matches `backfillPayloadMetadataIfNeeded()`'s `contentDigest.isEmpty` guard (`CanvasImageItem.swift:170`).

## Binary provenance and reuse justification

- On-disk hashes equal the values recorded in Opus's run logs: host `2287db13…`, host debug dylib `6dd8b417…`, test bundle binary `ef2d7db5…` under `/tmp/attic-perfa1-fixes-dd` (non-`DEBUG` bundle `429df8a4…` under `/tmp/attic-perfa1-fixes-nodebug-dd`).
- The test bundle and host dylib were built 14:21:56; `find Attic AtticTests AtticUnitTestHost Attic.xcodeproj -newer <bundle>` finds **no** Swift source, plist, entitlements, pbxproj, xcconfig, or script newer than the bundle. The bundle therefore represents the current, hash-verified sources.
- Reuse is authorized by that provenance; no private rebuild was needed. I did not rebuild from clean — see Limits.

## Independent reruns (windowless `AtticUnitTestHost`, `setActivationPolicy(.prohibited)`, in-memory/temp stores, `/tmp/attic-offline-xctest/run.zsh`)

| My run | Products | Result |
| --- | --- | --- |
| `swe-perfa1-focused` | `perfa1-fixes-dd` (DEBUG) | 7 tests, 0 failures — pending test, perf gate, 4 PERF-A1 `CanvasStoreTests`, drag test |
| `swe-perfa1-nodebug` | `perfa1-fixes-nodebug-dd` | 7 tests, 1 skipped (perf gate, by design), 0 failures — superset of Opus's 3-test nodebug run |
| `swe-perfa1-full` | `perfa1-fixes-dd` (DEBUG) | **799 tests, 4 skipped, 0 failures**, exit 0 |

My full-suite rerun reproduces Opus's claim exactly: 795 `passed` + the same 4 named skips (`AgentServerIntegrationTests.testOfficialMCPClientInteroperability`, two `PanelGeometryTests` swipe tests, `TaskStoreTests.testSuccessfulCloudImportRefreshesChangesSavedOutsideStoreContext`) = 799. Scope verified: the 42-class run list is identical to the set of `XCTestCase` subclasses in `AtticTests` sources (computed independently). Logs: `/tmp/attic-offline-xctest/swe-perfa1-*.log`.

## Inspected Opus results (not rerun claims, verified as recorded)

- `perfa1-fixes-full-unit.log`: 799 tests, 4 skipped, 0 failures over the identical 42-class list; recorded hashes match the on-disk binaries.
- `perfa1-fixes-focused.log`: 7 tests, 0 failures. `perfa1-fixes-nodebug-focused.log`: 3 tests, 1 skipped, 0 failures.
- Build logs `attic-perfa1-fixes-{build,nodebug-build,release-build}.log`: all succeeded, no errors.

## Residual gaps (non-blocking, no action required for this gate)

- The perf gate asserts `CanvasReplicaFetchCounter.rows` but not `fetches`; a future regression adding redundant fetches without extra rows would not trip the bound. Fetch count was verified unchanged (10) by probe, not by a durable assertion.
- The pending-context test exercises strokes only; `storedImageReplicas`, `storedBoardReplicas`, `tombstoneAllContent`, and semantic-object pending visibility rest on identical predicate forms by symmetry. Acknowledged in Opus's limits.
- `CanvasImagePayloadAccessCounter` remains unconditionally compiled — pre-existing pattern Sol explicitly excused; unchanged by this diff.
- The non-`DEBUG` perf gate is a visible skip, not a guard — by design; every current test configuration (`Local`/`Debug`) sets `DEBUG`.
- Measure-loop bound uses `store.strokes.count` evaluated after the loop (slightly lenient for early iterations); pre-existing PERF-A1 test structure, immaterial to the fix.

## Limits

- I reused the provenance-verified binaries rather than rebuilding from clean; the Release/non-`DEBUG` compile claims are verified by Opus's build logs plus the produced artifacts' symbol contents, not by a from-scratch private build.
- No native UI, gesture, Instruments, real user store, CloudKit, iPhone, signing, or installed-app behavior was exercised. The running preview was not touched.
- Native QA checklist from `Docs/Opus-Implementation-Report.md` remains open and unclaimed.

REVIEW_PASS
