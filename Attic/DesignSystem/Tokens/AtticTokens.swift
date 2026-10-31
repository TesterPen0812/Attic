import AppKit
import SwiftUI

// The design system's measurements in one place. Every value cites the spec
// (§ "Appearance and design system") or says why it exists. Components use
// these names, never literals, and the appearance check compares rendered
// frames against them.

/// The 4 pt spacing scale. `inset14` and `gap10` are the two fine steps the
/// spec measures for text insets (grouped rows, row text) and control gaps.
enum AtticSpacing {
    static let s4: CGFloat = 4
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s20: CGFloat = 20

    /// Grouped-row text inset in Settings (spec: "text inset 14").
    static let inset14: CGFloat = 14
    /// Circle to title in a task row: 16 + 16 + 10 = the 42 pt text column.
    static let gap10: CGFloat = 10

    /// Inside a group (spec: 8–12 pt). Between groups: 20–24 pt.
    /// Separate controls in a bar (spec: "separate controls sit 12 pt apart").
    static let betweenControls: CGFloat = 12

    /// Panel margin (spec: 320 × 520, margin 12).
    static let panelMargin: CGFloat = 12
    /// Settings: below the page header (spec: 52) and between sections (34).
    static let settingsBelowHeader: CGFloat = 52
    /// Appearance, compact (Astra 26, kept by the owner in round 6).
    static let settingsBelowHeaderCompact: CGFloat = 24
    static let settingsBetweenSections: CGFloat = 34
    /// Settings content card inset from the sidebar and window edges.
    static let settingsCardInset: CGFloat = 8
    /// Group card inset inside the content card.
    static let settingsGroupInset: CGFloat = 16
    /// Section heading to its card.
    static let settingsHeadingToCard: CGFloat = 10

    static let scale: [CGFloat] = [4, 8, 12, 16, 20, 24, 32]
}

/// The owner's Shapes (Accepted 2026-10-30, "Shapes: squircle surfaces,
/// 1.4 controls"). The design draws CSS `corner-shape`, whose
/// `superellipse(K)` is the curve |x|^(2^K) + |y|^(2^K) = 1 in the corner's
/// box; `Squircle` draws |x|^n + |y|^n = 1, so n = 2^K.
enum AtticShape {
    /// Surfaces (the panel, page shells, cards, menus, popovers, sheets,
    /// note blocks, rows, thumbnails): `squircle`, superellipse(2), n = 4.
    static let surfaceExponent: CGFloat = 4
    /// Controls (buttons, segmented controls and their highlights, tags,
    /// chips, badges, day keys): curve 1.4, n = 2^1.4 ≈ 2.64.
    static let controlExponent: CGFloat = pow(2, 1.4)

    /// A control on curve 1.4 is rounded by half its height: a wide one is
    /// a capsule, a square one a whole superellipse.
    static func controlRadius(height: CGFloat) -> CGFloat { height / 2 }
}

/// Corner radii. Controls follow `control(height:)`; surfaces keep a fixed
/// radius by kind whatever their size (spec § Corner rules).
enum AtticRadius {
    // The Shapes radii (Accepted 2026-10-30): design px, half in points.

    /// The panel and page shells: 104 px.
    static let shell: CGFloat = 52
    /// Cards: 48 px (the design's Card radius slider; owner, 2026-10-31,
    /// up from 36). Calendar day cards and Notes board cards both use it.
    static let card: CGFloat = 24
    /// Rows: 24 px.
    static let row: CGFloat = 12
    /// Menus and popovers: 32 px (owner, 2026-10-31: "back to what it
    /// was", the 16 pt of b74eee51), with 6 px padding; rows concentric,
    /// 32 − 6 = 26 px.
    static let menu: CGFloat = 16
    static let menuPadding: CGFloat = 3
    static let menuRow: CGFloat = concentric(outer: menu, padding: menuPadding)
    /// Note blocks: 20 px.
    static let noteBlock: CGFloat = 10
    /// Small objects (thumbnails, file tiles): 12 px.
    static let small: CGFloat = 6
    /// The format sheet: its 12 pt buttons plus its 7 pt padding (38 px).
    static let formatSheet: CGFloat = concentric(inner: 12, padding: 7)
    /// The review bar: its 10 pt buttons plus its 7 pt padding (34 px).
    static let reviewBar: CGFloat = concentric(inner: 10, padding: 7)

    /// Nested shapes stay concentric: the inner radius is the outer radius
    /// minus the padding between them, so the outer one is the inner one
    /// plus the padding (the format sheet 24 + 14 = 38 px).
    static func concentric(inner: CGFloat, padding: CGFloat) -> CGFloat { inner + padding }
    static func concentric(outer: CGFloat, padding: CGFloat) -> CGFloat { max(0, outer - padding) }

    /// Controls: Apple's continuous corner at about 42 % of the height
    /// (owner's decision, 2026-09-25, spec rev 175: the rounder corner,
    /// chosen over Craft's 32 % on the full panel), rounded to the half
    /// point: 13.5 on 32, 14.5 on 34, 15 on 36, 12 on 28, 7.5 on 18.
    /// Kept by the owner on 2026-09-27 after comparing fully round controls.
    /// Shapes (Accepted 2026-10-30): controls are on curve 1.4 and rounded
    /// by half their height, so a wide control is a capsule and a square
    /// one a whole superellipse.
    static let controlFraction: CGFloat = 0.5

    /// The header's controls (the owner's panel design: 30 px on 54 px,
    /// clamped to round).
    static let header: CGFloat = AtticControlSize.headerControl / 2

    static func control(height: CGFloat) -> CGFloat {
        (height * controlFraction * 2).rounded() / 2
    }

    static let popover: CGFloat = menu
    static let groupCard: CGFloat = 17
    static let contentCard: CGFloat = 10
    static let tile: CGFloat = 10
    static let image: CGFloat = 8
    /// Hover, selection and pressed highlights on rows (always 10).
    static let highlight: CGFloat = 10
    /// A chip nested in a capsule: outer radius minus the inset
    /// (14.5 − 4 = 10.5 on the 34 pt capsule).
    static var nestedChip: CGFloat { control(height: AtticControlSize.capsuleHeight) - AtticControlSize.capsuleInset }
    /// The subtask checkbox is a true squircle: a superellipse of this
    /// exponent across the whole 14 pt box (owner, 2026-09-26).
    static let subtaskCheckboxExponent: CGFloat = 4

    /// Nested radius, used only when the gap is 6 pt or less (spec rule 3).
    static func nested(outer: CGFloat, gap: CGFloat) -> CGFloat? {
        gap <= 6 ? max(outer - gap, 0) : nil
    }

    /// A ring drawn outside a shape: the shape's radius plus the ring's offset.
    static func ring(around radius: CGFloat, offset: CGFloat) -> CGFloat { radius + offset }
}

/// Control sizes (spec § Raised controls). Controls are slightly wider than
/// tall (about 1.15 : 1).
enum AtticControlSize {
    /// The panel's raised buttons (pin, All notes, New note, Aa): the
    /// header's square, radius 13.5 by the 42 % rule.
    static let panelButton = CGSize(width: headerControl, height: headerControl)
    /// Chrome B (Notes v2, owner 2026-10-08): every corner control in Notes
    /// and Tasks, 16 pt from the panel's edges
    /// (`AtticStyle.chromeMinimumInset`), the page switch's capsule height.
    /// Control size Medium (owner, 2026-10-20): 30 pt (it was 32, and 36
    /// before chrome B); radius 12.5 by the 42 % rule.
    /// The owner's panel design (2026-10-27, 54 px at 2×): 27.
    static let headerControl: CGFloat = 27
    /// The secondary floating controls, one step under the corner controls
    /// and the add bar (owner, 2026-10-22: "too big compared to everything
    /// else"): the tabs capsule, Find and View Options, the composer strip.
    /// Their hit areas stay larger than what is drawn.
    static let secondaryControl: CGFloat = 26
    static let settingsHeaderHeight: CGFloat = 34
    /// The page switch: the corner controls' height (30, Medium), chips 22
    /// inside a 4 pt inset.
    static let capsuleHeight: CGFloat = headerControl
    static let capsuleInset: CGFloat = 4
    /// An icon-only chip, 24 tall and 1.15 × as wide (28).
    /// The add bar matches the corner controls (Medium: 30; chrome B 32, was 36).
    /// The owner's panel design: the add field was 30.5 tall (61 px at 2×).
    /// One size (Accepted 2026-10-30): every control in the top row and the
    /// bottom bar is the page switch's 27.
    static let addBarHeight: CGFloat = headerControl
    /// The send button: 24 × 24 (chrome B; 28 × 28 in the 36 pt bar),
    /// nested **inside** the add bar.
    ///
    /// The spec's Raised controls table says "send 36 × 36"; that size came
    /// from mockups where the button sat beside the bar. The owner's polish
    /// rule outranks it: "the send button lives inside the add bar and
    /// appears only when there is text". Inside the 36 pt bar it is nested
    /// `sendInset` (4 pt) from the top, bottom and trailing edges, so it is
    /// 30 − 2 × 4 = 22 pt square (Medium), with the nested radius 12.5 − 4 = 8.5
    /// (corner rule 3: nesting for gaps of 6 pt or less). Kept at 28 × 28
    /// by the owner on 2026-09-24; a test holds the arithmetic.
    static let sendButton = CGSize(width: addBarHeight - 2 * sendInset, height: addBarHeight - 2 * sendInset)
    static let sendInset: CGFloat = 4
    static let smallHeight: CGFloat = 28
    static let smallMinWidth: CGFloat = 32
    static let toastHeight: CGFloat = 36
    static let tagHeight: CGFloat = 18
    /// Minimum hit target for any control (glyphs can be smaller).
    static let minimumHitTarget: CGFloat = 28
    /// How far a control smaller than the minimum target reaches past its
    /// drawn edge on each side, so it still answers a 28 pt target.
    static func hitOutset(for side: CGFloat) -> CGFloat { max(0, (minimumHitTarget - side) / 2) }
    /// 15 pt (control size Medium, owner 2026-10-20; Phase 0's confident
    /// circles were 16). The hit area stays 28.
    static let statusCircle: CGFloat = 15
    /// 13 pt (Medium; it was 14). The hit area stays 28.
    static let subtaskCheckbox: CGFloat = 13
    static let glyph: CGFloat = 14
    /// Icon-only raised buttons: the page switch's icon size (v9), so the
    /// pin and the switch read as one row. Medium: 12.2 (it was 13).
    static let raisedGlyph: CGFloat = 12.2
}

/// Row and panel layout (spec § Proportions and spacing).
enum AtticLayout {
    static let panelSize = CGSize(width: 320, height: 520)
    /// Rows are 36 pt, 52 with a details line (visual A, "Calm"): the
    /// highlight is 2 pt shorter than the pitch (1 pt inset top and bottom).
    /// Owner, 2026-09-26 (compact round, then tighter): 34 pt, 48 with a
    /// second line; highlights 30 / 44, 2 pt clear above and below.
    /// Spacing B, "dense 4/8" (owner, 2026-10-20): 32 pt, pill 28; two-line
    /// rows keep 48 / 44. The clear space between pills stays 2 + 2.
    static let rowPitch: CGFloat = 32
    static let rowHighlightHeight: CGFloat = 28
    static let detailRowPitch: CGFloat = 48
    static let detailRowHighlightHeight: CGFloat = 44
    /// The panel's lines (v9): row highlights 12 from the panel's edges,
    /// status circles (and the page title) at 20, task titles at 46, and
    /// the right-hand meta 20 from the right edge.
    /// Owner, 2026-09-26: the page title lines up with the pin's left edge
    /// (12) and the tasks sit 4 pt in from it: circles at 16, task titles
    /// at 42, highlights 8 from the panel's edges.
    /// Visual A ("Calm"): the page sits 8 inside the panel's 20 pt line, so
    /// highlights are 16 from the panel's edges, circles' visible edge at
    /// 24 (centre 31) and titles at 48: the 20 → 24 → 48 lines.
    static let rowHighlightInset: CGFloat = 8
    /// Owner, 2026-09-26: tasks sit under the page tabs' text — circles at
    /// 31 from the panel edge (23 in the page), titles at 55 (47).
    /// Phase 0's room (2026-09-26, supersedes the two above): the page sits
    /// 12 inside the panel's 24 pt margin, so circles' left edge is at 28
    /// (16 in the page, centre 36) and titles at 56 (44); highlights 20
    /// from the panel's edges; dates 28 from the right.
    /// Spacing B (owner, 2026-10-20): the page sits 8 inside the panel, so
    /// the pill's outer edge (8 into the page) is on the chrome's 16 pt
    /// line, the circles' left edge on the content line at 24, titles 8
    /// after the circle (47 from the panel's edge) and dates 24 from the
    /// right.
    static let circleX: CGFloat = 16
    /// Circle to title (spacing B: 8, it was 12): the same as the pill's
    /// inner padding.
    static let circleToTitle: CGFloat = 8
    static let textX: CGFloat = circleX + AtticControlSize.statusCircle + circleToTitle
    /// The content line, shared by both pages: the Tasks circles and the
    /// tabs' "Now", the note's title and body, and All notes' row text sit
    /// 8 inside the corner controls' line (24 from the panel's edge at the
    /// chrome's 16 pt inset), moving inward with it. Spacing B (owner,
    /// 2026-10-20) moved Tasks from 12 to 8, so the row pill's edge is on
    /// the controls' line itself; Notes followed (owner, 2026-10-21) so the
    /// pages line up when switching.
    static let contentFromChrome: CGFloat = 8
    /// The Tasks page's edge in the panel at a chrome inset (8 at the
    /// default corner): the circles (16 in the page) land on the content
    /// line. The live page and the Appearance preview share it.
    static func tasksPageEdge(chromeInset: CGFloat) -> CGFloat {
        // The owner's panel design (2026-10-27): the rows' highlight 10 from
        // the panel's edge (chrome − 6, 20 px at 2×), so the page edge sits
        // a highlight inset outside it (2 at the default corner).
        max(0, chromeInset - tasksListFromChrome - rowHighlightInset)
    }
    /// The design's list inset, inside the controls' line.
    static let tasksListFromChrome: CGFloat = 6
    /// Settings' sidebar keeps its own highlight inset.
    static let sidebarHighlightInset: CGFloat = 8
    static let subtaskPitch: CGFloat = 28
    /// Subtask text column: checkbox at the row's text column, text after it.

    /// Direction A's page tabs ("Now · Later · Done") in place of the
    /// title: the chip row on the panel's 18 pt line (12 inside the page),
    /// 14 below the header, the list 10 below the chips.
    /// The "Now" label starts on the circles' line (Phase 0's qualities).
    static let pageTabsX: CGFloat = circleX
    /// Visual A: 20 below the header; the list 14 below the tabs (owner, 2026-09-26; the review had 8).
    static let pageTabsTop: CGFloat = 20
    /// The quiet label row's line box (Phase 0's qualities).
    static let pageTabsHeight: CGFloat = 16
    static let pageTabsToList: CGFloat = 14
    /// The least room between the list's last content and the add bar.
    static let contentToAddBar: CGFloat = 16

    static let settingsSidebarWidth: CGFloat = 232
    static let sidebarRowPitch: CGFloat = 32
    static let sidebarHighlightHeight: CGFloat = 30
    static let sidebarIconX: CGFloat = 18
    static let sidebarTextX: CGFloat = 42
    static let groupedRowTall: CGFloat = 57
    static let groupedRowSingle: CGFloat = 40
    static let groupedRowTextInset: CGFloat = 14
    static let chevronTrailingCentre: CGFloat = 24
}

/// Content that scrolls under a floating control or an edge blurs
/// progressively under a veil of the surface (spec § Edge blur).
enum AtticEdgeBlur {
    static let panelTop: CGFloat = 56
    static let panelBottom: CGFloat = 60
    static let settingsBottom: CGFloat = 58
    static let maximumBlur: CGFloat = 6
    static let maximumVeil: Double = 0.65
    /// The veil's ramp from the open edge of the zone (0) to the bar (1):
    /// eased, so the fade has no visible start line.
    static let veilStops: [(location: Double, opacity: Double)] = [
        (0.00, 0.00), (0.30, 0.10), (0.55, 0.30), (0.80, 0.52), (1.00, 0.65)
    ]

    /// The veil's opacity at `depth` into the zone (0 open edge, 1 the bar).
    static func veil(at depth: Double) -> Double {
        let y = min(max(depth, 0), 1)
        for (lower, upper) in zip(veilStops, veilStops.dropFirst()) where y <= upper.location {
            let span = upper.location - lower.location
            return lower.opacity + (upper.opacity - lower.opacity) * (span > 0 ? (y - lower.location) / span : 1)
        }
        return veilStops.last?.opacity ?? 0
    }
}

// MARK: - Type

/// Every text style in the design system. Hierarchy comes from weight and
/// colour more than size (spec § Proportions: two densities, one rhythm).
enum AtticTextStyle: String, CaseIterable, Sendable {
    // Panel
    case noteTitle, panelHeading, body, noteBody, rowTitle, rowMeta, helper, hint
    // Direction A: page tabs, today's date, the priority mark, the
    // "Completed today" line.
    case pageTab, pageTabSelected, rowMetaEmphasis, priorityMark, sectionToggle
    // Phase 0's qualities: an in-progress title (medium) and the list's own
    // 13 pt text (empty states, the add bar, subtasks, the Done search).
    case rowTitleActive, listBody
    // Notes v2: All notes' rows in the note's own SF Pro (a 13 medium
    // title over 11.5 regular meta), so the list and the note read as one.
    case noteRowTitle, noteRowMeta
    // The owner's panel design (2026-10-27, drawn at 2×, in points): a
    // task's 12 medium title, its 11 meta line, the 10 date and tag, the
    // 11 bold priority mark, the 11 group header, the 13 add field.
    case taskTitle, taskMeta, taskDate, taskTag, taskPriority, groupHeader, addField
    case controlLabel, chipLabel, menuRow, shortcut, toast, tag, count, dropLabel
    // Attic's own dropdowns (E1, p2-24 D; Compact size, p2-28): 13 pt
    // names (SF Pro), the date card's month title, its days and its light
    // weekday row.
    // Draft C (owner, 2026-10-23): the month title 13 medium, days 13 with
    // the chosen one medium, weekdays 10 semibold, section headers 11
    // semibold.
    case dropdownRow, dropdownHeading, dropdownDay, dropdownDaySelected, dropdownWeekday, dropdownSection
    // Settings
    case pageTitle, sectionHeading, sidebarHeading, sidebarRow, groupLabel, groupValue
    case settingsHelper, settingsHint, tileLabel, tileLabelSelected, rowSingle

    struct Spec: Equatable {
        let size: CGFloat
        let weight: Font.Weight
        let italic: Bool
        let monospacedDigits: Bool
        /// SF Pro Rounded (Phase 0's task list, owner 2026-09-26).
        var rounded = false
    }

    /// The task list's text is SF Pro Rounded, like Phase 0's: titles, the
    /// second line, dates, the page labels, "Completed today", empty
    /// states and the add bar. The header and Settings stay SF Pro.
    var isListText: Bool {
        switch self {
        case .rowTitle, .rowTitleActive, .rowMeta, .rowMetaEmphasis, .count, .priorityMark,
             .pageTab, .pageTabSelected, .sectionToggle, .listBody: true
        default: false
        }
    }

    /// Note text is SF Pro (Notes v2, text direction 5, owner 2026-10-08;
    /// it was SF Pro Rounded). Tasks keeps its own Rounded voice.

    var spec: Spec {
        let base = baseSpec
        return Spec(size: base.size, weight: base.weight, italic: base.italic, monospacedDigits: base.monospacedDigits,
                    rounded: isListText)
    }

    private var baseSpec: Spec {
        switch self {
        case .noteTitle: Spec(size: AtticNoteType.title.size, weight: .bold, italic: false, monospacedDigits: false)
        case .panelHeading: Spec(size: 13, weight: .semibold, italic: false, monospacedDigits: false)
        case .body, .rowTitle, .listBody, .menuRow, .toast, .sidebarRow: Spec(size: 13, weight: .regular, italic: false, monospacedDigits: false)
        case .rowTitleActive: Spec(size: 13, weight: .medium, italic: false, monospacedDigits: false)
        case .noteRowTitle: Spec(size: 12, weight: .medium, italic: false, monospacedDigits: false)
        case .taskTitle: Spec(size: 12, weight: .medium, italic: false, monospacedDigits: false)
        case .taskMeta, .groupHeader: Spec(size: 11, weight: .regular, italic: false, monospacedDigits: true)
        case .taskDate: Spec(size: 10, weight: .regular, italic: false, monospacedDigits: true)
        case .taskTag: Spec(size: 10, weight: .regular, italic: false, monospacedDigits: false)
        case .taskPriority: Spec(size: 11, weight: .bold, italic: false, monospacedDigits: false)
        case .addField: Spec(size: 13, weight: .regular, italic: false, monospacedDigits: false)
        case .noteRowMeta: Spec(size: 10.5, weight: .regular, italic: false, monospacedDigits: false)
        case .noteBody: Spec(size: AtticNoteType.body.size, weight: .regular, italic: false, monospacedDigits: false)
        case .dropdownRow: Spec(size: 13, weight: .regular, italic: false, monospacedDigits: false)
        case .dropdownHeading: Spec(size: 13, weight: .medium, italic: false, monospacedDigits: false)
        case .dropdownDay: Spec(size: 13, weight: .regular, italic: false, monospacedDigits: true)
        case .dropdownDaySelected: Spec(size: 13, weight: .medium, italic: false, monospacedDigits: true)
        // Draft C: two-letter weekdays, small, semibold, in a light ink.
        case .dropdownWeekday: Spec(size: 10, weight: .semibold, italic: false, monospacedDigits: false)
        case .dropdownSection: Spec(size: 11, weight: .semibold, italic: false, monospacedDigits: false)
        case .rowMeta, .helper: Spec(size: 11.5, weight: .regular, italic: false, monospacedDigits: false)
        case .count: Spec(size: 11.5, weight: .regular, italic: false, monospacedDigits: true)
        case .rowMetaEmphasis: Spec(size: 11.5, weight: .medium, italic: false, monospacedDigits: false)
        case .priorityMark: Spec(size: 11, weight: .bold, italic: false, monospacedDigits: false)
        // Quiet labels, 11.5 medium; the selected page semibold, so the
        // selection reads on glass where the two greys are close (owner,
        // 2026-09-27).
        case .pageTab: Spec(size: 11.5, weight: .medium, italic: false, monospacedDigits: false)
        case .sectionToggle: Spec(size: 11.5, weight: .regular, italic: false, monospacedDigits: false)
        case .pageTabSelected: Spec(size: 11.5, weight: .semibold, italic: false, monospacedDigits: false)
        case .hint: Spec(size: 12.5, weight: .regular, italic: true, monospacedDigits: false)
        case .controlLabel: Spec(size: 12.5, weight: .medium, italic: false, monospacedDigits: false)
        case .chipLabel: Spec(size: 12, weight: .medium, italic: false, monospacedDigits: false)
        case .shortcut: Spec(size: 12, weight: .regular, italic: false, monospacedDigits: false)
        case .tag: Spec(size: 11.5, weight: .medium, italic: false, monospacedDigits: false)
        case .dropLabel: Spec(size: 11.5, weight: .medium, italic: false, monospacedDigits: false)
        case .pageTitle: Spec(size: 16, weight: .bold, italic: false, monospacedDigits: false)
        case .sectionHeading: Spec(size: 14, weight: .bold, italic: false, monospacedDigits: false)
        case .sidebarHeading: Spec(size: 13.5, weight: .bold, italic: false, monospacedDigits: false)
        case .groupLabel: Spec(size: 12, weight: .medium, italic: false, monospacedDigits: false)
        case .groupValue: Spec(size: 13.5, weight: .regular, italic: false, monospacedDigits: false)
        case .rowSingle: Spec(size: 13.5, weight: .regular, italic: false, monospacedDigits: false)
        case .settingsHelper: Spec(size: 12.5, weight: .regular, italic: false, monospacedDigits: false)
        case .settingsHint: Spec(size: 12.5, weight: .regular, italic: true, monospacedDigits: false)
        case .tileLabel: Spec(size: 13, weight: .regular, italic: false, monospacedDigits: false)
        case .tileLabelSelected: Spec(size: 13, weight: .medium, italic: false, monospacedDigits: false)
        }
    }

    var font: Font {
        var font = Font.system(size: spec.size, weight: spec.weight, design: spec.rounded ? .rounded : .default)
        if spec.italic { font = font.italic() }
        if spec.monospacedDigits { font = font.monospacedDigit() }
        return font
    }

    /// The AppKit font this style draws with (for measuring text).
    var nsFont: NSFont {
        let weight: NSFont.Weight = switch spec.weight {
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        default: .regular
        }
        var font = NSFont.systemFont(ofSize: spec.size, weight: weight)
        if spec.rounded, let rounded = font.fontDescriptor.withDesign(.rounded) {
            font = NSFont(descriptor: rounded, size: spec.size) ?? font
        }
        if spec.italic {
            font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: spec.size) ?? font
        }
        return font
    }

    /// The width a single line of `string` takes in this style, rounded up
    /// to the whole point (layout that reserves room for text uses it).
    func measuredWidth(_ string: String) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: nsFont]).width.rounded(.up)
    }

    /// Text on the rows of this style is a label, which never wraps. Only
    /// Settings helper text may wrap (to at most three lines).
    var mayWrap: Bool { self == .settingsHelper }
}

// MARK: - Motion

/// The one motion scale (Astra A4 §6, adopted 2026-10-11): three durations
/// and two curves, so the same kind of motion takes the same time on every
/// page. A feel (Lively, Subtle) only changes the spring's bounce.
///
/// - F, `fast` (120 ms): hover and focus, every exit and dismissal, and the
///   Reduced fade.
/// - M, `standard` (200 ms): things that appear (search, dropdowns and
///   pop-overs, notices, the status pill, completion feedback, toasts).
/// - L, `spatial` (280 ms): navigation, expansion, the Aa row's geometry,
///   a drag settling, the panel.
///
/// Curves: S, the feel's spring at one of those durations (positions and
/// geometry, which must reverse from where they are), and E, an ease-out
/// cubic (.2, .8, .2, 1) for opacity, the dropdown's reveal and exits.
///
/// Reduced (Settings › Animations › Reduced or macOS Reduce Motion), one
/// policy everywhere: no scaling, sliding or geometry interpolation; a
/// F/E fade where a fade helps, an instant change for pages, expansion and
/// the Aa row.
enum AtticMotionScale {
    static let fast: Double = 0.12
    static let standard: Double = 0.20
    static let spatial: Double = 0.28
    static let durations: [Double] = [fast, standard, spatial]

    /// E's control points (for Core Animation and AppKit callers).
    static let easeOutControlPoints: (Float, Float, Float, Float) = (0.2, 0.8, 0.2, 1)

    /// E: the ease-out curve at `duration`.
    static func easeOut(_ duration: Double) -> Animation {
        .timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
    }

    /// The exit: F/E, in every feel.
    static var exit: Animation { easeOut(fast) }

    /// Reduced's fade: F/E.
    static var reducedFade: Animation { easeOut(fast) }

    /// E as a Core Animation timing function (the Find bar, the table's
    /// scroll indicator).
    static var easeOutTimingFunction: CAMediaTimingFunction {
        let p = easeOutControlPoints
        return CAMediaTimingFunction(controlPoints: p.0, p.1, p.2, p.3)
    }

    /// The small overlays' recipe (notices, the status pill, the selection
    /// bar, the format row): a 4 pt rise (spec) and a 0.96 grow from the
    /// edge they come from, M/S in, F/E out by opacity only. Reduced: the
    /// F/E fade.
    static let overlayRise: CGFloat = 4
    static let overlayScale: CGFloat = 0.96

    static func overlayTransition(reduceMotion: Bool, from edge: VerticalEdge) -> AnyTransition {
        if reduceMotion { return .opacity.animation(reducedFade) }
        let insertion = AnyTransition.opacity
            .combined(with: .offset(y: edge == .bottom ? overlayRise : -overlayRise))
            .combined(with: .scale(scale: overlayScale, anchor: edge == .bottom ? .bottom : .top))
        return .asymmetric(insertion: insertion, removal: .opacity.animation(exit))
    }

    /// The overlays' animation while showing: M/S (the Reduced fade).
    static func overlayAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? reducedFade : AtticMotionPreset.popover.animation(reduceMotion: false)
    }
}

/// The search takeover, one recipe for Tasks and All notes (A4 M-01; the
/// owner: Notes' search must move exactly as Tasks' does): the field comes
/// in from the magnifier's end, 12 pt, growing from the feel's appear scale
/// (M/S); the tabs or the notes' heading leave toward the other end. It
/// ends at once (F/E), so the field lets the keyboard go. Reduced: the F/E
/// fade.
enum AtticSearchMotion {
    static let travel: CGFloat = 12

    static func field(reduceMotion: Bool) -> AnyTransition {
        AtticMotionPreset.popover.transition(reduceMotion: reduceMotion, edge: .trailing, distance: travel)
    }

    static func labels(reduceMotion: Bool) -> AnyTransition {
        AtticMotionPreset.popover.transition(reduceMotion: reduceMotion, edge: .leading, distance: travel)
    }

    static func animation(shown: Bool, reduceMotion: Bool) -> Animation? {
        shown ? AtticMotionPreset.popover.animation(reduceMotion: reduceMotion)
              : AtticMotionPreset.popover.leaveAnimation(reduceMotion: reduceMotion)
    }
}

/// The small set of interruptible springs every animation comes from
/// (spec § Motion). A SwiftUI spring retargets from its current value and
/// velocity when it is interrupted, so each one reverses from where it is.
/// Only transforms (position, scale) and opacity animate; `reduceMotion`
/// swaps in the fallback.
///
/// Settings › Animations selects Lively (default) or Subtle. Reduced and
/// macOS Reduce Motion swap every preset for its existing fallback.
enum AtticMotionPreset: String, CaseIterable, Sendable {
    /// Switch page: the feel's navigation spring (as `slide`), every time,
    /// the pages travelling sideways as they crossfade (`PanelPageMotion`).
    /// Reduce Motion: instant.
    case pageSwitch
    /// Now, Backlog and Done; note and All notes: a firm slide. RM: crossfade.
    case slide
    /// Task done: the wedge sweeps to a full disc, then the check draws
    /// (springs, so they reverse smoothly). RM: fade.
    case complete
    /// The done row slides to the done group after about a second.
    case doneSlide
    /// Card or quick-look expand. RM: instant.
    case expand
    /// Menus, selection bar, pop-overs, the strip, the Done search: they
    /// spring in from their anchor (or fade and rise, in the fade style).
    /// RM: fade.
    case popover
    /// Undo toast: springs up. RM: fade.
    case toast
    /// A dropped item settles into place; rows added, moved or completed.
    case settle
    /// A failed drop animates back to where it came from.
    case failReturn
    /// Hover and press feedback.
    case hover

    /// The spring this preset uses under `tuning`. Hover feedback is the
    /// same in every feel; a page switch is navigation, so it takes the
    /// feel's slide (A20: it was a 180 ms crossfade whatever the feel).
    func spring(in tuning: AtticMotionTuning) -> AtticMotionSpring {
        switch self {
        case .hover: AtticMotionSpring(response: AtticMotionScale.fast, bounce: 0)
        case .slide, .pageSwitch: tuning.slide
        case .expand: tuning.expand
        case .doneSlide: tuning.doneSlide
        case .popover: tuning.popover
        case .toast: tuning.toast
        case .complete: tuning.complete
        case .settle: tuning.settle
        case .failReturn: tuning.failReturn
        }
    }

    /// Duration of the spring's main motion (SwiftUI's perceptual
    /// duration), in seconds, in the current feel.
    var duration: Double { spring(in: .current).response }

    /// How much the spring bounces (SwiftUI's `bounce`: 0 is critically
    /// damped, 0.3 is `.bouncy`), in the current feel.
    var bounce: Double { spring(in: .current).bounce }

    enum ReducedMotion: Equatable { case instant, fade }

    var reducedMotion: ReducedMotion {
        switch self {
        case .pageSwitch, .expand: .instant
        default: .fade
        }
    }

    /// Rise distance for fade-and-rise presets (a row added or removed
    /// rises into or out of its place by `settle`'s).
    var rise: CGFloat {
        switch self {
        case .popover, .toast, .settle: AtticMotionScale.overlayRise
        default: 0
        }
    }

    /// How much of the feel's appear and leave scale this preset takes:
    /// all of it for the things that pop in (pop-overs, the strip, bars,
    /// the toast), a part for rows and the quick look (a row's text should
    /// not visibly zoom). Whole pages never scale: they hold the lists'
    /// AppKit scroll views, which a SwiftUI transform does not carry (the
    /// round 9 lesson), so a page switch stays a crossfade. The slides
    /// never scale either.
    var scaleWeight: Double {
        switch self {
        case .popover, .toast, .complete: 1
        case .expand: 0.5
        case .settle: 0.4
        case .pageSwitch, .slide, .doneSlide, .failReturn, .hover: 0
        }
    }

    /// The animation to use, or nil for an instant change: the feel's
    /// spring at the preset's duration on the scale (hover: F/E). Notes no
    /// longer has a slower spring of its own (A4 M-02).
    func animation(reduceMotion: Bool) -> Animation? {
        if reduceMotion { return reducedAnimation }
        if self == .hover { return AtticMotionScale.easeOut(AtticMotionScale.fast) }
        let spring = spring(in: .current)
        return .spring(duration: spring.response, bounce: spring.bounce)
    }

    /// Reduced's fallback, the same in every feel: the F/E fade, or an
    /// instant change for a page switch and an expansion.
    private var reducedAnimation: Animation? {
        switch reducedMotion {
        case .instant: nil
        case .fade: AtticMotionScale.reducedFade
        }
    }

    /// Something leaving: F/E in every feel (exits fade; they never
    /// bounce). Reduced: the fallback.
    func leaveAnimation(reduceMotion: Bool) -> Animation? {
        if reduceMotion { return reducedAnimation }
        return AtticMotionScale.exit
    }

    /// `animation` while something shows, `leaveAnimation` while it goes.
    func animation(reduceMotion: Bool, showing: Bool) -> Animation? {
        showing ? animation(reduceMotion: reduceMotion) : leaveAnimation(reduceMotion: reduceMotion)
    }

    /// Spring in from the anchor and tuck away with the selected recipe.
    /// Reduce Motion uses opacity only.
    func transition(reduceMotion: Bool, edge: Edge? = .bottom, anchor: UnitPoint? = nil,
                    distance: CGFloat? = nil) -> AnyTransition {
        if reduceMotion { return .opacity }
        let travel = distance ?? rise
        let fade = move(edge, by: travel, doublesSideways: distance == nil)
        let tuning = AtticMotionTuning.current
        guard scaleWeight > 0 else { return fade }
        let anchor = anchor ?? edge.map(Self.anchor(for:)) ?? .center
        let insertion = fade.combined(with: .scale(scale: scale(from: tuning.appearScale), anchor: anchor))
        let removal = move(edge, by: travel / 2, doublesSideways: distance == nil)
            .combined(with: .scale(scale: scale(from: tuning.leaveScale), anchor: anchor))
        return .asymmetric(insertion: insertion, removal: removal)
    }

    /// The scale something shown and hidden in place (not inserted: the
    /// strip, the add bar's send button) takes while hidden: the appear
    /// scale in the selected recipe, or 1 under Reduce Motion.
    func hiddenScale(reduceMotion: Bool) -> CGFloat {
        let tuning = AtticMotionTuning.current
        guard !reduceMotion else { return 1 }
        return scale(from: tuning.appearScale)
    }

    /// The feel's scale, weighted for this preset.
    private func scale(from feelScale: Double) -> CGFloat {
        CGFloat(1 - (1 - feelScale) * scaleWeight)
    }

    private func move(_ edge: Edge?, by distance: CGFloat, doublesSideways: Bool = true) -> AnyTransition {
        guard let edge, distance > 0 else { return .opacity }
        let sideways = doublesSideways ? distance * 2 : distance
        switch edge {
        case .bottom: return .opacity.combined(with: .offset(y: distance))
        case .top: return .opacity.combined(with: .offset(y: -distance))
        case .leading: return .opacity.combined(with: .offset(x: -sideways))
        case .trailing: return .opacity.combined(with: .offset(x: sideways))
        }
    }

    /// Where something that comes from `edge` grows from.
    static func anchor(for edge: Edge) -> UnitPoint {
        switch edge {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    /// How long the finished state holds before `doneSlide` (spec: about 1 s).
    static let doneHold: Double = 1.0
    /// How long the Undo toast stays (spec: 6 s).
    static let toastHold: Double = 6.0
}

/// One spring: SwiftUI's perceptual duration (`response`, seconds) and
/// `bounce` (0 critically damped, 0.3 `.bouncy`).
struct AtticMotionSpring: Hashable, Codable, Sendable {
    var response: Double
    var bounce: Double
}

/// Values for the selected Lively or Subtle recipe. Navigation is the slide
/// (and the Tasks pager's own settle), the quick look and the done row's
/// slide; the things that appear are the pop-overs, the strip, the bars,
/// the Done search, the toast, a completion and the rows that settle.
struct AtticMotionTuning: Hashable, Codable, Sendable {
    // Navigation.
    var slide: AtticMotionSpring
    var expand: AtticMotionSpring
    var doneSlide: AtticMotionSpring
    // Things that appear.
    var popover: AtticMotionSpring
    var toast: AtticMotionSpring
    var complete: AtticMotionSpring
    var settle: AtticMotionSpring
    var failReturn: AtticMotionSpring
    /// The scale the things that appear start from (1: none).
    var appearScale: Double
    /// The leave style's tuck: its response and the scale it tucks to.
    var leaveResponse: Double
    var leaveScale: Double
    /// Native pop-overs (the pickers, the date and tag pop-overs) spring
    /// in from their arrow as well as the system's own fade. Experimental:
    /// off in every feel until the owner has seen it.
    var popsNativePopovers = false

    /// The current tuning. Written only on the main thread, by
    /// `AppSettings` (Animations and the native-popover experiment); read wherever
    /// an animation is made, off the main actor too, like the presets.
    nonisolated(unsafe) static var current: AtticMotionTuning = AtticMotionFeel.recommended.tuning
}

/// The two spring recipes used by Settings › Animations.
enum AtticMotionFeel: String, CaseIterable, Sendable {
    case subtle
    case lively
    static let recommended: AtticMotionFeel = .lively

    var tuning: AtticMotionTuning {
        switch self {
        case .subtle: .subtle
        case .lively: .lively
        }
    }
}

extension AtticMotionTuning {
    /// Every feel on the one scale (`AtticMotionScale`): navigation, the
    /// quick look, the done row's slide, settling and a failed drop's
    /// return take L (280 ms); pop-overs, toasts and completions take M
    /// (200 ms). Feels differ only in bounce and in how much things grow.
    private static func scaled(bounce: Double, appearScale: Double, leaveScale: Double) -> AtticMotionTuning {
        let spatial = AtticMotionSpring(response: AtticMotionScale.spatial, bounce: bounce)
        let standard = AtticMotionSpring(response: AtticMotionScale.standard, bounce: bounce)
        return AtticMotionTuning(
            slide: spatial, expand: spatial, doneSlide: spatial,
            popover: standard, toast: standard, complete: standard, settle: spatial, failReturn: spatial,
            appearScale: appearScale, leaveResponse: AtticMotionScale.fast, leaveScale: leaveScale
        )
    }

    /// Bounce 0.04, growing from 0.96 of their size.
    static let subtle = scaled(bounce: 0.04, appearScale: 0.96, leaveScale: 0.98)

    /// The default: bounce 0.12, growing from 0.92 of their size.
    static let lively = scaled(bounce: 0.12, appearScale: 0.92, leaveScale: 0.96)

}

/// Whether this preview may show blur tuning and the native-popover experiment.
/// Never under the release identity.
enum AtticMotionLab {
    static let officialBundleIdentifier = "com.taha.Attic"
    static let previewPrefix = "com.taha.Attic.preview."
    static let argument = "--attic-motion-lab"

    /// A `com.taha.Attic.preview.*` build, or another non-release Attic
    /// identity launched with `--attic-motion-lab`.
    static func isAvailable(bundleIdentifier: String?, arguments: [String]) -> Bool {
        guard let bundleIdentifier, bundleIdentifier != officialBundleIdentifier else { return false }
        if bundleIdentifier.hasPrefix(previewPrefix), bundleIdentifier.count > previewPrefix.count { return true }
        return bundleIdentifier.hasPrefix(officialBundleIdentifier + ".") && arguments.contains(argument)
    }

    static let isAvailable = isAvailable(bundleIdentifier: Bundle.main.bundleIdentifier,
                                         arguments: ProcessInfo.processInfo.arguments)
}

/// Settings › General › Animations: Lively (the default), Subtle, or
/// Reduced, every preset's Reduce Motion fallback (crossfades or instant
/// changes, no travel), as macOS Reduce Motion gives. macOS Reduce Motion
/// forces Reduced whatever is chosen.
enum AtticAnimationLevel: String, CaseIterable, Sendable {
    case lively
    case subtle
    case reduced

    var title: String {
        switch self {
        case .lively: String(localized: "Lively")
        case .subtle: String(localized: "Subtle")
        case .reduced: String(localized: "Reduced")
        }
    }

    /// The spring values this level uses. Reduced never reads them (every
    /// preset takes its fallback), so it carries Subtle's.
    var feel: AtticMotionFeel {
        switch self {
        case .lively: .lively
        case .subtle, .reduced: .subtle
        }
    }

    /// Whether motion is reduced: this level is Reduced, or macOS Reduce
    /// Motion is on, which forces Reduced whatever is chosen.
    func reducesMotion(systemReduceMotion: Bool) -> Bool {
        systemReduceMotion || self == .reduced
    }

    /// The level stored by an earlier build: "full" (the springs) is now
    /// Lively, and "reduced" is still Reduced. Anything else is the default.
    static func migrated(from stored: String?) -> AtticAnimationLevel {
        guard let stored else { return .lively }
        if stored == "full" { return .lively }
        return AtticAnimationLevel(rawValue: stored) ?? .lively
    }
}

/// The Animations choice for code that runs outside a view (a model's
/// `withAnimation`, the panel's AppKit motion) and so cannot read
/// `design.reduceMotion`. `AppSettings` keeps `level` current.
@MainActor
enum AtticMotionPreference {
    static var level: AtticAnimationLevel = .lively

    /// Reduced in Settings, or Reduce Motion on in macOS.
    static var reducesMotion: Bool {
        #if DEBUG
        let system = systemReduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        let system = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #endif
        return level.reducesMotion(systemReduceMotion: system)
    }

    #if DEBUG
    /// Tests only: stands in for macOS Reduce Motion, which GitHub's macOS
    /// runner images turn on (`configure-system.sh`), so panel-motion tests
    /// can state the setting they test instead of inheriting the machine's.
    static var systemReduceMotionOverride: Bool?
    #endif
}

// MARK: - Touch

/// The haptic tick: a light tap when a task is completed and when a dragged
/// item snaps into place. Nothing else plays haptics, and nothing plays sound.
enum AtticHaptics {
    @MainActor
    static func tick(enabled: Bool = true) {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

// MARK: - Task vocabulary

/// The four states the status circle shows (spec § The status circle). The
/// design system keeps its own small types so it never depends on how the
/// store models tasks; Phase 1 maps `TaskStatus` onto these.
enum AtticTaskState: String, CaseIterable, Sendable {
    case todo, inProgress, done, backlog

    var spokenName: String {
        switch self {
        case .todo: String(localized: "to do")
        case .inProgress: String(localized: "in progress")
        case .done: String(localized: "done")
        case .backlog: String(localized: "later")
        }
    }
}

/// Priority is a mark after the title (Direction A): High "!!" in the
/// orange mark ink, Medium "!" in the secondary grey, Low and None nothing;
/// every open ring is the same grey. VoiceOver reads it with the task.
enum AtticPriority: String, CaseIterable, Sendable {
    case none, low, medium, high

    var spokenName: String? {
        switch self {
        case .none: nil
        case .low: String(localized: "low priority")
        case .medium: String(localized: "medium priority")
        case .high: String(localized: "high priority")
        }
    }
}
