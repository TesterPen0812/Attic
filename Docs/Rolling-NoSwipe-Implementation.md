# Rolling No-Subpanel-Swipe Implementation

Date: 2026-09-14
Branch: `codex/attic-task-panels-v2` @ `ae6418c1af690e29d15a20344cdb9765a23d3f85`
Requirement: **entirely remove task-subpanel swipe** — gesture interception,
dismissal state, animation, and swipe-exclusive helpers. Main-panel swipe
remains. All other subpanel interactions are preserved.

## Changed files (exact)

| File | Delta vs baseline |
|---|---|
| `Attic/Window/PanelSurfaceHostingView.swift` | −247/+3 lines: removed the entire swipe stack from `PanelSurfaceWindow`, plus `PanelSurfaceSwipeDismissal` and `PanelSurfaceMotionContainer` |
| `Attic/Window/SubtaskPanelController.swift` | −59/+3 lines: removed `swipeDismissal` wiring, the whole `Trackpad dismissal (R7)` section, `SwipePresentationKey` tracking in `syncState()`, the `invalidateTransientSwipe()` call in `openTransient`, and "a swipe" from the doc comment |
| `Attic/Services/SubtaskPanelLayout.swift` | −176 lines: removed `SubtaskSwipeDismissTracker` (recognition state machine, velocity model, presentation/transform helpers) |
| `AtticTests/PanelSurfaceHostingViewTests.swift` | replaced the R7 swipe-routing section (6 tests) with 4 no-swipe regression tests |
| `AtticTests/SubtaskPanelControllerTests.swift` | replaced 3 swipe-dismissal tests with 3 no-dismissal/preserved-close regression tests |
| `AtticTests/SubtaskPanelTests.swift` | removed the `SubtaskSwipeDismissTracker` unit-test section and its now-dangling empty MARKs (tested type no longer exists); all 28 remaining tests unchanged |

`PanelSurfaceHostingView.swift` and `PanelSurfaceHostingViewTests.swift` are
untracked at HEAD (created during this task-panel batch); the other four are
tracked modifications. No project-input files changed, so project
regeneration was not required.

## Baseline snapshots

Original snapshot: six files copied to `/tmp/attic-noswipe-baseline/` with
relative paths and SHA-256 recorded *before* the first edit
(2026-09-14 ~04:05 local; exec session 15187).

`/tmp` was cleaned before the continuation session, deleting the directory.
**Recovery:** the baseline was reconstructed byte-for-byte by reverse-applying
the recorded edit blocks to the current files (`/tmp/noswipe-blocks/`,
`reconstruct.py`), then verified against the recorded SHA-256s:

| File | SHA-256 | Result |
|---|---|---|
| `Attic/Window/PanelSurfaceHostingView.swift` | `fc778ecc…b25e4c` | MATCH |
| `Attic/Window/SubtaskPanelController.swift` | `47a06254…2962e` | MATCH |
| `Attic/Services/SubtaskPanelLayout.swift` | `c197b96b…ce936d` | MATCH — summary's recorded value was truncated to 63 chars; full 64-char digest computed |
| `AtticTests/PanelSurfaceHostingViewTests.swift` | `8f0070c7…46af4f` | MATCH |
| `AtticTests/SubtaskPanelControllerTests.swift` | `ea5f60fc…d82d9be` | MATCH |
| `AtticTests/SubtaskPanelTests.swift` | `c32adcc5…28ebe2` | MATCH |

All six reconstructed files now sit at `/tmp/attic-noswipe-baseline/<repo
relative path>` and are byte-identical to the pre-edit snapshot. The hash
matches also prove the current files equal *baseline + recorded edits only* —
no concurrent agent touched the owned files. Because recovery succeeded, no
`NoSwipeBaseline-Recovery.md` evidence note was required.

## Removed subpanel-swipe architecture

- `PanelSurfaceWindow`: `swipeDismissal` hook, `swipeTracker`, `swipeSession`,
  `swipeReducesMotion`/`swipePresented`/`swipeGeneration` state, modifier and
  interruption sets, scroll-wheel interception inside `sendEvent(_:)`,
  `cancelSwipeDismissal`, `isSwipeDismissalPresented`,
  `completeSwipeDismissal`. `sendEvent` is now a pure forward:
  ```swift
  override func sendEvent(_ event: NSEvent) {
      if let eventForwardingForTesting { eventForwardingForTesting(event) }
      else { super.sendEvent(event) }
  }
  ```
- `PanelSurfaceSwipeDismissal` (session/complete callback struct) and
  `PanelSurfaceMotionContainer` (the layer that hosted scale/fade transforms).
- `SubtaskSwipeDismissTracker` in `SubtaskPanelLayout.swift`: phase machine,
  intent/dominance gates, flick-velocity completion policy, presentation and
  pivot transform helpers.
- `SubtaskPanelController`: `canBeginSwipeDismissal`,
  `swipeDismissalSession`, `completeSwipeDismissal`,
  `transientSwipeRevision`, `SwipePresentationKey`,
  `invalidateTransientSwipe`, and the `surface.swipeDismissal` wiring in
  `configureSurface`.

Verified repo-wide: zero references remain to any of the above symbols.

## Preserved main-panel swipe (independent system)

Untouched and test-covered:

- `Attic/Window/AtticPanel.swift` — `PanelTrackpadDismissTracker` routing in
  `sendEvent`, `notesSwipeTarget` / `PanelNotesSwipeTarget`.
- `Attic/Services/PanelGeometry.swift` — `PanelTrackpadSwipePhase`,
  `PanelTrackpadSwipeSample`, `PanelTrackpadSwipeIntent`,
  `PanelTrackpadDismissTracker`, `PanelCollapseGeometry`.
- `Attic/Window/AtticPanelController.swift` + `PanelUIState.swift` —
  swipe lifecycle and the `.panelSwipe` interaction lock.
- `Attic/Views/Panel/NotesPanelContent.swift` — `NotesHorizontalSwipeView`.
- `AtticTests/PanelGeometryTests.swift` — 71 tests incl. all main-panel swipe
  cases (2 skips are pre-existing: `…ResourceProfile`,
  `…BeforeNextDisplayFrame`).

50 references to main-panel swipe symbols remain across those files.

## Preserved subpanel interactions

- `PanelSurfaceHostingView` keeps squircle hit-testing and
  `PanelSurfaceDragGeometry` header-drag routing (non-swipe).
- `keyDown` Escape → `onEscape` → `closeTransientSurface`/`closePinned`.
- Controller close paths intact: outside-click `dismissTransient`,
  `toggleFamilyPanel`, section-switch, `mainPanelDidHide`, `closePinned`.
- Pin/unpin (`pinFamily`), detach/drag (`detachTransient`), immediate
  click-to-open (`openFamilyPanel`), attachment switching
  (`showPanelView`), editing/focus (`surfaceInteractionBusy` still used by
  the hover-deferral path at `SubtaskPanelController.swift:583` and by its
  own tests — not dead).
- `eventForwardingForTesting` retained as the seam proving scroll reaches
  content; it adds no behavior when unset.

New regression coverage asserts: a swipe-shaped horizontal pan reaches
content 1:1 with no transform, fade, move, or dismissal; every scroll
flavour (began/changed/ended, imprecise wheels, momentum, modifier-bearing)
passes through; interrupted sequences leave no gesture state; Escape still
routes; scroll/drag residue never dismisses a latched or detached panel;
all preserved close paths still dismiss; re-open after dismissal is a fresh
stable presentation.

## Commands run and outcomes

```sh
# build-for-testing (required macOS local build)
xcodebuild build-for-testing -project Attic.xcodeproj -scheme Attic \
  -configuration Local -derivedDataPath /tmp/attic-noswipe-dd \
  -only-testing:AtticTests CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO -quiet
# → BUILD_EXIT=0 (pre-existing deprecation warnings only)

# offline in-host XCTest harness (restored from .build/final-fixes/offline-xctest/)
ATTIC_TEST_PRODUCTS=/tmp/attic-noswipe-dd/Build/Products/Local \
  zsh /tmp/attic-offline-xctest/run.zsh noswipe-focused-retry 240 \
  PanelSurfaceHostingViewTests SubtaskPanelControllerTests SubtaskPanelTests \
  PanelGeometryTests PanelUIStateTests
# → 183 tests, 2 skipped, 0 failures, exit_status=0
#   PanelGeometryTests 71 (2 skip) · PanelSurfaceHostingViewTests 7 ·
#   PanelUIStateTests 12 · SubtaskPanelControllerTests 65 · SubtaskPanelTests 28

ATTIC_TEST_PRODUCTS=… zsh run.zsh noswipe-geom-retry 240 PanelGeometryTests
# → 71 tests, 2 skipped, 0 failures, exit_status=0

ATTIC_TEST_PRODUCTS=… zsh run.zsh noswipe-perf 120 TaskPerformanceGateTests
# → 4 tests, 0 failures, exit_status=0

git diff --check
# → clean
```

## Failure classification

- **Code failures:** none.
- **Environment failures:** none blocking. `sandbox_extension_issue_file_to_process
  … Operation not permitted` is a tooling warning emitted by the offline host;
  results still produced (pre-existing, seen before these edits).
- **Flaky (pre-existing, not caused by this change):** the first combined run
  (`noswipe-focused`) reported 6 assertion failures across 4
  `PanelGeometryTests` main-panel swipe cases (`0 != 1`, gesture never
  recognized). These files were never touched; the suite passed 71/71 in
  isolation and the identical combined set passed 183/183 on retry —
  consistent with window-server/event-routing flake when suites share one
  host process. The earlier session's run saw the same suite pass.
- **Pre-existing:** `TaskPerformanceGateTests.testStatusToggleAtSixThousand
  TasksStaysBounded` failed once in the earlier session (144.8 ms vs 120 ms
  threshold); it passed 4/4 here — a timing-sensitive gate, unrelated to
  this change.

## Remaining validation limits

- The app was **not** launched or relaunched; the native pointer was **not**
  operated. No live visual, gesture, or accessibility evidence is claimed.
- Main-panel swipe is preserved in source and green under XCTest, but no
  live gesture claim is made.
- Final visual review belongs to **Sol Low**. Handoff setup note:
  *If the task sub-panel does not open, open it manually using double-click,
  then "Add Task." This setup may be necessary before the panel becomes
  available for inspection.*

## Diff integrity

`git diff --check` clean. Final review of all six diffs vs the hash-verified
baseline confirms only swipe-removal and test-replacement changes; no
unrelated Fable/root edits were touched, nothing was staged or committed.

IMPLEMENTATION_READY
