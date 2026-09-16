# Batch 1 Remediation — Independent SWE-2 Max Review

**Reviewer:** SWE-2 Max (independent; no other reviewers' findings or transcripts read)
**Verdict: REVIEW_PASS**

No confirmed defects. The remediation is correct on every path traced, the new
tests are causally connected to the fixes (verified by independent mutants, not
just the worker's logs), scope discipline holds, and the Development Contract is
honored. Minor items below are doc nits and optional coverage, not blockers.

---

## 1. Frozen inputs and provenance

| Item | Value |
|---|---|
| Snapshot | `/tmp/attic-b1rem-snapshot-20260915T130827Z` |
| `MANIFEST.sha256` file hash | `5d8ab5ef855d4e2f876da67db55417342698458ecc4f6c3d84d68777fd695e6f` — **matches** expected |
| Manifest verification | `sha256sum -c MANIFEST.sha256` → exit 0, every entry `OK` |
| Git base | `ae6418c1af690e29d15a20344cdb9765a23d3f85` |
| Private reconstruction | `/tmp/attic-b1rem-review-swe` (git archive + `worktree/` overlay; contents merged, no nested `worktree` dir) |
| Private DerivedData | `/tmp/attic-b1rem-review-swe-dd` (test products); `/tmp/attic-b1rem-dd` (earlier build) |
| Private test harness | `/tmp/attic-b1rem-review-swe-xctest/` (`run.zsh` + per-run `.xctestconfiguration` + logs) |
| This report | `Docs/Batch1-Remediation-SWE-Review.md` (only artifact written) |

The naked HEAD and the mutable live checkout were never built or tested. All
test evidence below comes from the private reconstruction.

### Reviewed source hashes (SHA-256, post-restore, all match manifest entries)

```
16db44a24b788f5d1c6ee4d6453d14da2f3c607464c4e900380662bb8aec933c  Attic/Services/CanvasStoreBoards.swift
16592495d2d83eb89d28646ed9954cd8da8cb22fdac75a60c97837231504dd06  Attic/Services/CanvasStorePersistence.swift
47a3115e41f7391b09e5f344f71ef00251cdc029742dc52c72b946a108965152  Attic/Canvas/CanvasSurfaceMac.swift
ebec9d9fa5c905ffff71ed58e95f5efa9adf978c98d83f0f8e954a53353fb586  Attic/Canvas/CanvasSession.swift          (caller/invariant)
c6a23302377b96d519541d0f3830f25e72facf541e34da0ca4942cfe4b162b44  Attic/Services/CanvasStore.swift          (caller/invariant)
79cb7d59d45008d0ef0824911e05b9b0daf2eea738a8a4ff0dcc49f090c40945  Attic/Services/CanvasStoreLifecycle.swift (caller/invariant)
8f7fe9484ad96403776640f60fa059b41eafa6ab62ebfcd2e68f5be59839dbbc  Attic/Canvas/CanvasSurfaceMacHelpers.swift (caller/invariant)
120bb04d8d835a89de04f51520c611cdb40c015fb500f92863bd851dc849a15d  AtticTests/CanvasDomainTests.swift
6bd16080a37fd5e55249f2ce97bd2d465ce78caa54accf7fb9ccf4178d7e51cd  AtticTests/CanvasStoreTests.swift
9286a6041264c77cde67c8a69100c0dd31b948ef8aa1546de9dafd4e3d2d9977  AtticTests/CanvasImageTests.swift
d0d7d897d27903cba94c2a9e44c600027b485ca273062f77dc0d4f27e9b32214  AtticTests/TestSupport.swift              (helpers)
281d7177be8d9117425cbe7e50d748285348f95ecb4f8d56283e4effd91093f5  Docs/Batch1-Remediation-Implementation.md
25dc97d5fee7a434b5476ad2eee36926a841a5bf9fe8bd364f623096daa090e5  Docs/DeepAudit-Batch1-Implementation.md
```

---

## 2. Scope verification

Comparing each file's baseline hash to its worktree hash confirms the worker's
footprint is exactly the owned set — nothing else moved relative to the
inherited dirty state:

- Source: `CanvasStoreBoards.swift`, `CanvasStorePersistence.swift`,
  `CanvasSurfaceMac.swift`
- Tests: `CanvasDomainTests.swift`, `CanvasStoreTests.swift`,
  `CanvasImageTests.swift`
- Docs: `Batch1-Remediation-Implementation.md`,
  `DeepAudit-Batch1-Implementation.md` (corrections only)

`AGENTS.md` and `CLAUDE.md` contract blocks are synchronized verbatim.
`-DATTIC_LOCAL_ONLY` is present in the Local configuration used for all builds.
No commits, pushes, launches, or UI automation were performed.

---

## 3. What was reviewed

Owned patches **and** their callers/invariants:

- `CanvasStore.save(restoringSelectionOnFailure:)` and the new
  `rollBackFailedSave(restoringSelection:)` helper, both failure arms
  (preparation and persist).
- `createCanvas`/`deleteCanvas` previous-selection capture and hand-off.
- `CanvasSession.createCanvas` (`boardChanged` = `created != nil ||
  store.selectedCanvasID != previousCanvasID`) and `deleteSelectedCanvas`
  (`succeeded || selectedCanvasID != id`) — the transition-based guards that
  make the externally-lost-board case work.
- `synchronizeFromStore`, `handleStoreRevision`, `cancelActiveInteraction`
  (`interactionCancellationEpoch &+= 1` + image-batch cancellation),
  `selectCanvas`, `discardPendingChanges`, `resolveCanvasPresentation` /
  `reloadCanvas` / `applyCanvasPresentation`, `persist(context)`.
- View side: `scrollWheel`, `handleMagnification`, `cancelInteraction`,
  `interruptTransientInteraction`, `deactivateRepresentation`,
  `resetViewportGestureRouting`, `interruptViewportGestureForPointer`,
  `hasActivePointerInteraction`, and every site that sets/clears
  `suppressesScrollSequence` / `suppressesMagnification` /
  `pendingScrollMomentumMode` / `activeViewportGesture`.
- `CanvasSurfaceIOS.swift` for comparison (different gesture model; deferred).
- All `save()` call sites for signature compatibility (default `nil` argument).
- `CanvasPanelContent` UI callers (thin wrappers over the session).
- New tests + helpers (`PersistenceGate`, `ControlledCanvasImagePreparer`,
  `CanvasReplicaReadGate`, synthetic scroll events, driven
  `NSMagnificationGestureRecognizer`).

Store invariants checked: the only sites that move `selectedCanvasID` ahead of a
`save()` are `createCanvas` and `deleteCanvas`; `selectCanvas` uses `refresh()`
(not `save()`); `ensureSelectedBoardReplicaExists`/`restoreBoardContents` never
move selection. The remediation covers the complete set of pre-save movers.

---

## 4. Requirement-by-requirement verification

| Requirement | Result | Basis |
|---|---|---|
| Failed create preserves original selection | ✅ Verified | Store test asserts selection restored; restore→reload→resolve path traced; fresh-context fetch proves nothing persisted |
| Failed delete preserves original selection | ✅ Verified | Same |
| Exact error messages preserved | ✅ Verified | `saveError · warning` / `Reload failed:` forms unchanged in the diff; tests assert `lastErrorMessage` equals the injected error |
| History/undo state preserved | ✅ Verified | Session teardown keys on actual selection change; tests assert undo stack + `canUndo` unchanged |
| Cancellation epoch preserved | ✅ Verified | `cancelActiveInteraction` not invoked on failed ops; tests assert epoch equality |
| In-flight imports not cancelled | ✅ Verified | Controlled preparer keeps an import in-flight across failed create/delete; asserts completion on original board |
| Externally lost board still clears stale state | ✅ Verified | External-context tombstone test; reload resolves to fallback; session detects real transition and tears down. Mutant-verified (§6) |
| Preparation-failure path | ⚠️ Inspected, untested | Same `rollBackFailedSave` + reload sequence as the tested persist arm; see S-1 |
| Nil-selection edge cases | ✅ Verified | `previousSelection == nil` → helper only rolls back; delete-of-only-nonselected-board path is a no-op restore by inspection |
| Foreign scroll tail suppressed after cancel | ✅ Verified | `cancelInteraction` now ORs pre-existing suppression into `resetViewportGestureRouting`; synthetic scroll + momentum tests pass; terminal events release suppression; next valid gesture works |
| Foreign pinch tail suppressed after cancel | ✅ Verified | Same mechanism via `suppressesMagnification`; driven recognizer test passes |
| Normal scroll/zoom unbroken | ✅ Verified | Tests assert post-boundary gestures still pan/zoom; 107-test focused suite + full suite green |
| Tests causally meaningful | ✅ Verified | Independent mutants reproduce the worker's before-run failure histogram line-for-line |
| No speculative refactor | ✅ Verified | Diff is minimal: one optional parameter, one 6-line helper, one OR-expression, call-site captures |
| Resource/perf impact | ✅ Verified | No new allocations/IO on hot paths; `save()` failure path unchanged cost profile |
| Documentation accuracy | ✅ Verified | Claims about injected-failure vs. native validation are honest; two minor nits (§7) |

---

## 5. Confirmed defects

**None.**

Notably, the core invariant is correctly framed as "did the selected board
actually change," not "did the operation return success" — this is what makes
the externally-lost-board case work without special-casing it.

## 6. Suspicions (bounded, non-blocking)

### S-1 — Preparation-failure arm has no injected-failure test — LOW

- **Location:** `CanvasStorePersistence.swift` `save()` first `catch` (calls
  `rollBackFailedSave` then `reloadCanvas`), ~lines 42–56.
- **Trigger:** `resolveCanvasPresentation` throwing on the pre-persist read
  (e.g., `loadReplicas` failure on the pending context).
- **Expected:** restore previous selection, reload, surface preparation error.
- **Actual:** by inspection, identical helper + reload sequence as the tested
  persist arm; risk is that a future edit could diverge the two arms silently.
- **Evidence:** code-symmetric; the persist arm is covered by
  `testFailedCreateAndDeleteSavesRestorePreviousSelectionAndKeepSaveError` and
  the lost-board test.
- **Suggested fix (optional):** inject a gate that throws on the *first*
  `loadReplicas` call and succeeds on reload — the seam exists (`loadReplicas`
  is an injectable `CanvasStore` init parameter, same pattern as
  `CanvasReplicaReadGate`). The implementation record's claim that "there is no
  preparation-failure seam in the test harness" is slightly inaccurate.
- **Unverified limits:** preparation throw surface is narrow (two
  `loadReplicas` calls; decode failures degrade to warnings).

### S-2 — Transient provisional `selectedCanvasID` publication — LOW / theoretical

- **Location:** `CanvasStoreBoards.createCanvas` / `deleteCanvas` select the new
  board *before* `save()`; on failure the store publishes the provisional value
  then the restored value, synchronously.
- **Expected:** observers never act on the intermediate value.
- **Actual:** no in-repo `$selectedCanvasID` Combine subscribers exist; SwiftUI
  coalesces within the same run-loop tick; session reads are synchronous. A
  future synchronous subscriber would observe both emissions.
- **Suggested fix (optional):** none required now; worth a comment or a future
  "compute-then-publish" shape if synchronous subscribers ever appear.
- **Unverified limits:** none — verified by grep over the reconstruction.

## 7. Optional improvements

1. **Coverage:** store-level test for a *failed delete of a non-selected board*
   (restore is provably a no-op; low value, cheap to add).
2. **Coverage:** `PersistenceGate.saveCount` assertion would catch a
   hypothetical double-persist retry (impossible by inspection today).
3. **Doc nits** in `Batch1-Remediation-Implementation.md`:
   - "no existing test was changed" — `testIncidentalPinchCannotDiscardBufferedInk`
     gained an `XCTAssertEqual(view.interaction.machine.state, .idle)` (a
     *strengthening*; cannot produce a false pass).
   - "no preparation-failure seam in the test harness" — see S-1.
   - `tests-first/` snapshot contains only `CanvasDomainTests.swift`; the other
     two test files' pre-fix copies aren't archived (the before-log still
     evidences their failures, so this is an evidence completeness nit, not a
     correctness gap).
4. **Advisory (deferred scope):** `CanvasSurfaceIOS.cancelInteraction` uses a
   different model (`activeViewportGestureCount`, no suppression flags). No
   action implied for this macOS remediation; noted only so the divergence is
   on record when iOS work resumes.

---

## 8. Independent test evidence

Build command (reconstruction, private DerivedData):

```
xcodebuild -project Attic.xcodeproj -scheme Attic \
  -configuration Local -derivedDataPath /tmp/attic-b1rem-review-swe-dd build
```

Result: **BUILD SUCCEEDED**; only App Intents metadata warnings
("Metadata extraction skipped, no AppIntents.framework dependency found").

Test execution: bounded offline runs inside the real `AtticUnitTestHost` via
`run.zsh` (`libXCTestBundleInject` + generated `.xctestconfiguration`,
`ATTIC_TEST_PRODUCTS=/tmp/attic-b1rem-review-swe-dd/Build/Products/Local`).
A benign `sandbox_extension_issue_file_to_process … (Operation not permitted)`
warning precedes each run; the host executes normally — same warning appears in
the worker's logs.

| Run | Log | Result |
|---|---|---|
| 6 new tests (fixed source) | `swe-new-tests.log` | 6 tests, 0 failures |
| Focused regression (4 affected classes) | `swe-focused.log` | 107 tests, 0 failures |
| **Mutant 1** — reverted all three source fixes | `swe-mutant.log` | 6 tests, **37 failures** |
| **Mutant 2** — narrowed session guards only | `swe-mutant2.log` | 8 tests, **8 failures, all inside `testFailedBoardSaveThatLosesItsBoardStillClearsStaleHistoryAndImports`** |
| Restored + rebuilt | `swe-restored.log` | 6 tests, 0 failures |
| **Full unit suite** | `swe-full-unit.log` | **811 tests, 4 skipped, 0 failures** (27.7s) |

Mutant 2 detail: `boardChanged := created != nil` and `if succeeded` (instead of
`|| selectedCanvasID != id`) — the other 7 tests in the run stayed green;
**only** the lost-board test failed. This proves the session-guard breadth is
load-bearing specifically for the externally-lost-board transition, and that the
test discriminates it.

Cross-check: the per-line failure histogram of my Mutant-1 run is **identical**
to the worker's `logs/xctest/before-new-tests.log` (same files, same line
numbers, same counts), independently confirming (a) reconstruction fidelity and
(b) that the same test bundle (`bundle_binary_sha256` `d05341e0…`) fails on
unfixed source and passes on fixed source — genuine causal tests, not
implementation-mirroring asserts.

Performance output (full suite): `Canvas decode stress: 96 images in 0.073s,
max active 4`; `PERFGATE toggle=8.93 snapshot=34.58 lookup=0.0038` — no
regression signal.

---

## 9. Commands run (exact forms)

```
shasum -a 256 /tmp/attic-b1rem-snapshot-20260915T130827Z/MANIFEST.sha256
cd /tmp/attic-b1rem-snapshot-20260915T130827Z && sha256sum -c MANIFEST.sha256

git -C /Users/taha/Developer/attic-task-panels-v2 archive \
    ae6418c1af690e29d15a20344cdb9765a23d3f85 | tar -x -C /tmp/attic-b1rem-review-swe
# recursive content overlay of snapshot worktree/ onto the reconstruction
# (verified: no nested worktree/ dir; every overlaid file hash-matches manifest)

xcodebuild -project Attic.xcodeproj -scheme Attic -configuration Local \
    -derivedDataPath /tmp/attic-b1rem-review-swe-dd build
xcodebuild … build for AtticUnitTestHost (same config/derivedData)

ATTIC_TEST_PRODUCTS=/tmp/attic-b1rem-review-swe-dd/Build/Products/Local \
    /tmp/attic-b1rem-review-swe-xctest/run.zsh LABEL SECONDS TESTID…

# mutants: reverse-applied owned source patches / narrowed session guards,
# rebuilt, re-ran; then restored from snapshot worktree and hash-verified:
shasum -a 256 <file>   # each restored file == MANIFEST.sha256 entry
```

Known command note: `git diff --check` was attempted inside the reconstruction
(exit 129 — archive trees aren't repos); whitespace was instead verified by
direct file comparison. No whitespace issues found.

---

## 10. Limitations and unverified scope

- **No app launch, no native UI, no physical trackpad input.** Scroll/pinch
  evidence is synthetic CGEvent + a driven `NSMagnificationGestureRecognizer`;
  real momentum-phase ordering and `delaysMagnificationEvents` timing are
  unverified. This review **does not claim a native pass** — live manual UAT on
  a physical trackpad remains outstanding.
- If a system never delivers a gesture's terminal event, suppression persists
  until the next valid boundary — intended design, bounded, but untestable here.
- CloudKit, APNs, iPhone companion, TestFlight, Production signing/schema:
  deferred per the Development Contract; **not validated and not claimed**.
- The reconstruction reproduces the snapshot's dirty state (inherited Batch-1
  work plus this remediation). Review coverage of the owned surface + callers/
  invariants was completed; the wider inherited diff was not re-audited.
- Minor: `git diff --check` inapplicable on an archive tree (noted above).

## 11. Verdict

**REVIEW_PASS**

The remediation correctly implements the required semantics on every traced
path, the tests are causally discriminating (independently mutant-verified),
scope and contract discipline hold, and documentation is accurate modulo the
nits in §7. Items S-1, S-2 and the optional improvements are follow-up
suggestions, not change requirements. Native/physical-gesture validation remains
a separate, explicit gate.

---

*Elapsed: ~32 minutes (snapshot 13:08:27Z → final checks 13:42Z), within the
45-minute budget. ~75 tool steps of the 120-step budget used. Live repo,
snapshot, and other workers' artifacts unmodified; only this report was
written.*
