import SwiftUI

extension View {
    /// Applies a shortcut when there is one.
    @ViewBuilder
    func noteShortcut(_ shortcut: KeyboardShortcut?) -> some View {
        if let shortcut { keyboardShortcut(shortcut) } else { self }
    }
}

/// The springy entrance the bar, the format row and the `/` list share: a fade, a 4 pt
/// rise and a slight grow from the anchored edge; a plain fade under
/// Reduce Motion.
enum NoteFormatMotion {
    static func transition(reduceMotion: Bool, from edge: VerticalEdge) -> AnyTransition {
        if reduceMotion { return .opacity }
        let rise = AtticMotionPreset.popover.rise
        return .opacity
            .combined(with: .offset(y: edge == .bottom ? rise : -rise))
            .combined(with: .scale(scale: 0.96, anchor: edge == .bottom ? .bottom : .top))
    }

    static func animation(reduceMotion: Bool) -> Animation? {
        AtticMotionPreset.popover.springy(reduceMotion: reduceMotion)
    }

    // MARK: Aa grows into the format row (A28, mockup p2-37 draft 1)

    /// The glass: Aa's glass stretches into the bar (0.42 s, bounce 0.12) and,
    /// closing, shrinks back into Aa 110 ms after the controls went (0.38 s,
    /// bounce 0.08). Reduce Motion (and Animations: Reduced): none, at once.
    static func growAnimation(opening: Bool, reduceMotion: Bool) -> Animation? {
        if reduceMotion { return nil }
        return opening ? .spring(duration: 0.42, bounce: 0.12)
                       : .spring(duration: 0.38, bounce: 0.08).delay(0.11)
    }

    /// The bar's controls: they fade in 230 ms after Aa starts, once the
    /// glass is wide, and out at once (0.14 s) when closing.
    static func controlsAnimation(opening: Bool, reduceMotion: Bool) -> Animation? {
        if reduceMotion { return nil }
        return opening ? .spring(duration: 0.2, bounce: 0).delay(0.23)
                       : .spring(duration: 0.14, bounce: 0)
    }

    /// How long the pieces that are leaving stay mounted after a change
    /// (the longest of their animations, with its delay, and a margin).
    static let rowLingerAfterOpening: Duration = .milliseconds(650)
    static let barLingerAfterClosing: Duration = .milliseconds(300)

    enum Side { case left, right, middle }

    static func clamp(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }

    /// How far a bottom-row control has stepped aside, 0 (in place) to 1
    /// (gone), for the glass's growth `grow` (0 shut, 1 open, a little over
    /// while it bounces). New note (right) goes as soon as the glass starts
    /// moving; All notes (left) about half way, when the glass reaches it;
    /// whatever sits between them goes with Aa's label.
    static func steppedAside(_ side: Side, grow: CGFloat) -> CGFloat {
        switch side {
        case .right: clamp((grow - 0.02) / 0.30)
        case .left: clamp((grow - 0.5) / 0.38)
        case .middle: clamp(grow * 3)
        }
    }

    /// Aa's label fades out in the first third of the growth.
    static func aaLabelOpacity(grow: CGFloat) -> CGFloat { 1 - clamp(grow * 3) }

    /// The glass's horizontal extent: Aa's, grown to the whole row.
    static func glassExtent(aa: CGRect, rowWidth: CGFloat, grow: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        (aa.minX + (0 - aa.minX) * grow, aa.maxX + (rowWidth - aa.maxX) * grow)
    }

    /// What a control that steps aside shows at `progress` (0 to 1): half
    /// size, 10 pt towards Aa, faded.
    static func offset(_ side: Side, progress: CGFloat) -> CGFloat {
        switch side {
        case .right: -10 * progress
        case .left: 10 * progress
        case .middle: 0
        }
    }
    static func scale(_ side: Side, progress: CGFloat) -> CGFloat { side == .middle ? 1 : 1 - 0.5 * progress }
}

/// The glass's growth (0 Aa, 1 the whole bar) and the bar's controls (0
/// hidden, 1 shown), as animated numbers the bottom row's pieces read.
/// The stage's coordinate space: Aa reports its frame in it.
private let noteFormatStageSpace = "noteFormatRowStage"

private struct NoteFormatGrowKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct NoteFormatControlsKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct NoteFormatOpenKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    fileprivate var noteFormatGrow: CGFloat {
        get { self[NoteFormatGrowKey.self] }
        set { self[NoteFormatGrowKey.self] = newValue }
    }
    fileprivate var noteFormatControls: CGFloat {
        get { self[NoteFormatControlsKey.self] }
        set { self[NoteFormatControlsKey.self] = newValue }
    }
    fileprivate var noteFormatOpen: Bool {
        get { self[NoteFormatOpenKey.self] }
        set { self[NoteFormatOpenKey.self] = newValue }
    }
}

/// Carries one animated number into the environment: SwiftUI interpolates
/// `value` through the spring, so everything below reads the spring's own
/// curve (the glass's growth drives the neighbours' timing).
private struct NoteFormatChannel: ViewModifier, Animatable {
    var value: CGFloat
    let key: WritableKeyPath<EnvironmentValues, CGFloat>

    var animatableData: CGFloat {
        get { value }
        set { value = newValue }
    }

    func body(content: Content) -> some View { content.environment(key, value) }
}

extension View {
    /// A bottom-row control that steps aside as Aa's glass grows into the
    /// format row (All notes, the status, New note).
    func noteFormatStepsAside(_ side: NoteFormatMotion.Side) -> some View {
        modifier(NoteFormatStepAside(side: side))
    }

    /// Aa itself: it reports where it is, and while the glass morphs the
    /// morphing glass stands in for it.
    func noteFormatMorphSource() -> some View {
        modifier(NoteFormatMorphSource())
    }
}

private struct NoteFormatStepAside: ViewModifier {
    let side: NoteFormatMotion.Side
    @Environment(\.noteFormatGrow) private var grow

    func body(content: Content) -> some View {
        let k = NoteFormatMotion.steppedAside(side, grow: grow)
        content
            .scaleEffect(NoteFormatMotion.scale(side, progress: k))
            .offset(x: NoteFormatMotion.offset(side, progress: k))
            .opacity(1 - k)
    }
}

private struct NoteFormatAaFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0 { value = next }
    }
}

private struct NoteFormatMorphSource: ViewModifier {
    @Environment(\.noteFormatGrow) private var grow
    @Environment(\.noteFormatOpen) private var open

    func body(content: Content) -> some View {
        content
            .opacity(open || grow != 0 ? 0 : 1)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: NoteFormatAaFrameKey.self,
                                           value: proxy.frame(in: .named(noteFormatStageSpace)))
                }
            }
    }
}

// MARK: - Selection bar

/// The bar over a text selection (mockup p2-16 D, as p2-36 draws it): the
/// style menu, B I U S, link, highlight and inline code, each showing its
/// state.
struct NoteFormatBarView: View {
    @ObservedObject var model: NoteFormatModel
    @Environment(\.atticDesign) private var design

    var body: some View {
        ZStack {
            if model.barShown {
                bar
                    .transition(NoteFormatMotion.transition(reduceMotion: design.reduceMotion,
                                                            from: model.barBelow ? .top : .bottom))
            }
        }
        .animation(NoteFormatMotion.animation(reduceMotion: design.reduceMotion), value: model.barShown)
        .padding(AtticNoteFormatMetrics.shadowRoom)
        .accessibilityHidden(!model.barShown)
    }

    private var bar: some View {
        let snapshot = model.snapshot
        let focus = model.barKeyboardIndex
        return AtticFormatBarSurface {
            AtticCommandMenu(commands: model.styleMenu(from: .selectionBar),
                             accessibilityLabel: String(localized: "Style, \(NoteCommandCatalog.styleName(snapshot.paragraph))")) {
                AtticFormatStyleFace(title: NoteCommandCatalog.styleName(snapshot.paragraph),
                                     isKeyboardFocused: focus == 0,
                                     isEnabled: NoteCommandCatalog.styles.contains { snapshot.isEnabled($0) })
            }
            .help(String(localized: "Style"))
            .accessibilityIdentifier("notes-format-bar-style")
            AtticFormatGroup { toggles(NoteCommandCatalog.barMarks, startingAt: 1) }
            AtticFormatGroup { toggles(NoteCommandCatalog.barInline, startingAt: 1 + NoteCommandCatalog.barMarks.count) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Format bar"))
        .accessibilityIdentifier("notes-format-bar")
    }

    private func toggles(_ commands: [NoteFormatCommand], startingAt start: Int) -> some View {
        ForEach(Array(commands.enumerated()), id: \.offset) { offset, command in
            NoteFormatToggle(model: model, command: command, surface: .selectionBar,
                             width: AtticNoteFormatMetrics.barToggleWidth,
                             isKeyboardFocused: model.barKeyboardIndex == start + offset)
        }
    }
}

/// One command as a toggle, from the snapshot.
struct NoteFormatToggle: View {
    @ObservedObject var model: NoteFormatModel
    let command: NoteFormatCommand
    let surface: NoteCommandSurface
    let width: CGFloat
    var isKeyboardFocused = false
    /// An action (outdent, indent): no on/off value.
    var announcesState = true

    var body: some View {
        let snapshot = model.snapshot
        let label = NoteCommandCatalog.menuTitle(command).replacingOccurrences(of: "…", with: "")
        Group {
            if command == .mark(.highlight) {
                AtticFormatToggle(value: snapshot.value(command), label: label, help: NoteFormatModel.help(command),
                                  width: width, isKeyboardFocused: isKeyboardFocused,
                                  disabledReason: snapshot.disabledReason, action: run) { ink in
                    AtticHighlightGlyph(ink: ink, swatch: model.highlightSwatch)
                }
            } else {
                AtticFormatToggle(systemName: NoteCommandCatalog.symbol(command), value: snapshot.value(command),
                                  label: label, help: NoteFormatModel.help(command), width: width,
                                  isKeyboardFocused: isKeyboardFocused, disabledReason: snapshot.disabledReason,
                                  announcesState: announcesState, action: run)
            }
        }
        .disabled(!snapshot.isEnabled(command))
        .accessibilityIdentifier(NoteCommandRouter.identifier(command))
    }

    private func run() { model.run(command, from: surface) }
}

// MARK: - The format row (OD-14)

/// Aa's format row (p2-36 draft 1): the bottom row itself, turned into one
/// row of paragraph formatting while it is open. The caret line's style as
/// a pill (its list holds Title … Mono, each in its own style), then
/// Bulleted, Numbered, Checklist and Quote showing which applies, outdent
/// and indent, and ✕. Nothing floats over the note; marks stay on the
/// selection bar. ⌘T or ⌃Tab put the keyboard on it (← → Tab move, Return
/// or Space press, Esc closes); the text keeps the caret throughout.
struct NoteFormatRowView: View {
    @ObservedObject var model: NoteFormatModel
    /// The row draws its own glass (the gallery); the bottom row's switch
    /// supplies the one glass that grows out of Aa instead.
    var drawsGlass = true
    let onClose: () -> Void

    /// The row's width (the bottom row's).
    @State private var width: CGFloat = 0

    var body: some View {
        // A long style name ("Subheading") in a narrow panel: 24 pt cells.
        let m = AtticNoteFormatMetrics.self
        let roomy = width == 0 || Self.minimumWidth(snapshot: model.snapshot, toggleWidth: m.rowToggleWidth) <= width
        row(toggleWidth: roomy ? m.rowToggleWidth : m.rowCompactToggleWidth)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
                if abs(new - width) > 0.5 { width = new }
            }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Format"))
        .accessibilityIdentifier("notes-format-row")
    }

    private func row(toggleWidth: CGFloat) -> some View {
        let focus = model.rowKeyboardIndex
        let lists = NoteCommandCatalog.lists
        let indents = NoteCommandCatalog.indents
        return AtticFormatRowSurface(drawsGlass: drawsGlass) {
            NoteFormatStylePill(model: model, isKeyboardFocused: focus == 0)
            AtticFormatSeparator()
            AtticFormatGroup {
                ForEach(Array(lists.enumerated()), id: \.offset) { offset, command in
                    NoteFormatToggle(model: model, command: command, surface: .formatBar, width: toggleWidth,
                                     isKeyboardFocused: focus == 1 + offset)
                }
            }
            AtticFormatSeparator()
            AtticFormatGroup {
                ForEach(Array(indents.enumerated()), id: \.offset) { offset, command in
                    NoteFormatToggle(model: model, command: command, surface: .formatBar, width: toggleWidth,
                                     isKeyboardFocused: focus == 1 + lists.count + offset, announcesState: false)
                }
            }
            Spacer(minLength: 0)
            AtticFormatToggle(systemName: "xmark", value: .off, label: String(localized: "Close Format"),
                              help: String(localized: "Close (Esc)"), width: toggleWidth,
                              isKeyboardFocused: focus == NoteFormatRowItem.all.count - 1, announcesState: false,
                              action: onClose)
                .accessibilityIdentifier("notes-format-row-close")
        }
    }

    /// What the row needs before its flexible gap: the inset, the pill, two
    /// lines and the cells.
    static func minimumWidth(snapshot: NoteFormatSnapshot, toggleWidth: CGFloat) -> CGFloat {
        let m = AtticNoteFormatMetrics.self
        let label = ceil((NoteCommandCatalog.styleName(snapshot.paragraph) as NSString)
            .size(withAttributes: [.font: AtticTextStyle.controlLabel.nsFont]).width)
        let pill = label + 4 + m.barStyleChevron + 2 + m.barStylePadding * 2
        let separators = 2 * (1 + m.rowSeparatorPadding * 2)
        let cells = CGFloat(NoteFormatRowItem.all.count - 1) * toggleWidth
        return ceil(AtticControlSize.capsuleInset * 2 + pill + separators + cells)
    }
}

/// The bottom row or, while Aa's format row is open, the format row in
/// its place (they take turns in one place; nothing floats over the note).
/// Aa's glass grows into the row (A28, mockup p2-37 draft 1): one glass
/// shape stretches from Aa's frame to the bar's, New note and All notes
/// shrink towards it as it passes, and the bar's controls fade in once it
/// is wide; closing reverses it. Animations: Reduced and Reduce Motion
/// swap at once.
struct NoteFormatRowSwitch<Row: View>: View {
    @ObservedObject var state: NoteFormatRowState
    /// The format model of the note on screen (read as the row opens).
    let model: () -> NoteFormatModel?
    @ViewBuilder let row: Row

    @Environment(\.atticDesign) private var design
    /// The bottom row stays mounted while it steps aside, the bar while it
    /// fades; shut or open and still, only one of them is.
    @State private var rowLingers = false
    @State private var barLingers = false
    @State private var lingering: Task<Void, Never>?

    var body: some View {
        let open = state.isOpen
        let reduce = design.reduceMotion
        NoteFormatRowStage(open: open, showsRow: !open || rowLingers, showsBar: open || barLingers,
                           model: model, row: row, onClose: { state.close() })
            .modifier(NoteFormatChannel(value: open ? 1 : 0, key: \.noteFormatControls))
            .animation(NoteFormatMotion.controlsAnimation(opening: open, reduceMotion: reduce), value: open)
            .modifier(NoteFormatChannel(value: open ? 1 : 0, key: \.noteFormatGrow))
            .animation(NoteFormatMotion.growAnimation(opening: open, reduceMotion: reduce), value: open)
            .onChange(of: open) { _, nowOpen in settle(opening: nowOpen, reduceMotion: reduce) }
    }

    /// Unmounts what has left once its animation is over.
    private func settle(opening: Bool, reduceMotion: Bool) {
        lingering?.cancel()
        guard !reduceMotion else {
            rowLingers = false
            barLingers = false
            return
        }
        if opening { rowLingers = true; barLingers = false } else { barLingers = true; rowLingers = false }
        lingering = Task { @MainActor in
            try? await Task.sleep(for: opening ? NoteFormatMotion.rowLingerAfterOpening
                                                : NoteFormatMotion.barLingerAfterClosing)
            guard !Task.isCancelled else { return }
            if opening { rowLingers = false } else { barLingers = false }
        }
    }
}

/// The pieces of the bottom row and the format row, one over the other:
/// the bottom row, the one glass between Aa's frame and the bar's, the
/// bar's controls.
private struct NoteFormatRowStage<Row: View>: View {
    let open: Bool
    let showsRow: Bool
    let showsBar: Bool
    let model: () -> NoteFormatModel?
    let row: Row
    let onClose: () -> Void

    @Environment(\.noteFormatGrow) private var grow
    @Environment(\.noteFormatControls) private var controls
    @State private var aa: CGRect = .zero
    @State private var size: CGSize = .zero

    var body: some View {
        ZStack {
            if showsRow {
                row
                    // They leave: no touches, nothing for VoiceOver.
                    .allowsHitTesting(!open)
                    .accessibilityHidden(open)
            }
            if showsBar, let model = model() {
                NoteFormatRowView(model: model, drawsGlass: false, onClose: onClose)
                    .opacity(controls)
                    .allowsHitTesting(open)
                    .accessibilityHidden(!open)
            }
        }
        .environment(\.noteFormatOpen, open)
        .coordinateSpace(name: noteFormatStageSpace)
        // Behind the row and the bar, and no part of the layout: the glass
        // may bounce past the row's edge.
        .background { glass }
        .onPreferenceChange(NoteFormatAaFrameKey.self) { new in
            if new.width > 0, new != aa { aa = new }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { new in
            if abs(new.width - size.width) > 0.5 || abs(new.height - size.height) > 0.5 { size = new }
        }
    }

    /// The one glass shape and Aa's label on it. It is Aa's frame while the
    /// row is shut (then Aa's own button shows instead), the bar's frame
    /// when open.
    @ViewBuilder
    private var glass: some View {
        if aa.width > 0, size.width > 0, open || grow != 0 {
            let extent = NoteFormatMotion.glassExtent(aa: aa, rowWidth: size.width, grow: grow)
            let height = aa.height
            let radius = AtticRadius.control(height: height)
            // Offsets are from the stage's centre, where this empty anchor sits.
            let centreX = (extent.leading + extent.trailing) / 2 - size.width / 2
            let centreY = aa.midY - size.height / 2
            Color.clear
                .frame(width: max(0, extent.trailing - extent.leading), height: height)
                .atticRaisedMaterial(cornerRadius: radius, interactive: false)
                .overlay {
                    AtticIcon(systemName: "textformat", size: AtticControlSize.raisedGlyph,
                              weight: AtticIconWeight.outline, ink: .icon)
                        .opacity(NoteFormatMotion.aaLabelOpacity(grow: grow))
                        // Aa's label stays where Aa was.
                        .offset(x: aa.midX - (extent.leading + extent.trailing) / 2)
                }
                .offset(x: centreX, y: centreY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The format row's style pill ("List ⌄"): it opens the style list (E1).
struct NoteFormatStylePill: View {
    @ObservedObject var model: NoteFormatModel
    var isKeyboardFocused = false

    var body: some View {
        let snapshot = model.snapshot
        let name = NoteCommandCatalog.styleName(snapshot.paragraph)
        let enabled = NoteCommandCatalog.styles.contains { snapshot.isEnabled($0) }
        Button { model.rowStyleListOpen = true } label: {
            AtticFormatStyleFace(title: name, isKeyboardFocused: isKeyboardFocused, isEnabled: enabled)
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .disabled(!enabled)
        .help(String(localized: "Style"))
        .accessibilityLabel(String(localized: "Style"))
        .accessibilityValue(name)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("notes-format-row-style")
        .atticDropdown(isPresented: $model.rowStyleListOpen, prefer: .above, label: String(localized: "Style"),
                       contentHeight: AtticDropdownMetrics.inset * 2
                           + AtticDropdownMetrics.rowHeight * CGFloat(NoteCommandCatalog.styles.count)) {
            NoteFormatStyleListView(model: model)
        }
    }
}

/// The style list (E1 at the Compact size): Title, Heading, Subheading,
/// Body and Mono, each in its own style, the current one ticked. ↑ ↓ move,
/// Return or Space choose, Esc closes.
struct NoteFormatStyleListView: View {
    @ObservedObject var model: NoteFormatModel

    @State private var highlighted: Int?
    @FocusState private var focused: Bool

    private var styles: [NoteFormatCommand] { NoteCommandCatalog.styles }

    var body: some View {
        let snapshot = model.snapshot
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(styles.enumerated()), id: \.offset) { index, command in
                AtticDropdownRow(title: command.title,
                                 check: snapshot.value(command) == .on ? .on : .off,
                                 isHighlighted: highlighted == index,
                                 titleInk: snapshot.isEnabled(command) ? .heading : .disabledText,
                                 titleFont: NoteFormatStyleListView.kind(command).font,
                                 onHover: { inside in
                                     let next = AtticListHighlight.hovered(index, inside: inside, current: highlighted)
                                     if next != highlighted { highlighted = next }
                                 }, position: index + 1, itemCount: styles.count) { pick(command) }
                    .accessibilityIdentifier("notes-format-row-" + NoteCommandRouter.identifier(command))
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .atticDropdownFocus($focused)
        .onAppear {
            highlighted = styles.firstIndex { snapshot.value($0) == .on }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Style"))
        .accessibilityIdentifier("notes-format-style-list")
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .downArrow: highlighted = min((highlighted ?? -1) + 1, styles.count - 1); return .handled
            case .upArrow: highlighted = max((highlighted ?? styles.count) - 1, 0); return .handled
            case .return, .space:
                guard let highlighted else { return .ignored }
                pick(styles[highlighted])
                return .handled
            case .escape:
                model.rowStyleListOpen = false
                return .handled
            default: return .ignored
            }
        }
    }

    private func pick(_ command: NoteFormatCommand) {
        guard model.snapshot.isEnabled(command) else { NSSound.beep(); return }
        model.rowStyleListOpen = false
        model.run(command, from: .formatBar)
    }

    static func kind(_ command: NoteFormatCommand) -> AtticFormatStyleKind {
        switch command {
        case .paragraph(.heading(1)): .title
        case .paragraph(.heading(2)): .heading
        case .paragraph(.heading): .subheading
        case .paragraph(.mono): .mono
        default: .body
        }
    }
}

// MARK: - The / list

/// The flat `/` list at the caret (p2-03; E1, p2-24 D): one row per
/// engine item, icon and name only (no hint column), the typed filter
/// emboldened. The keyboard and the pointer move the one highlight. It
/// opens below the caret when there is room, its left edge on the `/`.
struct NoteSlashListView: View {
    @ObservedObject var model: NoteSlashListModel
    @Environment(\.atticDesign) private var design

    var body: some View {
        let preset = AtticMotionPreset.popover
        ZStack(alignment: model.above ? .bottomLeading : .topLeading) {
            if model.shown, !model.items.isEmpty {
                AtticDropdownCard(width: model.width) {
                    rows
                }
                .environment(\.atticDropdownHeight, model.viewportHeight)
                .transition(preset.transition(reduceMotion: design.reduceMotion, edge: model.above ? .bottom : .top,
                                              anchor: model.above ? .bottomLeading : .topLeading))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(String(localized: "Insert"))
                .accessibilityIdentifier("notes-slash-list")
            }
        }
        .animation(preset.animation(reduceMotion: design.reduceMotion, showing: model.shown), value: model.shown)
        .padding(AtticDropdownMetrics.shadowRoom)
        .fixedSize()
    }
}

extension NoteSlashListView {
    @ViewBuilder
    fileprivate var rows: some View {
        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
            AtticDropdownRow(title: item.title, systemName: NoteCommandCatalog.slashSymbol(item.kind), match: model.query,
                             isHighlighted: index == model.highlighted,
                             onHover: { inside in
                                 // The list always keeps one highlight (Return takes it).
                                 if inside, model.highlighted != index { model.highlighted = index }
                             }, position: index + 1, itemCount: model.items.count) {
                model.onPick?(item.kind)
            }
            .id(index)
            .accessibilityIdentifier("notes-slash-\(item.kind.rawValue)")
        }
    }
}

// MARK: - Date and link cards

/// The date card (owner, 2026-10-05: the shared `AtticDateCard`): typing
/// after `/date` shows one or two matching days above the month; Return
/// inserts what is lit (today when nothing is typed); a day in the month
/// inserts it; Esc puts the typed `/date` back.
struct NoteDateCardView: View {
    @ObservedObject var model: NoteFormatCardModel

    var body: some View {
        let today = model.today
        let calendar = model.calendar
        AtticDropdownCard {
            AtticDateCard(today: today, selected: nil, calendar: calendar, typed: $model.dateText,
                          parse: { NoteDateQuery.parse($0, today: today, calendar: calendar) },
                          onPick: { model.onCommitDate?($0) },
                          onCancel: { model.onCancel?() })
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Insert date"))
        .accessibilityIdentifier("notes-date-card")
    }
}

/// The link card (⇧⌘K, the link toggle, Edit Link…): the address and,
/// for an existing link, Remove. Return applies; Esc cancels.
struct NoteLinkCardView: View {
    @ObservedObject var model: NoteFormatCardModel
    let hasLink: Bool
    @FocusState private var fieldFocused: Bool
    @Environment(\.atticDesign) private var design

    var body: some View {
        AtticDropdownCard(width: AtticNoteFormatMetrics.linkCardWidth) {
            AtticDropdownField(text: $model.linkText, placeholder: String(localized: "Paste or type a link"),
                               focus: $fieldFocused, label: String(localized: "Link address"), identifier: "notes-link-field",
                               onSubmit: { model.submitLink() })
                .onExitCommand { model.onCancel?() }
            if let error = model.linkError {
                AtticText(verbatim: error, style: .helper, ink: .helper)
                    .padding(.horizontal, AtticDropdownMetrics.rowPadding)
                    .padding(.top, 4)
            }
            AtticDropdownGap()
            HStack(spacing: 4) {
                if hasLink {
                    AtticSmallButton(systemName: nil, title: "Remove", label: "Remove Link") { model.onRemoveLink?() }
                        .accessibilityIdentifier("notes-link-remove")
                }
                Spacer(minLength: 0)
                AtticSmallButton(systemName: nil, title: hasLink ? "Update" : "Add Link",
                                 label: hasLink ? "Update Link" : "Add Link") { model.submitLink() }
                    .disabled(model.linkText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("notes-link-apply")
            }
        }
        .onAppear { fieldFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Link"))
        .accessibilityIdentifier("notes-link-card")
    }
}

/// The card on screen, if any, with the shared motion.
struct NoteFormatCardView: View {
    @ObservedObject var model: NoteFormatCardModel
    @Environment(\.atticDesign) private var design

    var body: some View {
        let preset = AtticMotionPreset.popover
        let transition = preset.transition(reduceMotion: design.reduceMotion, edge: model.above ? .bottom : .top,
                                           anchor: model.above ? .bottomLeading : .topLeading)
        ZStack(alignment: model.above ? .bottomLeading : .topLeading) {
            switch model.card {
            case .date:
                NoteDateCardView(model: model).environment(\.atticDropdownHeight, model.viewportHeight).transition(transition)
            case let .link(hasLink):
                NoteLinkCardView(model: model, hasLink: hasLink).environment(\.atticDropdownHeight, model.viewportHeight).transition(transition)
            case nil:
                EmptyView()
            }
        }
        .environment(\.atticDropdownWidth, model.viewportWidth)
        .animation(preset.animation(reduceMotion: design.reduceMotion, showing: model.card != nil), value: model.card)
        .padding(AtticDropdownMetrics.shadowRoom)
        .fixedSize()
    }
}

/// Draft 7's hint (OD-14): "Type / for headings, lists, quotes…" on an
/// empty body line with the caret in it, faint, gone with the first
/// keystroke. Drawn only; VoiceOver hears it as the text's help.
struct NoteSlashHintView: View {
    static let text = String(localized: "Type / for headings, lists, quotes…")

    @Environment(\.atticDesign) private var design

    var body: some View {
        let size = AtticTextStyle.noteBody.nsFont.pointSize
        (Text(String(localized: "Type "))
            + Text(verbatim: "/").font(.system(size: size - 0.5, design: .monospaced))
            + Text(String(localized: " for headings, lists, quotes…")))
            .font(AtticTextStyle.noteBody.font)
            .foregroundStyle(design.tokens.color(.placeholder))
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
