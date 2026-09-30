# Design system change log

The design system was frozen when the owner signed off the Phase 0 gallery.
Every later change is recorded here: what changed, why, and who asked.

## Phase 1

Phase 1 (Shell, Tasks and Settings) was built in three streams and integrated
on `redesign/phase-1`. Every change below is additive: no token, colour, radius
or type style changed.

### Actions-menu Return (GPT-6.1, round 13)

- Bare-key list shortcuts (Return, Space, Shift-Space and Delete) are native
  menu badge hints. Only shortcuts with Command, Control or Option become
  active menu equivalents. `AtticMenuCommand.menuShortcut` / `menuBadge` share
  this policy between `NSMenu` and SwiftUI menu items, including lazy menus.
- The CI trace showed NSMenu's internal tracker changing the highlight to
  Edit Title on Return, then running that action after close. The public
  equivalent override and local event monitors were bypassed. Removed the
  popup subclass and last-highlight redirect; standard AppKit tracking now
  owns Return. Ordinary list shortcuts retain their existing key handlers.
- Requested by the owner to fix Return choosing Edit Title instead of the
  highlighted actions-menu item. No task mutation or persistence changes.

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

### Visual A, "Calm" (redesign/p1-direction-a, on the Direction A trial)

From Astra's visual review (`phase0/runs/p1-astra-visual.md`, variant A). Appearance only.

- **Spacing:** controls 20 from the panel's edges (`AtticStyle.chromeMinimumInset`); header 32
  tall (`capsuleHeight`, pin 32 × 32); tabs 20 under the header, the list 8 under the tabs;
  rows 36 / 52 (highlights 34 / 50) with the title's 18 pt line at row top + 8, details 2 below,
  the circle centred at row top + 17; the 20 → 24 → 48 lines (`textX` 40 in the page's frame);
  dates 24 from the right, 12 pt least gap; "Completed today" 12 below the list, text at 48;
  at least 16 pt between content and the add bar.
- **Controls:** page switch 144 × 32 (selected chip at least 76, others 28, 2 apart, icon slot
  14, gap 6); tabs 4 apart; add bar plus at x 31 (slot 22, 12 pt light), text at 48.
  Radii follow the 42 % rule (13.5 / 9.5 / 10 / 15); Round controls (temporary) gives variant
  C (16 / 12 / 12 / 18). The pinned pin's glyph is regular weight, like a selected page icon.
- **Type:** unselected tabs 12 regular; priority mark 11 semibold; "Completed today" 11.5
  regular with an 8 pt medium chevron.
- **Status circle:** 14 pt outer, 1.25 pt inward stroke (1.5 Increase Contrast), dot 4.5,
  check 1.4.
- **Colours** (Original on Solid, no Tint: the `Calm` enum): surface #FCFBFA / #2C2E2D with a
  24 pt top sheen, task text, strong text, secondary, open ring, High, done disc and check,
  row hover and selection, selected tab and tab hover (new `tabSelected`, `tabHover`), page
  chip, all exact. State fills are overlays that reach the exact colour on the surface
  (`AtticRGBA.overlay(reaching:on:)`). Increase Contrast's secondary starts from #5E645F /
  #BBC1BB and steps darker only where a pressed or selected fill needs it for 4.5 : 1.
- **Drawn control material** (every palette): body #F6F6F3 / #373938, one 0.5 pt outline,
  a top highlight over 8 pt, one y 1 radius 2 shadow. The add bar draws flat (`addBarFlat`):
  #F6F6F3 / #323433 with a #D9DDD6 / #484D48 hairline, no shadow, no rim.
- **Panel:** one 0.5 pt inside edge (black 6 % / white 8 %) on the default surface; elevation
  10 % / 24 %, y 4, radius 12 plus a 3 % / 8 % contact shadow, so the window margin grew to 28.
- The Done search field's placeholder uses the helper grey (it failed 3 : 1 on Frosted).

### Phase 0's qualities in Direction A (redesign/p1-direction-a, owner 2026-09-26)

Supersedes visual A's spacing, header and drawn material (and the owner's two tweaks after it);
visual A's text and surface colours, the priority marks and Completed today stay.

- **Symmetrical header:** new `AtticPageButton` (Phase 0's mode dock): a 36 pt square like the
  pin showing the current page's icon on the selected chip; under the pointer or keyboard focus
  it opens leftward to all three pages (28 pt segments, 2 apart, 96 open), each with a tooltip;
  ⌘1–⌘3 stay; one VoiceOver control ("Pages", valued by the page, a named action per page,
  adjustable). The pin is 36 × 36 (`AtticControlSize.headerControl`); radius 15 by the 42 % rule,
  circles with the temporary Round controls switch. `AtticPageSwitch` stays in the gallery.
- **Quiet tabs:** `AtticPageTabs` are plain labels, 11.5 medium (`pageTab`, `pageTabSelected`),
  selected in the strong ink, others secondary, hover in the task text's ink, 16 apart, no chips;
  "Now" starts on the circles' line.
- **Room:** margins 24; rows 44 / 56 (text block centred, 2 pt between lines;
  `AtticTaskRowMetrics.titleTop(twoLine:)`); circles' left edge 28, titles 56, dates 28 from the
  right; labels 20 under the header, the list 14 under them; the add bar's plus at x 36, text 56.
- **Confident circles:** 16 pt, 1.6 pt ring (2 with Increase Contrast) in the task text's ink
  (`body`), in progress dot 5, Later dashed in the same ink; the done disc as before visual A.
- **Out of focus:** the drawn controls and the add bar use the Craft-style recipe again (as before
  visual A), deepened to the Phase 0 references' weight: Light fill 7.5 % black (face ≈ 19 below
  the surface, the reference's #ECECEC on white), sheen 30 %, rim 14 / 19 / 24 %, shadow 6 %;
  Dark fill 11 % white, rim 26 / 15 / 22 %. The selected chip is 10 % black in Light (8 % white in
  Dark, where more fails the heading over Liquid Glass). The pin's glyph is in the strong ink at
  regular weight, level with the page button's (`AtticRaisedButton.emphasisedGlyph`).
  Visual A's flat recipe (`Calm.controlRecipes`, `addBarFlat`) is kept but unused.
- **SF Pro Rounded in the task list (item 6):** `AtticTextStyle.Spec.rounded`, set for the list's
  styles (`isListText`: `rowTitle`, new `rowTitleActive` 13 medium for in-progress titles,
  `rowMeta`, `rowMetaEmphasis`, `count`, `priorityMark`, `pageTab(Selected)`, `sectionToggle`, and
  new `listBody` for empty states, the add bar, subtasks and the Done search). `font` and `nsFont`
  follow it. Task titles (and the title editor) use the primary ink (`heading`), and so do the
  circles' rings. The header and Settings stay SF Pro.

### Compact round (owner, 2026-09-26)

- **In progress:** `AtticStatusCircle(subtasks:)` draws the centre dot until a subtask is ticked,
  then a true pie of the share ticked, no minimum (`pieShare`); not started keeps the empty ring.
- **Rows 36 / 50**, highlights 30 / 44 (3 pt clear above and below), text and circle centred.
- **No green cast:** every visual-A grey of the default look is the neutral grey of its lightness
  (`AtticRGBA.neutralGrey`); the drawn controls sit on a neutral base.
- **Pure white Light surface** (#FFFFFF, no sheen); the inside edge and shadow stay. The drawn
  control face is now #ECECEC, Phase 0's reference exactly. Dark unchanged.
- **Done search is an inline row** (`AtticListSearchField`): no box, the magnifier (13 pt,
  secondary) on the circles' line, the text on the titles' line, the row's hover, a clear button.
- **Completed today is a disclosure:** its chevron on the circles' line (› / ⌄), its text on the
  titles' line; the component lays itself out across the row. Empty messages start on the tab
  labels' line (x 28); under an empty message Completed today is the next row.

### Phase 0's surfaces and Light palettes (owner, 2026-09-26)

The look ported, not the code: the design system's surface model now carries Phase 0's recipe.

- **Glass and Frosted, Light and Dark, all palettes and Tints:** `AtticSurfaceModel.phase0(_:)` —
  Phase 0's foundation colour (the palette's `opaqueSurface`) and opacity, its Tint stops and wash,
  Frosted's palette wash over `ultraThinMaterial` (`materialWash`), the native material drawn in
  Light under Original's shade (`brightNative`), and the palette's 0.75 pt hairline (`edge`,
  drawn by `AtticPanelRim`). Text on them is not stepped up (the palettes' or the ladder's inks).
- **Light palettes (all but Original), every surface:** Phase 0's Light surface, primary text
  (`heading`, `body`, `label`), secondary text (`helper`, `placeholder`) and accent (`accent`,
  `accentText`), exactly; the page button's current page in the accent (`pageChipAccent`: the
  palette's selected fill and hairline).
- **Unchanged:** Original's Light Solid (pure white, neutral greys) and every Dark Solid.
- **Named contrast exceptions** (tests, the owner decides): `Phase0TranslucentException` (Glass
  and Frosted are far more see-through than the rule allows) and `Phase0AccentException` (the Light
  accents as tag text under Increase Contrast).
- **Follow-up (owner, 2026-09-26):** Glass and Frosted, every palette and both modes, also take
  Phase 0's text: its primary (`heading`, `body`, `label`) and secondary (`helper`, `placeholder`)
  greys, near-black in Light and near-white in Dark. Solid keeps its text.

### Phase 1 final pass (owner, 2026-09-27)

- **Control corners stay at the 42 % rule** (the pin and page button 36 × 36, radius 15). The
  temporary Round controls switch is gone: `AtticRadius.controlFraction` is a constant again.
- **The selected page tab is semibold** (`pageTabSelected`), the others medium, in every look;
  every label reserves its semibold width, so the row never shifts.
- **The page button** reads as one "Pages" group with a named, selectable button per page
  (identifiers `panel-section-*`), open or shut; its `Item` is its own type.
- **Removed** (no caller left outside the gallery): `AtticPageSwitch` and its chip faces and
  metrics, `AtticPagePill` and its glyphs and metrics, `AtticStatusTabs` and their metrics, the
  `statusTab`, `statusTabSelected`, `statusCount` and `pageHeading` text styles, the page-title and
  status-tab layout tokens, visual A's flat add bar (`addBarFlat`, the raised material's `flat`
  option), its control recipes and body, page chip and tab chip colours (`tabSelected`,
  `tabHover`), and the 4.5 pt subtask checkbox radius.
- **Geometry check:** the page button replaces the page switch; the subtask checkbox is measured
  against its own squircle (superellipse, exponent 4).
- **Gallery panel and the Settings miniature** use the live panel's lines (corner-aware 24 pt
  controls inset, 36 pt header, the page 12 inside the panel); the miniature gains the add bar.
- **Done log day headings** take one row's pitch (34 pt), their text on the rows' title line.
- **Out of focus on Glass and Frosted** the panel's controls stay native glass (Phase 0's weight);
  the drawn recipe is for Solid (and Reduce Transparency) only.
- **VoiceOver:** a Later task's state reads "later"; a row being edited exposes its title field.

### Phase 1 round 5 (2026-09-27)

- **One highlight per list** (`AtticChoiceRow.onHover`, `AtticListHighlight`): in the date, tag,
  priority and suggestion lists the list owns its one highlight and the pointer moves it, as in a
  native menu; a hovered row and a keyboard row are never lit together. A row sliding under a
  resting pointer as the keyboard scrolls is not a pointer move. In the date picker the pointer on
  a day moves the keyboard cursor there (within the month shown), and on a quick day's row it
  takes the highlight from the cursor.
- **Highlight gap** (`AtticPickerMetrics.highlightGap`, 2 pt): a choice row's fill (and its focus
  ring) is inset 1 pt top and bottom, so two lit rows never merge into one block. Rows stay 28 pt
  and answer the pointer across their full height.
- **`atticPopover`**: Attic's pop-overs note their window with `AtticTextInput`, so no row or page
  command answers a key while a pop-over has the keyboard (the date picker's Backspace or Space
  never reaches the row's Delete or Complete).

### Phase 1 round 6 (owner decisions, 2026-09-27)

- **Typed pieces, option H** (`AtticTokenChip`, `AtticTokenField`, `AtticChipText`; owner item
  15): no pill. A recognised piece is drawn in the secondary ink (the add bar's placeholder grey,
  tuned on the bar's faces; a title being edited uses the row's helper grey), `!!` in High's orange
  (`priorityMark`), and a date gets its calendar icon before it, drawn by the layout manager as
  decoration (never a character). The icon fades in over 0.18 s while its room (kerning on the
  character before the date) opens, so the words after it move gently; Reduce Motion shows it at
  once. Measured on the bar's faces over every Solid combination: the grey ≥ 3.12 : 1 (4.68 : 1
  with Increase Contrast), the orange ≥ 3.25 : 1 (5.52 : 1); Glass and Frosted stay inside Phase
  0's named translucency exception. Removed: the chip pill (`chipOutset`, `chipFill`).
- **The review switches are the design** (owner item 20): `AtticReviewVariants`, the design
  context's `variants`, the colour key's switch fields and Settings › Compare are gone. Readable
  Glass (`AtticSurfaceModel.readable(primary:secondary:)`), the quiet drawn controls
  (`AtticColorTokens.recipes`), the defined dark edge (`AtticSurfaceModel.definedDarkEdge()`), the
  compact Appearance page and the explicit command names are always on.
- **Priority menus** (owner item 19): `TaskPriority.choices(keeping:)` offers No Priority, Medium
  and High; Low only while a task has it.
- **Strip values** (`AtticComposerStrip`, `AtticStripValue`; owner item 18, v19): a button with a
  value shows it on a filled pill (the recessed fill; the pressed fill while its picker is open)
  with a clear × (14 pt, glyph 8, 7 pt either side); empty, the small button's face as before.
  `!!` in High's orange, `!` in the helper grey. The Tag button opens the tag list. VoiceOver:
  the button's name, its value, and a Clear action. The strip's buttons are 4 pt apart
  (`stripSpacing`, was 2) so two pills never touch. The gallery shows the strip empty and set.
- **Done search on the tabs line** (`AtticTabsSearchField`, `AtticTabsSearchMetrics`; owner item
  17, card B of v22): replaces `AtticListSearchField` (removed with its metrics). A recessed 28 pt
  pill across the list's width, the magnifier on the circles' line, the text on the titles' line,
  a quiet "Esc" at the end. Programmatic focus puts the insertion point after the text.
- **Find highlight** (`AtticColorTokens.findHighlight`, `AtticText.highlights`,
  `AtticTaskRowModel.titleMatch`): a search match in a title sits on a soft yellow (Light 48 %,
  Dark 30 %; Increase Contrast 70 % / 42 %), its letters in the primary ink.

### Phase 1 round 9: motion (owner items 24–26, 2026-09-28)

- **Springy presets** (`AtticMotionPreset`): `bounce` is now per preset (was 0 everywhere).
  Things that appear land with a bounce: `popover` 0.3 (0.26 s, rise 6, was 0.12 s and 4),
  `toast` and `settle` 0.25 (`settle` gains a 6 pt rise for rows added or removed), `expand` and
  `doneSlide` 0.2, `failReturn` 0.15. Pages stay firm: `slide` 0.15, `.snappy`'s bounce (about
  2 pt on a 360 pt page), 0.32 s; `pageSwitch` (a crossfade) and `hover` never bounce. Durations
  are at most 0.35 s. Reduce Motion fallbacks are unchanged.
- **Pages settle on the slide's duration, critically damped.** The Tasks pager steps its own
  spring (`TasksPagerSpring`: 2π / `slide.duration`, no bounce, starting at the fingers' speed and
  capped so it never passes the page). SwiftUI animations of a page's offset moved what SwiftUI
  draws but not the lists' AppKit scroll views, so the pager does not use them for travel.
- **`AtticMotionPreset.exit(reduceMotion:)`**: leaving is a short fade-out with no bounce (the
  Done search's field lets the keyboard go at once).
- **`transition(reduceMotion:edge:)`** takes `.leading` and `.trailing` too (a sideways move of
  twice the rise): the Done search comes in from the magnifier's end as the tabs leave.
- **Settings › General › Animations** (`AtticAnimationLevel`: Full, Reduced): the design
  context's `reduceMotion` is on for Reduced as for macOS Reduce Motion
  (`atticDesignFromSystem(animations:)`), so every component and page following
  `design.reduceMotion` (the Notes branch too) needs nothing more. Code outside a view reads
  `AtticMotionPreference.reducesMotion` (the choice or the Mac's setting).

### Phase 1 round 10: full control (the capability audit, owner-approved, 2026-09-28)

The owner's principle: a calm look, never a cut capability. Every change is
additive; no token, colour, radius or type style changed.

- **`AtticMenuCommand` gains submenus, states, details and headings**
  (`children`, `state`, `detail`, `isHeader`, `.submenu`, `.header`), and
  finds the command for a key (`command(for:in:)`, `command(key:…)`). One
  list now draws a SwiftUI menu (`AtticMenuItems`: sections, headings, ticks,
  dashes, badges, submenus) and an `NSMenu` (**new `AtticNativeMenu`**) that a
  key or a button opens under an anchor (**new `AtticMenuAnchor`**). Why: one
  command definition drives the right-click menu, the actions button, ⇧⌘I, the
  keys and VoiceOver.
- **New `AtticMenuButton`**: a small button that opens a native menu from its
  own action. The selection bar's State and Priority use it (the SwiftUI
  `Menu` with a click-through label never took the click under XCUITest).
- **`AtticSelectionBar`**: an action may open a pop-over picker (Date, and the
  full tag picker with search and creation) instead of a menu; its menus are
  read when they open; VoiceOver reads a summary of what the selection shares
  or not. Same look.
- **New `AtticTaskShortcut`**: every task command's key in one place (⌘C,
  ⌘D and ⇧⌘I added; checked against the spec's key map). `AtticTaskKeys`
  answers ⌘C, ⌘D and ⇧⌘I, and only when the task offers the command.
- **`AtticTaskActions`** gains Move Up/Down, Add Subtask, Copy, Duplicate,
  Change Priority and Show Actions, each a VoiceOver action when offered.
- **`AtticTaskRow`** gains `onActions`: **new `AtticRowActionsButton`** ("…",
  the icon ink, the date's hover pill, 22 × 18, `AtticRowActionsMetrics`) on
  the title line only while the pointer or the keyboard is on the row; the
  date steps aside for it. Nothing shows at rest.
- **`AtticSubtaskRow` / `AtticQuickLook`**: a subtask may take `commands`
  (a keyboard stop with the commands' keys, its right-click menu and its
  VoiceOver actions, one list) and be renamed in place (`renaming`). The
  checkbox and the line look the same; a keyboard-driven focus ring shows.
- **New `AtticShortcutRecorderRow`** (Settings): the title, a raised key cap
  with the combination (Type a Shortcut while recording), and Reset; the
  refusal's reason in the warning ink under it.
- **`AtticTabsSearchField`** gives the keyboard to its own AppKit field from a
  probe beside it (**new `AtticFieldClaimProbe`**) the moment it is in the
  window: the ⌘F-after-Esc flake gave it to the field still fading out.

### Phase 1 round 11: performance and feel (owner: "everything feels laggy", 2026-09-28)

- **Motion presets back to the spec's timings** (§ Motion: under about 300 ms,
  no bounce on everyday actions), keeping round 9's life where it belongs:
  `slide` 0.25 s, bounce 0 (was 0.32, 0.15); `expand` 0.22, 0 (0.30, 0.2);
  `doneSlide` 0.25, 0 (0.34, 0.2); `popover` 0.22, 0.15 (0.26, 0.3); `toast`
  0.24, 0.12 (0.32, 0.25); `settle` 0.24, 0.08 (0.30, 0.25); `complete` 0.22,
  0.15 (0.26, 0.3); `failReturn` 0.28, 0.1 (0.34, 0.15). Navigation never
  bounces; only small things that appear land with a light bounce.
- **`AtticPageTabs` changes its selection plainly**: the page that shows the
  selection moves itself. Wrapping it in the slide's animation animated a tab
  click twice (the Tasks pager's own spring as well) and faded the page in.
- **`AtticMenuItems(building:)`**: commands built only when the menu is built.
  A row's `.contextMenu` otherwise worked out every command of every row, a
  fetch of every tag included, each time the list redrew (1.4–3.7 s for a tab
  click's first frame with the spec's 500 open and 5,000 done tasks).
- **`AtticTaskRowModel` is `Equatable`** (the subtask counts compared by hand),
  so a list can skip redrawing a row whose model did not change.
- No token, colour, radius or type style changed.

### Motion Lab: feels (owner, 2026-09-30: "I much more prefer the bounciness, even if it's slight")

- **`AtticMotionTuning`** holds every motion value: the navigation springs
  (`slide`, also the Tasks pager's settle; `expand`; `doneSlide`), the springs
  of things that appear (`popover`, `toast`, `complete`, `settle`,
  `failReturn`), the appear scale, the leave tuck (response, scale) and two
  styles, Appear and Leave (`AtticMotionStyle`: spring or fade). Every preset
  reads `AtticMotionTuning.current`; `pageSwitch` (a crossfade) and `hover`
  are the same in every feel. The design context carries the tuning
  (`motion`), so a change redraws everything at once.
- **`AtticMotionFeel`**, three feels as data: **Calm** is round 11 exactly,
  with its fades; **Lively** (the default): navigation 0.30 s / 0.12 (expand
  0.26), things that appear 0.26–0.28 s / 0.22 (settle 0.27 / 0.16) from 0.92
  of their size, leaving in a 0.14 s tuck to 0.96, each spring reaching 95 %
  of its way within a frame of Calm's; **Playful** is round 9's springs,
  popping from 0.88 and tucking to 0.94.
- **Presets**: `animation(reduceMotion:showing:)`, `leaveAnimation`, and
  `hiddenScale` (for things shown in place: the strip, the send button); the
  spring leave style also drives `exit`. `transition(reduceMotion:edge:anchor:)`
  adds, in the spring styles, a scale from the anchor (the edge a thing comes
  from, or an explicit one) weighted per preset (`scaleWeight`: all of it for
  pop-overs and the toast, 0.5 for the quick look, 0.4 for rows, none for
  pages, which hold AppKit scroll views a SwiftUI scale does not carry). A nil
  edge is a scale and fade with no rise.
- **Reduce Motion and Settings › Animations › Reduced ignore the feel**: the
  fallbacks use Calm's timings, and nothing scales.
- **`TasksPagerSpring`** takes the feel's bounce: a settle may pass its page by
  at most a fiftieth of a page (the damping and a flick's speed are capped),
  never toward a second page; Calm stays critically damped.
- **`atticPopover`**: an experimental spring-in from the arrow for native
  pop-overs (`AtticPopoverPop`, a Core Animation transform on the pop-over
  window's frame view), off in every feel; the lab has a switch for it.
- **New `AtticSegmentedRow`** (Settings): a label and the system segmented
  control, for the lab's feel.
- **`AtticMotionLab`**: the Settings › General › Motion Lab group shows only
  in `com.taha.Attic.preview.*` builds (or another non-release identity with
  `--attic-motion-lab`), never under `com.taha.Attic`; outside it no stored
  feel is read.
- No token, colour, radius or type style changed.
