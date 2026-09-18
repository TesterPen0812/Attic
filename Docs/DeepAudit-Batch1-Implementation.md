# Deep Audit Batch 1 — Implementation Record

**Status: REVIEW_READY.** This is ready for independent review. **Native (physical-input, live-panel) evidence is still PENDING.** Nothing here has been launched, relaunched, or checked by hand in the running app.

- **Findings in scope:** Batch 1 of `Docs/DeepAudit-Consolidated-2026-09-15.md`:
  - `RUN-001`, `RUN-002`, `CVD-01`: transient bridge teardown and import cancellation.
  - `CVD-02`: failed board operations lose history.
    - *Remediation correction:* this record covers only **validation refusals** (invalid name, unknown ID, last canvas). An **injected persistence failure** on create/delete was not covered here and still lost the selection, history, epoch, and imports; see `Docs/Batch1-Remediation-Implementation.md`.
  - `CVD-05`: incidental scroll or pinch drops buffered ink.
- **Sources read:**
  - The consolidated report, in full.
  - `Docs/DeepAudit-Canvas-2026-09-14.md` (CVD-01, CVD-02, CVD-05, CVX-04).
  - `Docs/DeepAudit-Runtime-2026-09-14.md` (RUN-001, RUN-002).
  - `AGENTS.md` / `CLAUDE.md`.
- **Writer:** a single root writer. No additional agents were used, and nothing was committed, pushed, or released.

## 1. Snapshot provenance (taken before any edit)

| Item | Value |
|---|---|
| Worktree | `/Users/taha/Developer/attic-task-panels-v2` |
| Branch | `codex/attic-task-panels-v2` |
| HEAD | `ae6418c1af690e29d15a20344cdb9765a23d3f85` (unchanged afterwards) |
| Porcelain status before | 151 lines (`/tmp/attic-batch1/status-before.txt`) |
| Pre-existing dirty diff | 65 files, +9764/−3058; `/tmp/attic-batch1/full-dirty-diff-before.patch` sha256 `f0e46688643b8dc8464ca729c640e5b0cc45ee2f19dd41ab506041bca69e3d0e` |
| Porcelain status after | 153 lines. The only additions are ` M AtticTests/CanvasImageTests.swift` and ` M AtticTests/CanvasSessionTests.swift`, which were clean at HEAD before. No other entry changed. |

**Checking that the pre-edit state was preserved.** I rebuilt every owned file in `/tmp/attic-batch1/pre` as `git archive HEAD` plus that file's hunks from the snapshot patch. Every rebuilt file matched its snapshot sha256 exactly. My own diff below is computed against those rebuilt pre-edit files, so it contains **only Batch 1 hunks**. All of the extensive dirty work already in these files is untouched.

| File | sha256 before | sha256 after |
|---|---|---|
| `Attic/Canvas/CanvasSurface.swift` | `ca6e3668ab915ed20299f1b3f7d7ad11e0f2c1ab2f8431551e0275d27b3ac4c3` | `a9456f44a18cf5f361435d8981c29ffbbac29df02d62b062bb4a0b74513437c0` |
| `Attic/Canvas/CanvasSurfaceMac.swift` | `e47b0e08b2a3e0e15590b840804b826a679a156155289089b0c79ec664a4723c` | `e1d4187626d45f8280f12ac21a89b68ce307d63143467b5bd2831a6f6e34f602` |
| `Attic/Canvas/CanvasSurfaceInteraction.swift` | `f1ebe1fc05d61351b1a1c87236a48606807c8a6cfc66cbc31a2f739cd049329a` | unchanged |
| `Attic/Canvas/CanvasSession.swift` | `bd441624d45ab47efcb988cbadd6799a8afb495e4c23bf821ccd2289fd6503cb` | `ebec9d9fa5c905ffff71ed58e95f5efa9adf978c98d83f0f8e954a53353fb586` |
| `Attic/Views/Panel/CanvasPanelContent.swift` | `7ff72dcfbdb3170aa46a61e4afa3facbc0d6dbee1172ac85bb41d649543855a9` | `1e35eb7f07024d32e4734750739ba7d40e251d6ef0e00c4495b2efa08a87734b` |
| `Attic/Views/Panel/AtticPanelView.swift` | `c41ea2aa89f136304cb27f07f14fefc9216fa5efb15905a79a92750e5718e88a` | `decf870b2ed9dd5e8673d215dabc5c13d865ba6b9b7be621ea4b6d095ae43749` |
| `Attic/Window/AtticPanelController.swift` | `b453562f1b6fb6175dac6c4248d8791832d774a5d7279ae5558bf2593063114c` | `480e3049a66de472b3c4b095e9c3d5a732fe3c74036a372a471b86695ff942c5` |
| `Attic/Canvas/CanvasSurfaceMacHelpers.swift` (out of scope; see note) | `8f7fe9484ad96403776640f60fa059b41eafa6ab62ebfcd2e68f5be59839dbbc` | unchanged |
| `AtticTests/CanvasDomainTests.swift` | `badfe50003529ba4a575229d6ea63f58de86edc0037eaf4cebdfce70f5349702` | `4977c9fecc37863a32e42268baea06f77d389d6b9dfc1cefdccd031dce6e05e7` |
| `AtticTests/CanvasImageTests.swift` | `799364c47b4e72459a21d8840e43ec65dd7ee065f8edb222454c7bf74009a3af` | `6395e9d374d01d450b0472d8305683f8ff56e8495f0bd6847698e838cfed2bba` |
| `AtticTests/CanvasSessionTests.swift` | `056fe6c927e1820707ab1c4823dd0f4c7bcebc57f26819a6246704722355bbd5` | `beb9dba1f9152b54ad157a617acad43c37afc12b0fadb9b509db93964234c721` |

**Own diff.** The file is `/tmp/attic-batch1/batch1-own.diff`, sha256 `f565b48c991e2226b4e68396ef4bb0503ecebd451e2cdbd33980de6440c3b60d`. It touches 9 files, +333/−19:

| Area | Change |
|---|---|
| Source | +107/−19 |
| Tests | +241 (including a 10-line rewrite of one existing test) |

The full diff is reproduced in the Appendix.

**Note on `CanvasSurfaceMacHelpers.swift`.** During development I briefly edited this out-of-scope file, then reverted it. Its rebuilt pre-edit hash equals its current hash, and it does not appear in the own diff. `AppCoordinator.swift` was not touched.

## 2. Hypotheses, live trace, and confirmation

### H1 — RUN-001 / RUN-002 / CVD-01: transient actions tear down the native bridge and abort imports (confirmed)

**Trace before the change:**

1. `CanvasSurface.body` applies `.id(session.interactionCancellationEpoch)`.
2. `CanvasSession.cancelActiveInteraction()` did `flushViewState(); interactionCancellationEpoch &+= 1`.
3. Three **transient** callers invoked it:
   - `CanvasPanelContent.zoom(by:)` (toolbar zoom).
   - `AtticPanelView.selectSection` (leaving Canvas).
   - `AtticPanelController.requestHide`, immediately after `hostingView.cancelActiveInteraction(reason: .explicitHide)`.
4. The epoch change gives the representable a new identity. SwiftUI then calls `CanvasNSViewRepresentable.dismantleNSView`, which calls `CanvasNSView.deactivateRepresentation()`.
5. That method ran `onCancelImageImportBatches()`, bound to `session.cancelAllImageImportBatches()`. It cancelled every session-owned `imageImportTasks` entry and threw away the view with its decode/render caches.
6. Result: an ordinary zoom click, panel hide, or section change silently aborted a multi-image import (RUN-001/CVD-01) and forced a full cache rebuild (RUN-002).

The lifecycle callers were:

- Board switch, create, and delete, through `synchronizeFromStore(clearHistory: true)` or directly.
- External history-reset revisions.
- `AppCoordinator.stop()` and `prepareForTermination()`.

The mutation run in §4.3 confirms the defect: restoring the old deactivate cancellation and epoch-based interruption makes the import-survival test lose both images (`session.images == []`, 2 cancellations).

### H2 — CVD-02: failed board operations discard undo history (confirmed)

*Remediation correction:* the reproductions below are store **validation refusals** only. They never reach `save()`. A persistence failure after the store moved `selectedCanvasID` was not reproduced by this record; it is handled in `Docs/Batch1-Remediation-Implementation.md`.

**Trace before the change.** `selectCanvas`, `createCanvas`, and `deleteSelectedCanvas` all ran `cancelPendingPlacement(); cancelActiveInteraction(); selectedImageID = nil` before the store call. The first two then always called `synchronizeFromStore(clearHistory: true)`.

**Reproductions** (the store refuses in each case):

- `createCanvas(name: "   ")` returns `nil` with `invalidCanvasName`.
- `selectCanvas(UUID())` returns `false`.
- `deleteSelectedCanvas()` on the last canvas returns `false` with `cannotDeleteLastCanvas`.

**Before the fix**, each refused call still:

- emptied the undo stack;
- dropped the pending placement;
- bumped the epoch, which rebuilt the surface and (via H1) cancelled imports.

The mutation run confirms this: undo count 1 became 0, the placement became nil, and the epoch went from 0 to 1.

### H3 — CVD-05: incidental scroll or pinch during ink or pointer editing discards buffered work (confirmed)

**Trace before the change.** Every unguarded entry into `beginViewportGestureSequence` discarded the image and shape previews and called `interaction.beginViewportGesture()`, which calls `machine.beginPan()`. From `.drawing`/`.erasing`, `beginPan()` drops all buffered points, and `mouseUp` then finishes a pan instead of saving a stroke. The unguarded entries were:

- In `scrollWheel`: the `directBegan` re-begin and the catch-all delta branch. Only the `momentumBegan` branch had an idle guard.
- In `handleMagnification`: `.began`, `.changed` with no active gesture, and `.possible`.

`beginViewportGestureSequence` itself refused only for `panLastPoint != nil`.

The mutation run confirms this: with the guards disabled, the machine goes `.drawing` → `.panning` / `.idle`, no stroke completes, and the viewport moves.

## 3. Fix design (smallest coherent change; no architecture or schema change)

### 3.1 Separate transient interruption from lifecycle cancellation

**`CanvasSession`:**

- Adds `let interactionInterruptions = PassthroughSubject<Void, Never>()`.
- Adds `func interruptActiveInteraction()`, which runs `flushViewState()` and then `interactionInterruptions.send()`. The subject delivers synchronously, and the epoch is not bumped.
- `cancelActiveInteraction()` remains the **lifecycle** path. It now calls `cancelAllImageImportBatches()` explicitly before bumping the epoch. Before, cancellation happened indirectly and asynchronously when SwiftUI dismantled the view. The set of lifecycle events that cancel imports is the same, but cancellation is now synchronous and no longer depends on SwiftUI's teardown timing.

**`CanvasNSViewRepresentable.configure`:**

- Installs a single `interactionInterruptionObservation` sink per active `CanvasNSView`. It is installed only while `isRepresentationActive`.
- The sink calls `interruptTransientInteraction()`, which:
  - commits the text editor, or suspends it if the commit fails (the same policy deactivation uses);
  - runs the existing `cancelInteraction()`, which discards ink and previews, resets pan and space state, and resets gesture routing with the same scroll/magnification suppression as before.
- The view, its caches, file-promise batches, and session imports all survive.

**`CanvasNSView.deactivateRepresentation()`:**

- No longer calls `onCancelImageImportBatches()`.
- Clears the interruption observation.
- Still commits or suspends text, deactivates, disables recognizers, cancels interaction, cancels **view-owned** file-promise batches, and detaches `onViewportChange`.

**Explicit user cancellation is unchanged:** Escape (`keyDown` 53 → `onCancelImageImportBatches`) and the import HUD's cancel button (`cancelAllImageImportBatches`).

**Transient callers now use `interruptActiveInteraction()`:**

- `CanvasPanelContent.zoom(by:)`
- `AtticPanelView.selectSection` (canvas → other section)
- `AtticPanelController.requestHide`

**Callers that still use lifecycle `cancelActiveInteraction()`:**

- `AppCoordinator.stop()` and `prepareForTermination()` (file not edited).
- `synchronizeFromStore(clearHistory: true)`, which covers board switch, create, and external history resets.
- A successful `deleteSelectedCanvas`.

**Stores are unaffected.** Store import validation of `canvasID`/`boardGeneration` still rejects stale targets. Existing tests for page switch, target deletion, and clear during decode all still pass.

### 3.2 CVD-02: gate the reset on an actual board change

- **`selectCanvas` / `createCanvas`:**
  - Capture `previousCanvasID` and run the store call inside `isApplyingLocalMutation`.
  - Compute `boardChanged = success || store.selectedCanvasID != previousCanvasID`.
  - Only when the board changed, set `selectedImageID = nil` and call `synchronizeFromStore(clearHistory: true)`. That path already cancels placement, runs lifecycle cancellation, and clears history.
  - An operation that leaves the board unchanged calls `synchronizeFromStore(clearHistory: false)`, which republishes the store's error message. At the time of this record that held only for validation refusals: a failed create/delete **save** had already moved `selectedCanvasID`, and the rollback reload fell back to the first live board, so the session saw a board change and reset. The remediation restores the previous selection in the store before that reload.
- **`deleteSelectedCanvas`:** runs the placement cancel, lifecycle cancellation, selection clear, and history clear only if the delete succeeded or the selection actually moved.
- **View state still saves before the board changes:** `synchronizeFromStore` calls `flushViewState()` before it adopts the new `selectedCanvasID` (it already did). The pre-call `cancelActiveInteraction()` flush that was removed is therefore not needed for the outgoing board's viewport.

### 3.3 CVD-05: refuse viewport takeover while the pointer is owned

- **`scrollWheel`:**
  - After decoding the phases, if `activeViewportGesture == nil && hasActivePointerInteraction`, return without beginning a gesture.
  - `hasActivePointerInteraction` covers ink or erase, Space/right/other pan, shape drag, and image move/resize.
  - The rest of a phased sequence is suppressed (`suppressesScrollSequence = true`, momentum mode cleared). A momentum end clears suppression. A standalone wheel tick is simply ignored.
- **`handleMagnification`:**
  - Under the same condition, `.began`/`.changed` set `suppressesMagnification = true` and return, and `.possible` returns.
  - `.ended`/`.cancelled`/`.failed` fall through to the existing handlers. Those only finish a *magnification-sourced* gesture (a no-op here) and clear suppression.
  - A pinch that outlives the stroke stays ignored until its next `.began`, which matches the existing cancelled-tail semantics.
  - *Remediation correction:* this held only while no cancellation intervened. `cancelInteraction()` overwrote both suppression flags, so a scroll or pinch tail that began during ink resumed as a viewport gesture after the ink was cancelled. Fixed in `Docs/Batch1-Remediation-Implementation.md`.
- **Existing ownership rules are unchanged.** A viewport gesture that is already active is not affected by the guard (`activeViewportGesture != nil`). Pointer-down still interrupts a live viewport gesture through `interruptViewportGestureForPointer()`.

## 4. Verification (private, windowless, local-only)

**Environment:**

- **Builds:** private DerivedData `/tmp/attic-batch1-dd`, `Local` configuration (`ATTIC_LOCAL_ONLY`), `CODE_SIGNING_ALLOWED=NO`.
- **Tests:** run through `/tmp/attic-offline-xctest/run.zsh`, which injects XCTest into `AtticUnitTestHost` (`com.taha.Attic.UnitTestHost`). That host is windowless (activation policy prohibited) and runs without IDE or testmanagerd.
- **Data:** in-memory or synthetic stores only. No personal stores, preferences, or containers were opened. No UI launch or relaunch.

### 4.1 Builds

| Command | Result |
|---|---|
| `xcodebuild build-for-testing -project Attic.xcodeproj -scheme Attic -configuration Local -derivedDataPath /tmp/attic-batch1-dd -only-testing:AtticTests CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO` | `** TEST BUILD SUCCEEDED **`; log `/tmp/attic-batch1/build-for-testing-2.log`. Final build after all edits. No Swift warnings; the only warning is appintentsmetadataprocessor's standard "no AppIntents.framework dependency". |
| `xcodebuild build -project Attic.xcodeproj -scheme Attic -configuration Local -destination 'platform=macOS' -derivedDataPath /tmp/attic-batch1-dd CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **`; log `/tmp/attic-batch1/build-app.log`. Built `Attic.app` has bundle ID `com.taha.Attic`; it was **not launched**. |

- No project inputs changed: no files were added and `Scripts/generate_project.rb` was not needed.
- `git diff --check` on all touched files: clean.

### 4.2 Focused regressions — `batch1-focused` (15/15 passed)

Log `/tmp/attic-offline-xctest/batch1-focused.log`:

- host sha256 `2287db13…a39e2d`
- bundle `4fbbbec4…15e0`
- `Executed 15 tests, with 0 failures`, `exit_status=0`

This run used the build made before the §4.4 test update. The final full suite re-ran all of these on the final binary.

**New tests:**

| Test | What it proves |
|---|---|
| `CanvasImageImportBatchTests/testSessionImportSurvivesTransientInterruptionAndSurfaceDismantle` | A two-image session-owned batch (gated preparer) survives `interruptActiveInteraction()` plus a real `dismantleNSView` of a configured surface. Both images persist, the epoch is unchanged, and there are 0 preparer cancellations. |
| `CanvasImageImportBatchTests/testBoardLifecycleCancellationStillCancelsSessionImports` | A successful `createCanvas` (board switch) bumps the epoch and cancels the in-flight batch. Lifecycle `cancelActiveInteraction()` (stop/termination) bumps the epoch and cancels a second batch. Nothing is persisted. |
| `CanvasSessionTests/testRefusedBoardOperationsKeepHistoryPlacementAndSurface` | **Validation refusals only** (no persistence failure is injected): whitespace-name create, unknown-ID select, and last-canvas delete each keep the board, undo count, `canUndo`, pending text placement, and epoch, and undo still works afterwards. Successful create, select, and delete still clear history and bump the epoch. |
| `CanvasDomainTests/testIncidentalScrollCannotDiscardBufferedInk` | Phased began/changed (with Command)/ended, momentum begin/continue/end, and a standalone wheel tick during ink keep `.drawing`, no active gesture, and no viewport delivery. `mouseUp` saves the 3-point stroke, and a later scroll pans normally. |
| `CanvasDomainTests/testIncidentalPinchCannotDiscardBufferedInk` | A short pinch (began/ended) mid-stroke is ignored. A pinch that outlives the stroke is ignored through its changed/ended tail. The 2-point stroke is saved. A fresh `.began` zooms to 1.25 normally. |
| `CanvasDomainTests/testTransientInterruptionReachesLiveSurfaceWithoutRebuildingIt` | An interruption delivered to a configured live surface commits an open text editor ("Keep" → "Keep edited"), then discards unfinished ink without saving a stroke. The surface stays active and the epoch unchanged. After a dismantle the observation is gone, and lifecycle cancellation still bumps the epoch. |

**Existing tests re-run** (gesture coexistence and deactivation semantics):

- `testTrackpadViewportDeltaCannotLeaveCanvasInputCaptured`
- `testTrackpadDoesNotStealSpaceHeldPointerPan`
- `testTrackpadDoesNotStealRightOrOtherPointerPan`
- `testInterruptedScrollMomentumCannotDiscardImagePointerPreview`
- `testInterruptedScrollMomentumCannotDiscardShapePointerPreview`
- `testNewPinchTakesOverScrollWithoutTerminalEventAndIgnoresMomentumTail`
- `testCancelledMagnificationTailCannotRestartUntilNewBegan`
- `CanvasAccessibilityTests/testViewportShortcutAfterSectionReplacementClaimsOnlyUnassignedWindowFocus`
- `CanvasAccessibilityTests/testSemanticObjectKeyboardSelectionEditingAndFailedDraftSurviveRecreation`

Two further IDs in that command were given the wrong class prefix and did not run: `testFocusLossCancellationCannotCancelANewerViewportGesture` and `testNewCommandScrollTakesOwnershipAfterMissingPinchTerminalEvent`. Both live in `CanvasDomainTests` and passed in the full suite.

### 4.3 Mutation check — `batch1-mutant` (all 5 targeted tests fail without the fixes)

**Setup.** A copy of the worktree at `/tmp/attic-batch1-mutant` (the live tree was untouched), built into `/tmp/attic-batch1-mutant-dd`, with these mutations:

- The scroll guard disabled.
- The pinch guard disabled.
- `onCancelImageImportBatches()` restored in `deactivateRepresentation`.
- `interruptActiveInteraction` bumping the epoch instead of sending.
- `createCanvas` always resetting.

**Result.** Log `/tmp/attic-offline-xctest/batch1-mutant.log`: `Executed 5 tests, with 40 failures`, `exit_status=1`.

| Test | Failures |
|---|---|
| Scroll | 16 |
| Pinch | 9 |
| Live interruption | 6 |
| Import survival | 4 |
| Refused board operations (validation refusals) | 5 |

These failures show each new test detects its defect. The lifecycle-cancellation test is a preservation test and was not part of the mutant set.

### 4.4 Full unit suite

**First run — `batch1-full-unit`: 805 tests, 4 skipped, 3 failures.** All three assertions came from the pre-existing `CanvasDomainTests/testCommandScrollUsesReentrantCanvasZoomPath`. That test (from `bc2d799`) sent a standalone **Command-scroll while ink was buffered** and asserted the old takeover: `.idle`, zoom applied, ink discarded. This is exactly the catch-all delta path that CVD-05's "Smallest fix" requires guarding. The canvas audit says: "should not destroy work in progress — at most it should be ignored until the stroke completes."

**Test update.** I did not change the source. I kept the test's purpose (Command-scroll takes the reentrant zoom path and delivers the viewport) and made it CVD-05-correct:

1. The Command-scroll during ink is now asserted to be ignored (`.drawing`, viewport unchanged, nothing delivered).
2. The stroke is finished.
3. The same event is then asserted to zoom (`.idle`, scale > 1, delivered viewport equals the live viewport).

**This is a deliberate behavior change for reviewers to confirm (see §6).**

**Second run — `batch1-full-unit-2` (final binary): `Executed 805 tests, with 4 tests skipped and 0 failures`, `exit_status=0`.**

- Log `/tmp/attic-offline-xctest/batch1-full-unit-2.log`; bundle sha256 `43f7a7af00ca604fb6289931c7bda9d7044eafdcdfa1bb7dc9ca514c45f00614`.
- It used the same 42-class list as the accepted PERF-A1 full run (`perfa1-fixes-full-unit`: 799 tests). A `comm` against every `*Tests` class declared in `AtticTests/` showed no missing class. 805 = 799 + 6 new tests.
- **PERF-A1 gates stayed intact.** `CanvasPerformanceGateTests` and `TaskPerformanceGateTests` passed. `Canvas decode stress: 96 images in 0.075s, max active 4`; `PERFGATE toggle=7.69 snapshot=32.04 lookup=0.0014`, which is within the gates. Notes, subtask, panel-geometry, and panel-surface suites all passed.

## 5. Limitations and items deliberately not addressed

1. **A section change still dismantles the surface.** The canvas is not in the view hierarchy while another section is shown. Session imports now survive and finish into their captured target. But **view-owned** file-promise batches (`filePromiseBatches`, for example drags from Photos or Mail that are still being delivered) and the view's decode/render caches still end with the view.
   - For **zoom and hide** the view, caches, and promises survive, so RUN-002's churn is removed for those actions.
   - For **section switching** the cache rebuild on return remains. RUN-002's performance magnitude is still unmeasured, as the consolidated report states.
2. **Out of CVD-05 scope, unchanged:**
   - Keyboard viewport shortcuts during ink (⌘=/⌘−/⌘0/⌘9 go through the session's zoom and fit paths, not these recognizers).
   - The Space key discarding mid-stroke ink (`CVX-04`, deliberate design, separate decision).
3. **Behavior change: Command-scroll during a held stroke is now ignored** rather than zooming and discarding the stroke (§4.4). The same applies to trackpad two-finger scroll and pinch during image move/resize, shape drag, and Space/right/other pan. They wait until the pointer interaction ends. A pinch already under way when the pointer interaction ends stays ignored until a new pinch begins.
4. **CVD-02 UI polish is not done.** Disabling the Create button for a whitespace-only name would touch UI outside this fix. The session no longer loses history on the refusal, and the store's error message is still published.
   - *Remediation correction:* CVD-02 was **not** complete for injected persistence failures on create/delete. That path is fixed and covered by failure-injection tests in `Docs/Batch1-Remediation-Implementation.md`.
5. **`AppCoordinator.swift` is unchanged.** `stop()` and `prepareForTermination()` keep lifecycle cancellation (epoch rebuild plus import cancel).
6. **No native evidence yet.** All evidence is unit and integration level in a windowless host with synthetic events: CGEvent-built scroll events and a driven `NSMagnificationGestureRecognizer` subclass. Physical trackpad phase ordering, SwiftUI's real identity and teardown timing, live panel hide/show, and real file-promise providers have **not** been exercised. No CloudKit, APNs, or iPhone claim is made.

## 6. Reviewer focus

- Is the subscription lifecycle right? It is installed in `configure` only while active and cleared in `deactivate`. `makeNSView` activates before its first `configure`. The sink uses `[weak view]` and `MainActor.assumeIsolated`, and the subject is sent only from main-actor session code.
- **Event handling after an interrupt.** Because the view is no longer replaced, later `mouseDragged`/`mouseUp` events from a still-held button now reach the same view. After `cancelInteraction()`:
  - the machine is `.idle`, `panLastPoint`, `shapePointerMode`, and `imagePointerMode` are nil/none, and `spacePressed` is false;
  - `mouseDragged` does nothing (`appendInk` refuses from `.idle`; `continuePan` needs `panLastPoint`);
  - `mouseUp` finishes nothing.
  - A drag that continues while Space stays physically held begins a fresh pan only after another Space `keyDown` arrives (for example, key auto-repeat).
- **Lifecycle import cancellation moved from asynchronous dismantle to synchronous `cancelActiveInteraction()`.** Confirm no lifecycle path relied on imports continuing until SwiftUI finished teardown.
- **`deleteSelectedCanvas` now performs lifecycle cancellation after the store call** instead of before it. View state for the outgoing board is flushed inside `synchronizeFromStore` before the selection changes. The deleted board's view state is filtered out.
- Accept or reject the Command-scroll-during-ink behavior change (§5.3), which follows the audit's CVD-05 text.

## 7. Native verification handoff (PENDING — not performed)

Run these in a uniquely named local-only preview (for example `com.taha.Attic.batch1`, its own store, `ATTIC_LOCAL_ONLY`). Never use the personal `com.taha.Attic` store. Record the branch, commit or dirty-hash set, executable path, and bundle ID for each run.

1. **Import survives transient actions (RUN-001/CVD-01):**
   - Drop 8–12 large images (Finder files) onto a board. While the HUD shows progress, click toolbar zoom in/out several times. All images should land and the HUD should complete with no cancellation.
   - Repeat, hiding the panel mid-import (hot corner or explicit hide), then reopen. The import should complete into the original board, with the viewport and selection intact.
   - Repeat, switching to Tasks or Notes mid-import, then returning to Canvas. Images should land on the captured board. Note whether any **file-promise** drag (Photos or Mail) in progress was cancelled; that is expected per §5.1, so record it.
   - Press Escape or the HUD cancel button mid-import. Import cancellation must still work.
2. **Legitimate teardown is preserved:** switch boards, create a board, and delete a board mid-import. The in-flight import should cancel, or land nowhere stale. Quitting the app mid-import should terminate cleanly, with no zombie decode and no persisted partial row.
3. **Refused board operations (CVD-02):** draw two strokes, then try to create a board named `"   "` from the canvas menu. An error should appear, Undo should still be enabled, and ⌘Z should undo the last stroke. Deleting the only board should show an error with history intact.
4. **Ink versus gestures (CVD-05) on a physical trackpad and mouse:**
   - Draw long strokes while resting a second finger or scrolling mid-stroke; include flick-scrolls just before pressing, to get momentum tails. Every stroke should save.
   - Pinch mid-stroke; the stroke should save and the viewport should not jump.
   - After releasing, a fresh two-finger scroll and pinch should pan and zoom normally.
   - Command-scroll with a mouse wheel while holding the button: nothing should happen until release, then Command-scroll should zoom.
   - Image move/resize and shape drag with incidental scroll or pinch: the preview should not snap back.
5. **Gesture coexistence and panel smoke:**
   - Space-drag pan, right-drag and middle-drag pan, trackpad pan/zoom, and ⌘=/⌘−/⌘0/⌘9.
   - Main-panel gestures unchanged, with no subpanel swipe regression.
   - Notes editing, task panels, and subtask panels unaffected.
   - Text editing: open a text object, type, then click toolbar zoom or hide the panel. The text should commit (or on a save failure, the draft should be retained).
6. **Cache churn (RUN-002, optional measurement):** on an image-heavy board, compare how long images take to redraw after zoom or hide versus after a section round-trip. Zoom/hide should not re-decode; a section round-trip still will.

## Appendix — own Batch 1 diff (against rebuilt pre-edit files)

```diff
--- a/Attic/Canvas/CanvasSurface.swift
+++ b/Attic/Canvas/CanvasSurface.swift
@@ -17,9 +17,11 @@
 
     var body: some View {
         platformSurface
-            // Rebuild the native bridge only for an explicit lifecycle
-            // cancellation. Dismantling discards unfinished input without
-            // changing completed strokes, images, or viewport state.
+            // Rebuild the native bridge only for board lifecycle or
+            // termination cancellation. Transient interruptions (zoom, hide,
+            // section change) reach the live view through
+            // `interactionInterruptions` instead, so they keep its caches and
+            // in-flight imports.
             .id(session.interactionCancellationEpoch)
             #if os(macOS)
             .accessibilityElement(children: .contain)
--- a/Attic/Canvas/CanvasSurfaceMac.swift
+++ b/Attic/Canvas/CanvasSurfaceMac.swift
@@ -1,5 +1,6 @@
 #if os(macOS)
 @preconcurrency import AppKit
+import Combine
 import SwiftUI
 import UniformTypeIdentifiers
 
@@ -126,6 +127,12 @@
         }
         view.onPreserveSemanticDraft = { [weak session] key, draft in session?.preserveSemanticTextDraft(key, draft: draft) }
         view.onSemanticDraft = { [weak session] key in session?.semanticTextDraft(key) }
+        if view.interactionInterruptionObservation == nil, view.isRepresentationActive {
+            view.interactionInterruptionObservation = session.interactionInterruptions
+                .sink { [weak view] in
+                    MainActor.assumeIsolated { view?.interruptTransientInteraction() }
+                }
+        }
         view.configure(
             canvasID: session.selectedCanvasID,
             strokes: session.strokes,
@@ -308,6 +315,7 @@
     ] = [:]
     var canvasAccessibilityNavigationOrder: [CanvasAccessibilityObjectKey] = []
     var accessibilityFocusedObjectKey: CanvasAccessibilityObjectKey?
+    var interactionInterruptionObservation: AnyCancellable?
     nonisolated(unsafe) var appResignObservation: NSObjectProtocol?
     nonisolated(unsafe) var windowResignObservation: NSObjectProtocol?
 
@@ -899,6 +907,19 @@
         let hasDelta = delta.width.isFinite
             && delta.height.isFinite
             && (delta.width != 0 || delta.height != 0)
+
+        // Ink, image, and shape interactions own the pointer. An incidental
+        // scroll must not take over and discard their buffered work (CVD-05);
+        // ignore the rest of its sequence, as the momentum guard below does.
+        if activeViewportGesture == nil, hasActivePointerInteraction {
+            pendingScrollMomentumMode = nil
+            if momentumEnded {
+                suppressesScrollSequence = false
+            } else if !isStandalone {
+                suppressesScrollSequence = true
+            }
+            return
+        }
 
         if directBegan {
             if activeViewportGesture?.source == .magnification {
@@ -992,6 +1013,20 @@
         let magnification = recognizer.magnification
         recognizer.magnification = 0
         let point = recognizer.location(in: self)
+        // Ink, image, and shape interactions own the pointer. A pinch must not
+        // take over and discard their buffered work (CVD-05); a continuous
+        // pinch stays ignored until its next began.
+        if activeViewportGesture == nil, hasActivePointerInteraction {
+            switch recognizer.state {
+            case .began, .changed:
+                suppressesMagnification = true
+                return
+            case .possible:
+                return
+            default:
+                break
+            }
+        }
 
         switch recognizer.state {
         case .began:
@@ -1248,15 +1283,27 @@
     func activateRepresentation() {
         isRepresentationActive = true
         gestureRecognizers.forEach { $0.isEnabled = true }
+    }
+
+    /// Discards unfinished input for a transient interruption while keeping
+    /// this representation, its caches, and in-flight imports alive.
+    func interruptTransientInteraction() {
+        guard isRepresentationActive else { return }
+        if !finishSemanticTextEditing(commit: true) { suspendSemanticTextEditing() }
+        cancelInteraction()
     }
 
+    /// File-promise deliveries are owned by this view and end with it.
+    /// Session-owned image imports are cancelled only by explicit user
+    /// cancellation or the session's lifecycle cancellation, so replacing
+    /// the view (for example, on a section change) cannot abort them.
     func deactivateRepresentation() {
         if !finishSemanticTextEditing(commit: true) { suspendSemanticTextEditing() }
         isRepresentationActive = false
+        interactionInterruptionObservation = nil
         gestureRecognizers.forEach { $0.isEnabled = false }
         cancelInteraction()
         cancelFilePromiseBatches()
-        onCancelImageImportBatches()
         onViewportChange = { _ in }
     }
 
--- a/Attic/Canvas/CanvasSession.swift
+++ b/Attic/Canvas/CanvasSession.swift
@@ -39,7 +39,14 @@
     @Published private(set) var canUndo = false
     @Published private(set) var canRedo = false
     @Published private(set) var lastErrorMessage: String?
+    /// Bumped only by board lifecycle and termination cancellation; the native
+    /// surface is rebuilt when it changes.
     @Published private(set) var interactionCancellationEpoch: UInt64 = 0
+    /// Delivered synchronously to the live native surface for transient
+    /// interruptions (zoom commands, panel hide, section changes). Unlike the
+    /// cancellation epoch it keeps the surface, its caches, and in-flight
+    /// imports alive.
+    let interactionInterruptions = PassthroughSubject<Void, Never>()
     @Published private(set) var pendingPlacement: CanvasPendingPlacement?
     @Published private(set) var imageImportProgress: CanvasImageImportBatchProgress?
     @Published private(set) var failedImageIDs: Set<UUID> = []
@@ -494,12 +501,15 @@
     @discardableResult
     func selectCanvas(_ id: UUID) -> Bool {
         guard id != selectedCanvasID else { return true }
-        cancelPendingPlacement()
-        cancelActiveInteraction()
-        selectedImageID = nil
+        let previousCanvasID = selectedCanvasID
         isApplyingLocalMutation = true
         let succeeded = store.selectCanvas(id)
-        synchronizeFromStore(clearHistory: true)
+        // A refused selection changed nothing: keep history, placement,
+        // imports, and the native surface (CVD-02). Clearing the history
+        // resets placement and interaction.
+        let boardChanged = succeeded || store.selectedCanvasID != previousCanvasID
+        if boardChanged { selectedImageID = nil }
+        synchronizeFromStore(clearHistory: boardChanged)
         isApplyingLocalMutation = false
         return succeeded
     }
@@ -517,12 +527,13 @@
             return nil
         }
         #endif
-        cancelPendingPlacement()
-        cancelActiveInteraction()
-        selectedImageID = nil
+        let previousCanvasID = selectedCanvasID
         isApplyingLocalMutation = true
         let created = store.createCanvas(name: name)
-        synchronizeFromStore(clearHistory: true)
+        // An invalid name or failed save must not cost undo history (CVD-02).
+        let boardChanged = created != nil || store.selectedCanvasID != previousCanvasID
+        if boardChanged { selectedImageID = nil }
+        synchronizeFromStore(clearHistory: boardChanged)
         isApplyingLocalMutation = false
         return created
     }
@@ -540,14 +551,15 @@
 
     @discardableResult
     func deleteSelectedCanvas() -> Bool {
-        cancelPendingPlacement()
-        cancelActiveInteraction()
-        selectedImageID = nil
         let id = selectedCanvasID
         let succeeded = applyLocalMutation {
             store.deleteCanvas(id)
         }
-        if succeeded {
+        // A refused delete (for example, the last canvas) changed nothing.
+        if succeeded || selectedCanvasID != id {
+            cancelPendingPlacement()
+            cancelActiveInteraction()
+            selectedImageID = nil
             clearHistory()
         }
         return succeeded
@@ -1413,11 +1425,23 @@
         scheduleViewStateSave()
     }
 
+    /// Lifecycle cancellation for a board switch, create, or delete, an
+    /// external history reset, and stop/termination. Cancels session-owned
+    /// image imports and rebuilds the native surface.
     func cancelActiveInteraction() {
         flushViewState()
+        cancelAllImageImportBatches()
         interactionCancellationEpoch &+= 1
     }
 
+    /// Transient interruption: the live surface commits or suspends text
+    /// editing and discards unfinished input, but is not rebuilt and does not
+    /// cancel image imports.
+    func interruptActiveInteraction() {
+        flushViewState()
+        interactionInterruptions.send()
+    }
+
     func flushViewState() {
         viewStateSaveTask?.cancel()
         viewStateSaveTask = nil
--- a/Attic/Views/Panel/CanvasPanelContent.swift
+++ b/Attic/Views/Panel/CanvasPanelContent.swift
@@ -395,7 +395,7 @@
     }
 
     private func zoom(by factor: Double) {
-        session.cancelActiveInteraction()
+        session.interruptActiveInteraction()
         session.zoom(by: factor, anchoredAt: CGPoint(x: surfaceSize.width / 2, y: surfaceSize.height / 2), in: surfaceSize)
     }
 
--- a/Attic/Views/Panel/AtticPanelView.swift
+++ b/Attic/Views/Panel/AtticPanelView.swift
@@ -806,7 +806,7 @@
         isQuickEntryFocused = false
         uiState.setInteractionLock(.quickEntryFocus, isActive: false)
         if uiState.selectedSection.isCanvas {
-            canvasSession.cancelActiveInteraction()
+            canvasSession.interruptActiveInteraction()
         }
 
         let selection = {
--- a/Attic/Window/AtticPanelController.swift
+++ b/Attic/Window/AtticPanelController.swift
@@ -466,7 +466,7 @@
         // Destructive/transient presentation state changes only after the
         // persistence boundary accepts the hide transaction.
         hostingView.cancelActiveInteraction(reason: .explicitHide)
-        canvasSession.cancelActiveInteraction()
+        canvasSession.interruptActiveInteraction()
         uiState.isCanvasConfirmationPresented = false
         uiState.dockingPreviewCorner = nil
         uiState.setInteractionLock(.windowMove, isActive: false)
--- a/AtticTests/CanvasDomainTests.swift
+++ b/AtticTests/CanvasDomainTests.swift
@@ -1853,6 +1853,14 @@
         ))
         event.flags = .maskCommand
         event.location = CGPoint(x: 120, y: 160)
+        // A stroke owns the pointer: the zoom waits instead of discarding it
+        // (CVD-05).
+        view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
+        XCTAssertEqual(view.interaction.machine.state, .drawing)
+        XCTAssertEqual(view.interaction.viewport, CanvasViewport())
+        XCTAssertNil(deliveredViewport)
+        view.finishPointerInteraction(finalInkPoint: nil)
+
         view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
 
         XCTAssertEqual(view.interaction.machine.state, .idle)
@@ -2230,10 +2238,142 @@
 
         XCTAssertFalse(view.isRepresentationActive)
         XCTAssertFalse(recognizer.isEnabled)
+        XCTAssertTrue(deliveredViewports.isEmpty)
+        XCTAssertEqual(view.interaction.viewport, CanvasViewport())
+    }
+
+    @MainActor
+    func testIncidentalScrollCannotDiscardBufferedInk() throws {
+        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 380))
+        _ = view.interaction.configure(strokes: [], tool: .pen, color: .ink, width: 3, viewport: CanvasViewport())
+        var deliveredViewports: [CanvasViewport] = []
+        var completedStrokes: [[CanvasPoint]] = []
+        view.onViewportChange = { deliveredViewports.append($0) }
+        view.onCompleteStroke = { points, _, _ in completedStrokes.append(points) }
+
+        XCTAssertTrue(view.interaction.beginInk(at: CGPoint(x: 40, y: 50), in: view.bounds.size))
+        XCTAssertTrue(view.interaction.appendInk(at: CGPoint(x: 60, y: 70), in: view.bounds.size))
+        // Trackpad phases, a momentum tail, and a standalone wheel event.
+        for event in [
+            try canvasScrollEvent(deltaY: 8, command: false, phase: 1),
+            try canvasScrollEvent(deltaY: 6, command: true, phase: 2),
+            try canvasScrollEvent(deltaY: 0, command: false, phase: 4),
+            try canvasScrollEvent(deltaY: 5, command: false, momentumPhase: 1),
+            try canvasScrollEvent(deltaY: 4, command: false, momentumPhase: 2),
+            try canvasScrollEvent(deltaY: 0, command: false, momentumPhase: 3),
+            try canvasScrollEvent(deltaY: 7, command: false)
+        ] {
+            view.scrollWheel(with: event)
+            XCTAssertEqual(view.interaction.machine.state, .drawing)
+            XCTAssertNil(view.activeViewportGesture)
+        }
         XCTAssertTrue(deliveredViewports.isEmpty)
+        XCTAssertEqual(view.interaction.viewport, CanvasViewport())
+
+        view.finishPointerInteraction(finalInkPoint: CGPoint(x: 80, y: 90))
+        XCTAssertEqual(completedStrokes.count, 1)
+        XCTAssertEqual(completedStrokes.first?.count, 3)
+        XCTAssertEqual(view.interaction.machine.state, .idle)
+
+        view.scrollWheel(with: try canvasScrollEvent(deltaY: 8, command: false, phase: 1))
+        view.scrollWheel(with: try canvasScrollEvent(deltaY: 0, command: false, phase: 4))
+        XCTAssertEqual(deliveredViewports.count, 1)
+        XCTAssertNotEqual(view.interaction.viewport.center, CanvasViewport().center)
+    }
+
+    @MainActor
+    func testIncidentalPinchCannotDiscardBufferedInk() throws {
+        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 380))
+        _ = view.interaction.configure(strokes: [], tool: .pen, color: .ink, width: 3, viewport: CanvasViewport())
+        let installed = try XCTUnwrap(view.gestureRecognizers.compactMap {
+            $0 as? NSMagnificationGestureRecognizer
+        }.first)
+        let action = try XCTUnwrap(installed.action)
+        let recognizer = DrivenMagnificationGestureRecognizer(target: view, action: action)
+        view.removeGestureRecognizer(installed)
+        view.addGestureRecognizer(recognizer)
+        var deliveredViewports: [CanvasViewport] = []
+        var completedStrokes: [[CanvasPoint]] = []
+        view.onViewportChange = { deliveredViewports.append($0) }
+        view.onCompleteStroke = { points, _, _ in completedStrokes.append(points) }
+
+        func drive(_ state: NSGestureRecognizer.State, magnification: CGFloat) {
+            recognizer.drive(state, magnification: magnification)
+            XCTAssertTrue(NSApplication.shared.sendAction(action, to: view, from: recognizer))
+        }
+
+        // A short pinch that begins and ends while drawing.
+        XCTAssertTrue(view.interaction.beginInk(at: CGPoint(x: 40, y: 50), in: view.bounds.size))
+        drive(.began, magnification: 0)
+        drive(.ended, magnification: 0.2)
+        XCTAssertEqual(view.interaction.machine.state, .drawing)
+
+        // A pinch that outlives the stroke stays ignored until a new began.
+        XCTAssertTrue(view.interaction.appendInk(at: CGPoint(x: 60, y: 70), in: view.bounds.size))
+        recognizer.drive(.possible, magnification: 0)
+        drive(.began, magnification: 0)
+        drive(.changed, magnification: 0.25)
+        XCTAssertEqual(view.interaction.machine.state, .drawing)
+        XCTAssertNil(view.activeViewportGesture)
+        view.finishPointerInteraction(finalInkPoint: nil)
+        XCTAssertEqual(completedStrokes.count, 1)
+        XCTAssertEqual(completedStrokes.first?.count, 2)
+        drive(.changed, magnification: 0.25)
+        drive(.ended, magnification: 0.1)
         XCTAssertEqual(view.interaction.viewport, CanvasViewport())
+        XCTAssertTrue(deliveredViewports.isEmpty)
+
+        recognizer.drive(.possible, magnification: 0)
+        drive(.began, magnification: 0)
+        drive(.changed, magnification: 0.25)
+        drive(.ended, magnification: 0)
+        XCTAssertEqual(view.interaction.viewport.scale, 1.25, accuracy: 0.001)
+        XCTAssertFalse(deliveredViewports.isEmpty)
+        XCTAssertEqual(view.interaction.machine.state, .idle)
     }
 
+    @MainActor
+    func testTransientInterruptionReachesLiveSurfaceWithoutRebuildingIt() async throws {
+        let session = CanvasSession(store: try makeTestCanvasStore())
+        let placed = await session.insertText("Keep", at: .zero, prefersDarkSurface: false)
+        XCTAssertTrue(placed)
+        let object = try XCTUnwrap(session.selectedSemanticObject)
+        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
+        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
+        window.contentView = view
+        let bridge = CanvasNSViewRepresentable(session: session, selectionAccentColor: .systemBlue,
+                                               clearReadabilityEnabled: false)
+        bridge.configure(view)
+        let epoch = session.interactionCancellationEpoch
+
+        // Zoom, hide, and section changes commit an open text editor.
+        view.beginSemanticTextEditing(object)
+        let editor = try XCTUnwrap(view.semanticTextEditor)
+        editor.insertText(" edited", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
+        session.interruptActiveInteraction()
+        XCTAssertNil(view.semanticTextEditor)
+        XCTAssertEqual(session.semanticObjects.first { $0.id == object.id }?.content?.text, "Keep edited")
+
+        // ...and discard unfinished ink on the same live surface.
+        session.selectTool(.pen)
+        bridge.configure(view)
+        let strokeCount = session.strokes.count
+        XCTAssertTrue(view.interaction.beginInk(at: CGPoint(x: 40, y: 50), in: view.bounds.size))
+        XCTAssertTrue(view.interaction.appendInk(at: CGPoint(x: 60, y: 70), in: view.bounds.size))
+        session.interruptActiveInteraction()
+        XCTAssertEqual(view.interaction.machine.state, .idle)
+        view.finishPointerInteraction(finalInkPoint: nil)
+        XCTAssertEqual(session.strokes.count, strokeCount)
+        XCTAssertTrue(view.isRepresentationActive)
+        XCTAssertEqual(session.interactionCancellationEpoch, epoch)
+
+        // A dismantled surface stops observing; lifecycle still rebuilds.
+        CanvasNSViewRepresentable.dismantleNSView(view, coordinator: ())
+        XCTAssertNil(view.interactionInterruptionObservation)
+        session.cancelActiveInteraction()
+        XCTAssertEqual(session.interactionCancellationEpoch, epoch + 1)
+    }
+
     private func canvasScrollEvent(
         deltaX: Int32 = 0,
         deltaY: Int32,
--- a/AtticTests/CanvasImageTests.swift
+++ b/AtticTests/CanvasImageTests.swift
@@ -914,9 +914,73 @@
         XCTAssertEqual(session.images.map(\.id), [batch.items[0].id, batch.items[2].id])
         XCTAssertEqual(persistence.saveCount, 1)
         XCTAssertFalse(FileManager.default.fileExists(atPath: cleanupRoot.path))
+    }
+
+    @MainActor
+    func testSessionImportSurvivesTransientInterruptionAndSurfaceDismantle() async throws {
+        let container = try PersistenceController.makeContainer(inMemory: true)
+        let gate = ControlledCanvasImagePreparer()
+        let session = makeSession(container: container, gate: gate)
+        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 380))
+        CanvasNSViewRepresentable(session: session, selectionAccentColor: .systemBlue,
+                                  clearReadabilityEnabled: false).configure(view)
+        let batch = makeBatch(target: session.captureImageImportTarget(), indices: [0, 1])
+        let epoch = session.interactionCancellationEpoch
+
+        session.startImageImportBatch(batch)
+        await gate.waitUntilStarted(count: 2)
+        // Zoom and panel hide interrupt the live surface; a section change
+        // dismantles it. None of them owns the session's imports.
+        session.interruptActiveInteraction()
+        CanvasNSViewRepresentable.dismantleNSView(view, coordinator: ())
+        await gate.release(0)
+        await gate.release(1)
+        let imported = await waitUntil { session.images.count == 2 }
+
+        XCTAssertTrue(imported)
+        XCTAssertEqual(Set(session.images.map(\.id)), Set(batch.items.map(\.id)))
+        XCTAssertEqual(session.interactionCancellationEpoch, epoch)
+        let cancellations = await gate.cancellationCount()
+        XCTAssertEqual(cancellations, 0)
+    }
+
+    @MainActor
+    func testBoardLifecycleCancellationStillCancelsSessionImports() async throws {
+        let container = try PersistenceController.makeContainer(inMemory: true)
+        let gate = ControlledCanvasImagePreparer()
+        let session = makeSession(container: container, gate: gate)
+        _ = try XCTUnwrap(session.createCanvas(name: "First"))
+
+        session.startImageImportBatch(makeBatch(target: session.captureImageImportTarget(), indices: [0]))
+        await gate.waitUntilStarted(count: 1)
+        let switchEpoch = session.interactionCancellationEpoch
+        _ = try XCTUnwrap(session.createCanvas(name: "Second"))
+        XCTAssertGreaterThan(session.interactionCancellationEpoch, switchEpoch)
+        let cancelledBySwitch = await waitUntil { await gate.cancellationCount() == 1 }
+        XCTAssertTrue(cancelledBySwitch)
+
+        session.startImageImportBatch(makeBatch(target: session.captureImageImportTarget(), indices: [1]))
+        await gate.waitUntilStarted(count: 2)
+        let terminationEpoch = session.interactionCancellationEpoch
+        session.cancelActiveInteraction()
+        XCTAssertEqual(session.interactionCancellationEpoch, terminationEpoch + 1)
+        let cancelledByTermination = await waitUntil { await gate.cancellationCount() == 2 }
+        XCTAssertTrue(cancelledByTermination)
+        XCTAssertTrue(session.images.isEmpty)
+        let rows = try ModelContext(container).fetch(FetchDescriptor<CanvasImageItem>())
+        XCTAssertTrue(rows.isEmpty)
     }
 
     @MainActor
+    private func waitUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
+        for _ in 0..<500 {
+            if await condition() { return true }
+            try? await Task.sleep(for: .milliseconds(10))
+        }
+        return await condition()
+    }
+
+    @MainActor
     private func makeSession(
         container: ModelContainer,
         gate: ControlledCanvasImagePreparer,
--- a/AtticTests/CanvasSessionTests.swift
+++ b/AtticTests/CanvasSessionTests.swift
@@ -73,6 +73,43 @@
     }
 
     @MainActor
+    func testRefusedBoardOperationsKeepHistoryPlacementAndSurface() throws {
+        let session = CanvasSession(store: try makeTestCanvasStore())
+        XCTAssertTrue(session.completeStroke(points: [.zero, CanvasPoint(x: 20, y: 30)]))
+        XCTAssertTrue(session.prepareTextPlacement("Keep placing", prefersDarkSurface: false))
+        let placement = try XCTUnwrap(session.pendingPlacement)
+        let undoCount = session.undoCommandCount
+        let epoch = session.interactionCancellationEpoch
+        let boardID = session.selectedCanvasID
+        XCTAssertGreaterThan(undoCount, 0)
+
+        XCTAssertNil(session.createCanvas(name: "   "))
+        XCTAssertFalse(session.selectCanvas(UUID()))
+        XCTAssertFalse(session.deleteSelectedCanvas())
+        XCTAssertEqual(session.selectedCanvasID, boardID)
+        XCTAssertEqual(session.undoCommandCount, undoCount)
+        XCTAssertTrue(session.canUndo)
+        XCTAssertEqual(session.pendingPlacement, placement)
+        XCTAssertEqual(session.interactionCancellationEpoch, epoch)
+        XCTAssertTrue(session.undo())
+
+        // Real board changes still reset history, placement, and the surface.
+        let second = try XCTUnwrap(session.createCanvas(name: "Second"))
+        XCTAssertEqual(session.selectedCanvasID, second.id)
+        XCTAssertEqual(session.undoCommandCount, 0)
+        XCTAssertNil(session.pendingPlacement)
+        XCTAssertGreaterThan(session.interactionCancellationEpoch, epoch)
+        let changes: [() -> Bool] = [{ session.selectCanvas(boardID) }, { session.deleteSelectedCanvas() }]
+        for change in changes {
+            XCTAssertTrue(session.completeStroke(points: [.zero, CanvasPoint(x: 40, y: 10)]))
+            let before = session.interactionCancellationEpoch
+            XCTAssertTrue(change())
+            XCTAssertEqual(session.undoCommandCount, 0)
+            XCTAssertGreaterThan(session.interactionCancellationEpoch, before)
+        }
+    }
+
+    @MainActor
     func testImageBatchAndHistoryKeepOneSelectionKind() async throws {
         let prepared = CanvasPreparedImage(encodedData: Data([1, 2, 3]), contentType: "public.png", pixelWidth: 20, pixelHeight: 20)
         let session = CanvasSession(store: try makeTestCanvasStore(), prepareImage: { _ in prepared })
```

---

**Final status: REVIEW_READY** — awaiting independent SWE-2 Max review, then Sol Low native QA. Native evidence remains **PENDING**.
