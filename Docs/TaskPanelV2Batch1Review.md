# Task panel V2 — batch 1 independent review

Final batch-1 source verdict: approved. The two original P2 contract defects, the row-help
observation, and the focus-title observer P2 are fixed correctly. No P1 issue was found. The
local data path is preserved. Live UI validation remains separate from this source verdict. The
stale parent-completion UI assertion is a test correction deferred to the next implementation
batch; the retained hierarchy proves the required product confirmation appeared.

## Bounded live-failure investigation — stale assertion, required behavior presented

### P2 — The compact-composer UI test asserts the wrong confirmation surface

**Location:** `AtticUITests/AtticUITests.swift:517-520`; relevant product paths
`Attic/Views/Panel/TaskRowView.swift:116-131`, `Attic/Views/Panel/TaskRowView.swift:409-415`, and
`Attic/Views/Panel/AtticPanelView.swift:644-649`.

The frozen live run did not reveal a product failure at parent completion. After one of two
children was completed, XCUI successfully clicked the parent's `complete-task-...` button. The
retained failure hierarchy then contained a keyboard-focused alert sheet titled “Complete this
task?”, its unfinished-subtask explanation, and both “Complete anyway” and “Cancel” buttons.
This also establishes that the new row-wide tap recognizer did not steal this status-button click.

The test nevertheless waits for `panel-error-message`. That identifier belongs to the main
panel's `store.lastErrorMessage` banner for operation/persistence errors. The unfinished-child
path deliberately intercepts the request in `requestStatus` and presents a calm confirmation
before calling the store, so no error banner should appear. The same incorrect expectation exists
in the frozen baseline test; it is stale test semantics rather than a batch-1 regression.

Required fix: replace the error-banner expectation with assertions for the alert title/message
and its two actions. Exercise both decisions: Cancel must leave the parent in To do with the
1-of-2 child state unchanged; “Complete anyway” must move the parent to Done while preserving the
unfinished child. A minimal rerun of this corrected flow is sufficient. The retained run proves
presentation and keyboard focus, but it stopped before either action, so cancel and override
outcomes remain live-UAT gaps rather than passes. The store-level preservation behavior remains
covered by `AtticTests/SubtaskTests.swift:78-88`.

## Fix-delta review

### P2 resolved — Focus-title observers are now presentation-scoped

**Location:** `Attic/Views/Panel/TaskRowView.swift:528-608`, especially
`Attic/Views/Panel/TaskRowView.swift:571-603`.

`TaskTitleExpansion.AnchorView` now derives its observation target from an active presentation
and the current window. Inactive rows install nothing. A focused row installs one bounded set for
its window and enclosing clip view, repeated SwiftUI updates do not stack registrations, and
focus loss, window removal, or dismantling removes the set. Keeping the set through temporary key
loss and scroll-out is necessary for the disclosed title to return when the window or row becomes
visible again. The implementation uses notifications rather than polling and clears configuration
on teardown, so a dismantled anchor cannot re-register when later moved in a view hierarchy.

The focused lifecycle test uses two anchors in a real `NSWindow`/`NSScrollView` hierarchy and
checks inactive, active, repeated-update, key-loss, scroll, focus-loss, removal/rejoin, and
dismantle states. It would fail against the pre-fix implementation. The supplied xcresult
independently reports 54 passed, 0 failed, 0 skipped and no runtime warnings; the Local build log
records `BUILD SUCCEEDED`. No UI-test source, accessibility identifier, persistence path, or
project input changed. Live focus-disclosure alignment and return after key/scroll transitions
remain UAT rather than source blockers.

### Original findings — resolved

- **F1 resolved:** `AtticGlassControlTreatment.resolve` now depends only on Reduce Transparency
  and native-glass availability. Surface translucency and Glassmorphism cannot change control
  treatment. The modifier and glass container no longer observe surface settings, and the updated
  test covers the four accessibility/availability outcomes.
- **F2 resolved in source:** clipped-title measurement and `TaskTitleDisclosure` now trigger a
  mouse-transparent, accessibility-hidden visual expansion under row-control keyboard focus,
  without changing row layout. Its visual placement, traversal behavior, and scrolling still need
  the recorded live checks.
- **F3 resolved:** row help now leads with click-to-open or click-to-reveal and retains the status
  double-click shortcut. Child-row help remains unchanged.
- **F4 test correction accepted:** the failed UI artifact showed `quick-entry-title` keyboard
  focused after the row reopened the panel with `focusEntry: false`; the preserved subtask draft
  existed but did not own focus. Clicking the subtask field before sending Escape tests the
  field's existing `.onExitCommand` contract. The test still requires draft preservation,
  Escape cancellation, entry collapse, affordance restoration, and successful refocus. This is
  a precondition repair rather than an assertion reduction or a product behavior change.

### Fix evidence reviewed

- `.build/batch1-fixes.diff` and current affected callers/tests were inspected against pre-fix
  tree `e4ec3474f0c67547095e6c64151f6d266b5fa76d` and the original frozen baseline.
- `.build/batch1-fixes/build-local-1.log` records `BUILD SUCCEEDED`.
- `.build/batch1-fixes/FixesFocused-1.xcresult` independently reports 127 passed, 0 failed,
  0 skipped, and no runtime warnings.
- `.build/batch1-fixes/uitest-compile-1.log` records `TEST BUILD SUCCEEDED`. The changed UI test
  compiled but was not rerun in these artifacts; that remains live-validation evidence.
- No model, store, entitlement, signing, local-only, or persistence code changed in the delta.
  The glass-policy simplification reduces unnecessary control invalidation. Apart from the
  per-row observers above, the width measurements and focus-only child panel are bounded and do
  not copy task or attachment data.

## Initial findings (resolved by the fix delta)

### P2 — Glassmorphism still changes controls away from Liquid Glass

**Location:** `Attic/Design/AtticStyle.swift:257-268`, exercised by
`Attic/Design/AtticStyle.swift:283-312` and `Attic/Design/AtticStyle.swift:363-377`.

`AtticGlassControlTreatment.resolve` returns `.material` whenever the panel is translucent
and its surface style is `.glassmorphism`. Every `atticGlassControl` in that configuration
therefore uses `.thinMaterial` instead of native Liquid Glass, and the surrounding
`GlassEffectContainer` is removed. This leaves control appearance coupled to a panel-surface
choice, contrary to R8 and the new settings promise that controls *always* use Liquid Glass.
The new test in `AtticTests/SettingsPresentationTests.swift:7-45` encodes the same exception,
so it verifies the defect rather than the contract.

Required fix: on systems that support native Liquid Glass, resolve control treatment to
`.nativeGlass` for every surface translucency and `PanelGlassStyle` combination. Keep
`.opaque` for Reduce Transparency and the existing material fallback for systems without
native glass. Update the table test so `.glassmorphism` has no special control exception.
Then run `SettingsPresentationTests` and the focused style/settings suites. Live validation
must compare interactive controls in solid, clear, frosted, and glassmorphism surfaces and
with Reduce Transparency.

### P2 — Keyboard focus does not expose a clipped full title

**Location:** `Attic/Views/Panel/TaskRowView.swift:45-46`,
`Attic/Views/Panel/TaskRowView.swift:181-223`, and
`Docs/TaskPanelV2Ledger.md:144-149`.

The full-title tooltip exists only on the clipped `ViewThatFits` fallback. Keyboard focus
changes `showsRowAffordances`, which controls the hover surface and ellipsis opacity, but it
does not change `titleArea` or present the full title. The ledger explicitly acknowledges
that keyboard focus does not show it. An accessibility label covers spoken access, and the
editor covers editing, but neither satisfies the separate R1 requirement that the full title
be available through focus to a keyboard user.

Required fix: add a restrained focus presentation for a clipped title, driven by the row's
focus state and sharing the same full string used by hover help. It must not change row height
or move metadata. Prefer one measurable/clipping-aware implementation instead of showing a
redundant overlay for short titles. Add focused coverage for the state decision, then validate
forward and reverse Full Keyboard Access traversal with a long title at minimum and maximum
panel widths.

## Non-blocking observation

`Attic/Views/Panel/TaskRowView.swift:89-94` gives the entire row a status-oriented tooltip
such as “Double-click to start,” while the row's primary single-click action now opens the
family panel. The tooltip is factually valid as a secondary shortcut, but it does not teach
the new primary action and can win when the pointer is over blank row space. During the title
focus fix, make the row help describe opening the panel while retaining the double-click
status shortcut in an appropriate secondary hint or status-control help.

## Reviewed behavior that is sound in source

- The title and metadata layout reserves the trailing 24-point menu slot and keeps normal
  rows at a 42-point minimum. The overflow fallback clips by mask rather than changing task
  data.
- Attachment thumbnails and subtask progress are passive views. Existing image import and
  image-management access remains in the shared task menu/context menu.
- The pinned marker calls the existing idempotent `openFamilyPanel`, which raises a pinned
  window instead of creating a transient. Pin/unpin remains in the subpanel.
- Child rows keep task drag and double-click status behavior without creating nested panels.
  They are rendered only inside their parent's existing family surface.
- The source-row mouse-down exemption uses the existing visible row anchor, so an idempotent
  row activation does not close and immediately recreate its latched surface. Existing
  geometry conversion and hidden/scrolled-row guards remain in force.
- No model, store, entitlement, signing, local-only, or persistence code changed. There are
  no new timers, observers, image decoding paths, or data copies. Added per-row work is small
  view state plus `ViewThatFits`; no material performance concern appears in source.
- Existing painted-surface hit ownership and transparent-corner behavior were not changed.

## Evidence reviewed

- `.build/batch1.diff` was inspected against the frozen snapshot tree
  `b6d6dabcf0ba00fc40c7e9b87ebf5c258a0ce0ae`, along with current changed source, callers,
  controller paths, and relevant tests.
- `.build/batch1/build-local-3.log` records `BUILD SUCCEEDED` on final source.
- `.build/batch1/Batch1Unit-2.xcresult` independently reports 694 total tests: 691 passed,
  3 skipped, 0 failed, and no runtime warnings. This predates only the final restoration of
  the rectangular row hit shape.
- `.build/batch1/Batch1Focused-3.xcresult` independently reports 208 passed, 0 failed, and
  no runtime warnings on final source. The focused set covers the changed controller and
  settings policy plus adjacent task, image, store, surface-hosting, and layout suites.
- `.build/batch1/uitest-compile-3.log` records `TEST BUILD SUCCEEDED`. UI tests compiled but
  were not run. I did not repeat the broad automated suites because the supplied result
  bundles substantiate them and the two findings are directly established by source policy.

The harmless logs include the expected App Intents metadata warning and transient system
service diagnostics. Neither result bundle records a runtime warning or test failure.

## Live UAT gaps, not source findings

- Rendered one-line fade, title/metadata spacing, row-height stability, pinned glyph size,
  hover contrast, and ellipsis visibility across supported widths and themes.
- Single click versus double click on blank row space, status, pinned marker, attachment
  metadata, and menu; parent and child drag/reorder from each usable row region.
- Full Keyboard Access in both traversal directions, focus-ring/ellipsis behavior, menu
  reachability while initially hidden, and long-title focus disclosure after the fix.
- VoiceOver order and wording for row, passive metadata, custom row action, pinned reveal,
  and the hover-only menu/context-menu path.
- Existing image popover access through both primary and context menus.
- Solid, clear, frosted, and glassmorphism panel surfaces with interactive controls after
  the R8 fix; Reduce Transparency and Increased Contrast; pinned glass weight.
- Existing latched/dragged subpanel behavior, pinned identity/position, source-row reopening,
  painted padding hit absorption, transparent corners, and unchanged main-panel motion and
  idle auto-hide.

## Actionable fix list

1. Correct the compact-composer parent-completion UI assertions in the next implementation batch
   and run that flow through both Cancel and “Complete anyway,” including proof that the unfinished
   child is preserved.
2. Use the concurrent live pass to validate focus expansion placement/lifecycle and the remaining
   row, gesture, accessibility, and glass appearance gaps already listed above.
