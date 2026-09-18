# Subtasks and compact composer — local verification

## Scope and implementation

Worktree: `/Users/taha/Developer/attic-scroll-under-controls`.
Branch: `codex/attic-mcp-subtasks-composer`, following MCP repair `b109b17634f2e1626903b98f6fd381fea4b1ed3d`.

- Optional scalar `TaskItem.parentID`, with automatic local schema migration.
- One-level, collapsible task families, inline entry, independent completion,
  and progress counts. Done children remain under their parent.
- Parent completion is manual and requires completed steps. Reopening or adding
  a child requires an unfinished parent. Moving a parent preserves its family.
- Duplicate-safe writes and family deletion; rollback on failed saves;
  conflicting, cyclic, or deeper imported links cannot broaden deletion scope.
- Cleanup retains the entire family until all physical replicas agree and every
  member's completion precedes the local-day cutoff. Orphans remain visible.
- Compact one-row entry while typing; a plus button opens a 34-point priority
  strip. Collapse preserves the current title and priority.
- MCP `create_task` and `list_tasks` accept `parent_id`; task results expose it.
  Parent deletion explicitly includes subtasks in the tool's description.

The implementation retains the existing SwiftUI/AppKit glass, themes, panel
navigation, and local-only identity/signing boundaries. It does not enable any
deferred iPhone, CloudKit, APNs, or production-store work.

## Automated evidence

Result bundles and logs live in the worktree's `.build/evidence/` directory.

- `subtasks-focused-3.xcresult`: 84 passed, zero skipped/failed/runtime warnings.
  Includes an on-disk pre-subtask schema fixture reopened with the new schema;
  UUID, title, priority, status, timestamps, and ordering are preserved, and a
  child can subsequently be saved and reloaded.
- `subtasks-full-1.xcresult`: 576 passed, zero skipped/failed/runtime warnings.
  This precedes the final nested-link deletion guard and expanded SDK subtask
  exercise; it is not the final-source gate.
- `subtasks-ui-1.xcresult`: runner initialization blocked before tests by a macOS
  authentication prompt. This is not a UI pass.
- `subtasks-full-2.xcresult`: 577 passed, no skips/failures/runtime warnings,
  including the expanded official-SDK subtask exercise and sibling reorder.
- `subtasks-full-3.xcresult`: 582 passed, no skips/failures/runtime warnings,
  including lazy credential loading, cancellation, failure/retry, UI-host
  credential isolation, and the family confirmation's auto-hide lock. Two
  test-only sendability conversion warnings were subsequently corrected.
- `subtasks-full-4.xcresult`: final application-source gate: 582 passed, zero
  failures, skips, runtime warnings, or compile warnings. Includes the inline
  entry scroll request and listener-generation cancellation guard.
- `subtasks-ui-4.xcresult`: existing task workflow and Agent Access setup page
  passed. The new subtask workflow reached inline entry but failed hit testing
  while a prior Keychain prompt remained visible. The run also reported one
  internal QoS warning. This is not a full subtask UI pass.
- `subtasks-ui-8.xcresult`: existing task workflow and Agent Access setup passed
  again. The new test successfully created two children but asserted the
  completion count before the accessibility value updated. Native pointer and
  accessibility actions both updated the preview's checkbox and progress;
  a subsequent AX snapshot reflected the update. The test now waits up to
  three seconds for the same exact expected value. Element-relative clicks
  also match the existing task/note checks for masked scroll content.
  The run reported an internal QoS warning; no behavior assertion was removed.

Project-generation repeatability, the installer (10 tests, 64 assertions),
preview launcher (7 tests, 54 assertions), JavaScript syntax, and whitespace
checks also passed.

### Startup issue found during native verification

The earlier credential branch checked `isRunningTests` but not the explicit
`ATTIC_UI_TESTING` flag. A UI host launched without XCTest environment keys
therefore read Keychain on the main thread. A sample of the stalled test host
(`subtasks-ui-3-sample.txt`) shows `AppCoordinator.init` →
`AgentAccessTokenStore.loadOrCreate` → `SecItemCopyMatching` waiting for approval.

Both test-host kinds now use an ephemeral credential. Normal apps do not load
credentials at construction at all: opt-in starts one background load, no
listener binds until it succeeds, denied access fails closed and can be retried,
and disabling access ignores a late result. A rapid retry reuses any pending
load so it cannot multiply system prompts. Listener generations also reject
requests from an earlier stopped instance. Keychain permissions are unchanged.

The new focused tests cover one-level validation, manual parent completion,
cross-scope family presentation, deletion boundaries, save rollback, cleanup
cutoffs, divergent replicas, orphan/cycle visibility, MCP arguments, and draft
interaction locks. The SDK exercise uses a real loopback Swift listener and an
in-memory test store, not a user's installed-client credential.

## Preview and release boundary

Preview display name: `Attic Subtasks Preview`.
Bundle: `com.taha.Attic.subtasks20260909.preview`.
Executable: `/Users/taha/Developer/attic-scroll-under-controls/.build/SubtasksPreview/Build/Products/Local/AtticSubtasksPreview.app/Contents/MacOS/AtticSubtasksPreview`.
Signing: approved local development override `AQ484LXN59`.

Native verification of build 3 (application source represented by the tests
above, before the feature commit): the persisted four-step preview family
survived relaunch with the same IDs and two completed children. Both native
accessibility and pointer checkbox actions changed progress. A typed subtask
draft survived collapse/expand. Choosing Add subtask scrolled the input above
the bottom composer. Compact and expanded composer appearances were inspected.
Preview executable SHA-256:
`e6f56d80b2766589e2044a0aa62c4cf7dbf984f05c7c7f0aeb641014af82b524`.

The preview contains synthetic demonstration data only. Final clean-source
preview provenance and Daily promotion are recorded separately below. A
source build alone is not an installed-app or connected-client verification.

## Current verification hold — 2026-09-10

`subtasks-ui-10` through `subtasks-ui-13` reached the disclosure check but did
not complete the automated collapse assertion. Bounded waits corrected the
earlier completion-count snapshot race. Direct native preview disclosure
actions (including a coordinate click with an inline draft focused) succeeded;
that does not turn the outstanding XCTest failure into a pass. A borderless
button-style experiment did not resolve it and was reverted.

`subtasks-ui-14` was interrupted at the initial quick-entry field before the
subtask checks. The computer-use inventory then explicitly reported the Mac
was locked and could not be automatically unlocked. An unvalidated z-order
experiment was also reverted. Current application source is again the source
covered by `subtasks-full-4`; the updated UI test still needs completion.

Daily remains at `8b03586df79c6d667a6aea444b74f7167e552568`, with Agent Access
off. No release replacement or data migration has been performed. Before the
hold, read-only inspection found one main task and zero notes. The existing
task-field digest was
`8047f810e95d8ec7755f0162b3567d88ec69684a42336a027bed3046e51d45b3`.
The prior MCP-only preview and the subtask preview were quit normally.

### Unlocked follow-up

After the user unlocked the Mac, computer use was available again.
`subtasks-ui-15` failed before launching the application: "Timed out while
enabling automation mode." The `testmanagerd` log explicitly reported that
the writer daemon required authentication and requested "Enable UI
Automation" for XCTest. This is a separate system approval from unlocking the
Mac; no authentication or permission setting was bypassed.

The disclosure test now anchors its real pointer click to the panel using the
control's current bounds. An element-relative coordinate had still invoked
XCTest's AX hit/scroll machinery; native coordinate clicks had worked. The
same collapse, re-expansion, and draft-preservation assertions remain. This
test-only change is not yet verified, because automation did not initialize.
No application source changed after `subtasks-full-4`.
`subtasks-ui-16`, retried after asking the user to approve that prompt, timed
out at the same automation-initialization step. Neither run executed the test.

Additional native checks on the same signed preview passed: attempting parent
completion with unfinished steps displayed the expected error; finishing all
four steps left the parent in To do; manually completing it moved the family
to Done with a count of one; reopening a child under a completed parent was
blocked; reopening the parent preserved all four completed children. The
family-deletion alert correctly named the parent and four children, and
Cancel left all five records visible. The destructive confirmation itself
has unit/SDK coverage but has not yet been reached by the automated UI test.
The preview was quit normally after these checks. Daily is still unchanged.
