import SwiftUI

// MARK: - Format toggles

/// One command in Notes' format controls (the selection bar and Aa): a flat
/// 28 pt control whose fill says its state. Off is clear; on takes the
/// selected chip's fill and the primary glyph; mixed (a selection that is
/// partly bold) takes half of it. Hover and press are fills, disabled is the
/// ghost ink, and the 2 pt ring shows only for the keyboard.
enum AtticFormatValue: Equatable {
    case off, on, mixed

    var spoken: String { Self.spokenValue(self) }

    static func spokenValue(_ value: AtticFormatValue) -> String {
        switch value {
        case .off: String(localized: "off")
        case .on: String(localized: "on")
        case .mixed: String(localized: "mixed")
        }
    }
}

struct AtticFormatToggle<Face: View>: View {
    typealias Value = AtticFormatValue

    let value: Value
    let label: String
    /// The tooltip ("Bold ⌘B").
    var help: String?
    var width: CGFloat = AtticNoteFormatMetrics.barToggleWidth
    /// The selection bar's 28; the format row's 24 (chrome B).
    var height: CGFloat = AtticControlSize.smallHeight
    /// The keyboard's position in a bar or pop-over (a ring, no focus move).
    var isKeyboardFocused = false
    /// Said by VoiceOver while the control is dimmed.
    var disabledReason: String?
    /// An action rather than a toggle (indent, close): no on/off value.
    var announcesState = true
    let action: () -> Void
    @ViewBuilder let face: (AtticInk) -> Face

    @Environment(\.atticDesign) private var design
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        let radius = AtticRadius.control(height: height)
        Button(action: action) {
            AtticFormatToggleFace(value: value, hovered: hovered, radius: radius, face: face)
                .frame(width: width, height: height)
                // The format row's 24 pt cells still answer a 28 pt target.
                .contentShape(Rectangle().inset(by: -AtticControlSize.hitOutset(for: min(width, height))))
        }
        .buttonStyle(AtticFormatPressStyle())
        .focusEffectDisabled()
        .atticFocusRing(isKeyboardFocused, cornerRadius: radius)
        .onHover { hovered = $0 }
        .help(help ?? label)
        .accessibilityLabel(label)
        .accessibilityValue(announcesState ? value.spoken : "")
        .accessibilityHint(isEnabled ? "" : (disabledReason ?? ""))
        .accessibilityAddTraits(announcesState && value == .on ? [.isButton, .isSelected] : .isButton)
    }

}

extension AtticFormatToggle where Face == AtticIcon {
    /// A glyph toggle (B, I, a list).
    init(systemName: String, value: Value, label: String, help: String? = nil,
         width: CGFloat = AtticNoteFormatMetrics.barToggleWidth, height: CGFloat = AtticControlSize.smallHeight,
         isKeyboardFocused: Bool = false,
         disabledReason: String? = nil, announcesState: Bool = true, action: @escaping () -> Void) {
        self.init(value: value, label: label, help: help, width: width, height: height, isKeyboardFocused: isKeyboardFocused,
                  disabledReason: disabledReason, announcesState: announcesState, action: action) { ink in
            AtticIcon(systemName: systemName, size: AtticSmallControlMetrics.iconSize, weight: .regular, ink: ink)
        }
    }
}

private struct AtticFormatPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.atticIsPressed, configuration.isPressed)
    }
}

private struct AtticFormatToggleFace<Face: View>: View {
    let value: AtticFormatValue
    let hovered: Bool
    let radius: CGFloat
    let face: (AtticInk) -> Face

    @Environment(\.atticDesign) private var design
    @Environment(\.atticIsPressed) private var isPressed
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let tokens = design.tokens
        let selected = tokens.chipSelected
        let fill: AtticRGBA = if !isEnabled {
            value == .off ? .clear : selected.withAlpha(selected.alpha / 2)
        } else if isPressed {
            tokens.pressed
        } else {
            switch value {
            case .on: selected
            case .mixed: selected.withAlpha(selected.alpha / 2)
            case .off: hovered ? tokens.chipHover : .clear
            }
        }
        let ink: AtticInk = !isEnabled ? .disabledIcon : (value == .off ? .icon : .glyph)
        face(ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill.color))
    }
}

/// The highlight toggle's face: an "A" on a swatch of the note's highlight.
struct AtticHighlightGlyph: View {
    let ink: AtticInk
    let swatch: AtticRGBA

    var body: some View {
        AtticText(verbatim: "A", style: .controlLabel, ink: ink)
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(swatch.color))
            .accessibilityHidden(true)
    }
}

// MARK: - The selection bar

/// The raised capsule the selection bar's controls sit in: the pop-over
/// surface (menus, pop-overs and the selection bar are raised over
/// content), a 4 pt inset, groups 4 apart and never lines.
struct AtticFormatBarSurface<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var probeID = UUID()

    var body: some View {
        let m = AtticNoteFormatMetrics.self
        let radius = AtticRadius.control(height: m.barHeight)
        HStack(spacing: m.barGroupGap) { content }
            .padding(AtticControlSize.capsuleInset)
            .frame(height: m.barHeight)
            // Raised over the text like a pop-over (its fill, rims and
            // shadow): glass over running text would let the words show
            // through the controls.
            .background(AtticPopoverBackground(cornerRadius: radius))
            .atticControlProbe("Format bar", id: probeID, expectedSize: nil, radius: radius, expectedRadius: 15)
    }
}

/// A group of toggles inside the bar or Aa (touching, 0 apart).
struct AtticFormatGroup<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View { HStack(spacing: 0) { content } }
}

/// The bar's style control: the current style's name and a small chevron
/// ("Body ⌄"); it opens the styles' native menu.
struct AtticFormatStyleFace: View {
    let title: String
    var isKeyboardFocused = false
    var isEnabled = true
    var height: CGFloat = AtticControlSize.smallHeight

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    var body: some View {
        let m = AtticNoteFormatMetrics.self
        let radius = AtticRadius.control(height: height)
        HStack(spacing: 4) {
            AtticText(verbatim: title, style: .controlLabel, ink: isEnabled ? .heading : .disabledText)
            AtticIcon(systemName: "chevron.down", size: m.barStyleChevron, weight: .semibold,
                      ink: isEnabled ? .chevron : .disabledIcon)
        }
        .padding(.horizontal, m.barStylePadding)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill((hovered && isEnabled ? design.tokens.chipHover : .clear).color))
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .atticFocusRing(isKeyboardFocused, cornerRadius: radius)
        .onHover { hovered = $0 }
    }
}

// MARK: - The format row (OD-14, p2-36 draft 1)

/// The bottom row turned into a one-row format bar: the bottom row's own
/// Liquid Glass (the drawn recipe under Reduce Transparency), as wide as
/// the row and as tall as its buttons, its controls in a 4 pt inset.
///
/// While it grows out of a button (`growth`, p2-37 draft 1) it is still one
/// glass shape: the glass spans from the button's frame to the row's as
/// `grow` goes from 0 to 1, and the controls are its content, at their
/// resting places and clipped to it, so nothing ever sits under or over
/// the glass. The button's glyph rides on the glass where the button was and
/// fades in the first third. At rest (`growth` nil or `grow` 1) it is the
/// plain row.
struct AtticFormatRowSurface<Content: View>: View, Animatable {
    var height: CGFloat = AtticControlSize.panelButton.height
    var growth: AtticFormatRowGrowth?
    /// The controls' own fade (they come in once the glass is wide).
    var contentOpacity: Double = 1
    @ViewBuilder let content: Content
    @State private var probeID = UUID()

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(growth?.leading ?? 1, growth?.trailing ?? 1) }
        set {
            growth?.leading = newValue.first
            growth?.trailing = newValue.second
        }
    }

    var body: some View {
        let radius = AtticRadius.control(height: height)
        let row = HStack(spacing: 0) { content }
            .padding(.horizontal, AtticControlSize.capsuleInset)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .opacity(contentOpacity)
        Group {
            if let growth {
                let extent = growth.extent
                Color.clear
                    .frame(width: extent.width, height: height)
                    .overlay(alignment: .leading) {
                        row.frame(width: growth.rowWidth).offset(x: -extent.minX)
                    }
                    .overlay(alignment: .leading) {
                        AtticIcon(systemName: growth.sourceSymbol, size: AtticControlSize.raisedGlyph,
                                  weight: AtticIconWeight.outline, ink: .icon)
                            .frame(width: growth.source.width, height: height)
                            .offset(x: growth.source.minX - extent.minX)
                            .opacity(growth.sourceGlyphOpacity)
                            .accessibilityHidden(true)
                    }
                    .clipShape(AtticControlShape.shape(cornerRadius: radius))
                    .atticRaisedMaterial(cornerRadius: radius, interactive: false)
                    // Placed by layout, not by an offset, so the glass is
                    // drawn exactly where the shape is on every frame.
                    .padding(.leading, extent.minX)
                    .frame(width: growth.rowWidth, alignment: .leading)
            } else {
                row.atticRaisedMaterial(cornerRadius: radius, interactive: false)
            }
        }
        .atticControlProbe("Format row", id: probeID, expectedSize: nil, radius: radius,
                              expectedRadius: AtticRadius.control(height: AtticControlSize.panelButton.height))
    }
}

/// Where the format row's glass is while it grows out of a button (p2-37
/// draft 1): the button's frame and the row's width in the row's own space,
/// and how far each edge has travelled (0 the button's edge, 1 the row's; a
/// spring may pass either end a little). The edges move on their own
/// channels; Aa's opening and closing now animate them together so the
/// glass grows and returns as one shape.
struct AtticFormatRowGrowth: Equatable {
    var source: CGRect
    var rowWidth: CGFloat
    var leading: CGFloat
    var trailing: CGFloat
    var sourceSymbol: String

    init(source: CGRect, rowWidth: CGFloat, leading: CGFloat, trailing: CGFloat, sourceSymbol: String) {
        self.source = source
        self.rowWidth = rowWidth
        self.leading = leading
        self.trailing = trailing
        self.sourceSymbol = sourceSymbol
    }

    /// Both edges together.
    init(source: CGRect, rowWidth: CGFloat, grow: CGFloat, sourceSymbol: String) {
        self.init(source: source, rowWidth: rowWidth, leading: grow, trailing: grow, sourceSymbol: sourceSymbol)
    }

    /// The glass's horizontal span.
    var extent: (minX: CGFloat, width: CGFloat) {
        let minX = source.minX + (0 - source.minX) * leading
        let maxX = source.maxX + (rowWidth - source.maxX) * trailing
        return (minX, max(0, maxX - minX))
    }

    /// The button's glyph on the glass: gone by a third of the way.
    var sourceGlyphOpacity: Double { Double(1 - min(1, max(0, max(leading, trailing) * 3))) }
}

/// The short upright line between the format row's groups.
struct AtticFormatSeparator: View {
    @Environment(\.atticDesign) private var design

    var body: some View {
        let m = AtticNoteFormatMetrics.self
        Rectangle()
            .fill(design.tokens.divider.color)
            .frame(width: 1, height: m.rowSeparatorHeight)
            .padding(.horizontal, m.rowSeparatorPadding)
            .accessibilityHidden(true)
    }
}

/// A paragraph style as the style list draws it: each name in a hint of
/// its own style (Title … Mono).
enum AtticFormatStyleKind {
    case title, heading, subheading, body, mono

    var font: Font {
        switch self {
        case .title: .system(size: 15, weight: .bold)
        case .heading: .system(size: 14, weight: .semibold)
        case .subheading: .system(size: 13.5, weight: .semibold)
        case .body: .system(size: 13, weight: .regular)
        case .mono: .system(size: 12, weight: .regular, design: .monospaced)
        }
    }
}

/// The table tools' glyphs in Aa's row (sheet 3, panel 2): a row or column
/// with a plus or a minus beside it, drawn as the draft draws them (a
/// 16-unit box, a 1.3 stroke) at the row's icon size.
struct AtticTableToolGlyph: View {
    enum Kind { case addRow, addColumn, deleteRow, deleteColumn }
    let kind: Kind
    let ink: AtticInk
    var size: CGFloat = 15

    @Environment(\.atticDesign) private var design

    var body: some View {
        AtticTableToolShape(kind: kind)
            .stroke(design.tokens.ink(ink).color, style: StrokeStyle(lineWidth: 1.3 * size / 16, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct AtticTableToolShape: Shape {
    let kind: AtticTableToolGlyph.Kind

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 16
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit) }
        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: rect.minX + x * unit, y: rect.minY + y * unit, width: width * unit, height: height * unit)
        }
        var path = Path()
        let radius = 1.4 * unit
        switch kind {
        case .addRow, .deleteRow:
            path.addRoundedRect(in: box(2, 2.5, 12, 5), cornerSize: CGSize(width: radius, height: radius))
            path.move(to: point(5.5, 12.5)); path.addLine(to: point(10.5, 12.5))
            if kind == .addRow { path.move(to: point(8, 10)); path.addLine(to: point(8, 15)) }
        case .addColumn, .deleteColumn:
            path.addRoundedRect(in: box(2.5, 2, 5, 12), cornerSize: CGSize(width: radius, height: radius))
            if kind == .addColumn {
                path.move(to: point(10, 8)); path.addLine(to: point(15, 8))
                path.move(to: point(12.5, 5.5)); path.addLine(to: point(12.5, 10.5))
            } else {
                path.move(to: point(10.5, 8)); path.addLine(to: point(15, 8))
            }
        }
        return path
    }
}
