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
    /// The checkbox's hit area (the glyph is 13): the 28 pt minimum target
    /// (it was 22; control size Medium keeps every hit area at 28 or more).
    static let hitSize: CGFloat = AtticControlSize.minimumHitTarget
    /// Checkbox to title.
    static let titleGap: CGFloat = 8
}

// MARK: - Task row, quick look and card

/// A task row (32 pt, 48 with a details line; spacing B, owner
/// 2026-10-20), from the row's top: the title's 18 pt line box at 7 in a
/// 32 pt row (centred in its 28 pt pill); in a 48 pt one the title at 5
/// (3 in the 44 pt pill), 2 pt, then the 14 pt details line, so the caps
/// sit 7.5 from the pill's top and the tag fill 7 from its bottom. The
/// circle is centred on the title line (16, or 14), the 28 / 44 pt
/// highlight 2 pt inside the row.
enum AtticTaskRowMetrics {
    static let titleLineHeight: CGFloat = 18
    /// The details line of All notes' rows and the quick look card.
    static let detailsLineHeight: CGFloat = 16
    /// A task row's details line (spacing B): the tag fill's own height,
    /// so the fill ends 7 above the pill's bottom.
    static let rowDetailsLineHeight: CGFloat = 14
    static let titleToDetails: CGFloat = 2
    /// The title's line box in a two-line pill (spacing B: 3, so the caps
    /// sit 7.5 from the pill's top, matching the tag's 7 at the bottom).
    static let twoLineTitleInset: CGFloat = 3
    /// The title line in its row: centred in a one-line row (7 in 32);
    /// in a two-line one, `twoLineTitleInset` into the pill (5 in 48).
    /// (D-13 had both at 8; spacing B moves the two-line block up 3.)
    static func titleTop(twoLine: Bool) -> CGFloat {
        twoLine ? pitchTopInset + twoLineTitleInset : (AtticLayout.rowPitch - titleLineHeight) / 2
    }
    /// The text block centred in its row (All notes' rows keep it: 6 from
    /// the top of a 48 pt row).
    static func centredBlockTop(twoLine: Bool) -> CGFloat {
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
    /// The pin sits on its bounds' centre (icon audit A3-03: the −0.5 nudge
    /// left its bounds 0.62 pt high; at 0 they are 0.12 pt high, and its
    /// broad head keeps its mass high either way).
    static let pinGlyphOffsetY: CGFloat = 0
    /// O14-05: the pinned pin, and what hovering it offers (Unpin).
    static let pinnedSymbol = "pin.fill"
    static let unpinSymbol = "pin.slash"
    /// New note's `square.and.pencil` (A3-01: measured low and right).
    static let newNoteGlyphOffset = CGSize(width: -0.5, height: -0.5)
    /// All notes' `rectangle.stack` (A3-02: measured high).
    static let stackGlyphOffsetY: CGFloat = 0.5
    /// Icon and label buttons: padding each side and icon-to-label gap.
    static let labelPadding: CGFloat = 12
    static let iconLabelGap: CGFloat = 6
    /// The icon beside a label is a point smaller than an icon-only glyph.
    static let labelIconSize: CGFloat = 13
}

/// The header's page button (Phase 0's mode dock): 30 pt (Medium), inset
/// 4, 22 pt segments 2 apart (30 shut, 78 open), the raised glyph's size.
enum AtticPageButtonMetrics {
    static let inset: CGFloat = 4
    static let segment: CGFloat = AtticControlSize.headerControl - 2 * inset
    static let gap: CGFloat = 2
    static let iconSize: CGFloat = AtticControlSize.raisedGlyph
    /// Phase 0's hairline around an accented current page.
    static let accentStrokeWidth: CGFloat = 0.75
}

/// The add bar (chrome B: 32 tall, radius 13.5; the send button inside).
/// Composers that grow with their text (O17-05): the add bar and a
/// subtask's entry wrap onto more lines up to this many, then scroll
/// inside, and shrink back when the text is cleared or added.
enum AtticComposerMetrics {
    static let maxLines = 6
}

enum AtticAddBarMetrics {
    /// The bar's plus stands where a row's circle does: with the bar on the
    /// controls' 16 pt line, the plus is centred on the circles' centre
    /// line (31.5 = 16 + 8 + 15 / 2) and the text starts on the task
    /// titles' line (47 = 16 + 8 + 15 + 8). Spacing B (owner, 2026-10-20)
    /// moved both lines; the bar's contents follow them (they were 36 and
    /// 56, with a 24 pt slot).
    static let leadingPadding: CGFloat = AtticLayout.contentFromChrome
    static let iconSlot: CGFloat = AtticControlSize.statusCircle
    static let gap: CGFloat = AtticLayout.circleToTitle
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
    /// The ellipsis symbol's weight (O17-10): heavy enough that its three
    /// dots sit closer than they are wide and read as one glyph, as the
    /// typeset "…" does, not three spaced dots.
    static let iconWeight: Font.Weight = .black
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
/// with one hairline and D's shadow. The Compact size (owner, 2026-10-05,
/// p2-28): 16 pt corners, 28 pt rows touching, 6 pt in from the edge, with
/// 13 pt names (`AtticTextStyle.dropdownRow`).
/// Every value of the look is here, so it is tuned in one place.
enum AtticDropdownMetrics {
    static let cornerRadius: CGFloat = 16
    /// Rows and fields sit this far in from the card's edge.
    static let inset: CGFloat = 6
    static let rowHeight: CGFloat = 28
    static let rowPadding: CGFloat = 9
    /// The pill: the whole row.
    static let highlightRadius: CGFloat = 8
    /// Native soft scroll edges overlap this small inset in cramped lists.
    static let iconSize: CGFloat = 13
    static let iconSlot: CGFloat = 16
    /// Between a row's columns (check, mark, icon, name).
    static let columnGap: CGFloat = 10
    static let checkSize: CGFloat = 10.5
    /// The tick's column, at the row's end (N-4's card design).
    static let checkSlot: CGFloat = 12
    /// A tag's colour dot before its name (N-4's card: 7 pt), in a column
    /// as wide as the tick's.
    static let dotSize: CGFloat = 7
    static let dotSlot: CGFloat = 12
    /// A priority's mark (↓, !, !!).
    static let markSlot: CGFloat = 15
    /// The least room before a trailing detail (⌥⌘2, 2 Oct).
    static let detailGap: CGFloat = 14
    /// A field (Find or add a tag, the link): 26 pt on the row's pill; the
    /// gap under it.
    static let fieldHeight: CGFloat = 26
    static let fieldGap: CGFloat = 3
    /// A quiet gap between groups (space, never a line).
    static let groupGap: CGFloat = 5
    /// The width rule (p2-23): fits its content, never under 144 pt, never
    /// past the panel's 12 pt margin.
    static let minWidth: CGFloat = 144
    static let panelMargin: CGFloat = 12
    /// From the anchor (the caret's line, a strip button) to the card.
    static let anchorGap: CGFloat = 6
    /// Room around the card for its shadow (12 down plus a 32 pt blur).
    static let shadowRoom: CGFloat = 44
    /// The date card (p2-30 draft 2 on p2-29 draft A; O14-09's polish,
    /// 2026-10-14): one grid of 29 x 29 cells, each holding a 25 pt
    /// rounded-square mark (7 pt corners), so the marks are 4 pt apart
    /// across and down. The month header is a row as tall as a week (3 pt
    /// more above it), on the grid's edges: the title starts at the first
    /// column's mark and › ends at the last column's. Then a 16 pt weekday
    /// row and the weeks. Every mark is 11 pt from the card's edges (3 pt
    /// in from the rows' edge, 3 pt above the card's).
    static let monthHeaderTop: CGFloat = 3
    static let monthChevron: CGFloat = 10
    /// ‹ and ›: 22 pt marks (6 pt corners), 2 pt apart, lit as a day is.
    static let monthNavMark: CGFloat = 22
    static let monthNavRadius: CGFloat = 6
    static let monthNavGap: CGFloat = 2
    /// Today in the month header: 12 pt text on a mark as tall as ‹ ›
    /// (their corners too), 2 pt before ‹.
    static let todayHeight: CGFloat = 22
    static let todayPadding: CGFloat = 6
    static let todayRadius: CGFloat = 6
    static let monthTodayGap: CGFloat = 2
    static let weekdayHeight: CGFloat = 16
    static let monthCellWidth: CGFloat = 29
    static let monthCellHeight: CGFloat = 29
    static let monthMark: CGFloat = 25
    static let monthMarkRadius: CGFloat = 7
    static let monthGridInset: CGFloat = 3
    static let monthGridBottom: CGFloat = 3
    /// The month title's start and ›'s end: the first and last columns'
    /// marks.
    static let monthTitleLeading: CGFloat = monthGridInset + (monthCellWidth - monthMark) / 2
    static let monthHeaderTrailing: CGFloat = monthTitleLeading
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
    static let spacing: CGFloat = 12
}

/// Tag chips (18 tall, control corner rule).
enum AtticTagMetrics {
    static let horizontalPadding: CGFloat = 6
    /// A tag set in a line of text (a row's details, a note's tag line):
    /// its hue's fill reaches this far past the words on each side, so the
    /// fill changes no layout (colour pass sheet: 4 px padding, -2 px margin).
    static let inlineFillOutset: CGFloat = 4
    static let inlineFillRadius: CGFloat = 5
}

// MARK: - Notes (Phase 2, slice 2)

/// The writing view and All notes (UX plan § 2, mockups p2-01, p2-02,
/// p2-05, p2-15).
/// Notes v2's type and spacing (text direction 5, "Notion-like", owner
/// 2026-10-08; the values are the draft's own, `redesign-notes-v2/drafts/
/// v2-04-text-directions.html`, `notion`). SF Pro throughout the note, one
/// near-black ink for the text and its headings; SF Mono for code.
///
/// Every gap is the space between two blocks' line boxes, set by the lower
/// block's kind, except that a heading binds to what follows it. The
/// editor adds each one as the lower paragraph's `paragraphSpacingBefore`
/// (`NoteTextStyle`), so no gap is ever counted twice.
enum AtticNoteType {
    struct Role: Equatable, Hashable, Sendable {
        let size: CGFloat
        let lineHeight: CGFloat
        /// The draft's CSS weight: 400 regular, 650 (between semibold and
        /// bold) for the headings, 700 bold for the note's title.
        let weight: CGFloat
        var monospaced = false
    }

    /// The note's first line.
    static let title = Role(size: 18.5, lineHeight: 22, weight: 700)
    /// R14 (Codex Pages scaled to the panel, `notes-r14-spec.md` B.2):
    /// Codex's sizes × 12.5 / 15, the body kept at the owner's 12.5. The
    /// Title style inside the note (H1), Heading (H2), Subheading (H3) and
    /// Small Heading (H4–H6: the body's size, the headings' weight).
    static let titleStyle = Role(size: 16.5, lineHeight: 21, weight: 650)
    static let heading = Role(size: 15, lineHeight: 20, weight: 650)
    static let subheading = Role(size: 13.5, lineHeight: 18.5, weight: 650)
    static let smallHeading = Role(size: 12.5, lineHeight: 18.5, weight: 650)
    /// Body, lists, checklists, quotes, callouts and table cells: 12.5 on
    /// a 1.48 line (Codex's 1.53 for a shorter measure).
    static let body = Role(size: 12.5, lineHeight: 18.5, weight: 400)
    /// A quote: the body's size and ink beside a 3 pt bar (Codex).
    static let quote = Role(size: 12.5, lineHeight: 18.5, weight: 400)
    /// Code (SF Mono) on Codex's 1.5 line, in one rounded block.
    static let mono = Role(size: 11, lineHeight: 16.5, weight: 400, monospaced: true)
    /// A code block's language label: Attic's smallest content text.
    static let codeLabel = Role(size: 11, lineHeight: 14, weight: 400)
    /// Inline code's face in its chip (Codex 0.87 em).
    static let inlineCodeSize: CGFloat = 11

    /// Spacing (B.3, Codex's whitespace × 0.6): between paragraphs (and
    /// inside quotes and callouts), between list or checklist items, and
    /// from the note's title to its first block.
    static let paragraphGap: CGFloat = 8
    static let listItemGap: CGFloat = 3
    static let titleToText: CGFloat = 10
    /// Above the Title style, Heading, Subheading and Small Heading; below
    /// each, to the block it introduces (above : below ≈ 2.7 : 1); a
    /// heading right after a heading sits 6 under it.
    static let aboveTitleStyle: CGFloat = 20
    static let aboveHeading: CGFloat = 16
    static let aboveSubheading: CGFloat = 14
    static let aboveSmallHeading: CGFloat = 12
    static let belowTitleStyle: CGFloat = 6
    static let belowHeading: CGFloat = 6
    static let belowSubheading: CGFloat = 6
    static let belowSmallHeading: CGFloat = 6
    static let headingAfterHeading: CGFloat = 6
    /// Around a box (code, a callout, a quote run) and a block object (an
    /// image, a file, a divider, a table); 6 when it follows a heading.
    static let blockMargin: CGFloat = 12
    static let blockAfterHeading: CGFloat = 6
    /// The code block (B.4): 8 above and below its lines, 12 at the sides,
    /// the content card's radius 10 and a 0.5 pt hairline. Its label row
    /// (14 tall) sits at the top, 4 above the first code line.
    static let monoPaddingV: CGFloat = 8
    static let monoPaddingH: CGFloat = 12
    static let monoRadius: CGFloat = AtticRadius.contentCard
    static let monoHairline: CGFloat = 0.5
    static let monoLabelHeight: CGFloat = 14
    static let monoLabelGap: CGFloat = 4
    /// Copy: a 16 pt icon chip in the label row, 7 in from the block's
    /// right edge and 7 down from its top (centred on the row), so it never
    /// covers code by layout. Its radius is a third of its size (5.3).
    /// Shown on hover, while the caret is in the block, or for VoiceOver.
    static let monoCopySize: CGFloat = 16
    static let monoCopyInset: CGFloat = 7
    static let monoCopyTop: CGFloat = 7
    static let monoCopyGlyph: CGFloat = 9
    /// Lists and checklists: their text 20 in (each level 20 more). Every
    /// marker sits in one 14 pt slot at the line's start, 6 before the
    /// text: a 4 pt disc, a 4.5 pt ring (1 pt stroke) and a 3.5 pt square
    /// by depth, centred on x 7 and raised 0.5 off the first line's
    /// x-height middle; numbers, letters and roman numerals end at x 14.
    static let listTextInset: CGFloat = 20
    static let listLevelStep: CGFloat = 20
    static let markerSlot: CGFloat = 14
    static let bulletDot: CGFloat = 4
    static let bulletRing: CGFloat = 4.5
    static let bulletRingStroke: CGFloat = 1
    static let bulletSquare: CGFloat = 3.5
    static let bulletSquareRadius: CGFloat = 0.5
    static let bulletCentre: CGFloat = 7
    static let bulletLift: CGFloat = 0.5
    static let numberGap: CGFloat = 6
    /// Quote: a 3 pt bar at the column's edge, the text 20 in (the lists'
    /// column).
    static let quoteBar: CGFloat = 3
    static let quoteTextInset: CGFloat = 20
    /// Callout: the recessed fill in a radius-10 box, 8 above and below
    /// its lines and 12 at the sides; the emoji at 15 pt in a 16 pt slot
    /// 12 in, centred on the first line's cap height, the text at 36 (12
    /// without an icon).
    static let calloutPaddingV: CGFloat = 8
    static let calloutPaddingH: CGFloat = 12
    static let calloutRadius: CGFloat = AtticRadius.contentCard
    static let calloutIconSize: CGFloat = 15
    static let calloutIconSlot: CGFloat = 16
    static let calloutTextInset: CGFloat = 36
    /// Inline code: a 14 pt chip centred on the x-height middle, radius 4,
    /// 4 outside the glyphs on each side (kerned in, so the line keeps its
    /// width rhythm).
    static let inlineCodeChipHeight: CGFloat = 14
    static let inlineCodeChipRadius: CGFloat = 4
    static let inlineCodeChipPadding: CGFloat = 4
    /// A divider: a 1 pt hairline across the column.
    static let dividerThickness: CGFloat = 1
    /// The block handle (D.2): 2 × 3 dots of 2 pt, 4 apart both ways (a
    /// 6 × 10 glyph), centred 12 left of the column (the table row grip's
    /// line) on the block's first line; a 24 × 28 hit area.
    static let handleDot: CGFloat = 2
    static let handlePitch: CGFloat = 4
    static let handleFromColumn: CGFloat = 12
    static let handleHitSize = CGSize(width: 24, height: 28)
    /// The drop line: 2 pt in the accent, radius 1.
    static let dropLineThickness: CGFloat = 2
    /// The fold chevron after a heading's last glyph: 8 wide, 6 after it.
    static let foldChevronWidth: CGFloat = 8
    static let foldChevronGap: CGFloat = 6
}

/// Notes v2 tables (spec § 4.1, sheet 3, owner 2026-10-08): the body's
/// type in cells (direction 5: 14 / 21), 6 pt side and 4 pt top and bottom
/// padding, columns 56–168 by content, a 0.5 pt grid in a 10 pt card, a
/// 16 pt fade at a cut edge and a 3 pt scroll indicator under a wide table.
enum AtticNoteTableMetrics {
    /// R14: Codex's 13 / 10 × 0.6.
    static let cellPaddingH: CGFloat = 8
    static let cellPaddingV: CGFloat = 6
    static let minColumnWidth: CGFloat = 56
    static let maxColumnWidth: CGFloat = 168
    /// The narrowest a dragged column may get.
    static let minDraggedWidth: CGFloat = 32
    static let radius: CGFloat = AtticRadius.contentCard
    static let hairline: CGFloat = 0.5
    /// Increase Contrast raises the grid to 1 pt.
    static let contrastHairline: CGFloat = 1
    static let edgeFade: CGFloat = 16
    static let indicatorHeight: CGFloat = 3
    /// The indicator's top, under the table's bottom edge (inside the 8 pt
    /// block margin, so scrolling never moves the text below).
    static let indicatorGap: CGFloat = 2.5
    static let activeRingWidth: CGFloat = 1.5
    static let activeRingRadius: CGFloat = 3
    /// The column grip (above the active column) and the row grip (in the
    /// margin, 16 from the panel's edge: 12 left of the column).
    static let columnGripSize = CGSize(width: 18, height: 5)
    static let rowGripSize = CGSize(width: 5, height: 14)
    static let rowGripFromColumn: CGFloat = 12
    static let columnGripAbove: CGFloat = 7
    /// The "+" chips at the end of the last column and under the last row.
    static let addChipSize: CGFloat = 14
    static let addChipGlyph: CGFloat = 8
    /// Grips and chips keep a 28 pt hit target, as every small control.
    static let gripHitTarget: CGFloat = 28
    /// The vertical grid line's drag area.
    static let resizeHitWidth: CGFloat = 8
}

enum AtticNoteMetrics {
    /// The note's text column (title and body): 8 inside the chrome's 16 pt
    /// line (24 from the panel's edge, the Tasks circles' line), moving
    /// inward with it. It insets both sides, so the right edge mirrors it.
    static let columnInset: CGFloat = AtticLayout.contentFromChrome
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
    /// The status slot's pill: as tall as the bottom row's buttons (32), at
    /// most 176 wide, and never wider than the room the row has left
    /// (`pillMaxWidth(panelWidth:chromeInset:showsFormat:)`), so the row can
    /// never outgrow the panel and push its corner buttons off its edges.
    static let pillHeight: CGFloat = AtticControlSize.headerControl
    static let pillMaxWidth: CGFloat = 176
    /// Aa to New note: the spec's 12 pt between separate controls (D-15:
    /// at chrome B's 6 they read as two glass blobs almost touching).
    static let formatButtonGap: CGFloat = 12
    /// The status pill's room between the bottom row's buttons: the panel
    /// less the chrome insets, the buttons (All notes, Aa, New note), Aa's
    /// gap and 12 clear on each side of the pill.
    static func pillMaxWidth(panelWidth: CGFloat, chromeInset: CGFloat, showsFormat: Bool) -> CGFloat {
        let buttons = AtticControlSize.panelButton.width * (showsFormat ? 3 : 2) + (showsFormat ? formatButtonGap : 0)
        let room = panelWidth - 2 * chromeInset - buttons - 2 * pillMinGap
        return max(0, min(pillMaxWidth, room))
    }
    static let pillIconSize: CGFloat = 13
    static let pillGap: CGFloat = 6
    static let pillPadding: CGFloat = 12
    /// The least room between the pill and All notes or Aa: 9, so every
    /// notice headline still fits a 320 pt panel's 162 pt slot with D-15's
    /// 12 pt between Aa and New note. It is only ever this tight beside the
    /// longest headline; a shorter pill sits in more room.
    static let pillMinGap: CGFloat = 9
    /// The details pop-over (p2-15 #2): 280 wide, items 14 apart.
    static let detailsWidth: CGFloat = 280
    static let detailsPadding: CGFloat = 16
    static let detailsItemGap: CGFloat = 14
    /// All notes: the rows' text on the note column (16 inside the list's
    /// 8 pt page edge). Its search field uses Tasks' columns (S-06).
    static let rowTextX: CGFloat = 16
    /// All notes sits on the shared content column (design review D-07): the
    /// page's edge is Tasks' (the text, 16 into it, lands 8 inside the
    /// controls' line: 24 at the default corner), the rows' highlights and
    /// the search field's edges are on the controls' own line (16 at the
    /// default corner, 8 clear of the text, like a task row's pill), and
    /// the right-hand edges mirror the left.
    static func libraryPageEdge(chromeInset: CGFloat) -> CGFloat {
        max(0, chromeInset + AtticLayout.contentFromChrome - AtticLayout.circleX)
    }
    /// How far a row's highlight (or the search field) sits inside the
    /// library's page edge: `circleX - contentFromChrome`, so its edge is
    /// the controls' line.
    static let libraryHighlightInset: CGFloat = AtticLayout.circleX - AtticLayout.contentFromChrome
    /// The ⋯ at the end of a row's title line (in the time's place).
    static let rowActionsGlyphSize: CGFloat = 14
    static let countIconSize: CGFloat = 10
    static let countGap: CGFloat = 3
    static let countsSpacing: CGFloat = 8
}

/// Notes' format controls (Phase 2 slice 3, mockups p2-16 D and p2-03):
/// the selection bar, Aa's pop-over, the `/` list and its date card, and
/// the link card. The bar is a raised capsule 36 tall (28 pt controls in a
/// 4 pt inset, like the selection bar), 24 pt toggles so it fits a 320 pt
/// panel; it floats 6 above the selection (below when there is no room).
enum AtticNoteFormatMetrics {
    static let barHeight: CGFloat = AtticControlSize.smallHeight + AtticControlSize.capsuleInset * 2
    /// V-03: a showing bar glides to a new selection's place on its side,
    /// and fades in when it changes sides (never crossing the selection).
    static let barMoveDuration: Double = AtticMotionScale.standard
    static let barFadeDuration: Double = AtticMotionScale.fast
    static let barToggleWidth: CGFloat = 24
    /// The highlighter's chevron (N-2 option A): a narrow second half of
    /// the highlight cell, its glyph 7 pt.
    static let highlightChevronWidth: CGFloat = 12
    static let highlightChevronSize: CGFloat = 7
    static let barGroupGap: CGFloat = 4
    static let barStylePadding: CGFloat = 7
    static let barStyleChevron: CGFloat = 8
    /// U-01: extra room after the bar's last toggle, so its glyph stands as
    /// far from the capsule's end as the style's name does from its start
    /// (4 + 7 = 11 at the leading end; 4 + about 3.5 of the cell's own
    /// side bearing + 4 at the trailing end).
    static let barTrailingRoom: CGFloat = 4
    /// From the selection's line to the bar, and from the panel's edge.
    static let barGap: CGFloat = 6
    static let barEdgeMargin: CGFloat = 4
    /// The format row (OD-14): 28 pt cells, 24 when a long style name
    /// would not fit the panel; 16 pt upright lines 4 from their groups.
    /// Chrome B: the row is the corner controls' 32, its cells 24 tall in
    /// the 4 pt inset (the capsule-chip rule).
    static let rowCellHeight: CGFloat = AtticControlSize.headerControl - 2 * AtticControlSize.capsuleInset
    static let rowToggleWidth: CGFloat = 28
    static let rowCompactToggleWidth: CGFloat = 24
    static let rowSeparatorHeight: CGFloat = 16
    static let rowSeparatorPadding: CGFloat = 4
    /// The compact row's lines (24 pt cells): 2 from their groups, so
    /// "Subheading" fits a 320 pt panel's 288 pt row whole (A39 F11).
    static let rowCompactSeparatorPadding: CGFloat = 2
    /// The `/` list, the date card and the link card, 6 below the line.
    static let linkCardWidth: CGFloat = 272
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
    /// The block file card in a task's note (`p3-19` column 2, `p3-21`;
    /// D5, D24): radius 17, the recessed fill, no border; a 28 pt header
    /// with the type ("PDF") left and Quick Look and ⋯ right, then the
    /// glyph, the name and the size, 10 under.
    static let blockRadius: CGFloat = AtticRadius.groupCard
    static let blockHeaderHeight: CGFloat = 28
    static let blockCardHeight: CGFloat = 70
    static let blockFirstLine: CGFloat = 36
    static let blockSecondLine: CGFloat = 52
    static let blockHeaderGlyph: CGFloat = 11
    static let blockHeaderGap: CGFloat = 10
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
    /// The selected object: a ring, and a resize corner (a 10 pt disc on
    /// the object's bottom-trailing corner, 20 pt to grab).
    /// The selected object's ring (F-06b, owner 2026-10-11): one 1.5 pt
    /// ring on the object's own edge, inside it, on its own corner radius,
    /// so it hugs the card or image with no gap and no second ring.
    static let ringWidth: CGFloat = 1.5
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
/// Top glass (option "B for the top", 2026-10-22): with rows and notes
/// running under the top line, its plain controls float on the raised
/// material the corner buttons and the composer strip use. A tab group
/// (Now · Later · Done, All notes and its tags) sits in one capsule; each
/// icon (Find, View Options, the library's magnifier) in its own circle; an
/// open search field on the same material. The labels stay where they were.
enum AtticTopGlassMetrics {
    /// The secondary floating controls' height, a step under the corner
    /// buttons (owner, 2026-10-22).
    static let height: CGFloat = AtticControlSize.secondaryControl
    /// How far a tab capsule reaches past its first and last label: its
    /// leading edge on the controls' line, the labels on the content line.
    static let capsulePadding: CGFloat = AtticLayout.contentFromChrome
    /// Between two glass shapes on the line (the composer strip's gap).
    static let spacing: CGFloat = AtticPickerMetrics.stripSpacing
    /// The last circle's trailing edge from the page's edge: on the
    /// controls' line, under the corner button above it.
    static let lineEndInset: CGFloat = AtticLayout.contentFromChrome
}

enum AtticPickerMetrics {
    static let rowGap: CGFloat = 8
    /// Between two lit rows' fills (round 5, the owner saw two adjacent tag
    /// rows lit as one block): each fill is inset half of it top and bottom.
    static let highlightGap: CGFloat = 2
    static let checkSize: CGFloat = 10
    static let checkSlot: CGFloat = 12
    /// Seven dropdown rows (28 pt) before the tag list scrolls.
    static let tagListMaxHeight: CGFloat = 196
    /// Move to Task… (control audit item 5): wider than the tag list, for
    /// task titles and where each is listed; seven rows before it scrolls.
    static let taskListMaxHeight: CGFloat = 196
    static let todayRing: CGFloat = 1.2
    /// The strip's buttons 4 apart (v19, so two filled pills never touch),
    /// 8 above the bar.
    static let stripSpacing: CGFloat = 4
    /// The strip's first button from the add bar's leading edge: flush, so
    /// a filled button never reaches past the bar (U-21).
    static let stripLeading: CGFloat = 0
    /// The room a squeezed value keeps for its first characters and "…"
    /// (a tag's "#laun…", a date's "Wed …"); round 12.
    static let stripTagPrefix: CGFloat = 34
    static let stripDatePrefix: CGFloat = 42
    static let stripToBar: CGFloat = 8
    /// The strip's buttons are floating glass, each on its own (owner B,
    /// 2026-10-22: with no bottom blur, rows scroll sharp under the strip),
    /// at the secondary controls' height: 26, a step under the add bar
    /// (owner, 2026-10-22; it was 30, and 28 before the glass). An
    /// icon-only button (Attach's paperclip) is as wide as it is tall.
    static let stripHeight: CGFloat = AtticControlSize.secondaryControl
    /// A set strip button (v19): its value, 7 pt, the clear × (14 pt, its
    /// glyph 8), then 7 pt to the pill's end.
    static let stripClearGap: CGFloat = 7
    static let stripClearSize: CGFloat = 14
    static let stripClearGlyph: CGFloat = 8
    static let stripValueTrailing: CGFloat = 7
    /// Short of room (deep review P3-01), a set button's inner gaps close
    /// up before its value is cut short: 3 from the icon to the value and
    /// from the value to the ×, 4 after the × (9 pt a button). The 9 pt
    /// before the icon stay, so the first icon keeps the circles' line.
    static let stripCompactIconGap: CGFloat = 3
    static let stripCompactClearGap: CGFloat = 3
    static let stripCompactValueTrailing: CGFloat = 4
}
