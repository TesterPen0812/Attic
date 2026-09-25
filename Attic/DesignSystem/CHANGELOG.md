# Design system change log

The design system was frozen when the owner signed off the Phase 0 gallery.
Every later change is recorded here: what changed, why, and who asked.

## Phase 1 · Shell stream (redesign/p1-shell)

All additive; no token, colour, radius or type style changed.

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
