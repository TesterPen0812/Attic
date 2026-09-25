# Design system change log

The design system (`Attic/DesignSystem/`) was frozen when the owner signed off
the Phase 0 gallery. Every later change is recorded here: what changed, why,
and whether anything looks different.

| Date | Stream | Change | Why | Visual change |
| --- | --- | --- | --- | --- |
| 2026-09-25 | Phase 1 Shell | `AtticPageSwitch.Item` gains optional `keyEquivalent` (⌘ + key selects the page) and `accessibilityIdentifier` (default: the title). | The panel header needs ⌘1/⌘2/⌘3 and stable UI-test identifiers on the real switch. | None. |
| 2026-09-25 | Phase 1 Shell | New `AtticMenuItems(commands:)`: the items of a native menu built from `AtticMenuCommand`s; `AtticCommandMenu` now uses it. | Context menus and the menu-bar menu show the same items, sections and shortcuts as command menus. | None. |
| 2026-09-25 | Phase 1 Shell | New `AtticNotice` (and `AtticNoticeMetrics.gap = 8`): a raised capsule like the toast, warning icon and message (up to two lines, full text as tooltip and VoiceOver label), optional Retry, Dismiss. | The panel's error state ("a problem is never hidden, with the next step as a button"); `AtticErrorLine` is single-line and has no dismiss. | New component. |
| 2026-09-25 | Phase 1 Shell | `AtticPanelStageSurface` and `AtticPanelRim` moved from the debug-only gallery into `Primitives/AtticMaterials.swift`; the rim is hidden from VoiceOver. | The live panel draws the same surface and rim as the gallery. | None. |
