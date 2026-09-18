# macOS CI remediation — 16 September 2026

The first complete Xcode 26.6 run, [35126949864](https://github.com/TesterPen0812/Attic/actions/runs/35126949864), built and analyzed the candidate successfully but reported 10 unit failures, 13 UI failures, and dependency-lockfile residue. These failures remain the integration gate until a corrected hosted run passes.

## Product fixes

- Completed-task cleanup now fetches done rows and parent-linked rows in batches, applying optional date and parent membership filters in memory. Hosted diagnostics proved that `PredicateExpressions.ForcedUnwrap` is unsupported on macOS 26.6; the earlier explicit non-nil/force-unwrap patch did not fix it. Replica and family agreement checks are unchanged. A regression test checks nil, exact-cutoff, older, and newer dates through a fresh context.
- Canvas dismantling captured a draft and synchronously published editing availability while SwiftUI invalidated its graph. All six hosted crash stacks identify this reentrant publication and a Swift exclusivity abort. Native teardown now separates immediate detachment from draft publication after graph teardown, preserving the original session and callbacks.
- Main-panel focus protection expires after 1.5 seconds without typing, but event-driven monitoring scheduled no wake-up while that temporary lock remained active. The monitor must schedule a single expiry sample for a stationary outside pointer. The two existing focus-and-idle UI assertions remain unchanged.

## UI harness corrections

- Query `add-task-button` by identifier across roles because its native role is MenuButton, then select Task options or Close task options from its menu before asserting expansion or collapse. The title-layout test uses the already-visible entry field directly.
- Use the current `subtask-composer-action-<UUID>` identifier.
- Move Settings clear of the always-visible test panel before interacting with occluded controls.
- Assert the documented 320×460 visible-content minimum, which is the accessibility frame; native resize borders are outside that frame.
- Reacquire the child entry field for each large-family row, preserving Return submission and row-creation assertions for every child. The focus hypothesis still needs hosted confirmation.

The original 13 UI failures therefore comprise ten proven selector/geometry/window-layout mismatches, one provisional fixture-focus failure, and two valid product failures sharing the idle scheduling cause. No test is skipped, and Escape is not added to bypass the focus-and-idle behavior.

## Workflow

The verified Bundler checksum is recorded, dependency installation is frozen, and both unit and UI result bundles are retained. Full required suites, static analysis, generated-project consistency, and checkout cleanliness remain gates. See [CI integration](CI-Integration-2026-09-16.md).

## Verification

Checks on the patched tree:

- Cleanup boundary regression and complete `DailyCleanupServiceTests`: 5 passed, zero failures. The preceding TaskStore/cleanup focused run passed 49 tests with one skip before the new boundary case.
- Canvas: the six previously aborting tests plus draft failure, replacement-session, deferred-lifetime, and reentrancy regressions passed; 12 tests, zero failures. No view-update publication or simultaneous-access warning appeared. These tests also passed locally before the fix, so hosted runtime confirmation remains required.
- Corner-hover and panel UI state: 37 passed, zero failures.
- Corrected UI tests: Local `AtticUI` build-for-testing passed. The final fixture adjustment preserves the same Return call inside the loop and passed diff checking; no native UI rerun is claimed yet.
- Frozen isolated Bundler install preserved the lockfile; workflow YAML and `git diff --check` passed.

The new hosted full-suite result is pending. Daily remains on its previous build while CI is failing.


## 17 September follow-up

The hosted run on `4c12274`, [35240529375](https://github.com/TesterPen0812/Attic/actions/runs/35240529375), passed all 837 unit tests except four explicit skips (833 passed, zero failures). That count includes one temporary diagnostic method with no assertions; it is removed after capturing the predicate evidence. All behavioral cleanup and family/replica regression tests remain. The final unit suite is therefore expected to contain 836 tests.

The diagnostic logged `unsupportedPredicate` for the force-unwrapped completion-date and parent-membership forms. It also showed that coalesced date comparisons worked in isolation, so the earlier claim that all optional-date comparisons fail was too broad. The current batch queries avoid force unwraps. The in-memory parent filter uses a `Set<UUID>` rather than repeated array membership searches, avoiding quadratic candidate-by-child work.

The post-edit snapshot cost was reduced by caching the root list and sorting children only when a family is requested. The unchanged hosted performance gate passed with a 25.3 ms toggle measurement; diagnostic snapshot time was 54.6 ms. The existing 120 ms threshold was not changed.

On the same candidate, 32 of 35 UI tests passed. The three remaining Settings tests were obstructed by the floating test panel and the Dock on the 1024×768 runner. Commit `3ceb134` changes only test navigation: it measures control frames after scrolling or moving Settings and avoids those obstructions. The hittability, selection, accessibility, idle-expiry, and Return-submission assertions remain. Its hosted result is pending at the time of this update.

Long-title AX checks establish single-line height and unchanged row width, not pixel clipping or fade quality. Separately, inspection of the saved hosted screen recording for `f737146` shows the long title fading inside the panel on one line. `TaskRowView.swift` is unchanged between that candidate and the current remediation; this is saved-render evidence, not a new installed-preview run. No merge or Daily installation has been performed by this remediation pass.


The follow-up run on `3ceb134`, [35247531839](https://github.com/TesterPen0812/Attic/actions/runs/35247531839), again passed all unit tests (833 passed, four skipped) and passed 33 of 35 UI tests. Agent Access and the appearance picker passed. The full theme test still failed when revisiting Light after scrolling to Clear: the control's accessibility frame was above the page's clipped viewport. The navigation helper now scrolls controls into the page viewport before resolving panel or screen occlusion. This is supported by the failed test's recording, which shows the page scrolled past the appearance row.

The other failure was the pinned-window test's initial task creation: the recording shows its title remaining in the field after one Return press. Fixture setup now waits for the exact title and enabled submit state before sending that same single Return. The row-creation assertion is unchanged; no second Return or click fallback is introduced. This readiness hypothesis still requires hosted confirmation.


Run [35250734604](https://github.com/TesterPen0812/Attic/actions/runs/35250734604) on `5c19827` passed normal/strict builds, static analysis and 832 unit tests (four skipped). UI testing passed 34 of 35, including the pinned-window test. The remaining theme test reached the viewport correction but XCTest could not find a hit point for the partially off-screen ScrollView at `{{200, 539}, {672, 594}}`. Scrolling now uses the visible empty leading gutter via the public `XCUICoordinate.scroll(byDeltaX:deltaY:)` API instead of the ScrollView's off-screen center. It remains a real pointer scroll; the same reachability and theme assertions remain required.

Run [35254191644](https://github.com/TesterPen0812/Attic/actions/runs/35254191644) on `db0b7d4` passed both builds, 832 unit tests (four skipped), static analysis and final project/worktree validation, but again passed only 34 of 35 UI tests. The theme test advanced to gradient coverage before the ScrollView hit-point failure recurred. The focused native theme test passed on macOS 27 with the isolated `com.taha.Attic.cisettings.db0b7d4` app; this did not reproduce the hosted display constraint. The gesture now anchors to the application frame and converts the same visible page point into application-relative coordinates, avoiding the ScrollView as the event-resolution root. Assertions and interaction semantics are unchanged.

Run [35257729491](https://github.com/TesterPen0812/Attic/actions/runs/35257729491) on `5587df6` passed 832 unit tests (four skipped) and 33 of 35 UI tests. Both Appearance failures were preceded by application-rooted scroll coordinates `(-inf, -inf)`: the application accessibility frame is not finite on the runner. The scroll now anchors to the visible Settings close button, validates its finite frame and hittability, and offsets into the same empty page gutter. It does not click the close button or change assertions.

## 18 September focused closeout

Run [35260843370](https://github.com/TesterPen0812/Attic/actions/runs/35260843370) on `a868c7b` passed 832 unit tests with four skips, but 32 of 35 UI tests. The remaining failures were the second translucency click after the page changed layout, gradient coverage stopping at 0.99, and fixture setup not revealing Step 8 in the bounded checklist. The finite scroll anchor produced valid coordinates; the second translucency click had omitted the existing reveal helper. It now remeasures and reveals that control after the layout change.

The gradient's archived synthesized event ended its move and released the mouse at the same offset, 2.478 seconds. The endpoint drag now holds for 0.2 seconds before release. This is a bounded input-timing correction, not proof of an underlying AppKit cause: the original endpoint test passed in a fresh local baseline. Exact 0 and 1 assertions, the existing three-second assertion timeout, pointer dragging, and the actual slider value remain required.

The family failure's accessibility hierarchy and recording show eight children already created, with the last row below the fold and the entry empty. Its ten-attempt reveal loop alternated scroll directions, repeatedly revisiting the same strip. The helper now scrolls toward the appended rows on every attempt. It still sends one Return per child, requires each child's own row, and checks the real scroll view and the unchanged height limit after creating all twelve children.

Native verification on macOS 27 passed all three focused Settings tests (theme matrix, appearance transitions, and exact gradient endpoints), then the large-family test: four passed, zero failures or skips, and no runtime warnings in either result summary. The uniquely identified local-only host was `com.taha.Attic.cicloseout.gradientbaseline.20260918`, executable `AtticGradientBaseline20260918`, built under `/tmp/attic-ci-gradient-baseline-20260918`. It ran the `a868c7b` checkout with the three test changes above; the verified test diff, build manifest, result summaries and logs are retained in `/Users/taha/Developer/attic-worker-runs/ci-closeout-20260918`. The XCTest app and runner exited, the UI lock was released, and each owned attachment root was cleaned. Both changed test files also type-check with Xcode 26.2. These local results do not replace the full hosted macOS 26.6 gate; its final result is recorded on PR #3.
