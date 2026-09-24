import SwiftUI

private struct AtticControlStateKey: EnvironmentKey {
    static let defaultValue: AtticControlState = .rest
}

extension EnvironmentValues {
    /// The state of the control a label sits in (so a disabled label turns ghostly).
    var atticControlState: AtticControlState {
        get { self[AtticControlStateKey.self] }
        set { self[AtticControlStateKey.self] = newValue }
    }
}

// MARK: - Raised button

/// Button style for every raised control: the rim-lit material, hover and
/// press states, a ghost when disabled, and the 2 pt focus ring. State
/// changes are instant (only position and opacity ever animate).
struct AtticRaisedButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        AtticRaisedButtonBody(configuration: configuration, cornerRadius: cornerRadius)
    }
}

private struct AtticRaisedButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let cornerRadius: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.atticForcedState) private var forced
    @State private var hovered = false

    var body: some View {
        let state = AtticStateResolver(
            forced: forced, isEnabled: isEnabled, isHovered: hovered,
            isPressed: configuration.isPressed, isFocused: isFocused
        ).state
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .environment(\.atticControlState, state)
            .background(AtticRaisedBackground(cornerRadius: cornerRadius, state: state))
            .atticFocusRing(state == .focused, cornerRadius: cornerRadius)
            .contentShape(shape)
            .onHover { hovered = $0 }
    }
}

/// A single raised button: pin, All notes, New note, the Settings back
/// button. Icon only (36 × 32 in the panel, 38 × 34 in Settings), or icon
/// and label at the same height.
struct AtticRaisedButton: View {
    let systemName: String?
    let title: String?
    let accessibilityLabel: String
    var size: CGSize = AtticControlSize.panelButton
    var help: String?
    let action: () -> Void

    @State private var probeID = UUID()

    /// Icon only. `label` is what VoiceOver and the tooltip say.
    init(systemName: String, label: String.LocalizationValue, size: CGSize = AtticControlSize.panelButton, help: String? = nil, action: @escaping () -> Void) {
        self.systemName = systemName
        self.title = nil
        self.accessibilityLabel = String(localized: label)
        self.size = size
        self.help = help
        self.action = action
    }

    /// Icon and label.
    init(systemName: String?, title: String.LocalizationValue, height: CGFloat = AtticControlSize.panelButton.height, action: @escaping () -> Void) {
        self.systemName = systemName
        let resolved = String(localized: title)
        self.title = resolved
        self.accessibilityLabel = resolved
        self.size = CGSize(width: 0, height: height)
        self.help = nil
        self.action = action
    }

    var body: some View {
        let radius = AtticRadius.control(height: size.height)
        Button(action: action) {
            AtticRaisedButtonLabel(systemName: systemName, title: title)
                .padding(.horizontal, title == nil ? 0 : AtticRaisedButtonMetrics.labelPadding)
                .frame(width: title == nil ? size.width : nil, height: size.height)
        }
        .buttonStyle(AtticRaisedButtonStyle(cornerRadius: radius))
        .focusEffectDisabled()
        .help(help ?? accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .atticControlProbe(
            title == nil ? "Single button" : "Label button",
            id: probeID,
            expectedSize: title == nil ? size : nil,
            radius: radius,
            expectedRadius: AtticRadius.control(height: size.height)
        )
    }
}

private struct AtticRaisedButtonLabel: View {
    let systemName: String?
    let title: String?
    @Environment(\.atticControlState) private var state

    var body: some View {
        let glyph: AtticInk = state == .disabled ? .disabledIcon : .glyph
        HStack(spacing: AtticRaisedButtonMetrics.iconLabelGap) {
            if let systemName {
                AtticIcon(systemName: systemName, size: title == nil ? AtticControlSize.glyph : AtticRaisedButtonMetrics.labelIconSize, weight: .medium, ink: glyph)
            }
            if let title {
                AtticText(verbatim: title, style: .controlLabel, ink: state == .disabled ? .disabledText : .heading)
            }
        }
    }
}

// MARK: - Page switch (group capsule with nested chips)

/// Icons in one capsule; the selected one also shows its label. Every icon
/// has a tooltip with its shortcut and a VoiceOver label, and announces its
/// selected state. The capsule is 32 tall, radius 10; chips are 24 tall,
/// radius 6 (nested), inset 4.
///
/// Layout never animates. The capsule reserves the widest label, so its
/// size is the same whichever page is selected; switching moves the
/// selection pill and the icons by position and crossfades the labels and
/// the icons' weight by opacity (spec § Performance: only position and
/// opacity animate). The buttons that take clicks and focus sit in a
/// separate, unanimated layer on top.
struct AtticPageSwitch<Page: Hashable>: View {
    struct Item: Identifiable {
        let page: Page
        let systemName: String
        let title: String
        let shortcut: String
        var id: String { title }
    }

    let items: [Item]
    @Binding var selection: Page
    /// The gallery pins a state on one chip only; nil pins it on all.
    var statePinnedPage: Page?

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @FocusState private var focusedPage: Page?
    @State private var hoveredPage: Page?
    @State private var probeID = UUID()

    /// The chip geometry for a selection (also used by the tests).
    struct Geometry: Equatable {
        let selectedWidth: CGFloat
        let unselectedWidth: CGFloat
        let spacing: CGFloat
        let labelWidths: [CGFloat]
        let count: Int

        init(titles: [String]) {
            let m = AtticPageSwitchMetrics.self
            labelWidths = titles.map { AtticTextStyle.chipLabel.measuredWidth($0) }
            unselectedWidth = AtticControlSize.chipIconWidth
            spacing = m.chipSpacing
            selectedWidth = (m.selectedPadding * 2 + m.iconSlot + m.iconLabelGap + (labelWidths.max() ?? 0)).rounded(.up)
            count = titles.count
        }

        /// The capsule's inner width: the same for every selection.
        var innerWidth: CGFloat {
            CGFloat(max(count - 1, 0)) * (unselectedWidth + spacing) + selectedWidth
        }

        func width(of index: Int, selected: Int) -> CGFloat {
            index == selected ? selectedWidth : unselectedWidth
        }

        func x(of index: Int, selected: Int) -> CGFloat {
            CGFloat(index) * (unselectedWidth + spacing) + (index > selected ? selectedWidth - unselectedWidth : 0)
        }

        /// Where chip `index`'s icon sits.
        func iconX(of index: Int, selected: Int) -> CGFloat {
            let m = AtticPageSwitchMetrics.self
            if index == selected {
                let content = m.iconSlot + m.iconLabelGap + labelWidths[index]
                return x(of: index, selected: selected) + ((selectedWidth - content) / 2).rounded()
            }
            return x(of: index, selected: selected) + (unselectedWidth - m.iconSlot) / 2
        }

        /// Where chip `index`'s label sits: its selected place, always (it
        /// only fades, never moves).
        func labelX(of index: Int) -> CGFloat {
            iconX(of: index, selected: index) + AtticPageSwitchMetrics.iconSlot + AtticPageSwitchMetrics.iconLabelGap
        }
    }

    var body: some View {
        let geometry = Geometry(titles: items.map(\.title))
        let selected = items.firstIndex { $0.page == selection } ?? 0
        let chipHeight = AtticControlSize.chipHeight
        ZStack(alignment: .topLeading) {
            // FocusState is read here, in the body, not in the ForEach below.
            decorations(geometry: geometry, selected: selected, focused: focusedPage, hovered: hoveredPage)
                .transaction { $0.animation = nil }
            RoundedRectangle(cornerRadius: AtticRadius.nestedChip, style: .continuous)
                .fill(design.tokens.chipSelected.color)
                .frame(width: geometry.selectedWidth, height: chipHeight)
                .offset(x: geometry.x(of: selected, selected: selected))
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                AtticPageChipFace(item: item, isSelected: index == selected)
                    .offset(x: geometry.iconX(of: index, selected: selected))
                AtticText(verbatim: item.title, style: .chipLabel, ink: .heading)
                    .fixedSize()
                    .frame(height: chipHeight)
                    .opacity(index == selected ? 1 : 0)
                    .transformEnvironment(\.atticProbesDisabled) { if index != selected { $0 = true } }
                    .offset(x: geometry.labelX(of: index))
            }
            hitLayer(geometry: geometry, selected: selected)
                .transaction { $0.animation = nil }
        }
        .frame(width: geometry.innerWidth, height: chipHeight, alignment: .topLeading)
        .padding(AtticControlSize.capsuleInset)
        .frame(height: AtticControlSize.capsuleHeight)
        .background(AtticRaisedBackground(cornerRadius: AtticRadius.control(height: AtticControlSize.capsuleHeight)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Pages"))
        .atticControlProbe(
            "Page switch", id: probeID, expectedSize: nil,
            radius: AtticRadius.control(height: AtticControlSize.capsuleHeight),
            expectedRadius: 10
        )
    }

    private func pinned(_ item: Item) -> AtticControlState? {
        guard statePinnedPage.map({ $0 == item.page }) ?? true else { return nil }
        return forced
    }

    /// Hover fills and focus rings: they follow the chip they belong to,
    /// never animate, and snap to the new layout.
    private func decorations(geometry: Geometry, selected: Int, focused focusedPage: Page?, hovered hoveredPage: Page?) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let pinned = pinned(item)
                let hovered = pinned == .hover || (pinned == nil && hoveredPage == item.page)
                let focused = pinned == .focused || (pinned == nil && focusedPage == item.page)
                let shape = RoundedRectangle(cornerRadius: AtticRadius.nestedChip, style: .continuous)
                shape
                    .fill((hovered && index != selected ? design.tokens.chipHover : .clear).color)
                    .atticFocusRing(focused, cornerRadius: AtticRadius.nestedChip)
                    .frame(width: geometry.width(of: index, selected: selected), height: AtticControlSize.chipHeight)
                    .offset(x: geometry.x(of: index, selected: selected))
            }
        }
    }

    /// The buttons: clicks, focus, tooltips and VoiceOver. Transparent.
    private func hitLayer(geometry: Geometry, selected: Int) -> some View {
        HStack(spacing: geometry.spacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                AtticPageChipButton(
                    item: item,
                    isSelected: index == selected,
                    size: CGSize(width: geometry.width(of: index, selected: selected), height: AtticControlSize.chipHeight),
                    hoveredPage: $hoveredPage
                ) {
                    withAnimation(AtticMotionPreset.pageSwitch.animation(reduceMotion: design.reduceMotion)) {
                        selection = item.page
                    }
                }
                .focused($focusedPage, equals: item.page)
            }
        }
    }
}

/// A chip's icon, drawn in both weights and crossfaded (opacity only).
private struct AtticPageChipFace<Page: Hashable>: View {
    let item: AtticPageSwitch<Page>.Item
    let isSelected: Bool

    var body: some View {
        let m = AtticPageSwitchMetrics.self
        ZStack {
            AtticIcon(systemName: item.systemName, size: m.iconSize, weight: .medium, ink: .glyph)
                .opacity(isSelected ? 1 : 0)
                .transformEnvironment(\.atticProbesDisabled) { if !isSelected { $0 = true } }
            AtticIcon(systemName: item.systemName, size: m.iconSize, weight: .regular, ink: .icon)
                .opacity(isSelected ? 0 : 1)
                .transformEnvironment(\.atticProbesDisabled) { if isSelected { $0 = true } }
        }
        .frame(width: m.iconSlot, height: AtticControlSize.chipHeight)
    }
}

private struct AtticPageChipButton<Page: Hashable>: View {
    let item: AtticPageSwitch<Page>.Item
    let isSelected: Bool
    let size: CGSize
    @Binding var hoveredPage: Page?
    let action: () -> Void

    @State private var probeID = UUID()

    var body: some View {
        Button(action: action) {
            Color.clear
                .frame(width: size.width, height: size.height)
                .contentShape(RoundedRectangle(cornerRadius: AtticRadius.nestedChip, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { inside in
            if inside {
                hoveredPage = item.page
            } else if hoveredPage == item.page {
                hoveredPage = nil
            }
        }
        .help("\(item.title) (\(item.shortcut))")
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .atticControlProbe(
            "Page chip", id: probeID,
            expectedSize: isSelected ? nil : CGSize(width: AtticControlSize.chipIconWidth, height: AtticControlSize.chipHeight),
            radius: AtticRadius.nestedChip,
            expectedRadius: AtticRadius.nested(outer: AtticRadius.control(height: AtticControlSize.capsuleHeight), gap: AtticControlSize.capsuleInset) ?? 0
        )
    }
}

// MARK: - Add bar

/// The add bar: one raised field, 36 tall, radius 11.5. The send button
/// lives inside it and appears only when there is text. Its slot is always
/// reserved, so the field never changes width: the button only fades in
/// with a short rise (opacity and position). Return adds; the bar keeps
/// focus for the next one.
struct AtticAddBar: View {
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticCapture) private var capture
    @Environment(\.atticForcedState) private var forced
    @FocusState private var focused: Bool
    @State private var hovered = false
    @State private var probeID = UUID()
    @State private var fieldProbeID = UUID()

    init(placeholder: String.LocalizationValue, text: Binding<String>, onSubmit: @escaping () -> Void) {
        self.placeholder = String(localized: placeholder)
        self._text = text
        self.onSubmit = onSubmit
    }

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        let m = AtticAddBarMetrics.self
        let height = AtticControlSize.addBarHeight
        let radius = AtticRadius.control(height: height)
        let state = AtticStateResolver(forced: forced, isEnabled: true, isHovered: hovered, isPressed: false, isFocused: false).state
        let send = AtticControlSize.sendButton
        HStack(spacing: m.gap) {
            AtticIcon(systemName: "plus", size: m.plusSize, weight: .medium, ink: state == .disabled ? .disabledIcon : .icon)
            field
                .atticControlProbe("Add bar field", id: fieldProbeID, expectedSize: nil, radius: 0, expectedRadius: 0)
            ZStack {
                if hasText {
                    sendButton(radius: radius)
                        .transition(AtticMotionPreset.popover.transition(reduceMotion: design.reduceMotion, edge: .bottom))
                }
            }
            .frame(width: send.width, height: send.height)
        }
        .padding(.leading, m.leadingPadding)
        .padding(.trailing, AtticControlSize.sendInset)
        .frame(height: height)
        .background(AtticRaisedBackground(cornerRadius: radius, state: state == .hover ? .rest : state))
        .atticFocusRing(state == .focused, cornerRadius: radius)
        .onHover { hovered = $0 }
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion), value: hasText)
        .atticControlProbe("Add bar", id: probeID, expectedSize: nil, radius: radius, expectedRadius: 11.5)
    }

    @ViewBuilder
    private var field: some View {
        if capture != nil {
            Group {
                if text.isEmpty {
                    AtticText(verbatim: placeholder, style: .body, ink: .placeholder)
                } else {
                    AtticText(verbatim: text, style: .body, ink: .body, truncates: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(
                "",
                text: $text,
                prompt: Text(verbatim: placeholder).foregroundStyle(design.tokens.color(.placeholder))
            )
            .textFieldStyle(.plain)
            .font(AtticTextStyle.body.font)
            .foregroundStyle(design.tokens.color(.body))
            .focused($focused)
            .onSubmit(onSubmit)
            .accessibilityLabel(placeholder)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sendButton(radius: CGFloat) -> some View {
        let size = AtticControlSize.sendButton
        let inner = AtticRadius.nested(outer: radius, gap: AtticControlSize.sendInset) ?? radius
        let shape = RoundedRectangle(cornerRadius: inner, style: .continuous)
        return Button(action: onSubmit) {
            AtticIcon(systemName: "arrow.up", size: AtticAddBarMetrics.sendGlyphSize, weight: .semibold, ink: .onInverse)
                .frame(width: size.width, height: size.height)
                .background(shape.fill(design.tokens.color(.inverseFill)))
                .contentShape(shape)
        }
        .buttonStyle(AtticShapeFocusStyle(cornerRadius: inner))
        .focusEffectDisabled()
        .help(String(localized: "Add (Return)"))
        .accessibilityLabel(String(localized: "Add"))
    }
}

// MARK: - Small controls

/// A 28 pt control (radius 9) for the selection bar and other tight spots.
/// Flat inside its raised container: hover and press are fills.
struct AtticSmallButton: View {
    let systemName: String?
    let title: String?
    let accessibilityLabel: String
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovered = false
    @State private var probeID = UUID()

    init(systemName: String?, title: String.LocalizationValue? = nil, label: String.LocalizationValue, action: @escaping () -> Void) {
        self.systemName = systemName
        self.title = title.map { String(localized: $0) }
        self.accessibilityLabel = String(localized: label)
        self.action = action
    }

    var body: some View {
        let height = AtticControlSize.smallHeight
        let radius = AtticRadius.control(height: height)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Button(action: action) {
            AtticSmallButtonFace(systemName: systemName, title: title, radius: radius, hovered: hovered)
                .contentShape(shape)
        }
        .buttonStyle(AtticFlatPressStyle())
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .atticControlProbe("Small control", id: probeID, expectedSize: nil, radius: radius, expectedRadius: 9)
    }
}

/// A plain button that never fades its label when disabled. Components
/// with a designed disabled state draw it with the disabled inks, which
/// meet the contrast rule; the plain style's extra fade would push them
/// below it (the pixel check reads the glyphs, so it would fail).
struct AtticUndimmedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Passes `isPressed` to the face through the environment.
private struct AtticFlatPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.atticIsPressed, configuration.isPressed)
    }
}

private struct AtticIsPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var atticIsPressed: Bool {
        get { self[AtticIsPressedKey.self] }
        set { self[AtticIsPressedKey.self] = newValue }
    }
}

private struct AtticSmallButtonFace: View {
    let systemName: String?
    let title: String?
    let radius: CGFloat
    let hovered: Bool

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @Environment(\.atticIsPressed) private var isPressed
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let tokens = design.tokens
        let state = AtticStateResolver(forced: forced, isEnabled: isEnabled, isHovered: hovered, isPressed: isPressed, isFocused: isFocused).state
        let fill: AtticRGBA = switch state {
        case .hover: tokens.chipHover
        case .pressed: tokens.chipSelected
        default: .clear
        }
        let ink: AtticInk = state == .disabled ? .disabledIcon : .glyph
        HStack(spacing: AtticSmallControlMetrics.iconLabelGap) {
            if let systemName {
                AtticIcon(systemName: systemName, size: AtticSmallControlMetrics.iconSize, weight: .regular, ink: ink)
            }
            if let title {
                AtticText(verbatim: title, style: .controlLabel, ink: state == .disabled ? .disabledText : .heading)
            }
        }
        .padding(.horizontal, title == nil ? 0 : AtticSmallControlMetrics.labelPadding)
        .frame(minWidth: AtticControlSize.smallMinWidth, minHeight: AtticControlSize.smallHeight, maxHeight: AtticControlSize.smallHeight)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill.color))
        .atticFocusRing(state == .focused, cornerRadius: radius)
    }
}

/// The selection bar: a raised capsule that floats above a multi-selection
/// with the count and state, priority, tag, move and delete.
struct AtticSelectionBar: View {
    struct Action: Identifiable {
        let systemName: String
        let label: String.LocalizationValue
        let handler: () -> Void
        var id: String { systemName }
    }

    let count: Int
    let actions: [Action]

    @State private var probeID = UUID()

    var body: some View {
        let height = AtticControlSize.smallHeight + AtticControlSize.capsuleInset * 2
        let radius = AtticRadius.control(height: height)
        HStack(spacing: AtticSelectionBarMetrics.controlSpacing) {
            AtticText(verbatim: String(localized: "\(count) selected"), style: .controlLabel, ink: .body)
                .padding(.leading, AtticSelectionBarMetrics.countLeading)
                .padding(.trailing, AtticSelectionBarMetrics.countTrailing)
            ForEach(actions) { action in
                AtticSmallButton(systemName: action.systemName, label: action.label, action: action.handler)
            }
        }
        .padding(AtticControlSize.capsuleInset)
        .frame(height: height)
        .background(AtticPopoverBackground(cornerRadius: radius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "\(count) selected"))
        .atticControlProbe("Selection bar", id: probeID, expectedSize: nil, radius: radius, expectedRadius: 11.5)
    }
}

// MARK: - Menus

/// One command in a native menu: a title menu, a "More" button, a context
/// menu. Menus stay the system's own (native first: keyboard navigation,
/// type-to-select, VoiceOver, system timing); Attic only chooses their
/// content and the control that opens them.
struct AtticMenuCommand: Identifiable {
    let id = UUID()
    let title: String
    var systemImage: String?
    var shortcut: KeyboardShortcut?
    var isDestructive = false
    var isDisabled = false
    /// Starts a new section (the system draws its separator).
    var startsSection = false
    let action: () -> Void

    init(
        _ title: String.LocalizationValue,
        systemImage: String? = nil,
        shortcut: KeyboardShortcut? = nil,
        isDestructive: Bool = false,
        isDisabled: Bool = false,
        startsSection: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = String(localized: title)
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.isDestructive = isDestructive
        self.isDisabled = isDisabled
        self.startsSection = startsSection
        self.action = action
    }
}

/// A native menu (SwiftUI `Menu`, an `NSMenu` underneath) opened by an
/// Attic-drawn label. In captures, where `ImageRenderer` cannot draw
/// AppKit, only the label is drawn.
struct AtticCommandMenu<Label: View>: View {
    let commands: [AtticMenuCommand]
    let accessibilityLabel: String
    @ViewBuilder let label: Label

    @Environment(\.atticCapture) private var capture

    var body: some View {
        if capture != nil {
            label
        } else {
            Menu {
                ForEach(commands) { command in
                    if command.startsSection, command.id != commands.first?.id {
                        Divider()
                    }
                    item(command)
                }
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(accessibilityLabel)
        }
    }

    @ViewBuilder
    private func item(_ command: AtticMenuCommand) -> some View {
        let button = Button(role: command.isDestructive ? .destructive : nil, action: command.action) {
            if let systemImage = command.systemImage {
                SwiftUI.Label(command.title, systemImage: systemImage)
            } else {
                Text(command.title)
            }
        }
        .disabled(command.isDisabled)
        if let shortcut = command.shortcut {
            button.keyboardShortcut(shortcut)
        } else {
            button
        }
    }
}

/// A title that opens its item's native menu (spec § Minimalism: anything
/// rarer lives behind one button, usually the item's title). 28 tall,
/// radius 9, a hover fill, the heading and a small chevron.
struct AtticTitleMenu: View {
    let title: String
    let commands: [AtticMenuCommand]

    var body: some View {
        AtticCommandMenu(commands: commands, accessibilityLabel: title) {
            AtticTitleMenuFace(title: title)
        }
    }
}

private struct AtticTitleMenuFace: View {
    let title: String

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @State private var hovered = false
    @State private var probeID = UUID()

    var body: some View {
        let m = AtticTitleMenuMetrics.self
        let radius = AtticRadius.control(height: m.height)
        let hover = forced == .hover || hovered
        HStack(spacing: m.gap) {
            AtticText(verbatim: title, style: .panelHeading, ink: .heading, truncates: true)
            AtticIcon(systemName: "chevron.down", size: m.chevronSize, weight: .semibold, ink: .chevron)
        }
        .padding(.horizontal, m.horizontalPadding)
        .frame(height: m.height)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill((hover ? design.tokens.chipHover : .clear).color))
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .onHover { hovered = $0 }
        .atticControlProbe("Title menu", id: probeID, expectedSize: CGSize(width: 0, height: m.height), radius: radius, expectedRadius: 9)
    }
}

// MARK: - Pop-overs

/// A choice row inside one of Attic's own pop-overs: genuine pop-over
/// content such as the link picker's results or ⌘K's list, never a command
/// menu (those are native, `AtticCommandMenu`). 28 tall, radius 9; the
/// hovered row, or the one the list's keyboard selection is on, takes the
/// selection fill.
struct AtticPopoverRow: View {
    let systemName: String?
    let title: String
    /// A quiet trailing detail ("Note", "Canvas").
    var detail: String?
    /// The list's keyboard selection is on this row.
    var isHighlighted = false
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    @State private var probeID = UUID()

    init(systemName: String?, title: String, detail: String? = nil, isHighlighted: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName
        self.title = title
        self.detail = detail
        self.isHighlighted = isHighlighted
        self.action = action
    }

    var body: some View {
        let m = AtticPopoverMetrics.self
        let height = AtticControlSize.smallHeight
        let radius = AtticRadius.control(height: height)
        let state = AtticStateResolver(forced: forced, isEnabled: isEnabled, isHovered: hovered, isPressed: false, isFocused: false).state
        let tokens = design.tokens
        let fill: AtticRGBA = switch state {
        case .disabled: .clear
        case .pressed: tokens.pressed
        case .hover, .focused: tokens.selected
        case .rest: isHighlighted ? tokens.selected : .clear
        }
        Button(action: action) {
            HStack(spacing: m.rowGap) {
                if let systemName {
                    AtticIcon(systemName: systemName, size: m.rowIconSize, ink: state == .disabled ? .disabledIcon : .icon)
                        .frame(width: m.rowIconSlot)
                }
                AtticText(verbatim: title, style: .menuRow, ink: state == .disabled ? .disabledText : .body, truncates: true)
                Spacer(minLength: m.trailingMinGap)
                if let detail {
                    AtticText(verbatim: detail, style: .shortcut, ink: state == .disabled ? .disabledText : .helper)
                }
            }
            .padding(.horizontal, m.rowPadding)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill.color))
            .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .onHover { hovered = $0 }
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .atticControlProbe("Pop-over row", id: probeID, expectedSize: nil, radius: radius, expectedRadius: 9)
    }
}

/// The container for Attic's own pop-overs (radius 20, 6 pt padding),
/// raised over content. Only for genuine pop-over content (a picker, a
/// search list, a preview); command menus are native (`AtticCommandMenu`).
struct AtticPopover<Content: View>: View {
    var width: CGFloat = AtticPopoverMetrics.defaultWidth
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(AtticPopoverMetrics.padding)
            .frame(width: width)
            .background(AtticPopoverBackground(cornerRadius: AtticRadius.popover))
    }
}

/// A quiet grouping gap inside a pop-over (space, not a line).
struct AtticPopoverGap: View {
    var body: some View { Color.clear.frame(height: AtticPopoverMetrics.groupGap).accessibilityHidden(true) }
}
