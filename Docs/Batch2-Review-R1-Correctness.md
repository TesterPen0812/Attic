# Batch 2 Review — R1: Correctness and Regression Safety

**Verdict: `REVIEW_PASS`**

Reviewer reconstruction: `/tmp/attic-b2-review-r1` (private; `git archive ae6418c1af690e29d15a20344cdb9765a23d3f85` + snapshot `worktree/` overlay). Live checkout untouched; snapshot untouched. Private DerivedData: `/tmp/attic-b2-r1-dd`, `/tmp/attic-b2-r1-unfixed-dd`. No commits, pushes, app launch, or native UI automation.

Snapshot manifest `MANIFEST.sha256` file hash verified: `9af3fc17a070842e7ce8a4975cd66efa7b4ce5a3b297b79bfd5371a5380ca339` — all 598 entries verified independently, 0 missing, 0 mismatched.

---

## 1. Per-fix verdicts

### CVD-03 — retry requeues every failed image — PASS

`CanvasImageDecodeRetryRequest.imageIDs: Set<UUID>` with a per-request `attemptID = UUID()` (`Attic/Canvas/CanvasImageTypes.swift:3-6`). `retryFailedImageDecodes()` intersects `failedImageIDs` with current `images` (`Attic/Canvas/CanvasSession.swift:383-388`), so a stale banner cannot request deleted or foreign IDs. `updateNSView` iterates `view.images` — the full placed-image list, not the candidate set — and calls `retryDecode(for:)` per match (`Attic/Canvas/CanvasSurfaceMac.swift:151-157`). `attemptID` is part of `Equatable`, so a repeated identical ID set still differs from `view.lastDecodeRetryRequest` and is re-delivered. Re-delivery onto a freshly created view is safe: unconsumed-failed lookups no-op via `failed.remove(key) != nil` (`CanvasSurfaceRenderer.swift:176`). Shared-`contentToken` duplicates collapse to one decode — the second `retryDecode` is a no-op; correct and non-duplicating.

### CVD-04 — retry outside the decode candidate set — PASS

`retryKeys` (`Attic/Canvas/CanvasSurfaceRenderer.swift:114`) protects explicit retries end to end: the queued entry survives candidate pruning (`:142`), the active task survives cancellation (`:144`), and `finishDecode` keeps a retried result through the `retried` disjunct (`:282,291-292`) whether it ends ready or failed. `removeAll()` clears `retryKeys` (`:191`) and is called on canvas switch (`CanvasSurfaceMac.swift:445`), so retries cannot leak across pages. `retryKeys` cannot strand: a queued retry is only consumed by `dequeueNext` (which always produces a task whose `finishDecode` removes the key at `:282`), by the `retryKeys`-protected prune, or by `removeAll`. The invariants that make `queued[key] != nil` at `:179` effectively guaranteed were verified: `failed`, `queued`, `active`, and `cached` states for a key are mutually exclusive through the cache's own transitions.

Candidate policy is `CanvasImageDecodeCandidatePolicy` (`CanvasSurfaceMacHelpers.swift:6-42`): visible rect plus a 192-view-point prefetch margin; `prepare` runs on every configure (`CanvasSurfaceMac.swift:524-530`), which is exactly why the protection is needed. Failure reporting republishes only via `onImageReady` → `onDecodeFailuresChanged` → `setFailedImageIDs` (`CanvasSurfaceMac.swift:105-107,332-338`), which re-intersects with current images (`CanvasSession.swift:369-372`); image-set changes re-intersect too (`CanvasSession.swift:1693-1694`).

### CVD-06 — toolbar and Add ▸ Edit Undo/Redo route through `CanvasEditCommandRoute` — PASS

All UI call sites route through the route: toolbar `CanvasPanelContent.swift:367-372`, Add ▸ Edit menu `:478-485`, app Edit commands `AtticApp.swift:59-77`. No remaining direct `session.undo()/redo()` from UI code. `CanvasEditCommandRoute` (`Attic/App/CanvasEditCommandRoute.swift`) predates Batch 2 at HEAD (baseline file is byte-identical to `ae6418c1`); the batch's only change to it is the `focusedResponder` seam for tests (`:11`), which defaults to the previous `NSApp.keyWindow?.firstResponder` expression. The route was already live for the app menu — the fix extends a proven path rather than inventing one. Routing semantics are correct: a focused `NSTextView` gets its own `undoManager` and the route deliberately does not fall through to `session.undo()` when the editor cannot undo — matching native Undo targeting; the button is disabled in that state anyway via `canUndo`.

### CVD-08 — committed text resize refits height — PASS

Every box-changing path converges on `transformSemanticObject` (`Attic/Canvas/CanvasSession.swift:1288-1307`): pointer commit (`finishImageInteraction` → `onTransformSemanticObject`, `CanvasSurfaceMacHelpers.swift:1081`, `CanvasSurfaceMac.swift:113-115`), keyboard (`resizeSelectedSemanticObject`, `CanvasSession.swift:1353-1358`), nudge (`:1346`) and layer change (`:1387`). The refit trigger `:1293-1294` requires a width or height change, so move-only and zIndex-only commits correctly skip it; a pure move does not regrow. The refit measures with the same framesetter the renderer draws with (`CanvasSemanticRenderer.swift:46-63` vs `:101-106`): identical font/paragraph attributes, identical −8 width inset, and `+12` vs `+8` height padding leaves 4 pt of slack — conservative, never under-measures given the 48-unit floor keeps `max(24, width − 8)` at parity with the draw width. `center.y += (height − proposedHeight)/2` anchors the top edge. `editSemanticObject` refits independently for content edits (`:1324-1327`). Undo/redo restore bypasses `transformSemanticObject` entirely (`restoreSemanticObject` → `store.restoreBoardContents`, `:1281-1285`), so historical snapshots restore verbatim — verified against `storedSemanticReplicas`/`stageSemanticRestore` in `Attic/Services/CanvasStoreSemanticObjects.swift`.

### CVX-06 — keyboard resize uses the pointer minimum — PASS

`resizeSelectedSemanticObject` floors both axes at `CanvasImagePlacement.minimumDimension` = 48 (`CanvasSession.swift:1356-1357`; `CanvasImageTypes.swift:439`), identical to the pointer floor (`resizedTransform`, `CanvasImageTypes.swift:567-568`) and the image keyboard floor (`CanvasSession.swift:1010-1011`). At the floor the composed transform equals `before` → returns false (true no-op), confirmed by the test.

## 2. Regression-safety review (callers, invariants, adjacent behavior)

- **Canvas recovery / page lifecycle:** `failedImageIDs` re-intersects on every publish and on image-set change; `imageCache.removeAll()` on `canvasID` change resets `queued/active/failed/retryKeys`. No stale retry or failure state crosses pages.
- **Image import lifecycle:** `importPreparedImage` → `images` → configure → `prepare` → decode → `failed` → banner → set-based retry. Verified the banner path cannot request non-present IDs.
- **Undo history:** refit happens before `recordNewCommand(.changeSemantic(before:after:))` (`CanvasSession.swift:1305`), so one user gesture = one history entry with the final committed transform; undo restores `before` exactly, including any pre-refit clipping state — correct semantics.
- **Edit routing:** `finishTextEditing()` gates tool/color/shape actions (`CanvasPanelContent.swift:427,441,521,532,543,556,599`) with the failed-save veto, unchanged by this batch.
- **Scope check:** baseline↔final diffs are confined to the owned files. Production deltas: `CanvasImageTypes` (2 changed lines), `CanvasSurfaceMac` (2), `CanvasSurfaceRenderer` (14), `CanvasSession` (28), `CanvasPanelContent` (24), `CanvasEditCommandRoute` (test seam only). `Docs/Native-Verification-Playbook.md` is present but owned by another actor per the implementation record.

## 3. New-test quality

The seven new tests are causally discriminating:

- `testRetryFailedImageDecodesRequeuesEveryVisibleFailure` / `...RequeuesOffScreenFailure` (`AtticTests/CanvasDomainTests.swift:1067,1101`): real `CanvasNSView` + real `CanvasImageDecodeCache`, real corrupt-image decode failures; include a no-failure negative control (`:1094-1097`).
- `testRetryDecodeRequeuesOffScreenFailureAcrossCandidatePruning` (`AtticTests/CanvasRenderCacheTests.swift:375`): blocking decode probe, both `cancelsActiveDecodesWhenRemoved` modes, explicit pruning-survival and active-decode assertions.
- `testToolbarAndMenuUndoRedoFollowFocusedTextEditor` (`CanvasDomainTests.swift:1139`): synthesized mouse clicks on the real toolbar buttons and real `NSPopUpButtonCell.performActionForItem` on a real (off-screen, non-key) window; `focusedResponder` restored via `defer`.
- `testNarrowingTextResizeGrowsHeightSoPersistedTextIsNotClipped` (`AtticTests/CanvasSessionTests.swift:288`) and `testPointerNarrowingTextResizeGrowsHeightToFitCommittedText` (`CanvasDomainTests.swift:1266`): assert persisted transform, top-edge anchor (`minY` equality), and actual CoreText visibility via `CTFrameGetVisibleStringRange` — stronger than height checks; the pointer test drives real `mouseDown/Dragged/Up` through the handle.
- `testKeyboardSemanticResizeSharesPointerMinimumDimension` (`CanvasSessionTests.swift:322`): asserts keyboard floor **equals** the pointer floor computed via `resizedTransform`, not a literal 48, plus at-floor no-op and text-visibility.

No false-positive patterns found (no tautological asserts, no unconditional `sleep`-then-assert; waits are condition-bounded `waitUntil`/`waitForCanvasCondition`).

## 4. Negative controls and mutants (independent runs)

- **Negative control** (all owned production fixes reverted in `/tmp/attic-b2-r1-unfixed`, tests kept): `Executed 7 tests, with 34 failures`, `exit_status=1` — matches the recorded `before-fix-final.log` (34 failures) and `before-errors.txt` line-for-line.
- **R1-mutant A** (`transformSemanticObject`: dropped `center.y` re-anchor, refit still grows): expected failures at top-edge assertions → observed **4 failures** (session `minY` at line 295, pointer `minY` at 1302, plus the downstream squash-control pair 316-317 whose reference frame shifts). Tests pin anchoring.
- **R1-mutant B** (`transformSemanticObject`: dropped `|| transform.height != before.transform.height`): expected height-only squash to persist clipped → observed **3 failures** at lines 316-318; `testPointerNarrowing` still passed (width trigger intact) — good isolation.
- **R1-mutant C** (`retryDecode`: dropped `retryKeys.insert`): expected queued off-screen retry to be pruned → observed **10 failures** (5 per cancellation mode) in the cache test; the session-level off-screen test **passed** because the retried decode starts immediately on a free worker and `cancelsActiveDecodesWhenRemoved=false` keeps the result — the implementation record predicted exactly this invisibility (§5 note on M2b/M2c), independently confirmed here.

## 5. Confirmed defects

None.

## 6. Suspicions (reasoned, not reproduced at runtime)

**S1 — stale failure banner after a pruned in-candidate retry (low, cosmetic).** `retryDecode` inserts into `retryKeys` only when the image is *already* outside `visibleKeys` (`CanvasSurfaceRenderer.swift:179`). If an in-candidate failed image is retried while all three decode workers are busy, then panned out of the candidate set before its queued entry dequeues, `prepare`'s filter (`:142`) prunes it with the failure already cleared. Consequences: the image becomes `.idle` and decodes normally on re-entry (harmless), but `session.failedImageIDs` keeps the id because nothing republishes until a decode finishes — the banner can show a stale failure on which "Retry" then no-ops (`failed.remove` returns nil). Window is narrow (needs saturated workers + immediate pan-out); self-heals on re-entry or removal. Suggested fix: insert into `retryKeys` whenever the retry was queued (`queued[key] != nil`), regardless of current visibility — an explicit user retry then always completes once.

**S2 — iOS surface never consumes retry requests (informational).** `CanvasSurfaceIOS.swift` has no `lastDecodeRetryRequest`/`retryDecode` wiring and prepares all images without a candidate policy. On iOS `retryFailedImageDecodes()` would publish a request nothing consumes. iOS is deferred product scope; recorded so the gap is not lost when iOS work resumes.

## 7. Optional improvements

- `canUndoCanvasEdit`/`canRedoCanvasEdit` (`CanvasPanelContent.swift:30-35`): the `session.canUndo ||` disjunct is redundant — the route already returns `session.canUndo` when no editor is focused. Harmless; may be intentional self-documentation.
- `CanvasImageDecodeCache.prepare` calls `rebuildQueueOrder(prioritizing:)` twice (`CanvasSurfaceRenderer.swift:149,153`); the post-enqueue call subsumes the first. Cosmetic.
- `queued[key] != nil` at `CanvasSurfaceRenderer.swift:179` is unreachable-false under current invariants (after a successful `failed.remove`, `enqueueIfNeeded` always queues — `cached`/`active`/`queued` cannot co-exist with `failed`). Harmless defensive check; could be an assertion comment instead.

## 8. Documentation accuracy

`Docs/DeepAudit-Batch2-Implementation.md` re-measured claims, all confirmed:

| Claim | Recorded | Independently observed |
|---|---|---|
| New tests on unfixed tree | 7 tests, 34 failures | 7 tests, **34 failures** (line-for-line match) |
| New tests on fixed tree | 7/0 | **7/0** |
| Focused Canvas (17 classes) | 205/0 | **205/0** |
| Full Local unit (42 classes) | 820 tests, 4 skipped, 0 failures | **820/4/0** (816 passed, 4 skipped) |
| Post-fix source hashes | 9 files | **9/9 match** my reconstruction |
| Mutant invisibility note (M2b/M2c not visible to view test) | explained | reproduced exactly under mutant C |

The recorded M-series mutant counts (M1=3, M2a=14, M2b=10, M2c=1, M3=5, M4=9, M5=5) were not re-run individually; instead three independent mutants (A/B/C above) covering distinct mechanisms were built and run, all discriminating.

## 9. Commands run (all inside `/tmp/attic-b2-review-r1` unless noted)

```text
# Snapshot verification
shasum -a 256 /tmp/attic-b2-snapshot-20260915T1845Z/MANIFEST.sha256
cd /tmp/attic-b2-snapshot-20260915T1845Z && shasum -a 256 -c MANIFEST.sha256   # 598/598 OK

# Reconstruction
git -C /Users/taha/Developer/attic-task-panels-v2 archive ae6418c1af690e29d15a20344cdb9765a23d3f85 | tar -x -C /tmp/attic-b2-review-r1
cp -R /tmp/attic-b2-snapshot-20260915T1845Z/worktree/. /tmp/attic-b2-review-r1/

# Build (fixed tree)
xcodebuild build-for-testing -project Attic.xcodeproj -scheme Attic -configuration Local \
  -derivedDataPath /tmp/attic-b2-r1-dd -only-testing:AtticTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO            # TEST BUILD SUCCEEDED

# Test runs (offline XCTest runner from snapshot; logs in /tmp/attic-b2-r1-xctest/)
ATTIC_TEST_PRODUCTS=/tmp/attic-b2-r1-dd/Build/Products/Local ./run.zsh r1-new-tests 300 <7 new tests>
    → Executed 7 tests, 0 failures, exit 0
ATTIC_TEST_PRODUCTS=/tmp/attic-b2-r1-dd/Build/Products/Local ./run.zsh r1-focused 600 <17 Canvas classes>
    → Executed 205 tests, 0 failures, exit 0  (15.9s test time)
ATTIC_TEST_PRODUCTS=/tmp/attic-b2-r1-dd/Build/Products/Local ./run.zsh r1-full 1500 <42 classes>
    → Executed 820 tests, 4 skipped, 0 failures, exit 0  (37.7s test time)

# Negative control: /tmp/attic-b2-r1-unfixed (6 owned production files reverted to baseline/)
xcodebuild build-for-testing ... -derivedDataPath /tmp/attic-b2-r1-unfixed-dd   # SUCCEEDED
./run.zsh r1-neg-control 300 <7 new tests>
    → Executed 7 tests, 34 failures, exit 1

# Mutants (built against /tmp/attic-b2-r1-dd, tree restored afterward)
mutant A → 3 tests, 4 failures, exit 1   (r1-mutA.log)
mutant B → 2 tests, 3 failures, exit 1   (r1-mutB.log)
mutant C → cache test 10 failures, exit 1 (r1-mutC.log); session off-screen test passed as predicted (r1-mutC2.log)
```

## 10. Source hashes reviewed (post-fix tree)

```text
40d1ff26…0ce954  Attic/Canvas/CanvasImageTypes.swift
c268412d…040a6e  Attic/Canvas/CanvasSession.swift
67477ef5…04c09e  Attic/Canvas/CanvasSurfaceMac.swift
48c81ecf…08f87a  Attic/Canvas/CanvasSurfaceRenderer.swift
169ead83…26336b  Attic/Views/Panel/CanvasPanelContent.swift
46676081…5b2bf   Attic/App/CanvasEditCommandRoute.swift
dac3e3aa…5b9f79  AtticTests/CanvasRenderCacheTests.swift
f5f8cdd3…eba2b0  AtticTests/CanvasSessionTests.swift
2777a07d…18562b  AtticTests/CanvasDomainTests.swift
```

## 11. Unverified limits

- No app launch, no native UI automation, no physical-input UAT — native verification remains a separate gate (`Docs/Native-Verification-Playbook.md`).
- iOS path not exercised (deferred platform; see S2).
- CloudKit, APNs, iPhone, Production schema/signing not exercised (out of scope per the Development Contract).
- Mutant coverage is mechanism-targeted, not exhaustive; multi-hour interaction soak not performed.
- S1 is reasoned from code paths, not observed at runtime.

**Elapsed:** ≈45 min wall clock (manifest verification, reconstruction, source review, 5 builds, 6 test runs, 3 mutants, report). Tool budget well within the 120-step cap.
