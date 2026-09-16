# Deep Audit Batch 2 — Canvas recovery, editing, and text layout

**Date:** 2026-09-15

**Repository:** `/Users/taha/Developer/attic-task-panels-v2`

**Branch:** `codex/attic-task-panels-v2`

**HEAD:** `ae6418c1af690e29d15a20344cdb9765a23d3f85`. No commits and no pushes were made.

**Sources:**

- `Docs/DeepAudit-Consolidated-2026-09-15.md`, section "Batch 2 — Canvas recovery, editing, and text layout"
- `Docs/DeepAudit-Canvas-2026-09-14.md`, findings CVD-03, CVD-04, CVD-06, CVD-08, and CVX-06

**Prerequisite:** Batch 1 (`Docs/Batch1-Remediation-Implementation.md`) was already present in the dirty tree. It was neither redone nor reverted.

**Review snapshot:** `/tmp/attic-b2-snapshot-20260915T1845Z` (read-only). See §8.

## 1. Scope and boundaries

Batch 2 fixes exactly five findings:

| Finding | Fix |
|---|---|
| **CVD-03** | Retry now requeues every failed image, not just the first. |
| **CVD-04** | Retry now works for a failed image outside the decode candidate set. |
| **CVD-06** | Toolbar and Add ▸ Edit menu Undo/Redo go through `CanvasEditCommandRoute`. |
| **CVD-08** | A committed resize of a text object refits its height to the new width, so persisted text is never clipped. |
| **CVX-06** | Keyboard resize uses the pointer minimum, `CanvasImagePlacement.minimumDimension` (48). |

What was not done:

- Nothing outside these five findings changed.
- There is no Canvas redesign and no cache redesign.
- No project inputs changed. All tests were added to existing files, so `Scripts/generate_project.rb` and `verify_project_generation.rb` were not needed.
- No app was launched.
- No CloudKit, mobile, attachment-root, or user-data work was done.

The persistence path is unchanged: `applyLocalMutation` and `store.updateSemanticObject` handle saves exactly as before. Replica resolution, undo history bounds, external storage, and hit testing are also unchanged.

## 2. Pre-existing dirty tree and baseline hashes

**Before any edit:**

- `git status --porcelain -uall` listed 330 entries: tracked modifications from earlier batches plus untracked docs and evidence. The list is saved as `/tmp/attic-b2/status-before.txt`.
- Every one of those paths was hashed into `/tmp/attic-b2/all-hashes-before.txt`.
- The full inherited diff was saved as `/tmp/attic-b2/full-dirty-diff-before.patch`.
- Pristine copies of the owned and context files were saved in `/tmp/attic-b2/baseline/`.

**Pre-edit SHA-256 of owned files:**

| File | State at baseline | SHA-256 |
|---|---|---|
| `Attic/App/CanvasEditCommandRoute.swift` | clean | `7baab4b52dee5d097ae37aeaffc3b73ef33e22a8a796242d9f3984358bc651e6` |
| `Attic/Canvas/CanvasImageTypes.swift` | dirty (inherited) | `560b2eeb7d0156e685f55f58bcffdbe3b775782ee46705a451ffbc9913fbd2a7` |
| `Attic/Canvas/CanvasSession.swift` | dirty (inherited) | `ebec9d9fa5c905ffff71ed58e95f5efa9adf978c98d83f0f8e954a53353fb586` |
| `Attic/Canvas/CanvasSurfaceMac.swift` | dirty (inherited) | `47a3115e41f7391b09e5f344f71ef00251cdc029742dc52c72b946a108965152` |
| `Attic/Canvas/CanvasSurfaceRenderer.swift` | clean | `1eb185644dcd9f62bb92a7013e083d132b0f4f4d6154573d4e6b87a5f6a1b304` |
| `Attic/Views/Panel/CanvasPanelContent.swift` | dirty (inherited) | `1e35eb7f07024d32e4734750739ba7d40e251d6ef0e00c4495b2efa08a87734b` |
| `AtticTests/CanvasDomainTests.swift` | dirty (inherited) | `120bb04d8d835a89de04f51520c611cdb40c015fb500f92863bd851dc849a15d` |
| `AtticTests/CanvasRenderCacheTests.swift` | clean | `078b8f903c3c2197f0162cefa0e19363aa916b51fdf851087cd211b3ec9c9077` |
| `AtticTests/CanvasSessionTests.swift` | dirty (inherited) | `beb9dba1f9152b54ad157a617acad43c37afc12b0fadb9b509db93964234c721` |

**Read-only context files** were also snapshotted, and all four are still byte-identical to baseline:

| File | SHA-256 |
|---|---|
| `Attic/App/AtticApp.swift` | `ffa672a8…` |
| `Attic/Canvas/CanvasSemanticRenderer.swift` | `61f32a2c…` |
| `Attic/Canvas/CanvasSemanticInteraction.swift` | `8e19f2d6…` |
| `AtticTests/CanvasImageTests.swift` | `9286a604…` |

**Post-fix SHA-256 of owned files:**

| File | SHA-256 |
|---|---|
| `Attic/App/CanvasEditCommandRoute.swift` | `4667608109c75c3b2731dac21bdc741f48296d74763b27c489354cdfd685b2bf` |
| `Attic/Canvas/CanvasImageTypes.swift` | `40d1ff2687918c432a2f471b3f91660a5cecc96566aaddb6d52cb91dcc0ce954` |
| `Attic/Canvas/CanvasSession.swift` | `c268412d6a25d33c910616823d1eef864b016bd935055443f21e83d688ea0c81` |
| `Attic/Canvas/CanvasSurfaceMac.swift` | `67477ef5d0faa803d713e6758a746e6cd42a7189449d4281c687dbc096040a6e` |
| `Attic/Canvas/CanvasSurfaceRenderer.swift` | `48c81ecf1a1085ba8a98239e8c4e561959cbd284898e534f7227009a5f408b19` |
| `Attic/Views/Panel/CanvasPanelContent.swift` | `169ead83d88d118b6e0515e3f26967e529ff38e13837cd65bb1572802326336b` |
| `AtticTests/CanvasDomainTests.swift` | `2777a07d58571a48de7c587f39bf646e2858f1e8fb5ce1a2fb07971b1d18562b` |
| `AtticTests/CanvasRenderCacheTests.swift` | `dac3e3aac349a2ee42288dbdd93feaf495b434b72e77781968eba4255b9f79fb` |
| `AtticTests/CanvasSessionTests.swift` | `f5f8cdd34897ba633f62277a88f3dbad1ca18adf1653eaa6248223d7eba2b0dd` |

**Scope proof after the fix:**

- `shasum -a 256 -c /tmp/attic-b2/all-hashes-before.txt` reports FAILED for exactly six paths. They are the six owned files that were already dirty at baseline: `CanvasImageTypes`, `CanvasSession`, `CanvasSurfaceMac`, `CanvasPanelContent`, `CanvasDomainTests`, and `CanvasSessionTests`. All other inherited paths are byte-identical.
- The status diff against baseline adds exactly four entries:
  - ` M Attic/App/CanvasEditCommandRoute.swift` (owned)
  - ` M Attic/Canvas/CanvasSurfaceRenderer.swift` (owned)
  - ` M AtticTests/CanvasRenderCacheTests.swift` (owned)
  - `?? Docs/Native-Verification-Playbook.md` (**not created by this batch**)
- This report, `Docs/DeepAudit-Batch2-Implementation.md`, is written after that check. It adds one more untracked entry.

**About `Docs/Native-Verification-Playbook.md`:** it was created on 2026-09-15 at 19:11:17 local time, while this batch was running, by another actor. Batch 2 never wrote it. It is left untouched and excluded from the owned diff, and the snapshot copies it only because it is untracked.

## 3. Confirmed hypotheses and fixes

### 3.1 CVD-03: retry only requeued the first failed image

**Hypothesis:** `CanvasSession.retryFailedImageDecodes()` picked `images.first(where: failedImageIDs.contains)`. The retry request type (`CanvasImageDecodeRetryRequest`) could carry only one `imageID`, so a banner showing N failures repaired one image per click.

**Discriminating evidence (unfixed run):** `testRetryFailedImageDecodesRequeuesEveryVisibleFailure` failed at `CanvasDomainTests.swift:1086` with `XCTAssertNotEqual failed: ("failed") is equal to ("failed")`. After retry plus `configure`, one of the two visible corrupt images was still `.failed`.

**Fix:**

- `CanvasImageTypes.swift:3-6`: the request now carries `imageIDs: Set<UUID>`.
- `CanvasSession.swift:374-389`:
  - `retryImageDecode(_:)` sends `[id]`.
  - `retryFailedImageDecodes()` sends `Set(images.map(\.id)).intersection(failedImageIDs)` and returns `false` if that set is empty.
- `CanvasSurfaceMac.swift:151-157`: the configure bridge calls `imageCache.retryDecode(for:)` for every image in `request.imageIDs`.
- The request is still consumed once per `attemptID`. There is no iOS consumer, and the accessibility retry action (`CanvasSurfaceMacHelpers.swift:489`) still retries a single image directly.

### 3.2 CVD-04: retry for an off-screen failure silently did nothing

**Hypothesis:** there were three separate gates, and each could silently drop a retry of an image outside the candidate set:

1. `CanvasImageDecodeCache.retryDecode` returned early unless `visibleKeys.contains(key)`.
2. Even without that guard, the next `prepare(for:)` would prune the queued retry, since `queued` was filtered to `visibleKeys`. `prepare` runs on every `configure` and every draw.
3. With `cancelsActiveDecodesWhenRemoved == true`, `prepare` cancelled the active retry and `finishDecode` discarded its result.

Meanwhile `session.failedImageIDs`, which drives the banner, spans all images, so Retry returned `true` while scheduling nothing.

**Discriminating evidence (unfixed runs):**

- **Cache unit test:** `testRetryDecodeRequeuesOffScreenFailureAcrossCandidatePruning` failed in both cancellation modes:
  - `("failed") is not equal to ("queued")` at lines 403 and 408
  - `("failed") is not equal to ("decoding")` at line 414
  - `[70, 71] != [70, 71, 70]` at line 422, meaning the retry never started
- **View integration test:** `testRetryFailedImageDecodesRequeuesOffScreenFailure` failed at `CanvasDomainTests.swift:1126` and `1129`. The off-screen image (x = 3000, outside the candidate set) stayed `.failed` after retry and a later configure.

**Fix (`CanvasSurfaceRenderer.swift`):** a small `retryKeys: Set<UUID>` tracks explicit retries of keys outside `visibleKeys`.

| Line | Change |
|---|---|
| 176 | `retryDecode` requires only a remembered failure (`failed.remove(key) != nil`). It still refuses never-failed or ready keys. |
| 179 | If the key is not visible and was actually queued, it is added to `retryKeys`. |
| 142 | `prepare` keeps queued entries that are visible or in `retryKeys`. |
| 144 | `prepare` does not cancel active decodes for retry keys. |
| 282, 292 | `finishDecode` consumes the retry key and keeps a retried result even when it is not visible. |
| 191 | `removeAll()` clears `retryKeys`, so page and lifecycle teardown still cancels everything. |

**Why the change is bounded:**

- A key leaves `retryKeys` when its attempt finishes or on `removeAll`.
- Only keys already in the bounded failure memo can enter it.
- `rebuildQueueOrder` still places visible candidates ahead of retries.
- Worker concurrency (`maximumConcurrentDecodes`) is unchanged.

**Separate testability:** the session multi-ID mechanism and the cache off-screen mechanism have separate tests and separate mutants (§5).

### 3.3 CVD-06: toolbar and menu Undo/Redo bypassed the focused text editor

**Hypothesis:** `CanvasPanelContent` toolbar buttons (`canvas-undo`, `canvas-redo`) and the Add ▸ Edit ▸ Undo/Redo menu items called `session.undo()` and `session.redo()` directly. While a text editor was focused, they changed canvas history instead of undoing typing. The app's Cmd-Z commands (`AtticApp.swift`) already use `CanvasEditCommandRoute`.

**Discriminating evidence (unfixed run, final test text):** `testToolbarAndMenuUndoRedoFollowFocusedTextEditor` failed with:

- `("Keep draft") is not equal to ("Keep") - toolbar Undo must undo typing in the focused editor` (line 1244)
- `("0") is not equal to ("1") - toolbar Undo must not pop canvas history while editing` (1245; the text object was removed)
- The same pair for menu Undo (1253, 1254)
- An editor identity failure at 1261

**Test harness notes:**

- The test hosts the real `CanvasPanelContent` in an `NSHostingView`.
- The window is borderless, positioned at (-20000, -20000), ordered front, and never made key.
- It clicks rendered toolbar buttons with `window.sendEvent`.
- It opens the real Add menu with `NSPopUpButtonCell.performClick` and chooses Edit ▸ Undo/Redo from an event-tracking timer.
- It sets up canvas history with both an undo and a redo available, so a misrouted Undo **or** Redo is observable.

**Fix:**

- **`CanvasEditCommandRoute.swift:8-12`:** adds a macOS-only `focusedResponder` seam that defaults to `{ NSApp.keyWindow?.firstResponder }`, the same expression as before, and uses it at the five existing responder lookups.
  - The unit-test host can never own a key window, so tests inject the hosting window's first responder and restore it in a `defer`.
  - The seam was added together with the tests, before the fix, and was present in the unfixed failing run. It changes no production behavior.
- **`CanvasPanelContent.swift`:**
  - The toolbar (lines 366-373) and menu (lines 477-485) call `CanvasEditCommandRoute.undo/redo(session:section: .canvas)`.
  - Disabled state uses `canUndoCanvasEdit` / `canRedoCanvasEdit` (lines 28-35), defined as `session.canX || CanvasEditCommandRoute.canX(...)`.
  - The session term is kept on purpose. Typing in the AppKit editor does not republish `CanvasSession`, so a disabled state based only on the route could stay disabled after the user types.

### 3.4 CVD-08: narrowing a text object persisted clipped text

**Hypothesis:** `CanvasSemanticRenderer` lays text out in `(width − 8) × (height − 8)` and clips to the object rect. `transformSemanticObject`, used by pointer resize, keyboard resize, nudge, and layer changes, stored any valid transform with no reflow. Only `editSemanticObject` grew height.

**Discriminating evidence (unfixed runs):**

- **Session test:** `testNarrowingTextResizeGrowsHeightSoPersistedTextIsNotClipped` failed on:
  - `97.0 is not greater than 97.0` (height did not grow)
  - the CoreText visible-range check at 297 and 300: the persisted object in a fresh `CanvasStore` shows fewer characters than the string
  - the squash negative control at 316-318: a 48-point height was persisted and clipped
- **Pointer path:** `testPointerNarrowingTextResizeGrowsHeightToFitCommittedText` drives a real `mouseDown/Dragged/Up` on the bottom-right handle of a `CanvasNSView` in a panel. It failed the same way at `CanvasDomainTests.swift:1303-1304`.

**Fix (`CanvasSession.swift:1288-1305`):**

- **Trigger:** the object has text content and the proposed width or height differs from the current transform.
- **Refit:** set height to `max(proposed height, CanvasSemanticRenderer.textSize(content, width:).height)`, the same function `editSemanticObject` uses. Then shift `center.y` by half the growth so the top edge stays fixed.
- **Validation:** the existing `isValid` and "changed" guards run after the refit. A resize that refits back to the current transform returns `false` and records nothing.
- **Unaffected paths:**
  - moves and z-order changes
  - shapes, which have no text
  - undo and redo, which restore snapshots via `.changeSemantic`
- **Undo:** records the refitted `after`, so undo and redo restore exact transforms. The tests assert this.

### 3.5 CVX-06: keyboard resize allowed 24 where pointer resize allowed 48

**Hypothesis:** `resizeSelectedSemanticObject(by:)` floored width and height at `24`, while pointer resize (`CanvasImagePlacement.resizedTransform`) floors at `minimumDimension = 48`.

**Discriminating evidence (unfixed run):** `testKeyboardSemanticResizeSharesPointerMinimumDimension` failed with:

- `24.0 != 48.0` at lines 339 and 340: the keyboard floor differs from the floor `resizedTransform` actually produces
- `48 != 96` at 345: growth from the too-small floor
- `24.0 != 48.0` at 352 and `24.0 < 48.0` at 353: keyboard-shrunk text
- visibility check false at 354

**Fix (`CanvasSession.swift:1353-1358`):** both floors use `CanvasImagePlacement.minimumDimension`.

**Separate testability:** the keyboard test's shape section (lines 322-345) does not depend on CVD-08. Mutant M4 (§5) proves the CVD-08 revert trips only the text-visibility assertion at line 354 of this test, while the M5 revert trips the floor assertions.

## 4. Owned diff, separate from inherited work

**Patches** (all in `/tmp/attic-b2/patches/`, copied into the snapshot):

| Patch | Contents | Diffstat |
|---|---|---|
| `batch2-owned.patch` | baseline → final, all 9 owned files | 524 insertions, 27 deletions |
| `batch2-tests-first.patch` | baseline → tests-first private copy: 3 test files plus the behavior-neutral `focusedResponder` seam | 476 insertions, 5 deletions |
| `batch2-fix-only.patch` | tests-first → final; production fix only | 5 files, 48 insertions, 22 deletions |

**Reconstruction check:** applying `batch2-owned.patch` with `patch -p1` to a copy of `/tmp/attic-b2/baseline` reproduces all nine final files byte-for-byte (`cmp`).

**Production lines changed by the fix:**

| File | Change |
|---|---|
| `CanvasImageTypes.swift` | 1 line |
| `CanvasSurfaceMac.swift` | 1 line |
| `CanvasSession.swift` | retry set, transform refit, resize floor |
| `CanvasSurfaceRenderer.swift` | `retryKeys` in 6 places |
| `CanvasPanelContent.swift` | 2 computed properties, 4 routed call sites |
| `CanvasEditCommandRoute.swift` | seam plus 5 lookups |

**Tests added:**

- **`CanvasRenderCacheTests.swift`:**
  - `testRetryDecodeRequeuesOffScreenFailureAcrossCandidatePruning` (line 375). It loops over both `cancelsActiveDecodesWhenRemoved` modes and includes a never-failed negative control.
  - `private actor RecoveringCanvasDecoderProbe` (line 651), which fails the first attempt, then holds each later decode until the test releases it.
- **`CanvasSessionTests.swift`:**
  - `import CoreText`
  - `testNarrowingTextResizeGrowsHeightSoPersistedTextIsNotClipped` (274), with move and squash negative controls
  - `testKeyboardSemanticResizeSharesPointerMinimumDimension` (322)
  - an internal helper `canvasSemanticTextIsFullyVisible` (767), which compares the CoreText frame's visible string range with the string length
- **`CanvasDomainTests.swift`** (class `CanvasAccessibilityTests`):
  - `import SwiftUI`
  - `testRetryFailedImageDecodesRequeuesEveryVisibleFailure` (1067), with a no-failure negative control
  - `testRetryFailedImageDecodesRequeuesOffScreenFailure` (1101)
  - `testToolbarAndMenuUndoRedoFollowFocusedTextEditor` (1139)
  - `testPointerNarrowingTextResizeGrowsHeightToFitCommittedText` (1266)
  - private helpers `waitForCanvasCondition`, `corruptCanvasImage`, and `firstCanvasView`

## 5. Verification

**Environment:**

- Configuration: `Local` (`ATTIC_LOCAL_ONLY`), `CODE_SIGNING_ALLOWED=NO`.
- Private DerivedData paths:
  - `/tmp/attic-b2-dd` (fixed repo)
  - `/tmp/attic-b2-before-dd` (tests-first private copy `/tmp/attic-b2-before`)
  - `/tmp/attic-b2-mut-dd` (mutant copy `/tmp/attic-b2-mut`)
- Tests ran through `/tmp/attic-b2/xctest/run.zsh LABEL SECONDS TEST...`. This is the same offline XCTest injection into `AtticUnitTestHost` that Batch 1 used. Each log ends with `exit_status=`.
- Stores were in-memory only. No app launch.

**Build command:**

```
xcodebuild build-for-testing -project Attic.xcodeproj -scheme Attic -configuration Local \
  -derivedDataPath <dd> -only-testing:AtticTests CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO
```

**Results:**

| Gate | Result | Log |
|---|---|---|
| Build, tests-first copy (unfixed) | exit 0, `** TEST BUILD SUCCEEDED **` | `logs/build-before-tests-final.log` |
| Build, fixed repo | exit 0, `** TEST BUILD SUCCEEDED **`; no Swift warnings (the only `warning:` line is appintentsmetadataprocessor's "no AppIntents.framework dependency") | `logs/build-after-final.log` |
| `xcodebuild build -scheme Attic -configuration Local -destination 'platform=macOS' -derivedDataPath /tmp/attic-b2-dd CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO` | exit 0, `** BUILD SUCCEEDED **`; `Attic.app` bundle ID `com.taha.Attic`, **not launched** | `logs/build-app-after.log` |
| 7 new tests, **unfixed** (host debug dylib `ddccbc3e…`) | `Executed 7 tests, with 34 failures`, all 7 failed, `exit_status=1` | `xctest/before-fix-final.log` |
| 7 new tests, fixed (host debug dylib `79edca8c…`) | `Executed 7 tests, with 0 failures`, `exit_status=0` | `xctest/after-new-tests-final.log` |
| Focused: all 17 Canvas classes<sup>1</sup> | `Executed 205 tests, with 0 failures`, `exit_status=0` | `xctest/after-focused-final.log` |
| Full Local unit suite: 42 classes, identical to every `XCTestCase` class in `AtticTests/` and to Batch 1's list | `Executed 820 tests, with 4 tests skipped and 0 failures`, `exit_status=0` (816 passed, 4 skipped) | `xctest/after-full-unit-final.log` |
| Stability: the 4 UI-hosted tests plus the cache test, 3 repeats | 5/5 passing in every run, `exit_status=0` ×3 | `xctest/after-stability-{1,2,3}.log` |
| `git diff --check` on the 9 owned files | exit 0, clean | — |

<sup>1</sup> `CanvasAccessibilityTests`, `CanvasAffordanceTruthTests`, `CanvasDocumentStoreTests`, `CanvasDomainTests`, `CanvasImageDomainTests`, `CanvasImageDropBatchTests`, `CanvasImageImportBatchTests`, `CanvasImageImportTests`, `CanvasImageInteractionTests`, `CanvasImageSessionTests`, `CanvasImageStoreTests`, `CanvasPerformanceGateTests`, `CanvasPrecisionTests`, `CanvasRenderCacheTests`, `CanvasSessionTests`, `CanvasStoreTests`, `CanvasUITestStoreTests`.

**Test count reconciliation:** Batch 1 reported 811 tests. The full run now executes 820.

- 7 are the new Batch 2 tests.
- 2 are inherited `CanvasStoreTests` tests: `testFailedPreparationOnCreateCanvas…` and `testFailedPreparationOnDeleteCanvas…`. They were already in the baseline tree; `CanvasStoreTests.swift` has the same hash as baseline, `a586501c…`.

This was checked with `comm` between Batch 1's full log (`/tmp/attic-b1rem-snapshot-20260915T130827Z/logs/xctest/after-full-unit.log`, 811 names) and this batch's full log (820 names). The 9 names above are the only additions, and no test disappeared. Both lists are in the snapshot as `b1-tests.txt` and `b2-tests.txt`.

**Performance gates in the full run:** `Canvas decode stress: 96 images in 0.074s, max active 4`; `PERFGATE toggle=7.71 snapshot=32.13 lookup=0.0012`.

**Test text changed once after the first before and after runs.** The toolbar test's layout-settling loop was wrapped in a nested synchronous `settleLayout()`. This removed a Swift 6 "`run(until:)` unavailable from asynchronous contexts" warning and does not change behavior. The same edit was applied to the tests-first copy, and the before-failure, after, focused, full, and stability runs above were all repeated on the final text. The superseded first runs are kept in the snapshot's `xctest/` and `logs/` directories (§8).

### Mutants

All mutants ran on `/tmp/attic-b2-mut`, a copy of the fixed tree. Each reverts one mechanism, then rebuilds and runs the 7 new tests. Patches, build logs, and test logs are in `mutants/`.

| Mutant | Reverted mechanism | Result | Tests that failed |
|---|---|---|---|
| **M1** `session-first-id-only` | Session sends only the first failed ID | 3 failures | visible retry, off-screen retry. The cache unit test **passes**. |
| **M2a** `cache-retry-visible-guard` | `retryDecode` requires visibility again (1 site) | 14 failures | cache unit test in both modes, off-screen retry. The visible retry test **passes**. |
| **M2b** `cache-prepare-prunes-retry` | `prepare` prunes queued retries | 10 failures | cache unit test only |
| **M2c** `cache-finish-drops-retry` | `finishDecode` discards a non-visible retried result | 1 failure | cache unit test, `cancelsActiveDecodesWhenRemoved=true` mode only |
| **M3** `toolbar-menu-session-direct` | Toolbar and menu Undo call `session.undo()` (2 sites) | 5 failures | toolbar/menu focused-editor test only |
| **M4** `no-text-regrowth` | Refit height is the proposed height | 9 failures | both narrowing tests, plus only the text-visibility assertion (line 354) of the keyboard test |
| **M5** `keyboard-min-24` | Keyboard floor back to 24 | 5 failures | keyboard minimum test only, at lines 339, 340, 345, 352, and 354 |

**Mutant notes:**

- **M2a was run twice.** The first attempt's text anchor also matched `clearFailure` (2 sites). It is kept as `SUPERSEDED-M2a-two-site.*`. The anchor was then made unique, the script now asserts the expected site count, and M2a was rerun. The single-site result is what the table shows.
- **Why M2b and M2c are invisible to the view test:** in that test the retried decode starts at once because a worker is free. Pruning and cancellation of a queued or active retry are covered by the cache unit test.
- **M3 ran before `settleLayout()`.** The mutant copy's tests predate that behavior-identical wrapper. Mutants M1 through M5 all used that same pre-wrapper test text.
- **After the runs,** the mutant copy was restored. `diff -rq` against the repo's `Attic/` and `AtticTests/` shows one difference: the `settleLayout()` wrapper in `CanvasDomainTests.swift`.

## 6. Unresolved risks and limitations

1. **Stale enabled state while typing.**
   - **With canvas history:** the toolbar and menu Undo/Redo stay enabled because of the session term. If the focused editor has nothing to undo, clicking does nothing: the route returns `false`, the same behavior as Cmd-Z.
   - **With empty canvas history:** the controls can stay disabled after the user starts typing until something else republishes. That was already the case before this batch, since the old disabled state was the session alone.
   - **Why not fixed:** a fully live editor-driven disabled state would need `NSUndoManager` observation in SwiftUI. That is outside the smallest fix.
2. **Growth always anchors the top edge.** When the user drags a *top* handle narrower, the refitted height extends downward from the proposed top instead of keeping the bottom fixed. The text is fully visible either way.
3. **Drag preview still clips.** During a pointer drag the preview shows the unrefitted, possibly clipped box. The fit happens on commit.
4. **No shrink-to-fit.** Height only grows. Widening leaves extra space, as the audit's grow-only guidance describes.
5. **Legacy clipped objects stay clipped.** A text object already persisted in a clipped state is refitted only on its next resize, not on a move.
6. **Very thin shapes.** Keyboard shrinking now stops at 48×48, the same floor the pointer already enforced. Shapes previously shrunk below 48 by keyboard keep their stored size until resized.
7. **Retry scope.** Explicit off-screen retries use workers ahead of margin prefetch. They stay behind visible candidates in queue order and are capped by the existing failure memo and concurrency limit. Heavy corruption on huge boards was not measured; this is a structural judgment.
8. **The UI-hosted toolbar test is heavier than the others.**
   - It orders a borderless window at (-20000, -20000) and briefly tracks a real popup menu.
   - It locates buttons by scanning the rendered toolbar (about 5 s).
   - It was stable across 5 runs: final, focused, full, and stability ×3, including the 3 dedicated stability repeats.
   - A future change to toolbar layout that moves Undo/Redo off the top 72 points would make it fail at `XCTUnwrap` rather than pass falsely.
9. **Native UAT not done.** The consolidated plan's gate includes a "native Canvas editor/recovery check". This task forbids app launches, so no isolated preview was installed or exercised. Real-pointer resize feel, the real key-panel responder chain (instead of the injected `focusedResponder`), and banner recovery on a real corrupt image are covered only by the unit-hosted tests above.
10. **No CloudKit, APNs, iPhone, or Production behavior** is claimed or tested.

## 7. Files not owned but observed

- `Docs/Native-Verification-Playbook.md`: untracked, created at 19:11 by another actor during this batch. Left untouched (§2).
- The other 329 baseline status entries are unchanged, verified by hash (§2).

## 8. Review snapshot

**Path:** `/tmp/attic-b2-snapshot-20260915T1845Z`, frozen read-only (`chmod -R a-w`).

**Contents:**

| Path | Contents |
|---|---|
| `worktree/` | Every path in `git status --porcelain -uall` after the fix (modified and untracked), copied at post-fix content, including this report and the non-owned playbook |
| `baseline/` | Pre-edit copies of owned and context files; `all-hashes-before.txt`, `owned-candidates-hashes-before.txt`, `status-before.txt`, `full-dirty-diff-before.patch`, `head.txt` |
| `patches/` | `batch2-owned.patch`, `batch2-tests-first.patch`, `batch2-fix-only.patch` |
| `logs/` | Build logs, before and after (`build-*-final.log` are authoritative), plus the first-pass `before-fix-new-tests.log` |
| `xctest/` | The runner (`run.zsh`, `makeconfig*`) and every run log with its `.meta` and `.xctestconfiguration`. Authoritative logs are `before-fix-final.log`, `after-new-tests-final.log`, `after-focused-final.log`, `after-full-unit-final.log`, and `after-stability-{1,2,3}.log`. The rest are superseded or diagnostic runs, kept for completeness: `before-new-tests*.log`, `before-final.log`, `dbg-toolbar.log`, `exp1-4.log`, the first-pass `after-*.log` without `-final`, and `mutant-*.log` |
| `mutants/` | `mutants.py`, `run.zsh`, `summary*.txt`, and per-mutant `.patch`, `.apply.txt`, `.build.log`, `.test.log` |
| `status-after.txt`, `before-errors.txt`, `full-classes.txt`, `b1-tests.txt`, `b2-tests.txt` | Post-fix status (taken after this report was written), the 34 before-fix error lines, the full-suite class list, and the Batch 1 vs Batch 2 ran-test lists |
| `MANIFEST.sha256` | SHA-256 of every file in the snapshot |

Editing stopped once the snapshot was frozen.

## 9. Verdict

**Verified:**

- All five findings have tests that failed on the unfixed code in a real private-copy run and pass after the fix.
- Mutants show each mechanism is exercised independently.
- Focused suites: 205/205. Full Local suite: 820 tests, 4 skipped, 0 failures.
- Clean builds with no Swift warnings.
- Clean `git diff --check`.
- Hash-verified preservation of inherited dirty work.

**Not verified:** native UAT in an isolated preview. It was excluded by the no-app-launch constraint; see §6, item 9.

IMPLEMENTATION_READY
