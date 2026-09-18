# SWE efficiency review — PERF-A1 Canvas replica reads

Date: 2026-09-14
Checkout: `/Users/taha/Developer/attic-task-panels-v2`
Branch/HEAD: `codex/attic-task-panels-v2` / `ae6418c1af690e29d15a20344cdb9765a23d3f85` (dirty shared checkout, nothing committed)
Baselines: `/tmp/attic-perf-a1-snapshot-135140` (pre-PERF-A1), `/tmp/attic-perfa1-fixes-snapshot-141831` (pre-review-fixes)
Reviewed inputs: `Docs/Opus-Implementation-Report.md`, `Docs/Sol-Canvas-PERFA1-Review.md`, `Docs/Opus-PERFA1-Review-Fixes.md`, `Docs/Rolling-Performance-Audit.md` (PERF-A1 entry), `Docs/SWE-PERFA1-Verification-Review.md`
Scope: independent production-efficiency and code-quality review. Read-only source/artifact inspection only — no builds, no test execution (the dedicated verifier owns reruns), no native UI, no preview interaction (the running `AtticChromeCheckpoint` preview was not touched), no source edits, no commit/push/release. This file is the only file I own.

## Verdict

The PERF-A1 predicate work and the three review fixes hold up under independent
efficiency-focused inspection. The row-reduction claims are internally
consistent to the row, the counter is genuinely absent from Release hot paths
(confirmed at the binary level, not just the source level), and the remaining
scaling costs are documented and bounded. No defects found; the observations
below are non-blocking.

## Independent verification — counter absent from Release

Sol's P1 asked for the counter out of shipped hot paths. Verified end to end:

- **Source:** `CanvasReplicaFetchCounter` is wrapped in `#if DEBUG … #endif`
  (`Attic/Services/CanvasStore.swift:66-90`). Both `ModelContext` helpers keep
  their non-DEBUG path as a bare `return try fetch(descriptor)` /
  `return try fetchCount(descriptor)` (`CanvasStore.swift:95-117`) — semantically
  identical to a direct call.
- **Build settings:** `project.pbxproj` sets
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` exactly twice — the `Debug`
  configuration block (line 1497) and the `Local` block (line 1869). No
  `Release` block defines it.
- **Release compile flags:** `/tmp/attic-perfa1-fixes-release-build.log` shows
  the `swiftc` invocation with `-DATTIC_LOCAL_ONLY` and no `-D DEBUG`
  (`-O -whole-module-optimization`), both architectures.
- **Supplied binary symbols (my own `nm`/`strings` runs):**

  | Binary | `CanvasReplicaFetchCounter` symbols |
  | --- | --- |
  | Release `Attic.app/Contents/MacOS/Attic` | **0** (`nm`, `nm -a`, `strings` all 0) |
  | non-DEBUG `AtticUnitTestHost` / `.debug.dylib` / `AtticTests` | **0** each |
  | DEBUG `AtticUnitTestHost.debug.dylib` | **24** (control) |

- The helpers themselves leave **0** `CanvasReplicas`-named symbols in the
  Release binary — they inlined completely, so the instrumentation seam is
  literally free in production. The non-DEBUG host dylib retains 2
  `CanvasReplicas` symbols (un-inlined helper instantiations) with 0 counter
  symbols, consistent with `#else` compilation.
- The only test references sit inside `#if DEBUG` / `#else XCTSkip(…)`
  (`AtticTests/CanvasPerformanceGateTests.swift:586-687`), so non-DEBUG test
  builds compile and report a visible skip rather than silently dropping the
  gate. The verifier's non-DEBUG rerun reproduced that skip plus 6/6 passes.

## Measured evidence — validated

Probe logs (`/tmp/attic-offline-xctest/perf-a1-probe-{baseline,after}.log`, same
seeded on-disk shape, counter-instrumented host both times):

| Operation | Fetches before → after | Rows before → after |
| --- | --- | --- |
| `addStroke` | 10 → 10 | 1,841 → 29 |
| `setDeleted` (3 ids) | 9 → 9 | 1,869 → 51 |
| `clearBoard` | 9 → 9 | 1,251 → 49 |
| `selectCanvas` (300-stroke board) | 5 → 5 | 624 → 303 |

The after-counts are not just "small" — they reconstruct exactly from the
mechanics, which makes them self-consistent rather than lucky:

- `addStroke` = board point-query (1) + id lookup (0, new id) + pending resolve
  (3 boards + 11 strokes) + fresh resolve (3 + 11) = **29**.
- `setDeleted`/`clearBoard` after the measure loop ≈ 21 strokes on the selected
  board: 3 + (3 + 21) + (3 + 21) = **51**; 1 + 24 + 24 = **49**.
- `selectCanvas` = backfill `contentDigest == ""` fetch + boards + strokes +
  images + semantic = 5 fetches; 3 + 300 = **303** rows.

Timing: `addStroke` median 44.4 ms → 2.25 ms; the payload probes show an
unpredicated 621-row fetch costs 11–12 ms while `payload.count` on already-
fetched rows costs 0.3–1.0 ms — consistent with the report's conclusion that
payload cost was row-materialisation of other canvases, and that the audit's
suggested scalar payload column was correctly declined (a schema change with no
measured benefit). `CanvasStrokeCacheEntry` still compares
`payloadByteCount == replica.payload.count` on rows that are loaded anyway.

The pending-context premise (predicated `fetch`, `idList.contains`, and
`fetchCount` observe unsaved inserts, `canvasID` moves, and tombstones) was
probe-verified (`onB=2 byIDs=2 liveOnACount=0 liveOnAFetch=0`) and is now a
durable test, `testCanvasScopedReplicaReadsSeeUnsavedChangesInTheContext`
(`AtticTests/CanvasStoreTests.swift:963-1040`), with a real discrimination check:
a second context still sees pre-change state before `save()`.

## Correctness review of the predicate semantics

- **Legacy default discovery** (`CanvasStore.swift:178-209`,
  `CanvasStorePersistence.swift:141-145`): `load` early-returns
  `hasUnboardedLegacyDefaultContent = false` whenever *any* physical board row
  with `logicalBoardID` exists. That is exactly the consume condition, because
  `boardWinnerByID` is populated from all board replicas including tombstoned
  ones — `boardWinnerByID[logicalBoardID] == nil` ⟺ no such row exists. A
  tombstoned default board therefore still suppresses the virtual board,
  matching the old "explicit tombstone wins" rule. The two computation branches
  (in-memory over loaded rows when `canvasID == defaultID`; `fetchCount` with
  `canvasID == defaultID && !tombstoned` otherwise) are predicate-equivalent.
- **Winner determinism:** every `prefers*` comparator
  (`CanvasStoreReplicaResolution.swift:72-188`) ends in a `persistentModelID`
  string tiebreak — a total order over distinct physical rows — so predicated
  fetch order cannot change winner selection.
- **Mutation fan-out:** `storedStrokeReplicas`/`storedImageReplicas`
  (`CanvasStorePersistence.swift:501-543`) keep the in-memory
  `canvasID`/`ids` filter after the predicated fetch, so every physical replica
  of each id on the selected canvas is still found. The ≤512-id `IN` list is
  well under SQLite's 999 bound-variable floor; the >512 fallback stays
  canvas-scoped (verified by the 532-id test, including the foreign same-id row
  left untouched at version 1).
- **`backfillLegacyImagePayloadMetadata`** (`CanvasStorePersistence.swift:458`):
  `contentDigest == ""` matches `backfillPayloadMetadataIfNeeded()`'s
  `contentDigest.isEmpty` guard exactly (`CanvasImageItem.swift:170`); rows with
  a digest are no longer materialised at all.
- **`importImages`** (`CanvasStoreImages.swift:86-99`): the target-canvas
  predicate reproduces the old `canvasID == target.canvasID` filter; all uses of
  `groupedRows` (`highestUnaffectedZ`, replica reuse) were already
  target-scoped.
- **Fallback reload** (`CanvasStorePersistence.swift:163-168`): when the
  requested canvas is not live, one extra `loadReplicas` runs for the resolved
  canvas on the *same* context; the first load's `boardReplicas` remain the
  resolution input, which is sound since a second read of one context resolves
  identically.
- No replica read bypasses the helpers: all 15 `FetchDescriptor<Canvas…>` sites
  in `Attic/` route through `fetchCanvasReplicas`/`countCanvasReplicas`;
  `Attic/Canvas`, `Attic/Views`, `CanvasStoreCloudSync`,
  `CanvasStoreReplicaResolution` contain no `FetchDescriptor`/`@Query`/
  `fetchCount` on replica types.

## Remaining scaling costs (all bounded, none hidden)

- **No `canvasID` index** — acknowledged in the report and unchanged. Each
  predicated fetch still scans the table at the SQLite level, but non-matching
  rows' overflow payloads are not touched and no model objects are
  materialised. This is the honest residual: O(total rows) page reads, not
  O(total payload bytes).
- **Boards are fetched unpredicated every load** — required: board resolution
  and duplicate-replica fan-out need every board row, tombstoned or not. Cost
  is O(board rows), small by design.
- **Legacy-default counts**: when no physical default board row exists, up to 3
  `fetchCount` scans per load (strokes → images → semantic, short-circuiting),
  ×2 loads per save. Non-materialising, legacy stores only; the common case
  (physical default board present) adds zero queries.
- **Double-resolve per save** (pending context + fresh context) is unchanged
  architecture; each half now reads only the selected canvas.
- **`storedSemanticReplicas(canvasID:)`** in `updateSemanticObject`,
  `deleteSemanticObject`, `stageSemanticRestore` still fetches all of the
  canvas's semantic rows then filters by id in memory — pre-existing shape,
  unchanged by this diff, and semantic-object counts are small.
- **`backfillLegacyImagePayloadMetadata`** still issues one
  `contentDigest == ""` fetch per `refresh()` — pre-existing cadence, now
  predicated rather than full-table.
- **Fallback reload** re-fetches boards (unused) — one extra load, only when the
  selected canvas died. Rare and bounded.

## Allocations, global state, threads

- New heap work: `idList = Array(ids)` (≤512 UUIDs ≈ ≤8 KB) per mutation lookup
  and the descriptor objects — trivial against what was removed.
- `#Predicate` captures are value types (`UUID`, `[UUID]`, `""`) — no shared
  reference capture, no retain risk.
- `CanvasReplicaFetchCounter`'s non-atomic statics are DEBUG-only and reached
  only through `@MainActor` `CanvasStore` paths or tests; `CanvasStoredReplicas.load`
  is `nonisolated static` but inherits the caller's actor. No Release exposure,
  no new thread hazard. Not adding `@MainActor` to the helpers is the right
  call — it would have been a larger, riskier change for test-only state.
- `static let replicaIdentifierPredicateLimit` — immutable `Int`, fine.

## Observations (non-blocking; no changes requested)

1. **[P3, pre-existing]** `CanvasImagePayloadAccessCounter`
   (`Attic/Models/CanvasImageItem.swift:12-22`) remains unconditionally compiled
   and still increments a process-global in Release — `nm` shows its `count`
   accessor symbol in the Release binary. It predates PERF-A1 (identical in the
   baseline snapshot), Sol explicitly waived extending the DEBUG-gate to it, and
   its cost is one `&+=` per external-storage fault on the already-rare
   `materialisedPayload` path. Worth noting only so "counter absent from
   Release" is understood to mean the *new* counter; gating it would be a
   consistency cleanup, not a fix for this work.
2. **[P3]** `CanvasReplicaFetchCounter.fetches` is written but never asserted —
   the gate bounds `rows` only. A future regression adding redundant fetches
   without extra rows would not trip it. Noted in
   `SWE-PERFA1-Verification-Review.md` as well; the probe showed fetch count
   unchanged (10 → 10).
3. **[P3]** The measure-loop bound evaluates `store.strokes.count` after the
   loop (`CanvasPerformanceGateTests.swift:658`), mildly lenient for early
   iterations; `XCTAssertLessThan(bound, unselectedRowCount)` keeps the bound
   below the regression threshold, so discrimination is intact.
4. **[P3]** The durable pending-context test exercises strokes; the image,
   board, tombstone-all, and semantic pending-visibility paths rest on the same
   predicate forms by symmetry. Acknowledged in the fixes report's limits.
5. **[P3]** Non-DEBUG configurations run the perf gate as a visible `XCTSkip`,
   not a guard — correct by design since every current test configuration
   (`Local`/`Debug`) sets `DEBUG`.

## Limitations of this review

Read-only source/artifact inspection: I did not build, run tests, or profile;
the dedicated verifier's reruns (`swe-perfa1-focused`/`nodebug`/`full`,
799/4-skipped/0-failed) cover execution. No Instruments, no real user store, no
Release runtime timing (symbol-level absence only — verified). No native UI,
preview interaction, CloudKit, or iPhone validation; the native-QA checklist in
`Docs/Opus-Implementation-Report.md` remains open and unclaimed here.

REVIEW_PASS
