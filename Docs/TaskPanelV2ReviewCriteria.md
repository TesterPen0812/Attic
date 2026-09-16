# Task panel V2 independent review criteria

The independent review compares each implementation batch with the exact snapshot at
`.build/v2-baseline` (`b6d6dabcf0ba00fc40c7e9b87ebf5c258a0ce0ae`). The written contract in
`TaskPanelV2Requirements.md` takes priority over incidental content in the reference
images. Implementer reports are routing information, not acceptance evidence.

Review goes beyond checklist compliance. It judges overall correctness, code quality,
maintainability, architecture fit, performance and resource cost, local data durability,
accessibility, and regressions inside and outside changed paths. Findings must identify
severity, exact file and line, a causal explanation, and meaningful validation. Avoid
speculative style churn. Keep source review, tests/builds, preview provenance, and live
UI evidence distinct.

## Batch 1 — R1 rows and R8 surface/control glass

- Non-editing titles stay on one line at every supported panel width. Long titles use a
  soft trailing fade, while hover, keyboard focus, editing, and accessibility expose the
  full title. Editing must preserve the complete draft and existing commit/cancel rules.
- Row height and content positions remain stable between normal, hover, keyboard focus,
  family-presented, pinned, attachment-importing, and metadata states.
- The hover/focus surface uses a subtle continuous-corner or superellipse shape. The
  ellipsis slot is always reserved, while the visible control appears only on row hover
  or keyboard focus. Its hidden state must not leave an invisible actionable control in
  the accessibility tree.
- Attachment preview/count and subtask progress are passive metadata without button
  styling or independent panel/popover behavior. The task row opens its family panel.
  Existing attachment actions remain reachable through the task menu until the gallery
  batch replaces them.
- The pinned marker is tiny and muted near the title, has the tooltip `Panel pinned`, and
  activates by revealing the existing pinned family. It never creates or replaces a
  panel. Pin and unpin controls remain inside the subpanel.
- Parent and child rows remain draggable over their usable area. New row activation,
  metadata, pinned-marker, menu, context-menu, drop, and double-click layers must not
  steal task reorder gestures. Child behavior preserves the one-level hierarchy and
  resolves family actions to the parent.
- Row activation and neutral hover preserve the existing family lifecycle. Deliberately
  latched or dragged subpanels remain open until outside click, and approved main-panel
  motion and idle dismissal remain unchanged.
- Panel translucency changes only the main and auxiliary panel surfaces. Pin, completion,
  composer, view-switch, and equivalent controls remain Liquid Glass with translucency
  both off and on. Pinned glass keeps its heavier treatment. Reduce Transparency and all
  supported themes remain readable without erasing this distinction.
- Settings copy says: `Changes the panel surface. Controls always use Liquid Glass.`
  Defaults, persistence, and migration remain compatible. Batch 1 must not affect
  `ATTIC_LOCAL_ONLY`, signing, entitlements, stores, or user data.
- Hover and reveal animation respects Reduce Motion. Keyboard and VoiceOver users can
  discover the full title, metadata values, pinned reveal, status, menu, row-open action,
  and attachment action without duplicate or conflicting semantics.

## Regression and quality review

- Trace the gesture and hit-test stack for single click, double click, drag, drop,
  context menu, status, pinned reveal, and trailing menu. Validate the behavior rather
  than accepting modifier order by inspection.
- Preserve parent/child status rules, completion confirmation, completed-item sorting,
  rename drafts and focus across pin/unpin, duplicate-safe UUID mutations, task-image
  imports, attachment menu access, and rollback behavior.
- Preserve row anchor publication, transient/pinned family identity and position,
  corridor behavior, painted-surface hit ownership, transparent-corner pass-through,
  main-panel idle auto-hide, and deliberate subpanel latching.
- Reject new repeated timers, unbounded work in row bodies, image decoding or data copies
  during layout, unstable identity, duplicated state ownership, or architecture that
  makes later unified-gallery batches harder to implement safely.
- Inspect callers and consumers outside changed files when shared styles, environments,
  settings, task semantics, or panel-controller behavior changes. A passing focused test
  does not excuse a concrete regression elsewhere.

## Evidence expected

- Review the exact changed files and diff against `.build/v2-baseline`, then inspect the
  relevant surrounding source and tests.
- Focused automated coverage should address title/layout stability where meaningfully
  extractable, passive metadata and pinned reveal semantics, surface/control style
  resolution across translucency and accessibility settings, and settings persistence.
- Existing relevant suites include `PanelSurfaceHostingViewTests`, `SubtaskPanelTests`,
  `SubtaskPanelControllerTests`, `SubtaskTests`, `TaskImageTests`, and `AppSettingsTests`.
  Targeted UI coverage should exercise hover and keyboard focus, layout stability, full
  long-title access, parent/child drag, pinned reveal identity, preserved attachment menu,
  and surface/control appearance in solid, clear, and frosted configurations.
- Compilation and automated tests do not prove rendered appearance, physical gestures,
  VoiceOver quality, installed-preview identity, resource use, or release readiness.
  Record these as separate evidence or explicitly unverified.

## Primary review paths

- `Attic/Views/Panel/TaskRowView.swift`
- `Attic/Views/Panel/TaskFamilyView.swift`
- `Attic/Views/Panel/TaskSectionView.swift`
- `Attic/Views/Panel/AtticPanelView.swift`
- `Attic/Views/Panel/SubtaskPanelContent.swift`
- `Attic/Views/Panel/TaskStatusButton.swift`
- `Attic/Views/Panel/TaskImageAttachments.swift`
- `Attic/Design/AtticPanelTheme.swift`
- `Attic/Design/AtticStyle.swift`
- `Attic/Design/TaskActionsMenu.swift`
- `Attic/Window/PanelSurfaceHostingView.swift`
- `Attic/Window/AtticPanel.swift`
- `Attic/Window/AtticPanelController.swift`
- `Attic/Window/SubtaskPanelController.swift`
- `Attic/Window/PanelUIState.swift`
- `Attic/Services/AppSettings.swift`
- `Attic/Services/SubtaskPanelLayout.swift`
- `Attic/Services/TaskStore.swift`
- `Attic/Views/Settings/PanelSettingsView.swift`
- `AtticTests/PanelSurfaceHostingViewTests.swift`
- `AtticTests/SubtaskPanelTests.swift`
- `AtticTests/SubtaskPanelControllerTests.swift`
- `AtticTests/SubtaskTests.swift`
- `AtticTests/TaskImageTests.swift`
- `AtticTests/AppSettingsTests.swift`
- `AtticUITests/SubtaskHoverPinnedUITests.swift`
