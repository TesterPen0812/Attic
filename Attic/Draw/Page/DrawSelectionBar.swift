import SwiftUI

enum DrawSelectionBarMetrics {
    /// 68 px tall with 6 px padding; actions 56 px, Style 72 px.
    static let height: CGFloat = 34
    static let padding: CGFloat = 3
    static let action: CGFloat = 28
    static let styleWidth: CGFloat = 36
    static let gap: CGFloat = 1
    static let radius: CGFloat = 16
    /// Above the selection: its 8 px outline gap, then 16 px.
    static let outlineGap: CGFloat = 4
    static let clearance: CGFloat = 8
    /// Kept 12 px from the board's sides.
    static let sideInset: CGFloat = 6
    /// D3's second line (58 px) and its 52 px corner cells.
    static let line: CGFloat = 29
    static let cornerCell: CGFloat = 26
    static let countPadding = (leading: CGFloat(7), trailing: CGFloat(5))
    static let countFont: CGFloat = 10
    static let labelFont: CGFloat = 10.5
}

/// Where the selection bar goes: above the selection, below it near the
/// top, clamped to the board's sides (the working file's rule).
enum DrawSelectionBarPlacement {
    struct Result: Equatable {
        var origin: CGPoint
        /// The bar sits above the selection (D3's second line grows upward).
        var above: Bool
    }

    static func place(selection: CGRect, barSize: CGSize, board: CGSize, clear: CGRect) -> Result {
        let m = DrawSelectionBarMetrics.self
        let top = selection.minY - m.outlineGap, bottom = selection.maxY + m.outlineGap
        var y = top - m.clearance - barSize.height
        var above = true
        if y < clear.minY { y = bottom + m.clearance; above = false }
        if y > clear.maxY - barSize.height { y = clear.minY; above = false }
        let x = max(m.sideInset, min(board.width - m.sideInset - barSize.width, selection.midX - barSize.width / 2))
        return Result(origin: CGPoint(x: x, y: y), above: above)
    }
}

/// The selection bar (Planning.md, Draw › Selection): a solid card, never
/// glass over ink. Style, Save Image (an image), Duplicate (several, or an
/// image), Delete and ⋯; D3: Style opens inside it and the others fold away.
struct DrawSelectionOverlay: View {
    @ObservedObject var model: DrawPageModel
    @ObservedObject var viewportState: DrawViewportState

    @Environment(\.atticDesign) private var design
    @State private var barSize = CGSize(width: 160, height: DrawSelectionBarMetrics.height)

    var body: some View {
        let actions = model.selectionActions
        let _ = model.selectionRevision
        GeometryReader { _ in
            if !actions.isEmpty, let bounds = DrawGeometry.union(model.selectedObjects) {
                let screen = viewportState.viewport.screen(bounds)
                let place = DrawSelectionBarPlacement.place(selection: screen, barSize: barSize,
                                                            board: model.boardSize, clear: model.clearRect)
                DrawSelectionBar(model: model, actions: actions, styleAbove: place.above)
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { barSize = $0 }
                    .offset(x: place.origin.x, y: place.origin.y - (model.isSelectionStyleOpen && place.above ? DrawSelectionBarMetrics.line : 0))
                    .transition(AtticMotionPreset.popover.transition(reduceMotion: design.reduceMotion))
            }
        }
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion, showing: !actions.isEmpty),
                   value: actions.isEmpty)
    }
}

struct DrawSelectionBar: View {
    @ObservedObject var model: DrawPageModel
    let actions: [DrawSelectionAction]
    /// D3's second line grows away from the selection.
    let styleAbove: Bool

    @Environment(\.atticDesign) private var design

    var body: some View {
        let m = DrawSelectionBarMetrics.self
        let open = model.isSelectionStyleOpen
        VStack(spacing: 0) {
            if open, styleAbove { secondLine }
            HStack(spacing: m.gap) {
                if model.selection.count > 1 {
                    Text(verbatim: String(localized: "\(model.selection.count) selected"))
                        .font(.system(size: m.countFont, weight: .semibold).monospacedDigit())
                        .foregroundStyle(design.tokens.color(.heading))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, m.countPadding.leading)
                        .padding(.trailing, m.countPadding.trailing)
                }
                ForEach(actions, id: \.self) { action in
                    if action == .style {
                        styleButton
                        if open { colours.transition(.opacity) }
                    } else if !open {
                        button(action).transition(.opacity)
                    }
                }
            }
            .frame(height: m.height - m.padding * 2)
            if open, !styleAbove { secondLine }
        }
        .padding(m.padding)
        .background(AtticPopoverBackground(cornerRadius: m.radius))
        .animation(DrawPageMetrics.fold(design.reduceMotion), value: open)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Selection"))
        .accessibilityIdentifier("draw-selection-bar")
    }

    private var styleButton: some View {
        let colour = model.selectionStyleColour
        let fill: AnyShapeStyle = colour.map { AnyShapeStyle($0.color(dark: design.mode == .dark)) }
            ?? AnyShapeStyle(AngularGradient(colors: DrawColour.allCases.dropFirst().map { $0.color(dark: design.mode == .dark) },
                                             center: .center))
        return DrawCell(width: DrawSelectionBarMetrics.styleWidth, height: DrawSelectionBarMetrics.action,
                        selected: model.isSelectionStyleOpen, help: String(localized: "Style"), identifier: "draw-selection-style",
                        action: model.toggleSelectionStyle) {
            HStack(spacing: 3) {
                DrawSwatchDot(fill: fill, size: DrawPageMetrics.styleSwatch)
                AtticIcon(systemName: "chevron.down", size: 6, weight: .semibold, ink: .chevron)
            }
        }
    }

    private var colours: some View {
        HStack(spacing: DrawSelectionBarMetrics.gap) {
            ForEach(DrawColour.allCases, id: \.self) { colour in
                DrawCell(width: DrawSelectionBarMetrics.action, height: DrawSelectionBarMetrics.action,
                         selected: model.selectionStyleColour == colour, help: colour.title,
                         identifier: "draw-style-colour-\(colour.rawValue)", action: { model.styleSelection(colour: colour) }) {
                    DrawSwatchDot(fill: AnyShapeStyle(colour.color(dark: design.mode == .dark)), size: 14)
                }
            }
        }
    }

    private var secondLine: some View {
        let m = DrawSelectionBarMetrics.self
        let text = model.selectionIsAllText
        return HStack(spacing: m.gap) {
            ForEach(DrawSize.allCases, id: \.self) { size in
                DrawCell(width: m.action, height: m.action, selected: model.selectionStyleSize == size,
                         help: size.title(text: text), identifier: "draw-style-size-\(size.rawValue)",
                         action: { model.styleSelection(size: size) }) {
                    if text {
                        Text(verbatim: "Aa").font(.system(size: size.sampleFont, weight: .medium))
                            .foregroundStyle(design.tokens.color(.heading))
                    } else {
                        Capsule().fill(design.tokens.color(.glyph)).frame(width: 18, height: CGFloat(size.strokeWidth))
                    }
                }
            }
            if model.selectionHasRectangle {
                ForEach(DrawCorners.allCases, id: \.self) { corners in
                    DrawCell(width: m.cornerCell * 2, height: m.action, selected: model.selectionCorners == corners,
                             help: corners == .square ? String(localized: "Square") : String(localized: "Rounded"),
                             identifier: "draw-style-corners-\(corners.rawValue)",
                             action: { model.styleSelection(corners: corners) }) {
                        Text(corners == .square ? String(localized: "Square") : String(localized: "Rounded"))
                            .font(.system(size: m.labelFont))
                            .foregroundStyle(design.tokens.color(.heading))
                    }
                }
            }
        }
        .frame(height: m.line, alignment: .center)
        .transition(.opacity)
    }

    @ViewBuilder
    private func button(_ action: DrawSelectionAction) -> some View {
        switch action {
        case .style:
            EmptyView()
        case .saveImage:
            AtticSmallButton(systemName: "square.and.arrow.down", label: "Save Image", action: model.saveSelectedImage)
                .accessibilityIdentifier("draw-selection-save-image")
        case .duplicate:
            AtticSmallButton(systemName: "plus.square.on.square", label: "Duplicate", action: model.duplicateSelection)
                .accessibilityIdentifier("draw-selection-duplicate")
        case .delete:
            AtticSmallButton(systemName: "trash", label: "Delete", action: model.deleteSelection)
                .accessibilityIdentifier("draw-selection-delete")
        case .more:
            AtticMenuButton(systemName: "ellipsis", label: "More", commands: { moreCommands })
                .accessibilityIdentifier("draw-selection-more")
        }
    }

    /// ⋯ (Planning.md): Cut, Copy, Paste, Duplicate, Copy as Image | Bring to
    /// Front, Send to Back | Delete. Menus don't print the keys.
    private var moreCommands: [AtticMenuCommand] {
        DrawMoreCommand.allCases.map { command in
            AtticMenuCommand(verbatim: command.title, isDestructive: command == .delete,
                             isDisabled: !model.isEnabled(command),
                             startsSection: command == .bringToFront || command == .delete) { model.runMore(command) }
        }
    }
}

extension DrawMoreCommand {
    var title: String {
        switch self {
        case .cut: String(localized: "Cut")
        case .copy: String(localized: "Copy")
        case .paste: String(localized: "Paste")
        case .duplicate: String(localized: "Duplicate")
        case .copyAsImage: String(localized: "Copy as Image")
        case .bringToFront: String(localized: "Bring to Front")
        case .sendToBack: String(localized: "Send to Back")
        case .delete: String(localized: "Delete")
        }
    }
}
