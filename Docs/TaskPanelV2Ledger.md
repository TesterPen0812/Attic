# Task panel V2 ledger

Contract: `Docs/TaskPanelV2Requirements.md` (all batches). Review criteria:
`Docs/TaskPanelV2ReviewCriteria.md` (orchestrator-owned; not edited by the implementer).

## Provenance

- Worktree: `/Users/taha/Developer/attic-task-panels-v2`, branch `codex/attic-task-panels-v2`.
- Base commit `ae6418c1af690e29d15a20344cdb9765a23d3f85` plus the uncommitted approved
  changes of `/Users/taha/Developer/attic-ux-refinement` (applied as a binary patch; nonignored
  untracked files copied). Porcelain status and SHA-256 of all 59 modified/untracked paths
  matched the baseline before any change. No commits.
- Snapshot tree (temporary index, no ref): `b6d6dabcf0ba00fc40c7e9b87ebf5c258a0ce0ae`.
  Patch, file list, digests and `PROVENANCE.md` live in `.build/v2-baseline/`.
- Batch diffs are computed against that tree, not against HEAD, so inherited edits are excluded.

## Batch status

| Batch | Scope | Status |
| --- | --- | --- |
| 1 | R1 main rows + R8 surface vs controls | Implemented and source-approved; rendered row/glass checks passed. Keyboard-focused title disclosure remains a manual gate. |
| 2 | R2 unified family panel + R3 attachments | Implemented; two SWE reviews and fix reviews approved. Targeted live switching, sizing, imports, preview and confirmation checks passed. |
| 3 | R4 drop interactions + R5 main composer attachments | Implemented; two SWE reviews and fixes approved. Final full unit suite covers affected paths; trusted-preview picker/pending/growth/submit/remove passed. Native cross-window drag checks remain manual. |
| 4 | R6 pointer corridor/pinning + R7 trackpad dismissal | Implemented; both SWE fix reviews approved. Actual window/controller regression tests pass; physical pointer-travel and trackpad feel remain manual gates. |
| 5 | Integrated review, fixes, tests, local-only preview, live UAT, resources | Astra HIGH final source approval granted after F1/F2 fixes. Final real-host XCTest: 767 executed, 764 passed, 3 skipped, zero failures across 39 suites. Final preview rebuilt, mapped code verified and targeted smoke passed. Manual gates below remain; this is not unconditional release or physical-UAT approval. |

## Final accepted source and remaining manual validation — 2026-09-13 11:48 UTC

- Final review: `TaskPanelV2FinalAstraReview.md`; no remaining actionable source findings.
- Final tests/build evidence: `.build/final-fixes/PROVENANCE.md`; real in-host XCTest, not an xcodebuild xcresult. Three skips remain opt-in environment/visual gates.
- Current isolated preview: `com.taha.Attic.taskpanels.v2`, executable `AtticTaskPanelsV2`, PID 38614 at verification; real mapped debug dylib recorded in `TaskPanelV2IntegrationLive.md`. Branch/HEAD and dirty source provenance above remain unchanged except documented patches.
- Targeted final live checks: pin/unpin, family open/close/reopen, normal-file picker import and immediate gallery update. Open clicked/latched panel CPU sample: average 0.493% of one core over 15 seconds; not a measurement of true hover-origin protected editing. Earlier hidden-idle RSS/CPU sample predates the final fixes and is not a final memory-leak measurement.
- Remaining manual/instrumented gates: physical two-finger dismissal/cancellation/Reduce Motion; actual pointer corridor travel past pinned panels; native cross-window file/card drag sessions; keyboard-focused full-title disclosure and VoiceOver; full automated UI suite. Synthetic unit events and source review do not prove these.
- Source work and available automated verification are finished. Automatic polling is paused to avoid spending resources on unchanged manual gates. No merge, push, release, official app replacement, or user-store reset was performed.
- Historical sections below preserve the evidence available at each stage; their earlier pending/unrun wording is superseded by this final status table where the same gate was later completed.

## Batch 1 — R1 + R8

Diff: `.build/batch1.diff` (cumulative, against the snapshot tree; includes untracked files;
excludes the orchestrator/reviewer-owned `TaskPanelV2ReviewCriteria.md`,
`TaskPanelV2Batch1Review.md` and `TaskPanelV2Batch1Live.md`). Fix delta only:
`.build/batch1-fixes.diff` (see "Review findings / fixes").

### Changed files

- `Attic/Views/Panel/TaskRowView.swift` — row layout, title, metadata, ellipsis, click handling,
  row help, focus title disclosure (`TaskTitleDisclosure`, `TaskTitleExpansion`).
- `Attic/Views/Panel/TaskFamilyView.swift` — doc comment only.
- `Attic/Window/SubtaskPanelController.swift` — source-row press is not an outside click.
- `Attic/Design/AtticStyle.swift` — `AtticGlassControlTreatment` policy for controls.
- `Attic/Views/Settings/AppearanceSettingsView.swift` — translucency copy.
- `AtticTests/SubtaskPanelControllerTests.swift`, `AtticTests/SettingsPresentationTests.swift` — new tests.
- `AtticUITests/AtticUITests.swift`, `AtticUITests/SubtaskHoverPinnedUITests.swift` — updated for
  passive progress, hover-revealed menu, pinned status (compiled, not run).
- `Docs/TaskPanelV2Ledger.md` — this file.

### Implementation

R1 rows
- [x] Non-editing title is one line (`lineLimit(1)`). `ViewThatFits` shows plain text when it
  fits; otherwise the clipped variant gets a 22 pt trailing gradient mask and a tooltip with the
  full title. Accessibility label is always the full title. Editing keeps the existing
  multi-line field (1–6 lines) and commit/cancel rules.
- [x] Row minimum height 42 pt as before; wrapping is gone, so height stays stable.
- [x] Tighter spacing: status→title 10 pt (was 12), title/metadata/menu 6 pt (was 12).
  Metadata stays trailing-aligned as in the reference image.
- [x] Attachment thumbnails and `N/M` progress are passive views (no `Button`, no button
  traits). Thumbnails expose one element labelled "N attached image(s)"; progress exposes
  label "Subtasks", value "N of M complete". Both keep their identifiers.
- [x] Attachment access kept: "Attach images…" and new "Show attached images" in the task
  menu/context menu, which present the existing `TaskImageAttachments` popover anchored on the
  thumbnails.
- [x] Ellipsis menu always laid out (24×24). Its glyph shows only on row hover or keyboard focus
  of a row control (status, pinned status, menu), together with the hover surface. While hidden
  it is `allowsHitTesting(false)` and `accessibilityHidden`. The context menu keeps the actions.
- [x] Hover surface: `RoundedRectangle(cornerRadius: 10, style: .continuous)` (was 8). The hit
  shape stays the full rectangle.
- [x] Clicking a top-level row calls the existing `openFamilyPanel(for:focusEntry: false)`.
  That opens and latches the transient, raises a detached or pinned panel, and never toggles
  closed. One tap recognizer reads `NSApp.currentEvent.clickCount`: 1 opens (top-level only),
  2 keeps the double-click status shortcut (parent and child), and editing ignores clicks.
  Rows expose the accessibility action "Show subtasks" / "Reveal pinned panel".
- [x] `SubtaskPanelController.noteOutsideMouseDown` ignores presses on the open family's own
  visible source row. Without this, a row click on a latched panel would close it on mouse-down
  and reopen it on mouse-up.
- [x] Pinned status: a tiny muted `pin.fill` glyph right after the title, shown only while the
  family is pinned. Tooltip and label "Panel pinned". Activating it calls `openFamilyPanel`,
  which raises the existing pinned window and never creates a transient. Pin and unpin stay
  in the subpanel.
- [x] Drag (`.draggable`), drop/reorder, completion confirmation, delete confirmation, rename
  focus restoration and image import are unchanged. Child rows use the same view.

R8 surface vs controls
- [x] `AtticGlassControlTreatment.resolve(reduceTransparency:supportsNativeGlass:)` (fix F1 removed
  the surface inputs):
  - Reduce Transparency → opaque.
  - No native glass (pre-macOS 26) → material.
  - Otherwise → native Liquid Glass for every translucency and glass style, Glassmorphism included.
  - Before batch 1, translucency off made all controls opaque and Glassmorphism used material.
- [x] `atticGlassEffectContainer` uses the same policy, so solid mode keeps the glass container.
- [x] Panel surface treatment (`AtticPanelSurface`, `surfaceTreatment(isTranslucent:)`) untouched.
- [x] Settings row description: "Changes the panel surface. Controls always use Liquid Glass."
  The solid-mode glass description adds "Controls still use Liquid Glass."

No new timers, polling, observers or image work. Hover/focus changes only toggle state in
existing row bodies. No persistence, settings keys, entitlements, `ATTIC_LOCAL_ONLY`,
signing or store changes.

### Checks (implementer)

Commands were run from the worktree. Logs are in `.build/batch1/`.

- `xcodebuild build -project Attic.xcodeproj -scheme Attic -configuration Local -destination
  'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO`
  → BUILD SUCCEEDED (`build-local-3.log`, final source).
- `xcodebuild test … -only-testing:AtticTests` → 694 tests, 3 skipped, 0 failures
  (`unit-tests-2.log`, `Batch1Unit-2.xcresult`). This ran on the final source except the last
  change (row `contentShape` reverted to `Rectangle`).
- Focused re-run on final source: SubtaskPanelControllerTests, SettingsPresentationTests,
  SubtaskPanelTests, SubtaskTests, TaskImageTests, AppSettingsTests,
  PanelSurfaceHostingViewTests and TaskStoreTests → 208 tests, 0 failures
  (`unit-tests-focused-3.log`).
- New tests (all pass):
  - `testRowClickResolvesToOpenOrStatusShortcut`
  - `testRowActivationLatchesHoverOpenedPanelInsteadOfClosing`
  - `testRowActivationForChildlessParentOpensAndPinnedFamilyRaisesWithoutDuplicate`
  - `testChildRowCannotOpenNestedPanel`
  - `testSourceRowPointIsRecognizedOnlyForVisibleAnchor`
  - `testTranslucencyChangesSurfaceOnlyWhileControlsStayLiquidGlass`
- `xcodebuild build-for-testing -scheme AtticUI … CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` →
  TEST BUILD SUCCEEDED (`uitest-compile-3.log`). UI tests were compiled, not run; Sol owns live UI.
- `/opt/homebrew/opt/ruby/bin/ruby Scripts/verify_project_generation.rb` → current and
  repeatable. No project inputs changed. System Ruby 2.6 lacks the `xcodeproj` gem.
- `git diff --check` → clean.

### Review findings / fixes

Sources: `Docs/TaskPanelV2Batch1Review.md` (Sol medium: 2 × P2 + 1 observation) and
`Docs/TaskPanelV2Batch1Live.md` (Sol low: 3/4 focused native tests pass, 1 failure).

Pre-fix snapshot tree (temporary index, no ref): `e4ec3474f0c67547095e6c64151f6d266b5fa76d`
(`.build/batch1-fixes/prefix-tree.txt`). Fix delta: `.build/batch1-fixes.diff` against that tree.
Logs are in `.build/batch1-fixes/`.

F1 — P2, Glassmorphism moved controls off Liquid Glass. **Fixed.**
- `Attic/Design/AtticStyle.swift`: `resolve` no longer takes `isTranslucent` or `glassStyle`, so no
  surface setting can change control treatment. `.opaque` only for Reduce Transparency; `.material`
  only when native glass is unavailable. `atticGlassEffectContainer` uses the same policy. The two
  modifiers no longer read the glass-style/translucency environment, so a surface change no longer
  invalidates every control. Panel surface code is untouched.
- `AtticTests/SettingsPresentationTests.swift`: the test that encoded the Glassmorphism exception
  now checks the complete input table (2 × 2) and the settings copy.

F2 — P2, keyboard focus did not expose a clipped title. **Fixed (source + state tests; needs live).**
- `TaskTitleDisclosure.isClipped(idealWidth:renderedWidth:)` compares the title's single-line ideal
  width (hidden measuring copy) with its rendered width, via `onGeometryChange`. The
  `ViewThatFits` layout Sol validated live is unchanged. Tolerance is 0.5 pt.
- `TaskTitleDisclosure.showsFullTitle` = clipped ∧ a row control has focus ∧ not editing. Short
  titles never get an overlay. Hover keeps the existing tooltip.
- `TaskTitleExpansion` works like an AppKit expansion tooltip. A borderless, non-activating,
  mouse-transparent, accessibility-hidden child window lays the same `task.title` over the row. Its
  first line sits on the clipped title, and the text wraps within the title column (minimum 200 pt).
  The row height and metadata never change, and the list's scroll view can't clip it. It is created
  only while presented, over a visible key window, with a non-empty visible anchor. It follows row
  frame changes and scroll-clip bounds changes. It is removed on key loss, when focus leaves, when
  editing starts, on scroll-out, and on dismantle. Material, or opaque window background under
  Reduce Transparency; stronger edge under Increased Contrast. No timers or polling.
- Test: `testKeyboardFocusDisclosesOnlyClippedTitlesOutsideEditing`.

F3 — observation, row help described only the double-click shortcut. **Fixed.**
- `TaskRowClick.help`: top-level rows show "Click to show subtasks" or "Click to reveal the pinned
  panel", followed by the status's double-click hint when one exists. Done has none. Child rows
  keep exactly their previous `doubleClickTitle` help. The status button keeps its own help.
- Test: `testRowHelpLeadsWithOpenActionAndKeepsDoubleClickShortcut`.

F4 — live failure `AtticUITests.testCompactComposerAndSubtaskPanels` at Escape-cancel. **Test
sequencing defect, not a product regression. Fixed in the test without weakening assertions.**
- Evidence (`.build/batch1-live/FocusedUI.xcresult`, activity log and failure hierarchy
  `FocusedUIAttachmentsAll/2A821370-….txt`): the step after Escape shows `quick-entry-title` and
  `task-entry-bar` as **Keyboard Focused**. `subtask-title-<parent>` is present with `Draft step`
  but not focused. No click on the entry came between the reopen and `typeKey(.escape)`. The
  Escape went to the main panel's quick-entry field, so the entry's `.onExitCommand` never ran.
- Cause: the test clicks `quick-entry-title` to dismiss the latched panel, which gives that field
  keyboard focus. It then reopens via the row, which calls `openFamilyPanel(for:focusEntry: false)`.
  That path presents with `orderFrontRegardless` and never calls `makeKey` or
  `activateSubtaskEntry`, so it never moves keyboard focus.
- Baseline proof (snapshot `b6d6dab`): the replaced progress control's action was
  `toggleFamilyPanel(for:)` (`TaskRowView.swift:218`). With the panel already dismissed, that
  reaches the same `openFamilyPanel(for:focusEntry: false)`, so Escape would have gone to the same
  quick-entry field. Batch 1 did not change focus behavior. The baseline ledger records the
  Escape/draft UI-test rewrite as "SCRIPT-VERIFIED; UNRUN". It lists `AtticUITests` outside
  `SubtaskHoverPinnedUITests` as "untouched by this branch but unverified here"
  (`Docs/HoverPinnedSubtasksVerificationLedger.md`). No baseline result bundle contains this test.
  The Escape step had never passed.
- Behavioral intent kept: the approved design keeps the draft on focus loss and outside dismissal.
  Escape cancels only from inside the entry. Explicit opens without an entry request don't steal
  focus. "Add subtask…" (`focusEntry: true`) keeps making the surface key. So the test now clicks
  into the entry, re-asserts `Draft step`, then presses Escape. Every original assertion stays: the
  affordance appears, the entry collapses, and the affordance reopens and focuses the entry.
  Latched/outside-click and source-row behavior are unchanged.
- Not changed: making a row click steal focus into a drafting entry. That would pull focus out of
  the quick-entry field on every family reopen. The contract doesn't ask for it.

Checks on fixed source (no UI run, no full suite):
- `xcodebuild build … -configuration Local … CODE_SIGNING_ALLOWED=NO` → BUILD SUCCEEDED
  (`build-local-1.log`); no new warnings in touched files.
- `xcodebuild test … -only-testing:` SettingsPresentationTests, SubtaskPanelControllerTests,
  SubtaskTests, AppSettingsTests → 127 tests, 0 failures (`unit-focused-1.log`,
  `FixesFocused-1.xcresult`).
- `xcodebuild build-for-testing -scheme AtticUI … CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` →
  TEST BUILD SUCCEEDED (`uitest-compile-1.log`). Not run; Sol owns the live re-run.
- No project inputs changed (no new files), so project regeneration was not needed. `git diff
  --check` → clean.
- Diffs were generated from a temporary index (`read-tree HEAD`, `add -A`, `write-tree`; the real
  index was not touched), with the three orchestrator/reviewer docs excluded. Tree IDs, file lists
  and SHA-256 digests are in `.build/batch1-fixes/diffs.txt`, generated after this ledger text.

F5 — fix-delta P2, every visible row observed key changes and scrolling. **Fixed.**
- Source: `Docs/TaskPanelV2Batch1Review.md` "Fix-delta review". Pre-change tree (temporary index,
  no ref): `7c9d6a626ae8e82bae6c8521005e9fb0f5fa2a2a` (`.build/batch1-observers/prefix-tree.txt`).
  Delta: `.build/batch1-observers.diff`. Logs: `.build/batch1-observers/`.
- `TaskTitleExpansion.AnchorView` no longer registers on `viewDidMoveToWindow`. Every `refresh`
  first calls `updateObservation`. The target is the anchor's window only while
  `configuration.isPresented`, plus that window's enclosing clip view. If the target identity
  matches the current set, nothing changes. Otherwise the old set is removed and, if presented in a
  window, one set is installed: become key, resign key, clip bounds.
- So unfocused rows hold zero observers. Presentation ending (focus loss, editing, title no longer
  clipped), leaving or changing window, and dismantle remove the set immediately. Dismantle also
  clears the configuration, so a later window move cannot re-register.
- Kept deliberately: the set survives key loss and scroll-out while still presented. The panel is
  hidden then, and the observers are what bring the title back on key gain or scroll-in. This is
  the same key-loss/clipping lifecycle as before, now for one focused row only. No polling;
  `NSClipView` bounds notifications are on by default (reviewer-verified runtime). Panel
  creation, placement, label and appearance are unchanged.
- Test seam: read-only `observerCount`. Test `testTitleExpansionObservesOnlyWhilePresentedInWindow`
  uses a real window, scroll view and two anchors. It checks: an unpresented row joining a window
  → 0; presented → 3, while the sibling stays 0; a repeated update does not stack; resign key and
  a clip scroll keep 3; presentation false → 0; removal from the window → 0; rejoining while
  presented → 3; `tearDown` → 0; re-adding a dismantled anchor → 0. The pre-fix code would fail
  the first assertion (3 observers on join).

Checks on F5 (separate derived data `.build/batch1-observers/DerivedData`; the preview and shared
`.build/DerivedData*` outputs were not touched; no UI was driven):
- `xcodebuild test … -configuration Local … -derivedDataPath .build/batch1-observers/DerivedData
  CODE_SIGNING_ALLOWED=NO -only-testing:AtticTests/SubtaskPanelControllerTests` → 54 passed,
  0 failed, 0 skipped (`unit-focused-1.log`, `ObserversFocused-1.xcresult`). This suite holds the
  new lifecycle test and the existing title-disclosure and row tests. Broader suites were not
  repeated: only `TaskRowView.swift`'s AppKit anchor and this test file changed.
- `xcodebuild build … -configuration Local … CODE_SIGNING_ALLOWED=NO` → BUILD SUCCEEDED
  (`build-local-1.log`). No warnings in the touched files.
- UI-test compile not repeated: no UI-test source and no accessibility identifier changed.
  No project inputs changed, so no regeneration. `git diff --check` → clean.
- Diffs come from temporary indexes, with the same three orchestrator/reviewer docs excluded;
  digests are in `.build/batch1-observers/diffs.txt`. One stray `git write-tree` ran against the
  real index while the prefix was being snapshotted. It wrote only a tree object, and staged
  content still equals HEAD. At most it refreshed the index's cache-tree extension.
- Live validation still needed: the title appears on FKA focus and follows scrolling, hides on key
  loss and returns on key gain, and hides on scroll-out and returns on scroll-in, for parent and
  child rows.

### Unverified — needs live validation (Sol)

These are not proven by source, build or unit tests:
- Rendered fade, spacing, pinned glyph size and contrast across themes.
- Liquid Glass controls in solid, clear, frosted and glassmorphism modes, and with Reduce
  Transparency.
- Whether `onTapGesture` fires for the second click of a double-click, so the status shortcut
  still works (AtticUITests `doubleClick` path).
- Whether the tap recognizer interferes with parent/child drag reorder.
- Whether the borderless `Menu` label updates its glyph opacity live, and stays visible while
  its menu is open.
- Whether `.focused` on the `TaskStatusButton` wrapper reveals row affordances under Full
  Keyboard Access, and whether `accessibilityHidden` changes Tab order.
- F2 focus disclosure: appears only for clipped titles under FKA forward and reverse traversal. Check
  position and wrapping at minimum and maximum panel widths, in child rows inside the subpanel, while
  scrolling, on key loss and panel hide, and under Reduce Transparency, Increased Contrast and every
  theme. Also check that it never intercepts clicks or appears in VoiceOver.
- F1: interactive controls on native Liquid Glass across solid, clear, frosted and Glassmorphism
  surfaces; opaque under Reduce Transparency; pinned glass weight.
- F3: row tooltip wording on blank row space for parent, pinned parent and child rows.
- F4: `testCompactComposerAndSubtaskPanels` re-run end to end (Escape through delete).
- VoiceOver: row actions, passive metadata values, and the pinned status hint.
- Updated UI tests: hover-then-menu helpers, pinned-status test, and row click replacing the
  progress button.

### Interpretations and open risks

- Full title: accessibility label, hover tooltip when clipped, focus disclosure when clipped (F2),
  and Edit title. If a mouse click gives a row control focus (for example with FKA on), the
  disclosure shows for that focus too.
- F2 adds two width measurements per row. Each changes state only when a width changes, so it costs
  one extra body pass at first layout.
- Editing still grows up to 6 lines so the full title stays editable. Row height is stable
  outside editing only.
- Clicking a childless top-level row opens the empty family panel ("No subtasks yet"). Hover
  still opens only families with children or drafts.
- A press on the source row (status button, menu, blank area) no longer dismisses that row's
  latched panel. Clicks elsewhere still dismiss it.
- A pinned glyph appearing on a long title narrows the faded title. The importing spinner
  still inserts itself as before.
- After F1, Glassmorphism affects only the surface; its controls use native glass like every other
  style. No separate "heavier pinned glass" code exists; pin controls keep the interactive
  `atticGlassControl`.
- Leftover dead path: rows no longer publish `TaskSubtaskControlFramePreferenceKey`, so the
  controller's `controlFrames` / `lastOutsideDismissal` suppression never engages.
  `toggleFamilyPanel` remains (tests only). Batch 2 can remove it with the panel rework.

## Batch 2 — R2 + R3

Diff: `.build/batch2.diff`, against pre-batch tree `11866767fbc5a85c261f3a3ed755855b502ad27c`
(temporary index `.build/batch2/prefix.index`, no ref, real index untouched; includes nonignored
untracked files). That tree equals the batch-1 observer fix's `current_tree`, so the independently
reviewed `.build/batch1-observers.diff` is preserved unchanged. Excluded from the diff: the
orchestrator/reviewer-owned `TaskPanelV2ReviewCriteria.md`, `TaskPanelV2Batch1Review.md`,
`TaskPanelV2Batch1Live.md`, and `TaskPanelV2Requirements.md`. The orchestrator changed the last one
during this batch (review-process wording only; no product requirement changed). Tree IDs, file
list and SHA-256 are in `.build/batch2/diffs.txt`. Logs are in `.build/batch2/`. Derived data is
`.build/DerivedData`. `.build/TaskPanelsV2Preview` was not touched, and no UI was driven.

### Changed files

- `Attic/Models/TaskItem.swift` — `images` renamed to `attachments`. Storage field unchanged.
- `Attic/Models/TaskImageReference.swift` — `contentType`/`isImage`; `importAttachments` (validates
  only image-typed files), `verifiedURL(for:)`; thumbnails only for images.
- `Attic/Models/TaskDragPayload.swift` — `TaskAttachmentDragItem` (drag-out of one attachment).
- `Attic/Services/TaskStore.swift` — `attachFiles(_:to:)` (resolves to parent, returns success),
  `attachmentOwnerID(for:)`, `removeAttachment(_:from:)`, `importingAttachmentTaskIDs`,
  task-worded limit errors, `reportUnavailableAttachment(named:)`.
- `Attic/Services/NoteAttachmentPlatformSupport.swift` — `isSafeToOpen(contentTypeIdentifier:)`
  extracted and shared; Notes behavior unchanged.
- `Attic/Services/SubtaskPanelLayout.swift` — `FamilyPanelView`, gallery metrics, shared
  `contentHeight(for:…)`, switch timing, footer control size.
- `Attic/Window/SubtaskPanelController.swift` — `FamilyPanelViewState`, `panelView(for:)`,
  `showPanelView(_:for:)`, `openFamilyPanel(…, view:)`, view retention rules, animated height-only
  frame changes.
- `Attic/Views/Panel/SubtaskPanelContent.swift` — two views, view switch beside composer,
  Add attachment composer, ideal-height sizing.
- `Attic/Views/Panel/TaskImageAttachments.swift` — `TaskAttachmentGlyph`, `TaskAttachmentPicker`,
  `TaskAttachmentActions`, `TaskAttachmentGallery`, `TaskAttachmentCard`, `TaskAttachmentsPopover`
  (replaces the image-only popover).
- `Attic/Views/Panel/TaskRowView.swift` — passive file/image metadata; menu “Add attachment…” and
  “Show attachments”; legacy subtask attachment popover; row `fileImporter` removed.
- Tests: `AtticTests/TaskImageTests.swift`, `AtticTests/SubtaskPanelTests.swift`,
  `AtticTests/SubtaskPanelControllerTests.swift`, `AtticUITests/AtticUITests.swift`.
- `Docs/TaskPanelV2Ledger.md` — this section.

No new files, so no project inputs changed. There are no model schema, settings keys,
entitlements, `ATTIC_LOCAL_ONLY`, signing, store or bundle identity changes. No dependencies,
frameworks, timers or pollers were added.

### Implementation

R2 unified family panel
- [x] Still one surface per family: the transient or its pinned window. Pin keeps the live window
  and its position. Reveal raises the existing pinned window. The lifecycle and corridor code are
  unchanged.
- [x] Exactly two views, `FamilyPanelView.subtasks` and `.attachments`. The header (title,
  “N of M complete”, pin/unpin/close) is shared and stays put.
- [x] Footer: the view's composer capsule (`Add subtask…` / `Add attachment…`, glass,
  non-interactive as before) plus a circular interactive glass switch. The switch shows the
  destination: `photo.on.rectangle` → “Show attachments” on Subtasks, `checklist` → “Show subtasks”
  on Attachments. Identifier `subtask-view-switch-<id>`.
- [x] View state lives in `FamilyPanelViewState`, a separate `ObservableObject` observed only by
  panel content. A switch doesn't invalidate every row that observes the controller.
- [x] Fresh open starts on Subtasks. `syncState` drops the view of any family left without a
  surface (dismissal, outside click, main-panel hide, close pinned, delete, hover browsing to
  another family). So the next open reads the default.
- [x] Keeps the view: hover enter/leave on its own row, pointer in/out of the surface, row-frame and
  main-panel movement, repeated row click or pinned-marker reveal, window drag (detach), pin,
  pinned reveal, unpin. Unpin restores the retained view explicitly, because its inner transient
  close runs `syncState`.
- [x] Explicit requests: “Show attachments” opens on Attachments. “Show subtasks” and “Add subtask…”
  (`focusEntry`) always show Subtasks. On a pinned family they switch that window.
- [x] Motion: `withAnimation` changes the view. A short 18 pt directional offset plus crossfade
  (0.22 s). Reduce Motion uses fade only (0.15 s).
- [x] Sizing: both views use `SubtaskPanelLayout.contentHeight`, which is natural height capped at
  the existing `maximumListHeight` (240), then scrolling.
  - Subtasks uses the existing measured or estimated list height.
  - Gallery height is arithmetic over fixed card metrics, so the target is known before render.
  - Content declares `frame(minHeight: 0, idealHeight:, maxHeight: .infinity)`. `fittingSize`
    gives the target, and the surface fills the window. The painted squircle, hit shape and footer
    move with the window frame.
- [x] Height animation: `applyFrame` animates a visible window when the top edge and width hold
  (`NSAnimationContext`, 0.22 s, ease-in-out). Anything that moves the surface (anchor tracking,
  display clamps, overlap avoidance) applies at once and stops an in-flight animation with a
  zero-duration animator update. In-flight targets are tracked per window, so repeated re-fits
  toward the same target don't restart the animation. Reduce Motion applies at once.
- [x] Latched and dragged panels still stay until an outside click. The file picker marks
  `presentedTaskAttachmentsID`, which the outside-click and hover-close paths already honor.

R3 attachments
- [x] Storage: images and general files share the existing parent-owned `imageReferencesData` JSON
  (`TaskImageReference`, keys unchanged) in private Application Support `Attic/TaskImages`, through
  the existing `AttachmentFileStore`.
  - Security-scoped access, coordinated chunked copy, digest, staging and batch rollback are
    unchanged.
  - Image-typed files must still decode; other regular files are accepted.
  - Limits stay 20 files / 15 MiB each / 100 MiB, now with task wording.
- [x] Ownership: `attachFiles` resolves a subtask to its parent (`attachmentOwnerID`), so there is
  no nested owner. It writes every replica with one save. If the save fails or throws, it rolls back
  (`save()`) and deletes only the new private copies. `removeAttachment` updates every replica, and
  deletes the private copy only after a successful save. Originals are never moved or deleted.
- [x] Compatibility: stored image references and old drag payloads decode unchanged and appear as
  image cards. Attachments stored on a subtask by an earlier build stay on that subtask. They
  remain viewable, draggable and removable through the row's “Show attachments” popover, which
  reuses the gallery.
- [x] Picker: one `NSOpenPanel` for `public.data`, multiple selection, no folders. Used by the panel
  composer and the row menu. On success it shows the family's Attachments view. It replaces the
  image-only row `fileImporter`, so the “Attach images…” capability is kept as “Add attachment…”.
- [x] Gallery: two columns of fixed 100 pt cards. Image cards show a 256 px thumbnail (existing
  bounded actor cache, loaded by digest, cancelled with the view). File cards show the system type
  icon. Both show filename (middle truncation) and size. One image is a half-width card, so it
  can't dominate the panel.
- [x] Card interactions:
  - Pointer: a click previews in Quick Look.
  - Hover or keyboard focus shows a small glass remove ×.
  - Keyboard: focusable like a button (`interactions: .activate`). Space/Return previews and Delete
    removes.
  - Context menu and VoiceOver actions: Quick Look, Open (only for types `isSafeToOpen` allows),
    Remove.
  - Quick Look and Open use the digest-verified private copy. A missing or changed copy shows a
    calm error instead.
- [x] Drag-out:
  - Each card drags as `TaskAttachmentDragItem` (`FileRepresentation`, `public.data`). The
    receiver gets a copy made only when the drop resolves (`allowAccessingOriginalFile: false`).
  - Row drag still exports title plus every attachment.
  - Row thumbnails remain passive metadata; images show thumbnails and files show type icons.
- [x] No work on resize: thumbnails key on digest and pixel size, and layout reads no file data.
  `ByteCountFormatter` and the system icon lookup are the only per-card body work.

R8 carry-over: switch, remove × and composer use `atticGlassControl`, so they stay native Liquid
Glass in every surface mode and opaque under Reduce Transparency (batch-1 policy).

### Stale UI test corrected (Batch1Review “Bounded live-failure investigation”)

`AtticUITests.testCompactComposerAndSubtaskPanels`:
- Removed the wrong `panel-error-message` expectation. The flow now asserts the confirmation title
  “Complete this task?”, its unfinished-subtask message, both “Complete anyway” and “Cancel”, and
  that no error banner exists.
- Cancel branch: the parent stays in To do (To do · 1, Done · 0), and progress stays
  “1 of 2 complete”.
- Complete anyway branch: the parent moves to Done (Done · 1, To do · 0). Progress stays
  “1 of 2 complete”, so the unfinished child stays unfinished, and “Book accommodation” still exists.
- The parent is then reopened (To do · 1, progress unchanged). The original second-child
  completion, Done/To do toggles and delete flow follow unchanged.
- Batch-1 Escape focus fix and every earlier assertion kept.
- New panel flow in the same test:
  - The switch exists and reads “Show attachments”. Activating it shows `add-attachment-<id>` and
    `subtask-attachments-<id>`, removes the subtask entry, and relabels the switch
    “Show subtasks”.
  - Hovering, then clicking, the parent row keeps Attachments.
  - After outside-click dismissal, reopening from the row starts on Subtasks with the retained
    draft.

### Checks (implementer)

- `xcodebuild build -project Attic.xcodeproj -scheme Attic -configuration Local -destination
  'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO` →
  BUILD SUCCEEDED (`build-local-3.log`). No warnings in touched files. Attempts 1–2 failed to
  compile: a duplicate `preview` name, then a type-check timeout. Both were fixed by splitting the
  card body.
- Focused `xcodebuild test … -only-testing:` TaskImageTests, SubtaskPanelTests,
  SubtaskPanelControllerTests → 108 tests, 0 failures (10 + 39 + 59; `unit-focused-2.log`,
  `Batch2Focused-2.xcresult`). One small card focus modifier and gallery property change came
  after this run; the full run below covers it.
- Full `xcodebuild test … -only-testing:AtticTests` on final source → 711 tests: 708 passed,
  3 skipped, 0 failed, no runtime warnings (`unit-tests-1.log`, `Batch2Unit-1.xcresult`).
- `xcodebuild build-for-testing -scheme AtticUI -configuration Local … CODE_SIGN_IDENTITY=-
  DEVELOPMENT_TEAM=` → TEST BUILD SUCCEEDED (`uitest-compile-1.log`). Compiled, not run.
- `/opt/homebrew/opt/ruby/bin/ruby Scripts/verify_project_generation.rb` → repeatable and current.
  No project inputs changed, so no regeneration was needed.
- `git diff --check` → clean.
- New tests:
  - `testImagesAndGeneralFilesAttachTogetherAndStayUsableAfterRelaunch`: image and text together,
    fresh store, types, thumbnail only for images, private verified copy is not the original,
    tamper refusal, export, original kept.
  - `testSubtaskAttachmentsResolveToTheParent`
  - `testAttachAndRemoveApplyToEveryPhysicalDuplicate`
  - `testFailedFileSaveRollsBackAndRemovesOnlyTheNewPrivateCopies`: also covers a failed removal
    keeping its reference and copy.
  - `testTaskLimitErrorsUseTaskWording`
  - `testLegacyImageReferencesDecodeAsImageAttachments`
  - `testOnlyOpenableFileTypesMayOpen`
  - `testBothViewsShareTheListMaximumAndSizeToTheirContent`
  - `testViewSwitchNamesItsDestination`
  - `testFreshOpenStartsOnSubtasksAndMovementKeepsTheChosenView`
  - `testPinUnpinAndPinnedRevealKeepTheSamePanelView`
  - `testExplicitViewRequestsAndSubtaskEntryChooseTheirView`
  - `testBrowsingToAnotherFamilyOpensItOnSubtasks`
  - `testPanelContentIdealHeightFollowsTheActiveView`: real `SubtaskPanelContent` in a hosting view.
    A 10-child list versus a one-file gallery changes the ideal height by exactly
    `maximumListHeight − galleryContentHeight(1)`, returns on switch back, and doesn't follow a
    shorter current frame.

### Unverified — needs live validation

Not proven by source, build or unit tests:
- Rendered footer: capsule/switch proportions against `subtasks.png`/`gallery.png`, symbol replace,
  glass in solid/clear/frosted/glassmorphism, Reduce Transparency, Increased Contrast, themes.
- View-switch motion: slide/crossfade feel, anchored top edge, window height animation in sync with
  content, no flicker of painted versus hit shape mid-animation, Reduce Motion fade. Both for the
  transient attached to a row and for detached and pinned windows, including near the bottom of the
  display, where the clamp applies at once.
- Gallery: card legibility, thumbnail crop, file icons, scrolling past 4 items, card insert and
  remove animation after import and removal.
- `NSOpenPanel` from a nonactivating transient or pinned panel: appears in front, the family panel
  and main panel stay open while it's up, and Cancel and Attach both restore cleanly. Importing
  spinner and label.
- Card interactions: Quick Look on click, × on hover, context menu, Full Keyboard Access focus and
  Space/Return/Delete, VoiceOver label and actions.
  - Whether interacting with the Quick Look window dismisses a latched transient (it counts as an
    outside click; pinned windows are unaffected).
- Drag-out of a card to Finder and other apps (file copy name and type). Parent and child task row
  drag and reorder are still unaffected. Card drag vs click inside the panel.
- `testCompactComposerAndSubtaskPanels` end to end, including both confirmation branches and the
  new view-switch steps.
- Legacy: a store with image attachments from the baseline build (parent and subtask) shows them
  and removes them correctly.

### Interpretations and open risks

- Hover browsing: an open latched transient still switches family when another family row is
  hovered, as before. The existing test `testHoverSwitchWhileOpenUsesFastDwellThroughTheController`
  encodes this. The browsed-to family opens fresh on Subtasks, and the family left behind forgets
  its view. I read R2 “neutral row hover never unexpectedly switches panel content” as applying to
  the view of an open family, which hover never changes. If the orchestrator reads it as “hover must
  not replace a latched family”, that is a lifecycle change for batch 4 (R6) and needs that test
  changed deliberately.
- Hover opening is still limited to families with children, drafts or an active entry. A family
  with only attachments opens by row click or menu.
- Remove × deletes immediately, as the replaced image popover did. There is no confirmation.
- Unchanged, flagged: attachments on a deleted task are removed after save, while attachments of a
  failed import are removed before any reference exists. There is no background orphan
  reconciliation for `Attic/TaskImages` if the app quits between a successful save and the async
  delete. Pre-existing; not changed here.
- The header subtitle reads “N of M complete” in both views, as in the reference gallery image.
- R4/R5 are not started. Existing drop behavior is untouched: task reorder drop on rows, and Notes
  and Canvas drop paths. No row or panel drop-to-attach exists yet.
- Batch-1 leftover `toggleFamilyPanel`/`controlFrames` dead path is still present (tests use it).

### Review findings / fixes

Sources: `Docs/TaskPanelV2Batch2SWE-A.md` (approved; six P3) and `Docs/TaskPanelV2Batch2SWE-B.md`
(approved; F1 contract question, F2–F5 P3, observations). Root ruling on SWE-B F1 recorded in
`Docs/TaskPanelV2Orchestration.md`. Reports were not edited.

Pre-fix snapshot tree (temporary index `.build/batch2-fixes/prefix.index`, no ref, real index
untouched, nonignored untracked files included): `11ad5b5cd293f65cdb7946a374031c880729c402`. It
differs from batch 2's `current_tree` only by the reviewer/orchestrator documents (SWE-A, SWE-B,
Orchestration, Requirements wording). Fix delta: `.build/batch2-fixes.diff`, excluding those
documents, `TaskPanelV2ReviewCriteria.md`, `TaskPanelV2Batch1Review.md` and
`TaskPanelV2Batch1Live.md`. Tree IDs, file list and SHA-256 are in `.build/batch2-fixes/diffs.txt`.
Logs and evidence are in `.build/batch2-fixes/`. `.build/TaskPanelsV2Preview` was not touched and
no UI was driven.

Changed files: `Attic/Services/AttachmentFileStore.swift`, `Attic/Models/NoteAttachment.swift`,
`Attic/Models/TaskImageReference.swift`, `Attic/Models/TaskDragPayload.swift`,
`Attic/Services/TaskStore.swift`, `Attic/Services/SubtaskPanelLayout.swift`,
`Attic/Window/PanelUIState.swift`, `Attic/Window/SubtaskPanelController.swift`,
`Attic/Views/Panel/SubtaskPanelContent.swift`, `Attic/Views/Panel/TaskImageAttachments.swift`,
`Attic/Views/Panel/TaskRowView.swift`, `AtticTests/TaskImageTests.swift`,
`AtticTests/SubtaskPanelControllerTests.swift`, this ledger. No new files, so no project inputs
changed. No schema, stored keys, settings keys, entitlements, `ATTIC_LOCAL_ONLY`, signing, store or
bundle identity changes.

FX1 — import kept every file's payload only to validate images (SWE-A P3-5, SWE-B observation). **Fixed.**
- Cause: `AttachmentFileStore.importOne` re-read each final file into `payload`
  (`Data(contentsOf:options: .mappedIfSafe)`) and `importFiles` returned all of them together. The
  task path used payloads only for `CGImageSourceCreateWithData` on image-typed files, then
  dropped them. A maximum batch (20 × 15 MiB) held up to ~300 MiB of mappings at once. Validating
  an image paged its whole file in, and on volumes where mapping isn't safe the read was a heap
  copy. Every general file paid a second full read for nothing.
- `importFiles(…, includePayload:)` overload. The existing signature (Notes and the
  `NoteAttachmentFileImporting` protocol) forwards `includePayload: true`, so Notes behavior is
  unchanged. `ImportedAttachment.payload` is now `Data?`, nil when not requested.
- `TaskImageFiles.importAttachments` imports with `includePayload: false`. It then validates each
  image-typed reference, one at a time, from its private copy with `CGImageSourceCreateWithURL`
  (`kCGImageSourceShouldCache: false`) and `CGImageSourceGetCount > 0`. That is the same predicate,
  and ImageIO reads the file incrementally.
- Rollback unchanged: any failure removes every reference in the batch and throws
  `fileReadCorruptFile`. Staging and final-directory rollback inside the actor is untouched.
- Integrity evidence: `.build/batch2-fixes/imageio-equivalence.txt` compares the data-based and
  URL-based checks on 8 inputs, and the verdicts match on all 8. Inputs: text named `.png`, valid
  PNG, PNG truncated to 40 bytes, PNG truncated to 8 bytes, JPEG bytes in `.png`, empty file,
  garbage `.jpg`, PNG bytes in `.heic`.
- Not changed: `verifiedMaterializedURL` still hashes a mapped file per preview, open or drag
  (SWE-A note; bounded by 15 MiB, mapped rather than copied).
- Test `testTaskImportReadsNoPayloadAndRejectsABatchWithABrokenImage`. The default import still
  returns payload bytes (the Notes path). `includePayload: false` returns nil payloads. A batch of
  valid PNG, text and broken image is rejected with zero private directories left and every
  original intact. The valid pair then imports with the right `isImage` flags. The existing
  `testCorruptImageIsRejectedAndLegacyTaskPayloadStillDecodes` and all 43 `NoteAttachmentTests`
  pass.

FX2 — drag-out promised `public.data` for every attachment (SWE-A P3-2). **Fixed.**
- Cause: `FileRepresentation(exportedContentType: .data)` is static per `Transferable` type.
  `.build/batch2-fixes/drag-type-control.txt` shows a provider registered as `public.data`
  failing conformance to `public.image` and `public.png`, so an image-only receiver refuses it.
- `TaskAttachmentDragItem` now builds an `NSItemProvider`. It registers one file representation
  under the attachment's recorded type (`public.data` if that type doesn't conform to data), with
  `suggestedName` set to the filename. Conformance still satisfies generic file receivers. There
  is no `.openInPlace`, so receivers get a copy, as with `allowAccessingOriginalFile: false`
  before. The verified private URL is resolved lazily when the drop loads, and nothing is copied
  on layout or resize. Cards use `.onDrag(_:preview:)` with the same preview.
- The task row drag (`TaskDragPayload`: internal ID, folder export, title) is unchanged.
- Test `testAttachmentDragPromisesItsRecordedTypeAndHandsOutACopy`: a PNG card registers exactly
  `public.png` and conforms to image, png and data. A text card conforms to plain text and data
  but not image. Loading as `public.image` yields a file that is not the private URL and holds the
  original bytes.

FX3 — picker/popover shared one mark: silent no-op and protection theft (SWE-A P3-3, SWE-B F3). **Fixed.**
- Cause: the picker and a child's legacy popover both wrote `presentedTaskAttachmentsID`. The
  picker's guard required it nil, but no affordance was disabled for that state. A popover opening
  over a live picker overwrote the picker's owner, so that family lost `familyEditBusy` protection.
- `PanelUIState.taskAttachmentPickerOwnerID` is the picker's own mark. It adds the same
  `.taskConfirmation` lock and is honored by `familyEditBusy`. Only the picker's completion clears
  it: section switches and task reconciliation leave it alone, because the `NSOpenPanel` is still
  up. `presentedTaskAttachmentsID` is now the popover's alone.
- `TaskAttachmentPicker.isAvailable(for:store:uiState:)` is true when the owner resolves, no picker
  is up and no import is in flight for that owner. The row menu item and the panel's Add
  attachment button are disabled exactly when it is false, and `choose` guards on it. So an
  offered click is never ignored, and a popover no longer blocks the picker.
- Test `testPickerAndChildPopoverKeepSeparateMarksAndNeitherSilentlyBlocks`.

FX4 — `frameAnimationTargets` could keep a dead window's entry (SWE-B F2, SWE-A note). **Fixed.**
- Cause: entries were keyed only by `ObjectIdentifier` and cleared by the completion handler,
  whose `weak surface` is nil after a close. Unpin also replaces the transient window without
  closing it. A later surface at the same address would read the dead target in
  `resizeDetachedSurface` and snap to the old window's frame.
- `SurfaceFrameAnimationTargets` holds each window weakly and returns a target only for that same
  live object. A mismatched or dead entry is dropped on lookup, and dead entries are pruned
  whenever a new target is set. Animation behavior is otherwise identical.
- Test `testFrameAnimationTargetsBelongToTheirLiveSurfaceOnly`: a released owner's entry isn't
  returned for a new owner and is pruned.

FX5 — outgoing view slid against the spatial model (SWE-A P3-1). **Fixed.**
- Cause: each view's removal offset was the negation of its insertion offset, so on a switch the
  two layers moved toward each other.
- `SubtaskPanelLayout.viewSwitchOffset(for:)` gives each view its own side: Subtasks −18,
  Attachments +18. The transition uses that offset for both insertion and removal, combined with
  opacity. Reduce Motion stays fade-only.
- Test `testViewSwitchPagesBothLayersTheSameWay` covers the offsets only. Motion is live-only.

FX6 — explicit view request on a hover-opened family snapped instead of animating (SWE-A P3-6). **Fixed.**
- Cause: `openTransient(latched: true)` returns true when the origin changes from hover to
  explicit, so `openFamilyPanel` took the fresh-open path. It set the view outside `withAnimation`
  and re-presented with `stopFrameAnimation`.
- When the transient already shows that family, the request now latches, syncs state (outside-click
  monitoring) and routes the view through `showPanelView`, which animates the content and re-fits
  the height. It then raises the window and honors `focusEntry` like the already-latched path. It
  does not re-present or snap the frame.
- Test `testExplicitViewRequestOnAHoverOpenedFamilySwitchesInPlaceAndLatches`: the view changes,
  and the panel is latched (it survives pointer leave). The animation itself is live-only.

FX7 — first fit used estimated chrome; Attachments-first and childless panels never re-fit (SWE-B F5). **Fixed.**
- Cause: the header and footer heights arrive by preference after the first layout. Only a list
  height measurement (children present) triggered the correcting re-fit.
- When a measured header or footer height changes by more than 0.5 pt, `SubtaskPanelContent` calls
  `noteChromeMeasured(for:mode:)`. For a live surface only, that schedules
  `refreshSurfaceSizes` on the next turn, the same pattern as `noteMeasuredListHeight`. Identical
  frames are already no-ops in `applyFrame`.
- Test `testMeasuredChromeRequestsARefitForAnAttachmentsFirstPanel` uses a real hosted content for
  a childless family opened on Attachments. The measurement requests a re-fit, with no list
  measurement present. A settled layout requests nothing more, and a host for a family without a
  live surface requests nothing. Test seam: read-only `chromeRefitRequestCount`.

FX8 — VoiceOver "Open" action was dead for unopenable types (SWE-A P3-4, SWE-B observation). **Fixed.**
- `TaskAttachmentCard` builds its named actions with `accessibilityActions`. "Open" is included only
  when `TaskAttachmentActions.canOpen`, and "Remove" always. The context menu keeps its disabled
  Open item, a visible, standard disabled command. `testOnlyOpenableFileTypesMayOpen` covers the
  predicate. The VoiceOver action list is live-only.

FX9 — Open handed the digest-protected private copy to editors (SWE-B F4). **Assessed; fixed for tasks.**
- Assessment: a task attachment's private file is its only stored bytes. No payload is kept in the
  model, and every use re-verifies the digest. If an editor saves over the file that
  `NSWorkspace.open` handed it, the attachment becomes permanently unavailable. Quick Look stays on
  the private copy: the presenter sets no delegate, so it offers no editing mode (live check below). Drag-out already gives receivers a copy.
- `TaskImageFiles.openableCopy(for:)` verifies the private copy and copies it into a fresh
  `AtticTaskExports/<UUID>/` directory. That is the same disposable root as the row-drag export,
  and it is pruned after a day through the shared `disposableDirectory()`. The copy keeps its
  sanitized filename and is made read-only (0444), so an editor reports the file as locked instead
  of silently discarding edits.
- `TaskAttachmentActions.open` opens that copy. A missing or changed private copy reports
  "missing or changed". A copy failure reports "Couldn't open …" (`reportAttachmentOpenFailure`).
  Owned private copies are never exposed for writing, and user originals are never touched.
- Notes were assessed, not changed: `NoteAttachmentActions.open` still opens the note's private
  materialization. That file is re-derived from the SwiftData payload when verification fails, so
  an external edit is overwritten on the next access. The edit is lost, but the attachment is not.
  This is pre-existing Notes behavior outside the V2 contract (backlog below).
- Test `testOpenHandsOutADisposableReadOnlyCopyAndThePrivateCopyStaysVerified`: the copy is outside
  private storage, keeps its name and bytes, and is not writable (a write throws). The private copy
  still verifies. Each open gets its own copy. A tampered private copy yields nil instead of a
  copy. The original is intact.

SWE-B F1 — hover replaces a latched anchored transient. **Root ruling: fix in batch 4 (R6); tracked below.**
Not changed in this delta, by instruction.

Other review notes, disposition:
- The `.noteTooLarge` message hardcodes "100 MiB" (SWE-A). Deferred, copy-only (backlog).
- AtticMobile compiles `TaskStore.swift` without the attachment sources (SWE-A, SWE-B). This
  predates batch 2 and iPhone work is deferred. Added to the backlog for the iPhone re-enablement
  checklist.
- No `Attic/TaskImages` orphan reconciler (SWE-A, SWE-B). Pre-existing; backlog.
- Attachment-only families don't hover-open, and the row action and help read "Show subtasks"
  (SWE-A, SWE-B). Hover-worthiness is a deliberate interpretation. The wording is a deferred
  cosmetic concern (backlog).
- The header subtitle describes subtask progress in both views (SWE-B). It matches the gallery
  reference image; deferred cosmetic concern (backlog).
- Clicking the Quick Look window dismisses a latched transient (SWE-B). This is consistent with
  outside-click semantics. It is a live UAT item, and batch 4 lifecycle work should consider it
  together with F1.
- A view switch drops a mounted entry's keyboard focus without restoring it (SWE-A). The draft
  and the active entry are preserved, matching focus-loss semantics. No change.
- Busy-guard and ambiguous-parent test gaps (SWE-A). The busy guard is now covered through
  `isAvailable`. The ambiguous-parent refusal remains untested (backlog).

### Checks (review fixes)

- `xcodebuild build -project Attic.xcodeproj -scheme Attic -configuration Local -destination
  'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO` →
  BUILD SUCCEEDED (`build-local-1.log`). No errors, and no warnings in touched files. This build
  covered all source changes; only test files and this ledger changed afterward.
- `xcodebuild test … -only-testing:AtticTests/`TaskImageTests, SubtaskPanelControllerTests,
  SubtaskPanelTests, NoteAttachmentTests, CornerHoverStateMachineTests → 181 tests, 0 failures,
  `** TEST SUCCEEDED **` (22 + 43 + 64 + 39 + 13; `unit-focused-1.log`,
  `FixesFocused-1.xcresult`). NoteAttachmentTests covers the shared importer change, and
  CornerHoverStateMachineTests covers the lock-reason composition. It built the final source.
  All 8 new tests passed.
- Full `AtticTests` was not repeated. The changes are confined to the suites above, and batch 2's
  full run (711 tests) is on record.
- UI-test compile was not repeated. `AtticUITests` is black-box (no `@testable` import), no
  UI-test source changed, and no accessibility identifier changed: `add-attachment-<id>` is still
  present and enabled in the tested default state.
- No project inputs changed, so no regeneration. `git diff --check` → clean.

### Unverified — needs live validation (review fixes)

- FX2: an image card dropped on image-only receivers (e.g. an image well, or a SwiftUI image drop
  target) and on Finder (copy name and type). A card drag vs click still disambiguates.
  `.onDrag`'s preview appearance matches the old `.draggable` preview.
- FX5/FX6: switch motion reads as one-direction paging. "Show attachments" from the row menu on a
  hover-opened panel slides and animates height instead of snapping.
- FX7: an Attachments-first open (menu "Show attachments", Add attachment completion) and a
  childless panel settle at the measured height without a visible second jump.
- FX3: while the picker is up, both Add attachment affordances appear disabled, and the picker's
  family panel and the main panel stay open when a child popover is opened elsewhere.
- FX8: the VoiceOver actions list shows Open only for openable types.
- FX9: Open launches the default app on the read-only copy (Preview, TextEdit). The editor's
  locked-file prompt is calm, and the attachment still previews afterward. Quick Look of an image or
  PDF offers no Markup or editing that could write to the private copy.

### Backlog carried forward

- **Batch 4 (R6), root ruling on SWE-B F1:** a deliberately latched anchored transient must
  persist until an outside click. Neutral hover on another family's row must not replace or
  downgrade it. Planned approach:
  - Gate the pending-open arm in `SubtaskPanelLifecycle.noteRowHover` (or its maturation) on the
    transient not being latched, keeping hover browsing for hover-origin panels.
  - Revisit the anchor-loss close for latched anchored panels (row scrolled out) under the same
    rule.
  - Consider whether a Quick Look click should count as outside.
  - Tests: extend the controller suite with "latched panel + other-row hover dwell → same family,
    still latched, view kept". Keep `testHoverSwitchWhileOpenUsesFastDwellThroughTheController`
    and `testBrowsingToAnotherFamilyOpensItOnSubtasks` for hover-origin panels, updating them
    deliberately if their setup latches. No user clarification required.
- Notes Open hands the private materialization to editors, and edits are overwritten on the next
  access. Pre-existing and outside V2. Candidate: reuse the disposable read-only copy.
- Deferred cosmetic/copy: "Show subtasks" wording for attachment-only families; header subtitle on
  Attachments; the hardcoded "100 MiB" limit message.
- Pre-existing gaps: `Attic/TaskImages` orphan reconciliation; `attachmentOwnerID`
  ambiguous-parent test; AtticMobile shared-source compile surface (iPhone re-enablement
  checklist).
- Batch-1 leftover `toggleFamilyPanel`/`controlFrames` dead path (tests only), for batch 4 lifecycle
  cleanup.


## Batch 3 — R4 + R5

Diff: `.build/batch3.diff`, against pre-batch tree `98cb0b6e14fedd6d78b5a431a9529e14e6fc9bdb`
(temporary index `.build/batch3/prefix.index`, no ref, real index untouched, nonignored untracked
files included). That tree differs from the batch-2 fix delta's `current_tree` only by
reviewer/orchestrator/live documents (FixSWE-A/B, Orchestration, Batch1Live); Batch2Live and a
further Orchestration update landed during the batch. The diff excludes all of those and `TaskPanelV2ReviewCriteria.md`, `TaskPanelV2Batch1Review.md`,
`TaskPanelV2Requirements.md`, `TaskPanelV2Batch2SWE-A/B.md`. Tree IDs, file list and SHA-256 are in
`.build/batch3/diffs.txt`; logs in `.build/batch3/`. Derived data `.build/DerivedData`.
`.build/TaskPanelsV2Preview` and the frozen preview executable were not touched, and no UI was
driven.

### Changed files

- New `Attic/Views/Panel/TaskAttachmentDrop.swift` — `TaskDropContent` (type routing),
  `TaskAttachmentStaging` (owned temp directory), `TaskDroppedFiles` (provider staging),
  `TaskFileDrop` (attach + reveal), `TaskFileDropTarget` (panel-wide target, environment key),
  `TaskFileDropDelegate`, `TaskRowDropDelegate`, `TaskDropOverlay`.
- New `Attic/Views/Panel/TaskComposerAttachments.swift` — `TaskComposerAttachments` (pending
  model), `TaskComposerAttachmentStrip`, `TaskComposerAttachmentChip`, `TaskComposerLayout`.
- `Attic/Services/TaskStore.swift` — `create(…, attachments:)`; `attachStagedFiles(to:stage:)`
  (reserved import returning new IDs); `attachFiles` now wraps it; `reportAttachmentImportFailure`.
- `Attic/Views/Panel/TaskRowView.swift` — one `onDrop` delegate replaces
  `dropDestination(for: TaskDragPayload.self)`; task-drop rules moved verbatim into
  `acceptTaskDrop`; row file overlay; menu picker reveals imported cards.
- `Attic/Views/Panel/SubtaskPanelContent.swift` — explicit init (StateObject), surface drop
  target/overlay/environment, fresh gallery IDs, picker reveal, import progress in the view switch.
- `Attic/Views/Panel/AtticPanelView.swift` — composer paperclip picker, drop, pending strip,
  upward growth (`taskEntryHeight`, hit height, scroll padding/mask, error banner offset, lock),
  submit binds pending references.
- `Attic/Views/Panel/TaskImageAttachments.swift` — picker split into shared `present`, task
  `choose` (returns IDs) and `chooseForComposer`; `isPresenting`; gallery `freshIDs` and card
  entrance.
- `Attic/Window/SubtaskPanelController.swift` — `revealImportedAttachments(_:for:transientAtDrop:)`;
  `FamilyPanelViewState` fresh-card marks (pruned with views).
- `Attic/Window/PanelUIState.swift` — `isComposerAttachmentPickerPresented` (`.taskConfirmation`).
- `Attic/Services/SubtaskPanelLayout.swift` — fresh-card timing constants.
- `Attic/Models/TaskDragPayload.swift` — gallery card drag also registers an own-process marker.
- `Attic/Info.plist` — exported `com.taha.attic.task-attachment` (conforms to `public.data`).
- `Attic.xcodeproj/project.pbxproj` — regenerated for the three new files.
- Tests: new `AtticTests/TaskAttachmentDropTests.swift`; `AtticTests/TaskImageTests.swift` (one
  assertion updated deliberately: the card provider now lists `public.png` then the marker).
- `Docs/TaskPanelV2Ledger.md` — status table and this section.

No model schema, stored keys, settings keys, entitlements, `ATTIC_LOCAL_ONLY`, signing, store or
bundle identity changes. No dependencies, timers or pollers. One one-shot `asyncAfter` clears
fresh-card marks after an import reveal.

### Existing code searched and reused

- Import, validation, limits, security scope, staging/final rollback: existing
  `AttachmentFileStore.importFiles(includePayload: false)` via `TaskImageFiles.importAttachments`.
- Notes drop paths (`dropDestination(for: URL.self)`, `NoteAttachmentPasteboardRouter`,
  `PromisedFileBatch`/`NSFilePromiseReceiver`) were reviewed. They are bound to Notes'
  `NSTextView`/pasteboard receiver and its `(urls, cleanupDirectories)` callback; SwiftUI drop
  destinations receive `NSItemProvider`s instead, so the task path uses the provider API
  (`loadObject(URL)`, `loadFileRepresentation`) with the same owned-cleanup-directory contract.
- Task reorder rules, `uiState.endDragging()`, picker marks, `openFamilyPanel`/`showPanelView`,
  gallery, thumbnail cache and Quick Look are reused unchanged.

### Implementation

R4 drop interactions
- [x] Routing (`TaskDropContent.classify`, synchronous from type conformance): an Attic task drag
  (`com.taha.attic.task-id`) is always a task drag, even when a row with attachments also exports a
  folder; a gallery card (own-process marker) is refused by every task drop target, so releasing a
  card over its own panel can never duplicate it; files are `public.file-url`, images, PDF, movies,
  audio, archives, spreadsheets, presentations; text selections and links are unsupported.
- [x] Main-list rows: one `TaskRowDropDelegate` per row. Task drags keep the exact previous rules
  (`endDragging` now runs synchronously at perform, before the payload loads, so the shell's
  150 ms drag-release watcher still sees the drag consumed). File drags attach to the row's owner.
- [x] Open family panel: the whole surface is a file drop target (`TaskFileDropDelegate`), and
  child rows inside it forward file drags to the same `TaskFileDropTarget` through the environment.
  So the entire panel highlights and attaches to the parent over the header, gallery, footer, empty
  space and child rows, on both Subtasks and Attachments. A child row resolves to its parent; no
  nested owner.
- [x] Overlay: `TaskDropOverlay` — 7 % accent tint and a thin accent edge in the surface's own shape
  (squircle for panels, the row's continuous hover shape for rows, the composer capsule), plus one
  small glass label “Drop to attach to “<parent title>””. Content stays visible; overlay is
  hit-test and accessibility inert and layout-neutral (`.overlay` after the ideal-height frame).
  Fades with `AtticMotion.quick`; none under Reduce Motion.
- [x] Import: `TaskStore.attachStagedFiles` reserves the owner before staging, so loading providers,
  copying and binding are one serialized operation. A second drop or picker import for the same
  owner is refused before loading with “Attic is still attaching files to “<title>”. Try again
  when it finishes.” (drop targets already refuse busy owners). Staging: file URLs are read in place
  (originals only read); promised or in-memory content is copied during its callback into
  `tmp/AtticTaskDrops/<UUID>/<index>/` with a type-matching extension, refused above 15 MiB or 20
  items before copying, and that owned directory is discarded after import, success or failure.
- [x] Success: `revealImportedAttachments` switches a panel already presenting the family to
  Attachments in place (the designed slide/crossfade and height animation), or opens the family on
  Attachments if the transient is the same one that was up at drop time. A panel closed or replaced
  during the import is never reopened or stolen. When the view switches, the new cards are marked
  fresh and enter just after the switch (scale 0.9→1 + fade, 35 ms stagger, capped); a gallery
  already on screen uses its existing insertion transition. Reduce Motion: fade only. VoiceOver
  announcement “Attached N files to <title>”. A drop onto a hover-opened transient latches it first,
  so it stays up while importing. While importing on Subtasks, the view switch shows a mini
  progress (value “Attaching files”); the row shows its existing spinner.
- [x] Failure: nothing switches or opens; the store keeps its calm task-worded message (main-panel
  error banner or the panel footer error row); every private copy and owned staging directory of
  the batch is removed; originals untouched; no false success (a failed save returns nil).
- [x] Picker paths now also return new IDs and use the same reveal policy (previously the row menu
  opened the family unconditionally and the panel button switched unconditionally).

R5 main composer
- [x] Paperclip button (“Add attachment”, `quick-entry-attach`) opens the shared picker;
  `isComposerAttachmentPickerPresented` holds the `.taskConfirmation` lock and blocks other pickers
  (one picker at a time). The composer shell is also a file drop target with overlay “Drop to
  attach to the new task”.
- [x] Pending items import immediately into private storage (`TaskComposerAttachments`), so image
  thumbnails (bounded 96 px cache) and file cards (icon, name, size) show before submit. A placeholder
  “Attaching N…” with a cancel × shows while a batch copies. Chips: click/Space Quick Look,
  hover/focus ×, Delete or VoiceOver “Remove”.
- [x] Growth: the strip (54 pt) sits above the text row inside the same glass rounded shell; the bar
  is bottom-anchored, so it grows upward. `taskEntryHeight` feeds the chrome hit height, scroll
  padding and mask, and the error banner moves up by the same amount.
- [x] Submit: `store.create(…, attachments:)` encodes the references before insert, so task and
  references share one save. On failure the title, priority, pending items and their private copies
  stay for retry; `didBind` clears pending only after success.
- [x] Races: one batch at a time (drop target and paperclip disabled while importing); submit
  button and Return wait for the batch (`canSubmit`); limits count items already pending. Cancel
  bumps a generation and cancels the task: the importer's own rollback or the returning batch removes
  its copies and owned staging, and a batch that finishes after cancel is deleted instead of
  appearing. Removing a chip deletes only that private copy. `.taskComposer` lock also covers pending
  or importing items.

R8 carry-over: overlay labels, chip ×, cancel × use `atticGlassControl`; composer shell unchanged
glass treatment.

Deliberately unchanged: existing latch/main-panel motion; F1 latched hover replacement (batch 4).

### Tests added (`TaskAttachmentDropTests`)

- `testDropContentSeparatesTaskRowsGalleryCardsFilesAndText` — includes a real gallery-card provider.
- `testStagingReadsFinderOriginalsInPlaceAndCopiesProvidedContentIntoItsOwnedDirectory`
- `testStagingRefusesTextOversizedAndTooManyItemsWithoutLeavingStagedFiles` — no provider is loaded
  for an over-limit batch.
- `testDroppedFilesAttachToTheParentAndDiscardOnlyTheirStaging` — child resolves to parent, relaunch,
  verified private copies, staging gone, originals kept.
- `testFailedStagingImportOrSaveReportsCalmlyWithoutFalseSuccessOrLeftovers`
- `testOverlappingImportForTheSameOwnerIsRefusedWithAMessage` — staging runs inside the
  reservation; the refused call stages nothing.
- `testImportedAttachmentsRevealOnlyWhereTheUserStillExpectsThem` — in-place switch, open gallery
  (no second entrance), closed during import, other family opened since, unchanged since drop,
  pinned, and mark expiry.
- `testComposerAttachmentsBindToTheNewTaskInItsSingleSave` — zero saves before submit, exactly one
  save for task plus references, relaunch.
- `testFailedSubmitKeepsTheDraftItemsAndTheirCopiesForRetry`
- `testRemovingOrCancellingDeletesOnlyTheComposersOwnCopies` — cancel during staging; no failure
  reported.
- `testComposerLimitsCountItemsAlreadyPending`

### Checks (implementer)

- `/opt/homebrew/opt/ruby/bin/ruby Scripts/generate_project.rb` then
  `Scripts/verify_project_generation.rb` → “Project generation is repeatable and Attic.xcodeproj is
  current” (after the two new sources and again after the new test file;
  `generate-project*.log`, `verify-project*.log`).
- `xcodebuild build -project Attic.xcodeproj -scheme Attic -configuration Local -destination
  'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO` →
  BUILD SUCCEEDED on final source (`build-local-2.log`; also `build-local-1.log` earlier). No
  warnings in touched files.
- `xcodebuild test … -only-testing:AtticTests/TaskAttachmentDropTests -only-testing:AtticTests/TaskImageTests`
  → 24 tests, 0 failures, `** TEST SUCCEEDED **` (11 + 13; `unit-focused-1.log`,
  `Batch3Focused-1.xcresult`). Source after this run changed only by one
  `.onChange(of: mode)` re-configuration line in `SubtaskPanelContent`; it compiled in the final
  build and test build.
- `xcodebuild build-for-testing … -scheme Attic -configuration Local` → TEST BUILD SUCCEEDED on
  final source (`build-for-testing-1.log`): every `AtticTests` file, including the unchanged
  SubtaskPanelTests/ControllerTests callers of the new `SubtaskPanelContent` init and picker API,
  compiles.
- NOT RUN — environment: adjacent suites `SubtaskPanelControllerTests`, `SubtaskPanelTests`,
  `SubtaskTests`, `TaskStoreTests`, `CornerHoverStateMachineTests` (plus a re-run of the two focused
  suites). Five attempts after 07:27 local (`unit-adjacent-1..5.log`, `unit-envcheck-1.log`) launched
  `AtticUnitTestHost` but never began tests; even the previously passing single suite stalled. A
  `sample` of the host showed the main thread blocked in XCTest
  `-[XCTestDriver _prepareTestConfigurationAndIDESession]` waiting on the IDE/testmanagerd session,
  before any test code. This matches the live owner's 06:20 UTC note (runner failed to initialize,
  environment). testmanagerd could not be restarted from this session; stalled runs and host
  processes were stopped and their partial result bundles removed. These suites must be run once the
  runner recovers; they cover `familyEditBusy`/picker availability, `FamilyPanelViewState.retain`,
  the hosted panel content and `create`.
- UI tests: no UI-test source or accessibility identifier used by them changed, so the AtticUI
  compile was not repeated. The AtticUnitTestHost/app targets compiled above.
- `git diff --check` over the batch diff → clean (`diffs.txt`).

### Unverified — needs live validation

Not proven by source, build or unit tests:
- Real drags: Finder files and folders (folder refused calmly), Photos/Mail/Safari file promises and
  in-memory images (the `loadFileRepresentation` path), multi-item drops, sandboxed file-URL access
  from other apps' drags.
- Hit routing: SwiftUI nested drop destinations — child row versus surface target inside a panel,
  row versus section, composer versus rows under it; whether the whole panel highlights
  continuously while crossing from surface space onto child rows and back.
- Task reorder/status drops on parent and child rows after the delegate replacement, including the
  unfinished-subtasks confirmation and the external-drag release watcher; attachment card drag-out
  to Finder still works; card released over its own panel and another task is refused (the
  own-process marker must be visible on the in-app drag pasteboard); trackpad scrolling unaffected.
- Overlay appearance in every theme/surface mode, Reduce Transparency/Motion, long titles.
- Motion: switch-then-card entrance timing; row drop opening the panel on Attachments; hover-opened
  transient latching on drop and staying open while importing; outside panels during a Finder drag.
- Composer: strip growth upward without moving the text row, hit testing on chips inside the chrome
  band, NSOpenPanel from the non-activating main panel, auto-hide held while the picker is up,
  submit disabled while importing, cancel ×, keyboard focus on chips, VoiceOver labels.
- Failure presentation: banner position above the grown composer; panel footer error row.

### Interpretations and open risks

- ~~Gallery-card drags are refused by all task drop targets, including other tasks.~~ Superseded
  by review fix BF1: other tasks and the composer copy a card; only its own owner refuses it.
- ~~Pending composer copies orphan if the app quits.~~ Superseded by review fix BF3 (launch
  sweep with an age floor).
- A drop on a main row whose import finishes after the user opened another family attaches without
  revealing; the row metadata shows the new count.
- A submit requires a title; attachments alone do not create a task.
- ~~Accepted drop types are a fixed list.~~ Superseded by review fix BF2 (general data files).
- `AtticMobile` shared-source compile surface is still not addressed (deferred iPhone work).

### Review findings / fixes

Sources: `Docs/TaskPanelV2Batch3SWE-A.md` (F1–F6) and `Docs/TaskPanelV2Batch3SWE-B.md` (P1, two
P2s, the source-staleness risk). Both asked for the same three fixes before acceptance. Reports were
not edited.

Pre-fix snapshot tree (temporary index `.build/batch3-fixes/prefix.index`, no ref, real index
untouched, nonignored untracked files included): `61b57b9731a3e9d83032f31264f43639e3746b0c`
(2026-09-13 07:29 UTC). It differs from batch 3's `current_tree` only by the two review reports and
an Orchestration update. Fix delta: `.build/batch3-fixes.diff`, which excludes those documents and
every file excluded from batch 3. Tree IDs, file list and SHA-256 are in `.build/batch3-fixes/diffs.txt`.
Logs and evidence are in `.build/batch3-fixes/`. `.build/TaskPanelsV2Preview` and the frozen preview
executable (still running under the live owner) were not touched, and no UI was driven.

Changed files: `Attic/Views/Panel/TaskAttachmentDrop.swift`, `Attic/Services/TaskStore.swift`,
`Attic/Models/TaskImageReference.swift`, `Attic/Services/AttachmentFileStore.swift`,
`Attic/Views/Panel/TaskComposerAttachments.swift`, `Attic/Views/Panel/AtticPanelView.swift`,
`Attic/Views/Panel/SubtaskPanelContent.swift`, `Attic/Views/Panel/TaskRowView.swift`,
`Attic/Views/Panel/TaskImageAttachments.swift`, `Attic/Window/SubtaskPanelController.swift`,
`Attic/App/AppCoordinator.swift`, `AtticTests/TaskAttachmentDropTests.swift`, this ledger. No new
files, so no project regeneration. No schema, stored keys, settings keys, Info.plist, entitlements,
`ATTIC_LOCAL_ONLY`, signing, store or bundle identity changes. No new timers, pollers or
dependencies. The launch sweep is one `Task` per launch.

BF1 — gallery cards refused by every task, not just their own (SWE-A F1, SWE-B P1). **Fixed.**
- Routing: `.attachmentCard` is still classified right after a task drag, so task reorder and status
  classification is unchanged. It is no longer a blanket refusal. `TaskAttachmentCardDrag` records
  the dragged card's `TaskAttachmentSource` (reference plus resolved top-level owner) when its
  `.onDrag` begins. `TaskStore.attachmentSource(for:)` resolves it from the store alone. A legacy
  subtask attachment resolves to the parent. An attachment held by two tasks, or by a parentless
  subtask, is unresolvable and refused everywhere. Synchronous validation
  (`TaskFileDrop.canAccept(_:onto:store:)`, `TaskAttachmentCardDrag.canCopy(toOwner:)`) refuses
  the card's own owner, including its child rows and its own panel surface. Other tasks' rows and
  panels, and the main composer (no owner yet), accept it with a `.copy` proposal.
- Perform: `TaskAttachmentCardDrag.sources(from:expected:)` loads the own-process marker and
  requires it to name the recorded attachment. `TaskStore.attachCopies(to:of:)` runs that inside
  the owner reservation. `verifiedCopySources` requires the record to match the store exactly (same
  attachment, digest and owner) and throws `alreadyAttached` for the target's own owner, a safety
  net against a stale proposal. `TaskImageFiles.importCopies` reads only the digest-verified private
  file and imports it as a new attachment with a new UUID directory, so no deletable storage is
  shared. It discards the copy if its digest differs from the source and keeps the source's
  recorded type. Binding, save rollback and the reveal use the existing import path
  (`attachStagedFiles` and `attachCopies` now share the private `attachImported`). Composer card
  drops go through a new `TaskComposerAttachments.add(count:files:importing:reportFailure:)`. The
  staged `add` wraps it with unchanged cancel/generation semantics.
- Failure copy: “Couldn’t attach files. The attachment is no longer available.” / “… That
  attachment already belongs to this task.” Nothing attaches and no copy is left behind.
- Why a process-local record: `DropInfo` validation cannot load item data, and the proposal must be
  decided before release. The record is only consulted while the own-process marker is present.
  Every card drag overwrites it, and the perform-time marker and store checks mean a stale record can
  never duplicate or copy the wrong file.

BF2 — promised general files silently excluded (SWE-A F3, SWE-B P2). **Fixed.**
- One rule, `TaskDropContent.classify`, applied at three levels: `DropInfo` (validation), per
  provider (`classify(_ provider:)`, used by `providers(for:in:)` for the fetch), and
  `TaskDroppedFiles.fileContentType(of:)` for materialization. The rule: a task drag, then a card,
  then files, meaning a listed file type, or any `public.data` that conforms to neither
  `public.text` nor `public.url` and is not an Attic in-app marker. Destinations register
  `TaskDropContent.dropTypes` (card marker + listed types + `public.data`).
- Accepted now: docx, doc, pages (single-file), eml, epub, fonts, and other declared or dynamic
  data. Still refused: text selections, links, folders (not data), and anything that also carries
  text. Text-conforming documents are also refused: txt, md, rtf, csv, json, html, **vCard (.vcf)
  and calendar (.ics)**. That is an explicit decision following the "reject text selections" rule;
  Finder file URLs of those types still attach as before. The note inline-card move marker
  (`com.taha.Attic.note-attachment-move`, conforms to `public.data`) is explicitly excluded, so a
  note card dragged over a task is never offered as a file.
- Materialization prefers a listed type, then the first declared (non-dynamic) data type, so a
  promised document keeps a real extension (`Report.docx`) and its content type. The existing
  regular-file, 15 MiB and 20-item guards still apply.
- Conformances measured on this machine: `.build/batch3-fixes/uti-matrix.txt` (source
  `uti-matrix.swift`). Promise metadata types (`com.apple.pasteboard.promised-file-url` /
  `-content-type`) conform to neither data nor url, so they do not interfere.
- Side effect, deliberately accepted: text and task drags now reach the composer and panel surface
  destinations and are answered `.forbidden` instead of being ignored. Nested child-row task
  destinations still win.

BF3 — pending composer copies orphan on quit (SWE-A F2, SWE-B P2). **Fixed (launch-only sweep with
an age floor).**
- Why this approach fits the current architecture: pending composer items must live in
  `Attic/TaskImages` before submit (thumbnails, Quick Look, single-save binding), so a separate
  staging owner would mean a second copy or a move at submit, against R3's no-duplication rule.
  Composer drafts are in-memory only, so after a relaunch no pending item can be live. The only
  in-session writers are imports, which are always seconds to minutes old when bound.
- `TaskStore.sweepUnreferencedAttachmentStorage(minimumAge: 24 h)` runs once per store (flag). It
  refuses to run while any import reservation is active. It collects referenced attachment UUIDs
  from **every physical replica** (`context.fetch`, not the de-duplicated `tasks`). If any replica's
  `imageReferencesData` fails to decode, it does not sweep at all. It protects by UUID regardless of
  digest (more conservative than the notes reconciler).
- `AttachmentFileStore.removeUnreferencedMaterializations` removes only canonical
  `<UPPERCASE-UUID>/<64-hex>` directories whose UUID is unreferenced and whose directory and every
  item in it were created and last modified before the cutoff. A missing or unreadable date counts
  as recent. Other entries in the tree, including `Thumbnails` and non-canonical names, are left
  alone. An emptied id directory is removed only if it was old before the sweep. Importer `.staging`
  batches older than the cutoff are removed. At most 500 removals per launch.
- `TaskAttachmentStaging.removeAbandoned(modifiedBefore:)` removes stale `tmp/AtticTaskDrops/<UUID>`
  directories left by a crash or quit mid-drop, using the same cutoff.
- Trigger: `AppCoordinator.start()` in the interactive, non-test, non-UI-test path only, where the
  container is the persistent store. Unit tests and UI tests use an in-memory store with the shared
  `TaskImages` root, and an empty reference set must never judge real files. The age floor also
  protects an import that begins while the sweep scans. Originals are never read or touched.
- Bound: an abandoned draft is reclaimed at the first launch at least 24 h after it was written.

F4 — stale panel highlight sources (SWE-A F4, SWE-B verification risk). **Fixed (hardening).**
`TaskFileDropTarget.end()` now runs when any file or card drop performs on a panel. The row calls it
before forwarding, and the panel's configured `perform` calls it first. A drop therefore clears every
source, including a surface whose exit was never delivered. Row-only and composer targets were
already single-source.

F5 — reveal treated "opened and closed another family" as unchanged (SWE-A F5). **Fixed.**
`SubtaskPanelController.RevealContext` pairs the transient family with a change counter, bumped
whenever the published `transientFamilyID` changes (`syncState`, `tearDown`). A reveal opens a
panel only if the context is identical to the one captured at drop or picker start. It still switches
in place a panel already presenting the family, and a pinned family. Every caller (row and panel
drops, row-menu and panel pickers, card copies) passes `revealContext`.

F6 — asymmetric staging discard contract (SWE-A F6). **Fixed (documented and tightened).** The
`stage` contract ("throw only after discarding your own directory; a returned staging is discarded
here") is stated on `attachStagedFiles`, the composer's `add`, and `TaskDroppedFiles.stage`, which
satisfies it. Both wrappers now discard a returned staging with `defer`, including when the import
throws.

Not changed (observations, deliberately left): the `performDrop` async result (no system reject
animation on a rare late failure), composer chips lacking Return, `Info.plist` whitespace, and
`familyEditBusy` not blocking a drop (calm degradation). Batch 4 latch/corridor/gesture work was
not started.

Tests added or updated in `AtticTests/TaskAttachmentDropTests.swift` (compiled, **not executed**,
see checks):
- `testDropContentSeparatesTaskRowsGalleryCardsFilesAndText`: extended with the general-file
  matrix (docx/doc/pages/eml/epub/ttf accepted; txt/rtf/csv/vcf/ics/md, link, folder, note marker,
  docx+text refused), provider-level classification, and `fileContentType` for a promised docx.
- `testPromisedGeneralDocumentsStageWithTheirTypeAndAttach`: promised docx and eml without file URLs
  stage as `Report.docx`/`Thread.eml` with their content types, verified private copies, originals
  kept.
- `testGalleryCardCopiesIntoAnotherTaskButNeverIntoItsOwnOwner`: own owner, child and panel refusal;
  other task and composer acceptance; files still accepted by the owner; a real card provider copies
  with a new id, same digest and type, and separate storage; relaunch persistence; removing the copy
  keeps the source verified; a stale perform onto the owner family is refused with no leftovers.
- `testGalleryCardDropRevalidatesTheMarkerAndTheVerifiedSource`: marker mismatch, a stale record,
  and a tampered private source each refuse calmly with no copy and no reservation left.
- `testGalleryCardDroppedOnTheComposerBecomesAPendingCopy`
- `testALegacySubtaskCardResolvesToItsParentAndAmbiguityRefuses`
- `testEndingADropClearsEveryPanelHighlightSource`
- `testLaunchSweepRemovesOnlyOldUnreferencedCopiesAndKeepsEveryReplicasFiles`: a duplicate replica
  whose references differ from the visible task keeps its file; an old orphan is removed; recent and
  unknown entries are kept; old drop staging is removed and live staging kept; a second call does
  not run.
- `testLaunchSweepDoesNothingWhenAReplicaIsUnreadableOrAnImportIsRunning`
- `testImportedAttachmentsRevealOnlyWhereTheUserStillExpectsThem`: moved to `RevealContext`, plus
  the opened-then-closed-other-family case.

### Checks (review fixes)

- `xcodebuild build -project Attic.xcodeproj -scheme Attic -configuration Local -destination
  'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO` →
  BUILD SUCCEEDED on final source (`build-local-1.log`). No errors, and no warnings in touched files.
- `xcodebuild build-for-testing …` (same flags) → TEST BUILD SUCCEEDED on final source
  (`build-for-testing-1.log`). Every `AtticTests` file compiles, including the new and updated tests
  and all callers of the changed `revealImportedAttachments`, `TaskFileDrop` and delegate APIs.
- **NOT RUN (environment): unit tests.** Readiness was inspected first. No stray `xcodebuild` or
  `AtticUnitTestHost` processes remained. `testmanagerd` was the same process (pid 62400, started
  06:54 local) that served the passing 07:24 focused run and the 07:27–08:02 stalls, so the evidence
  was inconclusive and warranted exactly one attempt. One `test-without-building` run (08:45 local)
  covered `TaskAttachmentDropTests`, `TaskImageTests`, `NoteAttachmentTests` (shared importer
  file), `SubtaskPanelControllerTests`, `SubtaskPanelTests` and `TaskStoreTests`. The host
  launched, and after 4 minutes there were zero `Test Suite` lines. A read-only `sample`
  (`host-sample-1.txt`) showed the main thread in `-[XCTestDriver
  _prepareTestConfigurationAndIDESession]`, the identical pre-test handshake stall
  (`unit-focused-1.log`, ends `** BUILD INTERRUPTED **`). The run and host were stopped and the
  partial result bundle removed. No further retries, and no TCC, security or service changes. These
  suites, plus `SubtaskTests` and `CornerHoverStateMachineTests` still owed from batch 3, must run
  once the runner recovers.
- Alternative legitimate execution (partial): `.build/batch3-fixes/sweep-harness/` compiles the
  real `Attic/Services/AttachmentFileStore.swift` and `Attic/Models/NoteAttachment.swift` with a
  standalone `main.swift` (`xcrun swiftc`, temp directory only). It passed 14/14 checks against real
  file dates (`run-1.log`): the removal limit, old unreferenced copies and their id directories
  removed, old referenced copies kept, recent copies kept, non-UUID and lowercase names kept, old vs
  new importer staging, originals untouched, and a recent file inside an old directory keeping the
  copy. It does not cover the store-level replica union or the SwiftUI-file code (classifier, card
  routing, drop staging sweep); those are compile-verified and covered only by the unexecuted tests
  above. The classifier's conformance inputs are measured in `uti-matrix.txt`.
- `git diff --check` → clean.

### Unverified — needs live validation (review fixes)

- Card drags: another family's row, panel surface and child rows show `.copy` and highlight; the
  own panel, its child rows and the owner's main-list row show no highlight or the forbidden cursor;
  release copies and reveals on the target; the composer accepts a card as a pending chip. A card
  from a legacy subtask popover is refused by its parent. Whether SwiftUI calls `.onDrag` before
  the first `validateDrop` (the record must exist first).
- Promised general files: a Mail `.docx`/`.eml` attachment drag and a browser download of a document
  (with and without an accompanying file URL or text flavor). Whether real promise providers expose
  the document type rather than only metadata. A vCard/contact drag is refused.
- Text and task drags over the composer and panel surface: forbidden cursor with no highlight, and
  task reorder over child rows inside a panel unchanged.
- Overlay clears after a drop that crosses surface → child row → release.
- Reveal: a main-row drop, then opening and closing another family during a slow import, leaves
  the target closed.
- Launch sweep in a real preview: a composer draft with items, quit, relaunch less than 24 h later
  (kept), then with backdated copies (removed). Only on an isolated preview store, never
  `com.taha.Attic` user data.

## Batch 4 — R6 + R7, Batch 3 live P1, Batch3FixSWE-A Lows

Diff: `.build/batch4.diff`, cumulative against the prefix tree taken before any Batch 4 edit (a
temporary index with `git add -A`, nonignored untracked files included). Provenance, file list and
digests are in `.build/batch4/PROVENANCE.md`. No commits, and the real index is untouched. The frozen
preview `.build/TaskPanelsV2Preview` was not rebuilt, relaunched or driven, and no UI was controlled.

### Changed files

- `Attic/Services/SubtaskPanelLayout.swift`: hull corridor (`pointerCoverage` with `crossingFrames`,
  `corridorHull`, `distance`), `TransientTravel`, latch rules in `SubtaskPanelLifecycle`, and
  `SubtaskSwipeDismissTracker`.
- `Attic/Window/SubtaskPanelController.swift`: travel decisions at close and switch maturity, pinned
  crossing coverage, the latched scroll-out rule, the bounded outside-click predicate, and the swipe
  gates.
- `Attic/Window/PanelSurfaceHostingView.swift`: `PanelSurfaceWindow` scroll routing,
  `PanelSurfaceSwipeDismissal` and `PanelSurfaceMotionContainer`.
- `Attic/Services/AttachmentFileStore.swift` and `Attic/Views/Panel/TaskAttachmentDrop.swift`: the
  symlink skip, and `TaskRowDropDelegate.perform(_:taskProvider:attachmentProviders:)`.
- `Attic/Design/AtticStyle.swift`, `Attic/Services/PanelGeometry.swift` and
  `Attic/Views/Panel/AtticPanelView.swift`: `composerAttachWidth` in the composer layout model.
- `Scripts/launch_local_preview.zsh`: stops an unrecorded instance and verifies the launched PID.
- Tests: `AtticTests/SubtaskPanelTests.swift`, `SubtaskPanelControllerTests.swift`,
  `TaskAttachmentDropTests.swift` and `PanelSquircleGeometryTests.swift`.
- No files were added or removed and no project inputs changed, so project regeneration and
  verification were not needed.

### Live P1 — composer paperclip absent at 332 pt: disposition

**Root cause: a stale preview process, not the layout or the source.** The evidence, captured
read-only, is in `.build/batch4/live-p1-evidence.txt`:

- The Batch 3 launch recorded PID 98729 (`launch.log`, `PreviewState/process.pid`). That PID was not
  running.
- The only running `AtticTaskPanelsV2` was PID 69452, started 07:21:27 local. That is before the
  09:43:36 Batch 3 rebuild, and matches the frozen Batch 2 preview era.
- `lsof` shows PID 69452 mapping the replaced images: stub inode 139158686 and `debug.dylib` inode
  139158684, 19,124,816 bytes. The on-disk Batch 3 bundle has inodes 139281284 and 139281282, and a
  20,305,872-byte `debug.dylib`.
- The on-disk Batch 3 `debug.dylib` contains `quick-entry-attach`, `Attach images or files` and
  `paperclip`. There is exactly one composer implementation (`AtticPanelView.taskEntryBar`).
- The launcher stops only the PID in `process.pid`. An instance whose record had been overwritten
  survived, the new instance was not running (empty stderr, no crash report, exit cause unknown),
  and the live checks inspected the Batch 2 binary.
- Provenance gap: the recorded "executable SHA-256" hashes the 41 KB stub, which is byte-identical in
  size across builds. The code lives in `AtticTaskPanelsV2.debug.dylib`, whose SHA-256 is
  `7b961e9f…a5a96` for the frozen Batch 3 bundle. Future live reports should record the
  `debug.dylib` hash and the running PID's mapped inode.

Layout was checked rather than assumed. In the worst supported geometry (320 pt, corner 140), the
insets are about 26.1 pt per side, which leaves about 129.8 pt for the title text beside the 42 +
28 + 42 pt controls. At 332 pt it is wider. The paperclip's fixed frame is not compressible.

Changes:

- `TaskEntryBarLayout.textFieldWidth` and its geometry test now account for the paperclip through
  `AtticStyle.composerAttachWidth`, with the same 28 pt, so proportions are unchanged. The ≥120 pt
  field assertion across every supported width and corner still holds.
- Launcher hardening: before launching, any process running exactly the preview executable is
  stopped. The resolved or recorded path must match; other apps are never touched. After launch
  the new PID must be alive at 1.5 s, and it must be the only instance, or the launch fails. A
  read-only dry check of the matcher (`launcher-pid-match-check.txt`) identifies PID 69452 and
  matches nothing for a nonexistent path. The script was syntax-checked but not run.

**Remains for the live owner:** stop PID 69452 or relaunch with the hardened launcher. Then confirm
the paperclip and `quick-entry-attach` at 332 pt with an empty and a populated title, and complete the
R5 picker, pending-card, upward growth and submit flow. Rendered verification is still owed.

### Batch3FixSWE-A Lows

- **Low 1, symlinks in owned-file cleanup: fixed.** `removeUnreferencedMaterializations`,
  `cleanOrphans` (id and digest levels, staging) and `TaskAttachmentStaging.removeAbandoned` now skip
  link entries (`lstat` type) and never traverse or remove them.
  - Measured honestly in `.build/batch4/symlink-harness/run-1.log`, which runs the real source with
    the prefix-tree file versus the working tree. The reported destination-deletion vector did not
    reproduce on this macOS even before the fix, because URL `isDirectoryKey` describes the link
    entry itself.
  - What the fix changes observably: the pre-fix code removed or acted on link entries (4 FAILs);
    post-fix, all checks pass. It also no longer depends on Foundation's link-resolution semantics.
  - XCTest: `testOwnedFileCleanupNeverActsThroughSymbolicLinks` (compiled, not run).
- **Low 2, `panelTarget.end()` on every row drop arm: fixed.** The body moved into the
  `DropInfo`-free `perform(_:taskProvider:attachmentProviders:)`. It clears row targets, then ends the
  panel target before any acceptance check, so task reorders, payload-less task drops, refused
  drops and attachment drops all end it.
  - XCTest: `testEveryRowDropEndsThePanelHighlightIncludingReorders` (compiled, not run).

### R6 implementation

- **Corridor to the actual placement.**
  - Transit is the convex hull of the source row and the surface, each padded by one row height
    (32 pt). It follows the frame placement actually produced, including a surface moved clear of
    a pinned panel.
  - Only the source-facing half-plane from the surface's centre counts, so a point beyond the
    surface, or its far corner wedges, is outside.
  - A visible pinned panel counts as transit where it intersects that hull (separating-axis test).
    Crossing it does not dismiss, while pinned panels off the route stay outside.
  - Without a live row, the main panel's facing edge is the source. A detached surface has no
    corridor.
- **Travel policy (`TransientTravel`).**
  - Arrival on the surface cancels the pending close and any pending switch immediately.
  - In transit, a close is deferred within the 0.6 s budget, and only renewed progress extends it:
    the closest distance must shrink by at least 2 pt. Progress is monotone, so it is bounded.
  - A switch to the row under the pointer yields only while the hand is still closing on the
    surface. Resting or sideways movement browses on the fast dwell as before.
  - A 0.1 s approach hold covers the close and switch timers maturing milliseconds apart; without
    it, the second check misread an approach as rest.
  - Travel starts at row or surface leaves and row enters. Timers exist only while a close or open
    is pending, so there is no idle polling.
- **Root ruling, latch.**
  - A latched (explicit or dragged) transient ignores other-row hover entirely: no pending open.
  - `openTransient(latched: false)` never downgrades a latch, and `closeTransient` resets the
    origin.
  - Source scroll-out or row disappearance keeps a latched panel where it is, following content
    height only. A hover-governed one still closes.
  - Explicit actions (row click, menu, count control, reveal) still switch tasks.
  - Outside click still dismisses. Its predicate is now the surface plus the transit gap within
    `sideGap` of the surface, excluding the main panel's content and pinned panels, so a long route
    cannot swallow real outside clicks.
- **Overlap and pinned identity.** Placement already avoids pinned panels and the main panel where
  the screen allows (`avoidingOverlap`), and a route test now covers it. Pin, unpin, reveal and moved
  position are unchanged.

### R7 implementation

- `PanelSurfaceWindow.sendEvent` routes only precise, phase-owned, non-momentum, modifier-free
  scrolling with no mouse button held. The surface must be unpinned
  (`swipeDismissal != nil`), idle (`canBeginSwipeDismissal`: that family's transient, not pinned, no
  edit, confirmation or menu), and not over horizontally scrollable content. Everything else,
  pinned windows included, passes through untouched.
- `SubtaskSwipeDismissTracker` decides direction after 6 pt with 1.5× horizontal dominance, using
  both the initial direction and the displacement. Vertical or diagonal sequences stay with the
  content for the whole gesture. Either horizontal direction dismisses.
- Progress follows the fingers over 180 pt, and reversing reduces it. On release it completes at
  ≥50%, or from ≥12% with velocity ≥450 pt/s over the last 0.1 s. A reverse flick at ≤−450 pt/s, a
  cancelled phase, a click, a key press or a magnify cancels.
- Presentation: an inward scale to 0.94 at full progress, with opacity 1→0.45, on a motion layer
  (`PanelSurfaceMotionContainer`, mirroring `AtticPanelContentContainer`) about the visual centre.
  - Reduce Motion keeps scale ≥0.995 and fades to 0.2 instead.
  - Completion animates for 0.16 s, then asks the controller, which declines if the surface was
    pinned or replaced meanwhile, and restores.
  - Cancel restores over 0.22 s (0 when hidden). Content interaction is re-enabled immediately, so
    the cancelling click lands.
- Cleanup: every `orderOut` cancels tracking and resets transform and opacity, so the reused transient
  window never reappears faded. Pinned configuration clears handlers. Closures are weak, and there
  are no observers or timers.
- The main panel's swipe, collapse animation, header drag and idle behaviour are untouched: no file
  in that path changed.

### Tests (intentional replacements marked)

- `SubtaskPanelTests`, new:
  - Corridor: `testCorridorFollowsAPlacementMovedClearOfAPinnedPanel` and
    `testCrossingPanelsCountOnlyWhereTheyLieOnTheRoute`.
  - Travel: `testTravelDefersACloseWithinABudgetThatOnlyProgressRenews` and
    `testTravelYieldsASwitchOnlyToAHandStillApproaching`.
  - Latch: `testLatchedTransientIgnoresOtherRowHoverAndIsNeverDowngraded`.
  - Swipe: `testVerticalAndDiagonalScrollingNeverDismisses`,
    `testHorizontalSwipeFollowsTheFingersInEitherDirection`, `testCompletionIsVelocityAware` and
    `testDismissalPresentationIsSubtleAndReduceMotionKeepsOnlyTheFade`.
  - The existing `testPointerCoverageSeparatesSurfaceTransitAndOutside` is unchanged and passes
    under the hull.
- `SubtaskPanelControllerTests`, new: `testLatchedPanelSurvivesNeutralHoverAndScrollOut` and
  `testSwipeDismissalIsOfferedOnlyToTheFamilysUnpinnedIdleSurface`.
- **Replaced:**
  - `testCorridorTransitDoesNotSwallowAPendingFamilySwitch` became
    `testCorridorTransitDefersASwitchOnlyWhileTheHandApproachesTheSurface`. A resting pointer still
    switches on time; an approaching one does not, and arrival drops the claim.
- **Adapted to the root ruling** (they opened latched, then expected neutral hover to replace the
  panel, which is now forbidden). Each now opens by hover, and its original intent is kept:
  - `testHoverSwitchDeferredWhileFamilyEditingChild`
  - `testHoverPendingRearmsWhileBusyAndOpensAfter`
  - `testPendingOpenWithoutAnchorReleasesMaturedFamilyState`
  - `testHoverSwitchWhileOpenUsesFastDwellThroughTheController`
- `installAnchors` is a new helper; `installAnchor` replaced the whole row map, which hover opens
  depend on.
- `TaskAttachmentDropTests` and `PanelSquircleGeometryTests`: as listed above.

### Checks

- Local `xcodebuild build` (the Batch 3 flags, `.build/DerivedData`): BUILD SUCCEEDED
  (`build-local-2.log`). `build-for-testing`: TEST BUILD SUCCEEDED (`build-for-testing-2.log`).
  Both are on final source. The only warning in touched files is the pre-existing
  `TaskAttachmentDrop.swift:35` `dragType` isolation warning, also present in Batch 3.
- Standalone real-source harness (`.build/batch4/policy-harness/`, `run-2.log`): **48/48
  `SubtaskPanelTests` PASS.**
  - It compiles the real `SubtaskPanelLayout.swift`, `Squircle.swift` and
    `PanelSurfaceHostingView.swift`, plus the real test file with only its two import lines
    stripped.
  - `Stubs.swift` provides a minimal XCTest assertion shim, four constants copied from source
    (`rowHeight` 32, `controlHitSize` 42, `screenInset` 12, `squircleExponent` 5, plus corner
    radius and exponent), a verbatim copy of `constrainedFrame`, `PanelCornerSize`, and a no-op
    `AtticPanelInteractionPolicy`.
  - The first run exposed two wrong inputs in new tests (a hull point, and the post-loop distance);
    the test inputs were corrected, not the product.
  - It does not execute controller, SwiftData, AppKit window or event paths.
- Symlink harness: see Low 1 (`run-1.log` pre/post, `run-2-post.log`).
- **XCTest: one evidence-based attempt, NOT RUN.** `testmanagerd` was still PID 62400, the process of
  both earlier stalls, though it had also served one passing run, so the evidence was mixed. One
  `test-without-building` of `SubtaskPanelControllerTests`, `SubtaskPanelTests`,
  `TaskAttachmentDropTests`, `PanelSurfaceHostingViewTests` and `PanelSquircleGeometryTests` ran
  (`unit-focused-1.log`).
  - The host launched (10:29:48 log lines), then zero `Test Suite` lines after 180 s. Run and host
    were stopped, and the result bundle removed.
  - The watchdog's first stop hit the wrapper shell, so xcodebuild was stopped explicitly
    afterwards; no test process remains.
  - The attempted `sample` captured the zsh wrapper, not the host, and is kept only as
    `host-sample-1-INVALID-sampled-zsh-wrapper.txt`. It is not stall evidence.
  - No retries, and no TCC, security or service changes.
- `git diff --check`: clean.

### Unverified — needs live or physical validation

- Physical gestures, all unverified:
  - A two-finger horizontal swipe on an unpinned transient, including a detached one: follows the
    fingers, subtle scale and fade, completion on a half swipe or a quick flick, and smooth restore
    on a short or reversed swipe.
  - Pinned panels ignore it.
  - Vertical scrolling of long subtask lists and galleries never dismisses, including diagonal
    starts, momentum after a vertical flick, and a swipe starting on the text entry.
  - Reduce Motion is a fade only.
  - Magic Mouse and wheel input are unaffected.
  - The reused transient reopens fully opaque after a completed swipe, and after a swipe interrupted
    by main-panel hide.
  - The main panel's own swipe-to-hide still behaves identically.
- Pointer travel: a slow and a fast diagonal from a row to its transient with a pinned family
  nearby and the transient placed around it, crossing the pinned panel and neighbour rows without a
  close or switch. Resting on a neighbour row still browses on the fast dwell. Moving clearly away
  closes. Entering the surface cancels at once.
- Latch: a clicked-open panel survives hovering other rows and scrolling its row out and back. An
  outside click, including on the main composer or a pinned panel, closes it. Clicks in the narrow
  gap do not.
- A press that cancels a swipe mid-gesture reaches its control.
- Live P1 (above): rendered paperclip at 332 pt and the R5 flow on a correctly relaunched preview.
- `AtticUITests/SubtaskHoverPinnedUITests` corridor tests were not updated or run. Their jump-style
  `hover()` samples read as a resting pointer, consistent with the new policy, but this is unverified.

### Interpretations and open risks

- "Crossing pinned panels" is limited to pinned frames that intersect the route hull, so parking on
  an off-route pinned panel closes the transient after the grace.
- Pinned-crossing coverage also keeps the main panel from auto-hiding while an open transient's route
  crosses a pinned panel. With no transient, pinned panels still keep nothing alive.
- Either horizontal swipe direction dismisses, because the motion is an inward scale rather than a
  slide. Main-panel swipes inside the main panel are unaffected.
- The swipe gate excludes surfaces with an in-flight edit, confirmation or menu. A focused or drafting
  subtask entry does not block it, because drafts survive dismissal.
- `PanelSurfaceMotionContainer` changes every surface's view hierarchy: the host now sits inside a
  layer-backed motion view. Hit-testing still goes through the host, and
  `PanelSurfaceHostingViewTests` compile but were not run, so this is a review focus.

## Batch 4 fixes — Batch4SWE-A/B findings, launcher lifecycle, test execution

Diff: `.build/batch4-fixes.diff`, taken against a temporary-index prefix tree captured before any
fix edit (`c08decbe…`). Provenance, digests and logs are in `.build/batch4-fixes/PROVENANCE.md`. No
commits were made, and the real index is untouched. Reviewer reports and the live report were read
only. The running preview (PID 10135) and its store were not relaunched, driven or signalled.

### Gesture findings

- **A F1 (medium), stale 160 ms completion: fixed at two layers.**
  - The owner hands the window a session (`swipeDismissalSession(for:)`), which is the controller's
    `transientSwipeRevision`.
    - The revision is bumped whenever the transient presentation's identity changes in `syncState`:
      family, latch or detach.
    - It is also bumped by every deliberate `openFamilyPanel` of the family already on screen,
      whether that path latches a hover panel or raises an already-latched one.
  - `completeSwipeDismissal(for:session:)` closes only while that session is still current.
  - The window also cancels on any `swipeDismissal` reconfiguration: `didSet` is now unconditional.
    The controller's invalidation cancels the transient window's gesture or completion too.
  - The completion now fires from a generation-guarded `asyncAfter`. It no longer uses the
    Core Animation completion block, which also fires on removal. Behaviour is unchanged
    otherwise.
- **A F2 / B P3, busy and pinned eligibility: fixed.**
  - The window re-reads `session()` for every event of a routed sequence, as `AtticPanel` does. A
    lock, pin or re-open mid-gesture cancels and hands the event to content.
  - At completion, `swipeDismissalSession` repeats the transient, unpinned and not-busy checks.
- **A F3, modifiers and indirect samples: fixed.**
  - `.flagsChanged` joins the interrupts, along with `.smartMagnify`, `.rotate` and `.swipe`.
  - A modifier-bearing, imprecise, phase-less, button-held or momentum sample mid-sequence now
    cancels, and is forwarded to content rather than consumed.
- **B P2, ghost surface: fixed.**
  - An `.ended` or `.cancelled` event counts as a direct sample even when it carries momentum, so
    the tracker always finalizes.
  - A new `.began` restores anything the previous sequence left on screen, through
    `cancelSwipeDismissal`, before routing. `resignKey` cancels an unfinished sequence.
  - Interrupts key off the routed session, not tracker state, so they still heal after the
    tracker resets.
  - The main panel's `AtticPanel` swipe and motion are untouched.

### Lows

- **B P3, cumulative progress: fixed.** `TransientTravel` measures net approach from the last
  renewal (or the start), so steps below 2 pt accumulate. Jitter in place cannot keep renewing, and
  progress stays monotone and bounded.
- **A F4, unused switch deadline: removed.** `switchDecision` defers only on real progress, which
  already bounds it, and no longer leaves a deadline for a later close to inherit.
- **B P3, `dragType` isolation: fixed.** `NoteInlineCardsLayout.dragType` is `nonisolated static
  let`, a constant. The Swift 6 warning is gone from both builds.
- **B note, stale travel on latch: fixed.** Latching an already-presented hover panel resets
  `travel` and reschedules timers, so pending hover work is cancelled rather than left to no-op.
- **B note, `run-1.log` equals `run-2.log` (Batch 4 harness):** historical and not reconstructible.
  In this delta every run keeps its own log.

### Launcher lifecycle (IntegrationLive actionable issue)

- **Cause, from the unified log** (`launcher-lifecycle-evidence.txt`):
  - The launcher started PID 9983 as a plain background child of its shell. launchd tracked it as
    `com.apple.xpc.launchd.unmanaged.AtticTaskPanels.9983`.
  - It logged from 10:36:38.352 and died at 10:36:39.816, about 1.46 s later, with no crash
    report and empty stderr. That is the moment the 1.5 s health check ended and the script
    returned.
  - The native launch, PID 10135, was a LaunchServices job,
    `gui/501/application.com.taha.Attic.taskpanels.v2…`, spawned by xpcproxy with parent launchd,
    and it stayed up.
  - The signal sender is not logged for unmanaged processes. Teardown of the invoking command's
    process group is therefore inferred from timing and process ownership, not proven.
- **Fix:**
  - Launch with `open -n --stdout/--stderr`, so launchd owns the app.
  - Discover the PID by exact executable path within a bounded 20 s wait, and fail if more than
    one instance appears.
  - Check the process across a bounded 3 s stability window. It must be the sole instance, be
    launchd-owned (parent 1), and map the on-disk stub **and** `*.debug.dylib` by inode and size,
    re-checked after hashing.
  - Write `PreviewState/launch-provenance.txt` with PID, parent, start, command, and inode, size
    and SHA-256 for both images.
  - The manifest also records both images' inode, size and SHA-256.
  - New read-only `--verify` mode: it builds, launches, locks and signals nothing, and exits
    nonzero unless the running instance verifies.
- **Checked without launching:**
  - `zsh -n` passes, and `--dry-run` shows the `open -n` launch.
  - `--verify` against live PID 10135 passed read-only (`launcher-verify-live-10135.txt`): sole,
    parent 1, stub `139292913`/41,008, debug dylib `139292911`/20,452,688, SHA-256 `5e68f56f…`,
    matching IntegrationLive. It also exposed the stale `recorded_pid=9983`.
  - A nonexistent preview fails with `found: none`.
  - **Not exercised:** the new launch path itself, which the live owner runs. PID 10135 runs the
    pre-fix build.

### Test execution — the XCTest gate, legitimately bypassed

- **Diagnosis.** The stall is in xcodebuild's IDE session with the host. The earlier host logged
  startup and then never discovered a suite, and `testmanagerd` has been PID 62400 since 06:54.
- **Method.** The real `AtticUnitTestHost` is launched directly with Xcode's
  `libXCTestBundleInject.dylib`. Its `XCTestConfigurationFilePath` points at an offline
  `XCTestConfiguration`: `reportResultsToIDE=NO`, `testsDrivenByIDE=NO`, no session, `testsToRun`
  = the selected identifiers, main-thread execution.
  - `makeconfig.m` writes that configuration, and `run.zsh` runs it with a watchdog.
  - XCTest then runs in-process and logs to stderr. The host exits with XCTest's status.
- **What was left alone.** No TCC, security or daemon changes, no `testmanagerd` restart, and no
  xcodebuild retry. Assertions and test selection are unmodified, and no test was skipped
  (0 "skipped").
- **Runs** (`.build/batch4-fixes/offline-xctest/`):
  - `probe-geometry.log`: 57/57 `PanelSquircleGeometryTests`, the first probe of the method.
  - `focused-1.log`: 152/152 across `PanelSurfaceHostingViewTests`, `SubtaskPanelControllerTests`,
    `SubtaskPanelTests`, `TaskAttachmentDropTests` and `NoteInlineCardsTests`. That build predates
    a one-attribute test-file warning fix.
  - **`final-gate-1.log`, final source: 351/351 in 11 suites, exit 0.** Suites:
    `CornerHoverStateMachineTests`, `NoteAttachmentTests`, `NoteInlineCardsTests`,
    `PanelSquircleGeometryTests`, `PanelSurfaceHostingViewTests` (10),
    `SubtaskPanelControllerTests` (68), `SubtaskPanelTests` (49), `SubtaskTests`,
    `TaskAttachmentDropTests`, `TaskImageTests` and `TaskStoreTests`.
- **Mutation check** (`MUTATIONS.md`). In an isolated copy, since deleted, the fixes were re-broken
  in production code only.
  - Seven of the ten new tests target a pre-fix defect, and all seven failed under their mutation.
    Momentum was isolated in a second round because another mutation masked it.
  - The other three guard baseline routing or the window side of a declined completion, and
    passed as expected.
- **Scope limits.**
  - This is the real XCTest framework in the real unit host, but not an xcodebuild/IDE result
    bundle.
  - `AtticUITests`, including `SubtaskHoverPinnedUITests`, still need testmanagerd and UI
    automation, and were **not run**.
  - Window tests drive the real `PanelSurfaceWindow.sendEvent` with CGEvent-synthesized scroll
    and flags events, on an offscreen window. This is not physical trackpad delivery.

### Tests added or changed

- `PanelSurfaceHostingViewTests`, new; the window glue with delayed completion:
  - `testDecidedSwipeIsConsumedAndCompletesOnlyAfterTheDelay`
  - `testReconfiguringDuringTheCompletionDelayDropsTheStaleCompletion`
  - `testCompletionDeclinedForAStaleSessionRestoresTheSurface`
  - `testTerminalEventCarryingMomentumStillFinalizes`
  - `testNewSequenceAndLostKeyRestoreAnUnfinishedGesture`
  - `testModifierLockOrIndirectSampleMidGestureCancelsAndReachesTheContent`
  - `testPinnedOrIneligibleSurfaceLeavesEveryScrollWithTheContent`
  - The seam is `PanelSurfaceWindow.eventForwardingForTesting`, which receives events otherwise
    passed to `super.sendEvent`.
- `SubtaskPanelControllerTests`, new:
  - `testStaleSwipeCompletionNeverClosesAReopenedLatchedOrReplacedSurface`, covering hover-latch,
    latched re-open, cross-family reuse and close/reopen.
  - `testSwipeCompletionRechecksBusyAndPinnedEligibility`, covering edit, delete confirmation,
    menu tracking and pin.
- `SubtaskPanelControllerTests`, adapted: `testSwipeDismissalIsOfferedOnlyToTheFamilysUnpinnedIdleSurface`
  now uses the session API with the same assertions.
- `SubtaskPanelTests`, new: `testSlowContinuousApproachAccumulatesProgress`. Existing travel tests
  are unchanged and pass.

### Checks

- Local `xcodebuild build` (`build-local-1.log`): BUILD SUCCEEDED, with no warnings in touched
  files.
- `build-for-testing` on final source (`build-for-testing-2.log`): TEST BUILD SUCCEEDED.
- Offline XCTest: see above. `git diff --check`: clean.
- No project inputs changed: no files were added to targets, so regeneration was not needed.

### Still unverified — physical or live

- Physical trackpad feel and the Batch 4 unverified list above are unchanged, including:
  - follow-the-fingers motion, flick and cancel;
  - Reduce Motion;
  - vertical-scroll immunity with real momentum;
  - a click cancelling mid-swipe;
  - the reused transient reopening opaque.
- Live checks for the fixes themselves:
  - a click or row activation during the 160 ms completion keeps the panel;
  - pressing a modifier mid-swipe restores it;
  - a fresh swipe after an interrupted one starts from a live surface.
- The new launcher path, on the next live relaunch: expect a launchd-owned PID that survives the
  launcher's return, plus `launch-provenance.txt`. Run `--verify` again before live checks.
- R6 corridor travel at real pointer speed, and `AtticUITests`.

## Final review fixes — Astra HIGH F1/F2

Review: `Docs/TaskPanelV2FinalAstraReview.md`, read only and not edited. Diff: `.build/final-fixes.diff`.
Provenance, digests and logs are in `.build/final-fixes/PROVENANCE.md`.

- The prefix tree `fa4ce898836f3577f7523c84e9884c520d1efbf5` came from a temporary index
  (`git read-tree HEAD` + `git add -A`, so nonignored untracked files are included). It was
  captured before any edit and equals the final-validation tree `618d631…` plus the Astra
  report, the final-validation report and the orchestration note.
- The real index, commits, preview PID 23135, stores, UI and memory were not touched.
- Only three implementer-owned source/test files changed, plus this ledger.

### F1 — a released family drop target retains itself and its owners: fixed

- **Cause, confirmed:** `SubtaskPanelContent.configureFileDrop` stored a `perform` closure on the
  `TaskFileDropTarget` that strongly captured that same target (for `end()`), as well as the
  store and controller.
  - That formed a cycle (target → callback → target) with no teardown.
  - Reconfiguration swapped one self-capturing closure for another.
- **Fix:** the stored callback captures the target `[weak fileDrop]` and calls `fileDrop?.end()`.
  - Everything else is unchanged:
    - parent/mode routing;
    - latching on transient drops;
    - `canAccept`, which never captured the target;
    - reconfiguration on appear, family change and mode change.
  - No explicit teardown was added, so a reused or promoted host can't be left with cleared
    callbacks.
  - The configuration moved into `static func configureFileDrop(_:parentID:mode:store:subtaskPanels:)`,
    which the view's private method calls. That gives tests a narrow seam that runs the
    production setup.
- **Tests** (`SubtaskPanelControllerTests`):
  - `testFamilyDropCallbacksKeepRoutingWithoutRetainingTheirTarget` uses the production setup.
    - A transient drop clears every highlight source and latches the hover-opened family: a later
      leave with the pointer outside keeps it.
    - It reconfigures for another family in pinned mode, drops the only strong reference and
      asserts that a weak reference to the target is nil.
  - `testDismantledFamilySurfaceReleasesTheOwnersItsDropTargetCaptured` uses the real host.
    - Real `SubtaskPanelContent` runs in `PanelSurfaceHostingView` inside `PanelSurfaceWindow`, as
      `makeSurface` builds it. The controller has presentation disabled.
    - The view configures on appear, then the same host is reused for another family and then
      pinned mode.
    - After the content view is detached and the window closed, the host, controller and store
      must all deallocate.
    - On the pre-fix source the host was released but the controller and store were not.
  - The existing whole-panel highlight and routing tests in `TaskAttachmentDropTests` (21) still
    pass.

### F2 — a busy hover close retries at an already-expired deadline: fixed

- **Cause, confirmed:**
  - When a matured close found `shouldDeferPointerClose` true, it called
    `lifecycle.noteRowHover(false)`. That call is deliberately idempotent, so it kept the expired
    deadline.
  - `rescheduleTimers` then dispatched at `max(0, deadline - now) == 0`, which took the same
    branch again. The result was an asynchronous main-queue spin for as long as the edit, menu,
    draft or focus lock held.
  - This behavior is inherited from the baseline.
  - **Measured on the pre-fix source** by the new tests, in the unit host with presentation
    suppressed: 57,293–71,087 close commits in the first 0.94 s wait (`pre-fix-new-tests.log`). The
    real app would also sample the pointer on each commit.
- **Fix, event-driven with no poller:**
  - **Suspend.** The busy branch records the lifecycle's pending close for that family as
    `suspendedClose`. `rescheduleTimers` schedules no work while that exact value
    (family + deadline) is still the lifecycle's pending close.
    - Any change to the pending close (arrival, source-row re-hover, a corridor re-arm, a fresh
      leave) or its removal (close, pin, detach, replacement) ends the suspension. A new
      deadline then schedules normally.
  - **Resume.** A `uiState.objectWillChange` sink, plus `reconcileStore` (family edit locks read
    store membership), schedules a coalesced next-turn check, and only while a close is
    suspended.
    - If the pending close was replaced or cancelled, the check drops the suspension.
    - If the lock still holds, the check does nothing.
    - Otherwise it calls `commitPendingClose` once. That judges the pointer the ordinary way:
      the surface cancels the close, the corridor defers it within the transit budget, and
      outside closes it.
  - **Lifecycle.** `tearDown` clears the suspension. The sink and the hop capture `self` weakly.
  - **Preserved:**
    - repeated-leave idempotence in `SubtaskPanelLifecycle`, which is unchanged;
    - latched and dragged surfaces, which have no hover close;
    - pinned families, the corridor budget and arrival;
    - drafts, since a close never clears them;
    - no close while any surface lock holds.
  - **Test seam:** `pendingCloseCommitCount`, which counts close maturities, next to
    `chromeRefitRequestCount`.
- **Tests** (`SubtaskPanelControllerTests`):
  - `testProtectedHoverCloseWaitsWithoutRetryingAndClosesOnceTheLockLifts` covers the draft,
    focused entry, child edit and menu-tracking locks.
    - With the pointer outside, across two waits of six close graces each, the count stays exactly
      1 and the panel stays open.
    - Lifting the lock, with no hover callback, closes it with exactly one more commit.
  - `testRepeatedProtectedDeadlinesEachWaitOnceAndResumeJudgesThePointer`:
    - arrival cancels a waiting close;
    - a fresh leave matures once, then waits;
    - rename typing under the lock re-judges nothing;
    - ending the edit while the hand is in the corridor defers instead of closing on the spot, and
      the panel then closes once the pointer is outside.
  - `testWaitingCloseNeverOutlivesReplacementPinDetachOrTeardown` covers explicit replacement,
    pin, drag-detach and `tearDown` while a close waits.
    - The draft survives, and lifting the lock afterwards runs no stale close.
    - The resulting transient or pinned state matches each case.
  - `testControllerWaitingOnALockStillDeallocates`: a suspended controller deallocates, and a lock
    change afterwards is harmless. Its deallocation asserts guard the new observer; the old defect
    fails only its count assert.

### Checks

- **Old behavior fails.** A seams-only source (tree `34d6f58f…`: static configure seam, counter,
  tests, no behavior fix) was built into `.build/final-fixes/DerivedData`.
  - The six new tests gave **29 failures across all 6** (`pre-fix-new-tests.log`, exit 1). These
    were:
    - F1: target retained; in the real host, controller and store retained;
    - F2: the commit counts above, in every lock, repeat and ending case.
  - The same DerivedData was then rebuilt incrementally from the fixed source, so the seams-only
    images are recorded only by hash in that log.
- **Builds on final source**, separate DerivedData `.build/final-fixes/DerivedData`, so earlier
  evidence products are untouched:
  - `build-for-testing-1.log`: TEST BUILD SUCCEEDED.
  - `build-local-1.log`: `xcodebuild build … -configuration Local … CODE_SIGNING_ALLOWED=NO`,
    BUILD SUCCEEDED, with no warnings in the touched files.
  - Local app `Attic.debug.dylib` SHA-256: `d2d4ddd5…e6559`.
- **Offline in-host XCTest.** The runner `run.zsh`, `makeconfig` and `makeconfig.m` are
  byte-identical to `.build/final-validation`. Each suite ran once, with no retries and no IDE.
  - Final images: host stub `2287db13…`, host debug dylib `5bfb5d18…54e31`, test bundle
    `737c902d…47cc`.
  - `new-tests-1.log`: 6/6 passed, 0 failures.
  - `focused-1.log`: 190 executed, 0 failures, 0 skipped. Suites: `SubtaskPanelControllerTests`
    74, `SubtaskPanelTests` 49, `SubtaskTests` 24, `TaskAttachmentDropTests` 21,
    `PanelSurfaceHostingViewTests` 10, `PanelUIStateTests` 12.
  - `full-suite-1.log`, the full suite run once: all 39 classes, **767 executed, 764 passed,
    3 skipped, 0 failures**, exit 0.
    - Per-suite counts equal the final validation's except `SubtaskPanelControllerTests`, which
      went from 68 to 74.
    - The skips are the same three opt-in environment gates: MCP Node interop and two
      `ATTIC_MOTION_VISUAL_TEST` tests.
- `git diff --check`: clean.
- `verify_project_generation.rb` (Homebrew Ruby): the project is current. No project inputs
  changed.

### Still unverified — gaps

- Nothing here is live or physical evidence. PID 23135 predates both fixes. A rebuilt preview and
  a live check are the live owner's job:
  - open, pin, close and reopen a family, then drop a file on the surface;
  - with a hover-opened panel typing a subtask or renaming a child, move the pointer away: the
    panel stays and CPU stays idle; ending the edit closes it once.
- There is no Instruments or memory-graph measurement of a live closed-window graph, and no live
  CPU sample in the protected state.
- **Residual, reviewed but not changed (out of F2 scope):** the resume check hops once per
  `PanelUIState` publish while a close is suspended, which scales with events and is not a timer.
  `commitPendingOpen` still re-arms a *different* row's pending open every `openDwell` (0.35 s)
  while the open surface is busy and the pointer rests on that row. That is a bounded periodic
  re-arm left in place by Astra's review, not a zero-delay spin.
- `AtticUITests`, physical R6 and R7, native drags and the keyboard/VoiceOver gates are unchanged
  from the lists above.

## Remaining batches

- 3 — Two SWE source reviews of `.build/batch3.diff`: done (three fixes requested). Fix delta
  `.build/batch3-fixes.diff`: implemented, built, tests compiled but not executed (runner stall).
  Pending: two SWE delta reviews; runner recovery, then the focused and adjacent suites; live
  local-preview UAT of both unverified lists above.
- 4 — Implemented with the live P1 root cause and both FixSWE-A Lows (`.build/batch4.diff`),
  reviewed by Batch4SWE-A/B. The fix delta `.build/batch4-fixes.diff` covers every actionable
  finding and the launcher lifecycle.
  - Pending: two SWE fix reviews, then live UAT of the Batch 4 unverified lists.
  - The preview must be rebuilt from this source, because PID 10135 runs the pre-fix image. Launch
    it with the updated launcher and confirm with `--verify`.
- 5 — Integrated review and Astra high final review: done. Its F1/F2 fixes are implemented and
  tested (see "Final review fixes"). Pending: Astra HIGH verification of that delta, a preview
  rebuilt from this source with live UAT, and resources. Final-integration backlog:
  - **Required test gate.** Unit suites were executed in Batch 4 fixes through the offline in-host
    XCTest configuration (`.build/batch4-fixes/offline-xctest/run.zsh`): 351/351 in 11 suites.
    Final integration should re-run it on the integrated source. `AtticUITests` remain
    **unexecuted**. The original list:
    - `TaskAttachmentDropTests`, `TaskImageTests`, `NoteAttachmentTests` and `TaskStoreTests`
    - `SubtaskTests`, `SubtaskPanelControllerTests` and `SubtaskPanelTests` (the latter only
      harness-run)
    - `PanelSurfaceHostingViewTests`, `PanelSquircleGeometryTests` and
      `CornerHoverStateMachineTests`
    - `AtticUITests` including `SubtaskHoverPinnedUITests`
    - Final review must not accept compile success or harness runs as a substitute.
  - **Keyboard clipped-title disclosure: unverified live.** Batch 2 live could not get task-row
    controls to take keyboard focus (`TaskPanelV2Batch2Live.md`). It is covered only by
    `testKeyboardFocusDisclosesOnlyClippedTitlesOutsideEditing`, which has not run.
  - Batch 3 live lists: drop overlays, card routing, promises, reveal, launch sweep. Physical drag
    sessions were undeliverable via CUA.
  - Batch 4 physical gestures and pointer travel (above).
  - Preview provenance: the launcher now records the `debug.dylib` hash and inode and the running
    PID's mapped images (`launch-provenance.txt`, `--verify`). This is unexercised on a fresh
    launch.
