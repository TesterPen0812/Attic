import AppKit
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
    /// L3: the flat corner surface instead of the raised material.
    var flat = false
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        AtticRaisedButtonBody(configuration: configuration, cornerRadius: cornerRadius, flat: flat, isSelected: isSelected)
    }
}

private struct AtticRaisedButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let cornerRadius: CGFloat
    var flat = false
    var isSelected = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.atticForcedState) private var forced
    @Environment(\.atticControlCornerExponent) private var cornerExponent
    @State private var hovered = false

    var body: some View {
        let state = AtticStateResolver(
            forced: forced, isEnabled: isEnabled, isHovered: hovered,
            isPressed: configuration.isPressed, isFocused: isFocused
        ).state
        let shape = AtticControlShape.shape(cornerRadius: cornerRadius, exponent: cornerExponent)
        Group {
            if flat {
                configuration.label
                    .environment(\.atticControlState, state)
                    .atticFlatSurface(cornerRadius: cornerRadius, state: state, isSelected: isSelected)
            } else {
                configuration.label
                    .environment(\.atticControlState, state)
                    .atticRaisedMaterial(cornerRadius: cornerRadius, state: state, interactive: state != .disabled)
            }
        }
            .atticFocusRing(state == .focused, cornerRadius: cornerRadius)
            .contentShape(shape)
            .onHover { hovered = $0 }
    }
}

/// A single raised button: pin, All notes or New note. Icon only, or
/// icon and label at the same height.
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
    /// The same, sideways (New note: −0.5, icon audit A3-01).
    var glyphOffsetX: CGFloat = 0
    /// The header's glyphs (Phase 0's qualities): the strong ink at regular
    /// weight, level with the page button's current page.
    var emphasisedGlyph = false
    /// L3: the header's flat corner surface (one fill, one hairline, no
    /// inner chip); a selected toggle takes the selected chip's fill whole.
    var flat = false
    /// A toggle that says "on" with its glyph (O14-05, the pinned pin): the
    /// glyph when selected (`pin.fill`) and, under the pointer, the action
    /// a click takes (`pin.slash`), cross-faded. Such a toggle draws no
    /// inner chip or selected fill: the filled glyph is the state.
    var selectedSystemName: String?
    var selectedHoverSystemName: String?
    /// A corner radius of its own (the owner's panel design draws the
    /// header's controls round); nil follows the 42 % rule.
    var cornerRadius: CGFloat?
    /// The glyph's turn in degrees (the design's pin leans 30° until pinned).
    var glyphRotation: Double = 0
    let action: () -> Void

    @State private var probeID = UUID()

    /// Icon only. `label` is what VoiceOver and the tooltip say.
    init(systemName: String, label: String.LocalizationValue, size: CGSize = AtticControlSize.panelButton, help: String? = nil,
         isSelected: Bool = false, glyphOffsetY: CGFloat = 0, glyphOffsetX: CGFloat = 0, emphasisedGlyph: Bool = false,
         flat: Bool = false, selectedSystemName: String? = nil, selectedHoverSystemName: String? = nil,
         cornerRadius: CGFloat? = nil, glyphRotation: Double = 0,
         action: @escaping () -> Void) {
        self.cornerRadius = cornerRadius
        self.glyphRotation = glyphRotation
        self.flat = flat
        self.selectedSystemName = selectedSystemName
        self.selectedHoverSystemName = selectedHoverSystemName
        self.glyphOffsetX = glyphOffsetX
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
    init(systemName: String?, title: String.LocalizationValue, height: CGFloat = AtticControlSize.panelButton.height,
         cornerRadius: CGFloat? = nil, action: @escaping () -> Void) {
        self.cornerRadius = cornerRadius
        self.systemName = systemName
        let resolved = String(localized: title)
        self.title = resolved
        self.accessibilityLabel = resolved
        self.size = CGSize(width: 0, height: height)
        self.help = nil
        self.action = action
    }

    var body: some View {
        let radius = cornerRadius ?? AtticRadius.control(height: size.height)
        // A toggle whose glyph says "on" draws no chip (O14-05).
        let chip = isSelected && selectedSystemName == nil
        Button(action: action) {
            AtticRaisedButtonLabel(systemName: systemName, title: title, isSelected: isSelected || emphasisedGlyph,
                                   onSystemName: isSelected ? selectedSystemName : nil,
                                   onHoverSystemName: isSelected ? selectedHoverSystemName : nil)
                .rotationEffect(.degrees(glyphRotation))
                .offset(x: glyphOffsetX, y: glyphOffsetY)
                .padding(.horizontal, title == nil ? 0 : AtticRaisedButtonMetrics.labelPadding)
                .frame(width: title == nil ? size.width : nil, height: size.height)
                // A 27 pt header control still answers a 28 pt target.
                .contentShape(Rectangle().inset(by: -AtticControlSize.hitOutset(for: size.height)))
                .background {
                    if chip, !flat {
                        AtticSelectedChip(outerHeight: size.height)
                    }
                }
        }
        .buttonStyle(AtticRaisedButtonStyle(cornerRadius: radius, flat: flat, isSelected: chip))
        .focusEffectDisabled()
        .help(help ?? accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .atticControlProbe(
            title == nil ? "Single button" : "Label button",
            id: probeID,
            expectedSize: title == nil ? size : nil,
            radius: radius,
            expectedRadius: cornerRadius ?? AtticRadius.control(height: size.height)
        )
    }
}

extension AtticRaisedButtonMetrics {
    /// A toggle's glyph (O14-05): off, its own; on, the "on" glyph, and
    /// under the pointer (or while pressed) the action a click takes
    /// ("Unpin"), so the toggle says what it does.
    nonisolated static func shownSymbol(_ systemName: String, on: String?, onHover: String?,
                                        state: AtticControlState) -> String {
        guard let on else { return systemName }
        if let onHover, state == .hover || state == .pressed { return onHover }
        return on
    }
}

private struct AtticRaisedButtonLabel: View {
    let systemName: String?
    let title: String?
    var isSelected = false
    /// A toggle that is on: its glyph, and the one under the pointer.
    var onSystemName: String?
    var onHoverSystemName: String?
    @Environment(\.atticControlState) private var state
    @Environment(\.atticDesign) private var design

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
                let size = title == nil ? AtticControlSize.raisedGlyph : AtticRaisedButtonMetrics.labelIconSize
                let weight: Font.Weight = isSelected ? .regular : AtticIconWeight.outline
                if onSystemName == nil {
                    AtticIcon(systemName: systemName, size: size, weight: weight, ink: glyph)
                } else {
                    // Every glyph the toggle can show, laid on one centre and
                    // cross-faded (F/E), so a change never moves the button.
                    let shown = AtticRaisedButtonMetrics.shownSymbol(systemName, on: onSystemName, onHover: onHoverSystemName, state: state)
                    let names = [onSystemName, onHoverSystemName].compactMap { $0 }
                    ZStack {
                        ForEach(names, id: \.self) { name in
                            AtticIcon(systemName: name, size: size, weight: weight, ink: glyph)
                                .opacity(name == shown ? 1 : 0)
                        }
                    }
                    .animation(design.reduceMotion ? nil : AtticMotionScale.easeOut(AtticMotionScale.fast), value: shown)
                }
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
    @Environment(\.atticControlCornerExponent) private var cornerExponent

    var body: some View {
        let inset = AtticControlSize.capsuleInset
        let radius = AtticRadius.nested(outer: AtticRadius.control(height: outerHeight), gap: inset) ?? AtticRadius.nestedChip
        AtticControlShape.shape(cornerRadius: radius, exponent: cornerExponent)
            .fill(design.tokens.chipSelected.color)
            .padding(inset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Hover gate

/// Hover UI opens only while no mouse button is down (V-04): a drag that
/// started elsewhere and passes over a hover control never opens it.
enum AtticHoverGate {
    static func opens(pressedButtons: Int) -> Bool { pressedButtons == 0 }
}

// MARK: - Page button (collapsed page dock)

/// The header's page button (Phase 0's mode dock, brought into Direction
/// A, 2026-09-26): at rest a square the size and shape of the pin, showing
/// only the current page's icon, plain as the pin's (D-11). Under the
/// pointer or keyboard focus it opens leftward into all the pages' icons
/// (the current one on the chip, each with a tooltip and its shortcut); a
/// click goes there, and it folds back when the pointer leaves. 36 pt,
/// inset 4, 24 pt segments 2 apart: 32 wide shut, 84 open.
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
    /// L3: the flat corner surface; the current page's glyph sits on it
    /// with no inner chip (open, the chip still marks it among the others).
    var flat = false

    @Environment(\.atticDesign) private var design
    @Environment(\.atticCapture) private var capture
    @Environment(\.atticKeyboardFocusVisible) private var keyboardFocusVisible
    @Environment(\.atticPageSwitcherPresence) private var presence
    @Environment(\.atticControlCornerExponent) private var cornerExponent
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
        // The owner's panel design: the header's controls are round.
        let radius = AtticRadius.header
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
                        let shape = AtticControlShape.shape(cornerRadius: chipRadius, exponent: cornerExponent)
                        let accent = design.tokens.pageChipAccent
                        if isSelected, !open {
                            // Shut, the current page's glyph sits plain, as the
                            // pin's does (D-11, owner 2026-10-11): the chip
                            // means "on" only for a pinned pin, and marks the
                            // current page only among the others once open.
                        } else if isSelected, let accent {
                            // Phase 0's Light palettes: the current page in the accent.
                            shape.fill(accent.fill.color)
                            shape.inset(by: M.accentStrokeWidth / 2).stroke(accent.stroke.color, lineWidth: M.accentStrokeWidth)
                        } else if isSelected {
                            shape.fill(design.tokens.chipSelected.color)
                        } else if hoveredPage == item.page {
                            shape.fill(design.tokens.chipHover.color)
                        }
                        let face = M.glyphFace(isSelected: isSelected, open: open, accent: accent != nil,
                                               solid: design.effectiveSurface == .solid)
                        AtticIcon(systemName: item.systemName, size: M.iconSize, weight: face.weight, ink: face.ink)
                    }
                    .frame(width: M.segment, height: M.segment)
                    // 24 pt chips (chrome B) still answer a 28 pt target,
                    // reaching into the gap and the capsule's inset.
                    .contentShape(Rectangle().inset(by: -AtticControlSize.hitOutset(for: M.segment)))
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
            // The owner's panel design: shut, a small chevron after the
            // current page says it opens.
            if !open {
                AtticIcon(systemName: "chevron.down", size: 7, weight: .semibold, ink: .chevron)
                    .frame(width: M.chevronWidth, height: M.segment)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .padding(M.inset)
        .frame(height: size)
        .modifier(AtticPageButtonSurface(flat: flat, cornerRadius: radius, hovered: hovering))
        .atticFocusRing(capture == nil && focused && keyboardFocusVisible, cornerRadius: radius)
        .contentShape(AtticControlShape.shape(cornerRadius: radius, exponent: cornerExponent))
        // V-04: it opens under a resting or moving pointer, never under a
        // mouse drag that started elsewhere (a marquee or a selection
        // passing over the header); the first move after the button comes
        // up opens it.
        .onContinuousHover { phase in
            switch phase {
            case .active:
                guard !hovering, AtticHoverGate.opens(pressedButtons: NSEvent.pressedMouseButtons) else { return }
                hovering = true
                onApproach()
            case .ended:
                if hovering { hovering = false }
                hoveredPage = nil
            }
        }
        .animation(AtticMotionPreset.expand.animation(reduceMotion: design.reduceMotion), value: open)
        // The header title makes room while it is open (OD-11).
        .onChange(of: open) { _, isOpen in presence?.set(isOpen) }
        .onDisappear { presence?.set(false) }
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
        .atticControlProbe("Page button", id: probeID, expectedSize: open ? nil : CGSize(width: Self.width(open: false, count: items.count), height: size),
                           radius: radius, expectedRadius: AtticRadius.header)
    }

    private func select(_ page: Page) {
        withAnimation(AtticMotionPreset.pageSwitch.animation(reduceMotion: design.reduceMotion)) {
            selection = page
        }
    }

    /// The width it takes shut and open (the header's hit testing).
    static func width(open: Bool, count: Int) -> CGFloat {
        let segments = open ? CGFloat(count) : 1
        return M.inset * 2 + segments * M.segment + (open ? CGFloat(max(count - 1, 0)) * M.gap : M.chevronWidth)
    }
}

/// The page button's surface: the raised material, or L3's flat one. Live
/// glass is interactive (owner, 2026-10-02): a click on any of its pages
/// gets the system's press response, as the pin's does. The pages' own
/// buttons still take the click: the interactive glass only responds to it.
private struct AtticPageButtonSurface: ViewModifier {
    let flat: Bool
    let cornerRadius: CGFloat
    let hovered: Bool

    func body(content: Content) -> some View {
        if flat {
            content.atticFlatSurface(cornerRadius: cornerRadius)
        } else {
            content.atticRaisedMaterial(cornerRadius: cornerRadius, interactive: true)
        }
    }
}

extension AtticPageButtonMetrics {
    /// A page's glyph. The current page's, shut or open, is the pin's
    /// (U-04): the strong glyph ink at regular weight, so the two corner
    /// buttons read as one pair and the page button never looks disabled.
    /// Open, a Light palette marks it in its accent on its tinted chip,
    /// except on an opaque surface (Reduce Transparency included), where
    /// palette ink can fall below the icon's floor on that chip. The other
    /// pages are quiet outline icons.
    nonisolated static func glyphFace(isSelected: Bool, open: Bool, accent: Bool, solid: Bool)
        -> (weight: Font.Weight, ink: AtticInk) {
        guard isSelected else { return (AtticIconWeight.outline, .icon) }
        return (.regular, open && accent && !solid ? .accent : .glyph)
    }
}

// MARK: - Header title room (OD-11)

/// Whether the page switcher is open, for the header title that must give
/// way to it. The page button reports into it; the title reads it. A
/// reference type in the environment, so the header never re-evaluates when
/// it flips: only the one title wrapper that observes it does.
@MainActor
final class AtticPageSwitcherPresence: ObservableObject {
    @Published private(set) var isOpen = false

    func set(_ open: Bool) {
        if isOpen != open { isOpen = open }
    }
}

private struct AtticPageSwitcherPresenceKey: EnvironmentKey {
    static let defaultValue: AtticPageSwitcherPresence? = nil
}

extension EnvironmentValues {
    /// The shell's page switcher presence (nil in the gallery and captures,
    /// where nothing makes room).
    var atticPageSwitcherPresence: AtticPageSwitcherPresence? {
        get { self[AtticPageSwitcherPresenceKey.self] }
        set { self[AtticPageSwitcherPresenceKey.self] = newValue }
    }
}

/// Where a header title sits between the pin and the page switcher (owner
/// decision B for Canvas, reused for Notes, OD-11). Shut, the title is
/// centred between the two 36 pt buttons. While the switcher is open it
/// takes the width to its left: the title left-aligns beside the pin and
/// truncates in what the switcher leaves, so it never sits under it, then
/// returns to the centre when the switcher closes. Pure geometry in the
/// panel's x axis, so a test can check it at any title length and width.
enum AtticHeaderTitleSlot {
    struct Placement: Equatable {
        /// The title's left edge, from the panel's left edge.
        let x: CGFloat
        let width: CGFloat
        var maxX: CGFloat { x + width }
    }

    /// The clear gap kept between the title and either neighbour.
    static let gap = AtticSpacing.s8

    /// The switcher's open frame, from the panel's left edge.
    static func switcherFrame(panelWidth: CGFloat, chromeInset: CGFloat, switcherWidth: CGFloat) -> ClosedRange<CGFloat> {
        let maxX = panelWidth - chromeInset
        return (maxX - switcherWidth)...maxX
    }

    static func placement(
        titleWidth: CGFloat,
        panelWidth: CGFloat,
        chromeInset: CGFloat,
        switcherWidth: CGFloat,
        switcherOpen: Bool
    ) -> Placement {
        let left = chromeInset + AtticControlSize.headerControl + gap
        let right = switcherOpen
            ? panelWidth - chromeInset - switcherWidth - gap
            : panelWidth - left
        let room = max(0, right - left)
        let width = min(max(0, titleWidth), room)
        let x = switcherOpen ? left : left + (room - width) / 2
        return Placement(x: x, width: width)
    }
}

/// Places its one child with `AtticHeaderTitleSlot`: full panel width, the
/// child's own height. The child is proposed the slot's width, so a long
/// title truncates there.
struct AtticHeaderTitleLayout: Layout {
    var chromeInset: CGFloat
    var switcherWidth: CGFloat
    var switcherOpen: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: subviews.first?.sizeThatFits(.unspecified).height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let title = subviews.first else { return }
        let placement = AtticHeaderTitleSlot.placement(
            titleWidth: title.sizeThatFits(.unspecified).width,
            panelWidth: bounds.width,
            chromeInset: chromeInset,
            switcherWidth: switcherWidth,
            switcherOpen: switcherOpen
        )
        title.place(at: CGPoint(x: bounds.minX + placement.x, y: bounds.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(width: placement.width, height: bounds.height))
    }
}

/// A header title that makes room for the page switcher: it slides left and
/// truncates while the switcher is open and slides back when it closes, with
/// the selected motion preset (Reduce Motion and Reduced: no slide, the new
/// width at once). One behaviour for every page's header title.
struct AtticHeaderTitleRoom<Content: View>: View {
    var chromeInset: CGFloat
    var switcherWidth: CGFloat
    /// Tests and captures pin the switcher open or shut; nil follows the
    /// shell's presence.
    var forcedOpen: Bool?
    @ViewBuilder var content: () -> Content

    @Environment(\.atticPageSwitcherPresence) private var presence

    var body: some View {
        if let presence, forcedOpen == nil {
            Observing(presence: presence, room: self)
        } else {
            Placed(room: self, open: forcedOpen ?? false)
        }
    }

    private struct Observing: View {
        @ObservedObject var presence: AtticPageSwitcherPresence
        let room: AtticHeaderTitleRoom

        var body: some View { Placed(room: room, open: presence.isOpen) }
    }

    private struct Placed: View {
        let room: AtticHeaderTitleRoom
        let open: Bool
        @Environment(\.atticDesign) private var design

        var body: some View {
            AtticHeaderTitleLayout(chromeInset: room.chromeInset, switcherWidth: room.switcherWidth, switcherOpen: open) {
                room.content()
            }
            // The switcher's own motion: the title moves with it. Instant
            // (no animation) in Reduce Motion and Reduced.
            .animation(AtticMotionPreset.expand.animation(reduceMotion: design.reduceMotion), value: open)
        }
    }
}

// MARK: - Add bar

/// The add bar: one raised field, 36 tall, radius 15. The send button
/// lives inside it and appears only when there is text. Its slot is always
/// reserved, so the field never changes width: the button only fades in
/// with a short rise (opacity and position). Return adds; the bar keeps
/// focus for the next one. Its live field wraps long text onto more lines
/// (O17-05): the bar grows upward a line at a time, up to
/// `AtticComposerMetrics.maxLines`, with its plus and send button resting
/// on its last line, and shrinks back when the text is added or cleared.
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
    /// Display state is a snapshot from the owning view. Keeping the edit
    /// binding out of DynamicProperty avoids invalidating the whole bar on
    /// scroll layout passes that poll bindings without changing the text.
    private let text: String
    // Binding itself conforms to DynamicProperty even without @Binding;
    // capture it in a closure so only the actual field owns that property.
    private let fieldText: () -> Binding<String>
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
    /// The live field's height: one line, or more as it wraps (O17-05).
    @State private var fieldHeight = AtticTokenFieldMetrics.height

    init(placeholder: String.LocalizationValue, text: Binding<String>, onSubmit: @escaping () -> Void) {
        self.placeholder = String(localized: placeholder)
        self.text = text.wrappedValue
        self.fieldText = { text }
        self.onSubmit = onSubmit
    }

    /// The live page's bar: a placeholder chosen at run time, the chip
    /// field, and a glyph for the bar's job.
    init(placeholder: String, text: Binding<String>, systemImage: String = "plus", showsSend: Bool = true,
         tokens: Tokens?, onSubmit: @escaping () -> Void) {
        self.placeholder = placeholder
        self.text = text.wrappedValue
        self.fieldText = { text }
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

    #if DEBUG
    /// Hosted regression counter, matching PanelHeader's scroll-frame seam.
    static var bodyEvaluations = 0
    #endif

    var body: some View {
        #if DEBUG
        let _ = Self.bodyEvaluations += 1
        #endif
        let m = AtticAddBarMetrics.self
        let height = AtticControlSize.addBarHeight
        // The owner's panel design: round (32 px on 61 px, clamped).
        let radius = height / 2
        // The field's own keyboard focus and the environment's enabled
        // state; the gallery's pinned states override both. The ring shows
        // only while the keyboard is driving (a click into the field, or
        // the panel opening with the bar focused, draws none).
        let state = AtticStateResolver(forced: forced, isEnabled: isEnabled, isHovered: hovered, isPressed: false,
                                       isFocused: isFieldFocused && keyboardFocusVisible).state
        let send = AtticControlSize.sendButton
        // Grown by the lines the live field wraps onto; the plus and the send
        // button rest on the last line (the bar grows upward, so they never
        // move while typing).
        let grown = max(0, fieldHeight - AtticTokenFieldMetrics.height)
        HStack(alignment: .bottom, spacing: m.gap) {
            // The owner's panel design: a 14 pt plus circle, grey at rest,
            // the ink disc with a white plus once there is text (it adds).
            plusCircle(disabled: state == .disabled)
                .frame(width: m.iconSlot, height: height)
            // It follows the bar's width frame by frame while the footer's
            // tabs fold away or return: on the Air (fix round 2) holding it
            // saved nothing measurable, and a held field had pushed the
            // footer past the panel's edges.
            field(disabled: state == .disabled)
                .frame(height: AtticTokenFieldMetrics.height + grown)
                .padding(.vertical, (height - AtticTokenFieldMetrics.height) / 2)
                .atticControlProbe("Add bar field", id: fieldProbeID, expectedSize: nil, radius: 0, expectedRadius: 0)
            // Built with the bar and only shown when there is text: the
            // first keystroke changes an opacity and an offset instead of
            // building the button (spec: one frame per keystroke).
            ZStack {
                if showsSend, !Self.plusAdds {
                    let shown = hasText
                    sendButton(radius: radius)
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown || design.reduceMotion ? 0 : AtticMotionPreset.popover.rise)
                        .scaleEffect(shown ? 1 : AtticMotionPreset.popover.hiddenScale(reduceMotion: design.reduceMotion))
                        .allowsHitTesting(shown)
                        .disabled(!shown)
                        .accessibilityHidden(!shown)
                        .transformEnvironment(\.atticProbesDisabled) { if !shown { $0 = true } }
                }
            }
            .frame(width: Self.plusAdds ? 0 : send.width, height: send.height)
            .padding(.vertical, (height - send.height) / 2)
        }
        .padding(.leading, m.leadingPadding)
        .padding(.trailing, Self.plusAdds ? m.leadingPadding : AtticControlSize.sendInset)
        // While the empty field has the keyboard, a quiet "!!!" at the
        // bar's end says how to set a priority. Over the field (whose text
        // is empty while it shows), so it never changes the field's width.
        .overlay(alignment: .bottomTrailing) {
            if isFieldFocused, text.isEmpty, capture == nil {
                Text(verbatim: "!!!")
                    .font(.system(size: 10))
                    .foregroundStyle(design.tokens.color(.placeholder))
                    .frame(height: height)
                    .padding(.trailing, Self.plusAdds ? m.leadingPadding : AtticControlSize.sendInset)
                    .help(String(localized: "Type !!! while adding to set priority"))
                    .accessibilityHidden(true)
            }
        }
        .frame(height: height + grown)
        .atticRaisedMaterial(cornerRadius: radius, state: state == .hover ? .rest : state, interactive: false)
        .atticFocusRing(state == .focused, cornerRadius: radius)
        .onHover { hovered = $0 }
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion, showing: hasText), value: hasText)
        // A line more or less: the bar's own spring, its text kept in view.
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion, showing: grown > 0), value: grown)
        .atticControlProbe("Add bar", id: probeID, expectedSize: nil, radius: radius,
                           expectedRadius: AtticControlSize.addBarHeight / 2)
    }

    @ViewBuilder
    private func field(disabled: Bool) -> some View {
        if capture == nil, let tokens {
            AtticTokenField(
                text: fieldText(),
                chips: tokens.chips,
                isFocused: tokens.isFocused,
                accessibilityLabel: placeholder,
                isEnabled: !disabled,
                actions: tokens.actions,
                editor: tokens.editor,
                growth: AtticTokenFieldGrowth(height: $fieldHeight, minHeight: AtticTokenFieldMetrics.height)
            )
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
                text: fieldText(),
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

    /// The design's plus circle adds; there is no separate send button.
    static let plusAdds = true

    @ViewBuilder
    private func plusCircle(disabled: Bool) -> some View {
        let tokens = design.tokens
        let active = hasText && !disabled
        let disc = active ? tokens.ink(.inverseFill) : tokens.ink(.heading).withAlpha(disabled ? 0.04 : 0.1)
        let glyph = active ? tokens.ink(.onInverse) : tokens.ink(disabled ? .disabledIcon : .icon)
        let mark = ZStack {
            Circle().fill(disc.color)
            AtticPlusGlyph().stroke(glyph.color, style: StrokeStyle(lineWidth: 0.85, lineCap: .round))
                .frame(width: AtticAddBarMetrics.plusSize, height: AtticAddBarMetrics.plusSize)
        }
        .frame(width: AtticAddBarMetrics.iconSlot, height: AtticAddBarMetrics.iconSlot)
        if showsSend, capture == nil {
            Button(action: onSubmit) {
                mark.contentShape(Rectangle().inset(by: -7))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(!active)
            .help(String(localized: "Add (Return)"))
            .accessibilityLabel(String(localized: "Add"))
            .animation(.easeOut(duration: 0.16), value: active)
        } else {
            mark.accessibilityHidden(true)
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
                // The 22 pt button still answers a 28 pt target (it reaches
                // 3 past its edge, inside the bar's 4 pt inset).
                .contentShape(Rectangle().inset(by: -AtticControlSize.hitOutset(for: size.height)))
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
    var nativeInputIdentifier: String? = nil
    /// Top glass (2026-10-22): on the top line, which content scrolls
    /// under, the field floats on the raised material at the Medium height
    /// (as the add bar does) instead of the recessed fill. The find bar,
    /// on its own card, keeps the recessed field.
    var floating = false
    /// Esc, or a click on the "Esc" hint: the search ends.
    let onEscape: () -> Void
    /// The owner's panel design: the header's round 27 pt field (a 12 pt
    /// magnifier in a 27 pt cell, 12 pt text), with `accessory` (the filter
    /// button) in place of the Esc hint.
    var header = false
    var accessory: AnyView? = nil

    @Environment(\.atticDesign) private var design
    @Environment(\.atticCapture) private var capture
    @FocusState private var focused: Bool
    @State private var claim = AtticFieldClaim()

    /// The field's height: floating, the Medium height.
    static func height(floating: Bool) -> CGFloat {
        floating ? AtticTopGlassMetrics.height : AtticControlSize.smallHeight
    }

    var body: some View {
        let m = AtticTabsSearchMetrics.self
        let tokens = design.tokens
        let height = header ? AtticControlSize.headerControl : Self.height(floating: floating)
        let font = header ? Font.system(size: 12) : AtticTextStyle.listBody.font
        HStack(spacing: 0) {
            AtticIcon(systemName: "magnifyingglass", size: header ? 12 : m.iconSize, weight: AtticIconWeight.outline,
                      ink: header ? .glyph : .helper)
                .frame(width: header ? AtticControlSize.headerControl : AtticControlSize.statusCircle)
                .padding(.leading, header ? 0 : AtticLayout.circleX - AtticLayout.rowHighlightInset)
            Group {
                if capture == nil, let nativeInputIdentifier {
                    AtticNativeSearchInput(text: $text, placeholder: placeholder,
                        identifier: nativeInputIdentifier, isFocused: isFocused,
                        color: NSColor(tokens.color(.heading)), placeholderColor: NSColor(tokens.color(.helper)),
                        onEscape: onEscape)
                        .background(AtticFieldClaimProbe(claim: claim, placeholder: placeholder,
                            wanted: { isFocused?.wrappedValue == true }).accessibilityHidden(true))
                } else if capture == nil {
                    TextField("", text: $text, prompt: Text(verbatim: placeholder).foregroundStyle(tokens.color(.helper)))
                        .textFieldStyle(.plain)
                        .font(font)
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
            .padding(.leading, header ? 0 : AtticLayout.textX - AtticLayout.circleX - AtticControlSize.statusCircle)
            if header {
                if let accessory {
                    accessory.padding(.trailing, 3)
                }
            } else {
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
        }
        .frame(height: height)
        .modifier(AtticSearchFieldBacking(floating: floating, height: height, radius: header ? AtticRadius.header : nil))
        .contentShape(Rectangle())
        .onTapGesture {
            // The native field has no SwiftUI focus of its own: a click on
            // the magnifier or the padding gives its AppKit field the
            // keyboard directly (review P3).
            if nativeInputIdentifier != nil, capture == nil {
                if isFocused?.wrappedValue != true { isFocused?.wrappedValue = true }
                takeKeyboard(request: claim.beginFocusRequest())
            } else {
                focused = true
            }
        }
        .onAppear {
            if isFocused?.wrappedValue == true { requestKeyboard() }
        }
        .onDisappear { claim.cancelFocusRequest() }
        .onChange(of: focused) { _, now in if isFocused?.wrappedValue != now { isFocused?.wrappedValue = now } }
        .onChange(of: isFocused?.wrappedValue) { _, wanted in
            if wanted == true, !focused { requestKeyboard() }
            else if wanted == false {
                claim.cancelFocusRequest()
                focused = false
            }
        }
        .padding(.horizontal, header ? 0 : AtticLayout.rowHighlightInset)
    }

    private func requestKeyboard() {
        let request = claim.beginFocusRequest()
        for delay in [0.0, 0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard isFocused?.wrappedValue == true else { return }
                takeKeyboard(request: request)
            }
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
    private func takeKeyboard(request: Int) {
        guard isFocused?.wrappedValue ?? true, let window = NSApp.keyWindow else { return }
        if claim.takeKeyboard(request: request, in: window) { focused = true }
    }
}

/// The AppKit field a SwiftUI text field draws with, found from a probe
/// beside it (round 10: the ⌘F-after-Esc flake gave the keyboard to the
/// field still fading out with the last search, found first in the window).
@MainActor
final class AtticFieldClaim {
    weak var field: NSTextField?
    private(set) var focusGeneration = 0
    private var awaitingFocus = false

    func beginFocusRequest() -> Int {
        focusGeneration += 1
        awaitingFocus = true
        return focusGeneration
    }

    func cancelFocusRequest() {
        focusGeneration += 1
        awaitingFocus = false
    }

    /// Only the first acquisition places the caret. A retry never edits a
    /// selection, and a completed or superseded request cannot take focus.
    @discardableResult
    func takeKeyboard(request: Int, in window: NSWindow) -> Bool {
        guard request == focusGeneration, awaitingFocus,
              let field, field.window === window else { return false }
        if (window.firstResponder as? NSTextView)?.delegate as? NSTextField === field {
            awaitingFocus = false
            return true
        }
        guard window.makeFirstResponder(field), self.field === field, field.window === window,
              let editor = field.currentEditor(), window.firstResponder === editor else { return false }
        awaitingFocus = false
        editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        return true
    }
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
        private var attachmentGeneration = 0

        func configure(claim: AtticFieldClaim, placeholder: String, wanted: @escaping () -> Bool) {
            self.claim = claim
            self.placeholder = placeholder
            self.wanted = wanted
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachmentGeneration += 1
            guard let window else { claim?.cancelFocusRequest(); return }
            let attachment = attachmentGeneration
            let request = claim?.focusGeneration
            // Resolve this probe's field after layout, but never replay an
            // old attachment's focus request into a different field/window.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window,
                      self.attachmentGeneration == attachment, let field = self.ownField() else { return }
                self.claim?.field = field
                guard let request, self.wanted(), window.isKeyWindow || window.canBecomeKey else { return }
                self.claim?.takeKeyboard(request: request, in: window)
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

/// A search field's backing: the recessed fill, or, floating on the top
/// line, the raised material (not a button, so its glass does not answer
/// the pointer).
struct AtticSearchFieldBacking: ViewModifier {
    let floating: Bool
    let height: CGFloat
    var radius: CGFloat? = nil

    @Environment(\.atticDesign) private var design
    @Environment(\.atticControlCornerExponent) private var cornerExponent

    func body(content: Content) -> some View {
        let radius = radius ?? AtticRadius.control(height: height)
        if floating {
            content.atticRaisedMaterial(cornerRadius: radius, interactive: false)
        } else {
            content.background(AtticControlShape.shape(cornerRadius: radius, exponent: cornerExponent).fill(design.tokens.recessed.color))
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
    /// A quiet icon sits beside page labels (the tabs line's Find and View
    /// Options, design review D-10: icons are never darker than the words
    /// next to them): the secondary tier's ink instead of the primary glyph's
    /// (`AtticColorTokens.quietIconInk`).
    let quietIcon: Bool
    /// Top glass (2026-10-22): an icon on the top line, which content
    /// scrolls under, floats on its own glass circle like the corner
    /// buttons: the raised material at the Medium height, as wide as it is
    /// tall, hover and press as the material's fills.
    let floating: Bool
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.atticControlCornerExponent) private var cornerExponent
    @State private var hovered = false
    @State private var probeID = UUID()

    init(systemName: String?, title: String.LocalizationValue? = nil, label: String.LocalizationValue,
         quietIcon: Bool = false, floating: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName
        self.title = title.map { String(localized: $0) }
        self.accessibilityLabel = String(localized: label)
        self.quietIcon = quietIcon
        self.floating = floating
        self.action = action
    }

    var body: some View {
        let height = floating ? AtticTopGlassMetrics.height : AtticControlSize.smallHeight
        let radius = AtticRadius.control(height: height)
        let shape = AtticControlShape.shape(cornerRadius: radius, exponent: cornerExponent)
        Button(action: action) {
            AtticSmallButtonFace(systemName: systemName, title: title, quietIcon: quietIcon, radius: radius, hovered: hovered,
                                 floating: floating)
                .contentShape(shape)
        }
        .buttonStyle(AtticFlatPressStyle())
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .atticControlProbe("Small control", id: probeID, expectedSize: nil, radius: radius,
                           expectedRadius: floating ? AtticRadius.control(height: AtticTopGlassMetrics.height) : 12)
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
    let quietIcon: Bool
    let radius: CGFloat
    let hovered: Bool
    var floating = false

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @Environment(\.atticIsPressed) private var isPressed
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.atticControlCornerExponent) private var cornerExponent

    var body: some View {
        let tokens = design.tokens
        let state = AtticStateResolver(forced: forced, isEnabled: isEnabled, isHovered: hovered, isPressed: isPressed, isFocused: isFocused).state
        // Floating, the material shows hover and press itself.
        let fill: AtticRGBA = switch (floating, state) {
        case (false, .hover): tokens.chipHover
        case (false, .pressed): tokens.chipSelected
        default: .clear
        }
        let ink: AtticInk = state == .disabled ? .disabledIcon : (quietIcon ? tokens.quietIconInk : .glyph)
        HStack(spacing: AtticSmallControlMetrics.iconLabelGap) {
            if let systemName {
                AtticIcon(systemName: systemName, size: AtticSmallControlMetrics.iconSize, weight: .regular, ink: ink)
            }
            if let title {
                AtticText(verbatim: title, style: .controlLabel, ink: state == .disabled ? .disabledText : .heading)
            }
        }
        .padding(.horizontal, title == nil ? 0 : AtticSmallControlMetrics.labelPadding)
        .modifier(AtticSmallButtonFrame(floating: floating, iconOnly: title == nil))
        .background(AtticControlShape.shape(cornerRadius: radius, exponent: cornerExponent).fill(fill.color))
        .modifier(AtticSmallButtonGlass(floating: floating, radius: radius, state: state))
        .atticFocusRing(state == .focused, cornerRadius: radius)
    }
}

/// The small button's size: 28 tall and at least 32 wide; floating, the
/// Medium height, an icon alone in a circle as wide as it is tall.
private struct AtticSmallButtonFrame: ViewModifier {
    let floating: Bool
    let iconOnly: Bool

    func body(content: Content) -> some View {
        if floating {
            let height = AtticTopGlassMetrics.height
            content.frame(minWidth: height, maxWidth: iconOnly ? height : nil, minHeight: height, maxHeight: height)
        } else {
            content.frame(minWidth: AtticControlSize.smallMinWidth, minHeight: AtticControlSize.smallHeight,
                          maxHeight: AtticControlSize.smallHeight)
        }
    }
}

/// A floating small button's own glass (or its opaque stand-in), with the
/// face's state as the material's fill.
private struct AtticSmallButtonGlass: ViewModifier {
    let floating: Bool
    let radius: CGFloat
    let state: AtticControlState

    func body(content: Content) -> some View {
        if floating {
            content.atticRaisedMaterial(cornerRadius: radius, state: state, interactive: state != .disabled)
        } else {
            content
        }
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
                        .atticDropdown(isPresented: popover.isPresented, prefer: .above, label: String(localized: action.label)) { popover.content() }
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
    /// For UI tests and automation (Notes' menus): the item's identifier.
    var identifier: String?
    /// A tag colour's dot before the title (the tag menu's Colour row, tag
    /// filters and the multi-select tag action).
    var swatch: AtticTagHue?
    /// Any other image before the title (the highlighter's colours).
    var image: NSImage?
    /// A priority's mark before the title (↓ ! !!), as the priority
    /// picker draws it; `.none` keeps the column empty.
    var priority: AtticPriority?
    /// The title's own face (a style list's names in their styles).
    var titleFont: NSFont?
    /// A submenu's card width when it is not the command width: Tags ›
    /// (224 pt) and Date › (200 pt), per `AtticMenuMetrics`.
    var menuWidth: CGFloat?
    /// Why a dimmed command can't run now (one-item plan, "Menus and
    /// keyboard": disabled commands explain why). VoiceOver reads it as the
    /// row's help; nothing changes in how the row looks.
    var disabledReason: String?
    let action: () -> Void

    init(
        _ title: String.LocalizationValue,
        systemImage: String? = nil,
        shortcut: KeyboardShortcut? = nil,
        isDestructive: Bool = false,
        isDisabled: Bool = false,
        startsSection: Bool = false,
        isChecked: Bool = false,
        identifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.init(verbatim: String(localized: title), systemImage: systemImage, shortcut: shortcut, isDestructive: isDestructive,
                  isDisabled: isDisabled, startsSection: startsSection, state: isChecked ? .on : nil, action: action)
        self.identifier = identifier
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
        swatch: AtticTagHue? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.swatch = swatch
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.isDestructive = isDestructive
        self.isDisabled = isDisabled
        self.startsSection = startsSection
        self.state = state
        self.detail = detail
        self.action = action
    }

    /// A submenu with an identifier (Notes' Insert ▸ and Format ▸).
    init(_ title: String.LocalizationValue, startsSection: Bool = false, identifier: String? = nil,
         submenu: [AtticMenuCommand]) {
        self.init(title, startsSection: startsSection, identifier: identifier, action: {})
        children = submenu
    }

    /// A submenu.
    static func submenu(_ title: String, systemImage: String? = nil, startsSection: Bool = false,
                        isDisabled: Bool = false, width: CGFloat? = nil, _ children: [AtticMenuCommand]) -> AtticMenuCommand {
        var command = AtticMenuCommand(verbatim: title, systemImage: systemImage, isDisabled: isDisabled || children.isEmpty,
                                       startsSection: startsSection) {}
        command.children = children
        command.menuWidth = width
        return command
    }

    /// Bare keys belong to the list, and are reference hints in a menu.
    /// NSMenu's tracking loop matches key equivalents internally, bypassing
    /// performKeyEquivalent and local event monitors. Return must therefore
    /// never be registered as Edit Title's native menu equivalent.
    var menuShortcut: KeyboardShortcut? {
        guard let shortcut, !shortcut.modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        return shortcut
    }

    var menuBadge: String? {
        let hint = menuShortcut == nil ? shortcut.map(Self.shortcutHint) : nil
        let parts = [detail, hint].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func shortcutHint(_ shortcut: KeyboardShortcut) -> String {
        let key: String
        switch shortcut.key {
        case .return: key = "↩"
        case .space: key = String(localized: "Space")
        case .delete: key = "⌫"
        case .deleteForward: key = "⌦"
        case .upArrow: key = "↑"
        case .downArrow: key = "↓"
        case .leftArrow: key = "←"
        case .rightArrow: key = "→"
        case .escape: key = "⎋"
        case .tab: key = "⇥"
        default: key = String(shortcut.key.character).uppercased()
        }
        return (shortcut.modifiers.contains(.shift) ? "⇧" : "") + key
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

    /// The command a key belongs to, enabled or not (a disabled command
    /// consumes its key: it does nothing rather than letting the key fall
    /// through to something else).
    static func keyOwner(for shortcut: KeyboardShortcut, in commands: [AtticMenuCommand]) -> AtticMenuCommand? {
        for command in commands {
            if !command.isHeader, command.children.isEmpty,
               let own = command.shortcut, own.key == shortcut.key, own.modifiers == shortcut.modifiers {
                return command
            }
            if let found = Self.keyOwner(for: shortcut, in: command.children) { return found }
        }
        return nil
    }

    /// The same command, dimmed, with the reason it can't run now.
    func disabled(because reason: String?) -> AtticMenuCommand {
        var copy = self
        copy.isDisabled = true
        copy.disabledReason = reason
        return copy
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
    /// ⇧⌘I opens the line's whole menu (`showActions`, control audit item
    /// 5), as it does a task row's.
    static func performSubtaskKey(key: KeyEquivalent, characters: String, modifiers: EventModifiers,
                                  in commands: [AtticMenuCommand], showActions: (() -> Void)? = nil) -> KeyPress.Result {
        if let showActions, !commands.isEmpty,
           AtticTaskKeys.command(key: key, characters: characters, modifiers: modifiers, listCommands: true) == .showActions {
            showActions()
            return .handled
        }
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

/// A glass menu (draft C, `AtticGlassMenu`) opened by an Attic-drawn label.
/// In captures, where `ImageRenderer` cannot draw AppKit, only the label is
/// drawn.
struct AtticCommandMenu<Label: View>: View {
    let commands: [AtticMenuCommand]
    let accessibilityLabel: String
    @ViewBuilder let label: Label

    @Environment(\.atticCapture) private var capture
    @State private var anchor = AtticMenuAnchor.Holder()

    var body: some View {
        if capture != nil {
            label
        } else {
            // Draft C: the glass menu, under its label.
            Button {
                guard let view = anchor.view else { return }
                AtticNativeMenu.popUp(commands, in: view)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .fixedSize()
            .background(AtticMenuAnchor(holder: anchor).accessibilityHidden(true))
            // A menu button for VoiceOver and Full Keyboard Access, as the
            // native menu's opener was: Press and Show Menu open it.
            .accessibilityRepresentation {
                AtticMenuButtonAccessibility(label: accessibilityLabel) { view in AtticNativeMenu.popUp(commands, in: view) }
            }
        }
    }
}

/// A glass menu's opener as VoiceOver sees it: a menu button (the role a
/// native pop-up menu's control has) whose Press and Show Menu open it.
struct AtticMenuButtonAccessibility: NSViewRepresentable {
    let label: String
    let open: (NSView) -> Void

    final class ButtonView: NSView {
        var open: ((NSView) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func accessibilityPerformPress() -> Bool {
            guard let open else { return false }
            open(self)
            return true
        }
        override func accessibilityPerformShowMenu() -> Bool { accessibilityPerformPress() }
    }

    func makeNSView(context: Context) -> ButtonView { ButtonView() }

    func updateNSView(_ view: ButtonView, context: Context) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.menuButton)
        view.setAccessibilityLabel(label)
        view.setAccessibilityHelp(String(localized: "Opens a menu"))
        view.open = open
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
            Toggle(isOn: Binding(get: { state == .on }, set: { _ in choose(command) })) { label(command) }
                .disabled(command.isDisabled)
                .modifier(AtticMenuShortcut(shortcut: command.menuShortcut))
                .modifier(AtticMenuBadge(detail: command.menuBadge))
        } else {
            Button(role: command.isDestructive ? .destructive : nil, action: { choose(command) }) {
                if command.state == .mixed {
                    // Some of the targets have it: a dash.
                    SwiftUI.Label(command.title, systemImage: "minus")
                } else {
                    label(command)
                }
            }
            .disabled(command.isDisabled)
            .modifier(AtticMenuShortcut(shortcut: command.menuShortcut))
            .modifier(AtticMenuBadge(detail: command.menuBadge))
        }
    }

    /// A chosen item: its command runs as a menu choice, so a field under
    /// the menu never takes the Return or click that chose it.
    private func choose(_ command: AtticMenuCommand) {
        AtticTextInput.choosing(command.menuShortcut, command.action)
    }

    @ViewBuilder
    private func label(_ command: AtticMenuCommand) -> some View {
        if let systemImage = command.systemImage {
            SwiftUI.Label(command.title, systemImage: systemImage)
        } else if let image = command.image {
            SwiftUI.Label { Text(verbatim: command.title) } icon: { Image(nsImage: image) }
        } else if let swatch = command.swatch {
            SwiftUI.Label { Text(verbatim: command.title) } icon: { Image(nsImage: AtticTagSwatch.image(swatch)) }
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

/// A native menu's trailing tick: this far past the menu's widest title.
enum AtticMenuTickMetrics {
    static let gap: CGFloat = 16
}

/// The same commands as an `NSMenu` (round 10): what a row's actions
/// button, ⇧⌘I and the selection bar open, anchored to a view. Native in
/// every way (keyboard, type-to-select, VoiceOver), with each command's
/// state, shortcut and detail as `AtticMenuItems` draws them.
@MainActor
enum AtticNativeMenu {
    /// The menu for `commands`.
    static func make(_ commands: [AtticMenuCommand], title: String = "") -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        // The tick after the item (N-4's card design, owner 2026-10-11: on
        // every dropdown): a menu with choices draws no leading tick column,
        // and each chosen item ends in its tick, one column for the menu.
        let tickColumn = trailingTickColumn(commands)
        if tickColumn != nil { menu.showsStateColumn = false }
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
            menu.addItem(item(command, tickColumn: tickColumn))
        }
        return menu
    }

    /// Where a menu's trailing ticks go (from the titles' start): past its
    /// widest title, or nil for a menu with no choice in it.
    static func trailingTickColumn(_ commands: [AtticMenuCommand]) -> CGFloat? {
        let items = commands.filter { !$0.isHeader }
        guard items.contains(where: { $0.state != nil }) else { return nil }
        let font = NSFont.menuFont(ofSize: 0)
        let widest = items.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return ceil(widest) + AtticMenuTickMetrics.gap
    }

    /// `title` with its tick (or the mixed dash) after it, at `column`.
    static func tickedTitle(_ title: String, state: AtticCheckState, column: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: column)]
        let mark = state == .mixed ? "\u{2013}" : "\u{2713}"
        return NSAttributedString(string: title + "\t" + mark,
                                  attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: paragraph])
    }

    /// A menu opened the way the system opens a right-click menu. AppKit
    /// appends the context-menu plug-ins to such a menu (the system's
    /// AutoFill submenu, Services) wherever a text input could be its
    /// target; these are Attic's own menus, so they get none (design review
    /// D-14: a stray "AutoFill ›" ended Notes' ⋯ menu).
    static func makeContextMenu(_ commands: [AtticMenuCommand], appearance: NSAppearance?) -> NSMenu {
        let menu = make(commands)
        menu.allowsContextMenuPlugIns = false
        menu.appearance = appearance
        return menu
    }

    private static func item(_ command: AtticMenuCommand, tickColumn: CGFloat? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: command.title, action: nil, keyEquivalent: "")
        item.keyEquivalentModifierMask = []
        if let systemImage = command.systemImage, command.state != .mixed {
            item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        } else if let image = command.image {
            item.image = image
        } else if let swatch = command.swatch, command.state != .mixed {
            item.image = AtticTagSwatch.image(swatch)
        }
        if !command.children.isEmpty {
            item.submenu = make(command.children, title: command.title)
        } else {
            item.target = AtticMenuTarget.shared
            item.action = #selector(AtticMenuTarget.runCommand(_:))
            item.representedObject = AtticMenuTarget.Box(command.action, keyEquivalent: command.menuShortcut)
        }
        switch command.state {
        case .on?: item.state = .on
        case .mixed?: item.state = .mixed
        case .off?, nil: item.state = .off
        }
        if let tickColumn {
            // The state stays the item's (VoiceOver reads it); only where
            // the tick is drawn moves, to the end.
            item.onStateImage = nil
            item.mixedStateImage = nil
            if let state = command.state, state != .off {
                item.attributedTitle = tickedTitle(command.title, state: state, column: tickColumn)
                item.setAccessibilityTitle(command.title)
            }
        }
        item.isEnabled = !command.isDisabled
        if let shortcut = command.menuShortcut, let key = keyEquivalent(shortcut.key) {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = modifiers(shortcut.modifiers)
        }
        if let detail = command.menuBadge { item.badge = NSMenuItemBadge(string: detail) }
        if let identifier = command.identifier {
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            item.setAccessibilityIdentifier(identifier)
        }
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

    // Opening a menu: every route opens Attic's glass menu (draft C, owner
    // 2026-10-23), which supersedes the native look for these menus. The
    // `NSMenu` builders above stay for the menu bar's Format menu and the
    // text editor's own context menu, which are the system's.

    /// Opens the menu under `rect` (in `view`'s coordinates), aligned to
    /// its leading edge (above it at the screen's bottom), and returns when
    /// it closes (Notes' ⋯ and ⇧⌘I, whose callers restore the keyboard
    /// afterwards).
    static func popUp(_ commands: [AtticMenuCommand], below rect: NSRect, in view: NSView) {
        AtticGlassMenu.popUp(commands, in: view, placement: .below(rect))
    }

    /// Opens the menu under `view` (or with its top-left at `point` in its
    /// coordinates), as a pop-up button does. Returns at once: the menu
    /// tracks on the next turn, so the caller's own event finishes.
    static func popUp(_ commands: [AtticMenuCommand], in view: NSView, at point: CGPoint? = nil) {
        AtticGlassMenu.popUpLater(commands, in: view, placement: point.map { .point($0) } ?? .below(view.bounds))
    }

    /// The right-click style (A39 F06, CU recheck 3): with glass menus the
    /// same as `popUp(_:below:in:)`, whose submenus are placed beside their
    /// rows with their titles whole.
    static func popUpContextMenu(_ commands: [AtticMenuCommand], below rect: NSRect, in view: NSView) {
        AtticGlassMenu.popUp(commands, in: view, placement: .below(rect))
    }

    /// Opens the menu with its top left at `point` in `view` (under its
    /// bottom-left corner by default) on the next turn: a row's actions
    /// (⇧⌘I, the row's ⋯, VoiceOver's Show actions).
    static func popUpContextMenu(_ commands: [AtticMenuCommand], in view: NSView, at point: CGPoint? = nil) {
        AtticGlassMenu.popUpLater(commands, in: view, placement: point.map { .point($0) } ?? .below(view.bounds))
    }
}

/// Runs a native menu item's command.
@MainActor
final class AtticMenuTarget: NSObject {
    static let shared = AtticMenuTarget()

    final class Box {
        let action: () -> Void
        let keyEquivalent: KeyboardShortcut?
        init(_ action: @escaping () -> Void, keyEquivalent: KeyboardShortcut? = nil) {
            self.action = action
            self.keyEquivalent = keyEquivalent
        }
    }

    /// Not `perform(_:)`: that is NSObject's `performSelector:`, which the
    /// selector resolved to, so a chosen item ran nothing (round 10, CI run 2).
    /// The command runs as a menu choice (`AtticTextInput.choosing`).
    @objc func runCommand(_ item: NSMenuItem) {
        guard let box = item.representedObject as? Box else { return }
        AtticTextInput.choosing(box.keyEquivalent, box.action)
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
    /// The anchor, when a key opens the same menu (follow-up part 2: ⌥⌘V
    /// opens View Options under its button).
    var holder: AtticMenuAnchor.Holder? = nil
    /// A small accent dot at the glyph's top trailing corner: the menu's
    /// choices hide something (an active filter).
    var showsDot = false
    /// What VoiceOver reads as the button's value (the current choice).
    var value: String? = nil
    /// A quiet icon (see `AtticSmallButton.quietIcon`).
    var quietIcon = false
    /// On its own glass circle (see `AtticSmallButton.floating`).
    var floating = false

    @State private var ownAnchor = AtticMenuAnchor.Holder()

    var body: some View {
        let anchor = holder ?? ownAnchor
        AtticSmallButton(systemName: systemName, label: label, quietIcon: quietIcon, floating: floating) {
            guard let view = anchor.view else { return }
            AtticNativeMenu.popUp(commands(), in: view)
        }
        .overlay(alignment: .topTrailing) {
            if showsDot { AtticMenuButtonDot().allowsHitTesting(false) }
        }
        .background(AtticMenuAnchor(holder: anchor).accessibilityHidden(true))
        .accessibilityHint(String(localized: "Opens a menu"))
        .accessibilityValue(value ?? "")
    }
}

/// The menu button's dot: 5 pt in the accent, 6 pt in from the control's
/// top trailing corner, on the glyph's corner.
private struct AtticMenuButtonDot: View {
    @Environment(\.atticDesign) private var design

    var body: some View {
        Circle()
            .fill(design.tokens.color(.accent))
            .frame(width: AtticMenuButtonMetrics.dotSize, height: AtticMenuButtonMetrics.dotSize)
            .padding(.top, AtticMenuButtonMetrics.dotInset)
            .padding(.trailing, AtticMenuButtonMetrics.dotInset)
            .accessibilityHidden(true)
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
    /// nil: no tick column. Otherwise the tick's column at the row's end,
    /// ticked when true (N-4's card design: the tick after the item).
    var checked: Bool?
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    @State private var probeID = UUID()

    init(systemName: String?, title: String, detail: String? = nil, isHighlighted: Bool = false,
         reservesIconSlot: Bool = false, checked: Bool? = nil, action: @escaping () -> Void) {
        self.systemName = systemName
        self.title = title
        self.detail = detail
        self.isHighlighted = isHighlighted
        self.reservesIconSlot = reservesIconSlot
        self.checked = checked
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
                if let checked {
                    Group {
                        if checked {
                            AtticIcon(systemName: "checkmark", size: AtticDropdownMetrics.checkSize, weight: .semibold, ink: .glyph)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: AtticDropdownMetrics.checkSlot)
                    .accessibilityHidden(true)
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
        .accessibilityValue(checked == true ? String(localized: "Selected") : "")
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

/// Literal native edits do not change the field's allocated geometry or
/// invalidate the surrounding task page. External replacements still update.
private struct AtticNativeSearchInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let identifier: String
    let isFocused: Binding<Bool>?
    let color: NSColor
    let placeholderColor: NSColor
    let onEscape: () -> Void

    final class Field: NSTextField {
        /// The field took the keyboard (a click back into it, ⌘F, Search).
        var onFocus: (() -> Void)?
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 18) }
        // The font and single-line height are fixed; typing changes neither.
        override func invalidateIntrinsicContentSize() {}

        /// Focus counts from the moment the field has the keyboard, not
        /// from its first edit (`controlTextDidBeginEditing`): ↓ after a
        /// click back into the field reaches the results (review P3).
        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { onFocus?() }
            return became
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Field, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: 18)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = true
        field.isSelectable = true
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel(placeholder)
        field.setAccessibilityIdentifier(identifier)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.owner = self
        let coordinator = context.coordinator
        field.onFocus = { [weak coordinator] in
            guard let owner = coordinator?.owner, owner.isFocused?.wrappedValue != true else { return }
            owner.isFocused?.wrappedValue = true
        }
        field.font = AtticTextStyle.listBody.nsFont
        field.textColor = color
        field.placeholderAttributedString = NSAttributedString(string: placeholder,
            attributes: [.font: AtticTextStyle.listBody.nsFont, .foregroundColor: placeholderColor])
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var owner: AtticNativeSearchInput
        init(_ owner: AtticNativeSearchInput) { self.owner = owner }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            owner.text = field.stringValue
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            if owner.isFocused?.wrappedValue != true { owner.isFocused?.wrappedValue = true }
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            if owner.isFocused?.wrappedValue == true { owner.isFocused?.wrappedValue = false }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            owner.onEscape()
            return true
        }
    }
}

/// The add field's plus (the owner's panel design: two 1.7 px strokes).
struct AtticPlusGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
