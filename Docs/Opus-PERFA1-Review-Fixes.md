# Opus — PERF-A1 review follow-ups

Date: 2026-09-14
Checkout: `/Users/taha/Developer/attic-task-panels-v2`
Branch/HEAD: `codex/attic-task-panels-v2` / `ae6418c1af690e29d15a20344cdb9765a23d3f85` (dirty shared checkout, nothing committed)
Inputs: `Docs/Opus-Implementation-Report.md`, `Docs/Sol-Canvas-PERFA1-Review.md` (CHANGES_REQUIRED: two P1 findings, one P2)
Status: **REVIEW_READY** for Sol Medium re-review. This is automated proof only; native QA was not performed and is not claimed.

## Outcome

| Sol finding | Fix | Evidence |
| --- | --- | --- |
| P1: replica fetch counter active in shipped hot paths | `CanvasReplicaFetchCounter` and both helper call sites compiled only under `DEBUG`. Without `DEBUG`, the helpers are plain `fetch` / `fetchCount` calls. The counter-based gate skips visibly when `DEBUG` is off. | Release app and a non-`DEBUG` test build both succeed. `nm` finds 0 counter symbols in them (24 in the `DEBUG` host dylib). The non-`DEBUG` gate reports skipped. |
| P1: `TaskImageTests:334` asserted the wrong `NSItemProvider` contract | `suggestedName` is now expected to be `"Picture"`. The delivered copy's `url.lastPathComponent` must be `"Picture.png"`. Drag implementation not touched. | Test passes in `DEBUG` and non-`DEBUG` builds. The full suite is now 0 failures (previously 1). |
| P2: pending-context predicate premise only in a deleted probe | New durable test `CanvasStoreTests.testCanvasScopedReplicaReadsSeeUnsavedChangesInTheContext` | Passes; asserts pending and post-save results, and that the changes were really unsaved. |

## Changes

### 1. `Attic/Services/CanvasStore.swift` (+14 / −1)
- The `enum CanvasReplicaFetchCounter` declaration is wrapped in `#if DEBUG … #endif`, and its doc comment says it is test-only.
- `ModelContext.fetchCanvasReplicas`: `#if DEBUG` fetches, notes the rows and returns; `#else` is `return try fetch(descriptor)`.
- `ModelContext.countCanvasReplicas`: the same pattern with `fetchCount`.
- Nothing else changed. Predicates, call sites, `CanvasStorePersistence.swift`, `CanvasStoreImages.swift` and `CanvasStoreSemanticObjects.swift` are byte-identical to the snapshot.
- Why `DEBUG`: the project-level `Debug` and `Local` configurations set `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`, and `Release` does not (checked with `xcodebuild -showBuildSettings`). Unit tests build only in `Local`/`Debug` (`@testable import` needs `ENABLE_TESTABILITY`, which Release sets to `NO`), so every existing test configuration keeps the counter.
- No `@MainActor` annotation was added. The helpers are called from the nonisolated `CanvasStoredReplicas.load`, so isolating the counter would be a larger change. The counter is no longer in shipped builds, so its lack of isolation now affects only tests.
- `CanvasImagePayloadAccessCounter` (older, a separate pattern) was left untouched, as Sol's finding allowed.

### 2. `AtticTests/CanvasPerformanceGateTests.swift` (+6 / −0)
- `testStrokeMutationsReadOnlyTheSelectedCanvasReplicas` is wrapped in `#if DEBUG`.
- `#else` keeps the same test name and throws `XCTSkip("CanvasReplicaFetchCounter is compiled only in DEBUG builds.")`, so a non-`DEBUG` test build compiles and reports the gate as skipped instead of silently dropping it.
- No assertion in the `DEBUG` body changed.

### 3. `AtticTests/TaskImageTests.swift` (+4 / −1)
- `XCTAssertEqual(imageProvider.suggestedName, "Picture.png")` becomes `"Picture"`, with a two-line comment explaining why.
- Inside the existing `loadFileRepresentation` completion, after the "receivers get a copy" assertion, it adds `XCTAssertEqual(url.lastPathComponent, "Picture.png", "not \"Picture\" or \"Picture.png.png\"")`.
- Every other assertion is unchanged: registered types, conformance, copy ≠ private URL, identical bytes, and `XCTAssertNil(error)` / `XCTAssertNotNil(url)`.
- `Attic/Models/TaskDragPayload.swift` is byte-identical to the snapshot.
- The basename assertion is not vacuous. `XCTAssertNotNil(url)` passed in the same closure, so the equality check ran against a real delivered URL whose basename was `Picture.png`. That rules out both `Picture.png.png` and an extensionless copy.

### 4. `AtticTests/CanvasStoreTests.swift` (+84 / −0)
New test `testCanvasScopedReplicaReadsSeeUnsavedChangesInTheContext`.

Setup:
- In-memory container with boards A and B and no physical default board row, so loading another canvas takes the `fetchCount` legacy-default path.
- Saved strokes:
  - `legacy`, live on the default canvas
  - `moving` and `staying`, on A
  - `existing`, on B
- A real `CanvasStore` selects B. The test uses `store.context`, the context `save()` resolves from.
- Before any changes, `load(from:contentCanvasID: B).hasUnboardedLegacyDefaultContent == true`.

Pending changes, left unsaved (`context.hasChanges` asserted):
- insert `inserted` on B (unsaved insert)
- move `moving` from A to B (a `canvasID` move into B's predicate and out of A's)
- tombstone `legacy`

Assertions, first on the pending context and then after `save()` on a fresh context:
- `CanvasStoredReplicas.load(from:contentCanvasID: B).strokes` is exactly `{existing, inserted, moving}` (canvas `fetch`).
- `hasUnboardedLegacyDefaultContent` is now `false` (production `fetchCount` path with `!tombstoned`).
- `load(… A).strokes` is exactly `[staying]` (the move out of A is seen).
- `fetch` with `canvasID == B && idList.contains($0.id)` over `[inserted, moving, staying]` returns exactly `{inserted, moving}`.
- `fetchCount` and `fetch` of `canvasID == default && !tombstoned` both return 0.
- On the pending context only: production `store.storedStrokeReplicas(matching: [inserted, moving, staying]).keys == {inserted, moving}`. This is the same `idList.contains` descriptor the mutation lookups use.

Discrimination check, inside the test:
- A separate `ModelContext(container)` still sees B = `[existing]` and `hasUnboardedLegacyDefaultContent == true` before the save.
- So the pending assertions can pass only if the predicated reads see unsaved changes. The same assertions against saved state would fail.

This covers every form in Sol's P2 finding: unsaved insert, `canvasID` moves into and out of predicates, tombstone, and `fetch` / `idList.contains` / `fetchCount` before save. It uses the production helpers where they are reachable. Images and semantic objects use the same predicate forms and are loaded by `load()`, but they have no dedicated pending rows here.

## Commands and results

All builds used private DerivedData/SYMROOT paths under `/tmp` and `CODE_SIGNING_ALLOWED=NO`. Tests ran through `/tmp/attic-offline-xctest/run.zsh`, which injects XCTest into `AtticUnitTestHost`:
- bundle identifier `com.taha.Attic.UnitTestHost`
- `setActivationPolicy(.prohibited)`, so no windows and no focus
- stores are in-memory or temporary directories

Nothing was installed or launched besides that windowless host. The running `AtticChromeCheckpoint` preview (PID 14206) was not touched and was still running afterwards.

1. **`DEBUG` (Local) test build**
   ```
   xcodebuild build-for-testing -project Attic.xcodeproj -scheme Attic -configuration Local \
     -derivedDataPath /tmp/attic-perfa1-fixes-dd -only-testing:AtticTests CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO
   ```
   `** TEST BUILD SUCCEEDED **`, exit 0. Log: `/tmp/attic-perfa1-fixes-build.log`.

2. **Focused tests (`DEBUG`)**: `run.zsh perfa1-fixes-focused 300` with the new pending test, the PERF-A1 perf gate, the four existing PERF-A1 `CanvasStoreTests`, and the `TaskImageTests` drag test.
   - Result: **7 executed, 0 failures.**
   - Log: `/tmp/attic-offline-xctest/perfa1-fixes-focused.log`

3. **Non-`DEBUG` test build**: same as (1) plus `'SWIFT_ACTIVE_COMPILATION_CONDITIONS='`, into `/tmp/attic-perfa1-fixes-nodebug-dd`.
   - Result: `** TEST BUILD SUCCEEDED **`, exit 0.
   - Log: `/tmp/attic-perfa1-fixes-nodebug-build.log`
   - The `-DDEBUG=1` in that log is the C preprocessor define, not a Swift condition. The symbol check below confirms the Swift `#else` paths were compiled.

4. **Focused tests (non-`DEBUG`)**: `run.zsh perfa1-fixes-nodebug-focused 300` with the pending test, the perf gate and the drag test.
   - Result: **3 executed, 1 skipped (perf gate, as designed), 0 failures.**
   - Log: `/tmp/attic-offline-xctest/perfa1-fixes-nodebug-focused.log`

5. **Release app compile**
   ```
   xcodebuild build -project Attic.xcodeproj -target Attic -configuration Release \
     SYMROOT=/tmp/attic-perfa1-fixes-release-sym OBJROOT=/tmp/attic-perfa1-fixes-release-obj CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO
   ```
   - Result: `** BUILD SUCCEEDED **`, exit 0.
   - Log: `/tmp/attic-perfa1-fixes-release-build.log`
   - Release settings: no `DEBUG`, `ENABLE_TESTABILITY = NO`, `OTHER_SWIFT_FLAGS = -DATTIC_LOCAL_ONLY`.
   - This is a compile-only check: nothing was signed, installed, launched or released.

6. **Instrumentation symbol check** (`nm … | grep -c CanvasReplicaFetchCounter`)

   | Binary | Counter symbols |
   | --- | --- |
   | Release `Attic.app/Contents/MacOS/Attic` | **0** |
   | non-`DEBUG` `AtticUnitTestHost` | **0** |
   | non-`DEBUG` `AtticUnitTestHost.debug.dylib` | **0** |
   | non-`DEBUG` `AtticTests` | **0** |
   | `DEBUG` `AtticUnitTestHost.debug.dylib` | 24 (control) |

7. **Integration gate: full unit suite (`DEBUG`)**
   - Command: `run.zsh perfa1-fixes-full-unit 900` over all 42 `XCTestCase` classes in `AtticTests`. The list was regenerated from source and is identical to the list in `perf-a1-full-unit.log`.
   - Result: **799 executed, 4 skipped, 0 failures, exit 0.**
   - Log: `/tmp/attic-offline-xctest/perfa1-fixes-full-unit.log`
   - The previous run was 798 tests with 1 failure. The only added test is the pending-context test, and the former failure now passes.
   - The 4 skips are identical to the previous run:
     - `AgentServerIntegrationTests.testOfficialMCPClientInteroperability`
     - two `PanelGeometryTests` swipe tests
     - `TaskStoreTests.testSuccessfulCloudImportRefreshesChangesSavedOutsideStoreContext`
   - Host `sha256 2287db132ef1900a23f1352289411bd47c6c755e9e2bbc7bfb59af32b7a39e2d`
   - Host debug dylib `6dd8b4175ae016665fcc2cca2108b16c94379f186319a5bf1f02deb3d767d156`
   - Test bundle binary `ef2d7db5699ad331c90861aeb548d9ed095d8bbcbc656e9943d4402473aaa7af`
   - Provenance: the owned sources were last modified 14:19:31–14:20:57, the test bundle was built at 14:21:56, and `find Attic AtticTests AtticUnitTestHost -newer <build log>` found no later source edits.

8. **Whitespace**: `git diff --check` for the two tracked files and `--no-index --check` for the two untracked test files are clean.

## Owned diff and hashes

Snapshot taken before any edit: `/tmp/attic-perfa1-fixes-snapshot-141831` (`SHA256SUMS`). The "before" hashes of the four Canvas files equal Opus's reported "after" hashes, so the starting point was exactly the reviewed PERF-A1 state.

| File | Before | After | +/− |
| --- | --- | --- | --- |
| `Attic/Services/CanvasStore.swift` | `f2fe7e6c3ac5b1079a0f8db2890fb3e089af92c54fae87ccc977cb16f3558a76` | `c6a23302377b96d519541d0f3830f25e72facf541e34da0ca4942cfe4b162b44` | 14/1 |
| `AtticTests/CanvasStoreTests.swift` | `fc11afe175cbf877db393fff92bdd9857ecd4987248abb6adbd7516e2c2de35a` | `30690cba35b878816c66d124fb6f66a5f9a8154a7c01b6e293f028b29664de72` | 84/0 |
| `AtticTests/CanvasPerformanceGateTests.swift` | `84ebbc443bd1efee5def134b524c51fb4b82eb4a1cb1805313b5dc7bf156f75c` | `798d2703af7563603227ca3ca4f960094d76a9fb81a11dcca63b830da35d8c53` | 6/0 |
| `AtticTests/TaskImageTests.swift` | `ebc4e8074e12b2e3c8be2c3b582aa249c17ef54d6b557a8dce024f9fd6f67591` | `83f3dd21b7587ca88c84fe7861fca21a92c23a9a3faf1c2bda20a3131ae7f611` | 4/1 |
| `Docs/Opus-PERFA1-Review-Fixes.md` | absent | this file | — |

These snapshotted files were verified unchanged with `cmp`:
- `CanvasStorePersistence.swift` (`ad3301ec…`)
- `CanvasStoreImages.swift` (`6f893775…`)
- `CanvasStoreSemanticObjects.swift` (`4e44df67…`)
- `TaskDragPayload.swift` (`e4753a36…`)

Diffs: `git diff --no-index /tmp/attic-perfa1-fixes-snapshot-141831/<file> <file>`. Each shows only the hunks described above, and other writers' edits in these files are preserved.

Not changed: project inputs or `Attic.xcodeproj` (no regeneration needed), models/schema, drag implementation, Notes and no-swipe code, and all other files.

## Limits

- **The non-`DEBUG` perf gate is a skip, not a guard.** Release builds have no row-count instrumentation by design, so the PERF-A1 row guard runs only in `DEBUG`/`Local` test runs, which is every current test configuration.
- **The pending-context test covers strokes only.** Images and semantic objects share the predicate forms and are loaded through `load()`, but have no dedicated pending rows. `storedImageReplicas`' `idList.contains` path is covered by symmetry, not by a test. The test also shows SwiftData behaviour on this SDK/OS only; it guards against future changes but is not a universal guarantee.
- **The Release check was compile and symbol inspection only.** There was no Release test run, since tests cannot build there without testability. There was no signing, installed-app inspection, Instruments, or runtime timing of the Release fetch path.
- **Not performed:** native UI or preview verification, pointer or UI access, and relaunching anything. The running `AtticChromeCheckpoint` preview was not touched (a separate Luna screenshot task is using it). There was no CloudKit or iPhone validation, no commit, push or release, and no user data was accessed or reset.
- **Native QA is still pending and is not claimed here**; the Sol Low checklist from `Docs/Opus-Implementation-Report.md` still applies.

REVIEW_READY
