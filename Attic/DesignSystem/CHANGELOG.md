# Design system change log

The design system was frozen when the owner signed off the Phase 0 gallery.
Every later change is recorded here: what changed, why, and who asked.

## Phase 1 · Settings stream (redesign/p1-settings)

All additive; no token, colour, radius or type style changed.

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
