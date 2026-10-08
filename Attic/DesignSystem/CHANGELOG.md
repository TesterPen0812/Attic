# Design system change log

The design system was frozen when the owner signed off the Phase 0 gallery.
Every later change is recorded here: what changed, why, and who asked.

## Phase 2

### Notes v2, round 2: tables (owner, 2026-10-08, sheet 3 as drafted)
- **`AtticNoteTableMetrics`**: cell padding 6 × 4 around the body's 14 / 21
  lines (a one-line row is 29), columns 56–168 by content, a 0.5 pt grid
  (1 pt under Increase Contrast) in a 10 pt card, a 16 pt fade at a cut
  edge, a 3 pt indicator 2.5 under a wide table, the active cell's 1.5 pt
  ring (radius 3), the 18 × 5 column grip, the 5 × 14 row grip 12 left of
  the column, 14 pt "+" chips; every grip and chip keeps a 28 pt target.
- **Colour tokens** (`AtticColorTokens`): `tableGrid` (the text's ink at
  13 % Light, 18 % Dark, 30 % with Increase Contrast), `tableHeaderFill`
  (3.5 % Light), `tableActiveRing` (a neutral 42 % ink, as the draft draws
  it, not the accent), `tableSelectionFill` (= `tagFillSelected`),
  `tableIndicator`, `tableGripFill`, `tableGripDot`, `tableAddFill`.
- **Components**: `AtticNoteTableGripView`, `AtticNoteTableAddChipView`
  and `AtticNoteTableIndicatorView` (AppKit, drawn from the tokens), and
  `AtticTableToolGlyph` (Aa's row in a table: add or delete a row or
  column, the draft's glyphs).
- **Aa's row** (owner pick Q6): Table takes Quote's cell; Quote joins the
  style list after Mono. In a table the row shows Table ⌄, the four tools
  and ✕ in the same capsule.

### Notes v2, round 1: chrome B and text direction 5 (owner, 2026-10-08)
- **Chrome B** (Notes and Tasks): `AtticControlSize.headerControl` 36 → 32
  (radius 13.5 by the 42 % rule) and `AtticStyle.chromeMinimumInset`
  24 → 16. Following them: the pin, the page button (24 pt chips,
  `AtticPageButtonMetrics.segment`), All notes, Aa, New note, the status
  pill (`AtticNoteMetrics.pillHeight`), the header title, Aa's format row
  (24 pt cells, `AtticNoteFormatMetrics.rowCellHeight`) and the add bar
  (`addBarHeight`, its send button 24). Aa sits 6 from New note
  (`formatButtonGap`). Chips and cells under 28 pt keep a 28 pt target
  (`AtticControlSize.hitOutset`).
- **The content line stays at 28** (`AtticLayout.contentFromChrome`, 12
  inside the chrome's line): the note's column, the Tasks circles and tabs;
  the add bar's plus stays on the circles' centre line
  (`AtticAddBarMetrics.leadingPadding` 8).
- **The status pill never outgrows the bottom row**
  (`AtticNoteMetrics.pillMaxWidth(panelWidth:chromeInset:showsFormat:)`),
  and the panel's root always takes its window's size from its origin
  (`PanelRootLayout`): the corner buttons can no longer be pushed off
  both edges.
- **Note text** (`AtticNoteType`, text direction 5): SF Pro throughout the
  note (`noteTitle` / `noteBody` are no longer Rounded), one near-black ink;
  Title 22 bold / 27, Title style 18 / 24, Heading 16.5 / 22, Subheading
  15 / 21 (weight 650), Body 14 / 21, Quote 15 / 22, Mono 12 / 18; gaps 3,
  12 after the title, 16 / 14 / 12 above headings and 2 / 1 / 1 below; lists
  22 in with a 5 pt dot; the quote's 3 pt bar, text 14 in; the Mono block's
  radius 10, 12 pt above and below and 9.5 at the sides (the draft's 14 wrapped
  the owner's 33-character citation line; 33 SF Mono characters at 12 pt are
  244.8 pt, and 10 pt sides leave 244). Copy is a 20 pt `doc.on.doc` chip,
  opaque in the block's fill, 3 pt into its top-right corner, shown on hover,
  with the caret in the block, or for VoiceOver. All notes' rows: `noteRowTitle` (13
  medium) and `noteRowMeta` (11.5), SF Pro.

### A32: Aa's neighbours pass under the row's edges; the close no longer waits (2026-10-08)
- **`atticControlReveal` / `AtticRevealedControlShape`**: a raised control
  can draw only part of itself. A glass container ignores a clip set on its
  members, so All notes and New note were drawn sliding out over the
  panel's margin and then vanished at once. Their glass shape now narrows to
  the part still inside the slot, so each passes under the row's edge.
- Closing: the glass starts back after 0.4 of a leave (was 0.8, which held
  a wide, empty glass for several frames in Calm). New note rides back in
  with the glass's trailing edge on the same spring, keeping the 8 pt gap;
  All notes and the status return on their own clocks as before.

### Aa neighbours slide into their sides (owner refinement, 2026-10-08)
- All notes' stack travels left and New note travels right as Aa expands,
  on the same selected app spring. Their glass and glyphs clip at the row
  edges, instead of fading in place or disappearing immediately.
- Closing brings them back from those sides. Returning travel stops at
  each resting slot, keeping the gap beside Aa clear. Reduced motion
  still swaps at once; Aa's paired-edge spring and timings are unchanged.

### Aa opens as one shape (owner refinement, 2026-10-08)
- Both glass edges start together on the selected `expand` spring. Removed
  the trailing-edge leave delay and the dependent controls delay, so Aa no
  longer stretches left and then right. Other app motion tokens are unchanged.
- New note retires immediately to clear its adjacent slot; All notes keeps
  its existing short fade. Closing, reduced motion and reversal cancellation
  retain their existing behavior.

### A29 round 4: content dissolves into the panel's edges; Aa answers at once (2026-10-06)
- **`atticScrollUnderFade(plainText:topEdge:bottomEdge:)`**: content eases
  from `edgeFloor` (0.10) at the panel's top and bottom edges to full at the
  middle of the header's controls and of the bottom row
  (`PanelPageLayout.scrollEdgeFadeTop/Bottom`); still none behind glass.
- **`AtticFormatRowGrowth.leading/trailing`**: the glass's two edges travel
  on their own clocks (both together still available).

### A29 round 3: no fade behind glass; the format row on the app's springs (2026-10-06)
Owner decisions of 2026-10-06 ~09:50. No colour, size or glass changed.
- **`AtticScrollUnderFade` / `atticScrollUnderFade(plainText:)`**: content
  runs under glass controls at full strength. Only a line of plain text over
  the content (Tasks' Now · Later · Done line, All notes' label line) keeps a
  short fade: `behindText` 0.10 across the text's own height, back to full
  within `textRamp` 6 pt either side. Removed: the A15 profile (`edgeOpacity`,
  `overTopControls`, `overBottomControls`, `controlsEdge`, the eased rise).
  The Notes editor (glass only) has no fade.
- **`NoteFormatMotion.Plan`**: the format row's motion takes `expand` (the
  glass), `popover` (the controls; the neighbours' return) and the feel's
  leave (the neighbours going, the controls going) from the chosen feel, with
  delays as shares of those springs.

### A29 the format row grows out of Aa (redesign/p2-format-motion-2, 2026-10-06)
Owner pick p2-37 draft 1 ("Aa grows into the bar"). No token, colour,
radius or size changed.
- **`AtticFormatRowSurface.growth`** (`AtticFormatRowGrowth`, animatable):
  the row's one glass spans from a button's frame to the whole row as it
  grows; the controls are the glass's content (clipped to it, at their
  resting places), and the button's glyph rides on it for the first third.
  Nil or fully grown, it draws exactly as before.
- **`AtticFormatRowSurface.contentOpacity`**: the controls' own fade.
- **`atticControlAway` / `atticControlGone`** (environment, round 2): a
  raised control fades out of a glass group (the identity glass, its content
  faded inside the glass), then drops its glass altogether. A glass container
  ignores a plain `.opacity` on its members. Unset, nothing changes.

### A25 Notes format row replaces Aa's pop-over (redesign/p2-integration, 2026-10-06)
Owner decision OD-14 (`mockups/p2-36-format-no-panel-drafts.png`, draft 1
plus draft 7's hint). No colour, radius or size token changed.
- **New `AtticFormatRowSurface`**: the bottom row's own raised material
  (Liquid Glass, the drawn recipe under Reduce Transparency) as wide as the
  row and 36 tall, controls 4 pt in; probed at radius 15.
- **New `AtticFormatSeparator`**: a 1 × 16 upright line in the `divider`
  token, 4 pt from each group (the draft's group lines).
- **New `AtticFormatStyleKind`**: each style's name in a hint of its own
  style (Title 15 bold … Mono 12 monospaced) for the style list.
- **`AtticDropdownRow.titleFont`**: an optional font for the name (the style
  list); every other row is unchanged.
- **`AtticFormatToggle.announcesState`**: actions in a row of toggles
  (outdent, indent, close) say no on/off value.
- **Removed** `AtticFormatStyleChip` and Aa's pop-over metrics
  (`popoverToggleWidth`, `popoverWidth`, `popoverRowGap`, `popoverGroupGap`,
  `styleChipPadding`); **added** `rowToggleWidth` 28, `rowCompactToggleWidth`
  24, `rowSeparatorHeight` 16, `rowSeparatorPadding` 4.

### A21 header title makes room for the page switcher (redesign/p2-integration, 2026-10-05)
Owner decision B (Canvas, 2026-10-03), applied to Notes now and shared with
Canvas later (OD-11). No token, colour, radius or size changed.
- **New `AtticHeaderTitleRoom` / `AtticHeaderTitleLayout` / `AtticHeaderTitleSlot`
  (`AtticControls.swift`)**: a header title is centred between the pin and
  the page button; while the page switcher is open it left-aligns beside the
  pin and truncates in the space the switcher leaves (8 pt clear), then
  returns to the centre when it closes. It moves with the `expand` preset;
  Reduce Motion and Animations: Reduced give the new width at once.
- **`AtticPageSwitcherPresence`** (environment, owned by the shell): the page
  button reports whether it is open; only the title wrapper observes it, so
  the header's own body never re-evaluates (`CornerGlassTests` still holds).
- The Notes header title uses it; the page switcher itself is unchanged.
- **Uneven glass buttons fixed** (owner, `p2-33`): `AtticControlGroup`'s
  `GlassEffectContainer(spacing:)` was 12 pt, wider than the 8 pt between
  Notes' Aa and New note, so the system blended their facing edges and each
  button's two sides had different curvature. The merge distance is now 0
  (`AtticControlShape.mergeDistance`) and every control draws one explicit
  symmetric continuous rounded rectangle (`AtticControlShape.shape`).

### A15 scroll-under fade (redesign/p2-integration, 2026-10-04)
Owner decision (2026-10-04, option A of the p2-27 draft; it replaces D1's
"rows fade out before the controls"). No token, colour, radius or size
changed; how scrolling content meets the fixed controls changed.
- **`AtticControlsFade` / `atticControlsFade(restTop:bottomControls:)` are
  replaced by `AtticScrollUnderFade` / `atticScrollUnderFade(topBand:
  restTop:bottomBand:restBottom:)`**: an opacity mask, static geometry, no
  blur and no native soft edge. Content runs under the top and bottom
  controls, faintly visible so the Liquid Glass picks it up: 6 % at the
  panel's edges, 10 % over the controls' middle, 22 % at their inner edge,
  then an eased (smoothstep) rise to full at the first and last resting
  places, which are unchanged and fully opaque.
- Tasks' lists (Now, Later, Done, Find results) use it through
  `TasksViewport.maskStops`; the Notes editor and All notes use it directly.
  All notes now runs its list under the label line (the line floats over it,
  with a click band as Tasks' tabs band; VoiceOver still reads the line
  first).

### Overnight A1 overlay construction review (2026-10-04)
- Overlay hierarchy deferral also covers initial title accessories, slash
  hint and object-control attachment during panel layout. Initial joins
  preserve geometry calculated while waiting; a flush reached through a
  nested run loop waits until the outer layout pass ends. The freeze cause
  remains a hypothesis for the separate on-screen check.


### Combined app fix round 2 (redesign/p2-fix2)

Requested by GPT-6.1's review of the combined fix round (2026-10-03). No
E1 value, token, colour, radius or size changed; nothing looks different.

- **`AtticTagPickerCard`'s highlight is the row's identity**
  (`AtticTagPickerHighlight`: a tag's name, or the "New tag" row), not its
  number: a toggle that reorders the rows (Notes lists the note's own tags
  first) no longer moves Return or Space onto another tag. One typing rule
  for Tasks and Notes: typing lights the tag with exactly the typed name,
  else "New tag" for it, never another tag. A prefix's Return adds what was
  typed (Notes' rule before; in Tasks it used to toggle the first match).
- **New `AtticOverlayHierarchy`** (P1-01 experiment): every overlay host's
  attach, detach and reparent (dropdown cards through
  `AtticDropdownSpace.show` and `AtticDropdownPresenter`, Notes' overlays)
  waits for the next run-loop turn when it is asked for inside a layout
  pass, coalesced per view; a host already in its parent moves at once.
  `AtticOverlayHostingView` marks its own layout pass.

### Combined app fix round (redesign/p2-integration)

Requested by the combined Tasks + Notes CU reviews of 2026-10-03. No E1
value, token, colour, radius or size changed.

- **A measured dropdown card grows for a wider row** (CU P3-03: the tag
  picker's "New tag “#cu2”" was cut to "New tag “#c…" in a half-empty
  card). Content reports its widest row with `atticDropdownIdealWidth(_:)`;
  `AtticDropdownCard` passes it on (`atticDropdownContentWidthChanged`) and
  `AtticDropdownPresenter.grow(toWidth:)` widens the open card within the
  width rule, keeping its side. It never narrows while open, so filtering
  never makes it jump in. `AtticTagPicker` reports its rows' width
  (`rowsWidth(tags:create:)`, measured from the names without a layout pass).
- **New `AtticTagPickerCard`**: the tag picker with its state and keys (the
  query, the one highlight, ↑ ↓, Return, Space on the rows under Full
  Keyboard Access, Tab between field and rows), moved out of Tasks'
  `TaskTagPickerView` so Notes' ⋯ → Tags… uses the same card (CU P2-03: it
  was a translucent arrow popover with dark-on-dark text in Dark and no
  keyboard highlight). The caller supplies the rows for a query. Typing now
  lights the tag with exactly the typed name when there is one, else the
  first match (Notes lists the note's own tags first). `AtticTagPicker.Tag`
  gains an optional `detail` (Notes' per-tag count, in the row's detail
  column).
- **New `AtticControlsFade` / `atticControlsFade(restTop:bottomControls:)`**
  (D1 for any page that scrolls between fixed controls; CU P2-02): the
  opacity mask Tasks' lists use (`TasksViewport.maskStops`: nothing over
  the top controls, the edge veil's eased ramp over the last 6 pt before
  the first line's resting place, the same ramp in the 6 pt before the
  bottom controls, nothing under them). Notes' editor and All notes use it
  with Clean cut (owner, 2026-10-03: no native soft edge on Notes). The
  editor's two `AtticEdgeVeil` overlays and the library rows' per-row
  `AtticScrollEdgeFade` (a blur and fade per row, by position) are gone;
  `AtticNoteMetrics.listTopFade` is removed. Tasks is unchanged.
- **Removed `AtticNoteTagList`** and its `AtticNoteMetrics.tagEditorWidth` /
  `tagEditorMaxListHeight`: replaced by the shared card above.

### Notes audit fix B2 (redesign/p2-audit-fix)

Requested by the Phase 2 audit (finding B2: the delete toast could take
⌘Z away from the text). No token, colour, radius or size changed.

- **`AtticUndoToast` gains `answersUndoKey`** (default true, so Tasks is
  unchanged) and **`PanelToastCenter.show` gains the same parameter**. With
  false the toast's button no longer carries the ⌘Z shortcut: it answers the
  pointer and VoiceOver only, and the VoiceOver announcement no longer says
  "with Command-Z". Notes' "Note deleted" toast passes false: ⌘Z there follows
  the text under the caret, then the library's history.

### Notes rebuild, slice 2 (redesign/phase-2)

Requested by the slice 2 brief (the writing view, the bottom row and slot,
All notes). Every addition reuses existing tokens: no colour, radius or
type size changed, except the one type change below, which is the owner's
decision.

- **`noteTitle` and `noteBody` are SF Pro Rounded** (`AtticTextStyle.isNoteText`):
  owner decision 4 (2026-09-27), the Tasks list's voice for the page of text.
  Sizes and weights unchanged (17 bold, 14 regular).
- **`AtticMenuCommand` gains `submenu`, `isChecked` and `identifier`**, and
  `AtticMenuItems` draws submenus and checkmarks (the note menu's Insert ▸ and
  Format ▸). **New `AtticNativeMenu`**: the same commands as an `NSMenu` popped
  up from an AppKit view (the ⋯ lives inside the note's text view, and ⇧⌘I
  opens the menu from the keyboard). Menus stay native.
- **New `AtticNoteMenuButton`** (the ⋯, a 28 pt target, icon ink, hover and
  pressed fills from `chipHover`/`chipSelected`), **`AtticNoteTagLine`**
  (tags under a title: the `tag` style in the secondary ink, 12 apart,
  wrapping) with **`AtticWrapLayout`** (items and lines with their own gaps),
  and **`AtticHeaderTitle`** (a scrolled-away title in the header: a raised
  control 36 tall with the `panelHeading` title and the title menu's chevron).
- **New `AtticNoteRow`, `AtticNoteRowModel` and `AtticNoteGroupHeading`**: All
  notes' 48 pt rows (the task row's metrics: title line, details line,
  highlight inset) with the time, a warning glyph beside it, a preview and
  counts; group headings like the Done log's days.
- **New `AtticNoteTagList`**: the note's tag editor ("Find or add a tag",
  ticked rows with counts, "New tag"). It follows Phase 1's tag list and should
  be unified with `AtticTagPicker` when Phase 1's final rounds are merged into
  this branch.
- **New `AtticTagSuggestion` and `AtticTagSuggestionList`**: the suggestions
  under a hashtag typed in a note's title (p2-01 #3), on the pop-over surface
  with `AtticPopoverRow`s; the keyboard's row uses the rows' highlight.
- **New `AtticStatusItem`, `AtticStatusPill` and `AtticStatusDetails`**: the
  Notes status slot (a raised capsule 36 tall, at most 176 wide, with the
  warning ink for problems, an inline action chip, "+N" or ✕) and its details.
  The toast's inner button gains `answersUndoKey` so the pill's Retry never
  takes ⌘Z.
- **`AtticListSearchField` gains `iconX`/`textX`, `onKeyPress` and
  `onEscapeWhenEmpty`** (defaults keep the Tasks Done search exactly as it
  was): All notes puts the search on the note column, ↑ ↓ and Return reach the
  list, and Esc in the empty field goes back.
- **New `AtticNoteMetrics`** (column, ⋯, tag line, header title, slot and
  All notes geometry).

### Notes, the owner's first feedback on slice 2

- **New `AtticMotionPreset.springy(reduceMotion:)`** (and `springyBounce`,
  0.24): a preset's motion 1.5 × as long with a soft overshoot, for Notes'
  slides, the search take-over, the status slot, the tag line and list
  changes (owner: "springy, alive"). Reduce Motion (and the Phase 1
  Animations setting, when merged) gives the preset's own fade or instant
  change. The existing presets are unchanged.
- **New `AtticNoteLibraryLine`**: All notes' label line with a quiet
  magnifier at its end; searching turns the line into a recessed field with
  an "Esc" hint (the Tasks Done search's pattern; to be unified with Phase 1's
  `AtticTabsSearchField` at the merge). Replaces All notes' search row.
- **`AtticNoteTagLine`** springs new tags in and fades removed ones.
- **`NoteObjectRenderer`** redraws only when the colour key changes (a
  control-material or Reduce Motion change redraws nothing).

### Notes rebuild, slice 1 (redesign/phase-2)

- **New `AtticDateChip`** (and `AtticDateChipMetrics`: a 10 pt calendar glyph,
  4 pt gap): a date inside note text. It reuses the tag chip's pill (18 tall,
  radius 7.5, `tagFill`, `AtticTagMetrics.horizontalPadding`) and the
  `chipLabel` style in body ink; no new colour, radius or type style. The note
  editor renders it (and `AtticSubtaskCheckbox`, for checklist lines) into
  images for its text attachments, so notes draw only design-system parts.
  Requested by the Phase 2 slice 1 brief (one inline date object).

## Phase 1

Phase 1 (Shell, Tasks and Settings) was built in three streams and integrated
on `redesign/phase-1`. Every change below is additive: no token, colour, radius
or type style changed.

### Native soft edge disabled everywhere (owner, overnight A1, 2026-10-04)

- `AtticScrollEdgeLab` ignores former preview defaults and environment
  overrides and offers no A/B switch. Stored preferences are left intact.
  Tasks, Done, the Notes editor and All notes use Clean cut with the D1
  control fade. A7 also disables the native edge in every E1 dropdown list
  and rejects former soft choices injected in code. A source guard rejects
  any surface or card enabling native scroll edges; hosted list and card
  tests assert no native pockets.
  This supersedes the preview exception in the earlier entry below.

### Clean cut by default (owner, 2026-10-03)

- **`AtticScrollEdgeLab` resolves to `.cleanCut`** for every identity, and
  a strict preview starts on it too; the system soft edge stays a
  preview-only A/B choice (Settings › General › Motion Lab, or
  `ATTIC_UI_TEST_SCROLL_EDGES=soft` in a preview). This reverses D4b. On
  Attic Glass at `dab5d2f` (gate g10) the soft edge cost about 9.5 GPU
  points mean, 17 peak and 5 WindowServer CPU while scrolling, and
  GPT-6.1's still captures with it on and off were pixel-identical: D1
  already fades the rows out before the fixed controls. D1's fade (the
  list's mask) is unchanged. `TasksDonePage.edges` defaults to it as well.

### Done's first results (Opus, 2026-10-03)

- **`AtticTextInput.passingToSelection(_:)`**: runs a key's command that a
  typing field passed on to the selection (⇧⌘I, or ⌘Return with no draft,
  from the composer or Find), so the key is not the field's while it runs.

### PR prep (Opus, 2026-10-03)

- **A menu's choice is not a typing field's key.** `AtticMenuItems` and
  `AtticNativeMenu` run a chosen item's command through
  `AtticTextInput.choosing(_:_:)`. While it runs, `ownsCurrentKey` gives a
  typing field only the item's own key equivalent; the Return or click
  that chose the item is the menu's. On macOS 27 a context menu carries
  its own text field (Ask Siri), so every menu command guarded by
  `ownsCurrentKey` could be refused (CU recheck 3: More › Open Files… did
  nothing while ⌘Return worked).
- **`AtticNativeMenu.popUpContextMenu(_:in:at:)`**: a row's actions menu
  (⇧⌘I, the row's ⋯, a subtask line's actions) opens as the system opens a
  right-click menu, so its submenus keep their titles whole. The pop-up
  style squeezed More's titles to "…" or single letters short of room.
  Button menus (View Options, the selection bar) keep the pop-up style.
- **`AtticTabsSearchField`, native input:** the field counts as focused
  when it takes the keyboard, not at its first edit, and a click on the
  magnifier or the padding gives it the keyboard.

### D1 edge fade (Sol, 2026-10-03)

- Owner decisions D1 and D4b replace scrolling beneath control labels.
  Each Tasks list's native soft viewport now ends below the tallest
  tabs/Find control and above the entire measured bottom control stack.
  Native pockets are clipped inside that viewport; the former control-size
  marker bands are gone. Tiny drawing markers remain in the empty resting
  gaps because `.soft` alone produces no pocket on the installed runtime.
- Resting row clearance, the independent control layer, and the preview-only
  Clean cut baseline are retained. No custom blur or scroll-driven SwiftUI
  state was added. The add bar renders an owner-provided text snapshot;
  its edit binding is captured for the field, avoiding false whole-bar
  invalidation on scroll layout passes. Real edits still update the owner.

### Deep review fixes (Opus, 2026-10-02)

- **`AtticRowFocus(binding:id:isFocused:isActive:)`**: a list that keeps
  its own record of which row has the keyboard says so. The Tasks page's
  lazy cells read the focus state as it was when the list was built (nil),
  so the keyboard's row never drew its ring (deep review P2-04). The ring
  itself is unchanged: the focus-ring token's 1 pt line on the highlight's
  edge.
- **The composer strip closes up before it cuts a value short** (P3-01:
  "Tomorr…", "#q…"): when the three set buttons would not fit at their
  usual padding, each closes its inner gaps (new tokens
  `stripCompactIconGap` 3, `stripCompactClearGap` 3,
  `stripCompactValueTrailing` 4, 9 pt a button); the 9 pt before the icon
  stay, so the first icon keeps the circles' line. With room, nothing
  changes. **`AtticStripValue.full`**: the tooltip's whole value (every
  tag).
- **The lists' bottom bar under the system soft edge covers the whole
  bottom stack** (P2-02): the strip, a selection bar or a paste offer while
  they show (`TasksBottomEdgeBar`, in Tasks). The same system pocket,
  taller; no blur of Attic's own.
- No token, colour, radius or type style changed.

### The corner buttons become Liquid Glass (Opus, 2026-10-02)

- **L3 → Liquid Glass.** Owner: "I want liquid glass, make it happen without
  losing any performance." This replaces L3 = A (the flat corner buttons).
  The header's pin and page button are the system's interactive Liquid Glass
  again (`atticRaisedMaterial`, `.regular.interactive()`, in the control's
  42 % continuous shape), both in the header's one `GlassEffectContainer`
  (`AtticControlGroup`). Their looks are Phase 0's: hover and press as fills
  inside the glass, the pinned pin and the page button's current page on the
  selected inner chip, the keyboard ring, and Increase Contrast's stronger
  edge.
- **`AtticPageButton`'s glass is now interactive** (it was not, as Phase 0's
  page switch): a click on any page gets the system's press response, as the
  pin's does. The pages' own buttons still take the click.
- **New `AtticCornerButtonStyle`** (`liquidGlass`, `flat`) with
  `drawsFlat(in:)`: the corner buttons keep L3's `AtticFlatSurface` wherever
  the controls are not live glass (Reduce Transparency, the Craft style, a
  Solid panel that is not key), and for the Flat choice. `AtticFlatSurface`
  stays for exactly those cases.
- **New `AtticCornerButtonsLab`** (preview identities only, like the scroll
  edge lab): Settings › General › Motion Lab › Corner buttons, "Liquid Glass /
  Flat", kept in the preview's defaults; the on-screen gate forces one with
  `ATTIC_UI_TEST_CORNER_BUTTONS=glass|flat` (`AtticPreviewOverrides.cornerButtons`).
  The official identity is always Liquid Glass.
- Settings' panel miniature draws the corner buttons the same way.
- Unchanged: the Find and View Options glyphs on the tabs line stay quiet,
  unbacked icons (D4 = A, and the floating controls' B: no backings).
- Cost (measured headless, `CornerGlassTests`): the shared container gives one
  backdrop for both buttons (it spans the header's width, at half
  resolution); interactive and non-interactive glass build the same layers at
  rest, with no animation running; scrolling and swiping never re-evaluate the
  header. The on-screen gate is the judge.

### Follow-up part 2: owner decisions (Opus, 2026-09-30)

- **Low priority returns** (option A, `mockups/p1f-06-low-priority.png`):
  `AtticPriorityMark` draws Low as a grey `↓` in the `priorityMark` style and
  the helper ink, where `!` and `!!` sit. `TaskPriority.choices` replaces
  `choices(keeping:)` and offers all four everywhere (round 7's R6 rule is
  lifted). The strip shows `↓` for Low. `AtticTaskShortcut.priorityNone…High`
  are ⌥⌘0–3; `AtticTaskShortcut.matches` also reads the number row's key
  codes, so a layout whose ⌥ changes a digit still matches. Why: the owner
  could not tell Low from none.
- **Find and View Options** (item 6, option A): **new `AtticViewLine`** (the
  quiet "Due or overdue · by due date · Show All" line an active filter
  shows); `AtticMenuButton` gains an optional anchor `holder` (⌥⌘V opens
  the same menu under the button), a 5 pt accent dot (`showsDot`,
  **new `AtticMenuButtonMetrics`**) and a VoiceOver `value`. Find reuses
  `AtticTabsSearchField` on every page.
- **L1, the active tab** (option B): `AtticPageTabs` draws a 2 pt line in the
  heading ink under the active label (`AtticPageTabsMetrics.underlineHeight`,
  `underlineGap`), moving with the slide preset, at once under Reduced
  animations. The inactive labels' colour is unchanged.
- **L2, the keyboard's row** (option A): a task row the keyboard is on draws
  one 1 pt line on its highlight's own edge (`AtticFocusRing` with gap 0,
  `AtticRingMetrics.rowLineWidth`) over the lighter hover fill, instead of
  the 2 pt ring 2 pt outside. Other controls keep the ring.
- **L3, the corner buttons** (option A): **new `AtticFlatSurface`**
  (`atticFlatSurface`, `AtticFlatSurfaceMetrics.hairline`): the recessed
  fill and one 1 pt hairline in the selected-chip ink, no rim, sheen, shadow
  or glass. `AtticRaisedButton(flat:)` and `AtticPageButton(flat:)` use it
  (shut, the current page's glyph sits on it with no inner chip; a pinned
  pin takes the chip fill whole). The keyboard ring stays.
- **L4, Dark Glass and Frosted +1 step**: `openRing()` at rest 0.36 → 0.46.
  Light, Dark Solid and Increase Contrast are unchanged. The icons and
  chevrons were not changed: the ladder's #8E8E8E is tuned to the 3 : 1
  icon floor before use, and every Dark context already renders #B2B2B2,
  lighter than the approved #A8A8A8 (measured over every palette, surface
  and Tint).
- Requested by the owner (decisions of 2026-09-30, "all recommended" and
  L1–L4).

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

### Phase 2 slice 3a — Notes format controls (2026-09-29)

- **New components** (`AtticNoteFormatComponents.swift`): `AtticFormatToggle` (a flat 28 pt
  toggle whose fill says off, on or mixed; the keyboard ring only for the keyboard; VoiceOver value
  "on/off/mixed"), `AtticFormatValue`, `AtticHighlightGlyph`, `AtticFormatBarSurface` (a capsule on the
  pop-over surface, 36 tall, 4 pt inset, groups 4 apart and never lines), `AtticFormatGroup`,
  `AtticFormatStyleFace` ("Body ⌄"), `AtticFormatStyleChip` (Aa's style chips, each in a hint of its
  own style) and `AtticDateCalendar` (the date card's month).
- **New metrics:** `AtticNoteFormatMetrics` (bar 36 tall with 24 pt toggles so it fits a 320 pt
  panel, 6 from the selection; Aa 300 wide with 32 pt toggles; the `/` list 256 wide; the date card
  236; the link card 272; 12 pt shadow room).
- The `/` list, date card and link card reuse `AtticPopover` and `AtticPopoverRow`; motion is the
  popover preset's springy variant (fade, 4 pt rise, 0.96 grow), a fade under Reduce Motion.

### Phase 1 follow-up: control audit items 5, 10 and 11 (2026-09-29)

- **New `AtticTaskPicker`** (Move to Task…): the tag picker's pattern for
  tasks — "Find a task", then `AtticChoiceRow`s with where each task is
  listed as the detail, one highlight for keys and pointer. Rows are built
  lazily with a known height (`AtticPickerMetrics.taskWidth` 260,
  `taskListMaxHeight` 196), so a long list costs a screenful per keystroke.
- **`AtticSubtaskRow`**: a managed line shows the row's `AtticRowActionsButton`
  while the pointer or the keyboard is on it, answers ⇧⌘I with its commands
  as a native menu (`AtticMenuCommand.performSubtaskKey(showActions:)`), and
  can point a pop-over at itself (`popover`; `AtticQuickLook.popover`). Nothing
  shows at rest.
- **`AtticDeletedItemRow`**: selectable (`isSelected` draws `selected` inset
  4 pt with the control corner rule, `AtticSettingsRowMetrics.selectionInset`;
  VoiceOver hears "selected"), `onSelect` with the modifiers held, a lazily
  built right-click menu that is also its VoiceOver actions, and Select /
  Deselect for VoiceOver.
- **`AtticActionRow.secondary`** (new `AtticRowAction`): a second small raised
  button before the first (Recently Deleted's selection row).
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

### Motion Lab: finish (owner, 2026-10-01: lively by default, reducible by the user)

- **Settings › General › Animations** is now **Lively** (the default),
  **Subtle** or **Reduced** (`AtticAnimationLevel`: `lively`, `subtle`,
  `reduced`). Lively is the Lively feel in every build. Subtle is the
  `AtticMotionFeel.subtle` tuning: Calm's timings (navigation 0.25 s, things
  that appear 0.22-0.24 s) with a small bounce (navigation 0.04, things that
  appear 0.10, settle and fail-return 0.08), springing in from 0.96 and
  tucking to 0.98 in 0.12 s; no plain fades. Reduced is the Reduce Motion
  fallback. macOS Reduce Motion forces Reduced whatever is chosen
  (`design.reduceMotion` is unchanged).
- A stored "full" becomes Lively (and is rewritten as `lively`); a stored
  "reduced" stays Reduced (`AtticAnimationLevel.migrated(from:)`).
- The Motion Lab stays preview-only, and its Feel row gains Subtle. A lab
  choice overrides Animations until Animations is changed, which puts the
  feel back to Lively or Subtle.
- **Edges is removed** (`4fc0f34` reverted): the lists and Notes are back to
  round 13's clean cut at the tabs' band and the bottom stack. A floating
  controls design replaces that behaviour later.

### Floating controls: the system soft scroll edge (owner, 2026-10-01)

- **The per-control softening is removed** (owner, 2026-10-01: "the
  floating icons and controls feel terrible… it is so incredibly laggy").
  `AtticSoftening`, `AtticSofteningLab`, `AtticControlFootprint(s)`,
  `atticControlFootprint`, `atticSoftenedByControls`, `AtticSofteningBand`,
  `AtticSofteningMask`, `AtticLabelHalo`, `AtticSofteningShape` and the
  tokens `softening`, `softeningMaximumDim`, `softeningMaximumBlur`,
  `haloRadius` and `softeningFeather` are gone, with the Motion Lab's
  "Softening behind controls" slider. It re-rendered the content to blur it
  on every frame of a scroll or a swipe, and showed a muddy box by the tabs.
- **New `AtticScrollEdgeStyle`** (`Primitives/AtticScrollEdges.swift`):
  the owner chose macOS 26's own scroll edge effect, soft style. The Tasks
  page's controls' zones (from the panel's top edge to the resting row,
  covering the header's buttons and the tabs; the add bar's zone) are its
  lists' bars (`safeAreaBar` with `AtticScrollEdgeBar`), so each list's
  scroll view gets the system's pockets there: rows are progressively
  blurred and faded toward the edge. The controls themselves still float
  over the lists in the page's own layer (as bar content, XCUITest could
  not hit the add bar's text view, and typing cost more). The window server
  draws the effect; Attic re-renders nothing. `atticScrollEdgeEffect(_:)`
  sets `.soft` (or hides it). Measured in the SDK and in-process: a pocket
  needs a SwiftUI `ScrollView` under a bar that draws something (no pocket
  for a clear bar, `safeAreaInset` or `contentMargins`), so
  `AtticScrollEdgeBar` draws an imperceptible fill; AppKit scroll views
  (the note editor) and SwiftUI's `TextEditor` get none, and AppKit's
  `NSScrollEdgeEffectStyle` exists only for title-bar and split-view
  accessories. Notes keeps round 13's behaviour.
- **`AtticScrollEdgeLab`**: a preview's developer panel (Motion Lab,
  "Scroll edges") switches between **System soft edge** (the default) and
  **Clean cut** (round 13: no bars, the lists' own mask cuts rows at the
  controls' bands), to feel both. Only a preview identity
  (`AtticMotionLab.isAvailable`) can leave the system soft edge: the
  switch, the stored choice and the `ATTIC_UI_TEST_SCROLL_EDGES` override
  are all gated on it, and the official and every other identity always
  resolve to the system soft edge.
- B's edge fade (`AtticEdgeBlur.edgeVisible`) is removed: the system's
  effect fades the edges, and the clean cut is round 13's mask.
- **`AtticReorderLiftModifier`**: the lifted card is opaque, in the panel's
  own colour (`fill(design:)`), no longer the pop-over fill.
- **`AtticTaskRow`**: hover is a tint only; the actions button is the
  keyboard's row's only (`showsActionsButton(forced:keyboardFocused:)`), so
  nothing moves as the pointer passes.
- No token, colour, radius or type style changed.

### Phase 2: the dropdown family, E1 (owner, 2026-10-02: "this works I guess")

- **New `AtticDropdown.swift`**, one component for every Attic pop-over
  list: the `/` list, the date card (Notes and Tasks), the tag picker, the
  priority picker, Aa and the link card. Native menus stay native.
  - `AtticDropdownCard` on `AtticDropdownSurface`: a solid card
    (`popoverFill` #FEFEFE / #363637), one 0.5 pt hairline outside it
    (`popoverOuterRim`, 1 pt and stronger under Increase Contrast) and D's
    shadow (`AtticShadows.dropdown` 16 / 12 and `dropdownContact` 3 / 2, in
    the new `dropdownShadow` and `dropdownContactShadow`); 20 pt corners,
    rows 10 pt in. No blur, so Reduce Transparency changes nothing.
  - `AtticDropdownRow`: 32 pt, touching; check, priority mark, a 14 pt icon
    in an 18 pt slot, the 14 pt name (new `dropdownRow` style), a short
    detail; the pill (new `dropdownHighlight`, #F1F1F1 / #444445) is the
    whole row, concentric with the corner. No hint column. One highlight
    per list, moved by the keyboard and the pointer.
  - `AtticDropdownField`: a row's height and pill on `recessed`; its
    placeholder sets its width.
  - `AtticDropdownLayout`: the width rule (fits its content, never under
    144 pt, never past the panel's 12 pt margin) and where it opens (left
    edge on the caret's column or the strip button; below when there is
    room, else above).
  - `atticDropdown(isPresented:prefer:label:content:)`: the card in the
    panel's overlay layer (`AtticDropdownPresenter`), with the pop-over
    preset's motion (Lively by default, a fade under Reduced). Its own host,
    so opening, filtering and closing never re-render the page behind. Its
    keys are its own while open (`AtticTextInput.isPopoverOpen`); Esc, a
    click outside or the panel letting go closes it and the keyboard goes
    back. VoiceOver hears a menu (`AtticOverlayHostingView.menuLabel`).
- **`AtticOverlayHostingView`** (was Notes' `NoteOverlayHostingView`) is the
  design system's overlay host.
- The Tasks date and tag pickers, the priority picker (⌥⌘0–3 on every row),
  the composer strip and the selection bar's pickers leave the native
  pop-over for the dropdown. `atticPopover` stays for Move to Task… and the
  subtask quick look.
- The month (both date cards): 30 × 28 cells, a 26 pt disc, a 30 pt header
  with a 14 pt semibold title (new `dropdownHeading`).
- Removed: `AtticPickerMetrics.dateWidth`, `tagWidth` and the old month
  values; `AtticNoteFormatMetrics.slashWidth`, `dateCardWidth`,
  `calendarCell`, `popoverPadding`. `tagListMaxHeight` is seven 32 pt rows.
- Preview capture seam `ATTIC_UI_TEST_POPOVER` (`AtticDropdownCaptureSeam`).


### Phase 2: E1 dropdown fix round 2 (2026-10-03)

- Unmodified Esc dismisses only after the active text input has finished its
  marked-text composition. Modified Esc and composition cancellation pass on.
- Cards keep their opening width and report natural content-height changes to
  their presenter. Link validation and calendar month changes update placement,
  hit bounds and the bounded native soft-edge scrolling viewport together.
  Dynamic cards retain their month, editing query and retry state when crossing
  the scrolling threshold, without adding edge space while the card fits.
- Priority picker rows route their displayed ⌥⌘0–3 shortcuts to the pick action
  while the picker is mounted. Menu-item semantics from round 1 are retained.

### Phase 2: E1 dropdown review fixes (Opus, 2026-10-03)

Requested by the Opus review of the dropdown fixes (P2-B1, P3-B2–B4, P3-T1).
Behaviour only: no token, colour, radius, size or motion preset changed.

- **One placement for every card**: `AtticDropdownLayout.place` (anchor,
  bounds, preferred side and the open card's current side → frame, side,
  width and height limit) and `AtticDropdownSpace` (the overlay, the panel
  less its 12 pt margin, and the host's frame). The presenter, the `/` list,
  Notes' date and link cards and the title's tag suggestions all use it. An
  open card keeps its side and flips only when that side can't hold it; a
  card that opens anew still opens below the caret when there is room.
- **The title's tag suggestions follow their `#`** as the note scrolls, and
  wait out of sight while it is under the header.
- **A measured card's natural height** is its laid-out height plus what any
  part gave up to fit (`atticDropdownHeightGivenUp`, the tag picker's list),
  read as one preference value, so a cut-short tag picker settles at once.
- **VoiceOver**: a dropdown row is "selected" only while it has the list's
  highlight; a tick is the menu item's mark (`AXMenuItemMarkChar`).
