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
            .frame(height: AtticSettingsMetrics.sidebarHintHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A sidebar row: 32 pt pitch, a 30 pt soft grey pill (radius 10) when
/// selected, icon lighter than text, 13 pt regular.
struct AtticSidebarRow: View {
    let systemName: String
    let title: String
    var isSelected = false
    let action: () -> Void

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
                let m = AtticSettingsMetrics.self
                // The 16 pt icon slot is centred on the icon column.
                let iconLeading = AtticLayout.sidebarIconX - (m.sidebarIconSlot - AtticControlSize.glyph) / 2
                AtticIcon(systemName: systemName, size: m.sidebarIconSize, weight: .regular, ink: .chromeIcon)
                    .frame(width: m.sidebarIconSlot)
                    .padding(.leading, iconLeading)
                AtticText(verbatim: title, style: .sidebarRow, ink: .chromeBody)
                    .padding(.leading, AtticLayout.sidebarTextX - iconLeading - m.sidebarIconSlot)
                Spacer(minLength: m.rowTrailingMinGap)
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
    let onBack: () -> Void

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
                if let border = tokens.groupCardBorder { shape.strokeBorder(border.color, lineWidth: AtticHairline.contrastBorder) }
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
                // One element: the row is a single pop-up for VoiceOver
                // (label "Surface", value "Solid"), not one per text line.
                AtticPopUpRowFace(label: label, value: title)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label)
                    .accessibilityValue(title)
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
        let m = AtticSettingsMetrics.self
        HStack(spacing: m.rowTrailingMinGap) {
            VStack(alignment: .leading, spacing: m.labelValueGap) {
                AtticText(verbatim: label, style: .groupLabel, ink: .label)
                AtticText(verbatim: value, style: .groupValue, ink: .body)
            }
            Spacer(minLength: m.rowTrailingMinGap)
            AtticIcon(systemName: "chevron.up.chevron.down", size: m.popUpChevronSize, weight: .medium, ink: .chevron)
                .frame(width: m.popUpChevronSlot)
                .padding(.trailing, AtticLayout.chevronTrailingCentre - m.popUpChevronSlot / 2)
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
            Spacer(minLength: AtticSettingsMetrics.rowTrailingMinGap)
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
        .padding(.trailing, AtticSettingsMetrics.switchTrailing)
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
            Circle().fill(Color.white).shadow(color: .black.opacity(AtticSettingsMetrics.switchKnobShadowAlpha), radius: AtticSettingsMetrics.switchKnobShadow.radius, y: AtticSettingsMetrics.switchKnobShadow.y).padding(AtticSettingsMetrics.switchKnobInset)
        }
        .frame(width: AtticSettingsMetrics.switchDrawingSize.width, height: AtticSettingsMetrics.switchDrawingSize.height)
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
    let action: () -> Void

    @State private var probeID = UUID()

    var body: some View {
        let m = AtticModeTileMetrics.self
        Button(action: action) {
            VStack(spacing: m.labelGap) {
                AtticModePreview(choice: choice)
                    .frame(width: m.previewSize.width, height: m.previewSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: AtticRadius.tile, style: .continuous))
                    .modifier(AtticTileRing(isSelected: isSelected, radius: AtticRadius.tile))
                    .atticControlProbe("Mode tile", id: probeID, expectedSize: m.previewSize, radius: AtticRadius.tile, expectedRadius: 10)
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
        let size = AtticModeTileMetrics.previewSize
        switch choice {
        case .light: half(dark: false)
        case .dark: half(dark: true)
        case .system:
            HStack(spacing: 0) {
                half(dark: false).frame(width: size.width / 2, alignment: .leading).clipped()
                half(dark: true).frame(width: size.width / 2, alignment: .trailing).clipped()
            }
        }
    }

    /// A small picture of the mode: a desktop and a window with two lines.
    private func half(dark: Bool) -> some View {
        let m = AtticModeTileMetrics.self
        let alphas = dark ? m.lineAlphasDark : m.lineAlphasLight
        return ZStack(alignment: .topLeading) {
            (dark ? m.desktopDark : m.desktopLight).color
            RoundedRectangle(cornerRadius: m.windowRadius, style: .continuous)
                .fill((dark ? m.windowDark : m.windowLight).color)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: m.lineSpacing) {
                        ForEach(Array(zip(m.lineWidths, alphas).enumerated()), id: \.offset) { _, line in
                            Capsule()
                                .fill((dark ? AtticRGBA.white(line.1) : AtticRGBA.black(line.1)).color)
                                .frame(width: line.0, height: m.lineHeight)
                        }
                    }
                    .padding(m.lineInset)
                }
                .padding(.top, m.windowInset)
                .padding(.leading, m.windowInset)
                .padding(.trailing, -m.windowOverhang)
                .padding(.bottom, -m.windowOverhang)
        }
        .frame(width: m.previewSize.width, height: m.previewSize.height)
        .accessibilityHidden(true)
    }
}

/// A palette: its Light and Dark surfaces with the accent dot, and its
/// name. Recessed, borderless; the current one gets the ring.
struct AtticPaletteTile: View {
    let palette: AtticPanelTheme
    var isSelected = false
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var probeID = UUID()

    var body: some View {
        let tokens = design.tokens
        let shape = RoundedRectangle(cornerRadius: AtticRadius.tile, style: .continuous)
        let m = AtticPaletteTileMetrics.self
        Button(action: action) {
            VStack(alignment: .leading, spacing: m.nameGap) {
                HStack(spacing: m.swatchGap) {
                    swatch(.light)
                    swatch(.dark)
                }
                AtticText(verbatim: palette.title, style: .settingsHelper, ink: isSelected ? .heading : .body)
            }
            .padding(m.padding)
            .frame(width: m.width, alignment: .leading)
            .background(shape.fill(tokens.recessed.over(tokens.contentCard).color))
            .overlay {
                if let border = tokens.recessedBorder { shape.strokeBorder(border.color, lineWidth: AtticHairline.contrastBorder) }
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
        let m = AtticPaletteTileMetrics.self
        let tokens = AtticDesignContext(mode: mode, palette: palette).tokens
        let shape = RoundedRectangle(cornerRadius: m.swatchRadius, style: .continuous)
        return shape
            .fill(tokens.panel.base.color)
            .overlay(shape.strokeBorder((mode == .light ? m.swatchRimLight : m.swatchRimDark).color, lineWidth: m.swatchRimWidth))
            .overlay(alignment: .trailing) {
                Circle().fill(tokens.color(.accent)).frame(width: m.accentDot, height: m.accentDot).padding(.trailing, m.accentDotInset)
            }
            .frame(width: m.swatchSize.width, height: m.swatchSize.height)
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
        let m = AtticSettingsMetrics.self
        HStack(spacing: m.sliderGap) {
            VStack(alignment: .leading, spacing: m.labelValueGap) {
                AtticText(verbatim: label, style: .groupLabel, ink: .label)
                AtticText(verbatim: valueText, style: .groupValue, ink: .body)
            }
            Spacer(minLength: m.rowTrailingMinGap)
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
            .frame(width: m.sliderWidth)
        }
        .padding(.leading, AtticLayout.groupedRowTextInset)
        .padding(.trailing, m.sliderTrailing)
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
                let m = AtticSettingsMetrics.self
                Capsule().fill(tokens.selected.over(tokens.groupCard).color).frame(height: m.sliderTrackHeight)
                Capsule().fill(tokens.color(.accent)).frame(width: x, height: m.sliderTrackHeight)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(AtticSettingsMetrics.sliderKnobShadowAlpha), radius: AtticSettingsMetrics.sliderKnobShadow.radius, y: AtticSettingsMetrics.sliderKnobShadow.y)
                    .frame(width: m.sliderKnob, height: m.sliderKnob)
                    .offset(x: x - m.sliderKnob / 2)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: AtticSettingsMetrics.sliderDrawingHeight)
        .accessibilityHidden(true)
    }
}

/// The small live preview at the top of Appearance: the panel as it will
/// look, over a stand-in desktop, cropped to the part worth showing (the
/// header, the tabs and the first rows). A picture: it is not interactive,
/// and the appearance check judges the panel itself, not this copy.
struct AtticAppearancePreview<Panel: View>: View {
    var height: CGFloat = AtticSettingsMetrics.previewHeight
    var scale: CGFloat = AtticSettingsMetrics.previewScale
    @ViewBuilder let panel: Panel

    @Environment(\.atticDesign) private var design

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AtticRadius.groupCard, style: .continuous)
        ZStack(alignment: .top) {
            AtticStandInWallpaper(dark: design.mode == .dark)
            panel
                .scaleEffect(scale, anchor: .top)
                .frame(width: AtticLayout.panelSize.width * scale, height: AtticLayout.panelSize.height * scale, alignment: .top)
                .shadow(
                    color: .black.opacity(design.mode == .dark ? AtticSettingsMetrics.previewShadowAlphaDark : AtticSettingsMetrics.previewShadowAlphaLight),
                    radius: AtticSettingsMetrics.previewShadow.radius, y: AtticSettingsMetrics.previewShadow.y
                )
                .padding(.top, AtticSettingsMetrics.previewTop)
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
