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

/// Button style for every raised control: Liquid Glass (or the Craft-style
/// recipe), hover and press states, a ghost when disabled, and the 2 pt
/// focus ring. State changes are instant (only position and opacity ever
/// animate; interactive glass adds the system's own press response).
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
            .atticRaisedMaterial(cornerRadius: cornerRadius, state: state, interactive: state != .disabled)
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
    /// A toggle that is on (the pinned pin): the button draws the same
    /// inner chip as the page switch's selected page, inside its own
    /// material (an overlay outside the glass does not render in a glass
    /// group), and its glyph takes the selected page's ink.
    var isSelected = false
    /// An optical nudge of the glyph inside the button (the pin: −0.5,
    /// visual A), so its visible outline looks centred.
    var glyphOffsetY: CGFloat = 0
    /// The header's glyphs (Phase 0's qualities): the strong ink at regular
    /// weight, level with the page button's current page.
    var emphasisedGlyph = false
    let action: () -> Void

    @State private var probeID = UUID()

    /// Icon only. `label` is what VoiceOver and the tooltip say.
    init(systemName: String, label: String.LocalizationValue, size: CGSize = AtticControlSize.panelButton, help: String? = nil,
         isSelected: Bool = false, glyphOffsetY: CGFloat = 0, emphasisedGlyph: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName
        self.title = nil
        self.accessibilityLabel = String(localized: label)
        self.size = size
        self.help = help
        self.isSelected = isSelected
        self.glyphOffsetY = glyphOffsetY
        self.emphasisedGlyph = emphasisedGlyph
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
            AtticRaisedButtonLabel(systemName: systemName, title: title, isSelected: isSelected || emphasisedGlyph)
                .offset(y: glyphOffsetY)
                .padding(.horizontal, title == nil ? 0 : AtticRaisedButtonMetrics.labelPadding)
                .frame(width: title == nil ? size.width : nil, height: size.height)
                .background {
                    if isSelected {
                        AtticSelectedChip(outerHeight: size.height)
                    }
                }
        }
        .buttonStyle(AtticRaisedButtonStyle(cornerRadius: radius))
        .focusEffectDisabled()
        .help(help ?? accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
    var isSelected = false
    @Environment(\.atticControlState) private var state

    var body: some View {
        // Icons are lighter and thinner than text (v4): the secondary icon
        // colour in a light outline weight. Pressed or selected, the glyph
        // takes the primary colour, as the page switch's selected page does.
        let glyph: AtticInk = switch state {
        case .disabled: .disabledIcon
        case .pressed: .glyph
        default: isSelected ? .glyph : .icon
        }
        HStack(spacing: AtticRaisedButtonMetrics.iconLabelGap) {
            if let systemName {
                // Selected (the pinned pin), the glyph is regular weight, as
                // the page switch's selected icon is (visual A).
                AtticIcon(systemName: systemName, size: title == nil ? AtticControlSize.raisedGlyph : AtticRaisedButtonMetrics.labelIconSize,
                          weight: isSelected ? .regular : AtticIconWeight.outline, ink: glyph)
            }
            if let title {
                AtticText(verbatim: title, style: .controlLabel, ink: state == .disabled ? .disabledText : .heading)
            }
        }
    }
}

/// The selected chip nested inside a raised control: the page switch's
/// selected page and a selected raised button (the pinned pin) draw the
/// same one, `capsuleInset` inside the control, radius nested.
struct AtticSelectedChip: View {
    var outerHeight: CGFloat = AtticControlSize.capsuleHeight
    @Environment(\.atticDesign) private var design

    var body: some View {
        let inset = AtticControlSize.capsuleInset
        let radius = AtticRadius.nested(outer: AtticRadius.control(height: outerHeight), gap: inset) ?? AtticRadius.nestedChip
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(design.tokens.chipSelected.color)
            .padding(inset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Page button (collapsed page dock)

/// The header's page button (Phase 0's mode dock, brought into Direction
/// A, 2026-09-26): at rest a square the size and shape of the pin, showing
/// only the current page's icon on the selected inner chip. Under the
/// pointer or keyboard focus it opens leftward into all the pages' icons
/// (the current one on the chip, each with a tooltip and its shortcut); a
/// click goes there, and it folds back when the pointer leaves. 36 pt,
/// inset 4, 28 pt segments 2 apart: 36 wide shut, 96 open.
///
/// One control for the keyboard (← → move between pages while it has
/// focus; ⌘1–⌘3 work from anywhere). VoiceOver reads one group, "Pages",
/// with a named button per page (the current one selected), whether the
/// button is open or shut, like the page tabs under it.
struct AtticPageButton<Page: Hashable>: View {
    struct Item: Identifiable {
        let page: Page
        let systemName: String
        let title: String
        /// The shortcut as the tooltip shows it ("⌘1").
        let shortcut: String
        /// The key that selects this page with ⌘ (live only).
        var keyEquivalent: KeyEquivalent?
        /// For UI tests and automation.
        var accessibilityIdentifier: String?
        var id: String { title }
    }

    let items: [Item]
    @Binding var selection: Page
    /// The gallery and captures pin it open (or shut); nil follows the
    /// pointer and focus.
    var pinnedOpen: Bool?
    /// The pointer arrived: the caller can build the other pages early.
    var onApproach: () -> Void = {}

    @Environment(\.atticDesign) private var design
    @Environment(\.atticCapture) private var capture
    @Environment(\.atticKeyboardFocusVisible) private var keyboardFocusVisible
    @FocusState private var focused: Bool
    @State private var hovering = false
    @State private var hoveredPage: Page?
    @State private var probeID = UUID()

    private typealias M = AtticPageButtonMetrics

    private var isOpen: Bool {
        pinnedOpen ?? (hovering || (focused && keyboardFocusVisible))
    }

    var body: some View {
        let open = isOpen
        let selected = items.firstIndex { $0.page == selection } ?? 0
        let size = AtticControlSize.headerControl
        let radius = AtticRadius.control(height: size)
        let chipRadius = AtticRadius.nested(outer: radius, gap: M.inset) ?? radius
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let isSelected = index == selected
                let visible = open || isSelected
                if index > 0 {
                    Color.clear.frame(width: open ? M.gap : 0, height: M.segment)
                }
                Button { select(item.page) } label: {
                    ZStack {
                        let shape = RoundedRectangle(cornerRadius: chipRadius, style: .continuous)
                        let accent = design.tokens.pageChipAccent
                        if isSelected, let accent {
                            // Phase 0's Light palettes: the current page in the accent.
                            shape.fill(accent.fill.color)
                            shape.inset(by: M.accentStrokeWidth / 2).stroke(accent.stroke.color, lineWidth: M.accentStrokeWidth)
                        } else if isSelected {
                            shape.fill(design.tokens.chipSelected.color)
                        } else if hoveredPage == item.page {
                            shape.fill(design.tokens.chipHover.color)
                        }
                        AtticIcon(systemName: item.systemName, size: M.iconSize,
                                  weight: isSelected ? .regular : AtticIconWeight.outline,
                                  ink: isSelected ? (accent == nil ? .glyph : .accent) : .icon)
                    }
                    .frame(width: M.segment, height: M.segment)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .keyboardShortcut(item.keyEquivalent.map { KeyboardShortcut($0, modifiers: .command) })
                .help("\(item.title) (\(item.shortcut))")
                .onHover { inside in
                    if inside { hoveredPage = item.page } else if hoveredPage == item.page { hoveredPage = nil }
                }
                .frame(width: visible ? M.segment : 0, height: M.segment, alignment: .trailing)
                // Folded away, a page is zero wide and all but transparent:
                // not 0, which would drop it from VoiceOver.
                .opacity(visible ? 1 : 0.001)
                .clipped()
                .allowsHitTesting(visible)
                .transformEnvironment(\.atticProbesDisabled) { if !visible { $0 = true } }
                .accessibilityLabel(item.title)
                .accessibilityIdentifier(item.accessibilityIdentifier ?? item.title)
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(M.inset)
        .frame(height: size)
        .atticRaisedMaterial(cornerRadius: radius, interactive: false)
        .atticFocusRing(capture == nil && focused && keyboardFocusVisible, cornerRadius: radius)
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .onHover { inside in
            hovering = inside
            if inside { onApproach() } else { hoveredPage = nil }
        }
        .animation(design.reduceMotion ? nil : .spring(duration: AtticMotionPreset.expand.duration, bounce: 0), value: open)
        // A Tab stop like a button: only when keyboard navigation is on,
        // so the panel never opens it by focusing it when revealed.
        .focusable(capture == nil, interactions: .activate)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            guard let next = AtticPageArrows.next(from: selected, key: press.key, modifiers: press.modifiers, count: items.count)
            else { return .ignored }
            if next != selected { select(items[next].page) }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Pages"))
        .atticControlProbe("Page button", id: probeID, expectedSize: open ? nil : CGSize(width: size, height: size),
                           radius: radius, expectedRadius: AtticRadius.control(height: size))
    }

    private func select(_ page: Page) {
        withAnimation(AtticMotionPreset.pageSwitch.animation(reduceMotion: design.reduceMotion)) {
            selection = page
        }
    }

    /// The width it takes shut and open (the header's hit testing).
    static func width(open: Bool, count: Int) -> CGFloat {
        let segments = open ? CGFloat(count) : 1
        return M.inset * 2 + segments * M.segment + (open ? CGFloat(max(count - 1, 0)) * M.gap : 0)
    }
}

// MARK: - Add bar

/// The add bar: one raised field, 36 tall, radius 15. The send button
/// lives inside it and appears only when there is text. Its slot is always
/// reserved, so the field never changes width: the button only fades in
/// with a short rise (opacity and position). Return adds; the bar keeps
/// focus for the next one.
struct AtticAddBar: View {
    /// The chip-drawing field (Phase 1, logged in `CHANGELOG.md`): what it
    /// draws as chips, its focus and what it reports.
    struct Tokens {
        var chips: [NSRange]
        var isFocused: Binding<Bool>
        var actions: AtticTokenFieldActions
    }

    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void
    /// The leading glyph: `plus` for adding, `magnifyingglass` when the bar
    /// searches (the Done log).
    var systemImage = "plus"
    /// Searching has nothing to send: the button never appears.
    var showsSend = true
    /// Live only: the native field that draws recognised pieces as chips.
    /// Captures (and the gallery) keep the plain field.
    var tokens: Tokens?

    @Environment(\.atticDesign) private var design
    @Environment(\.atticCapture) private var capture
    @Environment(\.atticForcedState) private var forced
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.atticKeyboardFocusVisible) private var keyboardFocusVisible
    @FocusState private var focused: Bool
    @State private var hovered = false
    @State private var probeID = UUID()
    @State private var fieldProbeID = UUID()

    init(placeholder: String.LocalizationValue, text: Binding<String>, onSubmit: @escaping () -> Void) {
        self.placeholder = String(localized: placeholder)
        self._text = text
        self.onSubmit = onSubmit
    }

    /// The live page's bar: a placeholder chosen at run time, the chip
    /// field, and a glyph for the bar's job.
    init(placeholder: String, text: Binding<String>, systemImage: String = "plus", showsSend: Bool = true,
         tokens: Tokens?, onSubmit: @escaping () -> Void) {
        self.placeholder = placeholder
        self._text = text
        self.systemImage = systemImage
        self.showsSend = showsSend
        self.tokens = tokens
        self.onSubmit = onSubmit
    }

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var isFieldFocused: Bool {
        if capture == nil, let tokens { return tokens.isFocused.wrappedValue }
        return focused
    }

    var body: some View {
        let m = AtticAddBarMetrics.self
        let height = AtticControlSize.addBarHeight
        let radius = AtticRadius.control(height: height)
        // The field's own keyboard focus and the environment's enabled
        // state; the gallery's pinned states override both. The ring shows
        // only while the keyboard is driving (a click into the field, or
        // the panel opening with the bar focused, draws none).
        let state = AtticStateResolver(forced: forced, isEnabled: isEnabled, isHovered: hovered, isPressed: false,
                                       isFocused: isFieldFocused && keyboardFocusVisible).state
        let send = AtticControlSize.sendButton
        HStack(spacing: m.gap) {
            AtticIcon(systemName: systemImage, size: m.plusSize, weight: AtticIconWeight.outline, ink: state == .disabled ? .disabledIcon : .icon)
                .frame(width: m.iconSlot)
            field(disabled: state == .disabled)
                .atticControlProbe("Add bar field", id: fieldProbeID, expectedSize: nil, radius: 0, expectedRadius: 0)
            // Built with the bar and only shown when there is text: the
            // first keystroke changes an opacity and an offset instead of
            // building the button (spec: one frame per keystroke).
            ZStack {
                if showsSend {
                    let shown = hasText
                    sendButton(radius: radius)
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown || design.reduceMotion ? 0 : AtticMotionPreset.popover.rise)
                        .allowsHitTesting(shown)
                        .disabled(!shown)
                        .accessibilityHidden(!shown)
                        .transformEnvironment(\.atticProbesDisabled) { if !shown { $0 = true } }
                }
            }
            .frame(width: send.width, height: send.height)
        }
        .padding(.leading, m.leadingPadding)
        .padding(.trailing, AtticControlSize.sendInset)
        .frame(height: height)
        .atticRaisedMaterial(cornerRadius: radius, state: state == .hover ? .rest : state, interactive: false)
        .atticFocusRing(state == .focused, cornerRadius: radius)
        .onHover { hovered = $0 }
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion), value: hasText)
        .atticControlProbe("Add bar", id: probeID, expectedSize: nil, radius: radius, expectedRadius: 15)
    }

    @ViewBuilder
    private func field(disabled: Bool) -> some View {
        if capture == nil, let tokens {
            AtticTokenField(
                text: $text,
                chips: tokens.chips,
                isFocused: tokens.isFocused,
                accessibilityLabel: placeholder,
                isEnabled: !disabled,
                actions: tokens.actions
            )
            .frame(height: AtticTokenFieldMetrics.height)
            .overlay(alignment: .leading) {
                if text.isEmpty {
                    AtticText(verbatim: placeholder, style: .listBody, ink: disabled ? .disabledText : .placeholder)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if capture != nil, let tokens, !text.isEmpty {
            // Captures draw the chips as SwiftUI (the native field can't
            // render in a capture).
            AtticChipText(text: text, chips: tokens.chips, disabled: disabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if capture != nil {
            Group {
                if text.isEmpty {
                    AtticText(verbatim: placeholder, style: .listBody, ink: disabled ? .disabledText : .placeholder)
                } else {
                    AtticText(verbatim: text, style: .listBody, ink: disabled ? .disabledText : .body, truncates: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(
                "",
                text: $text,
                prompt: Text(verbatim: placeholder).foregroundStyle(design.tokens.color(disabled ? .disabledText : .placeholder))
            )
            .textFieldStyle(.plain)
            .font(AtticTextStyle.listBody.font)
            .foregroundStyle(design.tokens.color(disabled ? .disabledText : .body))
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
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .atticOwnFocusRing(.rounded(radius: inner))
        .help(String(localized: "Add (Return)"))
        .accessibilityLabel(String(localized: "Add"))
    }
}

// MARK: - Search field

/// A search row at the top of the list it searches (the Done page; owner,
/// 2026-09-26): no box, one row tall. A 13 pt magnifier in the secondary
/// ink centred on the circles' line, the placeholder (secondary) and the
/// typed text (primary) on the titles' line in the list's rounded face,
/// the row's hover highlight, and a small clear button on the right once
/// there is text. Its focus is a binding, so Search from the menu bar can
/// put the keyboard in it; Esc clears the text, then leaves the field.
struct AtticListSearchField: View {
    let placeholder: String
    @Binding var text: String
    var isFocused: Binding<Bool>?

    @Environment(\.atticDesign) private var design
    @Environment(\.atticCapture) private var capture
    @Environment(\.atticForcedState) private var forced
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        let m = AtticListSearchFieldMetrics.self
        let tokens = design.tokens
        let hover = forced == .hover || hovered
        ZStack(alignment: .leading) {
            if hover {
                AtticHighlight(fill: tokens.hover, run: .single)
                    .frame(height: AtticLayout.rowHighlightHeight)
                    .padding(.horizontal, AtticLayout.rowHighlightInset)
            }
            AtticIcon(systemName: "magnifyingglass", size: m.iconSize, weight: AtticIconWeight.outline, ink: .helper)
                .frame(width: AtticControlSize.statusCircle)
                .padding(.leading, AtticLayout.circleX)
            HStack(spacing: AtticTaskRowMetrics.trailingMinGap) {
                if capture == nil {
                    TextField("", text: $text, prompt: Text(verbatim: placeholder).foregroundStyle(tokens.color(.helper)))
                        .textFieldStyle(.plain)
                        .font(AtticTextStyle.listBody.font)
                        .foregroundStyle(tokens.color(.heading))
                        .focused($focused)
                        .onExitCommand {
                            if text.isEmpty { focused = false } else { text = "" }
                        }
                        .accessibilityLabel(placeholder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    AtticText(verbatim: text.isEmpty ? placeholder : text, style: .listBody, ink: text.isEmpty ? .helper : .heading, truncates: true)
                    Spacer(minLength: 0)
                }
                if !text.isEmpty {
                    Button { text = "" } label: {
                        AtticIcon(systemName: "xmark.circle.fill", size: m.clearSize, weight: .regular, ink: .helper)
                            .frame(width: AtticControlSize.minimumHitTarget - 8, height: AtticControlSize.minimumHitTarget - 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Clear search"))
                    .accessibilityLabel(String(localized: "Clear search"))
                }
            }
            .padding(.leading, AtticLayout.textX)
            .padding(.trailing, AtticLayout.rowHighlightInset + AtticTaskRowMetrics.dateInset)
        }
        .frame(height: AtticLayout.rowPitch)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { focused = true }
        .onAppear { if isFocused?.wrappedValue == true { focused = true } }
        .onChange(of: focused) { _, now in if isFocused?.wrappedValue != now { isFocused?.wrappedValue = now } }
        .onChange(of: isFocused?.wrappedValue) { _, wanted in
            if let wanted, wanted != focused { focused = wanted }
        }
    }
}

// MARK: - Small controls

/// A 28 pt control (radius 12) for the selection bar and other tight spots.
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
        .atticControlProbe("Small control", id: probeID, expectedSize: nil, radius: radius, expectedRadius: 12)
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

/// The selection bar: a raised (glass) capsule that floats above a multi-selection
/// with the count and state, priority, tag, move and delete.
struct AtticSelectionBar: View {
    struct Action: Identifiable {
        let systemName: String
        let label: String.LocalizationValue
        let handler: () -> Void
        /// A choice (state, priority, tag): the button opens this native
        /// menu instead of acting (Phase 1).
        var menu: [AtticMenuCommand] = []
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
                if action.menu.isEmpty {
                    AtticSmallButton(systemName: action.systemName, label: action.label, action: action.handler)
                } else {
                    AtticCommandMenu(commands: action.menu, accessibilityLabel: String(localized: action.label)) {
                        AtticSmallButton(systemName: action.systemName, label: action.label, action: {})
                            .allowsHitTesting(false)
                    }
                    .help(String(localized: action.label))
                }
            }
        }
        .padding(AtticControlSize.capsuleInset)
        .frame(height: height)
        .atticRaisedMaterial(cornerRadius: radius, interactive: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "\(count) selected"))
        .atticControlProbe("Selection bar", id: probeID, expectedSize: nil, radius: radius, expectedRadius: 15)
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
        self.init(verbatim: String(localized: title), systemImage: systemImage, shortcut: shortcut, isDestructive: isDestructive,
                  isDisabled: isDisabled, startsSection: startsSection, action: action)
    }

    /// A title already localized (a switched Phase 1 label).
    init(
        verbatim title: String,
        systemImage: String? = nil,
        shortcut: KeyboardShortcut? = nil,
        isDestructive: Bool = false,
        isDisabled: Bool = false,
        startsSection: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
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
                AtticMenuItems(commands: commands)
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
}

/// The items of a native menu built from commands: sections separated by the
/// system's own divider, each item with its symbol and its shortcut shown
/// (spec: right-click menus show shortcuts too). Used by `AtticCommandMenu`
/// and inside `.contextMenu`.
struct AtticMenuItems: View {
    let commands: [AtticMenuCommand]

    var body: some View {
        ForEach(commands) { command in
            if command.startsSection, command.id != commands.first?.id {
                Divider()
            }
            item(command)
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
/// radius 12, a hover fill, the heading and a small chevron.
struct AtticTitleMenu: View {
    let title: String
    let commands: [AtticMenuCommand]

    var body: some View {
        AtticCommandMenu(commands: commands, accessibilityLabel: title) {
            AtticTitleMenuFace(title: title)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
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
        .atticControlProbe("Title menu", id: probeID, expectedSize: CGSize(width: 0, height: m.height), radius: radius, expectedRadius: 12)
    }
}

// MARK: - Pop-overs

/// A choice row inside one of Attic's own pop-overs: genuine pop-over
/// content such as the link picker's results or ⌘K's list, never a command
/// menu (those are native, `AtticCommandMenu`). 28 tall, radius 12; the
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
        .atticControlProbe("Pop-over row", id: probeID, expectedSize: nil, radius: radius, expectedRadius: 12)
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
