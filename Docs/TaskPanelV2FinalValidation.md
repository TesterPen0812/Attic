# Task Panel V2 — final validation (unit suite, generation, idle resources)

Validation only. No production or test source was edited, and nothing was committed.

- The real git index was not used. The tree hash came from a temporary index at
  `.build/final-validation/final.index`.
- The app was not relaunched, and no UI, pointer, or keyboard input was sent.
- No store was accessed or reset, and no memory was written.
- No other report, ledger, or `.build` directory was modified.
- This run ran concurrently with the Astra HIGH final review. All evidence is in
  `.build/final-validation/`, with SHA-256 sums in `SHA256SUMS.txt`.

## Source identity

- Worktree: `/Users/taha/Developer/attic-task-panels-v2`
- Branch: `codex/attic-task-panels-v2`
- HEAD: `ae6418c1af690e29d15a20344cdb9765a23d3f85`
- Validated working tree: `618d63189e439406d925f185d0c46b9fc950ac40`
  - Built with `git read-tree HEAD` plus `git add -A` on the temporary index, so nonignored
    untracked files are included.
  - The porcelain status is in `final-status.txt` (87 lines).
- Compared with the Batch 4 fixes tree `a1cd645dfb5591bd137a447ca1375887a55cf615`, the tree
  differs only in documentation. Source is frozen:
  - `Docs/TaskPanelV2Batch4FixSWE-A.md` (new)
  - `Docs/TaskPanelV2Batch4FixSWE-B.md` (new)
  - `Docs/TaskPanelV2IntegrationLive.md` (+35 lines)
  - `Docs/TaskPanelV2Orchestration.md` (+6 lines)
- Environment: Xcode 27.0 (27A5252f), macOS 27.0, Mac16,1 with 10 CPUs.

## Project generation and whitespace

- `/opt/homebrew/opt/ruby/bin/ruby Scripts/verify_project_generation.rb` (Ruby 4.0.4) printed
  "Project generation is repeatable and Attic.xcodeproj is current" (`project-generation.log`).
  - The first attempt used `/usr/bin/ruby` 2.6. It failed with `cannot load such file --
    xcodeproj`, which is an interpreter or gem problem, not a project problem.
  - The ledger's proven interpreter, Homebrew Ruby, was then used.
- `git diff --check` exited 0 (`diff-check.txt`).

## Build reuse

No rebuild was needed. The unit test products under `.build/DerivedData/Build/Products/Local`
are byte-identical to the images that passed the Batch 4 fixes 351/351 gate:

| Image | SHA-256 |
|---|---|
| `AtticUnitTestHost` (stub) | `2287db132ef1900a23f1352289411bd47c6c755e9e2bbc7bfb59af32b7a39e2d` |
| `AtticUnitTestHost.debug.dylib` | `324607c889fc41c1a5860742b2b67605d25018ca9d540299825d1e2f575aeda6` |
| `AtticTests.xctest/Contents/MacOS/AtticTests` | `9f00dfcc17ddfc84663088e343b85866c634e8beec23448b2cb30ed5ecc0ed28` |

Those images came from `build-for-testing-2.log` ("TEST BUILD SUCCEEDED") on the final Batch 4
fixes source. Only documentation changed after that, so the reuse is valid. The mutation builds
used separate `/tmp` DerivedData and did not overwrite these products.

## Full local unit suite — offline in-host XCTest

### Method

This is the proven route from `.build/batch4-fixes/offline-xctest`.

- `run.zsh`, `makeconfig` and `makeconfig.m` were copied into `.build/final-validation/`. Their
  SHA-256 hashes are identical to the originals (`f13edc4a…`, `d3f3a06e…`, `82923098…`).
- The real `AtticUnitTestHost` (bundle ID `com.taha.Attic.UnitTestHost`) was started with
  `libXCTestBundleInject.dylib`.
- It used an offline keyed-archived `XCTestConfiguration` (`full-suite-1.xctestconfiguration`)
  with these settings:
  - `reportResultsToIDE=NO`
  - `testsDrivenByIDE=NO`
  - `testsMustRunOnMainThread=YES`
  - `testTimeoutsEnabled=NO`
  - no IDE session
- `testsToRun` listed all 39 `XCTestCase` classes in `AtticTests/` (`test-classes.txt`).
- The watchdog limit was 1500 s. It did not fire.
- It ran once, with no retry, from 2026-09-13 10:56:12Z to 10:56:50Z. Host PID was 28821 and
  `exit_status=0`.
- No opt-in environment variables were set (`ATTIC_MOTION_VISUAL_TEST`, `ATTIC_MCP_NODE`,
  `ATTIC_MCP_SDK_ROOT`). No assertion was changed or skipped by this run.

**This is not an `xcodebuild test` result or `.xcresult`.** It is real XCTest inside the real
host with the final test images. `xcodebuild`'s testmanagerd handshake is bypassed, as described
in the ledger.

### Result

**761 executed, 758 passed, 3 skipped, 0 failures (0 unexpected), across 39 suites, in 37.6 s.**
No infrastructure failures occurred. Every class that started also finished, and 761 test cases
started.

| Suite | Executed | Skipped | Failed |
|---|---:|---:|---:|
| AgentAccessTokenStoreTests | 6 | 0 | 0 |
| AgentHTTPRequestTests | 12 | 0 | 0 |
| AgentServerIntegrationTests | 8 | 1 | 0 |
| AppSettingsTests | 34 | 0 | 0 |
| CanvasAccessibilityTests | 21 | 0 | 0 |
| CanvasAffordanceTruthTests | 1 | 0 | 0 |
| CanvasDocumentStoreTests | 6 | 0 | 0 |
| CanvasDomainTests | 41 | 0 | 0 |
| CanvasImageDomainTests | 4 | 0 | 0 |
| CanvasImageDropBatchTests | 3 | 0 | 0 |
| CanvasImageImportBatchTests | 6 | 0 | 0 |
| CanvasImageImportTests | 7 | 0 | 0 |
| CanvasImageInteractionTests | 4 | 0 | 0 |
| CanvasImageSessionTests | 4 | 0 | 0 |
| CanvasImageStoreTests | 6 | 0 | 0 |
| CanvasPrecisionTests | 2 | 0 | 0 |
| CanvasRenderCacheTests | 10 | 0 | 0 |
| CanvasSessionTests | 21 | 0 | 0 |
| CanvasStoreTests | 22 | 0 | 0 |
| CanvasUITestStoreTests | 1 | 0 | 0 |
| CornerHoverStateMachineTests | 22 | 0 | 0 |
| DailyCleanupServiceTests | 4 | 0 | 0 |
| MCPRequestHandlerTests | 28 | 0 | 0 |
| NoteAttachmentTests | 43 | 0 | 0 |
| NoteDraftControllerTests | 37 | 0 | 0 |
| NoteInlineCardsTests | 4 | 0 | 0 |
| NoteStoreTests | 14 | 0 | 0 |
| PanelGeometryTests | 70 | 2 | 0 |
| PanelSquircleGeometryTests | 57 | 0 | 0 |
| PanelSquircleSettingsTests | 10 | 0 | 0 |
| PanelSurfaceHostingViewTests | 10 | 0 | 0 |
| PanelUIStateTests | 12 | 0 | 0 |
| SettingsPresentationTests | 16 | 0 | 0 |
| SubtaskPanelControllerTests | 68 | 0 | 0 |
| SubtaskPanelTests | 49 | 0 | 0 |
| SubtaskTests | 24 | 0 | 0 |
| TaskAttachmentDropTests | 21 | 0 | 0 |
| TaskImageTests | 13 | 0 | 0 |
| TaskStoreTests | 40 | 0 | 0 |
| **Total** | **761** | **3** | **0** |

### Skips

All three skips are explicit opt-in environment gates in the source. None is a product or
infrastructure failure, and none is proof of the behaviour it guards.

- `AgentServerIntegrationTests.testOfficialMCPClientInteroperability` needs an optional
  external Node MCP SDK client (`ATTIC_MCP_NODE`, `ATTIC_MCP_SDK_ROOT`).
- `PanelGeometryTests.testNativeSwipeCompletionCancellationAndResourceProfile` requires the
  exclusive desktop visual-test run (`ATTIC_MOTION_VISUAL_TEST=1`). It was not run because UI
  and desktop control were out of scope.
- `PanelGeometryTests.testSwipeReleasePreservesLatestFingerPositionBeforeNextDisplayFrame` is
  gated the same way.

### Reconciliation with source

The source contains 763 `func test…` methods (`source-test-counts.txt`). The 2 not executed are
CloudKit-only tests compiled out by `#if !ATTIC_LOCAL_ONLY` / `#else`. This is correct for the
local-only contract, and a local-only counterpart runs in each case:

- `CanvasStoreTests.testCompletedCloudImportRefreshesThroughFreshContext`
- `NoteStoreTests.testSuccessfulCloudImportRefreshesChangesSavedOutsideStoreContext`

Every other class's executed count equals its source count.

### Cross-check with the 351-test gate

The 11 Batch 4 gate suites gave identical counts here, and all passed:

- CornerHover 22
- NoteAttachment 43
- NoteInlineCards 4
- PanelSquircleGeometry 57
- PanelSurfaceHostingView 10
- SubtaskPanelController 68
- SubtaskPanel 49
- Subtask 24
- TaskAttachmentDrop 21
- TaskImage 13
- TaskStore 40

The other 28 suites add 410 tests, which covers shared importer, storage, Notes, Canvas, settings
and UI-state code outside the gate. No actual product failure was found, so there is nothing to
route for fixes.

## Idle resource observation — trusted preview PID 23135 (read-only)

### Target

- Exact path: `.build/TaskPanelsV2Preview/Build/Products/Local/AtticTaskPanelsV2.app/Contents/MacOS/AtticTaskPanelsV2`
- Bundle: `com.taha.Attic.taskpanels.v2`
- Parent PID 1. It is the sole exact-path process.
- `lsof` shows both mapped `txt` images matching the files on disk:

| Image | Inode | Size (bytes) | SHA-256 |
|---|---|---:|---|
| Stub | `139311655` | 41,008 | `0bc7adc6…b986283` |
| `AtticTaskPanelsV2.debug.dylib` | `139311653` | 20,485,968 | `4c41aee5…c6eb0edf` |

These match `final-launch-provenance.txt`, which was built from the frozen Batch 4 fixes source.

### Conditions

- The 30 s window ran from 10:55:15Z to 10:55:46Z. The app had been running about 17–18 minutes.
- All 4 of the app's windows were off screen (`CGWindowListCopyWindowInfo`, read-only;
  `preview-windows.txt`). The panel was **hidden**, and so were the subtask transient and the
  other windows.
- There was no user HID input during the window. `HIDIdleTime` was 144 s at the start and 174 s
  at the end, and 309 s at 10:58:01Z, so no input occurred through the test run either.
- The unit test run was not active during the sample. Other unrelated system activity was not
  controlled.
- Tools: `ps` once per second (31 rows), `top -l 2 -s 29` for idle wakeups and footprint, plus
  `lsof` and `ps -M`. No `sample`, `spindump`, Instruments or memory dump was used, and no signals
  were sent.

### Results

| Metric | Observation |
|---|---|
| CPU | Cumulative CPU time 4.09 s → 4.10 s over 31 s, about 0.03 % of one core. `ps` `%CPU` was 0.0 on every row, and `top` showed 0.0. |
| Idle wakeups | 1034 → 1041, so 7 in 29 s (about 0.24/s). |
| RSS | 46.8–47.5 MiB (47,952–48,608 KiB), gently decreasing. `top` footprint (MEM) was 77 MB on both samples. Purgeable was 0 B. |
| Threads | 7 (4 in workqueue), unchanged. |
| File descriptors (`lsof` rows) | 80, unchanged. |
| Child processes | None. |

A post-test snapshot at 10:58:01Z, about 2 min 15 s later and spanning the full unit run, showed:

- CPU time 4.13 s, so +0.03 s;
- RSS 45.6 MiB;
- 7 threads and 80 file descriptors, unchanged;
- no children;
- still the sole exact-path PID;
- no leftover `AtticUnitTestHost` process.

There is no accumulating worker, timer or process growth signal, and no odd resource behaviour
needed investigation.

The `ps` grep for "attic" also matched ChatGPT CUA `node` kernel and worker processes. They have
been alive for about 7 h, and their command lines contain the `/Users/taha/Documents/Codex/.../Attic`
path. They are external tooling, not processes owned by the preview.

### Limits and comparison

- This is a short observation of the hidden, idle panel only. It is **not** an energy, battery,
  or thermal measurement.
- It does not cover visible, pinned, hover-sampling, scrolling, gesture, drag, or large-library
  states, or release builds.
- There is no earlier apples-to-apples baseline for this preview (same build, same hidden state).
  The nearest earlier idle figure is `Docs/UXRefinementLedger.md`: 0.37 % CPU and 112.5 → 84.0 MiB
  RSS. It was taken on a different branch, bundle and build, with a **pinned, visible** Tasks panel,
  so it is not comparable. No improvement or regression is claimed against it.

## Gates not proven by this validation

These remain required live, physical or UI gates. Unit tests, harnesses and this read-only sample
do not prove them:

- **`AtticUITests`**, including `SubtaskHoverPinnedUITests`, remain **unexecuted**. The
  xcodebuild/testmanagerd runner was previously blocked, and the offline route cannot drive UI
  tests.
- **Physical trackpad (R7):**
  - follow-the-fingers dismissal, velocity or flick completion, and cancellation;
  - rejecting vertical scroll with real momentum, and rejecting swipes on pinned panels;
  - Reduce Motion;
  - a click, row activation, or modifier during the 160 ms completion;
  - a fresh swipe after an interrupted one.
  - The two motion visual unit tests above were skipped.
- **Pointer corridor (R6)** at real pointer speed:
  - crossing a pinned panel and hover replacement;
  - keeping a latched panel after hover or scroll-out;
  - the outside-click gap.
- **Cross-window drag sessions (Batch 3):** drop overlays, card routing, file promises, and
  reveal. Native drag sessions were not delivered through CUA.
- **Keyboard focus:** clipped-title disclosure. `testKeyboardFocusDisclosesOnlyClippedTitlesOutsideEditing`
  is a UI test and has not run.
- **Optional external MCP client interop:** skipped, as above.
- **CloudKit, APNs, iPhone, TestFlight and Production:** out of scope under the local-only
  contract, and not claimed.

## Evidence (`.build/final-validation/`)

- Suite run: `full-suite-1.log`, `full-suite-1.log.meta`, `full-suite-1.xctestconfiguration`
- Counts: `per-suite.txt`, `test-classes.txt`, `source-test-counts.txt`, `executed-counts.txt`
- Runner: `run.zsh`, `makeconfig`, `makeconfig.m`
- Resource sampling: `sample.zsh`, `resource-sample-1.txt`, `top-idlew.txt`,
  `snapshot-pre-tests.txt`, `snapshot-post-tests.txt`, `preview-windows.txt`
  - In `resource-sample-1.txt`, the thread and fd header lines are missing because of a zsh
    `print "---"` option bug. It was fixed afterwards in `sample.zsh`, and those values were
    captured separately in the snapshot files.
- Source and project checks: `project-generation.log`, `diff-check.txt`, `final-status.txt`,
  `final.index`
- Checksums: `SHA256SUMS.txt`
