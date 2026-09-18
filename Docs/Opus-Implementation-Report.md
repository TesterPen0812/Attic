# Opus implementation report — PERF-A1 Canvas replica reads

Date: 2026-09-14
Checkout: `/Users/taha/Developer/attic-task-panels-v2`
Branch/HEAD: `codex/attic-task-panels-v2` / `ae6418c1af690e29d15a20344cdb9765a23d3f85` (dirty shared checkout, nothing committed)
Status: **REVIEW_READY** — automated proof only; native UI verification not performed.

## Outcome

PERF-A1 (`Docs/Rolling-Performance-Audit.md`) has two parts. The evidence split them:

1. **Unpredicated replica table fetches: CONFIRMED and fixed.**
   - `CanvasStoredReplicas.load(from:)` read every board, stroke, image and semantic row in the store, for every canvas, twice per save (pending context, then fresh context). Mutation lookups (`storedStrokeReplicas`, `storedImageReplicas`, `storedBoardReplicas`, `tombstoneAllContent`, image import) and the legacy image backfill also read whole tables and filtered in memory.
   - On a 3-board store (two 300-stroke boards, a 10-stroke selected board, ~7 KB payloads), one `addStroke` materialised **1,841 replica rows**. After the fix it reads **29**.
2. **"Needless stroke payload materialisation via `payload.count`": effectively DISPROVEN as a separate cost.**
   - `CanvasStrokeItem.payload` is inline `Data`, not external storage, so the bytes arrive with the row fetch.
   - On already-fetched rows, reading `payload.count` for 621 rows cost 0.29–1.0 ms. Reading scalar columns cost 0.47–1.4 ms. An unpredicated fetch of the same rows cost 11–12 ms.
   - The real payload cost was fetching other canvases' rows at all, which the predicates remove.
   - The audit's suggested stroke scalar payload column was therefore **not** added. It would be a schema change with no measured benefit. `CanvasStrokeCacheEntry` still compares `payloadByteCount == replica.payload.count`.

The number of fetches per operation is unchanged (10 for `addStroke`); only the rows each fetch returns changed. Save, rollback, post-save refresh, undo and the two-context resolve architecture are unchanged.

## What changed

### `Attic/Services/CanvasStore.swift`
- **`CanvasStoredReplicas.load(from:contentCanvasID:)`.** Fetches all board rows, plus only the strokes, images and semantic objects whose `canvasID` equals the requested canvas (`#Predicate`). Tombstones and duplicate replicas of that canvas are all still loaded, so winner resolution is identical.
- **`hasUnboardedLegacyDefaultContent`.** Keeps the virtual legacy default board, which is shown when no physical default board row exists but live content still claims `logicalBoardID`:
  - It is computed from the loaded rows when the default canvas is the one being loaded.
  - Otherwise it uses `fetchCount` with `canvasID == logicalBoardID && !tombstoned` for strokes, then images, then semantic objects. The default canvas's payloads stay on disk.
- **`loadReplicas` seam** is now `(ModelContext, UUID) throws -> CanvasStoredReplicas`.
- **`CanvasReplicaFetchCounter`** plus `ModelContext.fetchCanvasReplicas` / `countCanvasReplicas`: a test counter for replica reads and rows. It mirrors the existing `CanvasImagePayloadAccessCounter` pattern.

### `Attic/Services/CanvasStorePersistence.swift`
- **`resolveCanvasPresentation`** loads the selected canvas's content. If the selected canvas is no longer live and resolution falls back to another board, it reloads content for the resolved canvas from the same context (one extra load, fallback only). The existing in-memory `canvasID == resolvedSelectedCanvasID` filters remain.
- **`storedBoardReplicas(matching:)`** uses `#Predicate { $0.id == id }`.
- **`storedStrokeReplicas` / `storedImageReplicas`:**
  - Up to `replicaIdentifierPredicateLimit` (512) ids, the predicate is `canvasID == selected && idList.contains(id)`.
  - Above that, the predicate is `canvasID == selected`, which keeps the SQL `IN` list well under SQLite's bound-variable limit.
  - The in-memory `canvasID`/`ids` filter and grouping are kept, so every physical replica of each id on the selected canvas is still mutated, exactly as before.
- **`tombstoneAllContent`** uses canvas-scoped predicates.
- **`backfillLegacyImagePayloadMetadata`** fetches only `contentDigest == ""` rows. This is exactly the set `backfillPayloadMetadataIfNeeded()` can change: it guards on `contentDigest.isEmpty`, and the column defaults to `""`.

### `Attic/Services/CanvasStoreImages.swift`
- Image import fetches only the target canvas's image rows (it previously fetched all rows and filtered in memory).

### `Attic/Services/CanvasStoreSemanticObjects.swift`
- `storedSemanticReplicas` was already predicated; it now goes through `fetchCanvasReplicas` so the counter sees it.

### Correctness argument for pending changes
- Resolution runs on the pending context before `persist`, so predicated reads must see unsaved inserts and edits.
- A temporary probe (since removed) verified this on this SDK against a context with an unsaved insert, an unsaved `canvasID` move and an unsaved tombstone:
  - Predicated `fetch` returned the pending insert and the moved row (2/2).
  - `idList.contains` returned 2/2.
  - `fetchCount` and `fetch` with `!tombstoned` both returned 0 for the pending-tombstoned row.

Not changed: no schema or model changes, no project regeneration, no new files, no Notes/no-swipe source, and no board/content write paths beyond their lookups.

## Tests

### Added to existing files (no project changes needed)

**`AtticTests/CanvasPerformanceGateTests.swift`**
- `testStrokeMutationsReadOnlyTheSelectedCanvasReplicas`
  - Store: on-disk, 3 boards, 600 other-canvas strokes, 20 other-canvas images, 10 selected strokes.
  - Asserts replica rows read by `addStroke`, a measured `addStroke` loop, `setDeleted` and `clearBoard` stay within `3 × (boards + selected strokes)`. That bound is below the 620 other-canvas rows; before the fix those operations read 1,251–1,869 rows.
  - Also asserts the other canvases' rows are unrewritten (`mutationVersion == 1`, 60 tombstones kept) and still present correctly when selected (270 strokes, 20 images).

**`AtticTests/CanvasStoreTests.swift`**
- `testSameIDReplicaOnAnotherCanvasIsNotShownOrRewrittenBySelectedCanvasMutations`: delete and restore change both same-UUID replicas on the selected canvas (mutationVersion 2, then 3). The same UUID on another canvas keeps version 7 and its own content.
- `testUnboardedLegacyDefaultContentKeepsTheDefaultCanvasListedFromAnotherCanvas`:
  - Covers legacy stroke, image and semantic-only content, plus tombstoned-only content (must not list).
  - Checks the default canvas listing on open, after switching to another canvas, after a mutation there, and on reopen.
- `testRefreshAfterSelectedCanvasIsDeletedElsewhereShowsTheFallbackCanvasContent`: after the selected board is tombstoned by another context, `refresh()` falls back to the default canvas and shows its content, and the next mutation lands there.
- `testDeletingMoreStrokesThanTheIdentifierPredicateLimitTouchesEveryReplica`: 532 ids × 2 replicas, above the 512 limit. Delete and restore reach all 1,064 selected-canvas replicas, and the other-canvas replica stays untouched.

### Updated
- The private `CanvasReplicaReadGate.load` matches the new `loadReplicas` signature. It is used by the existing post-save reload-failure tests.

### Mutation check (tests fail when the fix is broken)
- I temporarily broke the fix in two ways: forced `hasUnboardedLegacyDefaultContent = false` on the count path, and disabled the fallback reload (`if false, …`).
- Build `/tmp/attic-perf-a1-mutant-build.log` succeeded. Run `perf-a1-mutant` gave **2 tests, 8 failures**:
  - The legacy test failed for stroke, image and semantic.
  - The fallback test showed `[]` instead of the default stroke.
- The sources were restored from `/tmp/perf-a1-mut-*.swift` and verified byte-identical with `cmp`, then rebuilt before the final runs below.
- The perf gate's bound is below the measured pre-fix rows for all asserted operations (baseline table below).

## Commands and results

**Build (final sources):**
```
xcodebuild build-for-testing -project Attic.xcodeproj -scheme Attic -configuration Local \
  -derivedDataPath /tmp/attic-perf-a1-dd -only-testing:AtticTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO > /tmp/attic-perf-a1-build4.log
```
Result: `** TEST BUILD SUCCEEDED **`, exit 0, 0 errors.

**New tests only:**
```
ATTIC_TEST_PRODUCTS=/tmp/attic-perf-a1-dd/Build/Products/Local /tmp/attic-offline-xctest/run.zsh perf-a1-new-gates 300 \
  CanvasPerformanceGateTests/testStrokeMutationsReadOnlyTheSelectedCanvasReplicas CanvasStoreTests/test…(4 above)
```
Result: 5 tests, 0 failures.

**All 17 Canvas XCTest classes:**
```
ATTIC_TEST_PRODUCTS=/tmp/attic-perf-a1-dd/Build/Products/Local /tmp/attic-offline-xctest/run.zsh perf-a1-canvas-all 900 \
  CanvasAccessibilityTests CanvasAffordanceTruthTests CanvasDocumentStoreTests CanvasDomainTests CanvasImageDomainTests \
  CanvasImageDropBatchTests CanvasImageImportBatchTests CanvasImageImportTests CanvasImageInteractionTests \
  CanvasImageSessionTests CanvasImageStoreTests CanvasPerformanceGateTests CanvasPrecisionTests CanvasRenderCacheTests \
  CanvasSessionTests CanvasStoreTests CanvasUITestStoreTests
```
Result: **183 tests, 0 failures**. Log `/tmp/attic-offline-xctest/perf-a1-canvas-all.log`, test bundle binary sha256 `e5784fd11f75b93aa920a4040f664935017f5ac2a0826bb0c68032ce41d57e23`.

**Every XCTestCase class in `AtticTests` (42 classes), same runner:** log `perf-a1-full-unit.log`.
- Result: 798 tests, 4 skipped, **1 failure**, outside Canvas scope: `TaskImageTests.testAttachmentDragPromisesItsRecordedTypeAndHandsOutACopy` (`"Picture"` vs `"Picture.png"`, `TaskImageTests.swift:334`).
- That test file is untracked work by another writer, has no Canvas references, and exercises task attachment drag naming (`TaskDragPayload`/`AttachmentFileStore`, both modified by others). I did not investigate or change it.

**Whitespace:** `git diff --check` on the six owned source/test files is clean.

## Performance evidence

The same seeded probe (on-disk store, 3 boards; logical and other boards have 300 strokes each with every 10th tombstoned; selected board has 10; 7,318-byte payloads) was run against the counter-instrumented build before the predicates (`perf-a1-probe-baseline.log`) and after (`perf-a1-probe-after.log`). Local configuration, debug test host, shared developer machine.

| Operation on the selected 10-stroke board | Replica fetches before → after | Rows before → after |
| --- | --- | --- |
| `addStroke` | 10 → 10 | **1,841 → 29** |
| `setDeleted` (3 ids) | 9 → 9 | **1,869 → 51** |
| `clearBoard` | 9 → 9 | **1,251 → 49** |
| `selectCanvas(other 300-stroke board)` | 5 → 5 | 624 → 303 |

Timing:
- `addStroke` median wall time: **44.4 ms → 2.3 ms** (10 samples; before 39–50 ms, after 2 ms each).
- The committed gate's `measure` averaged 0.002 s (RSD 4.7%) with the fix.
- Wall-clock timing is indicative only. The row counter assertions are the regression guard.

## Changed files (owned) and SHA-256

| File | Before snapshot (`/tmp/attic-perf-a1-snapshot-135140`) | After |
| --- | --- | --- |
| `Attic/Services/CanvasStore.swift` | `b6d8652b0c5536cb91a4ed9d7f2eff56c2710dd46a916d147bf8b567901cee58` | `f2fe7e6c3ac5b1079a0f8db2890fb3e089af92c54fae87ccc977cb16f3558a76` |
| `Attic/Services/CanvasStorePersistence.swift` | `66225d12c3c3f303e9310bd7289ce49a824476583ed7e6c19e6f2ddc8047e87b` | `ad3301ecc210b53f49ecb433ead63edaf053cc9ed2bda90f1392e0e0e83a85f3` |
| `Attic/Services/CanvasStoreImages.swift` | `56972ea1e10bac5868308463d5f20431fa087831c3f73fc47ffaeecd13bcbdb4` | `6f893775cad8586b9415e2e76a7a7879b3bfcdf7306f6fe4eb3684da47ae8acf` |
| `Attic/Services/CanvasStoreSemanticObjects.swift` | `b0455f7d36a4075e8e8616a459764b6112fa2335fd182277e095c142a4966de6` | `4e44df676d62e4faa77dbe36417124bf6f5953c5f3abe0808dbe7063eec6b831` |
| `AtticTests/CanvasStoreTests.swift` | `eb7b48f7cf8c5e5ec1373ac66049efb25b2437f7ded6c53acd04b7838aa5ed79` | `fc11afe175cbf877db393fff92bdd9857ecd4987248abb6adbd7516e2c2de35a` |
| `AtticTests/CanvasPerformanceGateTests.swift` | `c54b4e29fa25510b60644eeff25c65e55871af8df2e8505f594addd908715e00` | `84ebbc443bd1efee5def134b524c51fb4b82eb4a1cb1805313b5dc7bf156f75c` |
| `Docs/Opus-Implementation-Report.md` | absent | this file |

Before hashes come from `/tmp/attic-perf-a1-snapshot-135140/SHA256SUMS`.

Snapshot integrity:
- All 23 snapshotted Canvas model/service/test files were compared back with `cmp`. Only the six files above differ.
- Existing edits by other writers in those files were preserved: my changes were applied on top of the snapshot, and `diff -u` against it shows only the PERF-A1 hunks.
- Diff size versus snapshot:

| File | Insertions | Deletions |
| --- | --- | --- |
| `CanvasStore.swift` | 111 | 9 |
| `CanvasStorePersistence.swift` | 54 | 29 |
| `CanvasStoreImages.swift` | 4 | 2 |
| `CanvasStoreSemanticObjects.swift` | 1 | 1 |
| `CanvasStoreTests.swift` | 184 | 2 |
| `CanvasPerformanceGateTests.swift` | 100 | 1 |

## Remaining limits

- **No `canvasID` index.** Adding one is a schema change, so it was not made. SQLite still scans the table for the predicate, but it no longer materialises other canvases' rows or payloads. Very large stores therefore still pay a per-query scan.
- **The selected canvas's own rows are still loaded twice per save.** The pending-context and fresh-context resolves are the durability/refresh architecture and were kept. Cost scales with the selected board's size, including its tombstoned rows and inline stroke payloads.
- **Selection fallback costs one extra content load**, and only when the selected canvas stopped being live.
- **Mutations of more than 512 ids** read the whole selected canvas instead of an `IN` list. That is still canvas-scoped.
- **The fetch counter** is a process-global static used only for test assertions. It is not thread-safe, which matches the existing image payload counter on the main-actor store.
- **Not performed:** native UI or preview verification. I did not launch, relaunch or touch the running `AtticChromeCheckpoint` preview (PID 14206). There was no Instruments or real user-store profiling and no CloudKit/iPhone validation. Nothing was committed, pushed or released, and no user data was reset.
- **Remaining native QA (Sol Low):** in a local-only preview, check drawing, erase/undo/redo, clear and undo clear, board switch, create, rename and delete. Also check a legacy store without a default board row, and responsiveness on a multi-board store with large boards.
