# Rolling Performance Audit — Canvas, Notes, Task Hot Paths

**Auditor:** read-only SWE-2 Max performance audit
**Repository:** `/Users/taha/Developer/attic-task-panels-v2`
**Branch:** `codex/attic-task-panels-v2`
**HEAD:** `ae6418c1af690e29d15a20344cdb9765a23d3f85` (`ae6418c`)
**Worktree:** intentionally dirty; another worker's task-panels/swipe-removal changes are in flight. All citations are to the **current working-tree source**, not HEAD.
**Owned file:** `Docs/Rolling-Performance-Audit.md` only. No source, test, or project file was modified.

## Scope and validation limits

This audit reviewed current source for the Canvas, Notes, and task/panel hot
paths: repeated work, lag risk, memory retention, and background wakeups. It
re-verified the findings register in `Docs/ConcurrentSWEReview-Performance.md`
and `Docs/ConsolidatedDefectChecklist-2026-09-13.md` against the present code.

**What this audit did:** read source, traced callers and object lifecycles,
compared current code against prior findings.

**What this audit did not do (per task constraints):** build, run tests,
profile, launch or relaunch the app, operate the native pointer, or measure
frames/CPU/memory. Therefore:

- No frame-rate, latency, CPU, memory, or wakeup numbers are claimed. All
  impact magnitudes are hypotheses; only mechanisms are confirmed by source.
- The 24 ms replacement sample recorded in
  `Docs/PersonalChromeCheckpoint-2026-09-14.md` is diagnostics-inclusive and is
  not a frame-pacing benchmark; nothing here relies on it.

**Confidence labels used below:**

- `CONFIRMED` — the full causal chain is verified in current source.
- `STRONG EVIDENCE` — the cost exists; its user-visible magnitude needs profiling.
- `UNVERIFIED` — cannot be determined from source alone.
- `PASS` — reviewed and found sound in current source.
- `RESIDUAL` — prior defect repaired; a smaller bounded remainder noted.

## Current findings

### PERF-A1 — Canvas mutations pay ~9 full-table fetches across two contexts per save, and re-fault every visible stroke's payload — `CONFIRMED` mechanism, `UNVERIFIED` magnitude

**Where:**

- `Attic/Services/CanvasStore.swift:85-97` — `CanvasStoredReplicas.load(from:)`
  issues `context.fetch(FetchDescriptor<CanvasBoardItem>())`,
  `<CanvasStrokeItem>()`, `<CanvasImageItem>()`, and (macOS)
  `<CanvasSemanticObjectItem>()` with **no predicate** — every board, stroke,
  image, and semantic row in the store, across all canvases, tombstoned or not.
- `Attic/Services/CanvasStorePersistence.swift:25-84` — `save()` runs
  `resolveCanvasPresentation(using: context, …)` (line 31) **before**
  `persist` (line 54) and then `reloadCanvas(reusing: savedPresentation)`
  (line 61), which builds a **fresh** `ModelContext` (line 93) and resolves
  again (lines 94-99). `resolveCanvasPresentation` calls `loadReplicas` at
  line 110 — so one `save()` performs two full sets of unpredicated fetches.
- `Attic/Services/CanvasStorePersistence.swift:492-520` —
  `storedBoardReplicas(matching:)`, `storedStrokeReplicas(matching:)`, and
  `storedImageReplicas(matching:)` each fetch the **entire** table and filter
  in memory (`canvasID == selectedCanvasID && ids.contains($0.id)`).
  `tombstoneAllContent` (lines 522-570) adds two more full fetches plus
  `tombstoneSemanticObjects`.
- `Attic/Services/CanvasStore.swift:201-208` —
  `CanvasStrokeCacheEntry.representsSameCommittedValue` compares
  `payloadByteCount == replica.payload.count` (line 203); `rebound(to:)` reads
  `replica.payload.count` again (line 214); the decode path reads
  `replica.payload` (lines 223, 238). `CanvasStrokeItem.payload` is a plain
  `Data` stored property (`Attic/Models/CanvasStrokeItem.swift:11`) with **no
  external storage and no scalar byte-count column** — reading `.count`
  materializes the whole payload. So in the fresh-context resolve, every
  visible stroke's payload bytes are re-read on every save.
- Contrast: `CanvasImageItem` carries scalar `encodedByteCount`/`contentDigest`
  columns (`Attic/Models/CanvasImageItem.swift:58-60`) so image cache matching
  avoids the blob (`resolvedPayloadMetadata`, `hasEncodedPayload`,
  lines 122-149). `payloadByteCount` exists only on the stroke **cache entry**
  (`CanvasStore.swift:189`), not on the row — the stroke side of the
  CANVAS-016/PERF-08 repair was never applied to the model.

**Trigger (caller/lifecycle trace):** every committed Canvas mutation —
`addStroke` calls `ensureSelectedBoardReplicaExists` (full board fetch) and
`storedStrokeReplicas` (full stroke fetch) at
`Attic/Services/CanvasStoreStrokes.swift:28-29`, then `save()` (line 65);
`setDeleted` (`:78`), `stageStrokeRestore` (`:142`); image mutations at
`CanvasStoreImages.swift:57, 247, 283, 339`; board ops at
`CanvasStoreBoards.swift:57, 115, 152`; `CanvasStoreLifecycle.swift:18`;
`discardPendingChanges`/`reloadCanvas` on error paths
(`CanvasStorePersistence.swift:11-22`). Undo/redo commits and `refresh()`
take the same `loadReplicas` path. Net per `addStroke`: ~1 board-table fetch +
1 stroke-table fetch + persist + 2×(3-4 full-table fetches) + per-visible-
stroke payload materialization on the fresh context.

**Expected impact (hypothesis, unverified):** per-mutation main-actor
persistence work that scales with *total stored Canvas rows across all
boards* plus the selected board's inked bytes — not with the mutation itself.
On a heavily-used board, each stroke commit becomes a multi-hundred-row,
two-context round trip. Likely sub-millisecond-to-low-millisecond at small
store sizes; grows with history and board count.

**Bounded suggested fix (semantics-preserving):**

1. Predicate the mutation helpers with the exact existing in-memory filters:
   `storedBoardReplicas` → `id == target`; `storedStrokeReplicas` /
   `storedImageReplicas` → `canvasID == selectedCanvasID && id ∈ ids`;
   `tombstoneAllContent` → `canvasID == target`. The current filters already
   scope to the selected canvas, so replica-fan-out semantics are unchanged —
   every physical replica of a mutated id is still returned.
2. In `resolveCanvasPresentation`, fetch boards first (full fetch — the board
   list *is* the output), resolve the selection, then fetch strokes/images/
   semantic objects predicated on `canvasID ∈ {resolvedSelectedCanvasID,
   CanvasBoardItem.logicalBoardID}` — the logical board is required by the
   legacy-default detection at lines 146-155; replicas claiming other
   canvases are already discarded at lines 185/256, so observable output is
   preserved.
3. Add scalar `payloadByteCount` (and optionally `contentDigest`) columns to
   `CanvasStrokeItem`, written on insert/update and backfilled lazily the same
   way `backfillLegacyImagePayloadMetadata` does for images
   (`CanvasStorePersistence.swift:459-472`), so cache matching never touches
   `payload`; the blob is then read only on a true decode miss.

**Proposed measurement:** `loadReplicas` is already an injectable seam
(`CanvasStore.swift:348, 379-391`). XCTest: seed N boards × M strokes
(including tombstoned rows and a second canvas), commit one `addStroke`, and
assert fetched-row counts are O(matched replicas) rather than O(all rows) —
plus a payload-access counter on `CanvasStrokeItem` mirroring
`CanvasImagePayloadAccessCounter` asserting zero `payload` faults for
unchanged strokes. `os_signpost`/`Instruments` on `save()` wall time before
and after, on a seeded multi-board store.

---

### PERF-A2 — Every keystroke in the Notes composer re-renders and re-measures hosted SwiftUI subtrees, and the card-resolver still does O(document) string compares — `CONFIRMED` mechanism, `UNVERIFIED` magnitude

**Where:**

- `NoteDraftController.body` is `@Published`
  (`Attic/Services/NoteDraftController.swift:128-130`); `draftDidChange`
  (`:591-596`) also flips `isDirty` and bumps `generation`. `NoteComposerView`
  observes `noteDraft` (`Attic/Views/Panel/NotesPanelContent.swift:142`), so
  each keystroke re-evaluates the composer body and calls
  `AttachmentAwareTextEditor.updateNSView`
  (`Attic/Views/Panel/NoteAttachmentTray.swift:1147-1199`).
- `updateNSView` unconditionally re-hosts both embedded subtrees:
  `document.updateHeader` (`:1161` → `updateHeaderWidth` →
  `header.rootView = AnyView(…)`, `:996-1000`) and `document.updateAccessories`
  (`:1163` → `:990-994`). The header is always present
  (`hasDocumentHeader: true`, `NotesPanelContent.swift:296`) and contains
  `noteHeader` (`:359-396`), whose `saveStatus` allocates a
  `RelativeDateTimeFormatter` and calls `Date()` on every evaluation
  (`:466-468`). The accessories subtree holds the whole
  `NoteAttachmentTray`/card column (`:318-351`).
- `layoutDocument` (`:1165` → `:933-988`) reads `header.fittingSize` and
  `accessories.fittingSize` on **every** call when present (`:949-950`), and
  it is also invoked from `NoteDocumentScrollView.layout()` (`:857-862`) and
  `NoteEditorDocumentView.layout()` (`:926-931`) — so every document layout
  pass re-measures the hosted subtrees even when only the text changed.
- `NoteInlineCardResolver.resolve` runs per body evaluation
  (`NotesPanelContent.swift:314-316`, consumed at `:299-300`). Its memo `Key`
  stores the full `body` and `savedBody` strings and `key == cachedKey`
  compares them (`NoteInlineCards.swift:318-342`); on a miss,
  `ledger.replacement(from:to:)` performs two more whole-document equality
  checks (`anchorText == oldText`, `currentText == newText`,
  `NoteInlineCards.swift:281-298`) before its O(1) rebase. The resolver's own
  comment notes the panel "republishes several times per keystroke"
  (`:301-304`), so the O(document) compares are paid several times per
  keystroke, not once.

**Trigger:** every keystroke (and every non-body `noteDraft` publish — dirty
flip, error banner, import state) while the composer is open; `layoutDocument`
additionally re-measures on every scroll-view layout pass.

**Expected impact (hypothesis, unverified):** per-keystroke main-actor work
that grows with document byte size (3-4 near-full string comparisons) and
attachment-subtree size (rootView replacement + `fittingSize` measurement).
For typical short notes this is likely sub-millisecond and acceptable; for
long notes with several attachments it is the dominant *remaining*
per-keystroke cost now that the per-card UTF-16 diffs and unconditional card
re-renders of PERF-12 are gone from the typing path.

**Bounded suggested fix:**

- Add a monotonic `bodyRevision: UInt64` to `NoteDraftController` (bumped in
  `draftDidChange`) and key `NoteInlineCardResolver.Key` on it plus
  `noteStore.revision` instead of the raw strings; key the ledger's
  incremental check on `(savedRevision, bodyRevision)` with its existing
  length self-check, removing the two full-string compares.
- Gate `updateHeader`/`updateAccessories` on a content token (the header's
  real inputs: title, save-status inputs, palette) and skip `rootView`
  assignment when unchanged; memoize the measured `fittingSize` keyed on
  `(width, token)` so unrelated layout passes don't re-measure.
- Hoist `RelativeDateTimeFormatter` in `saveStatus` to a shared instance.

**Proposed measurement:** `os_signpost` intervals around `updateNSView`,
`layoutDocument`, and `resolve`; assert `updateHeaderWidth`/`updateAccessoryWidth`
call counts per keystroke drop to content-change-only (the resolver already
exposes `rebuilds`/`fullDiffs`/`incrementalRebases` counters at
`NoteInlineCards.swift:248-249, 316`). Type into a large seeded note
(~100 KB body, several inline attachments) under a body-eval counter or
SwiftUI Instruments template.

---

### PERF-A3 — `NoteStore.update` recomputes a whole-document UTF-16 diff once per inline attachment per autosave — `CONFIRMED` mechanism, `UNVERIFIED` magnitude

**Where:**

- `Attic/Services/NoteStore.swift:188-232` — when `bodyChanged`, `update`
  loops `storedAttachments(forNoteID:)` (`:213-218`) and calls
  `NoteInlineAnchor.moved(offset, from: note.body, to: destinationBody)` once
  **per inline attachment**.
- `Attic/Models/NoteInlineAnchor.swift:77-80` — `moved(from:to:)` delegates to
  `NoteTextReplacement.diffing(oldText, newText)`, which allocates two
  whole-document `[UInt16]` arrays and runs an O(document) prefix/suffix scan
  (`:52-64`). The comment says diffing is "the fallback … never the typing
  path" — but the save path invokes it k times per save, once per anchored
  attachment. `moved(_:by:in:)` (`:83-85`) already provides the O(1)
  single-replacement entry point.

**Trigger:** each debounced autosave (`NoteDraftController.swift:598-631`,
500 ms trailing / 5 s maximum) and each explicit `flush()` → `update`
(`:388-431`, call at `:423`) while the dirty note has inline attachments.
Also `onMoveAttachment` → `noteStore.placeAttachment` and any other
body-changing `update` caller.

**Expected impact (hypothesis, unverified):** k × O(document) allocation and
scan on the main actor per save where one diff suffices. Small for typical
notes; scales linearly with body size × inline-attachment count during
continuous typing (autosave fires up to ~2/s while dirty).

**Bounded suggested fix:** compute
`let replacement = NoteTextReplacement.diffing(note.body, destinationBody)`
once inside `if bodyChanged`, then call
`NoteInlineAnchor.moved(offset, by: replacement, in: destinationBody)` per
attachment — identical offsets, k× less work. Optionally plumb the editor's
ledger-composed replacement through `flush()` → `update` so the typing path
pays zero diffs; the ledger's self-check already guarantees correctness of
the composed replacement.

**Proposed measurement:** add a `diffing` invocation counter (same pattern as
the existing `attachmentReconciliationPasses`/`fullDiffs` seams) and assert
≤1 diff per body-changing `update` regardless of attachment count; time
`update` on a large seeded note with k inline attachments.

## Verified repaired in current source (excluded from findings)

Re-checked against the working tree; not repeated as current defects:

- **Task family lookups** — `TaskStore.subtasks(of:)`/`hasSubtasks`/`parent(of:)`
  use the `familyIndex` maps; `snapshot(for:)` is memoized per revision.
  (prior PERF-01) — `PASS`.
- **Per-row attachment JSON decode** — `TaskItem.attachments` caches decoded
  references in `@Transient` state keyed on `imageReferencesData`. (PERF-02) —
  `PASS`.
- **Store-wide row invalidation** — `TaskRowView` is `Equatable` with value
  inputs and observes no store publisher
  (`Attic/Views/Panel/TaskRowView.swift:17-47`); rename text lives in a
  dedicated `TaskRenameDraft`. Residual: `uiState`/`store` publishes still
  re-evaluate each visible `TaskFamilyView` body, but each is now O(1)
  (`TaskFamilyView.swift:17-29`). (PERF-03) — `RESIDUAL`, bounded.
- **Reveal-time full-store refresh** — `RevealRefreshPolicy.current` is
  `.inProcessAuthoritative` under `ATTIC_LOCAL_ONLY`, so
  `refreshStoreForReveal` performs no refresh
  (`Attic/Services/CornerHoverMonitor.swift:5-40, 487-493`). (PERF-04) —
  `PASS` for local-only builds; cloud-enabled path is deferred scope.
- **50 ms timer + `.userInitiated` activity while visible** — cadence is now
  `.idle` = 1 s (hidden, far), `.responsive` = 50 ms (hidden, near corner),
  `.eventDriven` = no timer while visible; the activity assertion is held
  only for `.responsive`
  (`Attic/Services/CornerHoverStateMachine.swift:36-63`,
  `CornerHoverMonitor.swift:376-423`). Residual: a 1 Hz safety-net timer plus
  always-on local+global pointer monitors run whenever the app is hidden —
  a deliberate, bounded trade-off (~1 wakeup/s with 250 ms leeway), not a
  defect. (PERF-05/06) — `RESIDUAL`, bounded.
- **Canvas save re-faulting image blobs** — scalar `encodedByteCount`/
  `contentDigest` validation and `resolvedPayloadMetadata`/`hasEncodedPayload`
  replace per-save blob reads; `backfillLegacyImagePayloadMetadata` migrates
  old rows (`CanvasStorePersistence.swift:283-292, 459-472`). (CANVAS-016/
  PERF-08 image side) — `PASS` (stroke side: see PERF-A1).
- **Per-scroll-frame `fittingSize` on subtask surfaces** — `updateTaskRowFrames`
  is change-gated and coalesced to ≤1 `repositionTransient` per run-loop turn,
  only while a transient surface is live; `applyFrame` early-outs on unchanged
  frames (`Attic/Window/SubtaskPanelController.swift:202-231, 827-936`).
  (PERF-06/TP-011) — `RESIDUAL`, bounded to one hosted-layout measure per
  frame while scrolling with a family panel open.
- **Canvas undo memory** — history entries estimate payload bytes and evict
  to a 64 MB budget. (CANVAS-010/PERF-11) — `PASS`.
- **Canvas full-array revision comparisons** — the store publishes
  `lastContentChange`/`contentRevision`/`publishedStrokeFingerprint`
  (`CanvasStore.swift:114-184`, `CanvasStorePersistence.swift:440-448`);
  `CanvasSession` consumes incremental deltas. (PERF-13) — `PASS`.
- **Per-pointer image sorting / unconditional AX rebuilds** — `CanvasImageDisplayCache`
  keys display/z/hit-test order on content revision + live preview
  (`CanvasSurfaceMacHelpers.swift:44-60`); `configure()` defers AX rebuilds to
  content changes and gates cursor-rect invalidation on role changes
  (`CanvasSurfaceMac.swift:413-539`); `interaction.configure` compares cheap
  `(id, renderToken)` keys (`CanvasSurfaceInteraction.swift:38-80`,
  `CanvasTypes.swift:341-343`). (PERF-09/10, CANVAS-017/018) — `PASS`.
- **Notes typing path (prior)** — per-card UTF-16 diffs replaced by the edit
  ledger + O(1) rebase; `reserveSpace` signs only card paragraphs;
  `NoteInlineCardResolver` memoizes per publish
  (`NoteInlineCards.swift:238-342`). (PERF-12/NOTES-013 typing side) —
  `RESIDUAL` — see PERF-A2/A3 for what remains.
- **Notes store** — `storedNotesIfPresent` is predicated
  (`NoteStore.swift:882-893`), `orderedNotes()`/`note(withID:)` are memoized
  per revision (`:668-696`), `attachments(for:)` is a dict lookup (`:277-279`),
  `save()` does not reload (`:737-754`). (PERF-14) — `PASS`.
- **Notes autosave** — debounced, cancellable, generation-checked, maximum-
  deadline, no polling (`NoteDraftController.swift:591-644`). — `PASS`.
- **Daily cleanup** — single next-midnight timer, event-driven re-arms, skips
  `store.refresh()` in local-only mode, calls `purgeCompleted` directly
  (`DailyCleanupService.swift:89-94`). (PERF-09/PERF-009) — `PASS`.
- **Pointer passthrough / drag watchdogs** — monitors are installed only
  while needed and do O(1) work per event; the capture watchdog timer exists
  only during an active resize/move
  (`AtticPanelController.swift:1134-1170`, `AtticPanel.swift:1191-1252`) —
  `PASS`.
- **Task attachment thumbnails** — `TaskImageThumbnail` loads via
  `.task(id: reference.digest)` — digest-keyed, async, decoded off the render
  pass (`TaskImageAttachments.swift:5-28`). — `PASS`.

## Insufficient evidence / not determined

- **All impact magnitudes above.** No profiling was permitted. Each finding
  states a confirmed mechanism; whether the cost is user-visible at realistic
  store/document sizes requires the proposed Instruments/`powermetrics`/
  signpost measurements.
- **Realistic store sizes.** The Canvas finding's severity depends on total
  stored rows across all boards; no telemetry or fixture data in the repo
  establishes a typical ceiling.
- **Whether `NSHostingView.fittingSize` cost is meaningful at header/tray
  subtree sizes** — confirmed per-call measurement, unmeasured magnitude.
- **Idle-state wakeup floor.** The 1 Hz hidden-state timer plus global event
  monitors are the resting-state cost floor; whether removing the timer loses
  real corner-coverage edge cases (stationary pointer inside the hotspot after
  display changes) was not fully determinable from source — the comment
  presents it as a deliberate safety net.

## Suggested priority order for a future implementation worker

1. **PERF-A1** — Canvas persistence: predicate the replica fetches and add
   the stroke scalar payload column. Largest scaling exposure; sits on every
   drawing mutation; the fix mirrors an already-landed pattern.
2. **PERF-A3** — hoist the per-attachment document diff in `NoteStore.update`.
   Trivially bounded, semantics-identical.
3. **PERF-A2** — identity-gate the hosted header/accessory re-render +
   measurement and the resolver's string compares. Larger surface area;
   highest per-keystroke leverage when notes grow.

No source, test, or project files were modified by this audit.
