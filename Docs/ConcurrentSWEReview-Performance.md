# Concurrent SWE Review — Performance, Energy, Memory, and Smoothness

**Lane:** SWE review lane 2 (performance / energy / memory / smoothness)
**Checkout:** `/Users/taha/Developer/attic-task-panels-v2`, branch `codex/attic-task-panels-v2`, baseline `ae6418c1` plus the existing dirty working tree
**Method:** Read-only source audit. No application or test source was modified; no GUI was operated; no builds or broad test suites were run. Evidence comes from source inspection plus the repository's own prior microbenchmarks under `.build/quality-audit/root/` and idle samples under `.build/quality-audit/a/`.
**Confidence legend:** CONFIRMED (full causal chain verified in source), STRONG EVIDENCE (cost verified, magnitude needs profiling), CANDIDATE (plausible, unproven), PASS (area reviewed and found sound), UNVERIFIED (could not be determined from source).

## Executive summary

The app's architecture is mostly event-driven and honest about its costs: there are no `TimelineView` spinners, no polling loops where events suffice, thumbnails and image imports run off-actor behind bounded caches, and monitors/timers are torn down correctly. The dominant cost driver is not any single wasteful subsystem — it is *multiplication*: a handful of O(n) or O(n²) primitives in `TaskStore` and the Canvas store are re-executed per SwiftUI body evaluation, per scroll frame, per pointer event, and per store revision, and nearly every store mutation publishes broadly, which re-triggers them app-wide.

The top repairs, in priority order:

1. **PERF-01/02/03 (P1)** — Task-family lookups are O(n) each and run ~3–4× per row body; attachment JSON is decoded ~6× per row body; and `@ObservedObject` fan-out means one keystroke re-evaluates every row. Together these make typing, toggling, and scrolling scale quadratically with task count. Measured: 357 ms for a full family-summary pass at 6,000 tasks.
2. **PERF-08 (P1)** — Every Canvas mutation saves, then resolves the presentation by faulting *every* image blob on the current board (`encodedData` external storage) and retaining all bytes in the presentation model. A 100 MB board re-reads 100 MB per committed stroke.
3. **PERF-07 (P2)** — While the panel is visible (or the pointer is within 144 pt of the corner), the app holds a `.userInitiated` activity assertion and a 50 ms main-queue timer — 1,200 samples/min — defeating App Nap for an app whose whole purpose is to sit resident.
4. **PERF-05/06 (P2)** — Reveal does three synchronous full-store reloads on the main actor; scrolling with a family surface open forces `layoutSubtreeIfNeeded` + `fittingSize` on a hosted SwiftUI panel per scroll frame.
5. **PERF-09/10 (P2)** — Canvas `configure()` re-sorts and rebuilds accessibility elements for all objects (with quadratic sub-loops) on every published change including pan/zoom; `mouseMoved` sorts the entire image array per event.
6. **PERF-12 (P2)** — Notes: every keystroke copies the whole note body into a signature, diffs it via two full UTF-16 array copies *per attachment card*, re-renders every inline card's `NSHostingView`, and may strip/re-apply paragraph attributes over the entire document.
7. **PERF-04/11/13/14 (P2/P3)** — Redundant unpredicated full-table fetches on the main actor per mutation; Canvas undo retains multi-MB image payloads for up to 100 commands; per-revision full-array snapshot copies/compares.

Nothing found requires breaking the local-first contract: every recommended fix preserves durable saves, rollback, and replica-safe mutation semantics. The replica-fetch patterns are correctness-driven (CloudKit-free uniqueness); the repair is to predicate them, not remove them.

---

## Measured evidence

| Evidence | Source | Result |
|---|---|---|
| Family-summary benchmark | `.build/quality-audit/root/family-summary-benchmark.txt` | 1,000 parents / 6,000 tasks: **357.3 ms** median for 3 `subtasks(of:)` evals per parent (300 parents → 33.1 ms, 100 → 4.6 ms, 30 → 0.7 ms — superlinear, consistent with O(n²)) |
| Attachment decode benchmark | `.build/quality-audit/root/attachment-decode-benchmark.txt` | 300 rows × 4 refs × 6 reads: **12.8 ms** per pass (100 rows → 5.1 ms) |
| Idle samples | `.build/quality-audit/a/sample-idle-{1,2}.txt` | At rest, main thread ~99% AppKit idle; only periodic work is `CornerHoverMonitor` cadence ticks → `AtticPanelController.updateMousePassthrough`; ~0.54% avg CPU |
| Reveal latency (prior audit) | `.build/quality-audit/b/evidence/hover-open-latency.txt` | ~0.55 s ≈ 0.35 s dwell + show animation at current data sizes |
| Checklist cross-ref | `Docs/ConsolidatedDefectChecklist-2026-09-13.md` TP-013 | Cites the same ~357 ms family-lookup figure |

The benchmarks model `subtasks(of:)`/`attachments` faithfully (the harness reimplements the same algorithms; the earlier interpreter run is ~6× slower than the compiled artifacts and was not used).

---

## Findings

### PERF-01 — Quadratic task-family scans on render-hot paths

**Severity:** P1 · **Status:** CONFIRMED · **Area:** TaskStore + task views

**Evidence**

- `TaskStore.subtasks(of:)` — `Attic/Services/TaskStore.swift:721-733`: `tasks.filter` (O(n)) where each candidate additionally calls `parent(of:)`, which itself does `tasks.first` (O(n)) — `TaskStore.swift:716-719`. One call is O(n) best-case, O(n·children) worst-case.
- `TaskStore.snapshot(for:)` — `TaskStore.swift:738-758`: for each status in scope, `orderedTasks(for:)` (O(n log n)) then `.filter { parent(of: $0) == nil }` — O(n²) per scope per rebuild. The memo at `snapshotCache` (line 739) is keyed by `revision`, which `save()`/`reloadTasks()` increment on *every* mutation (lines 867, 893), so the O(n²) rebuild happens once per mutation and again on every `refresh()`.
- Per-row call sites: `TaskFamilyView` — `Attic/Views/Panel/TaskFamilyView.swift:15` (`children` computed) with `summary` (lines 16-20) touching `children` up to 3× per body evaluation (`isEmpty`, `filter`, `count`); `TaskRowView` — `Attic/Views/Panel/TaskRowView.swift:399-449` calls `store.subtasks(of:)` in menu/drop/status logic ~3× per body; `SubtaskPanelContent` — `Attic/Views/Panel/SubtaskPanelContent.swift:49-51` (`children`), 62 (`completedCount` re-invokes `children`), 427 (`children.count` in `contentHeight`), 579 (`ForEach(children)`) — ~4 full scans per body.
- `TaskSectionView` drop logic — `Attic/Views/Panel/TaskSectionView.swift:80` — one more per drop proposal evaluation.

**Causal chain:** mutation → `save()` → `revision &+= 1` → snapshot cache invalidated → next `snapshot(for:)` = O(n²) → every visible `TaskFamilyView`/`TaskRowView`/`SubtaskPanelContent` body re-evaluates (see PERF-03) → each re-runs its own 3–4 O(n) scans. At 6,000 tasks, the benchmarked family-summary pass alone is ~357 ms; a rename keystroke that invalidates the list re-pays this across all visible rows.

**User impact:** Stutter on every toggle/rename/paste as task count grows; scroll jank; multi-second beach-balls at tens of thousands of tasks. This is the app's primary scaling ceiling.

**Recommended repair (direction only):** Build a `parentID → [child]` index once per revision inside `TaskStore` (or inside the snapshot), hand each family its precomputed children array, and keep `subtasks(of:)` as an O(1) dictionary lookup. Preserve sort semantics and the `parent(of:)` root-validation rule verbatim.

**Validation:** Re-run the family benchmark shape against the indexed path; Time Profiler trace of a status toggle at 6,000 tasks should drop the `subtasks`/`parent` frames below 1%.

---

### PERF-02 — Fresh `JSONDecoder` decode of attachments on every access (~6× per row body)

**Severity:** P1 · **Status:** CONFIRMED · **Area:** TaskItem + task views

**Evidence**

- `TaskItem.attachments` — `Attic/Models/TaskItem.swift:25-28`: `try? JSONDecoder().decode(...)` on every property access — a new decoder instance and a full JSON parse each time.
- Access sites per `TaskRowView` body: line 84 (glyph/indicator), 140-142 (attachment badge), 289-311 (drag payload construction for `.onDrag`), and inside 399-449 (menu/drop/status conditions). `SubtaskPanelContent.attachments` (lines 57-59) is re-evaluated at 429 (`attachmentCount`) and 457 (gallery). `TaskAttachmentsPopover` line 391 decodes again per body.
- Measured: 12.8 ms per 300-row × 6-read pass (`attachment-decode-benchmark.txt`) — paid on *every* body evaluation wave, not once per render.

**Causal chain:** Every invalidation of the row tree (PERF-03) re-decodes each visible row's attachment payload several times. The decodes are small but multiply: rows × 6 accesses × invalidations.

**User impact:** Adds milliseconds to every interaction at moderate data sizes; contributes to scroll/typing jank; pure repeated work.

**Recommended repair:** Memoize the decoded `[TaskImageReference]` per `imageReferencesData` content (a `TaskStore`-side cache keyed by task persistent ID + data hash, or a lazily decoded snapshot field populated once per revision). Keep `imageReferencesData` as source of truth.

**Validation:** Benchmark repeated `attachments` reads pre/post memoization; confirm identical decoded arrays; confirm mutations still propagate (replica sync writes `imageReferencesData`, TaskStore.swift:378).

---

### PERF-03 — Store-wide SwiftUI invalidation; per-keystroke and per-frame fan-out

**Severity:** P1 · **Status:** CONFIRMED · **Area:** PanelUIState / TaskStore observation

**Evidence**

- `PanelUIState` publishes 15+ properties — `Attic/Window/PanelUIState.swift:28-58` — including per-keystroke state: `editingDraftTitle` (line 33, fires per character while renaming a task), `subtaskDrafts` (line 35, per character while drafting a subtask), and `panelSize` (line 57, per resize frame).
- Every row observes the whole objects: `TaskRowView` (`@ObservedObject store/uiState/subtaskPanels`), `TaskFamilyView` (`Attic/Views/Panel/TaskFamilyView.swift:7-9`), `SubtaskPanelContent` (`SubtaskPanelContent.swift:14-18`), `TaskAttachmentsPopover` (`TaskImageAttachments.swift:384`). `@ObservedObject` invalidates on *any* `objectWillChange`, regardless of which property a row reads.
- `TaskStore` publishes `tasks`, `revision`, `lastErrorMessage`, `importingAttachmentTaskIDs`, `cloudSyncStatus` (`TaskStore.swift:184-191`); `save()` bumps `revision` per mutation.
- `noteStore.revision` → `AtticPanelView.swift:172-175` runs `reconcileNoteDraft()` + `openMostRecentNoteIfNeeded()`, which call `noteStore.orderedNotes()` (O(N log N) sort — `NoteStore.swift:643-650`) at three sites (AtticPanelView.swift:793, 803, 805) plus `savedNotes` (NotesPanelContent.swift:55) on every note save — i.e., every autosave keystroke-debounce cycle.
- `store.revision` → `AtticPanelView.swift:160-162` rebuilds `Set(store.tasks.map(\.id))` O(n) per mutation — cheap, but one more per-mutation pass.

**Causal chain:** one keystroke in a rename field → `editingDraftTitle` publishes → every `TaskRowView`/`TaskFamilyView`/`SubtaskPanelContent` body re-evaluates → each performs PERF-01 scans and PERF-02 decodes → O(visibleRows × n) per keystroke. Same for `panelSize` during a window resize (per frame) and `subtaskDrafts` while typing a subtask.

**User impact:** Typing lag and resize stutter that grow with list size; battery cost of repeated main-actor work.

**Recommended repair:** Cut the fan-out, not the work items: (a) pass rows a value-type model (`TaskRowModel` with precomputed children/attachment summary) so row bodies read no store methods; (b) split `PanelUIState` drafts per-task or keep draft text in `@State`/dedicated objects owned by the editing row only; (c) gate `reconcileNoteDraft`/`openMostRecentNoteIfNeeded` on actual ID-set changes rather than every revision.

**Validation:** SwiftUI body-count instrumentation (os_signpost around `snapshot(for:)`/`subtasks(of:)`) — one keystroke should produce ≤1 row-body wave, not O(rows).

---

### PERF-04 — Redundant unpredicated full-table fetches per mutation (main actor)

**Severity:** P2 · **Status:** CONFIRMED · **Area:** TaskStore persistence

**Evidence**

- `update(_:)` — `TaskStore.swift:299-384`: fetch #1 via `storedTasks(matching:)` → `storedTaskGroups(matching:)` at 930-938 does `context.fetch(FetchDescriptor<TaskItem>())` (933) then in-memory filters by ID — i.e., *the whole table* for one task's replicas; fetch #2 at 321 (`let stored = try context.fetch(...)`), unconditional — runs even for title-only edits, then `stored.contains` for status validations; a possible fetch #3 when `nextManualOrder` overflows → `assignSpacedManualOrders` → `storedTaskGroups` again (1138). `nextManualOrder` itself filters `tasks` in memory (1096) — acceptable.
- `create` — `TaskStore.swift:239-244`: `storedTasks(matching:)` full fetch for subtask parents + `nextManualOrder` + save.
- `purgeCompleted(before:)` — `TaskStore.swift:646-688`: full fetch (649), group all replicas (657), then a fixpoint while-loop (670-678) that iterates *all* stored items per pass until convergence — O(passes × n), passes bounded by family depth — then `expired.flatMap(\.attachments)` (681) decodes attachment JSON for every expired replica.
- `sweepUnreferencedAttachmentStorage` — `TaskStore.swift:518-536`: full fetch + `JSONDecoder().decode` of *every replica's* `imageReferencesData` (526) at launch (once per launch, off the critical path — moderate).
- All of the above run on `@MainActor` (`TaskStore` is main-actor-isolated).

**Causal chain:** each user action = 2–3 full-table reads + a save, serialized on the main thread; the same rows are then re-scanned in memory (PERF-01).

**User impact:** Per-mutation latency grows linearly with total stored rows (including replicas); adds up under rapid edits.

**Recommended repair:** Use `FetchDescriptor` `#Predicate` on `id`/`parentID` so only needed rows are materialized; skip the validation fetch entirely when `status` is unchanged; share one fetched set between replica resolution and validation; for `purgeCompleted`, predicate on `completedAt < cutoff` and evaluate the family-closure only over the expiry candidate set.

**Validation:** Instruments Core Data/SwiftData template — one status toggle should produce O(1) row materializations, not 2–3 full fetches.

---

### PERF-05 — Reveal performs three synchronous full-store reloads on the main actor (plus a delayed retry)

**Severity:** P2 · **Status:** STRONG EVIDENCE (cost path confirmed; user-visible magnitude depends on data size) · **Area:** CornerHoverMonitor → stores

**Evidence**

- `refreshStoreForReveal` — `Attic/Services/CornerHoverMonitor.swift:377-393`: `store.refresh()`, `noteStore.refresh()`, `canvasStore.refresh()` back-to-back, then a delayed retry task that repeats all three (387-392).
- Each refresh is a fresh-`ModelContext` full reload: `TaskStore.reloadTasks` (`TaskStore.swift:884-894`, full `TaskItem` fetch + dedupe pass); `NoteStore.reloadModels` (`NoteStore.swift:710-718` → `presentationSnapshot` 729-738 fetches *all* `NoteItem` + *all* `NoteAttachment`, then `installPresentation` 740-752 rebuilds `attachmentsByNoteID` and calls `reconcileFileStorage`); `CanvasStore` reload (`CanvasStorePersistence.swift:86-97` → `resolveCanvasPresentation` 104-390 — see PERF-08 for its per-image blob reads).
- Callers: `revealProgrammatically` (hot key → `AppCoordinator.showPanel/showNewTask`, AppCoordinator.swift:401-411) and the hover-reveal path.

**Causal chain:** reveal → three full database reads + resolve passes + downstream publishes → snapshot rebuild (PERF-01) + surface configure (PERF-09) + AX rebuild — all before/with the show animation, then again on the retry.

**User impact:** Reveal latency and dropped animation frames grow with total data size; double work when the retry fires.

**Recommended repair:** Gate each refresh on staleness (revision/watermark since last change — in `ATTIC_LOCAL_ONLY` builds there is no remote writer, so refreshes can be near-no-ops); refresh only the store for the visible section eagerly and defer the other two; overlap refresh with the show animation rather than preceding it.

**Validation:** Signpost the three refreshes; measure reveal-to-interactive at 0/1k/10k tasks+notes+canvas objects — target: no refresh work when nothing changed.

---

### PERF-06 — Per-scroll-frame forced layout of subtask surfaces via `fittingSize`

**Severity:** P2 · **Status:** STRONG EVIDENCE · **Area:** SubtaskPanelController layout

**Evidence**

- Every task row publishes its frame via `TaskRowAnchorPreferenceKey` (`AtticPanelView.swift:163-165`) → `SubtaskPanelController.updateTaskRowFrames` (`SubtaskPanelController.swift:210-217`), which calls `repositionTransient()` whenever a transient family surface is open.
- `repositionTransient` (1138-1164) → `fittingSize(of:)` (1239-1246): `host.layoutSubtreeIfNeeded()` + `host.fittingSize` — a full AppKit layout pass over the hosted SwiftUI family panel.
- `refreshSurfaceSizes` (1167-1179) repositions the transient and resizes *every* pinned surface via `resizeDetachedSurface` (1182-1190), each calling `fittingSize(of:)`; `updateTaskListViewport` is driven by `TaskListViewportPreferenceKey` (`AtticPanelView.swift:169-170`), which republishes during scroll.
- Trigger frequency: every scroll/layout pass while a transient or pinned surface exists — i.e., per frame during scrolling.

**Causal chain:** scroll → row-anchor preference republishes → `repositionTransient` → forced `layoutSubtreeIfNeeded` + `fittingSize` of a non-trivial SwiftUI tree → repeated synchronous layout during a scroll that is already doing SwiftUI work (PERF-01/02/03).

**User impact:** Scroll stutter precisely when the family panel is open; multiplies with multiple pinned surfaces.

**Recommended repair:** Coalesce row-frame/viewport updates to once per runloop tick (or per CATransaction); cache the measured size keyed by the surface's content signature (children count + attachment count + measured row heights already exist in `SubtaskPanelLayout`) and only call `fittingSize` when the signature changes.

**Validation:** Time Profiler while scrolling with a pinned family surface — `fittingSize`/`layoutSubtreeIfNeeded` should appear ≤1× per scroll gesture, not per frame.

---

### PERF-07 — Energy: 50 ms timer + `.userInitiated` activity assertion while armed or panel-visible; global event monitor wakes the process for all pointer motion

**Severity:** P2 · **Status:** CONFIRMED (mechanism); energy magnitude CANDIDATE → STRONG EVIDENCE with `powermetrics` · **Area:** CornerHoverMonitor

**Evidence**

- Cadences — `CornerHoverStateMachine.swift:28-51`: `.responsive` = 50 ms interval / 15 ms leeway; `.idle` = 1,000 ms / 250 ms leeway. `holdsResponsivenessActivity` is true for `.responsive` (line 46).
- Responsive whenever `isPanelVisible || isNearConfiguredCorner` — `CornerHoverStateMachine.swift:103`, with 96/144 pt hysteresis (76-77, 88-90). So the whole time the panel is open — the app's normal working state — the responsive cadence is held.
- Timer — `CornerHoverMonitor.swift:284-303`: main-queue `DispatchSource` repeating at cadence → `samplePointer` (179-253) does screen lookup, panel + auxiliary hit tests, and state-machine work.
- Activity assertion — `CornerHoverMonitor.swift:306-316`: `beginActivity(options: .userInitiatedAllowingIdleSystemSleep)` held for the entire `.responsive` period — this marks the app as doing user-initiated work and blocks App Nap for its duration.
- Monitors — `CornerHoverMonitor.swift:328-357`: a *global* `NSEvent` monitor for all mouse-moved/drag events system-wide (delivered on the main thread → `pointerActivityObserved`, 255-265) plus a local monitor including `keyDown`. The per-event path is cheap by design (cadence update only — good), but every system pointer event still wakes/dispatches into the process.
- Corroboration: the only periodic work in the idle samples is this monitor's ticks (`.build/quality-audit/a/sample-idle-1.txt`); idle CPU ~0.54% avg — bounded, but the `.userInitiated` hold is a policy cost, not a CPU reading.

**Causal chain:** panel open (or pointer parked near the corner) → 50 ms timer + userInitiated assertion continuously → ~1,200 wakeups/min of timer + hit-test work at elevated QoS, plus global event delivery for all system mouse motion. For an LSUIElement accessory whose job is to *wait*, this is the main idle-energy item.

**User impact:** Battery/energy while the panel is in normal use; prevents App Nap exactly when the app should be quietest.

**Recommended repair:** While the panel is visible, suspend the sampling timer entirely — visibility is already known and panel-internal hover is handled by the panel's own passthrough monitors (`AtticPanelController.swift:1142+`); resume sampling only when hidden and near-corner. Narrow `.userInitiated` holds to the dwell/decision window rather than the whole visible period; consider `leeway` ≥ interval for the responsive timer.

**Validation:** `powermetrics --samplers tasks` before/after: target zero `beginActivity` holds and zero timer wakeups while the panel is visible and idle; confirm reveal latency unchanged.

---

### PERF-08 — Canvas: every save re-faults every image blob; image bytes retained in the presentation model

**Severity:** P1 · **Status:** CONFIRMED (source path); byte-traffic magnitude UNVERIFIED pending Instruments · **Area:** CanvasStorePersistence / CanvasPlacedImage

**Evidence**

- `CanvasPlacedImage.encodedData: Data` — `Attic/Canvas/CanvasImageTypes.swift:215`: the presentation model carries each image's full PNG/JPEG bytes (import cap 8 MB — `CanvasImageImporter.swift:44-49`). `session.images`/`store.images` therefore retain *all* image bytes for the board in memory.
- `resolveCanvasPresentation` — `Attic/Services/CanvasStorePersistence.swift:104-390`: `replica.encodedData.isEmpty` at **line 283** runs before the cache check at 292, faulting the external-storage blob for every image winner on the selected canvas on *every* resolve; `CanvasPlacedImage(encodedData: replica.encodedData)` at 321 keeps the bytes; `CanvasImageCacheEntry` retains `image` including `encodedData` (331-347). Each `reloadCanvas` uses a fresh `ModelContext` (86-97) so blobs are re-read from disk on every resolve — the `CanvasImageCacheEntry` reuse at 292-306 avoids re-wrapping but not the `encodedData` fault at 283.
- `save()` — `CanvasStorePersistence.swift:24-83`: every mutation (each committed stroke, image move, semantic edit, clear, board rename) → persist → reload → resolve.
- Replica helpers — `CanvasStorePersistence.swift:431-459` (`storedBoardReplicas`/`storedStrokeReplicas`/`storedImageReplicas`): `context.fetch` of the *entire* table then in-memory filter — per mutation call.
- Mutations fan out through this path per user action: `addStroke` (`CanvasStoreStrokes.swift:8-67`), `setDeleted` (69-116), `importImages` (`CanvasStoreImages.swift:32+`), `clearBoardOutcome` (`CanvasStoreLifecycle.swift:13-60`), board ops (`CanvasStoreBoards.swift:20-161`).

**Causal chain:** stroke-up → `store.save()` → fresh-context reload → fetch all replica rows (metadata) → for each selected-canvas image: fault `encodedData` blob (`.isEmpty` + construction) → rebuild presentation → publish → session sync (PERF-13) → surface configure (PERF-09). Drawing 50 strokes in a session = 50 full image-table blob re-reads.

**User impact:** Disk I/O and main-actor latency proportional to *total image bytes on the board* on every commit; memory footprint = all board image bytes resident + decode cache on top.

**Recommended repair:** Store an `encodedByteCount`/`contentDigest` scalar column on `CanvasImageItem` so cache validation never touches the blob; move `encodedData` out of `CanvasPlacedImage` — decode on demand through the existing `CanvasImageDecodeCache` keyed by `contentToken` (the token already exists precisely to avoid byte comparisons, CanvasImageTypes.swift:211-214); predicate the replica fetches.

**Validation:** Instruments File I/O + Allocations: one stroke commit on a 100 MB board should read ~0 image bytes and allocate ~0 image data; `bytes faulted per save` metric should equal zero for unchanged images.

---

### PERF-09 — Canvas `configure()` does full-object scans + quadratic accessibility rebuild on every published session change (including pan/zoom)

**Severity:** P2 · **Status:** CONFIRMED · **Area:** CanvasSurfaceMac configure

**Evidence**

- `CanvasSession.viewport` is `@Published` — `CanvasSession.swift:27`; pan/zoom publishes per event → `CanvasPanelContent` body → `updateNSView` → `CanvasNSView.configure` (`CanvasSurfaceMac.swift:385-485`).
- Per `configure()`: image-signature map over all images (428-437); `interaction.configure` maps *all* strokes to render keys and array-compares them (`CanvasSurfaceInteraction.swift:42-57`, O(S)); `CanvasImageDecodeCandidatePolicy.candidates` scans all images (`CanvasSurfaceMacHelpers.swift:6-42`, O(I)); `refreshCanvasAccessibilityElements` (`CanvasSurfaceMacHelpers.swift:157-249`) sorts all strokes O(S log S) and all images O(I log I), then per image runs two `contains` scans over `semanticObjects` + `orderedImages` (O(I·(I+S)) total — lines 217-226), per semantic object two `contains` over `placedObjects` (O(O·(I+S)) — lines 248-249), plus label/value string formatting for every element; then `window?.invalidateCursorRects`.
- Additional invalidations with the same downstream: every store revision → `synchronizeFromStore` (PERF-13) publishes `strokes`/`images`/`semanticObjects`; `imageImportProgress`, `pendingPlacement`, `selectedImageID`, `canUndo`/`canRedo` publish on their own cadences — each triggers a full `configure` + AX rebuild.
- Mitigations that already exist: `interaction.configure` early-outs on unchanged content/style/viewport (43-65); `changed` flag gates `needsDisplay` (482); `element.update` reuses existing elements. The AX work runs regardless of whether an AX client is attached.

**Causal chain:** pan one frame → `viewport` publishes → `configure()` → O(S) + O(I) scans + O(S log S + I·(I+S) + O·(I+S)) AX rebuild + cursor-rect invalidation → at 60–120 Hz scroll/wheel events this dominates the canvas main thread.

**User impact:** Pan/zoom jank on populated boards; growing CPU-per-frame with object count; wasted work when VoiceOver is not running.

**Recommended repair:** Gate `refreshCanvasAccessibilityElements` behind (a) `NSAccessibility` client presence and (b) content changes only — never on viewport-only changes; throttle it to once per CATransaction; replace the per-object `contains` scans with precomputed z-order indices; pass a content revision into `configure` so unchanged strokes skip the render-key map.

**Validation:** AX audit + Time Profiler during a 60 fps pan on a 500-object board: `refreshCanvasAccessibilityElements` should not appear unless an AX client is attached; configure time should be O(changed objects).

---

### PERF-10 — Per-pointer-event full sorts in canvas hit-testing

**Severity:** P2 · **Status:** CONFIRMED · **Area:** CanvasSurfaceMac cursor path

**Evidence**

- `mouseMoved` — `CanvasSurfaceMac.swift:538-540` → `cursor(at:)` → `cursorRole(at:)` (`CanvasSurfaceMacHelpers.swift:605-647`): `semanticObject(at:)` (`CanvasSemanticInteraction.swift:103-111`) filters *all* semantic objects and *all* images per call (O(S+I)); `CanvasImagePlacement.topmostImage` (`CanvasImageTypes.swift:422-429`) does `images.sorted(by:)` — O(I log I) — *per mouse-moved event* while the select tool is active.
- `imagesForDisplay` — `CanvasSurfaceMacHelpers.swift:569-580`: returns `images` cheaply (CoW) when no preview is live, but during an image move/resize it maps the *entire* array per access — and it is accessed ~5× per configure/draw/hit-test pass (draw at `CanvasSurfaceMac.swift:550`, placed-objects at 581, AX at 164, cursor at 640, `selectedImage` at 566).
- `mouseDown` select path also calls `topmostImage` (CanvasSurfaceMac.swift:687-691) — bounded per click, fine.

**Causal chain:** pointer motion over the canvas at event rate (60–120 Hz) × O(I log I + S + I) per event; during image drags, ×5 array rebuilds per frame on top.

**User impact:** CPU per mouse-move grows with image count; noticeable on trackpads that emit dense events; energy during long sessions.

**Recommended repair:** Maintain the display image array already z-sorted (sorted once per content change, shared with the renderer's `comesBefore` order at `CanvasSurfaceMac.swift:583`); bounds-cull candidates before sorting; compute `imagesForDisplay` once per frame/transaction and share it across draw/AX/cursor consumers.

**Validation:** Time Profiler during `mouseMoved` storms on a 200-image board — `topmostImage` should drop from per-event O(I log I) to O(I) early-exit or better.

---

### PERF-11 — Canvas undo history retains full payloads, including image bytes

**Severity:** P2 · **Status:** CONFIRMED (retention); real-world magnitude depends on usage · **Area:** CanvasSession history

**Evidence**

- `HistoryCommand` — `CanvasSession.swift:44-52`: `.addImage/.addImages/.deleteImage/.replaceImage/.transformImage` retain `CanvasPlacedImage` (each carrying `encodedData` up to ~8 MB); `.transformImage` holds two; `.clear` holds `CanvasBoardContents` — *all* strokes, images, and semantic objects on the board (`CanvasSession.swift:923-939`).
- Cap: `maximumHistoryCount = 100` (line 71), trimmed at 1404-1411 — worst case ≈ 100 × multi-MB payloads.
- `Data` is CoW-shared with the live presentation, so undoing still-live images costs only the reference — the real cost is *deleted* content staying fully resident: a batch import of 10 images keeps ~80 MB alive until the command ages out; `.clear` keeps the whole board's bytes alive for 100 further commands.
- `.addStroke`/`.eraseStrokes` retain full `CanvasStroke` point arrays — a long stroke ≈ thousands of `CanvasPoint`s.

**User impact:** Memory footprint grows with image-heavy undo usage; deleted content lingers for up to 100 commands.

**Recommended repair:** Record image commands by identity + contentToken and re-materialize bytes from the store on undo/redo (the file is durable); or cap history by payload byte budget rather than count; drop `encodedData` from `CanvasPlacedImage` entirely (PERF-08 fix subsumes most of this).

**Validation:** Allocations: import 10×8 MB images, delete them, confirm resident bytes ≈ 0 after the change; undo still restores pixels correctly.

---

### PERF-12 — Notes: per-keystroke O(document) signatures, per-card full-body UTF-16 diffs, and unconditional `NSHostingView` re-renders

**Severity:** P2 · **Status:** CONFIRMED · **Area:** NoteAttachmentTray / NoteInlineCards / inlineCards

**Evidence**

- Keystroke path — `AttachmentAwareTextEditor` coordinator `textDidChange` (`NoteAttachmentTray.swift:1317-1327`): updates the binding (publishes `noteDraft.body`), invalidates layout, calls `document.layoutDocument(viewport:)` (829-897) — which reads accessory + header `fittingSize` and `usedRect` per keystroke — then captures view state (1329-1338 on selection/commit too).
- `NoteComposerView.inlineCards` — `NotesPanelContent.swift:308-320`: rebuilt on every `noteDraft.body` publish → `notes.first` scan + `attachments(for:)` + per attachment `NoteInlineAnchor.moved` (`NoteInlineAnchor.swift:12-23`) which allocates `Array(oldText.utf16)` **and** `Array(newText.utf16)` — two full UTF-16 copies of the whole note *per card per keystroke* — plus `AnyView` card construction.
- `NoteInlineCardsLayout.update` — `NoteInlineCards.swift:182-200`: `host.rootView = card.content` (189) is unconditional — every inline attachment card's entire SwiftUI subtree re-renders on every keystroke.
- `reserveSpace` — `NoteInlineCards.swift:203-233`: `signature = textView.string + cards…` (206) copies the entire document string per call; when the signature differs (every keystroke, since `textView.string` changes), it `removeAttribute(.paragraphStyle)` over the *whole* storage (218) then re-adds per-paragraph styles — O(document) attribute churn per keystroke when cards exist.
- `NoteInlineAnchor.paragraphStart` (`NoteInlineAnchor.swift:4-9`) runs `paragraphRange` per card in both `reserveSpace` (207) and `layout` (238).
- The autosave itself is well-designed (see PASS-08): the finding is the synchronous per-keystroke layout/signature work.

**Causal chain:** keystroke → `textDidChange` → publish → `inlineCards` rebuild (O(body) per card) → `updateNSView` → `inlineLayout.update` (all cards re-render) + `reserveSpace` (full-string signature + possible full-doc attribute strip) + `layoutDocument` (fitting sizes + `usedRect`) → all on the main actor.

**User impact:** Typing lag in attachment-bearing notes that grows with note length and card count; visible in large notes even at small attachment counts.

**Recommended repair:** Track anchor offsets incrementally from `NSTextStorage` edit deltas (the editor already sees `editedRange`) instead of re-diffing whole-body UTF-16 arrays; make the signature independent of `textView.string` (e.g., cards' own offset/height list — the string is already implied by `appliedSignature` only needing card changes); set `host.rootView` only when a card's content identity actually changed; skip `reserveSpace` when `cards` is empty and `appliedSignature` is empty (line 204 already early-outs — keep that fast path dominant).

**Validation:** Time Profiler typing test on a 50 KB note with 5 inline cards: per-keystroke cost should be O(edit) not O(document); confirm card frames/positions still correct after refactors (anchor behavior is subtle — keep `paragraphStart` semantics).

---

### PERF-13 — Canvas revision sync rebuilds and compares full signature arrays per save

**Severity:** P3 · **Status:** CONFIRMED (cost is real but elements are small) · **Area:** CanvasSession store sync

**Evidence**

- `handleStoreRevision` — `CanvasSession.swift:1426-1441`: builds `SemanticSnapshot` (76-150) — allocates a signature struct for *every* board/stroke/image/semantic object — then `snapshot != lastSemanticSnapshot` compares all elements.
- `synchronizeFromStore` (1443-1483): copies `strokes`/`images`/`semanticObjects` arrays (CoW-cheap) and publishes each → downstream `configure` (PERF-09).
- Trigger: every `store.revision` bump — i.e., every save, every reveal refresh, every image import batch step.

**Causal chain:** O(objects) signature alloc + compare + array copies per revision. Signatures are small (id + transform + versions — no byte data — good design), so this is a scaling tax rather than a cliff; it matters mainly as the trigger for PERF-09.

**Recommended repair:** Have the store publish a changed-keys set alongside `revision` so the session applies deltas; keep the snapshot compare as the fallback.

**Validation:** Signpost `handleStoreRevision`; a single-stroke save should sync O(1) objects.

---

### PERF-14 — NoteStore refresh does full-table fetches + index rebuild + file reconcile per revision

**Severity:** P3 · **Status:** CONFIRMED (bounded cadence, linear cost) · **Area:** NoteStore

**Evidence**

- `reloadModels` — `NoteStore.swift:710-718` → `presentationSnapshot` (729-738): fetches *all* `NoteItem` + *all* `NoteAttachment` rows unpredicated; `installPresentation` (740-752) rebuilds `attachmentsByNoteID` and calls `reconcileFileStorage` (751), which runs metadata reconciliation work over the full attachment set.
- `orderedNotes()` — `NoteStore.swift:643-650`: O(N log N) sort per call, called per body eval at `NotesPanelContent.swift:55` and three times per note revision at `AtticPanelView.swift:793-805`.
- `attachments(for:)` is a dict hit (`NoteStore.swift:265-267`) — good.

**Causal chain:** every note save (autosave at up to ~2/s during typing) → revision bump → note-list re-sort ×4 + row re-evals; every reveal refresh → two full fetches + attachment index rebuild + reconcile task.

**Recommended repair:** Memoize `orderedNotes` per revision (same pattern as `snapshotCache`); predicate attachment fetch on `noteID` set or watermark.

**Validation:** Notes of size 500+: refresh cost should be O(changed rows).

---

### PERF-15 — Daily cleanup / wake triggers full refresh + multi-pass purge scans

**Severity:** P3 · **Status:** CONFIRMED (bounded cadence) · **Area:** DailyCleanupService + purgeCompleted

**Evidence**

- `cleanupAndReschedule` — `DailyCleanupService.swift:68-75`: `store.refresh()` (full reload) + `purgeCompleted` on each trigger: midnight `Timer` (tolerance 1 s — good), day-change, timezone-change, app-activation, and workspace-wake notifications (23-49).
- `purgeCompleted` internals are PERF-04's multi-pass cost (full fetch + group + fixpoint family-closure + attachment decode).

**Causal chain:** each wake/activation → O(all tasks) refresh + O(passes × all tasks) purge. Cadence is honest (single timer, event-driven) — the cost is the scan shape, at most a few times/day.

**Recommended repair:** Skip `refresh()` when the local store is authoritative and unchanged (revision watermark); predicate the purge fetch on `completedAt < cutoff`.

**Validation:** Log cleanup duration at 10k tasks; should be sub-10 ms when nothing expired.

---

## Areas reviewed and found sound (PASS)

- **PASS-01 — No perpetual animation timelines.** No `TimelineView` anywhere; all animation is event-driven short springs (`AtticMotion.spring/quick`, `PanelSurfaceMotionContainer` Core Animation transforms — `PanelSurfaceHostingView.swift:248-285`); `animatePanel` skips restarting when the target frame is unchanged.
- **PASS-02 — Canvas renderer culling + path caching.** `CanvasSurfaceRenderer.swift:7-40` caches `CGPath` per stroke keyed by `renderToken`; draw culls to a 64 pt viewport margin (444-451, 470, 491); placed-object render objects sort once per draw then cull (`CanvasSurfaceMac.swift:580-594`).
- **PASS-03 — Canvas image decode pipeline.** `CanvasImageDecodeCandidatePolicy` (`CanvasSurfaceMacHelpers.swift:6-42`) bounds work to visible + 192 pt prefetch margin; `CanvasImageDecodeCache` is NSCache-bounded with 3-way off-main concurrency; retry/`failedImageIDs` bookkeeping exists (`CanvasSurfaceRenderer.swift:105-180`).
- **PASS-04 — Task thumbnail pipeline.** `TaskImageFiles.thumbnail` (`TaskImageReference.swift:135-154`): actor-isolated, digest-keyed 64-entry cache, ImageIO downscale ≤512 px off-main; `TaskImageThumbnail.task(id: digest)` (`TaskImageAttachments.swift:21-25`) re-fires only on content change.
- **PASS-05 — Attachment import is streamed and bounded.** `AttachmentFileStore.importOne` (`AttachmentFileStore.swift:403-512`): actor, 1 MB chunked FileHandle streaming + incremental SHA-256, 15 MB caps, file coordination, security-scope balancing; staging cleanup for stale temp files (382-390).
- **PASS-06 — Canvas image import is capped and off-actor.** `CanvasImageImporter` (`CanvasImageImporter.swift:104-215`): input byte caps, mapped reads, progressive downscale to an 8 MB encoded ceiling, `Task.checkCancellation` throughout; called from session import tasks (`maximumConcurrentImageImports = 2`).
- **PASS-07 — Monitor/timer hygiene.** Corner monitors removed on `stop()` (`CornerHoverMonitor.swift:359-368`); hosting view `deinit` removes escape/mouse-up monitors + cancels watchdog (`AtticPanel.swift:936-947`); `AtticPanelController.deinit` removes passthrough monitors (278-285); `GlobalHotKey` unregisters both Carbon refs (`GlobalHotKey.swift:80-85`); DailyCleanup uses one non-repeating midnight timer with 1 s tolerance (`DailyCleanupService.swift:78-90`).
- **PASS-08 — Note autosave cadence.** `NoteDraftController` (`NoteDraftController.swift:598-641`): 500 ms trailing debounce + a separate maximum deadline that typing does *not* extend (603-609); flush on hide/terminate (`AppCoordinator.swift:370-399`); recovery file written off-actor. The per-keystroke layout cost is PERF-12, not autosave.
- **PASS-09 — Canvas viewport persistence.** Debounced 400 ms (`CanvasSession.swift:1270-1321`), encodes then compares before writing to UserDefaults — no redundant plist churn.
- **PASS-10 — CloudKit dormant locally.** `ATTIC_LOCAL_ONLY` builds never install remote-change work; `NoteStore.handleCloudSyncEvent` early-returns (NoteStore.swift:662-664); activity tokens only exist on non-local builds.
- **PASS-11 — Drag payload construction is lazy.** `TaskDragPayload.itemProvider` registers completion-based data reps (`TaskDragPayload.swift:84-105`); file-promise deliveries have cleanup for late arrivals (`CanvasSurfaceMacHelpers.swift:917+`); `beginDragging` on preview appearance is one-shot per drag.
- **PASS-12 — Corner monitor idle cadence.** When disarmed, sampling drops to 1 s/250 ms leeway (`CornerHoverStateMachine.swift:32-44`) — confirmed by the idle samples; the finding is the *armed/visible* policy, not a leak.
- **PASS-13 — Hit-testing policy geometry.** `AtticPanel.hitTest`/`updateMousePassthrough` (`AtticPanel.swift:956-990`, `AtticPanelController.swift:316-358`) do bounded per-event geometry (Squircle contains + resize-edge policy) with no scans or layout.

## Cross-cutting notes

- **Replica-safe mutation is intentional, not accidental.** `storedTaskGroups`/`storedXReplicas` fetch-then-filter exists because UUIDs aren't DB-unique (TaskStore.swift:896-920, contract item in AGENTS.md). Every PERF-04/08 repair must keep mutate-every-replica semantics — predicate the *fetch*, keep the *grouping*.
- **Fresh-context reloads are the CloudKit-correctness pattern** (comments at TaskStore.swift:885-889, NoteStore.swift:711-714). Keep them; gate their *frequency* (PERF-05) rather than their mechanism.
- **Main-actor concentration.** `TaskStore`, `NoteStore`, `CanvasStore`, `CanvasSession`, `PanelUIState`, and all controllers are `@MainActor`. Every finding above lands on the main thread; there is no background offload anywhere in the mutation paths — worth noting as a systemic property for the repair lane.

## Suggested profiling acceptance tests (for the repair lane)

1. `powermetrics`/`sample` 60 s with panel open and idle → expect zero `beginActivity` holds and zero 50 ms timer wakeups (PERF-07).
2. Time Profiler: rename one task at 6,000 tasks → `subtasks(of:)`/`parent(of:)`/`attachments` frames < 1% (PERF-01/02/03).
3. Time Profiler: single keystroke in note with 5 inline cards, 50 KB body → per-keystroke cost bounded by edit range, not document length (PERF-12).
4. File I/O trace: one stroke commit on a 100 MB image board → ≤KBs of blob reads (PERF-08).
5. AX-disabled Time Profiler: 60 fps canvas pan on 500-object board → no `refreshCanvasAccessibilityElements` in the trace (PERF-09).
6. SwiftData/Instruments: one status toggle → ≤2 predicate-sized fetches (PERF-04).
7. Signposted reveal at 10k total records → reveal-to-interactive independent of data size when nothing changed (PERF-05).

## Scope notes

- This audit covers the active checkout including its dirty tree (notably the rewritten `SubtaskPanelController.swift`); the older Attic checkout was not reviewed.
- CloudKit/APNs/iPhone paths were reviewed for *presence and dormancy* only; no claim is made about their runtime behavior, consistent with the development contract.
- All file:line references were re-verified against the dirty working tree at audit time.
