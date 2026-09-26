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
    let action: () -> Void

    @State private var probeID = UUID()

    /// Icon only. `label` is what VoiceOver and the tooltip say.
    init(systemName: String, label: String.LocalizationValue, size: CGSize = AtticControlSize.panelButton, help: String? = nil,
         isSelected: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName
        self.title = nil
        self.accessibilityLabel = String(localized: label)
        self.size = size
        self.help = help
        self.isSelected = isSelected
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
            AtticRaisedButtonLabel(systemName: systemName, title: title, isSelected: isSelected)
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
                AtticIcon(systemName: systemName, size: title == nil ? AtticControlSize.raisedGlyph : AtticRaisedButtonMetrics.labelIconSize, weight: AtticIconWeight.outline, ink: glyph)
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

// MARK: - Page switch (group capsule with nested chips)

/// Icons in one capsule; the selected one also shows its label. Every icon
/// has a tooltip with its shortcut and a VoiceOver label, and announces its
/// selected state. The capsule is 34 tall, radius 14.5; chips are 26 tall,
/// radius 10.5 (nested: 14.5 − 4), inset 4.
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
    /// The gallery pins a state on one chip only; nil pins it on all.
    var statePinnedPage: Page?

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @Environment(\.atticCapture) private var capture
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
            // FocusState is read here, in the body (and only live: captures
            // have no focus system), not in the ForEach below.
            decorations(geometry: geometry, selected: selected, focused: capture == nil ? focusedPage : nil, hovered: hoveredPage)
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
            if capture == nil {
                hitLayer(geometry: geometry, selected: selected)
                    .transaction { $0.animation = nil }
            } else {
                // Captures draw the chips' frames without the live buttons.
                captureProbes(geometry: geometry, selected: selected)
            }
        }
        .frame(width: geometry.innerWidth, height: chipHeight, alignment: .topLeading)
        .padding(AtticControlSize.capsuleInset)
        .frame(height: AtticControlSize.capsuleHeight)
        .atticRaisedMaterial(cornerRadius: AtticRadius.control(height: AtticControlSize.capsuleHeight), interactive: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Pages"))
        .atticControlProbe(
            "Page switch", id: probeID, expectedSize: nil,
            radius: AtticRadius.control(height: AtticControlSize.capsuleHeight),
            expectedRadius: 14.5
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

    /// In captures: the chips' frames, reported to the check.
    private func captureProbes(geometry: Geometry, selected: Int) -> some View {
        HStack(spacing: geometry.spacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                AtticPageChipFrame(isSelected: index == selected, size: CGSize(width: geometry.width(of: index, selected: selected), height: AtticControlSize.chipHeight))
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
            AtticIcon(systemName: item.systemName, size: m.iconSize, weight: .regular, ink: .glyph)
                .opacity(isSelected ? 1 : 0)
                .transformEnvironment(\.atticProbesDisabled) { if !isSelected { $0 = true } }
            AtticIcon(systemName: item.systemName, size: m.iconSize, weight: AtticIconWeight.outline, ink: .icon)
                .opacity(isSelected ? 0 : 1)
                .transformEnvironment(\.atticProbesDisabled) { if isSelected { $0 = true } }
        }
        .frame(width: m.iconSlot, height: AtticControlSize.chipHeight)
    }
}

/// A chip's frame as the check sees it (size and nested radius).
private struct AtticPageChipFrame: View {
    let isSelected: Bool
    let size: CGSize
    @State private var probeID = UUID()

    var body: some View {
        Color.clear
            .frame(width: size.width, height: size.height)
            .atticPageChipProbe(id: probeID, isSelected: isSelected)
    }
}

private extension View {
    func atticPageChipProbe(id: UUID, isSelected: Bool) -> some View {
        atticControlProbe(
            "Page chip", id: id,
            expectedSize: isSelected ? nil : CGSize(width: AtticControlSize.chipIconWidth, height: AtticControlSize.chipHeight),
            radius: AtticRadius.nestedChip,
            expectedRadius: AtticRadius.nested(outer: AtticRadius.control(height: AtticControlSize.capsuleHeight), gap: AtticControlSize.capsuleInset) ?? 0
        )
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
        .keyboardShortcut(item.keyEquivalent.map { KeyboardShortcut($0, modifiers: .command) })
        .help("\(item.title) (\(item.shortcut))")
        .accessibilityLabel(item.title)
        .accessibilityIdentifier(item.accessibilityIdentifier ?? item.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .atticPageChipProbe(id: probeID, isSelected: isSelected)
    }
}

// MARK: - Page pill

/// The page pill (v9): a small pill of dots, the dark one the current page,
/// centred above the add bar. Under the pointer (or keyboard focus) it
/// opens into the pages' icons with the pointed-at page's name above it; a
/// click goes there, and it folds back when the pointer leaves. Opening is
/// a spring of position and opacity (the icons slide out from the dots);
/// Reduce Motion crossfades.
///
/// One control for the keyboard: it takes focus once, ← → move between
/// the pages while it has it. VoiceOver reads one group, "Pages", with a
/// named, selectable choice per page.
struct AtticPagePill<Page: Hashable>: View {
    typealias Icon = AtticPagePillIcon

    struct Item: Identifiable {
        let page: Page
        let title: String
        let icon: Icon
        var accessibilityIdentifier: String?
        var id: String { title }
    }

    let items: [Item]
    @Binding var selection: Page
    /// The gallery and captures pin it open (or shut); nil follows the
    /// pointer and focus.
    var pinnedOpen: Bool?
    /// The gallery pins the pointer on one page.
    var pinnedHover: Page?

    @Environment(\.atticDesign) private var design
    @Environment(\.atticCapture) private var capture
    @Environment(\.atticKeyboardFocusVisible) private var keyboardFocusVisible
    @FocusState private var focused: Bool
    @State private var hovering = false
    @State private var hoveredPage: Page?

    private typealias M = AtticPagePillMetrics

    private var isOpen: Bool {
        pinnedOpen ?? (hovering || (focused && keyboardFocusVisible))
    }

    var body: some View {
        let count = items.count
        let selected = items.firstIndex { $0.page == selection } ?? 0
        let open = isOpen
        let hovered = pinnedHover ?? hoveredPage
        ZStack(alignment: .bottom) {
            collapsed(count: count, selected: selected)
                .opacity(open ? 0 : 1)
            expanded(count: count, selected: selected, hovered: hovered, open: open)
                .opacity(open ? 1 : 0)
            if capture == nil {
                hitLayer(count: count)
            }
        }
        .frame(width: M.expandedWidth(count: count), height: M.expandedHeight, alignment: .bottom)
        .overlay(alignment: .top) {
            if open, let hovered, let index = items.firstIndex(where: { $0.page == hovered }) {
                tooltip(items[index].title)
                    .offset(x: M.segmentCentre(index, count: count), y: -(M.tooltipHeight + M.tooltipGap))
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(motion, value: open)
        .animation(AtticMotionPreset.hover.animation(reduceMotion: design.reduceMotion), value: hovered)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if !inside { hoveredPage = nil }
        }
        .focusable(capture == nil)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.intersection([.command, .option, .control, .shift]).isEmpty else { return .ignored }
            let step: Int
            switch press.key {
            case .leftArrow: step = -1
            case .rightArrow: step = 1
            default: return .ignored
            }
            let next = min(max(selected + step, 0), count - 1)
            guard next != selected else { return .handled }
            select(items[next].page)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Pages"))
    }

    private var motion: Animation? {
        design.reduceMotion
            ? .easeOut(duration: AtticMotionPreset.popover.duration)
            : .spring(duration: AtticMotionPreset.expand.duration, bounce: 0)
    }

    private func select(_ page: Page) {
        withAnimation(AtticMotionPreset.slide.animation(reduceMotion: design.reduceMotion)) {
            selection = page
        }
    }

    private func pillFill(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = design.mode == .dark
        return shape
            .fill(design.tokens.popoverFill.color)
            .overlay(shape.strokeBorder(Color.black.opacity(dark ? 0.5 : 0.07), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(dark ? 0.30 : 0.08), radius: dark ? 4 : 5, y: dark ? 2 : 1.5)
    }

    private func collapsed(count: Int, selected: Int) -> some View {
        ZStack {
            pillFill(radius: M.collapsedHeight / 2)
                .frame(width: M.collapsedWidth(count: count), height: M.collapsedHeight)
            ForEach(0..<count, id: \.self) { index in
                // The current page's dot in the helper grey, the others in
                // the quiet grey of a done disc (v9).
                Circle()
                    .fill(index == selected ? design.tokens.color(.helper) : design.tokens.doneDisc.color)
                    .frame(width: M.dotSize, height: M.dotSize)
                    .offset(x: M.dotCentre(index, count: count))
            }
        }
        .frame(height: M.collapsedHeight)
        .accessibilityHidden(true)
    }

    private func expanded(count: Int, selected: Int, hovered: Page?, open: Bool) -> some View {
        let inner = AtticRadius.nested(outer: M.expandedRadius, gap: M.inset) ?? M.expandedRadius
        return ZStack {
            pillFill(radius: M.expandedRadius)
                .frame(width: M.expandedWidth(count: count), height: M.expandedHeight)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ZStack {
                    RoundedRectangle(cornerRadius: inner, style: .continuous)
                        .fill((item.page == hovered ? design.tokens.hover : .clear).color)
                    AtticPagePillGlyph(icon: item.icon, ink: index == selected ? .heading : .icon)
                }
                .frame(width: M.segment.width, height: M.segment.height)
                // The icons slide out from the dots as the pill opens.
                .offset(x: open ? M.segmentCentre(index, count: count) : M.dotCentre(index, count: count))
            }
        }
        .frame(height: M.expandedHeight)
        .atticFocusRing(focused && keyboardFocusVisible && capture == nil, cornerRadius: M.expandedRadius)
        .accessibilityHidden(true)
    }

    /// The buttons: clicks, hover and VoiceOver. Transparent, in the opened
    /// pill's places whether it is open or not, so a click never lands on
    /// a moving target.
    private func hitLayer(count: Int) -> some View {
        HStack(spacing: M.segmentGap) {
            ForEach(items) { item in
                Button { select(item.page) } label: {
                    Color.clear
                        .frame(width: M.segment.width, height: M.segment.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { inside in
                    if inside { hoveredPage = item.page } else if hoveredPage == item.page { hoveredPage = nil }
                }
                .accessibilityLabel(item.title)
                .accessibilityIdentifier(item.accessibilityIdentifier ?? item.title)
                .accessibilityAddTraits(item.page == selection ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(M.inset)
    }

    private func tooltip(_ title: String) -> some View {
        AtticText(verbatim: title, style: .rowMeta, ink: .onInverse)
            .fixedSize()
            .padding(.horizontal, M.tooltipHorizontalPadding)
            .frame(height: M.tooltipHeight)
            .background(RoundedRectangle(cornerRadius: M.tooltipRadius, style: .continuous)
                .fill(design.tokens.color(.inverseFill)))
            .accessibilityHidden(true)
    }
}

/// The page pill's icons: the status circle's three states.
enum AtticPagePillIcon: Sendable { case open, dashed, done }

/// The page pill's icons, drawn at 15 pt.
struct AtticPagePillGlyph: View {
    let icon: AtticPagePillIcon
    let ink: AtticInk
    @Environment(\.atticDesign) private var design

    var body: some View {
        let m = AtticPagePillMetrics.self
        let colour = design.tokens.color(ink)
        ZStack {
            switch icon {
            case .open:
                Circle().inset(by: 2).stroke(colour, lineWidth: m.iconLineWidth)
            case .dashed:
                Circle().inset(by: 2).stroke(colour, style: StrokeStyle(lineWidth: m.iconLineWidth, lineCap: .round, dash: m.dash))
            case .done:
                Circle().inset(by: 1.3).fill(colour)
                AtticCheckShape()
                    .stroke(design.tokens.popoverFill.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .padding(4.4)
            }
        }
        .frame(width: m.iconSize, height: m.iconSize)
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
                    AtticText(verbatim: placeholder, style: .body, ink: disabled ? .disabledText : .placeholder)
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
                    AtticText(verbatim: placeholder, style: .body, ink: disabled ? .disabledText : .placeholder)
                } else {
                    AtticText(verbatim: text, style: .body, ink: disabled ? .disabledText : .body, truncates: true)
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
            .font(AtticTextStyle.body.font)
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
