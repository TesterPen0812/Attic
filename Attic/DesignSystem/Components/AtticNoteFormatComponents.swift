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
        let height = AtticControlSize.smallHeight
        let radius = AtticRadius.control(height: height)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Button(action: action) {
            AtticFormatToggleFace(value: value, hovered: hovered, radius: radius, face: face)
                .frame(width: width, height: height)
                .contentShape(shape)
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
         width: CGFloat = AtticNoteFormatMetrics.barToggleWidth, isKeyboardFocused: Bool = false,
         disabledReason: String? = nil, announcesState: Bool = true, action: @escaping () -> Void) {
        self.init(value: value, label: label, help: help, width: width, isKeyboardFocused: isKeyboardFocused,
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

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    var body: some View {
        let m = AtticNoteFormatMetrics.self
        let height = AtticControlSize.smallHeight
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
struct AtticFormatRowSurface<Content: View>: View {
    var height: CGFloat = AtticControlSize.panelButton.height
    @ViewBuilder let content: Content
    @State private var probeID = UUID()

    var body: some View {
        let radius = AtticRadius.control(height: height)
        HStack(spacing: 0) { content }
            .padding(.horizontal, AtticControlSize.capsuleInset)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .atticRaisedMaterial(cornerRadius: radius, interactive: false)
            .atticControlProbe("Format row", id: probeID, expectedSize: nil, radius: radius, expectedRadius: 15)
    }
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
