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

Long-title AX checks establish single-line height and unchanged row width, not pixel clipping or fade quality. Rendered appearance validation remains separate. No merge or Daily installation has been performed by this remediation pass.
