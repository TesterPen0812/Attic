# Deep Audit — Canvas Domain

**Date:** 2026-09-14
**Auditor:** Canvas-domain lead (read-only source audit)
**Source root:** `/Users/taha/Developer/attic-task-panels-v2` (worktree dirty with unrelated user edits — preserved untouched)
**Domain:** entire Canvas engine — input state machine, viewport/coordinates/zoom/pan, pencil precision, eraser, shapes/hit-testing/resize, selection, images/file drops, undo/redo, board lifecycle and persistence boundaries, toolbar wiring, accessibility — traced across session, panel, native surfaces, store, models, and tests.

This audit is source-verified. **No build, test run, UI host, or runtime measurement was performed** — every finding below is either logically established by the code (marked *confirmed*) or rests on mechanism alone (marked *structural* / *plausible*). Findings already documented by the sibling runtime audit (`DeepAudit-Runtime-2026-09-14.md`, RUN-001…RUN-010) are cross-referenced rather than re-litigated; this report owns the canvas-specific evidence and adds the interaction/functional details that audit did not cover.

---

## 1. Coverage matrix

| Subsystem | Files | State |
|---|---|---|
| Core types / geometry / hit-testing | `CanvasTypes`, `CanvasViewport`, `CanvasImageTypes` | ✅ audited |
| Input machine | `CanvasInputStateMachine` (idle/drawing/erasing/panning; 12 000-pt cap + compaction) | ✅ audited |
| Session engine | `CanvasSession` (tools, history, imports, text drafts, view-state persistence) | ✅ audited |
| macOS surface | `CanvasSurface`, `CanvasSurfaceMac`, `CanvasSurfaceMacHelpers`, `CanvasSurfaceInteraction`, `CanvasSemanticInteraction` | ✅ audited |
| iOS surface | `CanvasSurfaceIOS` (deferred platform) | ✅ dormant-checked |
| Rendering / caches | `CanvasSurfaceRenderer` (path cache, decode cache, hit-test order), `CanvasSemanticRenderer` (framesetter cache) | ✅ audited |
| Semantic objects | `CanvasSemanticObject`, `CanvasSemanticInteraction`, `CanvasStoreSemanticObjects` | ✅ audited |
| Images / drops | `CanvasImageImporter`, `CanvasImageTypes`, `CanvasImageExportDocument`, pasteboard/file-promise paths | ✅ audited |
| Stroke codec | `CanvasStrokeCodec` (versioned JSON archive, bounded) | ✅ audited |
| Store | `CanvasStore` + `…Boards`, `…Strokes`, `…Images`, `…Lifecycle`, `…Persistence`, `…ReplicaResolution`, `…SemanticObjects`, `…CloudSync` | ✅ audited |
| Models | `CanvasBoardItem`, `CanvasStrokeItem`, `CanvasImageItem`, `CanvasSemanticObjectItem` | ✅ audited |
| Toolbar / commands | `CanvasControls`, `CanvasPanelContent`, `CanvasEditCommandRoute` | ✅ audited |
| Accessibility | `CanvasAccessibilityObjectElement`, a11y wiring in `CanvasSurfaceMac*` | ✅ audited |
| Tests | `CanvasDomainTests`, `CanvasSessionTests`, `CanvasStoreTests`, `CanvasImageTests`, `CanvasRenderCacheTests`, `CanvasPerformanceGateTests`, `CanvasPrecisionTests`, `CanvasDocumentTests`, `CanvasUITests`, `CanvasMobileUITests` (≈7 600 lines) | ✅ cross-checked against source (not run) |
| Design doc | `CANVAS-DESIGN.md` | ✅ audited (found stale — CVX-05) |

Every `.swift` file under `Attic/Canvas/`, every `Canvas*` file under `Attic/Services/` and `Attic/Models/`, the canvas panel view, the edit-command route, and all canvas test files were read in full. Cross-domain callers (`AtticPanelView`, `AtticPanelController`, `AppCoordinator`, `AtticPanel`) were traced for every `cancelActiveInteraction`/session entry point.

---

## 2. Confirmed defects

### CVD-01 — Routine zoom clicks and section switches tear down the whole native bridge and cancel in-flight image imports — **High**, confirmed mechanism

**Mechanism.** `CanvasSurface` binds the native view's SwiftUI identity to `session.interactionCancellationEpoch` (`Attic/Canvas/CanvasSurface.swift:23`). `CanvasSession.cancelActiveInteraction()` unconditionally flushes view state **and** bumps the epoch (`Attic/Canvas/CanvasSession.swift:1416-1419`). The bump forces `dismantleNSView` → `deactivateRepresentation()` (`Attic/Canvas/CanvasSurfaceMac.swift:1253-1261`), which:

- commits or suspends any open text editor,
- disables gesture recognizers and cancels interaction,
- **cancels all file-promise batches** (`cancelFilePromiseBatches`),
- **cancels all session-level image-import batches** via `onCancelImageImportBatches` → `session.cancelAllImageImportBatches()` (wired at `CanvasSurfaceMac.swift:87-88`, session at `CanvasSession.swift:356`),
- destroys the per-view `CanvasPathCache`, 256 MB `CanvasImageDecodeCache`, `CanvasImageDisplayCache`, `CanvasSemanticRenderCache`, and the accessibility element map (`CanvasSurfaceMac.swift:223-261, 281, 306-309`),
- replaces `onViewportChange` with a no-op.

**Callers that trigger this without any lifecycle need** (full list — all verified):

| Caller | File:line | Legitimate? |
|---|---|---|
| Zoom In / Zoom Out menu buttons | `CanvasPanelContent.swift:397-399` (`zoom(by:)` calls `cancelActiveInteraction()` before `session.zoom`) | **No** — `session.zoom` itself only sets the viewport (`CanvasSession.swift:1407-1414`); native pinch/scroll zooms never bump the epoch |
| Section switch away from Canvas | `AtticPanelView.swift:809` | Partially — the section removal discards the view anyway; the bump adds a redundant rebuild during the transition |
| Panel hide | `AtticPanelController.swift:469` (immediately after the lighter `hostingView.cancelActiveInteraction(reason: .explicitHide)` at :468) | Partially — same redundancy; also aborts imports for the app's most frequent gesture |
| `selectCanvas` / `createCanvas` / `deleteSelectedCanvas` | `CanvasSession.swift:498, 521, 544` | Legitimate on success; on **failure** they still fire (CVD-02) |
| External semantic revision | `CanvasSession.swift:1687` | Legitimate |
| App stop/termination | `AppCoordinator.swift:375, 392` | Legitimate |

**Expected vs actual.** Zooming, hiding the panel, or switching sections should interrupt transient input only — `interaction.cancel()` on the live view already does that (`CanvasSurfaceInteraction.swift:199-204`). Actual: the entire native surface is dismantled and rebuilt, and **any image import in flight is silently cancelled** (batch items record `.cancelled` in the progress HUD). The comment at `CanvasSurface.swift:20-22` says the rebuild is "only for an explicit lifecycle cancellation" — the callers contradict the intent.

**Impact.** (a) Functional: an image drop or file-promise batch in flight is aborted by a Zoom click, panel hide, or section switch — user-visible lost work with only a "cancelled" progress entry. (b) Performance: every rebuild re-creates recognizers, tracking areas, drag-type registration, and re-enqueues all visible image decodes (≤3 workers, `CanvasSurfaceRenderer.swift:226-238`). Overlaps RUN-001/RUN-002 in the runtime audit; this report adds the confirmed zoom-button trigger and the import-cancellation edge it implies.

**Smallest fix.** Decouple "flush view state + discard ink" from "destroy the view": give `cancelActiveInteraction()` a `teardown: Bool` (or split it into `interruptInteraction()` vs `cancelInteractionAndRebuild()`), call the non-tearing variant from `zoom(by:)`, panel-hide, and section-switch sites, and reserve the epoch bump for board switch/create/delete and termination. Also move `onCancelImageImportBatches()` out of `deactivateRepresentation()` so a rebuild doesn't abort session-owned imports.

**Verification.** Unit: `startImageImportBatch` with a slow injected `prepareImage`, call `zoom(by:)`-equivalent, assert batch completes and `interactionCancellationEpoch` is unchanged. UI: drop several images, click Zoom In mid-import — imports should finish.

---

### CVD-02 — Failed `selectCanvas`/`createCanvas`/`deleteSelectedCanvas` still wipe undo history and tear down the view — **Medium**, confirmed

**Mechanism.** `CanvasSession.selectCanvas` (`CanvasSession.swift:495-505`):

```swift
let succeeded = store.selectCanvas(id)
synchronizeFromStore(clearHistory: true)   // unconditional
```

`createCanvas` (:508-528) is identical: `cancelPendingPlacement()`, `cancelActiveInteraction()` (epoch bump → CVD-01 teardown), then `synchronizeFromStore(clearHistory: true)` regardless of `store.createCanvas` returning `nil`. `deleteSelectedCanvas` (:542-553) cancels the interaction unconditionally too (its `clearHistory` is success-gated, unlike the other two).

**Reachable failure paths** (all in `CanvasStoreBoards.swift`): `selectCanvas` fails when the id isn't a live board (:9-12); `createCanvas` fails on a whitespace-only or >80-char name (`normalizedCanvasName`, `CanvasStoreReplicaResolution.swift:232-236`), `sortIndex` exhaustion, or a save failure (:45). The New Canvas alert's Create button is always enabled (`CanvasPanelContent.swift:226-234`), so a whitespace name is a one-click repro.

**Expected vs actual.** `renameSelectedCanvas` shows the intended pattern — `if succeeded { clearHistory() }` (:531-537). Actual: a failed selection/creation still clears the undo/redo stacks, cancels in-flight imports (via the epoch teardown), and resets selection — the user loses undoability over an operation that changed nothing.

**Impact.** Silent loss of undo history (session-scoped, so no persisted data loss) plus the CVD-01 side effects on a pure validation failure.

**Smallest fix.** Gate `synchronizeFromStore(clearHistory:)` and `cancelActiveInteraction()` on the store result — or at minimum pass `clearHistory: succeeded`. For `createCanvas`, validating the name in the alert (`disabled` on the Create button) removes the most reachable trigger.

**Verification.** Unit: `session.createCanvas(name: "   ")` → assert `undoCommandCount` unchanged and `interactionCancellationEpoch` unchanged.

---

### CVD-03 — `retryFailedImageDecodes()` retries only the first failed image — **Low-Medium**, confirmed

**Mechanism.** `CanvasSession.swift:376-382` finds `images.first(where: { failedImageIDs.contains($0.id) })` and calls `retryImageDecode(first.id)` — despite the doc comment "Retries every image whose decode failed" (:372) and the plural banner it feeds (`imageRecoveryNotice`, `CanvasPanelContent.swift:270-307`; label "N images could not be displayed", Retry at :279-281).

**Expected vs actual.** A "Retry" on a banner reporting *N* failures should requeue all N. Actual: one image retries; the banner stays up (N−1 still failed) and each click repairs exactly one more. Functional but wrong-shaped; users may not click N times.

**Smallest fix.** Loop over all failed IDs (`for id in failedImageIDs { retryImageDecode(id) }`) — `imageDecodeRetryRequest` carries a single imageID, so either extend it to a set or emit one request per id consumed by the configure pass.

**Verification.** Unit: seed two failed decodes (inject a failing decoder in `CanvasImageDecodeCache`), call `retryFailedImageDecodes`, assert both leave `.failed` state.

---

### CVD-04 — Retry for an off-screen failed image silently no-ops — **Low-Medium**, confirmed

**Mechanism.** The session accepts any retry for an image present on the board: `retryImageDecode` guards only `images.contains(id)` (`CanvasSession.swift:367-370`). But the renderer-side `CanvasImageDecodeCache.retryDecode` requires `visibleKeys.contains(key)` (`CanvasSurfaceRenderer.swift:171-173`) — the retry is dropped for any image outside the tracked/visible candidate set. Meanwhile the failure banner aggregates `session.failedImageIDs`, which `setFailedImageIDs` intersects with **all** session images (:362-365), not just tracked ones — the view-side failure set is computed over `images` at `CanvasSurfaceMac.swift:327`. So a failed image scrolled outside the viewport+prefetch margin remains in the banner, Retry returns `true`, and nothing is ever scheduled. It only heals when the image re-enters the visible set (a new `prepare(for:)` requeues a `.failed` key only via explicit retry — the failed memo survives, `CanvasSurfaceRenderer.swift` failure-retention logic).

**Expected vs actual.** Retry should either schedule the decode regardless of visibility or the UI should scope the banner to retryable images. Actual: a true-but-useless Retry affordance for off-screen failures.

**Impact.** A failed image off-screen is permanently unrecoverable via the banner until the user happens to pan it back into the tracked set; the notice also can't be told apart from a live retryable failure.

**Smallest fix.** In `retryDecode`, drop the `visibleKeys` requirement (insert the key into the decode pipeline as a margin-priority item), or have `setFailedImageIDs` report the retryable subset and keep a second "pending" set for the rest.

**Verification.** Unit: configure the cache with image A off-screen-failed → `retryDecode(for: A)` → assert a decode is enqueued (currently it returns early).

---

### CVD-05 — Scroll-wheel delta or pinch during an ink stroke silently discards the stroke — **Medium**, confirmed

**Mechanism.** `CanvasNSView.scrollWheel(with:)` (`CanvasSurfaceMac.swift:872-953`): the `momentumBegan` branch correctly guards `interaction.machine.state == .idle` (:932-936), but the catch-all delta branch (:943-953) and the `directBegan` re-begin (:911-914) do **not**. The magnification recognizer's `.began` (:1007-1010), `.changed`-with-no-active-gesture (:1013-1017), and `.possible` (:1033-1045) paths have no state guard either. All call `beginViewportGestureSequence` (`CanvasSurfaceMacHelpers.swift:946-961`), which calls `discardImagePreview()`, `discardShapePreview()`, and `interaction.beginViewportGesture()` → `machine.beginPan()` — and `beginPan` from `.drawing`/`.erasing` **discards all buffered points** (`CanvasInputStateMachine`; `CanvasSurfaceInteraction.swift:186-193` "Taking ownership discards any unfinished ink").

**Expected vs actual.** A trackpad scroll tick or incidental two-finger touch mid-stroke (common while drawing with the palm resting, or a momentum tail arriving late) should not destroy work in progress — at most it should be ignored until the stroke completes. Actual: the buffered ink is dropped; `mouseUp` then finishes a *pan* gesture (`finishPointerInteraction` routes by `machine.state`) — no stroke is saved, no error, no undo entry. The same path also cancels an in-flight image-move/resize or shape preview, snapping the object back.

**Impact.** Intermittent silent work loss during the app's core gesture. Reachable: macOS delivers scroll events while the mouse button is held (accessibility devices, some tablet drivers, momentum arriving as a drag begins, `NSEvent` routing edge cases); pinch during a stroke is normal hand posture.

**Smallest fix.** Add `interaction.machine.state == .idle` to the catch-all and re-begin guards (mirroring :932) and to the `.began`/`.possible` magnification branches — or have `beginViewportGestureSequence` itself refuse while ink is buffered (it already refuses during a pan, `panLastPoint == nil` at :954).

**Verification.** Unit: `beginInk` + two `appendInk`, then `scrollWheel` with a delta (or `magnification` `.began`) → assert `machine.state == .drawing` and buffered points intact. Currently the machine transitions to `.panning` and the points are gone.

---

### CVD-06 — Toolbar Undo/Redo bypass the text-editor undo routing — **Low-Medium**, confirmed

**Mechanism.** `CanvasEditCommandRoute.undo/redo` (`Attic/App/CanvasEditCommandRoute.swift:38-63`) route to the focused `NSTextView`'s `undoManager` first — so **Cmd+Z while editing canvas text undoes text**. But the toolbar buttons call the session directly (`CanvasPanelContent.swift:358-361`: `_ = session.undo()`, `_ = session.redo()`), as do the canvas-menu Undo/Redo items (:466-471 area). While the semantic editor is open with uncommitted text, a toolbar/menu Undo pops a *canvas* history command (e.g., deletes the previous stroke) instead of undoing the last typed run. The editor's dirty draft is preserved through the resulting `reconcileSemanticTextEditing` (conflict → draft retained), so no text is lost — but the two undo affordances disagree about what "undo" means in the same visual state, and the canvas-level undo commits/suspends nothing first.

**Expected vs actual.** Same gesture, same state, two different undo scopes. The route type exists precisely to prevent this split; the toolbar/menu paths just never use it.

**Smallest fix.** Point the toolbar buttons and menu items at `CanvasEditCommandRoute.undo(session:section:)` / `.redo`, and the disabled states at `.canUndo`/`.canRedo` (which already exist and handle the editor case).

**Verification.** Unit/UI: open text editing, type, click toolbar Undo → assert the text undo ran (editor text changes), not a canvas history pop.

---

### CVD-07 — Tombstoned and stale-generation rows are never physically deleted and are re-fetched on every save — **Medium**, confirmed structure, unmeasured growth impact

**Mechanism.** No `context.delete` exists anywhere in the Canvas store layer. `clearBoard` advances `clearGeneration` on board replicas and `tombstoneAllContent` marks strokes/images/semantic objects (`CanvasStoreLifecycle.swift`); `setDeleted` marks `tombstoned`. The fetch helpers in `CanvasStorePersistence.swift:490-595` query `#Predicate { $0.canvasID == canvasID }` **with no tombstone or generation filter** — every save, refresh, and mutation on the selected canvas fetches *all* historical rows, and `resolveCanvasPresentation` filters winners in memory afterward. External-storage image payloads of deleted/cleared images are retained indefinitely (rows persist; `.externalStorage` keeps blobs on disk but the row set grows).

**Expected vs actual.** Generations exist so stale rows stay "retained but invisible" (`CANVAS-DESIGN.md:27`) — that contract is kept for correctness. But nothing bounds or reclaims the dead set: repeated Clear/Undo cycles, deletes, and duplicate-replica writes accumulate rows that are loaded, grouped, and resolved on every subsequent save forever. The PERF-A1 test bound (`testStrokeMutationsReadOnlyTheSelectedCanvasReplicas`, `CanvasPerformanceGateTests.swift:587-682`) proves other canvases' rows aren't fetched — it does **not** bound dead rows on the *selected* canvas (it seeds none there).

**Impact.** Monotonic per-canvas row growth → linearly increasing fetch/group/resolve work per save and per refresh; storage grows; `tombstoned` filtering happens after materialization. Unmeasured — at small scale it's invisible; over months of use on one canvas it's a slow leak.

**Smallest fix.** A compaction pass: on `clearBoard` success (or lazily on refresh when dead rows exceed a threshold), physically delete rows where `canvasID == x && (tombstoned || boardGeneration < currentGeneration)` — keeping a safety margin if CloudKit resurrection semantics require the tombstones (the tombstone design suggests they might, so confirm before deleting rather than filtering fetches only). At minimum, add `!tombstoned && boardGeneration == current` to the read predicates where replicas aren't needed, keeping a full fetch only for mutation paths.

**Verification.** Unit: clear a 50-row board twice, assert stored-row count and `CanvasReplicaFetchCounter.rows` stay flat instead of doubling.

---

### CVD-08 — Resizing a text object narrower permanently clips its text until re-edited — **Low-Medium**, confirmed

**Mechanism.** Text is laid out and clipped to `object.worldRect` by `CanvasSemanticRenderer` (~:101, `context.clip(to:)`/layout in rect). Resize paths set `transform` directly with no reflow: `resizedTransform` (`CanvasImageTypes.swift:552-605`, min 48 via `minimumDimension` :439), pointer path at `CanvasSurfaceMac.swift:811`, and `resizeSelectedSemanticObject` (`CanvasSession.swift:1333-1339`, min **24** — inconsistent with the pointer's 48). Only `editSemanticObject` recomputes text height — `changed.transform.height = max(height, needed)` (:1303-1308), which *grows* but never shrinks. So: narrow the object → text reflows to a narrower column → needs more height → bottom lines are clipped, and that clipped geometry **persists** (the smaller width is saved; nothing ever recomputes required height outside an edit).

**Expected vs actual.** Either the resize reflows height (auto-grow like the edit path), or the user gets a visible overflow signal. Actual: silent truncation; recovery only by re-editing the text (commit re-grows height) or re-widening by hand.

**Impact.** Data isn't lost — the string is intact — but the placed text shows clipped content until manually fixed. Repro: place multi-line text → drag a side handle inward → bottom lines disappear.

**Smallest fix.** After a committed semantic resize of a `text` object, run the same `textSize(..., width:)` + grow-only height adjustment `editSemanticObject` uses (and consider shrink-to-fit for height too). Also unify the two minimums (24 vs 48).

**Verification.** Unit: narrow-resize a text object, assert `transform.height` grew to fit via `CanvasSemanticRenderer.textSize`.

---

## 3. Measured performance findings

**None.** No builds, tests, UI hosts, or instruments were run for this audit — every performance-relevant item is marked *structural* and listed in §4. The existing counter-gated tests (`CanvasPerformanceGateTests`) establish that PERF-08/09/10/11/13/A1 bounds hold in the suite; this audit found no counterexample to them in source.

## 4. Plausible but unverified concerns

- **CVP-01 — File-promise batches can hang when a provider delivers fewer files than `fileTypes.count`.** Slot allocation uses `expectedCount = max(receiver.fileTypes.count, 1)` **per receiver** (`CanvasSurfaceMacHelpers.swift:1157-1171`), while `receivePromisedFiles` invokes its callback once *per file actually written* (:1200-1223) and `CanvasFilePromiseBatchCoordinator.record` fills exactly one slot per delivery and finishes only when *all* slots are filled (:682-708). Image-promise sources commonly advertise several UTIs (png/jpeg/tiff) but write one file — under that contract the batch never reaches `.ready`: the drop produces **no import, no error, no progress UI**, and the coordinator + temp dirs sit until Escape or view teardown (`cancelFilePromiseBatches` does clean up, :1317-1327). The coordinator's own test uses one slot per receiver (`CanvasDomainTests.swift:1155-1222`), so the over-allocation lives only in the untested caller. Needs a live drag to confirm real-world `fileTypes`/delivery ratios; if confirmed, expect "dropping an image from Photos/Safari does nothing" reports. *Fix direction:* derive `expectedCount` from delivered files (one slot per receiver, fill on arrival) or bound the wait with a completion timeout that fails the batch visibly.
- **CVP-02 — Accessibility queries rebuild the element map unconditionally.** `accessibilityChildren()`/`accessibilitySelectedChildren()` call `refreshCanvasAccessibilityElements` directly (`CanvasSurfaceMac.swift:391-407`), as do `focusNextCanvasObject` (per Tab) and two keyDown paths (`CanvasSurfaceMacHelpers.swift:454, 551`; `CanvasSurfaceMac.swift:1124, 1146`). The stale-flag/coalesced machinery (`invalidate…` → `flushPendingAccessibilityRebuild`, helpers :270-295) only guards the configure-driven path — every direct query pays the full rebuild: `orderedStrokes` sort, per-element `update`, fresh `NSAccessibilityCustomAction` objects, `accessibilityRebuildCount += 1` (:315-322). VoiceOver interrogates children on focus moves and attribute requests, so frequency is client-driven; cost is O(strokes log + objects) per query. First query *must* build (the guarded path requires `hasBuilt…`), so the fix is `if !hasBuilt || stale { refresh }` rather than routing to `flush…`. Perf gate `testViewportOnlyConfigureDoesNotRebuildAccessibilityElements` doesn't cover the query path.
- **CVP-03 — `semanticObject(at:)` bypasses the precomputed image hit-test order.** `CanvasSemanticInteraction.swift:103-111` filters `imagesForDisplay` linearly (plus all semantic objects) and `max(by:)` over the combined hits — instead of `imageDisplayOrder.topmostImage` which has union-bounds early-out and front-to-back early-hit (`CanvasSurfaceRenderer.swift`). Called from `cursorRole` (every mouseMoved in Select tool) and every Select click. O(images + objects) with allocation per event; fine at current counts, it reintroduces the pattern PERF-10 removed for images.
- **CVP-04 — `semanticObjectsForDisplay` remaps the array on every access during a semantic drag.** `CanvasSemanticInteraction.swift:93-101` — while `semanticPointerActive` is set, each access `map`s all objects; it's read by `draw` (per frame, `CanvasSurfaceMac.swift:636`), `cursorRole`, `semanticObject(at:)`, `selectedSemanticObject`, and the a11y rebuild (helpers :335, 429) — several O(n) maps per drag frame. Images got a cached equivalent (`imageDisplayCache`) in PERF-10; semantics didn't. Same shape, smaller n — structural note only.
- **CVP-05 — macOS ink ignores coalesced mouse samples.** `mouseDragged`/`appendInk` consume only the event's final location; `NSEvent.coalescedEvents(for:)` is never used (iOS does use `coalescedTouches`, `CanvasSurfaceIOS.swift`). Doc-acknowledged (`CANVAS-DESIGN.md:67` "rapid ink currently does not consume AppKit coalesced mouse samples"). Effect: fast flicks sample at event rate (~display refresh), producing sparser point density than hardware delivers — mild precision loss on fast strokes; unmeasured visually.
- **CVP-06 — Semantic text drafts orphan on deletion.** `session.semanticTextDrafts` survives conflict/suspend by design, but deleting the edited object (`deleteSemanticObject`) or its whole canvas (`deleteCanvas`) leaves the draft keyed to an unreachable entity — retained for the session's life, and on canvas-delete it's under an id that can never be re-selected. Bounded (draft count) but a real retention edge.
- **CVP-07 — `EditCommandRoute` matches any `NSTextView` in the key window.** `canUndo/canRedo/undo/redo` check `NSApp.keyWindow?.firstResponder as? NSTextView` (`CanvasEditCommandRoute.swift:25, 33, 42, 55`), not specifically `CanvasSemanticTextEditor` (contrast `finishTextEditing` at :12 which uses the precise class). If any non-canvas text view holds first responder while the Canvas section is visible (none known today — the candidates are compile- or section-scoped away), canvas undo would route to it. Low risk; worth a class check for symmetry.
- **CVP-08 — `imageDecodeRetryRequest` replays on view recreation.** The request persists on the session until consumed; a rebuilt view's `lastDecodeRetryRequest` is nil, so the next configure re-applies the retry (`CanvasSurfaceRenderer`/view configure). Harmless no-op when the image is no longer failed — but combined with CVD-01's frequent rebuilds it's a subtle repeated side effect.
- **CVP-09 — Eraser worst-case work.** `accumulateEraseHits` rescans all non-erased strokes per accepted drag sample (`CanvasSurfaceInteraction.swift:220-233`) — O(strokes × events) per gesture, mitigated by per-stroke bounds rejection and the 12 000-pt input cap. Covered by RUN-003 in the runtime audit; flagged here as the in-domain instance with the note that no spatial index exists.

## 5. Minor / optional UX items

- **CVX-01 — iOS text-placement popover promises editing that iOS can't do.** `CanvasPanelContent.swift:626` — "Double-click placed text to edit it" — but `insertText` on `#if !os(macOS)` rasterizes text into an image, and there is no double-tap path on iOS. The placement instruction itself is truthful ("non-editable text image"); only this helper line lies. Deferred platform; fix the copy when iOS ships.
- **CVX-02 — "Export Original…" exports canonical bytes, not the original.** `CanvasPanelContent.swift:687` + `CanvasImageExportDocument` write `image.encodedData` — the post-import re-encoded, ≤4096 px, ≤8 MB version. The original file is never stored, so this is the best available — but the label over-promises. "Export Image…" is truthful.
- **CVX-03 — Inconsistent text-commit veto across entry points.** Tool buttons and canvas switch/create honor `CanvasEditCommandRoute.finishTextEditing()` (`CanvasPanelContent.swift:415, 429, 509, 520, 531, 544, 587`), but Rename, Delete Canvas, Fit, Zoom, Clear, Import Image, and the selection-dock actions don't (:201-248, 363-369, 159-184, 702-840). The suspend/draft machinery makes this safe (uncommitted text is preserved, not lost) — the inconsistency is that some paths commit-or-veto while others proceed and suspend. Style edits from the semantic dock *while editing* create a draft-conflict record rather than applying cleanly. One-line guards where a commit is semantically required; otherwise document the suspend behavior.
- **CVX-04 — Space key discards in-progress ink.** `keyDown` 49 cancels interaction before arming pan (`CanvasSurfaceMac.swift:1130-1135`) — same discard family as CVD-05 but deliberate (space = pan modifier). Worth a deliberate-design check: a stray Space press mid-stroke silently drops the stroke.
- **CVX-05 — `CANVAS-DESIGN.md` is materially stale.** It still describes shapes→strokes and text→image storage (:21 — semantic objects now exist on macOS), claims no retry/remove/export UI (:46 — `imageRecoveryNotice` + image dock exist), says history is "count-bounded rather than byte-bounded" (:68 — byte budget exists, CANVAS-010), and says viewport is "session-local… not persisted" (:57 — `CanvasViewStateArchive` writes UserDefaults). Readers will be misled; refresh the doc or mark it superseded.
- **CVX-06 — Keyboard resize minimum differs from pointer minimum.** `resizeSelectedSemanticObject` floors at 24 (`CanvasSession.swift:1336`) vs `minimumDimension = 48` for pointer resize (`CanvasImageTypes.swift:439`) — a keyboard-resized object can reach sizes the pointer can't produce; trivially inconsistent.
- **CVX-07 — `accessibilityValue`/`failedImageIDs` recompute sets per query.** `Set(images.map(\.id))` in `setFailedImageIDs` (:362-365) and the label string in `CanvasSurface.accessibilityValue` (:60-80) are cheap; noted for completeness.

## 6. Dismissed hypotheses

- **Import-result ID mismatch — dismissed.** `CanvasSession.importImageBatch` looked like it could attribute outcomes to the wrong ids after storage; `CanvasStoreImages.importImages` preserves `requestID` (request id *is* the image id), so outcome mapping is correct.
- **Broad persistence-rollback failure — dismissed.** Every mutation path do/catches, calls `context.rollback()`/`discardPendingChanges`, and reloads on failure; `save()`'s typed outcomes (`noChange`/`persisted`/`persistedWithWarning`/`failed`) plus post-save fresh-context reload are consistent with `CANVAS-DESIGN.md:29` and covered by `CanvasStoreTests` (e.g., `testFailedAddRollsBack…`, `testClearReportsPersistedWhenFreshContextReloadFailsWithoutRetry`).
- **Coordinate-transform defect — dismissed.** `CanvasViewport` world↔view round-trip, clamped zoom anchors, resize centering, and `fit` math are correct in source and covered by `testViewportWorldViewRoundTripSurvivesResize`, `testZoomKeepsAnchorWorldPointStationaryAndClampsScale`, `testDropCoordinatesRemainCorrectUnderZoomAndPan`. Non-finite guards exist at every ingress (`appendInk` :134, `worldPoint` validity, `resizedTransform` :558-604).
- **Eraser math — dismissed.** Segment-distance hit testing, bounds rejection, per-gesture single history command (`testOneEraseGestureIsOneHistoryCommandForEveryHitStroke`), and `max(12/scale, 2)` radius are all correct. Only the rescan complexity (CVP-09/RUN-003) stands.
- **Per-pointer-event image sorting — dismissed.** PERF-10's `CanvasImageHitTestOrder` (precomputed front-to-back/back-to-front + union bounds, preview-aware) is used on the image paths and gated by `testTopmostImageHitTestingOverTwoHundredImages`. The semantic-path linear scan remains (CVP-03).
- **Same-UUID cross-canvas mutation leakage — dismissed.** Mutations are canvas-scoped by predicate and `testSameIDReplicaOnAnotherCanvasIsNotShownOrRewrittenBySelectedCanvasMutations` pins the intended contract.
- **Unbounded memory in the input/import paths — dismissed.** Point buffer capped at 12 000 with deterministic compaction; imports ≤64 MB in / ≤8 MB encoded / ≤4096 px, 2-concurrent, cancel-aware, security-scope balanced; history is count- and byte-bounded; decode cache 256 MB/48 images/3 workers; failure memo bounded. The residual residency issue is RUN-010 (encoded payloads live in `session.images`), which stands.
- **Accessibility rebuild on viewport-only changes — dismissed for the configure path.** `strokeContentRevision` + stale-flag + run-loop coalescing verified and test-gated; the *query* path remains unguarded (CVP-02).
- **Toolbar tool-switch losing unsaved text — dismissed.** The real toolbar buttons all guard with `finishTextEditing()` (:509, :520, :531); only secondary actions lack it (CVX-03), and drafts survive suspension anyway.

## 7. Prioritized fixes

1. **CVD-01 + CVD-02 (shared root):** split transient interruption from lifecycle teardown — stop bumping `interactionCancellationEpoch` for zoom clicks, panel hide, and section switch; gate `clearHistory`/teardown on store success in `selectCanvas`/`createCanvas`; take import-batch cancellation out of `deactivateRepresentation`. Fixes a functional abort, an undo-history wipe, and recurring cache churn. (Aligns with runtime audit priority 1.)
2. **CVD-05:** add the `.idle` guard to the remaining scroll/pinch entry paths (one-line guards mirroring `CanvasSurfaceMac.swift:932`) — removes silent mid-stroke ink loss.
3. **CVD-07:** decide the dead-row retention contract (needed for CloudKit resurrection vs. safe to compact locally), then either physically delete past-generation tombstoned rows or add generation/tombstone filters to the read predicates.
4. **CVP-01:** fix file-promise slot accounting (slot per receiver, not per advertised UTI) or add a bounded wait that fails the batch visibly — pending one live-drag confirmation.
5. **CVD-03 + CVD-04:** make `retryFailedImageDecodes` actually retry all failures and make retry visibility-independent (or scope the banner to retryable images).
6. **CVD-06:** route toolbar/menu Undo/Redo through `CanvasEditCommandRoute`.
7. **CVD-08:** reflow text height on committed semantic resizes; unify resize minimums.
8. **CVP-02:** gate `accessibilityChildren`/`accessibilitySelectedChildren`/`focusNextCanvasObject` rebuilds on `!hasBuilt || stale`.
9. **CVX-05:** refresh `CANVAS-DESIGN.md` (semantic storage, retry UI, byte-bounded history, persisted view state) — cheap, prevents future audits chasing stale contracts.
10. **CVP-03/04, CVP-05, CVX-01–04, 06–07:** cosmetic/consistency; batch with nearby work.

## 8. Limitations

- **Source-only audit.** No build, no unit/UI test execution, no Instruments, no live gestures, no performance measurements. All performance items are structural; severities are reasoned, not measured. Gesture-timing issues that only physical input exposes remain possible.
- **Deferred platforms.** `CanvasSurfaceIOS` and all CloudKit paths (`CanvasStoreCloudSync`, remote observers) were reviewed for dormancy and local-only correctness only — not validated as functional. Per the project contract, nothing here claims iPhone/CloudKit/APNs/TestFlight behavior works.
- **File-promise provider contract (CVP-01)** is the one finding whose real-world frequency can't be settled from source — it needs a live drop from a real provider.
- **Dirty worktree.** Line numbers reflect this snapshot; unrelated in-flight user edits may shift them.
- **Not claimed:** exhaustive proof that no further canvas defect exists — coverage is complete over the source inventory and every traced caller, with residual risk concentrated in native-gesture timing and a11y-client query patterns that require live verification.
