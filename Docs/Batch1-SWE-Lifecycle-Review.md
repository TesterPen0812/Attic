# Batch 1 — Independent SWE Lifecycle Review

**Reviewer:** independent read-only audit (this pass). No source edits, commits, pushes, UI launches, or relaunches were performed. No additional agents were used.
**Scope:** import lifetime and transient interruption vs. legitimate board/termination teardown, session ownership, native bridge caches, input cancellation, races, and failed board-operation undo/placement preservation — for findings `RUN-001`, `RUN-002`, `CVD-01`, `CVD-02`, `CVD-05`.
**Materials:** `Docs/DeepAudit-Batch1-Implementation.md` (full), `Docs/DeepAudit-Consolidated-2026-09-15.md` Batch 1, `Docs/DeepAudit-Canvas-2026-09-14.md` (CVD-01/02/05), `Docs/DeepAudit-Runtime-2026-09-14.md` (RUN-001/002), live source, and the `/tmp/attic-batch1` snapshot artifacts.

## 1. Provenance — verified independently, not taken on trust

- The `pre/` files are **not** `HEAD`: they are `git archive HEAD` + pre-existing dirty hunks. Re-hashing all nine owned files reproduced the document's "before" sha256s exactly; current files match the "after" sha256s.
- `batch1-own.diff` (sha256 `f565b48c…`) was regenerated against the rebuilt pre-edit files and the diff bodies match — it contains only Batch 1 hunks, +333/−19 across 9 files.
- `status-before.txt` vs `status-after.txt` differ only by ` M AtticTests/CanvasImageTests.swift` and ` M AtticTests/CanvasSessionTests.swift` (clean at HEAD before). `CanvasDomainTests.swift` was already dirty before the batch. All 151 other porcelain entries — the user's extensive unrelated dirty work — are untouched.
- `CanvasSurfaceInteraction.swift` and `CanvasSurfaceMacHelpers.swift` are byte-identical to their snapshots. `AppCoordinator.swift` untouched.
- Claimed test artifacts exist and match: `batch1-focused.log` 15/15 pass; `batch1-mutant.log` 5 tests / 40 failures (each new test detects its defect); `batch1-full-unit-2.log` 805 tests, 4 skipped, 0 failures; `build-for-testing-2.log` `TEST BUILD SUCCEEDED`.

## 2. Confirmed findings

**None.** No defects were confirmed within the review scope. Section 4 lists the counterexamples probed and why they resolve correctly; section 5 lists residual observations that are pre-existing, declared, or out of scope — none introduced by this batch.

## 3. Per-finding assessment

### RUN-001 / RUN-002 / CVD-01 — transient teardown — correctly split

- `CanvasSession.interactionInterruptions` (`CanvasSession.swift:48`) is a `PassthroughSubject` delivered synchronously from `interruptActiveInteraction()` (`:1441-1444`: `flushViewState()` + `send()`, no epoch bump). `cancelActiveInteraction()` (`:1431-1435`) remains the lifecycle path and now calls `cancelAllImageImportBatches()` **directly** before `interactionCancellationEpoch &+= 1` — previously import cancellation was indirect, via `.id` rebuild → `dismantleNSView` → `deactivateRepresentation` → `onCancelImageImportBatches`. The new ordering is strictly better: cancellation no longer depends on SwiftUI's teardown timing (relevant to `prepareForTermination`, where a deferred rebuild might never run before exit).
- Delivery: `CanvasNSViewRepresentable.configure` installs the sink once, only while `isRepresentationActive` and when no observation exists (`CanvasSurfaceMac.swift:130-135`); `[weak view]` + `MainActor.assumeIsolated`; `send()` only fires from `@MainActor` session code. `deactivateRepresentation` clears the observation before disabling recognizers (`:1303`).
- `interruptTransientInteraction()` (`:1289-1294`) commits or suspends the text editor then calls the pre-existing `cancelInteraction()` — the exact semantics the audits asked for, on the live view, preserving decode/path/display/semantic caches, file-promise batches, and imports.
- `deactivateRepresentation()` (`:1298-1308`) no longer calls `onCancelImageImportBatches()` — view death cannot abort session imports. Explicit user cancellation is preserved: Escape still calls it (`:1174`), as does the HUD cancel button (`CanvasPanelContent.swift:868`).
- Transient callers verified in context: `CanvasPanelContent.zoom(by:)` (`:397-400`), `AtticPanelView.selectSection` (`:808-810`, fires only when leaving canvas and only after the notes-close refusal guard), `AtticPanelController.requestHide` (`:469`, fires only after all refusal guards — screen, draft flush — pass).
- Lifecycle callers verified: `AppCoordinator.stop()` (`:375`) and `prepareForTermination()` (`:392`) still cancel; board ops cancel via `synchronizeFromStore(clearHistory:)`'s tail (`CanvasSession.swift:1709-1713`); external semantic-change revisions still cancel through `handleStoreRevision` (`:1610-1616`).
- Import ownership is real, not cosmetic: batches live in `imageImportTasks` (`:143`, pre-existing registry), capture `CanvasImportTarget(canvasID:boardGeneration:)` at start (`:343-348`), persist via `store.importImages(_:target:)` against the captured target (`:878`) — a stale board or generation is rejected store-side — and the store write is wrapped in `isApplyingLocalMutation` (`:877-880`) so one batch's completion cannot tear down a sibling batch through `handleStoreRevision`. Selection/undo recording is gated on the target still being current (`:893-906`).
- `.id(session.interactionCancellationEpoch)` (`CanvasSurface.swift:25`) is unchanged as the rebuild mechanism; the comment now matches behavior.

### CVD-02 — failed board operations — correctly gated

- `selectCanvas` (`:501-515`), `createCanvas` (`:517-539`), `deleteSelectedCanvas` (`:552-566`) now gate teardown on `boardChanged` = `success || store.selectedCanvasID != previousCanvasID` (delete: `succeeded || selectedCanvasID != id`). Verified against every store path in `CanvasStoreBoards.swift`/`CanvasStorePersistence.swift`:
  - Refusal before mutation (invalid id, invalid name, sortIndex exhaustion, last-canvas delete, draft-retention guard at `:522-528`) → `boardChanged` false → history, placement, selection, imports, and surface preserved; the store's `lastErrorMessage` still reaches the session through `synchronizeFromStore` (`:1689`).
  - Save failure after mutation → `save()` rolls back the context and `reloadCanvas()` re-resolves selection (`CanvasStorePersistence.swift:73-83, 90-101`). If the fallback selection differs from `previousCanvasID`, `boardChanged` is true and teardown is **correct** — the visible presentation genuinely moved; keeping board-A undo history while viewing board B would be the bug.
  - Delete failure where rollback resurrects the board and selection re-resolves back to `id` → `succeeded || selectedCanvasID != id` is false → preserved. The condition handles the bounce-back case exactly.
- The old code's *two* epoch bumps per successful board switch (pre-call + sync tail) collapse to one — a small extra win. Teardown now runs at the end of `synchronizeFromStore` after content adoption, so the rebuilt view sees the new board's content immediately.
- View state is not lost for the outgoing board: `flushViewState()` runs inside `synchronizeFromStore` before adopting the new `selectedCanvasID` (`:1661-1669`), and the deleted board's saved state is pruned by the `canvases` filter in `flushViewState`.

### CVD-05 — scroll/pinch vs. pointer-owned input — correctly guarded, broader than the suggested fix

- `scrollWheel` (`CanvasSurfaceMac.swift:910-922`) and `handleMagnification` (`:1016-1029`) now refuse gesture takeover while `activeViewportGesture == nil && hasActivePointerInteraction`.
- `hasActivePointerInteraction` (`CanvasSurfaceMacHelpers.swift:756-763`) covers `panLastPoint` (Space/right/other pan), `shapePointerMode`, `imagePointerMode` `.moving`/`.resizing` (which also covers semantic drags — `semanticPointerActive` is always paired), and `machine.state != .idle` (ink/erase/pan).
- This is deliberately stronger than the audit's minimal `.idle` suggestion — and necessarily so: `beginViewportGestureSequence` (`CanvasSurfaceMacHelpers.swift:946-961`) calls `discardImagePreview()`/`discardShapePreview()` unconditionally, and image/shape drags leave `machine.state == .idle`. An `.idle`-only guard would still have allowed `momentumBegan` (pre-existing `:932` guard) and the catch-all to snap back a live image/shape preview. The chosen predicate closes that residual hole too.
- Suppression semantics mirror the pre-existing momentum pattern: `suppressesScrollSequence` set for phased events, cleared on momentum end or the next `directBegan`; `suppressesMagnification` set on `.began`/`.changed`, `.possible` ignored, terminal states fall through to the existing handlers which are no-ops without an active gesture and clear suppression. A pinch that outlives the stroke stays ignored until a fresh `.began` — matching cancelled-tail semantics.
- The Command-scroll-during-ink test rewrite (§4.4 of the implementation doc) matches the audit's expected behavior ("at most it should be ignored until the stroke completes") — accepted as a deliberate, disclosed behavior change.

## 4. Counterexamples probed

| Probe | Result |
|---|---|
| Same-board reselect via the Canvases menu (checkmarked row stays enabled, `CanvasPanelContent.swift:413-425`) | No teardown — `session.selectCanvas` early-returns `true` at `:503`, a pre-existing guard. The `succeeded ||` disjunct in `boardChanged` is unreachable for a no-op (success implies moved) — harmless dead disjunct. |
| `createCanvas` save failure after `selectedCanvasID` is pre-mutated (`CanvasStoreBoards.swift:44`) | Rollback + `resolveCanvasPresentation` fallback re-resolves to a live board; if it differs from previous, `boardChanged` teardown is correct. (Store could preferentially restore the *previous* selection — pre-existing store wart, out of scope.) |
| Save **and** reload both throw | `selectedCanvasID` can retain a phantom id which the session adopts; `selectedCanvas` falls back to a live board until the next successful op heals it. Identical exposure pre-batch; not worsened. |
| Text commit inside `interruptTransientInteraction` re-entering session | `commitSemanticText` → `editSemanticObject`/`insertSemanticObject` are `applyLocalMutation`-wrapped (`:1271, :1294, :1321`) → nested `handleStoreRevision` sees `isApplyingLocalMutation` → `clearHistory: false`. No re-entrant teardown. |
| Import completing while another batch is in flight | Store write is flag-protected (`:877-880`); sibling batches unaffected. |
| Interrupt delivered while no view is subscribed / view mid-dismantle | `send()` is synchronous; no subscriber → no-op (nothing to interrupt); dismantle itself discards input via `deactivateRepresentation`. |
| Pointer events arriving after interruption | `cancelInteraction()` leaves machine `.idle` with all pointer modes cleared; straggler `mouseDragged`/`mouseUp` are inert; a new `mouseDown` starts a fresh interaction. |
| Programmatic section switch bypassing `AtticPanelView.selectSection` (`CornerHoverMonitor.preparePresentation`, `CornerHoverMonitor.swift:201`) | No interrupt fires, but the surface dismantles anyway → `deactivateRepresentation` performs equivalent teardown; session viewport persists via the debounced `viewStateSaveTask`. Equivalent outcome. |
| `session.refresh()` / reveal refresh producing a semantic change | Still routes through `handleStoreRevision` → `clearHistory: semanticChange` → full teardown incl. imports. Legitimate external-change reset; pre-existing and unchanged. |
| iOS surface | `interruptActiveInteraction` has no subscriber; `.id` lifecycle still applies. No iOS caller exists; harmless. |

## 5. Residual observations (not findings)

1. **Declared limitations are accurate.** Section changes still dismantle the surface, so view-owned file-promise batches and decode/render caches still end on a section change (imports do not). Zoom/hide preserve everything. Keyboard viewport shortcuts (⌘=/⌘−/⌘0/⌘9, Fit, Reset) during ink still discard buffered ink via `configure`'s `shouldCancelInk` — an inconsistent protection surface vs. scroll/pinch, explicitly disclosed as outside CVD-05. Space-discards-ink (CVX-04) unchanged. CVD-02 UI polish (disabling whitespace-only Create) not done — the error banner still publishes, history survives.
2. **`importImage(url:)` / `importImage(data:)`** (`CanvasSession.swift:736-753`) `await importImageBatch` directly without registering in `imageImportTasks`, so lifecycle cancellation cannot reach them. Pre-existing; no production callers (the file picker uses `startImageImportBatch`, `CanvasPanelContent.swift:168`). Latent API trap for future callers only.
3. **`MainActor.assumeIsolated` in the sink** (`CanvasSurfaceMac.swift:132-134`) is safe only because `send()` is confined to main-actor session code today; a `receive(on:)` hop would be more defensive against future non-main senders.
4. The `succeeded ||` / `created != nil` disjuncts in the `boardChanged` formulas are unreachable given the `:503` guard and store semantics — dead-but-harmless defensive clauses.

## 6. Evidence boundaries

All evidence reviewed is **source-level plus unit/integration tests in a windowless host with synthetic events** (CGEvent-built scroll phases, a driven `NSMagnificationGestureRecognizer` subclass). The following remain **unverified by this review and are not implied by it**: physical trackpad phase ordering, real SwiftUI identity/teardown timing, live panel hide/show, real file-promise providers (CVP-01 stays open), and any running-app behavior. Native QA belongs to the separate "Sol Low" pass; the implementation doc's §7 handoff list is appropriate for it. No CloudKit/APNs/iPhone/TestFlight/Production claim is made or implied.

REVIEW_PASS
