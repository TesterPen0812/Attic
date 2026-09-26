# Design system change log

The design system was frozen when the owner signed off the Phase 0 gallery.
Every later change is recorded here: what changed, why, and who asked.

## Phase 1

Phase 1 (Shell, Tasks and Settings) was built in three streams and integrated
on `redesign/phase-1`. Every change below is additive: no token, colour, radius
or type style changed.

### Shell (redesign/p1-shell)

- **`AtticPageSwitch.Item` gains `keyEquivalent` and `accessibilityIdentifier`**
  (both optional; the identifier defaults to the title). The panel header needs
  ⌘1/⌘2/⌘3 on the real switch and stable UI-test identifiers. No visual change.
- **New `AtticMenuItems(commands:)`**: the items of a native menu built from
  `AtticMenuCommand`s (sections, symbols, shortcuts shown); `AtticCommandMenu`
  now uses it. The panel's right-click menu and the menu-bar menu show the same
  items, sections and shortcuts as command menus. No visual change.
- **New `AtticNotice`** (and `AtticNoticeMetrics.gap = 8`): a raised capsule like
  the toast, with a warning icon, the message (up to two lines, the full text as
  tooltip and VoiceOver label), an optional Retry and Dismiss. The panel's error
  state ("a problem is never hidden, with the next step as a button");
  `AtticErrorLine` is single-line and has no dismiss. New component.
- **`AtticPanelStageSurface` and `AtticPanelRim` moved** from the debug-only
  gallery into `Primitives/AtticMaterials.swift`; the rim is hidden from
  VoiceOver. The live panel draws the same surface and rim as the gallery.
  No visual change.

### Tasks (redesign/p1-tasks)

- **Task keys: ⇧Space completes** (`AtticTaskKeys`). ⌥Space still works, but
  launchers (Raycast, ChatGPT) take it on many Macs, so it never reaches Attic
  there. Proposed replacement for the spec's keymap; ⌥Space kept as an alias.
- **Keyboard-only focus rings** (`AtticKeyboardFocus.swift`: the
  `atticKeyboardFocusVisible` environment value and `AtticKeyboardFocusTracker`).
  Owner decision 2026-09-25: rings show only while the keyboard drives (Tab or
  an arrow turns them on, a click turns them off). Task rows and the add bar
  read it. The default is true, so the gallery and captures still draw pinned
  focus states.
- **Task row** (`AtticTaskRow`): `onSelect` (a click selects in Phase 1; the
  row opens its page in Phase 3), `focus` (a list-owned `FocusState<UUID?>`, so
  ↑ ↓ move focus from row to row) and `titleEditing` (Return or a double-click
  edits the title in place: Return saves, Esc cancels, leaving saves). New
  `AtticRowFocus`, `AtticTitleEditing`, `AtticRowTitleEditor`.
- **Quick look** (`AtticQuickLook`): `newSubtask`, an unticked box and the
  title field in place of "Add subtask" while a subtask is being written.
- **Add bar** (`AtticAddBar`): a live init with a run-time placeholder, the
  leading glyph (`magnifyingglass` when the bar searches the Done log),
  `showsSend`, and `tokens`, the new `AtticTokenField`: a native text view that
  draws recognised pieces (#tag, a date, `!`) as chips (a pill in the selection
  fill behind the text as typed, the text in the heading ink: on the raised bar
  the tag's accent grey on the tag fill measured 2.77 : 1 in Dark, and heading
  on the tag fill 4.42 : 1 on Dark Porcelain Glass); Backspace after a chip turns it back into text; ⌘Return, Esc,
  multi-line paste and ⌘Z (typing first, then the page) are reported to the
  owner. Captures draw the same chips with SwiftUI (`AtticChipText`); the
  gallery's add bar board shows them and the Done page's search bar.
- **Selection bar** (`AtticSelectionBar.Action.menu`): a button can open a
  native menu (state, priority, tag) instead of acting.

### Settings (redesign/p1-settings)

- **New `AtticSettingsPageComponents.swift`** for the rebuilt Settings pages:
  `AtticSettingsScrollPage` (a page's scrolling body under the fixed header:
  group inset 16, content 52 pt below the header, a 12 pt ease-in under the
  header and the page blurring out over the bottom 58 pt along the veil ramp,
  `AtticSettingsEdgeMask`); `AtticActionRow` (a title, or label over value,
  with a small raised button: Copy, Open Login Items, Empty…);
  `AtticStatusRow` (a state line); `AtticGroupMessage` (information, warning
  or error inside a card, helper text that may wrap, optional action);
  `AtticGroupFootnote` (helper text under a card); `AtticGroupEmptyRow` (the
  quiet italic empty line inside a card); `AtticDeletedItemRow` (Recently
  Deleted: kind icon, title over "Deleted 3 days ago · with 2 subtasks",
  Restore); `AtticSearchField` (recessed, 32 tall, control corner rule, clear
  button, Esc clears); metrics in `AtticSettingsRowMetrics` and
  `AtticSettingsPageMetrics`; helpers `atticIdentifier(_:)` and
  `atticFocused(_:)`. Why: Settings needed rows with actions, messages, a list
  and a search field, and the spec forbids hand-rolled looks outside the
  design system. Asked for by the Settings brief (Recently Deleted page).
- **`AtticSliderRow`**: optional `step` (the value is rounded as it moves; the
  slider stays continuous, because a stepped macOS slider draws one tick per
  step, a solid comb on the Width slider), `accessibilityValue` (what
  VoiceOver reads when it differs from the visible value: "0.2 seconds" for
  "0.2 s") and `identifier`; disabled (Tint length while Tint is Off) the
  label and value take the disabled ink.
- **`AtticSidebarRow`**: `identifier`, and `keyboardFocused` (the sidebar that
  owns focus says when the row shows its ring, so a click never draws one,
  owner rule 2026-09-25); `isSelected` now also removes the selected trait
  when false.
- **`AtticPopUpRow`, `AtticSwitchRow`, `AtticModeTile`, `AtticPaletteTile`**:
  an `identifier` for UI tests; tiles report "Selected / Not selected" and
  drop the selected trait when not selected.
- **`AtticGroupDivider`**: `leadingInset` (40 for rows that lead with an icon,
  so the divider still starts at the text column).
- **`AtticAppearancePreview`**: `accessibilityLabel`, so the preview can say
  which look it shows.

### Integration (redesign/phase-1)

- **New `AtticRecipeShapeBackground` and `AtticRaisedShapeBackground`**: the
  drawn raised recipe in any insettable control shape (circle, capsule, the
  panel's squircle); `AtticRecipeBackground` now draws through it with a
  rounded rectangle, unchanged. The older panel controls that go through
  `atticGlassControl` (Notes, Canvas, subtask and attachment controls) draw
  `AtticRaisedShapeBackground` while the panel is not key, the same rule as
  the design system's own controls (native glass renders flat in a window
  that is not key). Asked for by the Phase 1 shell review (finding 3).
- **`AtticPanelRim` is the one panel edge**: Settings' Appearance miniature
  draws it instead of its own copy; the inner rim's corner is clamped at 0
  (the copy's guard). No visual change.
- `Squircle` (Attic/Design) is now an `InsettableShape`, so the recipe's
  inner rim can sit inside it. No visual change for existing callers.

### Direction A trial (redesign/p1-direction-a)

A trial the owner compares with the Phase 1 preview (brief: phase1/direction-a-brief.md,
mockup v11-direction-a). Unlike the streams above, these change existing looks.

- **Status circle: one grey, one weight.** Every open ring is `priorityNone` at
  1.4 pt (1.8 with Increase Contrast); `ringWidth(increaseContrast:)` replaces the
  per-priority widths, and the circle no longer takes a priority or a progress.
  In progress is the ring a step darker (`priorityMedium`) with a filled centre dot
  (`activeDotDiameter` 4.8); the pie, `minimumWedge` and `wedgeSweep` are gone.
  Completing sweeps the done disc in from 12 o'clock as before.
- **Priority is a mark** (`AtticPriorityMark`): High "!!" in the new `priorityMark`
  ink (orange, Light #E2711D / Dark #F0A04E before tuning: a redder orange stays orange, not brown, at 3 : 1; secondary text, 3 : 1, 4.5 : 1
  under Increase Contrast), Medium "!" in `helper`, Low and None nothing. New text
  style `priorityMark` (11.5 bold).
- **Due tones** (`AtticTaskRowModel.Due.tone`: quiet, today, overdue) replace
  `isUrgent`: only overdue is red; Today is `body` in the new `rowMetaEmphasis`
  (11.5 medium). New `AtticDueText`.
- **Row anatomy:** the date always sits at the right of the title line; the second
  line holds tags and the subtask checklist ("☑ 1/3", a button with a hover fill,
  `AtticSubtaskChecklistMetrics`), plus a page, files and links when present. The
  trailing "1/3" button and `AtticSubtaskCountMetrics` are gone.
- **Task actions and keys:** `AtticTaskActions` is `toggleDone`, `toggleWorking`,
  `openPage`, `moveToBacklog`, `delete`. Space (and ⌥Space) toggles done, as the
  circle does; ⇧Space starts or stops working. VoiceOver names follow the state
  ("Complete" / "Mark as not done", "Start working" / "Stop working", "Move to Later").
- **New `AtticPageTabs`** (Now · Later · Done chips: 12 pt, 24 tall, `pageTab` /
  `pageTabSelected` styles, the chip fill; one keyboard control, ← →), with
  `AtticLayout.pageTabsX/Top/ToList` (12, 14, 10).
- **New `AtticCompletedLine`** ("Completed today · N ›", `sectionToggle` 12 medium,
  the chevron turns down when open).
- **New `AtticListSearchField`** (28 tall, radius 9, the chip fill): the Done page's
  search at the top of its list.
- **`AtticEmptyLine` is upright 13 pt** (`body` style, `helper` ink); `isFootnote` is gone.
- The page pill (`AtticPagePill`) and the status tabs stay in the design system and
  the gallery, unused by the Tasks page.
