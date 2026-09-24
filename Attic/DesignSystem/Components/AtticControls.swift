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
                .padding(.horizontal, title == nil ? 0 : 12)
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
        let glyph: AtticInk = state == .disabled ? .disabled : .glyph
        HStack(spacing: 6) {
            if let systemName {
                AtticIcon(systemName: systemName, size: title == nil ? AtticControlSize.glyph : 13, weight: .medium, ink: glyph)
            }
            if let title {
                AtticText(verbatim: title, style: .controlLabel, ink: state == .disabled ? .disabled : .heading)
            }
        }
    }
}

// MARK: - Page switch (group capsule with nested chips)

/// Icons in one capsule; the selected one also shows its label. Every icon
/// has a tooltip with its shortcut and a VoiceOver label, and announces its
/// selected state. The capsule is 32 tall, radius 10; chips are 24 tall,
/// radius 6 (nested), inset 4.
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
    @State private var probeID = UUID()

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                AtticPageChip(item: item, isSelected: item.page == selection, takesPinnedState: statePinnedPage.map { $0 == item.page } ?? true) {
                    withAnimation(AtticMotionPreset.pageSwitch.animation(reduceMotion: design.reduceMotion)) {
                        selection = item.page
                    }
                }
            }
        }
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
}

private struct AtticPageChip<Page: Hashable>: View {
    let item: AtticPageSwitch<Page>.Item
    let isSelected: Bool
    let takesPinnedState: Bool
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @Environment(\.isFocused) private var isFocused
    @State private var hovered = false
    @State private var probeID = UUID()

    var body: some View {
        let tokens = design.tokens
        let state = AtticStateResolver(forced: takesPinnedState ? forced : nil, isEnabled: true, isHovered: hovered, isPressed: false, isFocused: isFocused).state
        let shape = RoundedRectangle(cornerRadius: AtticRadius.nestedChip, style: .continuous)
        let fill: AtticRGBA = isSelected ? tokens.chipSelected : (state == .hover ? tokens.chipHover : .clear)
        Button(action: action) {
            HStack(spacing: 5) {
                AtticIcon(systemName: item.systemName, size: 13, weight: isSelected ? .medium : .regular, ink: isSelected ? .glyph : .icon)
                if isSelected {
                    AtticText(verbatim: item.title, style: .chipLabel, ink: .heading)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, isSelected ? 9 : 0)
            .frame(minWidth: AtticControlSize.chipIconWidth, minHeight: AtticControlSize.chipHeight, maxHeight: AtticControlSize.chipHeight)
            .background(shape.fill(fill.color))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .atticFocusRing(state == .focused, cornerRadius: AtticRadius.nestedChip)
        .onHover { hovered = $0 }
        .help("\(item.title) (\(item.shortcut))")
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .atticControlProbe(
            "Page chip", id: probeID,
            expectedSize: isSelected ? nil : CGSize(width: AtticControlSize.chipIconWidth, height: AtticControlSize.chipHeight),
            radius: AtticRadius.nestedChip,
            expectedRadius: AtticRadius.nested(outer: 10, gap: AtticControlSize.capsuleInset) ?? 0
        )
    }
}

// MARK: - Add bar

/// The add bar: one raised field, 36 tall, radius 11.5. The send button
/// lives inside it and appears only when there is text (fading in with a
/// short move). Return adds; the bar keeps focus for the next one.
struct AtticAddBar: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    @Environment(\.atticDesign) private var design
    @Environment(\.atticCapture) private var capture
    @Environment(\.atticForcedState) private var forced
    @FocusState private var focused: Bool
    @State private var hovered = false
    @State private var probeID = UUID()

    init(placeholder: String.LocalizationValue, text: Binding<String>, onSubmit: @escaping () -> Void = {}) {
        self.placeholder = String(localized: placeholder)
        self._text = text
        self.onSubmit = onSubmit
    }

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        let height = AtticControlSize.addBarHeight
        let radius = AtticRadius.control(height: height)
        let state = AtticStateResolver(forced: forced, isEnabled: true, isHovered: hovered, isPressed: false, isFocused: false).state
        HStack(spacing: 8) {
            AtticIcon(systemName: "plus", size: 12.5, weight: .medium, ink: state == .disabled ? .disabled : .icon)
            field
            if hasText {
                sendButton(radius: radius)
                    .transition(AtticMotionPreset.popover.transition(reduceMotion: design.reduceMotion, edge: .bottom))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, hasText ? AtticControlSize.sendInset : 12)
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
                    AtticText(verbatim: text, style: .body, ink: .body)
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
        }
    }

    private func sendButton(radius: CGFloat) -> some View {
        let size = AtticControlSize.sendButton
        let inner = AtticRadius.nested(outer: radius, gap: AtticControlSize.sendInset) ?? radius
        return Button(action: onSubmit) {
            AtticIcon(systemName: "arrow.up", size: 12, weight: .semibold, ink: .onInverse)
                .frame(width: size.width, height: size.height)
                .background(
                    RoundedRectangle(cornerRadius: inner, style: .continuous)
                        .fill(design.tokens.color(.inverseFill))
                )
                .contentShape(RoundedRectangle(cornerRadius: inner, style: .continuous))
        }
        .buttonStyle(.plain)
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
        let ink: AtticInk = state == .disabled ? .disabled : .glyph
        HStack(spacing: 5) {
            if let systemName {
                AtticIcon(systemName: systemName, size: 13, weight: .regular, ink: ink)
            }
            if let title {
                AtticText(verbatim: title, style: .controlLabel, ink: state == .disabled ? .disabled : .heading)
            }
        }
        .padding(.horizontal, title == nil ? 0 : 9)
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
        HStack(spacing: 2) {
            AtticText(verbatim: String(localized: "\(count) selected"), style: .controlLabel, ink: .body)
                .padding(.leading, 10)
                .padding(.trailing, 6)
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

/// A row in Attic's own menus and pop-overs (the system's context menus stay
/// native). 28 tall, radius 9; the hovered or keyboard-selected row is the
/// selection fill.
struct AtticMenuRow: View {
    let systemName: String?
    let title: String
    var shortcut: String?
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    @State private var probeID = UUID()

    init(systemName: String?, title: String.LocalizationValue, shortcut: String? = nil, action: @escaping () -> Void) {
        self.systemName = systemName
        self.title = String(localized: title)
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        let height = AtticControlSize.smallHeight
        let radius = AtticRadius.control(height: height)
        let state = AtticStateResolver(forced: forced, isEnabled: isEnabled, isHovered: hovered, isPressed: false, isFocused: false).state
        let tokens = design.tokens
        let fill: AtticRGBA = switch state {
        case .hover, .focused: tokens.selected
        case .pressed: tokens.pressed
        default: .clear
        }
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemName {
                    AtticIcon(systemName: systemName, size: 13, ink: state == .disabled ? .disabled : .icon)
                        .frame(width: 16)
                }
                AtticText(verbatim: title, style: .menuRow, ink: state == .disabled ? .disabled : .body)
                Spacer(minLength: 16)
                if let shortcut {
                    AtticText(verbatim: shortcut, style: .shortcut, ink: state == .disabled ? .disabled : .helper)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill.color))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .atticControlProbe("Menu row", id: probeID, expectedSize: nil, radius: radius, expectedRadius: 9)
    }
}

/// A pop-over or menu container: radius 20, 6 pt padding.
struct AtticMenu<Content: View>: View {
    var width: CGFloat = 220
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(6)
            .frame(width: width)
            .background(AtticPopoverBackground(cornerRadius: AtticRadius.menu))
    }
}

/// A quiet grouping gap inside a menu (space, not a line).
struct AtticMenuGap: View {
    var body: some View { Color.clear.frame(height: 6).accessibilityHidden(true) }
}
