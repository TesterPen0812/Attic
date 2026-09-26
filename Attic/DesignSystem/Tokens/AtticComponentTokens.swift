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

/// A task row (visual A, "Calm"), from the row's top: the title's 18 pt
/// line box at 8 (8 + 18 + 10 in a 36 pt row), the details line 2 below it
/// (8 + 18 + 2 + 16 + 8 in a 52 pt row), the circle centred on the title
/// line (row top + 17), the highlight 1 pt inside the row.
enum AtticTaskRowMetrics {
    static let titleLineHeight: CGFloat = 18
    static let detailsLineHeight: CGFloat = 16
    static let titleToDetails: CGFloat = 2
    /// The text block (title, or title + 2 + details) is centred in the
    /// row: 9 from the top of a 36 pt row, 7 in a 50 pt one.
    static func titleTop(twoLine: Bool) -> CGFloat {
        let block = titleLineHeight + (twoLine ? titleToDetails + detailsLineHeight : 0)
        return ((twoLine ? AtticLayout.detailRowPitch : AtticLayout.rowPitch) - block) / 2
    }
    /// The circle's centre below the row's top: the title line's centre.
    static func circleCentreY(twoLine: Bool) -> CGFloat { titleTop(twoLine: twoLine) + titleLineHeight / 2 }
    /// The highlight sits 3 pt below the row's top (3 pt clear above and
    /// below, owner 2026-09-26).
    static var pitchTopInset: CGFloat { (AtticLayout.rowPitch - AtticLayout.rowHighlightHeight) / 2 }
    /// The least room between a title (or its priority mark) and the date.
    static let trailingMinGap: CGFloat = 12
    /// Small icons in the details line (window, paperclip).
    static let detailsIconSize: CGFloat = 10
    static let detailsIconGap: CGFloat = 3
    static let attachmentIconGap: CGFloat = 2
    /// The date at the right end sits this far inside the highlight.
    static let dateInset: CGFloat = 8
}

/// Quiet text actions inside content ("Add subtask", "Open page").
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

/// The page switch: icons in one capsule, the selected one also showing its
/// label (visual A: 144 × 32, chips 24, radius 13.5 / 9.5, inset 4; the
/// selected chip 76 wide, the others 28, 2 apart).
enum AtticPageSwitchMetrics {
    static let chipSpacing: CGFloat = 2
    static let iconSize: CGFloat = 13
    /// The glyph's slot inside a chip, and the gap to the label.
    static let iconSlot: CGFloat = 14
    static let iconLabelGap: CGFloat = 6
    static let selectedPadding: CGFloat = 6
    /// The selected chip's width: 76, or wider when a label needs it.
    static let selectedMinWidth: CGFloat = 76
}

/// The header's page button (Phase 0's mode dock): 36 pt, inset 4,
/// 28 pt segments 2 apart (36 shut, 96 open), 13 pt icons.
enum AtticPageButtonMetrics {
    static let inset: CGFloat = 4
    static let segment: CGFloat = 28
    static let gap: CGFloat = 2
    static let iconSize: CGFloat = 13
}

/// The page pill above the add bar (v9, owner 2026-09-26): three dots
/// that open, under the pointer or the keyboard, into the three pages'
/// icons (open ring, dashed ring, done disc) with the page's name above.
enum AtticPagePillMetrics {
    static let dotSize: CGFloat = 5
    static let dotGap: CGFloat = 5
    static let collapsedHeight: CGFloat = 16
    static let collapsedPadding: CGFloat = 7
    static let segment = CGSize(width: 30, height: 24)
    static let segmentGap: CGFloat = 2
    static let inset: CGFloat = 3
    /// The opened pill's corner (v9), with the segments nested inside it.
    static let expandedRadius: CGFloat = 9
    static let iconSize: CGFloat = 15
    static let iconLineWidth: CGFloat = 1.4
    static let dash: [CGFloat] = [1.95, 1.75]
    /// The name above the pointed-at icon.
    static let tooltipGap: CGFloat = 6
    static let tooltipHorizontalPadding: CGFloat = 8
    static let tooltipHeight: CGFloat = 22
    static let tooltipRadius: CGFloat = 6
    /// Between the pill and the add bar.
    static let toAddBar: CGFloat = 8

    static func expandedWidth(count: Int) -> CGFloat {
        inset * 2 + segment.width * CGFloat(count) + segmentGap * CGFloat(max(count - 1, 0))
    }
    static var expandedHeight: CGFloat { segment.height + inset * 2 }
    static func collapsedWidth(count: Int) -> CGFloat {
        collapsedPadding * 2 + dotSize * CGFloat(count) + dotGap * CGFloat(max(count - 1, 0))
    }
    /// Where segment `index`'s centre sits, from the opened pill's centre.
    static func segmentCentre(_ index: Int, count: Int) -> CGFloat {
        -expandedWidth(count: count) / 2 + inset + CGFloat(index) * (segment.width + segmentGap) + segment.width / 2
    }
    /// Where dot `index`'s centre sits, from the pill's centre.
    static func dotCentre(_ index: Int, count: Int) -> CGFloat {
        (CGFloat(index) - CGFloat(count - 1) / 2) * (dotSize + dotGap)
    }
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

/// Status tabs under the header (spec: 13 pt, 14 apart).
enum AtticStatusTabMetrics {
    static let height: CGFloat = 22
    static let countGap: CGFloat = 4
    static let focusRadius: CGFloat = 4
    /// A task dragged over a tab outlines it in this shape.
    static let dropOutlineHeight: CGFloat = 26
    static let dropOutlineOutset: CGFloat = 7
}

/// Direction A's page tabs as quiet labels (Phase 0's qualities): 16 pt
/// apart; the focus ring sits 4 pt around the selected label; the click
/// target reaches 6 pt past the text.
enum AtticPageTabsMetrics {
    static let spacing: CGFloat = 16
    static let focusRadius: CGFloat = 6
    static let focusOutset: CGFloat = 4
    static let hitOutset: CGFloat = 6
}

/// The row's priority mark ("!!" High, "!" Medium) after the title.
enum AtticPriorityMarkMetrics {
    static let titleGap: CGFloat = 6
}

/// The subtask count on a row's details line: a checklist glyph and
/// "1/3", with a hover fill that reads as a control.
enum AtticSubtaskChecklistMetrics {
    /// Visual A: a 10 pt glyph in a 12 pt slot, 3 pt before the count.
    static let iconSize: CGFloat = 10
    static let iconSlot: CGFloat = 12
    static let iconGap: CGFloat = 3
    static let horizontalPadding: CGFloat = 4
    static let height: CGFloat = 18
}

/// "Completed today · N ›": the Now list's done section toggle.
enum AtticCompletedLineMetrics {
    static let height: CGFloat = 24
    /// Visual A: 12 below the last open row, its text on the title line.
    static let top: CGFloat = 12
    static let gap: CGFloat = 6
    /// An 8 pt medium chevron, 6 after the count.
    static let chevronSize: CGFloat = 8
    static let horizontalPadding: CGFloat = 6
}

/// The Done page's search row (`AtticListSearchField`): one row tall, no box.
enum AtticListSearchFieldMetrics {
    /// The magnifier (13 pt) on the circles' line; the clear button's glyph.
    static let iconSize: CGFloat = 13
    static let clearSize: CGFloat = 12
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
