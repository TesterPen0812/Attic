# Sol code review — PERF-A1 Canvas replica reads

Date: 2026-09-14  
Checkout: `/Users/taha/Developer/attic-task-panels-v2`  
Baseline: `/tmp/attic-perf-a1-snapshot-135140`  
Reviewed report: `Docs/Opus-Implementation-Report.md`  
Scope: independent source/diff/test review only; no source edits, native UI, preview relaunch, commit, push, or release.

## Verdict

The Canvas predicate change is correct in the reviewed paths and the measured row reduction is supported by the supplied before/after artifacts. It preserves selected-canvas presentation, physical-replica fan-out, rollback behavior, legacy-default discovery, and fallback selection in the cases exercised. The focused PERF-A1 tests passed independently.

Changes are still required before this shared checkout has a clean integration gate. One new test counter remains active in production code on every wrapped Canvas fetch, the predicate behavior with pending `ModelContext` changes is supported only by a removed probe rather than a durable regression test, and the full unit suite has a deterministic test defect outside the Canvas diff.

## Findings

### [P1] Keep the replica fetch counter out of shipped hot paths

**File:** `Attic/Services/CanvasStore.swift:66-104`  
**Affected calls:** `CanvasStore.swift:147-190`, `CanvasStorePersistence.swift:458-575`, `CanvasStoreImages.swift:87-89`, and `CanvasStoreSemanticObjects.swift:43-45`.

`CanvasReplicaFetchCounter` is test instrumentation, but `fetchCanvasReplicas` and `countCanvasReplicas` unconditionally mutate two process-global static integers in every build. PERF-A1 therefore adds stateful work to every Canvas replica fetch, including Release. The after measurements include this cost and still show a large improvement, so it does not invalidate the reported row or timing result. It remains unnecessary production work in the exact hot path being optimized. The mutable globals are also not actor-isolated at their declaration; current calls are reached through the `@MainActor` `CanvasStore`, which bounds the present risk, but the generic `ModelContext` helpers do not enforce that boundary.

**Recommendation:** compile the counter mutations only under `DEBUG`/a dedicated test instrumentation flag, or inject a test observer at the store seam. Keep Release helpers as direct `fetch`/`fetchCount` calls. If Release test configurations must compile these assertions, leave a no-op counter API in Release and skip the counter-only tests there. The older `CanvasImagePayloadAccessCounter` pattern does not require extending the same production instrumentation to all replica reads.

### [P1] Fix the deterministic full-suite test defect; the drag implementation is behaving correctly

**File:** `AtticTests/TaskImageTests.swift:334` (outside the six-file PERF-A1 diff)  
**Related implementation:** `Attic/Models/TaskDragPayload.swift:21-42` (unrelated dirty work).

Both Opus's 798-test run and the independent focused rerun fail because the test expects `imageProvider.suggestedName == "Picture.png"`. The implementation deliberately strips the extension and sets `suggestedName` to `"Picture"`. That matches the installed macOS SDK contract: `loadFileRepresentation` attempts to use `suggestedName` with an appropriate extension based on the content type. An isolated SDK probe with a PNG representation observed `suggestedName == "Picture"` and a delivered copy named `Picture.png`.

This is a current test assertion defect, not a Canvas PERF-A1 regression and not evidence that the drag-out behavior is broken. It cannot be called "pre-existing" relative to the checked-in baseline because `TaskImageTests.swift` is untracked and `TaskDragPayload.swift` is unrelated dirty work.

**Reproducer:**

```text
ATTIC_TEST_PRODUCTS=/tmp/attic-perf-a1-dd/Build/Products/Local \
  /tmp/attic-offline-xctest/run.zsh sol-review-perf-a1-focused 300 \
  TaskImageTests/testAttachmentDragPromisesItsRecordedTypeAndHandsOutACopy

TaskImageTests.swift:334: XCTAssertEqual failed: Optional("Picture") != Optional("Picture.png")
```

**Recommendation:** change the property assertion to `"Picture"`, then add/assert `url.lastPathComponent == "Picture.png"` inside the existing `loadFileRepresentation` completion. This tests both halves of the intended contract: an extensionless suggestion avoids `Picture.png.png`, and the receiver gets the correct final filename.

### [P2] Preserve the pending-context predicate premise as a permanent regression test

**Files:** `Attic/Services/CanvasStore.swift:137-196`, `Attic/Services/CanvasStorePersistence.swift:104-169`, and `AtticTests/CanvasPerformanceGateTests.swift`.

`save()` resolves the pending context before persistence, so correctness depends on predicated `fetch`, `idList.contains`, and `fetchCount` observing unsaved inserts, property moves into and out of a predicate, and tombstones. The supplied temporary probe covered all four forms and passed on this SDK (`onB=2`, `byIDs=2`, `liveOnACount=0`, `liveOnAFetch=0`). Existing persistence-failure tests also exercise pending inserts/updates indirectly. However, the direct probe was removed, and no current test names or directly asserts the complete premise.

**Recommendation:** retain a small on-disk or in-memory test that inserts one pending row, moves one row's `canvasID`, tombstones one row, and asserts the same fetch/fetch-count results before saving. This guards the central SwiftData behavior PERF-A1 now relies on, rather than leaving it only in an ephemeral log.

## Verified implementation behavior

- **Snapshot identity:** all 23 files in `SHA256SUMS` match the snapshot, and `cmp` reports exactly the six owned files changed. The six before and after SHA-256 values match `Docs/Opus-Implementation-Report.md` exactly.
- **Diff scope:** independent `--no-index` stats match the report: `111/9`, `54/29`, `4/2`, `1/1`, `184/2`, and `100/1` insertions/deletions for the six files respectively. `git diff --check` is clean for those files.
- **Replica identity:** predicates include both `canvasID` and requested IDs; grouping and in-memory filters remain. The focused same-UUID/cross-canvas test passed and verifies both selected-canvas replicas advance while the foreign replica remains at its original mutation version.
- **More than 512 IDs:** the 532-ID test passed. The fallback predicate fetches the whole selected canvas, then filters IDs in memory, so it avoids an oversized `IN` list while retaining every selected-canvas physical replica. The image helper is structurally symmetric, although the durable >512 test covers strokes only.
- **Legacy default:** when there is no physical default board, the selected-default path inspects already-loaded rows and the other-canvas path uses live-row counts for strokes, images, and semantic objects. The four-case legacy test passed, including tombstoned-only content remaining hidden.
- **Fallback selection:** a missing/tombstoned selected board triggers one reload for the resolved board's content from the same context. The external-deletion fallback test passed and the next mutation remained on the fallback canvas.
- **Rollback and saved-presentation behavior:** the predicate change does not alter `context.rollback()`, fresh-context replacement, or the persisted-presentation fallback. The 183-test Canvas run includes the existing failed-save, failed-reload, clear, and undo coverage and passed.
- **Backfill:** restricting image metadata backfill to `contentDigest == ""` matches `backfillPayloadMetadataIfNeeded()`'s guard exactly. Empty payloads still remain legacy/invalid and unchanged, as before.
- **Performance claim:** the supplied probes used the same seeded shape and recorded rows `1,841 -> 29` for `addStroke`, `1,869 -> 51` for `setDeleted`, `1,251 -> 49` for `clearBoard`, and `624 -> 303` for selecting the larger board. The after median (`44.4 ms -> 2.3 ms`) is indicative on a shared machine; the deterministic row counts are the stronger evidence. The claim that `payload.count` was not a separately important cost is consistent with the probe, but it is a local SDK/store observation rather than a universal SwiftData guarantee.

## Independent checks

- Reused the final build only after verifying its test-bundle SHA-256 was `e5784fd11f75b93aa920a4040f664935017f5ac2a0826bb0c68032ce41d57e23`, matching both supplied final logs. The bundle timestamp is later than all six reviewed source/test timestamps.
- Ran the PERF-A1 performance gate plus the four new Canvas correctness tests: **5 passed, 0 failed**. Log: `/tmp/attic-offline-xctest/sol-review-perf-a1-focused.log`.
- Included the reported attachment drag test in the same run: **1 failed**, deterministically at `TaskImageTests.swift:334`.
- Inspected the installed SDK declaration and ran an isolated `NSItemProvider` PNG probe: property `Picture`, delivered copy `Picture.png`, no error.
- Verified the supplied Canvas run: **183 passed, 0 failed**. Verified the supplied full run: **798 executed, 4 skipped, 1 failure** at the same attachment assertion.

## Limitations

No native UI, gesture, accessibility, Instruments, real user store, CloudKit, iPhone, release configuration, or installed-app behavior was exercised. No independent pre-fix binary was rebuilt; baseline performance is assessed from the supplied probe artifact, whose binary hash differs from the final build as expected. The focused rerun used the already-built final bundle after provenance checks, avoiding a needless full rebuild in the extensively dirty shared checkout.

CHANGES_REQUIRED
