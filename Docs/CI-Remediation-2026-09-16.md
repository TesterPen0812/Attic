# macOS CI remediation — 16 September 2026

The first complete Xcode 26.6 run, [35126949864](https://github.com/TesterPen0812/Attic/actions/runs/35126949864), built and analyzed the candidate successfully but reported 10 unit failures, 13 UI failures, and dependency-lockfile residue. These failures remain the integration gate until a corrected hosted run passes.

## Product fixes

- Completed-task cleanup uses an explicit non-nil completion-date comparison instead of a coalesced distant-future sentinel. The former expression returned no eligible rows under hosted SwiftData. Replica and family agreement checks are unchanged. A regression test checks nil, exact-cutoff, older, and newer dates through a fresh context.
- Canvas dismantling captured a draft and synchronously published editing availability while SwiftUI invalidated its graph. All six hosted crash stacks identify this reentrant publication and a Swift exclusivity abort. Native teardown now separates immediate detachment from draft publication after graph teardown, preserving the original session and callbacks.
- Main-panel focus protection expires after 1.5 seconds without typing, but event-driven monitoring scheduled no wake-up while that temporary lock remained active. The monitor must schedule a single expiry sample for a stationary outside pointer. The two existing focus-and-idle UI assertions remain unchanged.

## UI harness corrections

- Query `add-task-button` by identifier across roles because its native role is MenuButton.
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
