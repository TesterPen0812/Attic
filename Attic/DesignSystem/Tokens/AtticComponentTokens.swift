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

/// The status circle (spec § The status circle): 16 pt.
enum AtticStatusCircleMetrics {
    static let lineWidth: CGFloat = 1.5
    static let lineWidthIncreased: CGFloat = 2
    /// Keeps the ring's outer edge half a point inside the 16 pt frame.
    static let edgeInset: CGFloat = 0.5
    /// Gap between the ring and the in-progress half disc.
    static let halfDiscGap: CGFloat = 1.75
    static let checkLineWidth: CGFloat = 1.6
    /// Inset of the check inside the filled circle.
    static let checkInset: CGFloat = 4.25
    /// Backlog's dashed ring: dash and gap.
    static let backlogDash: [CGFloat] = [2.1, 2.3]
    /// Differentiate Without Colour: 1–3 dots beside the circle.
    static let priorityDot: CGFloat = 2.5
    static let priorityDotSpacing: CGFloat = 1.5
    static let priorityMarkOffset: CGFloat = 5
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

enum AtticTaskRowMetrics {
    /// A two-line row's title line and details line.
    static let titleLineHeight: CGFloat = 18
    static let detailsLineHeight: CGFloat = 16
    static let titleToDetails: CGFloat = 1
    /// Top of the title in a two-line row (centres both lines in 42).
    static let twoLineTextTop: CGFloat = 5
    /// The circle rises a point in a two-line row, level with the title.
    static let twoLineCircleLift: CGFloat = 1
    /// The row sits 1 pt below its pitch's top (half the 2 pt row gap).
    static let pitchTopInset: CGFloat = 1
    static let trailingMinGap: CGFloat = 8
    /// Small icons in the details line (window, paperclip).
    static let detailsIconSize: CGFloat = 10
    static let detailsIconGap: CGFloat = 3
    static let attachmentIconGap: CGFloat = 2
    /// "Add to page" sits this far inside the highlight's trailing edge.
    static let dropLabelInset: CGFloat = 10
    /// The subtask count sits this far inside the highlight's trailing edge.
    static let countInset: CGFloat = 2
    /// A date alone at the right end sits where the count's text would end.
    static let dateInset: CGFloat = 8
    /// Between the date and the count at the right end.
    static let trailingGap: CGFloat = 4
}

/// "1/3 ›": the subtask count button in a row.
enum AtticSubtaskCountMetrics {
    static let height: CGFloat = 22
    static let horizontalPadding: CGFloat = 6
    static let gap: CGFloat = 3
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
    /// Icon and label buttons: padding each side and icon-to-label gap.
    static let labelPadding: CGFloat = 12
    static let iconLabelGap: CGFloat = 6
    /// The icon beside a label is a point smaller than an icon-only glyph.
    static let labelIconSize: CGFloat = 13
}

/// The page switch: icons in one capsule, the selected one also showing its
/// label (spec § Raised controls: 32 tall, chips 24, radius 9.5, inset 4).
enum AtticPageSwitchMetrics {
    static let chipSpacing: CGFloat = 2
    static let iconSize: CGFloat = 13
    /// The glyph's slot inside a chip (the widest of the three symbols).
    static let iconSlot: CGFloat = 16
    static let iconLabelGap: CGFloat = 5
    static let selectedPadding: CGFloat = 9
}

/// The add bar (spec: 36 tall, radius 15; the send button inside).
enum AtticAddBarMetrics {
    static let leadingPadding: CGFloat = 12
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
