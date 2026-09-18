# SWE correctness review — PERF-A1 Canvas replica reads (independent)

Date: 2026-09-14
Checkout: `/Users/taha/Developer/attic-task-panels-v2`
Baselines: `/tmp/attic-perf-a1-snapshot-135140` (pre-PERF-A1), `/tmp/attic-perfa1-fixes-snapshot-141831` (post-implementation, pre-fixes)
Reviewed documents: `Docs/Opus-Implementation-Report.md`, `Docs/Sol-Canvas-PERFA1-Review.md`, `Docs/Opus-PERFA1-Review-Fixes.md`
Method: source/read-only evidence inspection against both snapshots — no builds, no test execution, no source edits, no UI. The shared dirty checkout was left untouched except this file.

## Verdict

The PERF-A1 predicate change is semantically equivalent to the previous fetch-all-then-filter behavior on every path I traced, and Sol's three findings are correctly resolved by the follow-up fixes. I found no confirmed correctness defects.

**REVIEW_PASS**

## Snapshot and diff integrity (verified independently)

- Current SHA-256 of all 23 snapshotted files was recomputed. Every file matches either the pre-PERF-A1 snapshot or the exact "after" hash claimed in `Docs/Opus-PERFA1-Review-Fixes.md` — nothing else drifted.
- `git diff` vs `/tmp/attic-perf-a1-snapshot-135140` shows only the claimed hunks: `CanvasStore.swift` (+111/−9 net), `CanvasStorePersistence.swift` (+54/−29), `CanvasStoreImages.swift` (+4/−2), `CanvasStoreSemanticObjects.swift` (+1/−1), `CanvasStoreTests.swift` (+268/−2 total across both rounds), `CanvasPerformanceGateTests.swift` (+106/−1 total).
- `git diff` vs `/tmp/attic-perfa1-fixes-snapshot-141831` shows exactly the fixes report's claims: `CanvasStore.swift` +14/−1 (`#if DEBUG` counter gating), `CanvasStoreTests.swift` +84/−0 (pending-context test), `CanvasPerformanceGateTests.swift` +6/−0 (`#else` skip), `TaskImageTests.swift` +4/−1 (assertion fix). `CanvasStorePersistence.swift`, `CanvasStoreImages.swift`, `CanvasStoreSemanticObjects.swift`, `TaskDragPayload.swift` are byte-identical to the fixes snapshot.
- `git diff --check` (tracked) and `git diff --no-index --check` (untracked test files) report no whitespace errors.
- All three modified/added test files were already explicit `PBXBuildFile` members of `AtticTests` — no project regeneration needed. Verified against `project.pbxproj`.

## Mechanism verification (source-traced, not endorsed)

### 1. Predicate equivalence of the content load

`CanvasStoredReplicas.load(from:contentCanvasID:)` (`CanvasStore.swift:150-211`) fetches all `CanvasBoardItem` rows unpredicated (required: the board list spans canvases) and scopes strokes/images/semantic objects to `canvasID == <requested>`. The old code fetched all rows and the only cross-canvas consumer of that superset was the legacy-default check — now reimplemented as `hasUnboardedLegacyDefaultContent`. Every remaining consumer in `resolveCanvasPresentation` filters `replica.canvasID == resolvedSelectedCanvasID`, so the predicate can only ever return the rows the old filters kept. Tombstoned rows and duplicate physical replicas of the requested canvas are still fetched (no `tombstoned` predicate), so winner resolution is unchanged.

### 2. `hasUnboardedLegacyDefaultContent` is equivalent to the old `hasLiveLegacyDefaultContent`

- Old (`snapshot` `CanvasStorePersistence.swift:137-148`): `contains { $0.canvasID == logicalBoardID && !$0.tombstoned }` over all-rows of each entity type, OR'd.
- New (`CanvasStore.swift:178-209`): if a physical default board row exists (any state, including tombstoned) the flag stays `false` — which is consistent because `resolveCanvasPresentation`'s `boardWinnerByID[logicalBoardID] == nil` guard blocks the virtual append in exactly the same case (`CanvasStorePersistence.swift:141-143`). When no physical default row exists: loading the default canvas checks the already-fetched rows (`canvasID == default` subset, same predicate); loading another canvas answers the identical question via `fetchCount(canvasID == default && !tombstoned)` for strokes → images → semantic objects with `||` short-circuit. Same three-way OR, same pending-context semantics (see §3).

### 3. Pending insert/move/tombstone visibility

`save()` resolves on the pending context before `persist` (`CanvasStorePersistence.swift:31`), so correctness depends on predicated reads observing unsaved changes. The durable test `testCanvasScopedReplicaReadsSeeUnsavedChangesInTheContext` (`CanvasStoreTests.swift:963-1040`) is genuinely discriminating:

- Pending insert on B, pending `canvasID` move A→B, pending tombstone on the default canvas, all on `store.context` (the same context `save()` resolves from).
- Asserts predicated `fetch` (via production `CanvasStoredReplicas.load`), `fetchCount` (via the production `hasUnboardedLegacyDefaultContent` count path and a direct count), and `idList.contains` (via production `store.storedStrokeReplicas`) — before `context.save()` and again on a fresh post-save context.
- A separate `ModelContext(container)` still sees committed state (B = `[existing]`, flag `true`), proving the pending assertions could not pass against persisted data.

I verified the assertions would each fail if predicates saw only committed state: `load(B)` would return `[existing]` instead of `{existing, inserted, moving}`; the flag would stay `true` instead of flipping to `false`; `load(A)` would still contain `moving`. The move-out direction is also covered (`staying` alone remains on A).

Residual gap (non-blocking, symmetric): the test exercises `CanvasStrokeItem` only; image and semantic predicates are the identical three shapes through the same helpers. A pending *insert* into the default-canvas count path is also not directly covered — but that form cannot arise in production, since inserts always target `selectedCanvasID`, and `selectedCanvasID == default` takes the loaded-rows branch rather than the count branch.

### 4. Selection fallback

`resolveCanvasPresentation` reloads via `loadReplicas(sourceContext, resolvedSelectedCanvasID)` exactly when `resolvedSelectedCanvasID != selectedCanvasID` (`CanvasStorePersistence.swift:163-168`), before `strokeReplicas`/`imageReplicas`/`semanticReplicas` are bound (lines 169-173). The boards re-resolve identically because the reload uses the same context; `boardWinnerByID`, `resolvedBoards`, `resolvedGeneration` are computed before the reload and remain valid. `replicas.boards` and `replicas.hasUnboardedLegacyDefaultContent` are not consumed after the reload. `testRefreshAfterSelectedCanvasIsDeletedElsewhereShowsTheFallbackCanvasContent` covers the realistic trigger (external tombstone → `refresh()` → fallback to the default canvas, next mutation lands there). The pending-context variant (selected canvas tombstoned inside the same save) is effectively unreachable today — `deleteCanvas` retargets `selectedCanvasID` before `save()` — and the branch is harmless either way.

### 5. Duplicate IDs across canvases

`storedStrokeReplicas`/`storedImageReplicas` scope to `canvasID == selectedCanvasID`, identical to the old in-memory filter. Mutations therefore touch every physical replica *on that canvas* and leave same-UUID replicas on other canvases divergent — matching the project contract (dedupe for presentation only). `testSameIDReplicaOnAnotherCanvasIsNotShownOrRewrittenBySelectedCanvasMutations` proves both halves: the two local replicas advance (v2 then v3) while the foreign replica holds v7, and selecting the other canvas shows its own content. `importImages` is scoped to `target.canvasID` (which may differ from the selection) exactly as before (`CanvasStoreImages.swift:87-90`).

### 6. >512 identifier fallback

`replicaIdentifierPredicateLimit = 512`; at or below it the predicate is `canvasID == selected && idList.contains($0.id)` (SQL `IN`, safely under SQLite's bound-variable limit); above it, the predicate is `canvasID == selected` with the id filter applied in memory — every selected-canvas replica is still found, without an oversized `IN` list. `testDeletingMoreStrokesThanTheIdentifierPredicateLimitTouchesEveryReplica` drives 532 ids × 2 replicas through delete and restore and verifies all 1,064 local replicas plus the untouched cross-canvas same-id replica. The image helper is structurally identical (the >512 durable test covers strokes only — symmetric, non-blocking).

### 7. Rollback, post-save refresh, undo

`save()`/`discardPendingChanges`/`reloadCanvas` structure is unchanged: pending resolve → `persist` → fresh-context reload → `applyCanvasPresentation`, with `context.rollback()` and persisted-presentation fallback on failure. All paths consume `loadReplicas` results identically; nothing in the diff alters rollback or context replacement. `CanvasReplicaReadGate.load` was updated to the two-argument seam and the four existing post-save-reload-failure tests (`CanvasStoreTests.swift:437,475,506,544`) still exercise it. Undo/redo flows through `setDeleted`/`restoreBoardContents`, covered above.

### 8. Backfill predicate

`backfillLegacyImagePayloadMetadata` now fetches only `contentDigest == ""` rows. `backfillPayloadMetadataIfNeeded()` (`CanvasImageItem.swift:169-181`) guards on `contentDigest.isEmpty` and mutates only `encodedByteCount`/`contentDigest`, so the predicate selects exactly the mutable set; empty-payload legacy rows still fault and return false, as before.

### 9. `storedBoardReplicas(matching:)` and `tombstoneAllContent`

Board lookup is predicated on `id` only (no tombstone/canvas scoping) — identical to the old in-memory filter, including matching tombstoned rows (required by `ensureSelectedBoardReplicaExists`'s empty check). `tombstoneAllContent(canvasID:)` predicates strokes and images on the *deleted* canvas parameter — correctly independent of `selectedCanvasID` — and `tombstoneSemanticObjects` was already canvas-scoped.

### 10. Caller sweep for hidden regressions

Every `FetchDescriptor<Canvas*>` site in `Attic/` is one of the reviewed helpers (15 sites across the four files). No other production code reads canvas replica rows — `CanvasStoreCloudSync` (dormant under `ATTIC_LOCAL_ONLY`), `CanvasSession`, and the panel views consume published snapshots only. `CanvasPanelContent` uses only the selected canvas's published arrays (e.g. `contentCountLabel`), so no UI depended on the removed whole-table reads. All `stored*` callers (`addStroke`, `setDeleted`, `stageStrokeRestore`, `updateImage`, `setImageDeleted`, `stageImageRestore`, `importImages`, `renameCanvas`, `deleteCanvas`, `clearBoard`, `ensureSelectedBoardReplicaExists`, `tombstoneAllContent`, semantic mutations) were traced — each received the same row set as under the old filters.

### 11. `#if DEBUG` instrumentation gating (Sol P1)

Verified against `project.pbxproj`: the project-level `Debug` and `Local` configurations set `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`; no `Release` block sets it, and `ENABLE_TESTABILITY = YES` exists on the Debug/Local project blocks. The counter enum and both counter call sites are inside `#if DEBUG`; non-`DEBUG` helpers are plain `fetch`/`fetchCount`. The gate test keeps its name under `#else` and throws `XCTSkip`, so a non-`DEBUG` run reports a loud skip rather than silently dropping the guard. Supplied evidence corroborates: `perfa1-fixes-nodebug-focused.log` shows the skip at `CanvasPerformanceGateTests.swift:685` and 3 executed/1 skipped/0 failed; the report's `nm` symbol counts (0 in Release app and non-DEBUG binaries, 24 in the DEBUG host dylib) are consistent with the structure.

### 12. `TaskImageTests` fix (Sol P1)

The assertion now expects `suggestedName == "Picture"` and adds `url.lastPathComponent == "Picture.png"` inside the `loadFileRepresentation` completion — matching the SDK contract (the provider appends the type extension on the delivered copy; a `.png` suffix in the suggestion would yield `Picture.png.png`). The added assertion is non-vacuous: `XCTAssertNotNil(url)` already passed in the same closure before the basename check runs.

## Test quality assessment

The durable tests are real regression guards, not tautologies:

- The pending-context test (§3) fails if any of the three predicate forms ignores unsaved changes, in either direction, and re-verifies post-save.
- The performance gate binds rows to `3 × (boards + selected strokes)` — measured post-fix values (29/51/49) sit well under it while it stays far below the 620-row other-canvas floor, and it asserts `bound < unselectedRowCount` so the gate cannot silently become vacuous. It also asserts other canvases' rows were not rewritten (`mutationVersion == 1`, 60 tombstones) and still present on selection.
- The >512 test reaches every replica above the limit; the legacy test covers stroke/image/semantic/tombstoned-only content across open, switch, mutation, and reopen; the fallback test covers external deletion plus a subsequent mutation.

Minor test nits (informational, not defects): the `measure`-loop bound in the gate is evaluated once after the loop, when `strokes.count` has grown — slightly more permissive than a per-iteration bound, though still far under the regression threshold; and `fetchCount` increments `CanvasReplicaFetchCounter.fetches` without adding to `rows`, so the row bound cannot see count queries — appropriate, since counts do not materialise rows.

## Report claims corroborated from supplied artifacts (not independently executed)

- `perfa1-fixes-focused.log`: 7 tests, 0 failures (DEBUG), including the pending test, gate, all four PERF-A1 correctness tests, and the drag test.
- `perfa1-fixes-nodebug-focused.log`: 3 executed, 1 skipped (gate), 0 failures.
- `perfa1-fixes-full-unit.log`: 799 executed, 4 skipped, 0 failures — the earlier `perf-a1-full-unit.log` shows the deterministic `TaskImageTests.swift:334` failure resolved.
- `perf-a1-canvas-all.log`: 183 Canvas tests, 0 failures.
- The mutation-check and `nm`/Release-compile claims are consistent with the reviewed source structure; I did not rebuild or rerun them (a dedicated verifier owns execution).

## Residual limitations (non-blocking)

- Pending-change coverage is strokes-only; image/semantic predicates and the image >512 path are covered by symmetry, not dedicated tests.
- The row-count gate guards only `DEBUG`/`Local` test runs — which is every current test configuration — and reports a visible skip otherwise.
- No `canvasID` index: predicates still scan the table; they no longer materialise other canvases' rows or payloads. Schema change deliberately out of scope.
- In stores with no physical default board row, every load for a non-default canvas pays up to three `fetchCount` queries; cheap relative to row materialisation, and self-eliminating once the default board is materialised.
- `fetchCanvasReplicas`/`countCanvasReplicas` are generic `ModelContext` helpers; future non-Canvas callers in `DEBUG` would pollute the counter. No such callers exist today.
- `CanvasReplicaFetchCounter` remains non-isolated — now test-only (DEBUG), matching the scope of the existing image payload counter.
- Not assessed here (per task boundary): builds/tests were not executed by this reviewer; no native UI, Instruments, Release-runtime timing, CloudKit, or iPhone validation — the native QA checklist in `Docs/Opus-Implementation-Report.md` remains open.

REVIEW_PASS
