# Task panel V2 — Batch 1 live UI validation

Date: 2026-09-13. Scope: Batch 1 R1 row/control foundation and R8 surface/control
separation. This is local-only preview evidence, not production, CloudKit, APNs,
iPhone, TestFlight, or release validation.

## Source and preview identity

- Worktree: `/Users/taha/Developer/attic-task-panels-v2`
- Branch: `codex/attic-task-panels-v2`
- HEAD: `ae6418c1af690e29d15a20344cdb9765a23d3f85`
- Source state: dirty, as expected from the inherited UX baseline plus Batch 1. Before
  this report was added, `git status --porcelain=v1` contained 63 paths and had SHA-256
  `f74f5c2ebc5993025782297dd49e74fcad88ff94a7b5f9a4a797764b25efc8f3`.
- Batch snapshot: `.build/batch1.diff`, SHA-256
  `e02a0e8cfd40a32a259f1f5e7013492d9b003648ade3606432be3c61e1af823b`.
- Manual preview: `Attic Task Panels V2`, bundle
  `com.taha.Attic.taskpanels.v2`, executable `AtticTaskPanelsV2` at
  `.build/TaskPanelsV2Preview/Build/Products/Local/AtticTaskPanelsV2.app/Contents/MacOS/AtticTaskPanelsV2`.
  Executable SHA-256:
  `fbdb2226e5d51ab318f54c51d01bef66f028a43e3635fa8e5149df06bec3f9a3`.
- The launch manifest and entitlements are under `.build/TaskPanelsV2Preview/PreviewState/`.
  The ad-hoc signed Local build contained sandbox, user-selected file access,
  get-task-allow and network entitlements; it contained no CloudKit, ubiquity, or APNs
  entitlement.
- Focused UI-test host: `Attic Task Panels V2 UI`, bundle
  `com.taha.Attic.taskpanels.v2.uitest`, executable SHA-256
  `66b962c89cb25e22c356dfd38f73fa2800cafe8c861642e9feaeed8f6bb7c42c`.
- The prior `com.taha.Attic.ux.refinement` preview and its data were not changed.

## Direct rendered observations

- In the dark preview, a deliberately long title rendered as one compact line inside the
  existing 42 pt row. It did not wrap or expand the row.
- The clipped title ended in a soft trailing fade. The visible ellipsis occupied a separate
  trailing slot and did not displace the title or metadata while the pointer was on the row.
- The hover background used the expected subtle continuous-corner shape. Top pin/status
  and bottom composer controls retained the current glass appearance on the observed panel.
- Accessibility exposed the entire long title on the row and title text even though the
  rendered title was clipped.
- The manual CUA session could not reliably keep the auto-hiding main panel exposed after
  an accessibility click. Interaction conclusions below therefore come from the focused
  native UI tests, with the rendered observations kept separate.

## Focused native interaction result

Command: `Scripts/run_local_ui_tests.zsh` with four explicit test selections and isolated
app/test bundle identities. Result: 4 tests, 3 passed, 1 failed. Evidence:
`.build/batch1-live/focused-ui.log`, `.build/batch1-live/FocusedUI.xcresult`, and exported
failure artifacts under `.build/batch1-live/FocusedUIAttachmentsAll/`.

Passed:

- `testCreateAdvanceCompleteAndOpenContextMenu`: parent row double-click status shortcut
  and the hover-revealed ellipsis menu remained usable.
- `testDragReordersTasksWithMatchingPriority`: task row dragging/reordering remained usable.
- `testPinnedFamilyShowsQuietStatusThatRevealsPanel`: passive progress was not exposed as a
  button; pinning showed the quiet `Panel pinned` marker; activating it revealed the same
  pinned family; unpinning removed the marker.

The failing `testCompactComposerAndSubtaskPanels` still verified these paths before its
failure:

- the ellipsis menu opened and `Add subtask…` created the family panel;
- two child rows were created and progress was exposed as passive `0 of 2 complete`
  metadata;
- completing a child updated progress to `1 of 2 complete` without changing the parent;
- an outside click dismissed the latched panel while preserving its draft;
- clicking the parent row reopened the same family with `Draft step` still present. The
  captured hierarchy showed one transient family surface and no duplicate family window,
  so this path did not instantly close/reopen or duplicate the panel.

## Initial-run defect (superseded by the fix-snapshot revalidation below)

`testCompactComposerAndSubtaskPanels` failed at the Escape-cancel step. After Escape, the
expected `add-subtask-<parent>` affordance never appeared. The captured hierarchy still
contained the open family panel and `subtask-title-<parent>` text field with value
`Draft step`. Expected behavior is for Escape in the entry field to discard the deliberate
draft and collapse the composer. This blocks claiming the full child/status/pin continuation
of that test from this snapshot. The earlier verified row reopening behavior remains valid.

## Not verified in the initial pass

- Full Keyboard Access focus reveal, focus-only full-title disclosure, and VoiceOver hints.
- Ellipsis hidden state away from hover, menu-open persistence, and pixel-level no-jump
  comparison; the hovered state and reserved trailing area were observed.
- Passive image metadata and `Show attached images`; no image fixture was added. Existing
  attachment reachability remains pending Batch 2/live follow-up.
- Child-row drag reorder specifically. Parent row reorder passed; child status interaction
  passed in the longer test before its failure.
- Solid, clear, frosted, glassmorphism, Reduce Transparency, and pinned-heavy-glass matrix.
  Only the observed dark preview surface was inspected. The independent source review has
  already identified glassmorphism/material control policy and focus-only full-title
  disclosure issues, so this pass did not duplicate those checks before fixes.
- Physical trackpad dismissal is Batch 4 scope and was not exercised.

## Fix-snapshot revalidation

The review fixes were validated against a frozen rebuilt executable before the later
observer-lifecycle source follow-up began:

- Fix delta: `.build/batch1-fixes.diff`, SHA-256
  `6331e0910e069ef8e3f75e7edcf646ecf5f4f3621b0dd9efa3407955b4b3809a`.
- Cumulative Batch 1 snapshot at that point: `.build/batch1.diff`, SHA-256
  `2c93c1ee33632a5e25f034dce918358443d5cecedb93746291f3f9fc5253dcf3`.
- Frozen source status before rebuilding: 64 porcelain paths, SHA-256
  `c8381e7afa147aa87f74b334b9cdf7588c88d5f466621820113f2166f69d5f56`.
- Rebuilt manual preview kept the same display name, bundle ID, executable name and isolated
  store. Its new executable SHA-256 was
  `af521bd3fbc44f3fdce83c24cf60f73185734da4f2d933227b31a5bd94112cf1`.
  Build/launch evidence: `.build/batch1-live/launch-fixes.log`.

### Escape and composer path

The corrected `testCompactComposerAndSubtaskPanels` sequencing now clicked the preserved
`Draft step` field before Escape. The rerun passed that formerly failing section: Escape
discarded the deliberate draft and exposed the collapsed Add subtask affordance; that
affordance reopened and focused the entry. The same run then pinned and unpinned the family
successfully and saved the screenshot
`.build/batch1-live/CompactComposerFixAttachments/901D5A52-E601-4431-AF3E-DA47948D8B4A.png`.
This confirms the product's deliberate behavior: outside dismissal and row reopening preserve
the draft, while Escape cancels only when the entry has focus.

The end-to-end test then failed later, at the unfinished-child parent-completion warning test
assertion. With
the parent `Plan weekend trip` in To do, `Choose destination` complete, `Book accommodation`
incomplete and passive progress `1 of 2 complete`, the test clicked the parent's
`complete-task-<parent>` control. The stale `panel-error-message` assertion did not become true
within two seconds and the parent remained To do. The retained hierarchy actually contained a
keyboard-focused confirmation sheet titled `Complete this task?`, with `Complete anyway` and
`Cancel` buttons. The product's confirmation presentation therefore passed; the assertion was
wrong. Neither confirmation button was selected in this run, so Cancel/override preservation
remained unverified at this snapshot. The failure hierarchy also showed the one open transient
family, the completed and incomplete child states, and the parent's `Mark done` control. Evidence:
`.build/batch1-live/CompactComposerFix.xcresult`,
`.build/batch1-live/compact-composer-fix.log`,
`.build/batch1-live/compact-composer-fix-activities.json`, and
`.build/batch1-live/CompactComposerFixAttachments/15F291E2-6E05-4DBA-84BD-268F3B68352C.txt`.
The Batch 2 test correction now asserts this sheet and both branches directly.

### Surface/control visuals

On the frozen executable, the isolated Appearance setting was changed from Original/Clear
translucent to Glassmorphism translucent, then to a solid panel. In both rendered captures:

- the panel surface changed visibly;
- the top pin/section controls and bottom composer retained the rounded refractive Liquid Glass
  treatment rather than flattening into the panel material;
- control shape, placement and label layout stayed stable across the surface changes.

The preview was restored to translucent Original/Clear afterward. Reduce Transparency and the
pinned-heavy-glass state were not changed or claimed.

### Keyboard disclosure limit

Full Keyboard Access was disabled on the host (`AppleKeyboardUIMode = 0`). It was not changed,
so the focus-only clipped-title expansion could not be exercised with forward/reverse keyboard
traversal. The corrected row help was visible in accessibility as `Click to show subtasks.
Double-click to start`. The earlier full-title accessibility label and hover fade observation
still stand. Alignment during focused scrolling, key loss, child-row focus and menu traversal
remain unverified pending an authorized host state that exposes button focus.

The UI lock was released after each native/manual run. No production source was edited by this
validation.
