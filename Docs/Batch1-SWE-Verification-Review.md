# Batch 1 — Independent SWE Verification Review

**Verdict: REVIEW_PASS.**

- **Scope reviewed:** `RUN-001`, `RUN-002`, `CVD-01` (transient bridge teardown / import cancellation), `CVD-02` (failed board operations lose history), `CVD-05` (incidental scroll/pinch drops buffered ink), per `Docs/DeepAudit-Batch1-Implementation.md` against `Docs/DeepAudit-Consolidated-2026-09-15.md` and the source audits `Docs/DeepAudit-Canvas-2026-09-14.md` / `Docs/DeepAudit-Runtime-2026-09-14.md`.
- **Reviewer:** SWE-2 Max, root session. No subagents used. Read-only audit of source; no edits, commits, pushes, UI launches, or relaunches. User stores/containers never touched.
- **Native QA:** explicitly out of scope here — owned separately by Sol Low. Nothing below is inferred as physical-input or live-panel evidence.

## 1. Provenance — verified byte-for-byte, independently reconstructed

| Claim | Result |
|---|---|
| `full-dirty-diff-before.patch` sha256 `f0e46688…3d0e` | Verified — matches on-disk file. |
| `batch1-own.diff` sha256 `f565b48c…3b60d` | Verified — matches on-disk file. |
| Pre-edit snapshots are HEAD + dirty-patch hunks | Verified — spot-checked `CanvasSession.swift`, `CanvasSurfaceMac.swift`, `AtticPanelController.swift`: `git show HEAD:<f>` + that file's hunks from the snapshot patch reconstruct `/tmp/attic-batch1/pre/<f>` exactly. |
| Before/after hash table | Verified — all 11 `/tmp/attic-batch1/pre` hashes match the "before" table; all 11 current worktree hashes match the "after" table (incl. unchanged `CanvasSurfaceInteraction.swift` `f1ebe1fc…` and `CanvasSurfaceMacHelpers.swift` `8f7fe948…`). |
| Own diff is the complete change | Verified — `pre/` + `batch1-own.diff` produce the current live files byte-for-byte (9 files, +333/−19, no mismatches). All other dirty work preserved untouched. |
| Porcelain delta | Verified — `status-before` 151 lines → `status-after` 153 (only `AtticTests/CanvasImageTests.swift`, `AtticTests/CanvasSessionTests.swift` newly dirty). Current tree = after-state + the untracked implementation doc itself (154). No drift. |

## 2. Mechanism review — confirmed sound

**Transient vs lifecycle split (RUN-001/RUN-002/CVD-01).** Verified in source:

- `CanvasSession.interruptActiveInteraction()` (`CanvasSession.swift:1440-1443`) does `flushViewState()` + `interactionInterruptions.send()` — no epoch bump. The subject is a `PassthroughSubject` (line 49) delivered synchronously on the main actor; `CanvasSession` is `@MainActor` (line 24), so the sink's `MainActor.assumeIsolated` (`CanvasSurfaceMac.swift:133`) matches the file's existing store-revision sink idiom (`CanvasSession.swift:299-301`).
- The sink is installed once per live view inside `configure` (`CanvasSurfaceMac.swift:130-135`), gated on `isRepresentationActive` (defaults `true`, line 311; `makeNSView` activates before its first `configure`, lines 17-22). `[weak view]` — no retain cycle; `deactivateRepresentation` clears it (line 1303). A dismantled view cannot be re-interrupted, and each rebuilt view re-subscribes cleanly.
- `interruptTransientInteraction()` (`CanvasSurfaceMac.swift:1290-1294`) commits-or-suspends the text editor then runs the existing `cancelInteraction()` — identical teardown of transient input, minus view destruction.
- `deactivateRepresentation()` (`:1300-1308`) no longer calls `onCancelImageImportBatches()`; it still cancels **view-owned** file-promise batches — correct ownership split, and the honest residual is disclosed (§5.1 of the impl doc).
- Lifecycle `cancelActiveInteraction()` (`:1431-1435`) now cancels imports **synchronously** then bumps the epoch. Callers audited: `synchronizeFromStore(clearHistory: true)` (`:1709-1713`), `deleteSelectedCanvas` success path (`:559-564`), `AppCoordinator.stop()`/`prepareForTermination()` (`AppCoordinator.swift:375,392` — file untouched). All are genuine lifecycle events. Explicit user cancellation is preserved: Escape (`CanvasSurfaceMac.swift:1171-1182` → `onCancelImageImportBatches`) and the HUD cancel button (`CanvasPanelContent.swift:868` → `cancelAllImageImportBatches` directly).
- Cancelled imports can never persist: `importImageBatch` returns before `store.importImages` when `Task.isCancelled` (`CanvasSession.swift:857-866`), and store-side `canvasID`/`boardGeneration` target validation (`:893-894`) rejects stale targets even if cancellation were somehow bypassed.
- Transient callers converted exactly as claimed: `CanvasPanelContent.zoom` (`:398`), `AtticPanelView.selectSection` canvas-exit (`:808-810`), `AtticPanelController.requestHide` (`:469`). The other hide paths (`.screenChanged`, `.applicationDeactivated`, `.lostWindow`) call only the panel-level `PanelSurfaceHostingView.cancelActiveInteraction(reason:)` (`AtticPanel.swift:1147`) — they never touched the canvas session before and still don't; parity, not regression.
- Post-interrupt held-button safety verified: after `cancelInteraction()`, `mouseDragged`/`mouseUp` are no-ops (`appendInk` refuses from `.idle`; `finishPointerInteraction` finishes nothing); a still-held Space only re-arms via a fresh `keyDown` — matching the doc's §6 description.

**CVD-02 gating.** `selectCanvas` (`:502-515`), `createCanvas` (`:518-539`), `deleteSelectedCanvas` (`:553-566`) all gate the reset on `succeeded || selection-actually-moved` — defensive against partial store mutations. Refusals run `synchronizeFromStore(clearHistory: false)`, which republishes the store's error (every refusal branch in `CanvasStoreBoards.swift` sets `lastErrorMessage`: lines 10, 23, 27, 52, 105, 109). Outgoing-board view state is still flushed before adoption of the new selection inside `synchronizeFromStore` (`:1661-1670`), so removing the pre-call flush loses nothing. The early virtual-board text-draft refusal in `createCanvas` (`:519-528`) already preserved history before and still does.

**CVD-05 guards.** `scrollWheel` (`CanvasSurfaceMac.swift:911-922`) and `handleMagnification` (`:1016-1029`) guard on `activeViewportGesture == nil && hasActivePointerInteraction`. Coverage of `hasActivePointerInteraction` (`CanvasSurfaceMacHelpers.swift:756-763`) verified to include ink/erase (`machine.state`), Space/right/other pointer pans (`panLastPoint`), shape drags (`shapePointerMode`), image move/resize **and semantic-object drags** (both use `imagePointerMode` — `CanvasSemanticInteraction.swift:119,135`). Suppression semantics verified cannot wedge: a fresh `directBegan` always clears `suppressesScrollSequence` (`:931`), `momentumEnded` clears it (`:1005` and inside the new guard `:916-917`), standalone wheel ticks during a pointer interaction are ignored without poisoning the next sequence, and `.ended`/`.cancelled`/`.failed` pinch tails clear `suppressesMagnification` (`:1059,1063`). A scroll sequence that began during ink stays dead for its whole physical sequence — matching the audit's "ignored until the stroke completes."

## 3. Test quality — meaningful and discriminating

- All 6 new tests and the rewritten `testCommandScrollUsesReentrantCanvasZoomPath` verified present and asserting the new contract (ink ignored-then-saved; refused ops keep board/history/placement/epoch; interruption commits text and drops ink without rebuild; session imports survive interrupt+dismantle; lifecycle still cancels).
- Mutant evidence verified: `/tmp/attic-batch1-mutant` contains exactly the 5 documented mutations (`if false,` on both guards, restored `onCancelImageImportBatches()` in deactivate, `boardChanged = true`, epoch bump in `interruptActiveInteraction`), and `batch1-mutant.log` shows `5 tests, 40 failures`. Each new test detects its defect.
- The Command-scroll test rewrite is legitimate: it still proves the reentrant zoom path and viewport delivery (second scroll: `.idle`, `scale > 1`, delivered == live viewport) while asserting the CVD-05-correct interim behavior. The disclosed behavior change is the one the audit text prescribes.
- Minor methodological note (non-blocking): the mutant set mutated only `createCanvas` for CVD-02; the `selectCanvas`/`deleteSelectedCanvas` refusal paths are discriminated by the test's shared assertions (undo count, placement, epoch) by construction but were not individually mutation-proven.

## 4. Build/test evidence — claimed results verified, then independently reproduced

Claimed logs verified on disk:

- `batch1-focused.log`: 15/15 pass, bundle `4fbbbec4…` (pre-§4.4 build — consistent with the disclosure). The two mis-prefixed IDs disclosed in the doc are real `CanvasDomainTests` members (`CanvasDomainTests.swift:1227,1242`) and passed in the full run.
- `batch1-full-unit.log`: 805 tests, 4 skips, exactly 3 failures — all in `testCommandScrollUsesReentrantCanvasZoomPath` at its pre-update line numbers (1858-1860), consistent with running the pre-update bundle.
- `batch1-full-unit-2.log`: `Executed 805 tests, with 4 tests skipped and 0 failures`, `exit_status=0`. Bundle sha256 `43f7a7af…f00614` matches the on-disk `.xctest` binary in `/tmp/attic-batch1-dd` — provenance chain intact. 42/42 declared `*Tests` classes ran (verified against `AtticTests/`); 805 = 799 (perfa1 baseline log) + 6 new. All 4 skips are explained gates (MCP external client, 2× desktop visual-test, deferred CloudKit).
- `build-for-testing-2.log`: `** TEST BUILD SUCCEEDED **`; only benign warnings.

Independent rerun (my own artifacts, windowless local-only host, synthetic stores only):

- `xcodebuild build-for-testing -scheme Attic -configuration Local -derivedDataPath /tmp/attic-swe-review-dd -only-testing:AtticTests CODE_SIGNING_ALLOWED=NO` → `** TEST BUILD SUCCEEDED **`. Rebuilt host binary sha256 `2287db13…a39e2d` is **byte-identical** to the one recorded in the implementer's runs — a reproducible-build confirmation of the tested sources.
- `/tmp/attic-offline-xctest/swe-review-focused.log`: 18/18 pass, including the two tests the original focused run missed via wrong class prefix (ran under `CanvasDomainTests`) and the rewritten Command-scroll test.
- `/tmp/attic-offline-xctest/swe-review-full.log`: `Executed 805 tests, with 4 tests skipped and 0 failures`, `exit_status=0` — independently reproduces the claimed gate.
- `git diff --check` on all 9 touched files: clean.

## 5. Observations (non-blocking; none are new regressions)

1. **Keyboard viewport shortcuts during ink** (⌘=/⌘−/⌘0/⌘9 via `performKeyEquivalent`, `CanvasSurfaceMac.swift:1110-1125`) still drop a buffered stroke — not through the recognizer path but through `onViewportChange` → `setViewport` → `interaction.configure`'s `viewportChanged` ink-cancel (`CanvasSurfaceInteraction.swift:54-57`). Outcome matches the new "transient interruption discards ink" semantics, so it is consistent rather than a hole — but the discard arrives as a configure side effect rather than an explicit interrupt. Disclosed as unchanged in impl §5.2; consider an explicit `interruptTransientInteraction()`-equivalent on that path in a follow-up if the product wants zoom to *not* kill an in-progress stroke.
2. **Suppressed-pinch resumption edge:** if a transient interrupt lands while a suppressed pinch is still physically in progress, `cancelInteraction`'s routing reset clears `suppressesMagnification`, so the pinch's remaining `.changed` events can start a zoom mid-gesture. Benign (the ink it protected is already discarded by the interrupt itself); noted for completeness.
3. **Residual RUN-002 surface:** section switching still dismantles the view — view-owned file-promise batches end and caches rebuild on return. Accurately disclosed (impl §5.1); session imports, the batch's actual target, survive.
4. Other hide paths (`.screenChanged`, `.applicationDeactivated`, `.lostWindow`) never called the session-level cancel before and still don't call `interruptActiveInteraction` — buffered ink survives those hides exactly as before. Consistent parity; flag only if the product wants all hides to interrupt.

## 6. Not verified here (by design)

Physical trackpad phase ordering, real file-promise providers, live panel hide/show, real SwiftUI `.id` teardown timing, and any CloudKit/APNs/iPhone claim — all remain for Sol Low native QA per impl §7. Unit/integration evidence above uses the windowless `AtticUnitTestHost` with synthetic CGEvent/driven-recognizer input only.

---

**REVIEW_PASS** — implementation is correct, provenance is exact, tests are discriminating, and the 805/4-skip/0-fail gate was independently reproduced on a private build of the verified tree.
