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
        .animation(AtticMotionPreset.expand.animation(reduceMotion: design.reduceMotion), value: open)
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
        var chips: [AtticTokenChip]
        var isFocused: Binding<Bool>
        var actions: AtticTokenFieldActions
        /// Edits made as typing (the strip's picks, a suggestion taken).
        var editor: AtticTokenFieldEditor?
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
                actions: tokens.actions,
                editor: tokens.editor
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

/// The Done page's search, on the tabs line (owner item 17, card B of
/// v22): while searching, the field takes the line where "Now · Later ·
/// Done" sat. A recessed 28 pt pill across the list's width, the 13 pt
/// magnifier in the secondary ink on the circles' line, the placeholder
/// (secondary) and the typed text (primary) on the titles' line, and a
/// quiet "Esc" at the end that returns the tabs. Its focus is a binding,
/// so Search from the menu bar and ⌘F put the keyboard in it. Esc clears
/// the search and returns the tabs.
struct AtticTabsSearchField: View {
    let placeholder: String
    @Binding var text: String
    var isFocused: Binding<Bool>?
    /// Esc, or a click on the "Esc" hint: the search ends.
    let onEscape: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticCapture) private var capture
    @FocusState private var focused: Bool
    @State private var claim = AtticFieldClaim()

    var body: some View {
        let m = AtticTabsSearchMetrics.self
        let tokens = design.tokens
        let height = AtticControlSize.smallHeight
        HStack(spacing: 0) {
            AtticIcon(systemName: "magnifyingglass", size: m.iconSize, weight: AtticIconWeight.outline, ink: .helper)
                .frame(width: AtticControlSize.statusCircle)
                .padding(.leading, AtticLayout.circleX - AtticLayout.rowHighlightInset)
            Group {
                if capture == nil {
                    TextField("", text: $text, prompt: Text(verbatim: placeholder).foregroundStyle(tokens.color(.helper)))
                        .textFieldStyle(.plain)
                        .font(AtticTextStyle.listBody.font)
                        .foregroundStyle(tokens.color(.heading))
                        .focused($focused)
                        .onExitCommand(perform: onEscape)
                        .accessibilityLabel(placeholder)
                        // This field's own AppKit field, found from beside it
                        // (round 10): a field fading out with the last search
                        // is never the one given the keyboard.
                        .background(AtticFieldClaimProbe(claim: claim, placeholder: placeholder,
                                                         wanted: { isFocused?.wrappedValue == true }).accessibilityHidden(true))
                } else {
                    AtticText(verbatim: text.isEmpty ? placeholder : text, style: .listBody, ink: text.isEmpty ? .helper : .heading, truncates: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, AtticLayout.textX - AtticLayout.circleX - AtticControlSize.statusCircle)
            Button(action: onEscape) {
                AtticText(verbatim: String(localized: "Esc"), style: .shortcut, ink: .helper)
                    .padding(.horizontal, m.hintPadding)
                    .frame(height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(String(localized: "End the search (Esc)"))
            .accessibilityLabel(String(localized: "End search"))
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: AtticRadius.control(height: height), style: .continuous).fill(tokens.recessed.color))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onAppear {
            // Once the field is in the window (a focus set as it appears is
            // lost, and the click that opened it ends after this): the
            // keyboard goes to it, the insertion point after its text.
            // A field that held the keyboard (the add bar) gives it up in
            // the same turn, so a second try follows if the first was lost.
            guard isFocused?.wrappedValue == true else { return }
            for delay in [0.0, 0.15, 0.4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard isFocused?.wrappedValue == true else { return }
                    if delay == 0 { focused = true }
                    takeKeyboard()
                }
            }
        }
        .onChange(of: focused) { _, now in if isFocused?.wrappedValue != now { isFocused?.wrappedValue = now } }
        .onChange(of: isFocused?.wrappedValue) { _, wanted in
            if let wanted, wanted != focused {
                focused = wanted
                if wanted { DispatchQueue.main.async { takeKeyboard() } }
            }
        }
        .padding(.horizontal, AtticLayout.rowHighlightInset)
    }

    /// Focus given from outside (typing on the Done page, ⌘F, Search): the
    /// insertion point goes after what is there, as if typed, never
    /// selecting it (a first letter typed on the page must not be replaced
    /// by the next).
    private func caretToEnd() {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor else { return }
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
    }

    /// This field's AppKit text field: an editable one with its prompt.
    static func isSearchField(_ field: NSTextField, placeholder: String) -> Bool {
        field.isEditable && (field.placeholderAttributedString?.string == placeholder || field.placeholderString == placeholder
            || field.accessibilityLabel() == placeholder)
    }

    static func searchField(in view: NSView, placeholder: String) -> NSTextField? {
        if let field = view as? NSTextField, isSearchField(field, placeholder: placeholder) { return field }
        for child in view.subviews {
            if let found = searchField(in: child, placeholder: placeholder) { return found }
        }
        return nil
    }

    /// The field takes the keyboard even when the view that had it went
    /// away in the same moment (the tabs it replaces, CI run 1): if the
    /// focus asked for did not land, the window's first responder becomes
    /// this field's own text field.
    private func takeKeyboard() {
        // Only while the page still wants it (a page hidden since, R2).
        guard isFocused?.wrappedValue ?? true, let window = NSApp.keyWindow else { return }
        // This field's own AppKit field, when it is in the window.
        if let field = claim.field, field.window === window {
            if (window.firstResponder as? NSTextView)?.delegate as? NSTextField !== field { window.makeFirstResponder(field) }
            caretToEnd()
            return
        }
        // Not found yet: the probe gives it the keyboard the moment it is
        // in the window (never a window-wide guess, which could pick the
        // field fading out with the last search).
    }
}

/// The AppKit field a SwiftUI text field draws with, found from a probe
/// beside it (round 10: the ⌘F-after-Esc flake gave the keyboard to the
/// field still fading out with the last search, found first in the window).
@MainActor
final class AtticFieldClaim {
    weak var field: NSTextField?
}

/// Finds its field (`AtticTabsSearchField.isSearchField`) among its nearest
/// ancestors' subviews when it enters a window, and gives it the keyboard
/// then when the field wants it: the moment the field exists, not after a
/// guessed delay.
struct AtticFieldClaimProbe: NSViewRepresentable {
    let claim: AtticFieldClaim
    let placeholder: String
    let wanted: () -> Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.configure(claim: claim, placeholder: placeholder, wanted: wanted)
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.configure(claim: claim, placeholder: placeholder, wanted: wanted)
    }

    final class ProbeView: NSView {
        private var claim: AtticFieldClaim?
        private var placeholder = ""
        private var wanted: () -> Bool = { false }

        func configure(claim: AtticFieldClaim, placeholder: String, wanted: @escaping () -> Bool) {
            self.claim = claim
            self.placeholder = placeholder
            self.wanted = wanted
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // The field is laid out beside the probe in the same pass.
            DispatchQueue.main.async { [weak self] in self?.take() }
        }

        private func take() {
            guard let window, let field = ownField() else { return }
            claim?.field = field
            guard wanted(), window.isKeyWindow || window.canBecomeKey else { return }
            if (window.firstResponder as? NSTextView)?.delegate as? NSTextField !== field {
                window.makeFirstResponder(field)
            }
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }

        /// Fields another probe already took: a field fading out with the
        /// last search is one, the field that just appeared is not.
        @MainActor private static let taken = NSHashTable<NSTextField>.weakObjects()

        /// The matching field this probe belongs to: one no other probe
        /// took (the newest), nearest to the probe if there are several.
        private func ownField() -> NSTextField? {
            if let known = claim?.field, known.window === window { return known }
            guard let field = matchingField(excludingTaken: true) ?? matchingField(excludingTaken: false) else { return nil }
            Self.taken.add(field)
            return field
        }

        private func matchingField(excludingTaken: Bool) -> NSTextField? {
            guard let content = window?.contentView else { return nil }
            let mine = convert(bounds, to: nil)
            var fields: [NSTextField] = []
            func collect(_ view: NSView) {
                if let field = view as? NSTextField, AtticTabsSearchField.isSearchField(field, placeholder: placeholder),
                   !excludingTaken || !Self.taken.contains(field) {
                    fields.append(field)
                }
                view.subviews.forEach(collect)
            }
            collect(content)
            func distance(_ field: NSTextField) -> CGFloat {
                let frame = field.convert(field.bounds, to: nil)
                return hypot(frame.midX - mine.midX, frame.midY - mine.midY)
            }
            return fields.min { distance($0) < distance($1) }
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
/// with the count and state, priority, date, tag, move and delete. Round
/// 10: a choice opens a native menu from a plain button (every click takes
/// it), and Date and Tags open their pickers (every tag, search and
/// creation) as pop-overs. VoiceOver reads the count and what the selected
/// tasks share or not ("mixed priority").
struct AtticSelectionBar: View {
    struct Action: Identifiable {
        let systemName: String
        let label: String.LocalizationValue
        let handler: () -> Void
        /// A choice (state, priority): the button opens this native menu
        /// instead of acting, read when it opens.
        var menu: (() -> [AtticMenuCommand])? = nil
        /// A picker (date, tags): the button opens it as a pop-over.
        var popover: AtticAnchoredPopover? = nil
        var id: String { systemName }
    }

    let count: Int
    let actions: [Action]
    /// What VoiceOver says after the count ("mixed priority, tagged
    /// launch"); nil says nothing more.
    var summary: String? = nil

    @State private var probeID = UUID()

    var body: some View {
        let height = AtticControlSize.smallHeight + AtticControlSize.capsuleInset * 2
        let radius = AtticRadius.control(height: height)
        HStack(spacing: AtticSelectionBarMetrics.controlSpacing) {
            // The count is never cut mid-word ("3 sel…"): it reads "3
            // selected" when the room allows and "3" when it does not (a
            // rounder panel corner, a bigger count); VoiceOver has the words.
            ViewThatFits(in: .horizontal) {
                AtticText(verbatim: String(localized: "\(count) selected"), style: .controlLabel, ink: .body)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                AtticText(verbatim: String(count), style: .controlLabel, ink: .body)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
                .padding(.leading, AtticSelectionBarMetrics.countLeading)
                .padding(.trailing, AtticSelectionBarMetrics.countTrailing)
                .accessibilityValue(summary ?? "")
            ForEach(actions) { action in
                if let menu = action.menu {
                    AtticMenuButton(systemName: action.systemName, label: action.label, commands: menu)
                } else if let popover = action.popover {
                    AtticSmallButton(systemName: action.systemName, label: action.label, action: action.handler)
                        .atticPopover(isPresented: popover.isPresented, arrowEdge: .top) { popover.content() }
                } else {
                    AtticSmallButton(systemName: action.systemName, label: action.label, action: action.handler)
                }
            }
        }
        .padding(AtticControlSize.capsuleInset)
        .frame(height: height)
        .atticRaisedMaterial(cornerRadius: radius, interactive: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "\(count) selected"))
        .accessibilityValue(summary ?? "")
        .atticControlProbe("Selection bar", id: probeID, expectedSize: nil, radius: radius, expectedRadius: 15)
    }
}

// MARK: - Menus

/// One command in a native menu: a title menu, a "More" button, a context
/// menu, a row's actions (round 10). Menus stay the system's own (native
/// first: keyboard navigation, type-to-select, VoiceOver, system timing);
/// Attic only chooses their content and the control that opens them. The
/// same list builds a SwiftUI menu (`AtticMenuItems`) and an `NSMenu`
/// (`AtticNativeMenu`, which a key or a button can open), so a command's
/// title, shortcut and state are defined once.
struct AtticMenuCommand: Identifiable {
    let id = UUID()
    let title: String
    var systemImage: String?
    var shortcut: KeyboardShortcut?
    var isDestructive = false
    var isDisabled = false
    /// Starts a new section (the system draws its separator).
    var startsSection = false
    /// A tick (on), a dash (mixed: some of the targets), or neither.
    var state: AtticCheckState?
    /// A quiet trailing detail ("Tue 30 Sep").
    var detail: String?
    /// A submenu's commands (the command itself then does nothing).
    var children: [AtticMenuCommand] = []
    /// A section's heading ("3 Tasks"): not a command.
    var isHeader = false
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
        state: AtticCheckState? = nil,
        detail: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.isDestructive = isDestructive
        self.isDisabled = isDisabled
        self.startsSection = startsSection
        self.state = state
        self.detail = detail
        self.action = action
    }

    /// A submenu.
    static func submenu(_ title: String, systemImage: String? = nil, startsSection: Bool = false,
                        isDisabled: Bool = false, _ children: [AtticMenuCommand]) -> AtticMenuCommand {
        var command = AtticMenuCommand(verbatim: title, systemImage: systemImage, isDisabled: isDisabled || children.isEmpty,
                                       startsSection: startsSection) {}
        command.children = children
        return command
    }

    /// A section's heading: starts a section, titled.
    static func header(_ title: String) -> AtticMenuCommand {
        var command = AtticMenuCommand(verbatim: title, startsSection: true) {}
        command.isHeader = true
        return command
    }

    /// The command a key press runs, searched through submenus: the first
    /// enabled one with this shortcut.
    static func command(for shortcut: KeyboardShortcut, in commands: [AtticMenuCommand]) -> AtticMenuCommand? {
        for command in commands {
            if !command.isDisabled, !command.isHeader, command.children.isEmpty,
               let own = command.shortcut, own.key == shortcut.key, own.modifiers == shortcut.modifiers {
                return command
            }
            if let found = Self.command(for: shortcut, in: command.children) { return found }
        }
        return nil
    }

    /// The command a key press runs (a subtask's keys, round 10): the
    /// first enabled one whose shortcut is this key with exactly these
    /// modifiers; letters by their character, Backspace however it comes.
    /// `includingDisabled` finds a disabled command too (a key the list owns
    /// even when it cannot run now).
    static func command(key: KeyEquivalent, characters: String, modifiers: EventModifiers,
                        in commands: [AtticMenuCommand], includingDisabled: Bool = false) -> AtticMenuCommand? {
        let relevant = modifiers.intersection([.command, .shift, .option, .control])
        let deletes: Set<Character> = [KeyEquivalent.delete.character, KeyEquivalent.deleteForward.character, "\u{7F}", "\u{8}", "\u{F728}"]
        for command in commands {
            if let found = Self.command(key: key, characters: characters, modifiers: modifiers,
                                        in: command.children, includingDisabled: includingDisabled) { return found }
            guard includingDisabled || !command.isDisabled, !command.isHeader, command.children.isEmpty, let shortcut = command.shortcut,
                  shortcut.modifiers == relevant else { continue }
            if shortcut.key == .delete {
                if deletes.contains(key.character) || characters.first.map(deletes.contains) == true { return command }
            } else if shortcut.key == .space {
                if key == .space || characters == " " || characters == "\u{A0}" { return command }
            } else if shortcut.key == key || (characters.count == 1 && characters.lowercased() == String(shortcut.key.character)) {
                return command
            }
        }
        return nil
    }

    /// A subtask's key press (round 10b): runs the command the key names
    /// and takes the key. A command that is disabled right now (Move Up on
    /// the first subtask) still takes its key and does nothing, so the key
    /// never falls through to the list and moves the main task instead.
    static func performSubtaskKey(key: KeyEquivalent, characters: String, modifiers: EventModifiers,
                                  in commands: [AtticMenuCommand]) -> KeyPress.Result {
        guard let command = command(key: key, characters: characters, modifiers: modifiers,
                                    in: commands, includingDisabled: true) else { return .ignored }
        if !command.isDisabled { command.action() }
        return .handled
    }

    /// Every title, submenus included (tests read what a menu offers).
    static func titles(in commands: [AtticMenuCommand]) -> [String] {
        commands.flatMap { [$0.title] + titles(in: $0.children) }
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
/// system's own divider (or titled), each item with its symbol, its state
/// and its shortcut shown (spec: right-click menus show shortcuts too);
/// submenus nest. Used by `AtticCommandMenu` and inside `.contextMenu`.
struct AtticMenuItems: View {
    private let build: () -> [AtticMenuCommand]

    init(commands: [AtticMenuCommand]) {
        build = { commands }
    }

    /// Commands built only when the menu itself is built (round 11): a
    /// row's `.contextMenu` otherwise worked out every command of every
    /// row, tags and dates included, each time the list redrew.
    init(building build: @escaping () -> [AtticMenuCommand]) {
        self.build = build
    }

    var body: some View {
        let sections = sections(build())
        ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
            if let header = section.header {
                Section(header.title) { items(section.items) }
            } else {
                if index > 0 { Divider() }
                items(section.items)
            }
        }
    }

    private struct Group {
        var header: AtticMenuCommand?
        var items: [AtticMenuCommand] = []
    }

    private func sections(_ commands: [AtticMenuCommand]) -> [Group] {
        var result: [Group] = []
        for command in commands {
            if command.isHeader {
                result.append(Group(header: command))
            } else if command.startsSection || result.isEmpty {
                result.append(Group(items: [command]))
            } else {
                result[result.count - 1].items.append(command)
            }
        }
        return result
    }

    private func items(_ commands: [AtticMenuCommand]) -> some View {
        ForEach(commands) { command in item(command) }
    }

    @ViewBuilder
    private func item(_ command: AtticMenuCommand) -> some View {
        if !command.children.isEmpty {
            Menu {
                AtticMenuItems(commands: command.children)
            } label: {
                label(command)
            }
            .disabled(command.isDisabled)
        } else if let state = command.state, state != .mixed {
            // A toggle draws the native tick.
            Toggle(isOn: Binding(get: { state == .on }, set: { _ in command.action() })) { label(command) }
                .disabled(command.isDisabled)
                .modifier(AtticMenuShortcut(shortcut: command.shortcut))
                .modifier(AtticMenuBadge(detail: command.detail))
        } else {
            Button(role: command.isDestructive ? .destructive : nil, action: command.action) {
                if command.state == .mixed {
                    // Some of the targets have it: a dash.
                    SwiftUI.Label(command.title, systemImage: "minus")
                } else {
                    label(command)
                }
            }
            .disabled(command.isDisabled)
            .modifier(AtticMenuShortcut(shortcut: command.shortcut))
            .modifier(AtticMenuBadge(detail: command.detail))
        }
    }

    @ViewBuilder
    private func label(_ command: AtticMenuCommand) -> some View {
        if let systemImage = command.systemImage {
            SwiftUI.Label(command.title, systemImage: systemImage)
        } else {
            Text(verbatim: command.title)
        }
    }
}

private struct AtticMenuShortcut: ViewModifier {
    let shortcut: KeyboardShortcut?

    func body(content: Content) -> some View {
        if let shortcut { content.keyboardShortcut(shortcut) } else { content }
    }
}

private struct AtticMenuBadge: ViewModifier {
    let detail: String?

    func body(content: Content) -> some View {
        if let detail { content.badge(Text(verbatim: detail)) } else { content }
    }
}

/// A pop-up menu that shows every command's shortcut but answers only the
/// shortcuts that carry ⌘, ⌃ or ⌥ (round 13). A bare key (Return for Edit
/// Title, Space for Complete, Delete) is a shortcut of the list behind the
/// menu, shown for reference: inside the open menu those keys belong to the
/// menu (↓ highlights, Return activates the highlighted item), never to the
/// item whose hint they are.
/// Return belongs to a tracking menu, including events dispatched through
/// NSApplication to its underlying key window. Keep native navigation and
/// shortcut hints, and consume the activating press through its release.
final class AtticPopUpMenu: NSMenu, NSMenuDelegate {
    private var isTracking = false
    private var keyMonitor: Any?
    private var claimedReturn: (code: UInt16, timestamp: TimeInterval)?

    override init(title: String) {
        super.init(title: title)
        delegate = self
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    func menuWillOpen(_ menu: NSMenu) {
        isTracking = true
        // The root owns input for its whole open submenu chain.
        guard (supermenu as? AtticPopUpMenu)?.isTracking != true, keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            MainActor.assumeIsolated { self.takeReturn(event) ? nil : event }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        isTracking = false
        if claimedReturn == nil { stopMonitoring() }
    }

    private func stopMonitoring() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        claimedReturn = nil
    }

    /// One owner for Return, whether AppKit asks for a menu equivalent or
    /// sends the event through the window's local event monitors.
    private func takeReturn(_ event: NSEvent) -> Bool {
        if event.type == .keyUp, event.keyCode == claimedReturn?.code {
            claimedReturn = nil
            if !isTracking { stopMonitoring() }
            return true
        }
        guard event.type == .keyDown else { return false }
        if !isTracking {
            if let claimedReturn, event.keyCode == claimedReturn.code,
               event.isARepeat || event.timestamp == claimedReturn.timestamp { return true }
            // A lost release cannot suppress a later, fresh key press.
            stopMonitoring()
            return false
        }
        guard event.keyCode == 36 || event.keyCode == 76,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        claimedReturn = (event.keyCode, event.timestamp)
        var selectedMenu: NSMenu = self
        while let child = selectedMenu.highlightedItem?.submenu, child.highlightedItem != nil {
            selectedMenu = child
        }
        guard let item = selectedMenu.highlightedItem, item.isEnabled else { return true }
        if item.submenu != nil {
            // Opening a highlighted submenu is native Right-arrow navigation.
            // Queue it to the tracker instead of sending Return to the page.
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let right = NSEvent.keyEvent(with: type, location: event.locationInWindow, modifierFlags: [],
                                                timestamp: event.timestamp, windowNumber: event.windowNumber,
                                                context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}",
                                                isARepeat: false, keyCode: 124) {
                    NSApp.postEvent(right, atStart: false)
                }
            }
        } else if item.action != nil {
            let index = selectedMenu.index(of: item)
            cancelTrackingWithoutAnimation()
            selectedMenu.performActionForItem(at: index)
        }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if MainActor.assumeIsolated({ takeReturn(event) }) { return true }
        // Bare keys are list shortcuts shown for reference. Modified menu
        // equivalents still run their own item, independently of highlight.
        guard !event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        return super.performKeyEquivalent(with: event)
    }
}

/// The same commands as an `NSMenu` (round 10): what a row's actions
/// button, ⇧⌘I and the selection bar open, anchored to a view. Native in
/// every way (keyboard, type-to-select, VoiceOver), with each command's
/// state, shortcut and detail as `AtticMenuItems` draws them.
@MainActor
enum AtticNativeMenu {
    /// The menu for `commands`.
    static func make(_ commands: [AtticMenuCommand], title: String = "") -> NSMenu {
        let menu = AtticPopUpMenu(title: title)
        menu.autoenablesItems = false
        var first = true
        for command in commands {
            if command.isHeader {
                if !first { menu.addItem(.separator()) }
                menu.addItem(.sectionHeader(title: command.title))
                first = false
                continue
            }
            if command.startsSection, !first { menu.addItem(.separator()) }
            first = false
            menu.addItem(item(command))
        }
        return menu
    }

    private static func item(_ command: AtticMenuCommand) -> NSMenuItem {
        let item = NSMenuItem(title: command.title, action: nil, keyEquivalent: "")
        if let systemImage = command.systemImage, command.state != .mixed {
            item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        }
        if !command.children.isEmpty {
            item.submenu = make(command.children, title: command.title)
        } else {
            item.target = AtticMenuTarget.shared
            item.action = #selector(AtticMenuTarget.runCommand(_:))
            item.representedObject = AtticMenuTarget.Box(command.action)
        }
        switch command.state {
        case .on?: item.state = .on
        case .mixed?: item.state = .mixed
        case .off?, nil: item.state = .off
        }
        item.isEnabled = !command.isDisabled
        if let shortcut = command.shortcut, let key = keyEquivalent(shortcut.key) {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = modifiers(shortcut.modifiers)
        }
        if let detail = command.detail { item.badge = NSMenuItemBadge(string: detail) }
        return item
    }

    /// AppKit's key equivalent for a SwiftUI key.
    nonisolated static func keyEquivalent(_ key: KeyEquivalent) -> String? {
        func unit(_ value: Int) -> String? { UnicodeScalar(UInt32(value)).map { String(Character($0)) } }
        switch key {
        case .return: return "\r"
        case .space: return " "
        case .delete: return unit(NSBackspaceCharacter)
        case .deleteForward: return unit(NSDeleteFunctionKey)
        case .upArrow: return unit(NSUpArrowFunctionKey)
        case .downArrow: return unit(NSDownArrowFunctionKey)
        case .leftArrow: return unit(NSLeftArrowFunctionKey)
        case .rightArrow: return unit(NSRightArrowFunctionKey)
        case .escape: return "\u{1B}"
        case .tab: return "\t"
        default: return String(key.character)
        }
    }

    nonisolated static func modifiers(_ modifiers: EventModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    /// Opens the menu under `view` (at its bottom-left, or at `point` in
    /// its coordinates), as a pop-up button does. Returns at once: the
    /// menu tracks on the next turn, so the caller's own event finishes.
    static func popUp(_ commands: [AtticMenuCommand], in view: NSView, at point: CGPoint? = nil) {
        let menu = make(commands)
        menu.appearance = view.window?.effectiveAppearance
        let location = point ?? CGPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4)
        DispatchQueue.main.async {
            guard view.window != nil else { return }
            menu.popUp(positioning: nil, at: location, in: view)
        }
    }
}

/// Runs a native menu item's command.
@MainActor
final class AtticMenuTarget: NSObject {
    static let shared = AtticMenuTarget()

    final class Box {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
    }

    /// Not `perform(_:)`: that is NSObject's `performSelector:`, which the
    /// selector resolved to, so a chosen item ran nothing (round 10, CI run 2).
    @objc func runCommand(_ item: NSMenuItem) {
        (item.representedObject as? Box)?.action()
    }
}

/// The AppKit view behind a SwiftUI control, to anchor a native menu to
/// (round 10). Click-through; reports itself to its holder.
struct AtticMenuAnchor: NSViewRepresentable {
    let holder: AtticMenuAnchor.Holder

    @MainActor
    final class Holder {
        weak var view: NSView?
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        holder.view = view
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) { holder.view = view }

    final class AnchorView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A small button that opens a native menu under itself (round 10: the
/// selection bar's choices). A plain button with the menu opened in its
/// action: every click on it opens the menu (the SwiftUI `Menu` with a
/// click-through label never took the selection bar's clicks), and a key
/// can open the same menu (`AtticNativeMenu`). `commands` is read when it
/// opens, so ticks and dashes are current.
struct AtticMenuButton: View {
    let systemName: String
    let label: String.LocalizationValue
    let commands: () -> [AtticMenuCommand]

    @State private var anchor = AtticMenuAnchor.Holder()

    var body: some View {
        AtticSmallButton(systemName: systemName, label: label) {
            guard let view = anchor.view else { return }
            AtticNativeMenu.popUp(commands(), in: view)
        }
        .background(AtticMenuAnchor(holder: anchor).accessibilityHidden(true))
        .accessibilityHint(String(localized: "Opens a menu"))
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
    /// Keeps the icon column when this row has no icon, so a list of rows
    /// where only one is ticked stays aligned.
    var reservesIconSlot = false
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    @State private var probeID = UUID()

    init(systemName: String?, title: String, detail: String? = nil, isHighlighted: Bool = false,
         reservesIconSlot: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName
        self.title = title
        self.detail = detail
        self.isHighlighted = isHighlighted
        self.reservesIconSlot = reservesIconSlot
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
                } else if reservesIconSlot {
                    Color.clear.frame(width: m.rowIconSlot, height: 1).accessibilityHidden(true)
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
