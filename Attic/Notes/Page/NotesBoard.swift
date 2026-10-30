import AppKit
import SwiftUI

/// The notes list's two layouts (Accepted 2026-10-30, "Notes board"): one
/// flowing two-column board of cards, or the list with its sections. Kept
/// per user in the identity's own defaults; the design starts on the list.
enum NotesLibraryLayout: String, CaseIterable, Identifiable, Sendable {
    case board, list

    static let `default`: Self = .list
    static let defaultsKey = "notes.library.layout"

    var id: Self { self }

    init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? .default
    }

    var title: String {
        switch self {
        case .board: String(localized: "Board")
        case .list: String(localized: "List")
        }
    }
}

/// The board's sizes, in points (the design is drawn at 2×: px ÷ 2).
enum NotesBoardMetrics {
    static let columns = 2
    /// 12 px between the columns, between the cards, and above the board.
    static let columnGap: CGFloat = 6
    static let cardGap: CGFloat = 6
    static let topPadding: CGFloat = 6
    /// Shapes: cards are 36 px, on the surface squircle.
    static let radius: CGFloat = AtticRadius.card
    static let cornerExponent: CGFloat = AtticShape.surfaceExponent
    /// Padding 16 18 15 18 px; the card's lines 6 px apart.
    static let padding = EdgeInsets(top: 8, leading: 9, bottom: 7.5, trailing: 9)
    static let lineGap: CGFloat = 3
    /// The title: 22 px, weight 600, on a 28 px line, up to three lines.
    static let titleSize: CGFloat = 11
    static let titleLine: CGFloat = 14
    static let titleLines = 3
    /// The snippet: 19 px on a 26 px line, up to six lines.
    static let snippetSize: CGFloat = 9.5
    static let snippetLine: CGFloat = 13
    static let snippetLines = 6
    /// The time and #tag: 16 px on a 20 px line, 8 px apart, 4 px lower.
    static let metaSize: CGFloat = 8
    static let metaLine: CGFloat = 10
    static let metaGap: CGFloat = 4
    static let metaTop: CGFloat = 2
    /// The small grey pin: 13 × 19 px, 5 px down, 8 px after the title.
    static let pinSize = CGSize(width: 6.5, height: 9.5)
    static let pinTop: CGFloat = 2.5
    static let titleGap: CGFloat = 4
    /// "•••": a 32 px square on curve 1.4, pulled 2 px up and 4 px right.
    static let actionsSide: CGFloat = 16
    static let actionsOutset = CGSize(width: 2, height: 1)
    static let actionsGlyphSize: CGFloat = 12.5
    /// Images: a striped block 112 px tall (150 from three images), its
    /// lower corners 6 px; the count 15 px, 8 × 12 px in.
    static let imageHeight: CGFloat = 56
    static let tallImageHeight: CGFloat = 75
    static let imageBottomRadius: CGFloat = 3
    static let imageLabelSize: CGFloat = 7.5
    static let imageLabelPadding = EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
    static let stripe: CGFloat = 4

    /// The extra leading that puts `size` on a `line` tall line.
    static func lineSpacing(size: CGFloat, weight: NSFont.Weight = .regular, line: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return max(0, line - (font.ascender - font.descender + font.leading))
    }
}

/// Where each card goes (the design's board): every card to the shorter
/// column, ties to the left, by a height estimated from the note's content
/// alone. Never from measured layout: a layout that measures its cards and
/// writes the heights back is the feedback loop that froze this panel once.
enum NotesBoardLayout {
    /// The design's characters per line at its card width.
    static let titleCharacters = 17
    static let snippetCharacters = 22

    /// The design's estimate, halved: images, the title's lines (at least
    /// one, at most three), the snippet's (at most six), and the padding
    /// and meta line.
    static func estimatedHeight(titleLength: Int, snippetLength: Int, images: Int) -> CGFloat {
        typealias M = NotesBoardMetrics
        func lines(_ length: Int, per: Int, max: Int) -> Int { Swift.min(max, (length + per - 1) / per) }
        let image: CGFloat = images <= 0 ? 0 : (images >= 3 ? M.tallImageHeight : M.imageHeight)
        let title = M.titleLine * CGFloat(Swift.max(1, lines(titleLength, per: titleCharacters, max: M.titleLines)))
        let snippet = snippetLength > 0
            ? M.lineGap + M.snippetLine * CGFloat(lines(snippetLength, per: snippetCharacters, max: M.snippetLines)) : 0
        return image + title + snippet + 33.5
    }

    /// The column of each card, in order.
    static func columns(heights: [CGFloat], count: Int = NotesBoardMetrics.columns) -> [Int] {
        var totals = [CGFloat](repeating: 0, count: max(1, count))
        return heights.map { height in
            var shortest = 0
            for index in totals.indices where totals[index] < totals[shortest] { shortest = index }
            totals[shortest] += height + NotesBoardMetrics.cardGap
            return shortest
        }
    }
}

/// A board card (the design's draft 1): an image block when the note has
/// images, the title (up to three lines) with a small grey pin when pinned,
/// the snippet (up to six lines; a long link wraps), then the time and the
/// first #tag. On the raised surface, a squircle. Hover, the keyboard's
/// card or a focused "•••" show "•••", which opens the row's short menu.
struct NotesBoardCard: View {
    let details: NotesLibraryModel.RowDetails
    let pinned: Bool
    var isSelected = false
    var isHighlighted = false
    let commands: () -> [AtticMenuCommand]
    let anchors: AtticNoteRowAnchors
    let onShowActions: () -> Void
    let onOpen: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @Environment(\.atticTagColouring) private var colouring
    @State private var hovered = false
    @State private var actionsHovered = false
    @FocusState private var actionsFocused: Bool

    private typealias M = NotesBoardMetrics

    #if DEBUG
    /// Test seam: how many times a card's body has run.
    static var bodyEvaluations = 0
    #endif

    private var row: AtticNoteRowModel { details.row }

    var body: some View {
        #if DEBUG
        let _ = Self.bodyEvaluations += 1
        #endif
        let hover = forced == .hover || hovered
        let showsActions = hover || isHighlighted || actionsFocused
        let shape = Squircle(cornerRadius: M.radius, exponent: M.cornerExponent)
        openButton(shape: shape, hover: hover)
            .overlay(alignment: .topTrailing) { actionsButton(shown: showsActions) }
            .onHover { hovered = $0 }
    }

    private func openButton(shape: Squircle, hover: Bool) -> some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                if row.images > 0 { imageBlock }
                VStack(alignment: .leading, spacing: M.lineGap) {
                    titleLine
                    if !row.preview.isEmpty { snippet }
                    metaLine.padding(.top, M.metaTop)
                }
                .padding(M.padding)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(shape)
            .background { surface(shape: shape, hover: hover) }
            .contentShape(shape)
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pinned ? String(localized: "Pinned, \(row.spoken)") : row.spoken)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("notes-board-card")
        .accessibilityActions {
            ForEach(AtticNoteRow.spokenActions(commands())) { command in
                Button(command.title, action: command.action)
            }
        }
    }

    /// The raised surface (glass where the controls are glass), the hover
    /// on it, and the selected or keyboard card's fill.
    private func surface(shape: Squircle, hover: Bool) -> some View {
        Color.clear
            .atticRaisedMaterial(cornerRadius: M.radius, state: hover ? .hover : .rest, interactive: false)
            .environment(\.atticControlCornerExponent, M.cornerExponent)
            .overlay {
                if isSelected || isHighlighted { shape.fill(design.tokens.selected.color) }
            }
            .allowsHitTesting(false)
    }

    private var titleLine: some View {
        HStack(alignment: .top, spacing: M.titleGap) {
            Text(verbatim: row.title)
                .font(.system(size: M.titleSize, weight: .semibold))
                .lineSpacing(M.lineSpacing(size: M.titleSize, weight: .semibold, line: M.titleLine))
                .lineLimit(M.titleLines)
                .foregroundStyle(design.tokens.ink(.heading).color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if pinned {
                NotesBoardPin()
                    .fill(TasksPanelDesign.toneInk(.meta, tokens: design.tokens).color)
                    .frame(width: M.pinSize.width, height: M.pinSize.height)
                    .padding(.top, M.pinTop)
                    .accessibilityHidden(true)
            }
            // "•••"'s room, kept at rest too, so hover never re-wraps the
            // title (and moves the cards under it).
            Color.clear.frame(width: M.actionsSide - M.actionsOutset.width, height: 1)
        }
    }

    private var snippet: some View {
        Text(verbatim: row.preview)
            .font(.system(size: M.snippetSize))
            .lineSpacing(M.lineSpacing(size: M.snippetSize, line: M.snippetLine))
            .lineLimit(M.snippetLines)
            .foregroundStyle(TasksPanelDesign.toneInk(.date, tokens: design.tokens).color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The time and the first #tag, in the design's grey (see-through on
    /// glass) and the tag's own colour; a not-saved or proposal mark first.
    private var metaLine: some View {
        let tokens = design.tokens
        return HStack(spacing: M.metaGap) {
            if row.needsAttention {
                AtticIcon(systemName: "exclamationmark.circle", size: M.metaSize, weight: .medium, ink: .warningText)
            } else if row.hasProposal {
                AtticIcon(systemName: "sparkle", size: M.metaSize, ink: .helper)
            }
            Text(verbatim: row.time)
                .foregroundStyle(TasksPanelDesign.toneInk(.meta, tokens: tokens).color)
                .fixedSize()
            if let tag = details.tag {
                Text(verbatim: "#" + tag)
                    .foregroundStyle(tagInk(tag, tokens: tokens))
                    .lineLimit(1)
            }
        }
        .font(.system(size: M.metaSize).monospacedDigit())
        .frame(height: M.metaLine)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tagInk(_ tag: String, tokens: AtticColorTokens) -> Color {
        let text = TasksPanelDesign.tagColours(hue: TasksPanelDesign.oklchHue(for: colouring.hue(for: tag)),
                                               dark: design.mode == .dark).text
        return TasksPanelDesign.vivid(text, tokens: tokens).color
    }

    /// The design's stand-in for the note's images: a striped block with
    /// the count, as the list's thumbnails draw them.
    private var imageBlock: some View {
        let ink = design.tokens.ink(.heading)
        return ZStack(alignment: .bottomTrailing) {
            Canvas { context, size in
                let band = M.stripe
                var index = 0
                var x = -size.height
                while x < size.width + size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x + band, y: 0))
                    path.addLine(to: CGPoint(x: x + band + size.height, y: size.height))
                    path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                    path.closeSubpath()
                    context.fill(path, with: .color(ink.withAlpha(index.isMultiple(of: 2) ? 0.035 : 0.07).color))
                    x += band
                    index += 1
                }
            }
            Text(verbatim: row.images == 1 ? String(localized: "1 image") : String(localized: "\(row.images) images"))
                .font(.system(size: M.imageLabelSize).monospacedDigit())
                .foregroundStyle(TasksPanelDesign.toneInk(.date, tokens: design.tokens).color)
                .padding(M.imageLabelPadding)
        }
        .frame(maxWidth: .infinity)
        .frame(height: row.images >= 3 ? M.tallImageHeight : M.imageHeight)
        .clipShape(Squircle(cornerRadius: M.imageBottomRadius, exponent: M.cornerExponent))
    }

    private func actionsButton(shown: Bool) -> some View {
        let radius = AtticShape.controlRadius(height: M.actionsSide)
        return Button(action: onShowActions) {
            AtticIcon(systemName: "ellipsis", size: M.actionsGlyphSize, weight: .medium, ink: .icon)
                .frame(width: M.actionsSide, height: M.actionsSide)
                .background {
                    if actionsHovered {
                        AtticControlShape.shape(cornerRadius: radius, exponent: AtticShape.controlExponent)
                            .fill(design.tokens.hover.color)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .focused($actionsFocused)
        .atticOwnFocusRing(.rounded(radius: radius, height: M.actionsSide))
        .background { AtticNoteRowAnchor(id: row.id, anchors: anchors) }
        .onHover { actionsHovered = $0 }
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .padding(.top, M.padding.top + (row.images > 0 ? (row.images >= 3 ? M.tallImageHeight : M.imageHeight) : 0)
                 + (M.titleLine - M.actionsSide) / 2)
        .padding(.trailing, M.padding.trailing - M.actionsOutset.width)
        .help(String(localized: "Note actions (⇧⌘I)"))
        .accessibilityLabel(String(localized: "Actions for \(row.title)"))
        .accessibilityIdentifier("notes-row-actions")
    }
}

/// The design's small pin (13 × 19 px): the head, the collar and the point.
struct NotesBoardPin: Shape {
    func path(in rect: CGRect) -> Path {
        // The design's 17.286 × 26.5 drawing, scaled to the rect.
        let sx = rect.width / 17.286, sy = rect.height / 26.5
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        path.move(to: p(3.4, 0))
        path.addLine(to: p(13.886, 0))
        path.addLine(to: p(14.786, 2))
        path.addLine(to: p(12.6, 4.4))
        path.addLine(to: p(12.6, 9.7))
        path.addQuadCurve(to: p(17.286, 15.8), control: p(16.9, 11.8))
        path.addLine(to: p(16.486, 16.7))
        path.addLine(to: p(0.8, 16.7))
        path.addLine(to: p(0, 15.8))
        path.addQuadCurve(to: p(4.686, 9.7), control: p(0.4, 11.8))
        path.addLine(to: p(4.686, 4.4))
        path.addLine(to: p(2.5, 2))
        path.closeSubpath()
        path.addRoundedRect(in: CGRect(origin: p(7.643, 16.7), size: CGSize(width: 2 * sx, height: 9.8 * sy)),
                            cornerSize: CGSize(width: sx, height: sx))
        return path
    }
}

// MARK: - The board | list switch

/// The switch's sizes: the top row's 27 pt glass with two 21 pt cells,
/// 1 pt apart, in its 3 pt inset (as Now · Later · Done).
enum NotesLayoutSwitchMetrics {
    static let inset: CGFloat = AtticPageButtonMetrics.inset
    static let cell: CGFloat = AtticPageButtonMetrics.segment
    static let gap: CGFloat = 1
    /// The design's 22 px glyphs.
    static let glyph: CGFloat = 11

    static func markerOffset(index: Int) -> CGFloat { CGFloat(index) * (cell + gap) }

    static var width: CGFloat {
        let count = CGFloat(NotesLibraryLayout.allCases.count)
        return inset * 2 + count * cell + (count - 1) * gap
    }
}

/// Board | list on the top row's page-switch slot (Accepted 2026-10-30,
/// "Notes board"), shown only on the notes list: the current one on the
/// flat grey marker, its glyph in the primary ink and the other grey.
/// ←/→ move between them; VoiceOver reads each by name.
struct NotesLayoutSwitch: View {
    @Binding var selection: NotesLibraryLayout

    @Environment(\.atticDesign) private var design
    @Environment(\.atticCapture) private var capture
    @Environment(\.atticKeyboardFocusVisible) private var keyboardFocusVisible
    @FocusState private var focused: Bool
    @State private var hovered: NotesLibraryLayout?

    private typealias M = NotesLayoutSwitchMetrics

    var body: some View {
        let tokens = design.tokens
        let layouts = NotesLibraryLayout.allCases
        let selected = layouts.firstIndex(of: selection) ?? 0
        let chipRadius = AtticShape.controlRadius(height: M.cell)
        HStack(spacing: M.gap) {
            ForEach(layouts) { layout in
                let on = layout == selection
                let ink = on || hovered == layout ? tokens.ink(.heading).color
                    : TasksPanelDesign.toneInk(.meta, tokens: tokens).color
                Button { selection = layout } label: {
                    NotesLayoutGlyph(layout: layout)
                        .stroke(ink, style: StrokeStyle(lineWidth: layout == .board ? 0.9 : 1, lineCap: .round, lineJoin: .round))
                        .frame(width: M.glyph, height: M.glyph)
                        .frame(width: M.cell, height: M.cell)
                        .contentShape(AtticControlShape.shape(cornerRadius: chipRadius, exponent: AtticShape.controlExponent))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { inside in
                    if inside { hovered = layout } else if hovered == layout { hovered = nil }
                }
                .help(layout.title)
                .accessibilityLabel(layout.title)
                .accessibilityIdentifier("notes-layout-\(layout.rawValue)")
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
        }
        .background(alignment: .leading) {
            AtticSelectionMarker(cornerRadius: chipRadius)
                .frame(width: M.cell, height: M.cell)
                .offset(x: M.markerOffset(index: selected))
                .accessibilityHidden(true)
        }
        .padding(M.inset)
        .frame(height: AtticControlSize.headerControl)
        .background(Color.clear.atticRaisedMaterial(cornerRadius: AtticRadius.header, interactive: false))
        .atticFocusRing(capture == nil && focused && keyboardFocusVisible, cornerRadius: AtticRadius.header)
        .animation(design.reduceMotion ? nil : .easeOut(duration: 0.16), value: selection)
        .focusable(capture == nil)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            guard let next = AtticPageArrows.next(from: selected, key: press.key, modifiers: press.modifiers, count: layouts.count)
            else { return .ignored }
            if next != selected { selection = layouts[next] }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Layout"))
        .accessibilityIdentifier("notes-layout-switch")
    }
}

/// The design's glyphs (22 px): four cards in two uneven columns for the
/// board, three lines for the list.
struct NotesLayoutGlyph: Shape {
    let layout: NotesLibraryLayout

    func path(in rect: CGRect) -> Path {
        let s = rect.width / 22
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rect.minX + x * s, y: rect.minY + y * s, width: w * s, height: h * s)
        }
        var path = Path()
        switch layout {
        case .board:
            for (frame, radius) in [(r(1.5, 1.5, 8, 11), 2.4), (r(12.5, 1.5, 8, 7), 2.4),
                                    (r(1.5, 15.5, 8, 5), 2.2), (r(12.5, 11.5, 8, 9), 2.4)] as [(CGRect, CGFloat)] {
                path.addRoundedRect(in: frame, cornerSize: CGSize(width: radius * s, height: radius * s), style: .continuous)
            }
        case .list:
            for y in [5.5, 11, 16.5] as [CGFloat] {
                path.move(to: CGPoint(x: rect.minX + 3.5 * s, y: rect.minY + y * s))
                path.addLine(to: CGPoint(x: rect.minX + 18.5 * s, y: rect.minY + y * s))
            }
        }
        return path
    }
}
