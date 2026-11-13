import SwiftUI

/// The Draw page's sizes, in points (the drawing is at 2×: px ÷ 2).
enum DrawPageMetrics {
    /// One size (Accepted 2026-10-30): the capsule is the bottom bar's 27 pt.
    static let capsule: CGFloat = AtticControlSize.headerControl
    /// The capsule's 6 px side padding and the cells' 2 px gap.
    static let capsulePadding: CGFloat = 3
    static let cellGap: CGFloat = 1
    /// Tool cells 52 × 42 px; D1's colour cells 44 px wide.
    static let cell = CGSize(width: 26, height: 21)
    static let colourCell: CGFloat = 22
    /// The swatch's 24 px dot; Style's 26 px.
    static let swatch: CGFloat = 12
    static let styleSwatch: CGFloat = 13
    /// The shapes' faint shared backing, rgba(0, 0, 0, 0.035).
    static let stripBacking: Double = 0.035
    /// Shape's corner mark: 7 px, 9 px from the right, 7 px from the bottom.
    static let cornerMark: CGFloat = 3.5
    static let cornerMarkInset = CGSize(width: 4.5, height: 3.5)
    /// A stroke dims the bar (and, D6, the top row) to 35 %.
    static let dimmed: Double = 0.35
    /// The title capsule: 150 px from each side, 16/20 px padding, 10 px gap.
    static let titleSideInset: CGFloat = 75
    static let titlePadding = (leading: CGFloat(10), trailing: CGFloat(8))
    static let titleGap: CGFloat = 5
    static let titleFont: CGFloat = 12
    /// The zoom pill: 48 px tall, 20 px padding, 16 px above the bar.
    static let pillHeight: CGFloat = 24
    static let pillPadding: CGFloat = 10
    static let pillGap: CGFloat = 8
    /// The board's clear area keeps 12 px from the top row and the bar.
    static let clearGap: CGFloat = 6
    /// Accepted menu placement: 8 pt from its title control.
    static let menuGap: CGFloat = AtticMenuMetrics.anchorGap

    static func fold(_ reduceMotion: Bool) -> Animation { AtticPanelChromeMetrics.fold(reduceMotion: reduceMotion) }

    /// The tool capsule's width with `strip` open (nil: shut), as
    /// `DrawToolBar` lays it out: Select, Pen, Eraser, Text, Shape, the
    /// swatch and Undo, one of them widened into its strip (Undo folds away
    /// while a strip is open). The bar's ✦ reads it to step aside (13 Nov).
    static func capsuleWidth(strip: DrawStrip?) -> CGFloat {
        let tool = cell.width
        let cells: [CGFloat]
        switch strip {
        case nil: cells = Array(repeating: tool, count: 7)
        case .pen?, .text?: cells = Array(repeating: tool, count: 5) + [stripWidth(count: DrawSize.allCases.count, cell: tool)]
        case .shape?: cells = Array(repeating: tool, count: 5) + [stripWidth(count: DrawShape.allCases.count, cell: tool)]
        case .colour?: cells = Array(repeating: tool, count: 5) + [stripWidth(count: DrawColour.allCases.count, cell: colourCell)]
        }
        return stripWidth(cells) + 2 * capsulePadding
    }

    private static func stripWidth(count: Int, cell: CGFloat) -> CGFloat {
        stripWidth(Array(repeating: cell, count: count))
    }

    private static func stripWidth(_ cells: [CGFloat]) -> CGFloat {
        cells.reduce(0, +) + CGFloat(max(0, cells.count - 1)) * cellGap
    }

    /// D4 removes the menu's search row. The list keeps both card insets
    /// and stops at the panel's bottom inset, with one pixel of grace.
    static let bottomGrace: CGFloat = 0.5

    static func menuListRoom(boardHeight: CGFloat, chromeTop: CGFloat, chromeBottom: CGFloat) -> CGFloat {
        let room = boardHeight - chromeTop - capsule - menuGap - chromeBottom
            - AtticGlassMenuShape.inset * 2 + bottomGrace
        // Expand in tall panels; in a tight work area the list scrolls
        // inside the room that actually exists, with no forced height floor.
        return max(0, room)
    }
}

extension DrawTool {
    var title: String {
        switch self {
        case .select: String(localized: "Select")
        case .pen: String(localized: "Pen")
        case .eraser: String(localized: "Eraser")
        case .text: String(localized: "Text")
        case .shape: String(localized: "Shape")
        }
    }

    var systemName: String {
        switch self {
        case .select: "cursorarrow"
        case .pen: "pencil.tip"
        case .eraser: "eraser"
        case .text: "textformat"
        case .shape: "rectangle"
        }
    }
}

extension DrawShape {
    var title: String {
        switch self {
        case .rectangle: String(localized: "Rectangle")
        case .ellipse: String(localized: "Ellipse")
        case .line: String(localized: "Line")
        case .arrow: String(localized: "Arrow")
        }
    }

    var systemName: String {
        switch self {
        case .rectangle: "rectangle"
        case .ellipse: "oval"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        }
    }
}

extension DrawColour {
    var title: String {
        switch self {
        case .ink: String(localized: "Ink")
        case .blue: String(localized: "Blue")
        case .red: String(localized: "Red")
        case .green: String(localized: "Green")
        case .orange: String(localized: "Orange")
        }
    }

    func color(dark: Bool) -> Color { Color(cgColor: DrawPalette(dark: dark).cgColor(self)) }
}

extension DrawSize {
    func title(text: Bool) -> String {
        switch self {
        case .small: text ? String(localized: "Small") : String(localized: "Thin")
        case .medium: String(localized: "Medium")
        case .large: text ? String(localized: "Large") : String(localized: "Thick")
        }
    }

    /// Style's "Aa" at 17, 22 and 29 px.
    var sampleFont: CGFloat {
        switch self { case .small: 8.5; case .medium: 11; case .large: 14.5 }
    }
}

/// One cell in a capsule: the bar's 21 pt chip on the one selection marker,
/// a step lighter under the pointer (the tag bar's pills).
struct DrawCell<Label: View>: View {
    var width: CGFloat = DrawPageMetrics.cell.width
    var height: CGFloat = DrawPageMetrics.cell.height
    var selected = false
    let help: String
    var identifier: String?
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    var body: some View {
        let radius = AtticShape.controlRadius(height: height)
        let shape = AtticControlShape.shape(cornerRadius: radius, exponent: AtticShape.controlExponent)
        Button(action: action) {
            label()
                .frame(width: width, height: height)
                .background {
                    if selected {
                        AtticSelectionMarker(cornerRadius: radius).transition(AtticSelectionMarker.transition)
                    } else if hovered {
                        shape.fill(AtticSelectionMarker.hoverFill(design.tokens).color)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .atticOwnFocusRing(.rounded(radius: radius, height: height))
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier ?? "")
        .animation(AtticSelectionMarker.animation(reduceMotion: design.reduceMotion), value: selected)
    }
}

/// A colour's dot with the design's white inner ring and hairline.
struct DrawSwatchDot: View {
    let fill: AnyShapeStyle
    var size: CGFloat = DrawPageMetrics.swatch

    var body: some View {
        Circle()
            .fill(fill)
            .overlay(Circle().inset(by: 0.5).stroke(Color.white.opacity(0.9), lineWidth: 1))
            .overlay(Circle().stroke(Color.black.opacity(0.14), lineWidth: 0.5))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The tool capsule (Planning.md, Draw › Bottom bar): Select, Pen, Eraser,
/// Text and Shape, then the swatch and Undo, only as wide as its tools.
/// Shape, the swatch (D1) and a second click on Pen or Text (D2) widen in
/// place; Undo folds away while they're open.
struct DrawToolBar: View {
    @ObservedObject var model: DrawPageModel

    @Environment(\.atticDesign) private var design

    var body: some View {
        let m = DrawPageMetrics.self
        let shape = Squircle(cornerRadius: AtticShape.controlRadius(height: m.capsule), exponent: AtticControlShape.designExponent)
        let dark = design.mode == .dark
        HStack(spacing: m.cellGap) {
            ForEach([DrawTool.select, .pen, .eraser, .text], id: \.self) { tool in
                if tool == .pen, model.strip == .pen {
                    widths(.pen)
                } else if tool == .text, model.strip == .text {
                    widths(.text)
                } else {
                    toolCell(tool)
                }
            }
            if model.strip == .shape {
                strip {
                    ForEach(DrawShape.allCases, id: \.self) { kind in
                        DrawCell(selected: model.shape == kind, help: kind.title, identifier: "draw-shape-\(kind.rawValue)",
                                 action: { model.pickShape(kind) }) { icon(kind.systemName) }
                    }
                }
            } else {
                toolCell(.shape)
            }
            if model.strip == .colour {
                strip {
                    ForEach(DrawColour.allCases, id: \.self) { colour in
                        DrawCell(width: m.colourCell, selected: model.colour == colour, help: colour.title,
                                 identifier: "draw-colour-\(colour.rawValue)", action: { model.pickColour(colour) }) {
                            DrawSwatchDot(fill: AnyShapeStyle(colour.color(dark: dark)))
                        }
                    }
                }
            } else {
                DrawCell(help: String(localized: "Colour"), identifier: "draw-swatch", action: model.clickSwatch) {
                    DrawSwatchDot(fill: AnyShapeStyle(model.colour.color(dark: dark)))
                }
                .transition(.opacity)
            }
            if model.isUndoShown {
                DrawCell(help: String(localized: "Undo"), identifier: "draw-undo", action: {
                    IdleLatencyTrace.controlDispatched(.drawUndo)
                    model.undoAcknowledged()
                }) {
                    icon("arrow.uturn.backward")
                }
                .opacity(model.canUndo ? 1 : m.dimmed)
                .disabled(!model.canUndo)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, m.capsulePadding)
        .frame(height: m.capsule)
        .clipShape(shape)
        .background(Color.clear.atticRaisedMaterial(cornerRadius: AtticShape.controlRadius(height: m.capsule), interactive: false, edgeLight: true))
        .fixedSize()
        .animation(m.fold(design.reduceMotion), value: model.strip)
        // Esc from a focused cell closes an open strip, so the keyboard
        // gets back to Undo and to the bar's ✦, which steps aside while a
        // strip is open (13 Nov). Shut, Esc passes on as before.
        .onExitCommand(perform: model.strip == nil ? nil : { model.closeStrip() })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Tools"))
        .accessibilityIdentifier("draw-tool-bar")
    }

    private func toolCell(_ tool: DrawTool) -> some View {
        let name = tool == .shape ? model.shape.systemName : tool.systemName
        let help = tool == .shape ? model.shape.title : tool.title
        return DrawCell(selected: model.tool == tool, help: help, identifier: "draw-tool-\(tool.rawValue)",
                        action: {
                            IdleLatencyTrace.controlDispatched(.drawTool)
                            model.clickTool(tool)
                        }) {
            icon(name)
                .overlay(alignment: .bottomTrailing) {
                    // Tools with variants carry Shape's small corner mark (D2).
                    if tool == .shape || tool == .pen || tool == .text { cornerMark }
                }
        }
        .transition(.opacity)
    }

    private func widths(_ kind: DrawStrip) -> some View {
        strip {
            ForEach(DrawSize.allCases, id: \.self) { size in
                let text = kind == .text
                DrawCell(selected: (text ? model.textSize : model.strokeSize) == size, help: size.title(text: text),
                         identifier: "draw-\(text ? "text" : "pen")-\(size.rawValue)",
                         action: { model.pickSize(size, for: kind) }) {
                    if text {
                        Text(verbatim: "Aa").font(.system(size: size.sampleFont, weight: .medium))
                            .foregroundStyle(design.tokens.color(.heading))
                    } else {
                        Capsule().fill(design.tokens.color(.glyph))
                            .frame(width: 12, height: CGFloat(size.strokeWidth))
                    }
                }
            }
        }
    }

    private func strip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: DrawPageMetrics.cellGap) { content() }
            .background(AtticControlShape.shape(cornerRadius: AtticShape.controlRadius(height: DrawPageMetrics.cell.height),
                                                exponent: AtticShape.controlExponent)
                .fill(design.tokens.ink(.heading).withAlpha(DrawPageMetrics.stripBacking).color))
            .transition(.opacity)
    }

    private func icon(_ name: String) -> some View {
        AtticIcon(systemName: name, size: AtticControlSize.raisedGlyph, weight: AtticIconWeight.outline, ink: .glyph)
    }

    private var cornerMark: some View {
        Path { path in
            let s = DrawPageMetrics.cornerMark
            path.move(to: CGPoint(x: s, y: 0))
            path.addLine(to: CGPoint(x: s, y: s))
            path.addLine(to: CGPoint(x: 0, y: s))
            path.closeSubpath()
        }
        .fill(design.tokens.color(.chevron))
        .frame(width: DrawPageMetrics.cornerMark, height: DrawPageMetrics.cornerMark)
        .offset(x: DrawPageMetrics.cell.width / 2 - DrawPageMetrics.cornerMarkInset.width - AtticControlSize.raisedGlyph / 2,
                y: DrawPageMetrics.cell.height / 2 - DrawPageMetrics.cornerMarkInset.height - AtticControlSize.raisedGlyph / 2)
        .accessibilityHidden(true)
    }
}
