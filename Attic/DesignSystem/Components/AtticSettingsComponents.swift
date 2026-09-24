import SwiftUI

// Settings follow Craft (spec § Settings): a translucent, desaturated
// sidebar; the page in an inset content card; grouped cards (radius 17)
// with label-over-value rows and a ⌃⌄ pop-up; almost no outlines; the
// current choice gets a 2 pt ring with a 2 pt gap. No label ever wraps.

// MARK: - Sidebar

/// The translucent sidebar background (the system sidebar material under a
/// desaturated veil of the chrome colour; solid under Reduce Transparency).
struct AtticSidebarBackground: View {
    @Environment(\.atticDesign) private var design

    var body: some View {
        AtticSurfaceBackground(model: design.tokens.chrome, shape: Rectangle(), isChrome: true)
    }
}

/// A bold group heading, aligned with the icon column.
struct AtticSidebarHeading: View {
    let title: String

    var body: some View {
        AtticText(verbatim: title, style: .sidebarHeading, ink: .chromeHeading)
            .padding(.leading, AtticLayout.sidebarIconX)
            .frame(height: AtticLayout.sidebarRowPitch, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A quiet italic hint under a group (shown when the group needs one).
struct AtticSidebarHint: View {
    let text: String

    var body: some View {
        AtticText(verbatim: text, style: .settingsHint, ink: .chromeHint)
            .padding(.leading, AtticLayout.sidebarIconX)
            .frame(height: 24, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A sidebar row: 32 pt pitch, a 30 pt soft grey pill (radius 10) when
/// selected, icon lighter than text, 13 pt regular.
struct AtticSidebarRow: View {
    let systemName: String
    let title: String
    var isSelected = false
    var action: () -> Void = {}

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @Environment(\.isFocused) private var isFocused
    @State private var hovered = false
    @State private var probeID = UUID()

    var body: some View {
        let tokens = design.tokens
        let state = AtticStateResolver(forced: forced, isEnabled: true, isHovered: hovered, isPressed: false, isFocused: isFocused).state
        let fill: AtticRGBA? = isSelected ? tokens.selected : (state == .hover ? tokens.hover : nil)
        Button(action: action) {
            HStack(spacing: 0) {
                AtticIcon(systemName: systemName, size: 13.5, weight: .regular, ink: .chromeIcon)
                    .frame(width: 16)
                    .padding(.leading, AtticLayout.sidebarIconX - 1)
                AtticText(verbatim: title, style: .sidebarRow, ink: .chromeBody)
                    .padding(.leading, AtticLayout.sidebarTextX - AtticLayout.sidebarIconX - 15)
                Spacer(minLength: 8)
            }
            .frame(height: AtticLayout.sidebarHighlightHeight)
            .background {
                if let fill {
                    AtticHighlight(fill: fill).padding(.horizontal, AtticLayout.rowHighlightInset)
                }
            }
            .overlay {
                if state == .focused {
                    Color.clear
                        .atticFocusRing(true, cornerRadius: AtticRadius.highlight)
                        .padding(.horizontal, AtticLayout.rowHighlightInset)
                }
            }
            .frame(height: AtticLayout.sidebarRowPitch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .atticControlProbe(
            "Sidebar row", id: probeID,
            expectedSize: CGSize(width: 0, height: AtticLayout.sidebarRowPitch),
            radius: AtticRadius.highlight, expectedRadius: AtticRadius.highlight
        )
    }
}

// MARK: - Content card and header

/// The page's inset card: 8 pt from the sidebar and window edges, radius
/// 10, a 1 px rim.
struct AtticContentCard<Content: View>: View {
    @ViewBuilder let content: Content

    @Environment(\.atticDesign) private var design
    @Environment(\.displayScale) private var displayScale
    @State private var probeID = UUID()

    var body: some View {
        let tokens = design.tokens
        let shape = RoundedRectangle(cornerRadius: AtticRadius.contentCard, style: .continuous)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(shape.fill(tokens.contentCard.color))
            .clipShape(shape)
            .overlay(shape.strokeBorder(tokens.contentCardRim.color, lineWidth: max(1 / displayScale, 0.5)))
            .atticControlProbe("Content card", id: probeID, expectedSize: nil, radius: AtticRadius.contentCard, expectedRadius: 10)
    }
}

/// The page's top bar: a rim-lit back button (sub-pages only) and the
/// 16 pt bold title.
struct AtticSettingsHeader: View {
    let title: String
    var showsBack = true
    var onBack: () -> Void = {}

    var body: some View {
        HStack(spacing: AtticSpacing.s12) {
            if showsBack {
                AtticRaisedButton(systemName: "chevron.left", label: "Back", size: AtticControlSize.settingsBackButton, action: onBack)
            }
            AtticText(verbatim: title, style: .pageTitle, ink: .heading)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(height: AtticControlSize.settingsBackButton.height)
        .padding(AtticSpacing.s12)
    }
}

// MARK: - Groups

/// A section heading above a group card: 14 pt bold, aligned with the
/// rows' text column.
struct AtticSectionHeading: View {
    let title: String

    var body: some View {
        AtticText(verbatim: title, style: .sectionHeading, ink: .heading)
            .padding(.leading, AtticLayout.groupedRowTextInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A group card: recessed, flat, borderless (a 1 pt border only under
/// Increase Contrast), radius 17. Rows are separated by dividers that run
/// from the text column to the right edge.
struct AtticGroupCard<Content: View>: View {
    @ViewBuilder let content: Content

    @Environment(\.atticDesign) private var design
    @State private var probeID = UUID()

    var body: some View {
        let tokens = design.tokens
        let shape = RoundedRectangle(cornerRadius: AtticRadius.groupCard, style: .continuous)
        VStack(spacing: 0) { content }
            .background(shape.fill(tokens.groupCard.color))
            .clipShape(shape)
            .overlay {
                if let border = tokens.groupCardBorder { shape.strokeBorder(border.color, lineWidth: 1) }
            }
            .atticControlProbe("Group card", id: probeID, expectedSize: nil, radius: AtticRadius.groupCard, expectedRadius: 17)
    }
}

/// The divider inside a group card.
struct AtticGroupDivider: View {
    @Environment(\.atticDesign) private var design
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(design.tokens.divider.color)
            .frame(height: max(1 / displayScale, 0.5))
            .padding(.leading, AtticLayout.groupedRowTextInset)
            .accessibilityHidden(true)
    }
}

/// A label-over-value row (57 pt) with a ⌃⌄ pop-up for choices. The menu is
/// the system's own (native first); the row is ours.
struct AtticPopUpRow<Choice: Hashable>: View {
    let label: String
    let choices: [(value: Choice, title: String)]
    @Binding var selection: Choice

    @Environment(\.atticCapture) private var capture

    var body: some View {
        let title = choices.first { $0.value == selection }?.title ?? ""
        if capture != nil {
            AtticPopUpRowFace(label: label, value: title)
        } else {
            Menu {
                Picker(label, selection: $selection) {
                    ForEach(choices, id: \.value) { choice in
                        Text(choice.title).tag(choice.value)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                AtticPopUpRowFace(label: label, value: title)
            }
            .menuStyle(.button)
            .buttonStyle(AtticRowPressStyle())
            .menuIndicator(.hidden)
            .accessibilityLabel(label)
            .accessibilityValue(title)
        }
    }
}

/// The drawn face of a pop-up row (also used, static, in captures).
struct AtticPopUpRowFace: View {
    let label: String
    let value: String

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @Environment(\.atticIsPressed) private var isPressed
    @State private var hovered = false
    @State private var probeID = UUID()

    var body: some View {
        let pressed = forced == .pressed || isPressed
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                AtticText(verbatim: label, style: .groupLabel, ink: .label)
                AtticText(verbatim: value, style: .groupValue, ink: .body)
            }
            Spacer(minLength: 8)
            AtticIcon(systemName: "chevron.up.chevron.down", size: 10.5, weight: .medium, ink: .chevron)
                .frame(width: 16)
                .padding(.trailing, AtticLayout.chevronTrailingCentre - 8)
        }
        .padding(.leading, AtticLayout.groupedRowTextInset)
        .frame(height: AtticLayout.groupedRowTall)
        .background((pressed ? design.tokens.selected : (forced == .hover || hovered ? design.tokens.hover : .clear)).color)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .atticControlProbe(
            "Grouped row", id: probeID,
            expectedSize: CGSize(width: 0, height: AtticLayout.groupedRowTall),
            radius: 0, expectedRadius: 0
        )
    }
}

private struct AtticRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.atticIsPressed, configuration.isPressed)
    }
}

/// A single-line row (40 pt) with a system switch tinted in the accent.
struct AtticSwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    @Environment(\.atticDesign) private var design
    @Environment(\.atticCapture) private var capture
    @State private var probeID = UUID()

    var body: some View {
        HStack {
            AtticText(verbatim: title, style: .rowSingle, ink: .body)
            Spacer(minLength: 8)
            if capture != nil {
                AtticSwitchDrawing(isOn: isOn)
            } else {
                Toggle(title, isOn: $isOn)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(design.tokens.color(.accent))
            }
        }
        .padding(.leading, AtticLayout.groupedRowTextInset)
        .padding(.trailing, 14)
        .frame(height: AtticLayout.groupedRowSingle)
        .atticControlProbe(
            "Grouped row (single)", id: probeID,
            expectedSize: CGSize(width: 0, height: AtticLayout.groupedRowSingle),
            radius: 0, expectedRadius: 0
        )
    }
}

/// A capture-only drawing of the small system switch (AppKit switches do
/// not render in `ImageRenderer`). Live UI always uses the real switch.
private struct AtticSwitchDrawing: View {
    let isOn: Bool
    @Environment(\.atticDesign) private var design

    var body: some View {
        let tokens = design.tokens
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill((isOn ? tokens.ink(.accent) : tokens.selected.over(tokens.groupCard)).color)
            Circle().fill(Color.white).shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5).padding(1.5)
        }
        .frame(width: 32, height: 18)
        .accessibilityHidden(true)
    }
}

// MARK: - Tiles

/// Tile selection: the 2 pt ring with a 2 pt gap in the accent.
private struct AtticTileRing: ViewModifier {
    let isSelected: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            if isSelected { AtticFocusRing(cornerRadius: radius) }
        }
    }
}

/// System, Light and Dark: a small preview with its name below.
struct AtticModeTile: View {
    enum Choice: String, CaseIterable { case system, light, dark }

    let choice: Choice
    var isSelected = false
    var action: () -> Void = {}

    @State private var probeID = UUID()

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                AtticModePreview(choice: choice)
                    .frame(width: 112, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: AtticRadius.tile, style: .continuous))
                    .modifier(AtticTileRing(isSelected: isSelected, radius: AtticRadius.tile))
                    .atticControlProbe("Mode tile", id: probeID, expectedSize: CGSize(width: 112, height: 70), radius: AtticRadius.tile, expectedRadius: 10)
                AtticText(
                    verbatim: title,
                    style: isSelected ? .tileLabelSelected : .tileLabel,
                    ink: isSelected ? .heading : .body
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var title: String {
        switch choice {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
}

private struct AtticModePreview: View {
    let choice: AtticModeTile.Choice

    var body: some View {
        switch choice {
        case .light: half(dark: false)
        case .dark: half(dark: true)
        case .system:
            HStack(spacing: 0) {
                half(dark: false).frame(width: 56, alignment: .leading).clipped()
                half(dark: true).frame(width: 56, alignment: .trailing).clipped()
            }
        }
    }

    private func half(dark: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            (dark ? Color(.sRGB, red: 0.27, green: 0.31, blue: 0.38) : Color(.sRGB, red: 0.90, green: 0.86, blue: 0.80))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(dark ? Color(.sRGB, red: 0.17, green: 0.17, blue: 0.18) : Color(.sRGB, red: 0.98, green: 0.98, blue: 0.98))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(dark ? Color.white.opacity(0.35) : Color.black.opacity(0.22)).frame(width: 40, height: 3)
                        Capsule().fill(dark ? Color.white.opacity(0.2) : Color.black.opacity(0.12)).frame(width: 28, height: 3)
                    }
                    .padding(9)
                }
                .padding(.top, 12)
                .padding(.leading, 12)
                .padding(.trailing, -20)
                .padding(.bottom, -20)
        }
        .frame(width: 112, height: 70)
        .accessibilityHidden(true)
    }
}

/// A palette: its Light and Dark surfaces with the accent dot, and its
/// name. Recessed, borderless; the current one gets the ring.
struct AtticPaletteTile: View {
    let palette: AtticPanelTheme
    var isSelected = false
    var action: () -> Void = {}

    @Environment(\.atticDesign) private var design
    @State private var probeID = UUID()

    var body: some View {
        let tokens = design.tokens
        let shape = RoundedRectangle(cornerRadius: AtticRadius.tile, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 4) {
                    swatch(.light)
                    swatch(.dark)
                }
                AtticText(verbatim: palette.title, style: .settingsHelper, ink: isSelected ? .heading : .body)
            }
            .padding(8)
            .frame(width: 132, alignment: .leading)
            .background(shape.fill(tokens.recessed.over(tokens.contentCard).color))
            .overlay {
                if let border = tokens.recessedBorder { shape.strokeBorder(border.color, lineWidth: 1) }
            }
            .modifier(AtticTileRing(isSelected: isSelected, radius: AtticRadius.tile))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(palette.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .atticControlProbe("Palette tile", id: probeID, expectedSize: nil, radius: AtticRadius.tile, expectedRadius: 10)
    }

    private func swatch(_ mode: AtticDesignContext.Mode) -> some View {
        let tokens = AtticDesignContext(mode: mode, palette: palette).tokens
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(tokens.panel.base.color)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.black.opacity(mode == .light ? 0.08 : 0.25), lineWidth: 0.5))
            .overlay(alignment: .trailing) {
                Circle().fill(tokens.color(.accent)).frame(width: 5, height: 5).padding(.trailing, 6)
            }
            .frame(width: 54, height: 22)
            .accessibilityHidden(true)
    }
}

// MARK: - Slider row and live preview

/// A label-over-value row with a system slider (Tint length). The slider is
/// the system's own; captures draw a faithful stand-in.
struct AtticSliderRow: View {
    let label: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    @Environment(\.atticDesign) private var design
    @Environment(\.atticCapture) private var capture
    @State private var probeID = UUID()

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                AtticText(verbatim: label, style: .groupLabel, ink: .label)
                AtticText(verbatim: valueText, style: .groupValue, ink: .body)
            }
            Spacer(minLength: 8)
            Group {
                if capture != nil {
                    AtticSliderDrawing(fraction: (value - range.lowerBound) / (range.upperBound - range.lowerBound))
                } else {
                    Slider(value: $value, in: range)
                        .controlSize(.small)
                        .tint(design.tokens.color(.accent))
                        .labelsHidden()
                        .accessibilityLabel(label)
                        .accessibilityValue(valueText)
                }
            }
            .frame(width: 180)
        }
        .padding(.leading, AtticLayout.groupedRowTextInset)
        .padding(.trailing, 16)
        .frame(height: AtticLayout.groupedRowTall)
        .atticControlProbe(
            "Grouped row", id: probeID,
            expectedSize: CGSize(width: 0, height: AtticLayout.groupedRowTall),
            radius: 0, expectedRadius: 0
        )
    }
}

/// A capture-only drawing of the small system slider.
private struct AtticSliderDrawing: View {
    let fraction: Double
    @Environment(\.atticDesign) private var design

    var body: some View {
        let tokens = design.tokens
        GeometryReader { proxy in
            let x = proxy.size.width * min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(tokens.selected.over(tokens.groupCard).color).frame(height: 4)
                Capsule().fill(tokens.color(.accent)).frame(width: x, height: 4)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                    .frame(width: 14, height: 14)
                    .offset(x: x - 7)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }
}

/// The small live preview at the top of Appearance: the panel as it will
/// look, over a stand-in desktop, cropped to the part worth showing (the
/// header, the tabs and the first rows). A picture: it is not interactive,
/// and the appearance check judges the panel itself, not this copy.
struct AtticAppearancePreview<Panel: View>: View {
    var height: CGFloat = 156
    var scale: CGFloat = 0.62
    @ViewBuilder let panel: Panel

    @Environment(\.atticDesign) private var design

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AtticRadius.groupCard, style: .continuous)
        ZStack(alignment: .top) {
            AtticStandInWallpaper(dark: design.mode == .dark)
            panel
                .scaleEffect(scale, anchor: .top)
                .frame(width: AtticLayout.panelSize.width * scale, height: AtticLayout.panelSize.height * scale, alignment: .top)
                .shadow(color: .black.opacity(design.mode == .dark ? 0.35 : 0.14), radius: 8, y: 3)
                .padding(.top, 18)
                .environment(\.atticProbesDisabled, true)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .clipShape(shape)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Preview of the panel"))
    }
}
