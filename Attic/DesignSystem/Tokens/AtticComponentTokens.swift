import SwiftUI

// Per-component measurements: every size, gap, stroke, shadow and fixed
// colour a component draws with lives here, typed and documented, so no
// component carries a visual literal of its own. The shared scales (spacing,
// radii, control sizes, layout) are in `AtticTokens.swift`; colours that
// depend on the look are in `AtticColorTokens`.

// MARK: - Icons

/// Icons are lighter and thinner than text (spec § Colour, v4): SF Symbols
/// outlines in a light weight, in the secondary icon colour. Only a
/// selected state (the current page) or a glyph on a filled control (send)
/// is drawn heavier.
enum AtticIconWeight {
    static let outline: Font.Weight = .light
}

// MARK: - Rings and outlines

/// Keyboard focus and the current choice (spec § Hover, selection, focus:
/// "a 2 pt ring with a 2 pt gap"; its radius is the shape's plus the offset).
enum AtticRingMetrics {
    static let width: CGFloat = 2
    static let gap: CGFloat = 2
    /// How far the ring's outer edge sits outside the shape.
    static var outset: CGFloat { width + gap }
    /// L2 (option A, owner 2026-09-30): a task row the keyboard is on
    /// draws one 1 pt line on its highlight's own edge (no gap), over the
    /// lighter hover fill, in place of the 2 pt ring 2 pt outside.
    static let rowLineWidth: CGFloat = 1
    /// The drop-target outline, drawn inside the selection shape.
    static let dropOutlineWidth: CGFloat = 1.5
}

// MARK: - Shadows

/// A shadow cast only outside its shape (`AtticOutsideShadow`).
struct AtticShadowSpec: Equatable, Sendable {
    let radius: CGFloat
    let y: CGFloat
    /// Multiplies the look's shadow colour alpha.
    var alphaScale: Double = 1
}

enum AtticShadows {
    /// Menus, pop-overs, toasts and the selection bar: a soft lift…
    static let popover = AtticShadowSpec(radius: 12, y: 6)
    /// …and a tight contact shadow at half the strength.
    static let popoverContact = AtticShadowSpec(radius: 1, y: 0.5, alphaScale: 0.5)
    /// A carried item (small tilted card).
    static let carry = AtticShadowSpec(radius: 10, y: 6)
    /// A row lifted straight up for reordering: lower than a carry.
    static let reorder = AtticShadowSpec(radius: 8, y: 3, alphaScale: 0.8)
    /// Attic's own dropdowns (E1, p2-25): D's drop shadow, CSS
    /// `0 12px 32px` and `0 2px 6px` (a SwiftUI radius is half a CSS blur),
    /// in `dropdownShadow` and `dropdownContactShadow`.
    static let dropdown = AtticShadowSpec(radius: 16, y: 12)
    static let dropdownContact = AtticShadowSpec(radius: 3, y: 2)
}

/// Hairlines of raised surfaces over content (menus, pop-overs, toasts, drag cards).
enum AtticHairline {
    static let width: CGFloat = 0.5
    static let widthIncreased: CGFloat = 1
    /// The inner light band.
    static let innerRim: CGFloat = 1
    /// Recessed things (cards, tiles) get a border only under Increase Contrast.
    static let contrastBorder: CGFloat = 1
}

// MARK: - Status circle and subtasks

/// The status circle (Phase 0's confident circles, 2026-09-26): 16 pt.
enum AtticStatusCircleMetrics {
    /// The ring's outer edge is the frame's edge (the stroke is inward).
    static let edgeInset: CGFloat = 0
    /// Every open ring is one ink at one weight (Direction A): 1.6 pt,
    /// 2 pt under Increase Contrast.
    static func ringWidth(increaseContrast: Bool) -> CGFloat {
        increaseContrast ? 2 : 1.6
    }
    /// In progress: the ring with a filled 5 pt centre dot ("working on
    /// it"), never a share of anything.
    static let activeDotDiameter: CGFloat = 5
    /// Completing: the done disc sweeps in from 12 o'clock, starting this
    /// far inside the frame, and the least gap it keeps inside the ring.
    static let wedgeInset: CGFloat = 3.2
    static let wedgeGap: CGFloat = 0.7
    /// The done check (the 16 pt disc's, as before visual A).
    static let checkLineWidth: CGFloat = 1.6
    /// Inset of the check inside the done disc.
    static let checkInset: CGFloat = 4.25
    /// Later's dashed ring: weight and dash / gap.
    static let backlogLineWidth: CGFloat = 1.6
    static let backlogLineWidthIncreased: CGFloat = 2
    static let backlogDash: [CGFloat] = [2.2, 2.2]

    static func wedgeInset(ringWidth: CGFloat) -> CGFloat {
        max(wedgeInset, edgeInset + ringWidth + wedgeGap)
    }
}

/// The rounded-square subtask checkbox and its row.
enum AtticSubtaskMetrics {
    static let lineWidth: CGFloat = 1.3
    static let lineWidthIncreased: CGFloat = 1.8
    static let checkLineWidth: CGFloat = 1.5
    static let checkInset: CGFloat = 3.5
    /// The checkbox's hit area (the glyph is 14).
    static let hitSize: CGFloat = 22
    /// Checkbox to title.
    static let titleGap: CGFloat = 8
}

// MARK: - Task row, quick look and card

/// A task row (34 pt, 48 with a details line), from the row's top: the
/// text block centred (the title's 18 pt line box at 8 in a 34 pt row;
/// title, 2 pt, then the 16 pt details line at 6 in a 48 pt one), the
/// circle centred on the title line (17, or 15), the 30 / 44 pt highlight
/// 2 pt inside the row.
enum AtticTaskRowMetrics {
    static let titleLineHeight: CGFloat = 18
    static let detailsLineHeight: CGFloat = 16
    static let titleToDetails: CGFloat = 2
    /// The text block (title, or title + 2 + details) is centred in the
    /// row: 8 from the top of a 34 pt row, 6 in a 48 pt one.
    static func titleTop(twoLine: Bool) -> CGFloat {
        let block = titleLineHeight + (twoLine ? titleToDetails + detailsLineHeight : 0)
        return ((twoLine ? AtticLayout.detailRowPitch : AtticLayout.rowPitch) - block) / 2
    }
    /// The circle's centre below the row's top: the title line's centre.
    static func circleCentreY(twoLine: Bool) -> CGFloat { titleTop(twoLine: twoLine) + titleLineHeight / 2 }
    /// The highlight sits 2 pt below the row's top (2 pt clear above and
    /// below, owner 2026-09-26).
    static var pitchTopInset: CGFloat { (AtticLayout.rowPitch - AtticLayout.rowHighlightHeight) / 2 }
    /// The least room between a title (or its priority mark) and the date.
    static let trailingMinGap: CGFloat = 12
    /// Small icons in the details line (window, paperclip).
    static let detailsIconSize: CGFloat = 10
    /// Owner fix 2 (2026-09-27): an icon 5 pt before its label (the
    /// paperclip's too), items 14 pt apart with no " · " between them.
    static let detailsIconGap: CGFloat = 5
    static let detailsItemSpacing: CGFloat = 14
    /// The hover pill behind a clickable date or tags (owner fix 5 C):
    /// 18 tall, reaching 5 pt past the text on each side.
    static let metaPillHeight: CGFloat = 18
    static let metaPillOutset: CGFloat = 5
    /// The date at the right end sits this far inside the highlight.
    static let dateInset: CGFloat = 8
}

/// Quiet text actions inside content ("Add subtask", "Open page").
/// L3's flat corner buttons (`AtticFlatSurface`).
enum AtticFlatSurfaceMetrics {
    static let hairline: CGFloat = 1
}

/// The menu button's dot (follow-up part 2, item 6: View Options while a
/// filter hides tasks).
enum AtticMenuButtonMetrics {
    static let dotSize: CGFloat = 5
    static let dotInset: CGFloat = 6
}

enum AtticQuietActionMetrics {
    static let height: CGFloat = 24
    static let horizontalPadding: CGFloat = 6
    static let iconSize: CGFloat = 12
    static let iconSlot: CGFloat = 14
    static let gap: CGFloat = 8
    static let chevronSize: CGFloat = 9
    /// The chevron tucks in after the label.
    static let chevronPullIn: CGFloat = 4
}

enum AtticQuickLookMetrics {
    static let bottomPadding: CGFloat = 4
}

/// The task card in notes and task pages (recessed, radius 10).
enum AtticTaskCardMetrics {
    /// The circle's centre sits 12 + 8 from the card's leading edge.
    static let leadingInset: CGFloat = 12
    static let circleTop: CGFloat = 1
    static let titleHeight: CGFloat = 30
    static let circleToTitle: CGFloat = 4
    /// The details line tucks 6 pt under the title's line box.
    static let detailsPullUp: CGFloat = 6
    static let detailsBottom: CGFloat = 6
    static let detailsGap: CGFloat = 6
    static let detailsIconGap: CGFloat = 3
    static let chevronSize: CGFloat = 10
    static let chevronHitSize = CGSize(width: 28, height: 30)
    static let trailingInset: CGFloat = 4
    /// Expanded content aligns with the title column (12 + 16 + 10).
    static let expandedLeading: CGFloat = 38
    static let expandedTrailing: CGFloat = 12
    static let expandedBottom: CGFloat = 6
    static let actionsTop: CGFloat = 4
}

// MARK: - Controls

enum AtticRaisedButtonMetrics {
    /// The pin's glyph sits half a point up in its button (visual A), so
    /// its visible outline reads as centred.
    static let pinGlyphOffsetY: CGFloat = -0.5
    /// Icon and label buttons: padding each side and icon-to-label gap.
    static let labelPadding: CGFloat = 12
    static let iconLabelGap: CGFloat = 6
    /// The icon beside a label is a point smaller than an icon-only glyph.
    static let labelIconSize: CGFloat = 13
}

/// The header's page button (Phase 0's mode dock): 36 pt, inset 4,
/// 28 pt segments 2 apart (36 shut, 96 open), 13 pt icons.
enum AtticPageButtonMetrics {
    static let inset: CGFloat = 4
    static let segment: CGFloat = 28
    static let gap: CGFloat = 2
    static let iconSize: CGFloat = 13
    /// Phase 0's hairline around an accented current page.
    static let accentStrokeWidth: CGFloat = 0.75
}

/// The add bar (spec: 36 tall, radius 15; the send button inside).
enum AtticAddBarMetrics {
    /// With the bar 24 from the panel's edge, the plus is centred on the
    /// status circles' centre line (36 = 24 + 24 / 2) and the text starts
    /// on the task titles' line (56 = 24 + 24 + 8).
    static let leadingPadding: CGFloat = 0
    static let iconSlot: CGFloat = 24
    static let gap: CGFloat = 8
    static let plusSize: CGFloat = 12.5
    static let sendGlyphSize: CGFloat = 12
}

enum AtticSmallControlMetrics {
    static let iconSize: CGFloat = 13
    static let iconLabelGap: CGFloat = 5
    static let labelPadding: CGFloat = 9
}

/// The selection bar: the count, then the small controls.
enum AtticSelectionBarMetrics {
    static let controlSpacing: CGFloat = 2
    static let countLeading: CGFloat = 10
    static let countTrailing: CGFloat = 6
}

/// Direction A's page tabs as quiet labels (Phase 0's qualities): 16 pt
/// apart; the focus ring sits 4 pt around the selected label; the click
/// target reaches 6 pt past the text.
enum AtticPageTabsMetrics {
    static let spacing: CGFloat = 16
    static let focusRadius: CGFloat = 6
    static let focusOutset: CGFloat = 4
    static let hitOutset: CGFloat = 6
    /// L1 (option B, owner 2026-09-30): a 2 pt line in the heading ink
    /// under the active label, as wide as its text, its top 1 pt below the
    /// labels' 16 pt line.
    static let underlineHeight: CGFloat = 2
    static let underlineGap: CGFloat = 1
}

/// The row's priority mark ("!!" High, "!" Medium) after the title.
enum AtticPriorityMarkMetrics {
    static let titleGap: CGFloat = 6
}

/// The subtask count on a row's details line: a checklist glyph and
/// "1/3", with a hover fill that reads as a control.
enum AtticSubtaskChecklistMetrics {
    /// A 10 pt glyph in a 12 pt slot, 4 pt before the count: 5 pt from
    /// the glyph's edge, like every details icon (owner fix 2).
    static let iconSize: CGFloat = 10
    static let iconSlot: CGFloat = 12
    static let iconGap: CGFloat = 4
    static let horizontalPadding: CGFloat = 4
    static let height: CGFloat = 18
}

/// "Completed today · N ›": the Now list's done section toggle.
/// A task row's actions button (round 10).
enum AtticRowActionsMetrics {
    static let width: CGFloat = 22
    static let iconSize: CGFloat = 12
    /// After the date (or the title when there is none).
    static let gap: CGFloat = 4
}

enum AtticCompletedLineMetrics {
    static let height: CGFloat = 24
    /// Visual A: 12 below the last open row, its text on the title line.
    static let top: CGFloat = 12
    static let gap: CGFloat = 6
    /// An 8 pt medium chevron, 6 after the count.
    static let chevronSize: CGFloat = 8
    static let horizontalPadding: CGFloat = 6
}

/// The Done page's search on the tabs line (`AtticTabsSearchField`).
enum AtticTabsSearchMetrics {
    /// The magnifier (13 pt) on the circles' line.
    static let iconSize: CGFloat = 13
    /// The "Esc" hint's padding inside the field's end.
    static let hintPadding: CGFloat = 10
}

/// Title menus and Attic's own pop-overs (radius 20).
enum AtticPopoverMetrics {
    static let padding: CGFloat = 6
    static let defaultWidth: CGFloat = 220
    static let rowPadding: CGFloat = 8
    static let rowIconSize: CGFloat = 13
    static let rowIconSlot: CGFloat = 16
    static let rowGap: CGFloat = 8
    static let trailingMinGap: CGFloat = 16
    /// A quiet grouping gap between sections (space, never a line).
    static let groupGap: CGFloat = 6
}

/// Attic's own dropdowns, the E1 family (owner, 2026-10-02; mockups p2-25
/// E1, p2-24 D, p2-23): the `/` list, the date card (Notes and Tasks), the
/// tag and priority pickers, Aa and the link card. A solid card (no blur)
/// with one hairline and D's shadow, 20 pt corners; rows 32 pt, touching,
/// 10 pt in from the edge, so the 10 pt pill nests in the 20 pt corner.
/// Every value of the look is here, so it is tuned in one place.
enum AtticDropdownMetrics {
    static let cornerRadius: CGFloat = 20
    /// Rows and fields sit this far in from the card's edge.
    static let inset: CGFloat = 10
    static let rowHeight: CGFloat = 32
    static let rowPadding: CGFloat = 10
    /// The pill: the whole row, concentric with the corner (20 - 10).
    static let highlightRadius: CGFloat = 10
    static let iconSize: CGFloat = 14
    static let iconSlot: CGFloat = 18
    /// Between a row's columns (check, mark, icon, name).
    static let columnGap: CGFloat = 10
    static let checkSize: CGFloat = 11
    static let checkSlot: CGFloat = 12
    /// A priority's mark (↓, !, !!).
    static let markSlot: CGFloat = 16
    /// The least room before a trailing detail (⌥⌘2, 2 Oct).
    static let detailGap: CGFloat = 16
    /// A field (Find or add a tag, the date, the link): a row's height and
    /// pill; the gap under it.
    static let fieldHeight: CGFloat = 32
    static let fieldGap: CGFloat = 4
    /// A quiet gap between groups (space, never a line).
    static let groupGap: CGFloat = 6
    /// The width rule (p2-23): fits its content, never under 144 pt, never
    /// past the panel's 12 pt margin.
    static let minWidth: CGFloat = 144
    static let panelMargin: CGFloat = 12
    /// From the anchor (the caret's line, a strip button) to the card.
    static let anchorGap: CGFloat = 6
    /// Room around the card for its shadow (12 down plus a 32 pt blur).
    static let shadowRoom: CGFloat = 44
    /// The month (the date card): 30 x 28 cells, a 26 pt day disc.
    static let monthCellWidth: CGFloat = 30
    static let monthCellHeight: CGFloat = 28
    static let monthDisc: CGFloat = 26
    static let monthHeaderHeight: CGFloat = 30
    static let monthButton: CGFloat = 24
    static let monthChevron: CGFloat = 11
    static let weekdayHeight: CGFloat = 20
    /// How long a closing card stays in the overlay for its leave motion.
    static let leaveCleanup: TimeInterval = 0.3
}

/// The title that opens a native menu (a note's or a page's title).
enum AtticTitleMenuMetrics {
    static let height: CGFloat = 28
    static let horizontalPadding: CGFloat = 8
    static let chevronSize: CGFloat = 9
    static let gap: CGFloat = 5
}

// MARK: - Feedback

enum AtticToastMetrics {
    static let leadingPadding: CGFloat = 14
    static let gap: CGFloat = 10
    static let buttonPadding: CGFloat = 10
}

enum AtticNoticeMetrics {
    static let gap: CGFloat = 8
}

enum AtticErrorLineMetrics {
    static let height: CGFloat = 22
    static let gap: CGFloat = 5
    static let iconSize: CGFloat = 12
}

/// Static skeleton rows while a list loads (no shimmer).
enum AtticSkeletonMetrics {
    static let circle: CGFloat = 14
    static let barHeight: CGFloat = 10
    static let barRadius: CGFloat = 4
    /// Varied lengths, so the rows read as text and not as a grid.
    static let barWidths: [CGFloat] = [148, 112, 176, 132]
}

enum AtticSpinnerMetrics {
    static let size: CGFloat = 12
    static let lineWidth: CGFloat = 1.6
    /// The drawn arc (capture stand-in for the system spinner).
    static let arc: CGFloat = 0.72
    /// The system spinner at `.small`, scaled to the glyph size.
    static let systemScale: CGFloat = 0.8
}

// MARK: - Drag and drop

/// Carry and reorder drag previews (spec § Two drag styles).
enum AtticDragMetrics {
    /// The carried card tilts; the stack fans out behind it.
    static let tilt: Double = -3
    static let stackTilts: [Double] = [0.5, 3.5]
    static let stackOffsets: [CGSize] = [CGSize(width: 2.5, height: 1.5), CGSize(width: 5, height: 3)]
    static let stackBackOpacity: Double = 0.9
    static let taskCardHeight: CGFloat = 32
    static let taskCardMaxWidth: CGFloat = 200
    static let taskCardPadding: CGFloat = 10
    static let taskCardGap: CGFloat = 8
    static let fileCardPadding: CGFloat = 8
    static let fileCardGap: CGFloat = 5
    static let thumbnailSize = CGSize(width: 72, height: 50)
    static let fileNameMaxWidth: CGFloat = 88
    /// The stack's count badge.
    static let badgeSize: CGFloat = 18
    static let badgePadding: CGFloat = 6
    static let badgeOffset: CGFloat = 8
}

/// An image stand-in for thumbnails (radius 8, the image radius).
enum AtticThumbnailTokens {
    static let lightGradient = (top: AtticRGBA(0xCCD9ED), bottom: AtticRGBA(0xE6EBF5))
    static let darkGradient = (top: AtticRGBA(0x4D576B), bottom: AtticRGBA(0x383D4D))
    /// A title bar suggesting a screenshot.
    static let barLight = AtticRGBA.white(0.8)
    static let barDark = AtticRGBA.white(0.25)
    static let barSize = CGSize(width: 38, height: 5)
    static let barRadius: CGFloat = 2
    static let barInset: CGFloat = 7
}

// MARK: - Settings

enum AtticSettingsMetrics {
    static let sidebarIconSize: CGFloat = 13.5
    static let sidebarIconSlot: CGFloat = 16
    static let sidebarHintHeight: CGFloat = 24
    static let rowTrailingMinGap: CGFloat = 8
    /// Label over value in a grouped row.
    static let labelValueGap: CGFloat = 2
    static let popUpChevronSize: CGFloat = 10.5
    static let popUpChevronSlot: CGFloat = 16
    static let switchTrailing: CGFloat = 14
    static let sliderTrailing: CGFloat = 16
    static let sliderGap: CGFloat = 16
    static let sliderWidth: CGFloat = 180
    /// Capture stand-ins for the system switch and slider (the live UI
    /// always uses the real controls).
    static let switchDrawingSize = CGSize(width: 32, height: 18)
    static let switchKnobInset: CGFloat = 1.5
    static let switchKnobShadow = AtticShadowSpec(radius: 0.5, y: 0.5)
    static let switchKnobShadowAlpha = 0.18
    static let sliderKnobShadow = AtticShadowSpec(radius: 1, y: 0.5)
    static let sliderKnobShadowAlpha = 0.22
    static let sliderTrackHeight: CGFloat = 4
    static let sliderKnob: CGFloat = 14
    static let sliderDrawingHeight: CGFloat = 18
    /// The live preview at the top of Appearance.
    static let previewHeight: CGFloat = 156
    static let previewScale: CGFloat = 0.62
    static let previewTop: CGFloat = 18
    /// The miniature fades out over the preview card's last 36 pt.
    static let previewBottomFade: CGFloat = 36
    static let previewShadow = AtticShadowSpec(radius: 8, y: 3)
    static let previewShadowAlphaLight: Double = 0.14
    static let previewShadowAlphaDark: Double = 0.35
}

/// System, Light and Dark tiles.
enum AtticModeTileMetrics {
    static let previewSize = CGSize(width: 112, height: 70)
    static let labelGap: CGFloat = 8
    static let tileSpacing: CGFloat = 16
    /// The small window drawn inside the preview.
    static let windowRadius: CGFloat = 6
    static let windowInset: CGFloat = 12
    static let windowOverhang: CGFloat = 20
    static let lineInset: CGFloat = 9
    static let lineSpacing: CGFloat = 4
    static let lineHeight: CGFloat = 3
    static let lineWidths: [CGFloat] = [40, 28]
    /// The preview's desktop and window colours (a picture of each mode,
    /// independent of the current look).
    static let desktopLight = AtticRGBA(0xE6DBCC)
    static let desktopDark = AtticRGBA(0x454F61)
    static let windowLight = AtticRGBA(0xFAFAFA)
    static let windowDark = AtticRGBA(0x2B2B2E)
    static let lineAlphasLight: [Double] = [0.22, 0.12]
    static let lineAlphasDark: [Double] = [0.35, 0.20]
}

/// Palette tiles: Light and Dark swatches with the accent dot, and the name.
enum AtticPaletteTileMetrics {
    static let width: CGFloat = 132
    static let padding: CGFloat = 8
    static let nameGap: CGFloat = 7
    static let swatchGap: CGFloat = 4
    static let swatchSize = CGSize(width: 54, height: 22)
    /// Continuous corner at about 23 % of the swatch: a picture of a
    /// surface, not a control, so it keeps a fixed small radius.
    static let swatchRadius: CGFloat = 5
    static let swatchRimWidth: CGFloat = 0.5
    static let swatchRimLight = AtticRGBA.black(0.08)
    static let swatchRimDark = AtticRGBA.black(0.25)
    static let accentDot: CGFloat = 5
    static let accentDotInset: CGFloat = 6
    /// Three tiles per row, 12 apart.
    static let perRow = 3
    static let spacing: CGFloat = 12
}

/// Tag chips (18 tall, control corner rule).
enum AtticTagMetrics {
    static let horizontalPadding: CGFloat = 6
}

// MARK: - Notes (Phase 2, slice 2)

/// The writing view and All notes (UX plan § 2, mockups p2-01, p2-02,
/// p2-05, p2-15).
enum AtticNoteMetrics {
    /// The note's text column: 4 inside the chrome's 24 pt line (28 from
    /// the panel's edge, the Tasks circles' line), moving inward with it.
    static let columnInset: CGFloat = 4
    /// The title's first line sits 16 under the header (y = 76 in a
    /// 320 × 520 panel).
    static let titleTopGap: CGFloat = 16
    /// The ⋯ at the end of the title's first line: a 28 pt target, its
    /// glyph on the column's trailing edge; the title's lines keep 32 clear.
    static let menuButtonSize: CGFloat = 28
    static let menuGlyphSize: CGFloat = 15
    static let titleTrailingReserve: CGFloat = 32
    /// Tags under the title: 12 apart, lines 4 apart.
    static let tagSpacing: CGFloat = 12
    static let tagLineSpacing: CGFloat = 2
    /// The header title (a scrolled-away title): 36 tall, at most as wide as
    /// the room between the pin and the page button.
    static let headerTitlePadding: CGFloat = 14
    /// The status slot's pill: 36 tall, at most 176 wide (12 clear of each
    /// bottom button in a 320 pt panel).
    static let pillHeight: CGFloat = 36
    static let pillMaxWidth: CGFloat = 176
    static let pillIconSize: CGFloat = 13
    static let pillGap: CGFloat = 6
    static let pillPadding: CGFloat = 12
    /// The details pop-over (p2-15 #2): 280 wide, items 14 apart.
    static let detailsWidth: CGFloat = 280
    static let detailsPadding: CGFloat = 16
    static let detailsItemGap: CGFloat = 14
    /// All notes: the search row's magnifier and text, and the rows' text,
    /// on the note column (16 inside the list's 12 pt page edge).
    static let searchIconX: CGFloat = 14
    /// The "Esc" hint at the end of the search field.
    static let searchHintPadding: CGFloat = 10
    static let searchTextX: CGFloat = 36
    /// The list's top edge fade (the Tasks lists' 16 pt before Phase 1
    /// round 12 moved them to a veil).
    static let listTopFade: CGFloat = 16
    static let rowTextX: CGFloat = 16
    /// The ⋯ at the end of a row's title line (in the time's place).
    static let rowActionsGlyphSize: CGFloat = 14
    static let countIconSize: CGFloat = 10
    static let countGap: CGFloat = 3
    static let countsSpacing: CGFloat = 8
    /// Tag suggestions under a title hashtag: 220 wide, 6 below its line,
    /// the row text on the hashtag's first letter.
    static let suggestionWidth: CGFloat = 220
    static let suggestionGap: CGFloat = 6
    static let suggestionShadowRoom: CGFloat = 10
    /// The tag editor: 240 wide, at most 8 rows before it scrolls.
    static let tagEditorWidth: CGFloat = 240
    static let tagEditorMaxListHeight: CGFloat = 8 * 28
}

/// Notes' format controls (Phase 2 slice 3, mockups p2-16 D and p2-03):
/// the selection bar, Aa's pop-over, the `/` list and its date card, and
/// the link card. The bar is a raised capsule 36 tall (28 pt controls in a
/// 4 pt inset, like the selection bar), 24 pt toggles so it fits a 320 pt
/// panel; it floats 6 above the selection (below when there is no room).
enum AtticNoteFormatMetrics {
    static let barHeight: CGFloat = AtticControlSize.smallHeight + AtticControlSize.capsuleInset * 2
    static let barToggleWidth: CGFloat = 24
    static let barGroupGap: CGFloat = 4
    static let barStylePadding: CGFloat = 7
    static let barStyleChevron: CGFloat = 8
    /// From the selection's line to the bar, and from the panel's edge.
    static let barGap: CGFloat = 6
    static let barEdgeMargin: CGFloat = 4
    /// Aa's pop-over: 300 wide (the five style chips in one row), 32 pt
    /// toggles, groups spread to the edges, rows 8 apart.
    static let popoverToggleWidth: CGFloat = 32
    static let popoverWidth: CGFloat = 300
    static let popoverRowGap: CGFloat = 8
    static let popoverGroupGap: CGFloat = 10
    static let styleChipPadding: CGFloat = 5
    /// The `/` list, the date card and the link card, 6 below the line.
    static let slashMaxVisibleRows = 9
    static let linkCardWidth: CGFloat = 272
    static let cardGap: CGFloat = 6
    /// Room around a floating control for its shadow.
    static let shadowRoom: CGFloat = 12
}

/// Notes' images and files (Phase 2 slice 3b, UX plan § 3.5, p2-13): the
/// file card, a failure drawn on its object with its actions, the selected
/// object's ring and resize corner, the drop line and the carry card.
enum AtticNoteObjectMetrics {
    /// The card: a content card (radius 10), 12 in, a 22 pt type glyph and
    /// two 12 pt lines: the name, then the size or the failure.
    static let cardHeight: CGFloat = 54
    static let cardRadius: CGFloat = AtticRadius.contentCard
    static let cardPadding: CGFloat = 12
    static let cardIcon: CGFloat = 20
    static let cardIconSlot: CGFloat = 22
    static let cardIconGap: CGFloat = 10
    /// The two lines' centres in the 54 pt card.
    static let cardFirstLine: CGFloat = 18
    static let cardSecondLine: CGFloat = 36
    /// The actions drawn on a failed object: quiet chips 18 tall, 6 in,
    /// 4 apart, 8 after the message. Only those that fit are drawn; every
    /// one is also in the object's menu and its VoiceOver actions.
    static let chipHeight: CGFloat = 18
    static let chipPadding: CGFloat = 6
    static let chipGap: CGFloat = 4
    static let messageGap: CGFloat = 8
    /// A failed image's face: the glyph (14) over the message, the chips
    /// under it, 6 apart; one row when the reserved space is under 64 tall.
    static let failureGlyph: CGFloat = 14
    static let failureRowGap: CGFloat = 6
    static let failureStackMinHeight: CGFloat = 64
    /// The selected object: a 2 pt ring 2 outside it, and a resize corner
    /// (a 10 pt disc on the ring's bottom-trailing corner, 20 pt to grab).
    static let ringWidth: CGFloat = 2
    static let ringOutset: CGFloat = 2
    static let resizeHandle: CGFloat = 10
    static let resizeHitTarget: CGFloat = 20
    /// The drop line: 2 pt, with a 6 pt disc at its leading end, across
    /// the column.
    static let dropLineWidth: CGFloat = 2
    static let dropLineCap: CGFloat = 6
    /// The carry card: the file card's look at 220 × 44, "+N" for more.
    static let carryWidth: CGFloat = 220
    static let carryHeight: CGFloat = 44
}

/// The pickers of owner fix 5 (v17): the composer strip, the suggestions
/// over the add bar and Move to Task…. The date and tag pickers' card, rows
/// and month are the dropdown family's (`AtticDropdownMetrics`).
enum AtticPickerMetrics {
    static let rowGap: CGFloat = 8
    /// Between two lit rows' fills (round 5, the owner saw two adjacent tag
    /// rows lit as one block): each fill is inset half of it top and bottom.
    static let highlightGap: CGFloat = 2
    static let checkSize: CGFloat = 10
    static let checkSlot: CGFloat = 12
    static let dividerGap: CGFloat = 4
    /// Seven 32 pt dropdown rows before the tag list scrolls.
    static let tagListMaxHeight: CGFloat = 224
    /// Move to Task… (control audit item 5): wider than the tag list, for
    /// task titles and where each is listed; seven rows before it scrolls.
    static let taskWidth: CGFloat = 260
    static let taskListMaxHeight: CGFloat = 196
    static let suggestionWidth: CGFloat = 220
    static let todayRing: CGFloat = 1.2
    /// The strip's buttons 4 apart (v19, so two filled pills never touch),
    /// 8 above the bar.
    static let stripSpacing: CGFloat = 4
    /// The room a squeezed value keeps for its first characters and "…"
    /// (a tag's "#laun…", a date's "Wed …"); round 12.
    static let stripTagPrefix: CGFloat = 34
    static let stripDatePrefix: CGFloat = 42
    static let stripToBar: CGFloat = 8
    /// A set strip button (v19): its value, 7 pt, the clear × (14 pt, its
    /// glyph 8), then 7 pt to the pill's end.
    static let stripClearGap: CGFloat = 7
    static let stripClearSize: CGFloat = 14
    static let stripClearGlyph: CGFloat = 8
    static let stripValueTrailing: CGFloat = 7
}
