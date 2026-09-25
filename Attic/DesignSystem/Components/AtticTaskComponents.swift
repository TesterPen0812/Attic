import SwiftUI

// MARK: - Actions

/// Everything a task row or card can do. Every callback is required, so a
/// control that is drawn is always wired: Phase 1 passes the store's
/// operations, the gallery records which one fired.
struct AtticTaskActions {
    /// The circle's click and Space: to do → in progress → done.
    let advance: () -> Void
    /// VoiceOver "Start".
    let start: () -> Void
    /// ⌥Space and VoiceOver "Complete": done in one step, whatever the state.
    let complete: () -> Void
    /// A click on the row, ⌘Return and VoiceOver "Open page".
    let openPage: () -> Void
    /// ⌘B and VoiceOver "Move to Backlog".
    let moveToBacklog: () -> Void
    /// Delete and VoiceOver "Delete".
    let delete: () -> Void

    /// The VoiceOver actions a task offers (spec § Accessibility: "Start,
    /// Complete, Open page, Move to Backlog, Delete"), in that order.
    var accessibilityActions: [(name: String, handler: () -> Void)] {
        [
            (String(localized: "Start"), start),
            (String(localized: "Complete"), complete),
            (String(localized: "Open page"), openPage),
            (String(localized: "Move to Backlog"), moveToBacklog),
            (String(localized: "Delete"), delete)
        ]
    }
}

/// The task keys a focused row or card answers (spec § Keyboard map):
/// Space starts or completes, ⌥Space completes, ⌘Return opens the page;
/// rows also take ⌘B (Backlog) and Delete. ↑ ↓ and ⌘↑ ⌘↓ belong to the
/// list, and Return (edit title) to the row's title editor, in Phase 1.
enum AtticTaskKeys {
    enum Command: Equatable { case advance, complete, openPage, moveToBacklog, delete }

    /// The command for a key, or nil when the key is not a task key.
    static func command(key: KeyEquivalent, characters: String, modifiers: EventModifiers, listCommands: Bool) -> Command? {
        let relevant = modifiers.intersection([.command, .option, .control, .shift])
        // ⌥Space types a non-breaking space, so match the characters too.
        if key == .space || characters == " " || characters == "\u{A0}" {
            if relevant == [] { return .advance }
            if relevant == .option { return .complete }
            return nil
        }
        if key == .return, relevant == .command { return .openPage }
        guard listCommands else { return nil }
        // Backspace arrives as U+007F (or U+0008), forward delete as U+F728.
        let deletes: Set<Character> = [KeyEquivalent.delete.character, KeyEquivalent.deleteForward.character, "\u{7F}", "\u{8}", "\u{F728}"]
        if deletes.contains(key.character) || characters.first.map(deletes.contains) == true, relevant == [] { return .delete }
        if relevant == .command, key.character == "b" || characters.lowercased() == "b" { return .moveToBacklog }
        return nil
    }

    static func perform(_ command: Command, _ actions: AtticTaskActions) {
        switch command {
        case .advance: actions.advance()
        case .complete: actions.complete()
        case .openPage: actions.openPage()
        case .moveToBacklog: actions.moveToBacklog()
        case .delete: actions.delete()
        }
    }
}

private extension View {
    /// Keyboard focus for a task row or card: focusable, the system focus
    /// effect replaced by Attic's 2 pt ring (drawn by the caller from
    /// `isFocused`), and the task keys. Captures (`ImageRenderer`) have no
    /// focus system, so they get none of it.
    @ViewBuilder
    func atticTaskFocus(_ isFocused: Binding<Bool>, enabled: Bool, actions: AtticTaskActions, listCommands: Bool, live: Bool) -> some View {
        if live {
            modifier(AtticTaskFocusModifier(isFocused: isFocused, enabled: enabled, actions: actions, listCommands: listCommands))
        } else {
            self
        }
    }

    /// The task's VoiceOver actions.
    func atticTaskAccessibilityActions(_ actions: AtticTaskActions) -> some View {
        accessibilityActions {
            ForEach(Array(actions.accessibilityActions.enumerated()), id: \.offset) { _, action in
                Button(action.name, action: action.handler)
            }
        }
    }
}

/// The live focus machinery for a task row or card. It owns the
/// `FocusState` and mirrors it into the component's own state, so the
/// component never touches `FocusState` (captures have no focus system).
private struct AtticTaskFocusModifier: ViewModifier {
    @Binding var isFocused: Bool
    let enabled: Bool
    let actions: AtticTaskActions
    let listCommands: Bool

    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable(enabled)
            .focused($focused)
            .focusEffectDisabled()
            .onChange(of: focused) { _, now in isFocused = now }
            .onKeyPress(phases: .down) { press in
                guard enabled, let command = AtticTaskKeys.command(
                    key: press.key, characters: press.characters, modifiers: press.modifiers, listCommands: listCommands
                ) else { return .ignored }
                AtticTaskKeys.perform(command, actions)
                return .handled
            }
    }
}

// MARK: - Status circle

/// The status circle shows and changes a task's state (spec § The status
/// circle, owner-approved hybrid 2026-09-25):
///
/// - **To do:** a grey ring whose weight shows priority (None the lightest
///   and faintest, Medium the heaviest and darkest); only High is red.
/// - **In progress:** the same ring and a wedge from 12 o'clock, clockwise:
///   the share of subtasks ticked, at least a quarter (a quarter when the
///   task has none, meaning "started").
/// - **Done:** a quiet grey disc with a darker grey check, whatever the
///   priority.
/// - **Backlog:** a dashed grey ring.
///
/// Completing: the wedge sweeps to a full disc, then the check draws and
/// the haptic tick lands (springs, so a change of mind mid-way reverses
/// smoothly); Reduce Motion fades the done disc in. Disabled, the ring and
/// wedge take the disabled icon colour (3 : 1), never faded below it.
struct AtticStatusCircle: View {
    let state: AtticTaskState
    let priority: AtticPriority
    /// In progress: the share of subtasks ticked (0…1), or nil when the
    /// task has none. Also where completing sweeps from.
    var progress: Double?
    /// Pin the check's drawing progress (gallery); nil animates live.
    var checkProgress: Double?
    /// Pin the completion sweep, 0 (the wedge) to 1 (the full disc)
    /// (gallery); nil animates live.
    var completionProgress: Double?
    var isDisabled = false

    @Environment(\.atticDesign) private var design
    @State private var completion: Double = 1
    @State private var completionStart: Double = 0
    @State private var drawnCheck: Double = 1
    @State private var discOpacity: Double = 1
    @State private var probeID = UUID()
    @State private var checkProbeID = UUID()

    var body: some View {
        let tokens = design.tokens
        let m = AtticStatusCircleMetrics.self
        let ringInk: AtticInk = isDisabled ? .disabledIcon : Self.ink(for: priority)
        let colour = tokens.color(ringInk)
        let width = m.ringWidth(priority, increaseContrast: design.increaseContrast, differentiateWithoutColor: design.differentiateWithoutColor)
        let size = AtticControlSize.statusCircle
        let sweep = m.wedgeSweep(progress)
        let motion = AtticMotionPreset.complete.animation(reduceMotion: design.reduceMotion)
        ZStack {
            switch state {
            case .todo:
                Circle().inset(by: m.edgeInset + width / 2).stroke(colour, lineWidth: width)
                    .atticRingProbe(id: probeID, ink: ringInk, tokens: tokens)
            case .inProgress:
                Circle().inset(by: m.edgeInset + width / 2).stroke(colour, lineWidth: width)
                    .atticRingProbe(id: probeID, ink: ringInk, tokens: tokens)
                AtticWedge(sweep: sweep, inset: m.wedgeInset(ringWidth: width))
                    .fill(colour)
                    .animation(motion, value: sweep)
            case .done:
                AtticCompletionMark(
                    completion: completionProgress ?? completion,
                    start: completionProgress == nil ? completionStart : (progress == nil ? 0 : sweep),
                    ring: colour, ringWidth: width, disc: tokens.doneDisc.color
                )
                .opacity(discOpacity)
                AtticCheckShape()
                    .trim(from: 0, to: checkProgress ?? drawnCheck)
                    .stroke(tokens.color(.doneCheck), style: StrokeStyle(lineWidth: m.checkLineWidth, lineCap: .round, lineJoin: .round))
                    .atticCheckProbe(id: checkProbeID, ink: .doneCheck, foreground: tokens.ink(.doneCheck))
                    .padding(m.checkInset)
                    .opacity(discOpacity)
            case .backlog:
                let dashed = design.increaseContrast ? m.backlogLineWidthIncreased : m.backlogLineWidth
                let backlogInk: AtticInk = isDisabled ? .disabledIcon : .priorityNone
                Circle().inset(by: m.edgeInset + dashed / 2)
                    .stroke(tokens.color(backlogInk), style: StrokeStyle(lineWidth: dashed, dash: m.backlogDash))
                    .atticRingProbe(id: probeID, ink: backlogInk, tokens: tokens)
            }
        }
        .frame(width: size, height: size)
        .onChange(of: state) { old, new in
            guard new == .done, old != .done else { return }
            guard checkProgress == nil, completionProgress == nil else {
                AtticHaptics.tick(enabled: design.hapticsEnabled)
                return
            }
            completionStart = old == .inProgress ? sweep : 0
            if design.reduceMotion {
                completion = 1
                drawnCheck = 1
                discOpacity = 0
                withAnimation(motion) { discOpacity = 1 }
                AtticHaptics.tick(enabled: design.hapticsEnabled)
            } else {
                completion = 0
                drawnCheck = 0
                discOpacity = 1
                withAnimation(motion) {
                    completion = 1
                } completion: {
                    AtticHaptics.tick(enabled: design.hapticsEnabled)
                    withAnimation(motion) { drawnCheck = 1 }
                }
            }
        }
        .accessibilityHidden(true)
    }

    static func ink(for priority: AtticPriority) -> AtticInk {
        switch priority {
        case .none: .priorityNone
        case .low: .priorityLow
        case .medium: .priorityMedium
        case .high: .priorityHigh
        }
    }

    /// The spoken state: "in progress, 1 of 3 subtasks".
    static func spokenState(_ state: AtticTaskState, subtasks: (done: Int, total: Int)?) -> String {
        guard state == .inProgress, let subtasks, subtasks.total > 0 else { return state.spokenName }
        return state.spokenName + ", " + String(localized: "\(subtasks.done) of \(subtasks.total) subtasks")
    }

    /// The share of subtasks ticked, or nil when there are none.
    static func progress(_ subtasks: (done: Int, total: Int)?) -> Double? {
        guard let subtasks, subtasks.total > 0 else { return nil }
        return Double(subtasks.done) / Double(subtasks.total)
    }
}

/// Completing: the wedge (in the ring's colour) sweeps from where it was to
/// the full disc while the ring fades and the quiet done grey takes over.
/// At 1 it is the done disc alone.
private struct AtticCompletionMark: View, Animatable {
    var completion: Double
    let start: Double
    let ring: Color
    let ringWidth: CGFloat
    let disc: Color

    var animatableData: Double {
        get { completion }
        set { completion = newValue }
    }

    var body: some View {
        let m = AtticStatusCircleMetrics.self
        let c = min(1, max(0, completion))
        let sweep = start + (1 - start) * c
        let inset = m.wedgeInset(ringWidth: ringWidth) * (1 - c) + m.edgeInset * c
        ZStack {
            if c < 1 {
                Circle().inset(by: m.edgeInset + ringWidth / 2).stroke(ring, lineWidth: ringWidth).opacity(1 - c)
                AtticWedge(sweep: sweep, inset: inset).fill(ring).opacity(1 - c)
            }
            AtticWedge(sweep: sweep, inset: inset).fill(disc).opacity(c)
        }
    }
}

private extension View {
    /// Reports the ring to the appearance check. Done has no ring probe: it
    /// is judged by its check, and its disc is decoration.
    func atticRingProbe(id: UUID, ink: AtticInk, tokens: AtticColorTokens) -> some View {
        atticProbe { specimen in
            AtticProbe(id: id, kind: .icon(name: "status circle"), ink: ink, foreground: tokens.ink(ink), specimen: specimen)
        }
    }
}

extension View {
    /// Reports a check mark to the appearance check: its ink on the fill it
    /// is drawn on (read inside the fill, where the stroke never passes),
    /// so a check that is missing or too faint fails.
    func atticCheckProbe(id: UUID, ink: AtticInk = .onDone, foreground: AtticRGBA) -> some View {
        atticProbe { specimen in
            AtticProbe(
                id: id, kind: .icon(name: "check mark"), ink: ink, foreground: foreground,
                specimen: specimen, allowsOverlap: true,
                backgroundSamples: AtticCheckShape.fillOnlyPoints
            )
        }
    }
}

/// A wedge of a disc from 12 o'clock, clockwise (in progress), inset from
/// its frame; a full disc at 1.
struct AtticWedge: Shape {
    var sweep: Double
    var inset: CGFloat

    var animatableData: AnimatablePair<Double, CGFloat> {
        get { AnimatablePair(sweep, inset) }
        set { sweep = newValue.first; inset = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        guard r.width > 0, sweep > 0 else { return Path() }
        if sweep >= 1 { return Path(ellipseIn: r) }
        var path = Path()
        let centre = CGPoint(x: r.midX, y: r.midY)
        path.move(to: centre)
        path.addArc(center: centre, radius: r.width / 2, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * sweep), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// A check mark drawn as one stroke, so `trim` can draw it.
struct AtticCheckShape: Shape {
    /// Points of its frame (unit coordinates) the stroke never reaches:
    /// the lower right and the upper left, inside the fill behind it.
    static let fillOnlyPoints = [CGPoint(x: 0.85, y: 0.85), CGPoint(x: 0.15, y: 0.15), CGPoint(x: 0.8, y: 0.95)]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.84))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.94, y: rect.minY + rect.height * 0.18))
        return path
    }
}

/// The circle as a button with its hit area and VoiceOver name. Its
/// keyboard focus (with Full Keyboard Access) draws Attic's 2 pt ring
/// around the circle in place of the system focus effect.
///
/// Inside a task row or card the circle is not a Tab stop of its own: the
/// row is, and Space does what a click on the circle does, so Tab moves
/// row to row instead of stopping twice per task.
struct AtticStatusButton: View {
    let state: AtticTaskState
    let priority: AtticPriority
    /// Ticked and total subtasks: the in-progress wedge and "1 of 3 subtasks".
    var subtasks: (done: Int, total: Int)?
    var isDisabled = false
    var isTabStop = true
    let onAdvance: () -> Void

    var body: some View {
        Button(action: onAdvance) {
            AtticStatusCircle(state: state, priority: priority, progress: AtticStatusCircle.progress(subtasks), isDisabled: isDisabled)
                .frame(width: AtticControlSize.minimumHitTarget, height: AtticControlSize.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusable(isTabStop)
        .focusEffectDisabled()
        .atticOwnFocusRing(.circle(diameter: AtticControlSize.statusCircle))
        .disabled(isDisabled)
        .accessibilityLabel(String(localized: "Status"))
        .accessibilityValue([AtticStatusCircle.spokenState(state, subtasks: subtasks), priority.spokenName].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Keyboard focus on a button (with Full Keyboard Access) drawn as Attic's
/// 2 pt ring in place of the system focus effect. The ring follows the
/// button's *own* focus: `Environment.isFocused` is also true inside a
/// focused ancestor (a focused task row), which drew a second ring around
/// the status circle whenever its row had focus. Captures have no focus
/// system; there only the gallery's pinned state draws it.
struct AtticOwnFocusRing: ViewModifier {
    enum Outline {
        /// A circle of this diameter at the centre (radius = d / 2).
        case circle(diameter: CGFloat)
        /// A rounded rectangle of this radius; `height` limits it to the
        /// visible chip inside a taller hit area.
        case rounded(radius: CGFloat, height: CGFloat? = nil)
    }

    let outline: Outline

    @Environment(\.atticCapture) private var capture
    @Environment(\.atticForcedState) private var forced

    func body(content: Content) -> some View {
        if capture == nil {
            content.modifier(AtticLiveOwnFocusRing(outline: outline, pinned: forced == .focused))
        } else {
            content.overlay { if forced == .focused { ring } }
        }
    }

    @ViewBuilder
    fileprivate var ring: some View {
        AtticOwnFocusRing.ring(outline)
    }

    @ViewBuilder
    fileprivate static func ring(_ outline: Outline) -> some View {
        switch outline {
        case let .circle(diameter):
            AtticFocusRing(cornerRadius: diameter / 2).frame(width: diameter, height: diameter)
        case let .rounded(radius, height):
            AtticFocusRing(cornerRadius: radius).frame(height: height)
        }
    }
}

private struct AtticLiveOwnFocusRing: ViewModifier {
    let outline: AtticOwnFocusRing.Outline
    let pinned: Bool
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        let shows = pinned || focused
        content
            .focused($focused)
            .overlay { if shows { AtticOwnFocusRing.ring(outline) } }
    }
}

extension View {
    /// Attic's focus ring for this button's own keyboard focus.
    func atticOwnFocusRing(_ outline: AtticOwnFocusRing.Outline) -> some View {
        modifier(AtticOwnFocusRing(outline: outline))
    }
}

// MARK: - Status tabs

/// The quiet Now · Backlog · Done switch under the header: 13 pt, 14 pt
/// apart; the selected tab is the body colour in medium weight, with no
/// underline; counts are set apart from their labels. Each tab reserves
/// its medium-weight width, so selecting one never shifts its neighbours;
/// the tab's own look changes instantly (only the list below slides).
struct AtticStatusTabs<Tab: Hashable>: View {
    struct Item: Identifiable {
        let tab: Tab
        let title: String
        let count: Int?
        var id: String { title }
    }

    let items: [Item]
    @Binding var selection: Tab
    /// The gallery pins a state on one tab only; nil pins it on all.
    var statePinnedTab: Tab?
    /// A task dragged over a tab moves it there: that tab outlines, with no
    /// words (the result is obvious).
    var dropTargetTab: Tab?

    @Environment(\.atticDesign) private var design

    var body: some View {
        HStack(spacing: AtticLayout.statusTabsGap) {
            ForEach(items) { item in
                AtticStatusTab(item: item, isSelected: item.tab == selection, takesPinnedState: statePinnedTab.map { $0 == item.tab } ?? true) {
                    withAnimation(AtticMotionPreset.slide.animation(reduceMotion: design.reduceMotion)) {
                        selection = item.tab
                    }
                }
                .background {
                    if item.tab == dropTargetTab {
                        AtticDropOutline(cornerRadius: AtticRadius.control(height: AtticStatusTabMetrics.dropOutlineHeight))
                            .padding(.horizontal, -AtticStatusTabMetrics.dropOutlineOutset)
                            .frame(height: AtticStatusTabMetrics.dropOutlineHeight)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct AtticStatusTab<Tab: Hashable>: View {
    let item: AtticStatusTabs<Tab>.Item
    let isSelected: Bool
    let takesPinnedState: Bool
    let action: () -> Void

    @Environment(\.atticForcedState) private var forced
    @Environment(\.isFocused) private var isFocused
    @State private var hovered = false

    var body: some View {
        let state = AtticStateResolver(forced: takesPinnedState ? forced : nil, isEnabled: true, isHovered: hovered, isPressed: false, isFocused: isFocused).state
        Button(action: action) {
            HStack(spacing: AtticStatusTabMetrics.countGap) {
                ZStack(alignment: .leading) {
                    // Reserves the selected (medium) width in every state.
                    Text(verbatim: item.title).font(AtticTextStyle.statusTabSelected.font).hidden()
                        .accessibilityHidden(true)
                    AtticText(
                        verbatim: item.title,
                        style: isSelected ? .statusTabSelected : .statusTab,
                        ink: ink(state)
                    )
                }
                if let count = item.count {
                    // The count reads with its tab (v4: "Now 4", "Backlog 3").
                    AtticText(verbatim: "\(count)", style: .statusCount, ink: ink(state))
                }
            }
            .frame(height: AtticStatusTabMetrics.height)
            .contentShape(Rectangle())
            .transaction { $0.animation = nil }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .atticFocusRing(state == .focused, cornerRadius: AtticStatusTabMetrics.focusRadius)
        .onHover { hovered = $0 }
        .accessibilityLabel(item.title)
        .accessibilityValue(item.count.map { String(localized: "\($0) tasks") } ?? "")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// Selected or hovered tabs read in the body colour; the others are the
    /// quietest grey (secondary text, 3 : 1).
    private func ink(_ state: AtticControlState) -> AtticInk {
        isSelected || state == .hover ? .body : .muted
    }
}

// MARK: - Task row

/// What a task row shows. The design system's own model: Phase 1 fills it
/// from the store.
struct AtticTaskRowModel: Identifiable, Sendable {
    struct Due: Sendable {
        let text: String
        /// Overdue and today are red; tomorrow, this week and later are quiet.
        let isUrgent: Bool
    }

    var id = UUID()
    var title: String
    var state: AtticTaskState = .todo
    var priority: AtticPriority = .none
    var due: Due?
    var tags: [String] = []
    var attachments = 0
    var links = 0
    var subtasks: (done: Int, total: Int)?
    var inWindow = false
    /// The task has a page (notes written into it).
    var hasPage = false

    /// A second line only when the task has tags, a page, files or links
    /// (or is open in a window); the due date then moves into that line
    /// ("Today · #launch"). Otherwise the date sits at the right end of the
    /// title line, as in v4.
    var hasDetails: Bool {
        state != .done && (!tags.isEmpty || hasPage || attachments > 0 || links > 0 || inWindow)
    }

    /// The due date shown at the right end of the title line.
    var trailingDue: Due? {
        hasDetails || state == .done ? nil : due
    }

    var accessibilityDescription: String {
        var parts = [title, state.spokenName]
        if let spoken = priority.spokenName { parts.append(spoken) }
        if let due { parts.append(String(localized: "due \(due.text)")) }
        if !tags.isEmpty { parts.append(String(localized: "tagged \(tags.joined(separator: ", "))")) }
        if let subtasks { parts.append(String(localized: "\(subtasks.done) of \(subtasks.total) subtasks")) }
        return parts.joined(separator: ", ")
    }
}

/// A task row: 32 pt (30 highlight + 2), 44 pt with a details line; the
/// circle at x = 16 and the title at x = 42; highlight inset 8, radius 10.
/// Three click targets: the circle (advance), the subtask count (quick
/// look), and the rest (open the page). Keyboard focusable: a focused row
/// draws the 2 pt accent ring and answers the task keys (`AtticTaskKeys`).
struct AtticTaskRow: View {
    let model: AtticTaskRowModel
    var isSelected = false
    var selectionRun: AtticSelectionRun = .single
    var isExpanded = false
    /// "Add to page" while a file hovers over the row.
    var dropLabel: String?
    let actions: AtticTaskActions
    /// The subtask count: opens or closes the quick look.
    let onToggleExpanded: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.atticCapture) private var capture
    @State private var focused = false
    @State private var hovered = false
    @State private var probeID = UUID()

    var body: some View {
        let tokens = design.tokens
        let m = AtticTaskRowMetrics.self
        let state = AtticStateResolver(forced: forced, isEnabled: isEnabled, isHovered: hovered, isPressed: false, isFocused: false).state
        // Captures have no focus system: FocusState is read only when live.
        let showsFocusRing = forced == .focused || (forced == nil && isEnabled && focused)
        let twoLine = model.hasDetails
        let highlightHeight = twoLine ? AtticLayout.detailRowHighlightHeight : AtticLayout.rowHighlightHeight
        let pitch = twoLine ? AtticLayout.detailRowPitch : AtticLayout.rowPitch
        let fill: AtticRGBA? = if state == .pressed {
            tokens.pressed
        } else if isSelected {
            tokens.selected
        } else if state == .hover {
            tokens.hover
        } else {
            nil
        }
        let disabled = state == .disabled
        let done = model.state == .done
        let hitInset = (AtticControlSize.minimumHitTarget - AtticControlSize.statusCircle) / 2

        ZStack(alignment: .topLeading) {
            Group {
                if let fill {
                    AtticHighlight(fill: fill, run: isSelected ? selectionRun : .single)
                }
                if dropLabel != nil {
                    AtticDropOutline()
                }
            }
            .frame(height: highlightHeight)
            .padding(.horizontal, AtticLayout.rowHighlightInset)

            HStack(alignment: .top, spacing: 0) {
                AtticStatusButton(state: model.state, priority: model.priority, subtasks: model.subtasks, isDisabled: disabled, isTabStop: false, onAdvance: actions.advance)
                    .atticForcedState(nil)
                    .padding(.leading, AtticLayout.circleX - hitInset)
                    .padding(.top, (AtticLayout.rowHighlightHeight - AtticControlSize.minimumHitTarget) / 2 - (twoLine ? m.twoLineCircleLift : 0))
                VStack(alignment: .leading, spacing: m.titleToDetails) {
                    AtticText(
                        verbatim: model.title,
                        style: .rowTitle,
                        ink: disabled ? .disabledText : (done ? .helper : .body),
                        strikethrough: done,
                        truncates: true
                    )
                    .frame(height: twoLine ? m.titleLineHeight : AtticLayout.rowHighlightHeight)
                    if twoLine {
                        AtticTaskDetails(model: model, disabled: disabled)
                            .frame(height: m.detailsLineHeight)
                    }
                }
                .padding(.leading, AtticLayout.textX - AtticLayout.circleX - AtticControlSize.minimumHitTarget + hitInset)
                .padding(.top, twoLine ? m.twoLineTextTop : 0)
                Spacer(minLength: m.trailingMinGap)
                trailing(disabled: disabled)
            }
        }
        .frame(height: pitch, alignment: .top)
        .padding(.top, m.pitchTopInset)
        .frame(height: pitch)
        .overlay(alignment: .top) {
            if showsFocusRing {
                Color.clear
                    .frame(height: highlightHeight)
                    .atticFocusRing(true, cornerRadius: AtticRadius.highlight)
                    .padding(.horizontal, AtticLayout.rowHighlightInset)
                    .padding(.top, m.pitchTopInset)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { if isEnabled { actions.openPage() } }
        .atticTaskFocus($focused, enabled: isEnabled, actions: actions, listCommands: true, live: capture == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.accessibilityDescription)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction { actions.openPage() }
        .atticTaskAccessibilityActions(actions)
        .accessibilityActions {
            if model.subtasks != nil, model.state != .done {
                Button(isExpanded ? String(localized: "Hide subtasks") : String(localized: "Show subtasks"), action: onToggleExpanded)
            }
        }
        .atticControlProbe(
            twoLine ? "Task row (details)" : "Task row", id: probeID,
            expectedSize: CGSize(width: 0, height: pitch), radius: AtticRadius.highlight, expectedRadius: 10
        )
    }

    @ViewBuilder
    private func trailing(disabled: Bool) -> some View {
        if let dropLabel {
            AtticText(verbatim: dropLabel, style: .dropLabel, ink: .accentText, allowsOverlap: true)
                .frame(height: AtticLayout.rowHighlightHeight)
                .padding(.trailing, AtticLayout.rowHighlightInset + AtticTaskRowMetrics.dropLabelInset)
        } else {
            let count = model.state == .done ? nil : model.subtasks
            HStack(spacing: AtticTaskRowMetrics.trailingGap) {
                if let due = model.trailingDue {
                    AtticText(verbatim: due.text, style: .rowMeta, ink: disabled ? .disabledText : (due.isUrgent ? .dueText : .helper))
                        .frame(height: AtticLayout.rowHighlightHeight)
                        .padding(.trailing, count == nil ? AtticTaskRowMetrics.dateInset : 0)
                }
                if let count {
                    AtticSubtaskCountButton(done: count.done, total: count.total, isExpanded: isExpanded, disabled: disabled, action: onToggleExpanded)
                        .padding(.trailing, AtticTaskRowMetrics.countInset)
                }
            }
            .padding(.trailing, AtticLayout.rowHighlightInset)
        }
    }
}

/// The details line: due date, tags, files and links, only when present.
private struct AtticTaskDetails: View {
    let model: AtticTaskRowModel
    let disabled: Bool

    var body: some View {
        HStack(spacing: 0) {
            let parts = segments
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    AtticText(verbatim: " · ", style: .rowMeta, ink: disabled ? .disabledText : .helper)
                }
                part
            }
        }
    }

    private var segments: [AnyView] {
        let m = AtticTaskRowMetrics.self
        let text: AtticInk = disabled ? .disabledText : .helper
        let icon: AtticInk = disabled ? .disabledIcon : .icon
        var parts: [AnyView] = []
        if model.inWindow {
            parts.append(AnyView(HStack(spacing: m.detailsIconGap) {
                AtticIcon(systemName: "macwindow", size: m.detailsIconSize, weight: .light, ink: icon)
                AtticText("In window", style: .rowMeta, ink: text)
            }))
        }
        if let due = model.due {
            parts.append(AnyView(AtticText(verbatim: due.text, style: .rowMeta, ink: disabled ? .disabledText : (due.isUrgent ? .dueText : .helper))))
        }
        for tag in model.tags {
            parts.append(AnyView(AtticText(verbatim: "#" + tag, style: .rowMeta, ink: disabled ? .disabledText : .accentText)))
        }
        if model.hasPage {
            parts.append(AnyView(HStack(spacing: m.detailsIconGap) {
                AtticIcon(systemName: "doc.text", size: m.detailsIconSize, weight: .light, ink: icon)
                AtticText("Page", style: .rowMeta, ink: text)
            }))
        }
        if model.attachments > 0 {
            parts.append(AnyView(HStack(spacing: m.attachmentIconGap) {
                AtticIcon(systemName: "paperclip", size: m.detailsIconSize, weight: .light, ink: icon)
                AtticText(verbatim: "\(model.attachments)", style: .rowMeta, ink: text)
            }))
        }
        if model.links > 0 {
            parts.append(AnyView(AtticText(verbatim: String(localized: "\(model.links) links"), style: .rowMeta, ink: text)))
        }
        return parts
    }
}

/// "1/3": the second click target, which opens and closes the quick look.
/// No chevron (v4): the count alone, with a hover fill.
private struct AtticSubtaskCountButton: View {
    let done: Int
    let total: Int
    let isExpanded: Bool
    let disabled: Bool
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    var body: some View {
        let m = AtticSubtaskCountMetrics.self
        let radius = AtticRadius.control(height: m.height)
        Button(action: action) {
            AtticText(verbatim: "\(done)/\(total)", style: .count, ink: disabled ? .disabledText : .helper)
                .padding(.horizontal, m.horizontalPadding)
                .frame(height: m.height)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill((hovered && !disabled ? design.tokens.chipHover : .clear).color)
                )
                .frame(height: AtticLayout.rowHighlightHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .atticOwnFocusRing(.rounded(radius: radius, height: m.height))
        .disabled(disabled)
        .onHover { hovered = $0 }
        .help(isExpanded ? String(localized: "Hide subtasks") : String(localized: "Show subtasks"))
        .accessibilityLabel(String(localized: "\(done) of \(total) subtasks"))
        .accessibilityValue(isExpanded ? String(localized: "expanded") : String(localized: "collapsed"))
        .accessibilityHint(isExpanded ? String(localized: "Collapses the quick look") : String(localized: "Expands the quick look"))
    }
}

// MARK: - Quick look and subtasks

/// A subtask's rounded-square checkbox (tasks keep circles, so the two never
/// look alike).
struct AtticSubtaskCheckbox: View {
    let isDone: Bool

    @Environment(\.atticDesign) private var design
    @State private var checkProbeID = UUID()
    @State private var probeID = UUID()

    var body: some View {
        let tokens = design.tokens
        let m = AtticSubtaskMetrics.self
        let size = AtticControlSize.subtaskCheckbox
        let shape = RoundedRectangle(cornerRadius: AtticRadius.subtaskCheckbox, style: .continuous)
        let lineWidth = design.increaseContrast ? m.lineWidthIncreased : m.lineWidth
        ZStack {
            if isDone {
                shape.fill(tokens.color(.doneFill))
                AtticCheckShape()
                    .stroke(tokens.color(.onDone), style: StrokeStyle(lineWidth: m.checkLineWidth, lineCap: .round, lineJoin: .round))
                    .atticCheckProbe(id: checkProbeID, foreground: tokens.ink(.onDone))
                    .padding(m.checkInset)
            } else {
                shape.inset(by: lineWidth / 2).stroke(tokens.color(.priorityNone), lineWidth: lineWidth)
            }
        }
        .frame(width: size, height: size)
        .atticProbe { [probeID] specimen in
            AtticProbe(
                id: probeID, kind: .icon(name: "subtask checkbox"),
                ink: isDone ? .doneFill : .priorityNone,
                foreground: tokens.ink(isDone ? .doneFill : .priorityNone), specimen: specimen
            )
        }
        .accessibilityHidden(true)
    }
}

struct AtticSubtaskModel: Identifiable, Sendable {
    var id = UUID()
    var title: String
    var isDone = false
}

/// One subtask line: checkbox and title, 28 pt pitch.
struct AtticSubtaskRow: View {
    let subtask: AtticSubtaskModel
    let onToggle: () -> Void

    var body: some View {
        let m = AtticSubtaskMetrics.self
        HStack(spacing: m.titleGap) {
            Button(action: onToggle) {
                AtticSubtaskCheckbox(isDone: subtask.isDone)
                    .frame(width: m.hitSize, height: m.hitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, -(m.hitSize - AtticControlSize.subtaskCheckbox) / 2)
            AtticText(verbatim: subtask.title, style: .body, ink: subtask.isDone ? .helper : .body, strikethrough: subtask.isDone, truncates: true)
            Spacer(minLength: 0)
        }
        .frame(height: AtticLayout.subtaskPitch)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(subtask.title)
        .accessibilityValue(subtask.isDone ? String(localized: "done") : String(localized: "to do"))
        .accessibilityAction(named: Text(subtask.isDone ? "Mark as not done" : "Mark as done"), onToggle)
    }
}

/// The quick look: the row expands in place into its subtasks, "Add
/// subtask" and "Open page". Aligned to the row's text column.
struct AtticQuickLook: View {
    let subtasks: [AtticSubtaskModel]
    let onToggle: (AtticSubtaskModel) -> Void
    let onAddSubtask: () -> Void
    let onOpenPage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(subtasks) { subtask in
                AtticSubtaskRow(subtask: subtask) { onToggle(subtask) }
            }
            AtticQuietAction(systemName: "plus", title: String(localized: "Add subtask"), action: onAddSubtask)
            AtticQuietAction(systemName: nil, title: String(localized: "Open page"), trailingChevron: true, emphasised: true, action: onOpenPage)
        }
        .padding(.leading, AtticLayout.textX)
        .padding(.trailing, AtticLayout.rowHighlightInset)
        .padding(.bottom, AtticQuickLookMetrics.bottomPadding)
    }
}

/// A quiet text action inside content ("Add subtask", "Open page"): no
/// raised material, a hover fill, helper or label ink.
struct AtticQuietAction: View {
    let systemName: String?
    let title: String
    var trailingChevron = false
    var emphasised = false
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @State private var hovered = false

    var body: some View {
        let m = AtticQuietActionMetrics.self
        let hover = forced == .hover || hovered
        Button(action: action) {
            HStack(spacing: m.gap) {
                if let systemName {
                    AtticIcon(systemName: systemName, size: m.iconSize, weight: .medium, ink: .icon)
                        .frame(width: m.iconSlot)
                }
                AtticText(verbatim: title, style: emphasised ? .controlLabel : .body, ink: emphasised ? .label : .helper)
                if trailingChevron {
                    AtticIcon(systemName: "chevron.right", size: m.chevronSize, weight: .semibold, ink: .chevron)
                        .padding(.leading, -m.chevronPullIn)
                }
            }
            .padding(.horizontal, m.horizontalPadding)
            .frame(height: m.height)
            .background(
                RoundedRectangle(cornerRadius: AtticRadius.control(height: m.height), style: .continuous)
                    .fill((hover ? design.tokens.chipHover : .clear).color)
            )
            .padding(.horizontal, -m.horizontalPadding)
            .frame(height: AtticLayout.subtaskPitch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Task card

/// What a task card can do beyond a row's actions. Every callback is
/// required: each drawn control is wired.
struct AtticTaskCardActions {
    /// The chevron, and VoiceOver "Expand" / "Collapse".
    let toggleExpanded: () -> Void
    /// A subtask's checkbox.
    let toggleSubtask: (AtticSubtaskModel) -> Void
    /// "Add subtask".
    let addSubtask: () -> Void
    /// "Open in Tasks": shows the task in the panel's Tasks page.
    let openInTasks: () -> Void
}

/// The task card that lives in notes and task pages: recessed and flat
/// inside content (radius 10, no border). Collapsed: circle, title and a
/// details line when there are details. Expanded: subtasks you can tick,
/// "Add subtask", then "Open in Tasks" and "Open page". Keyboard focusable
/// with the 2 pt accent ring; Space, ⌥Space and ⌘Return work as on a row.
struct AtticTaskCard: View {
    let model: AtticTaskRowModel
    var subtasks: [AtticSubtaskModel] = []
    var isExpanded = false
    /// The note or page the card sits in, for VoiceOver ("card, in note Launch sync").
    var container: String?
    let actions: AtticTaskActions
    let cardActions: AtticTaskCardActions

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.atticCapture) private var capture
    @State private var focused = false
    @State private var hovered = false
    @State private var probeID = UUID()

    var body: some View {
        let tokens = design.tokens
        let m = AtticTaskCardMetrics.self
        let shape = RoundedRectangle(cornerRadius: AtticRadius.tile, style: .continuous)
        let hover = forced == .hover || hovered
        let showsFocusRing = forced == .focused || (forced == nil && isEnabled && focused)
        let fill = hover ? tokens.hover.over(tokens.recessed) : tokens.recessed
        let hitInset = (AtticControlSize.minimumHitTarget - AtticControlSize.statusCircle) / 2
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                AtticStatusButton(state: model.state, priority: model.priority, subtasks: model.subtasks, isTabStop: false, onAdvance: actions.advance)
                    .atticForcedState(nil)
                    .padding(.leading, m.leadingInset - hitInset)
                    .padding(.top, m.circleTop)
                VStack(alignment: .leading, spacing: AtticTaskRowMetrics.titleToDetails) {
                    AtticText(verbatim: model.title, style: .rowTitle, ink: model.state == .done ? .helper : .body, strikethrough: model.state == .done, truncates: true)
                        .frame(height: m.titleHeight)
                    if model.hasDetails || model.subtasks != nil {
                        AtticCardDetails(model: model)
                            .frame(height: AtticTaskRowMetrics.detailsLineHeight)
                            .padding(.top, -m.detailsPullUp)
                            .padding(.bottom, m.detailsBottom)
                    }
                }
                .padding(.leading, m.circleToTitle)
                Spacer(minLength: AtticTaskRowMetrics.trailingMinGap)
                Button(action: cardActions.toggleExpanded) {
                    ZStack {
                        if isExpanded {
                            AtticIcon(systemName: "chevron.up", size: m.chevronSize, weight: .semibold, ink: .chevron).transition(.opacity)
                        } else {
                            AtticIcon(systemName: "chevron.down", size: m.chevronSize, weight: .semibold, ink: .chevron).transition(.opacity)
                        }
                    }
                    .frame(width: m.chevronHitSize.width, height: m.chevronHitSize.height)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? String(localized: "Collapse") : String(localized: "Expand"))
                .padding(.trailing, m.trailingInset)
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(subtasks) { subtask in
                        AtticSubtaskRow(subtask: subtask) { cardActions.toggleSubtask(subtask) }
                    }
                    AtticQuietAction(systemName: "plus", title: String(localized: "Add subtask"), action: cardActions.addSubtask)
                    HStack {
                        AtticQuietAction(systemName: nil, title: String(localized: "Open in Tasks"), emphasised: true, action: cardActions.openInTasks)
                        Spacer()
                        AtticQuietAction(systemName: "doc.text", title: String(localized: "Open page"), emphasised: true, action: actions.openPage)
                    }
                    .padding(.top, m.actionsTop)
                }
                .padding(.leading, m.expandedLeading)
                .padding(.trailing, m.expandedTrailing)
                .padding(.bottom, m.expandedBottom)
                .transition(.opacity)
            }
        }
        .background {
            ZStack {
                shape.fill(fill.color)
                if let border = tokens.recessedBorder { shape.strokeBorder(border.color, lineWidth: AtticHairline.contrastBorder) }
            }
        }
        .atticFocusRing(showsFocusRing, cornerRadius: AtticRadius.tile)
        .contentShape(shape)
        .onHover { hovered = $0 }
        .atticTaskFocus($focused, enabled: isEnabled, actions: actions, listCommands: false, live: capture == nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityActions {
            Button(isExpanded ? String(localized: "Collapse") : String(localized: "Expand"), action: cardActions.toggleExpanded)
        }
        .atticTaskAccessibilityActions(actions)
        .accessibilityActions {
            Button(String(localized: "Open in Tasks"), action: cardActions.openInTasks)
        }
        .atticControlProbe("Task card", id: probeID, expectedSize: nil, radius: AtticRadius.tile, expectedRadius: AtticRadius.tile)
    }

    private var accessibilityLabel: String {
        var label = model.accessibilityDescription + ", " + String(localized: "card")
        if let container { label += ", " + String(localized: "in \(container)") }
        return label
    }
}

private struct AtticCardDetails: View {
    let model: AtticTaskRowModel

    var body: some View {
        let m = AtticTaskCardMetrics.self
        HStack(spacing: m.detailsGap) {
            if let due = model.due {
                HStack(spacing: m.detailsIconGap) {
                    AtticIcon(systemName: "calendar", size: AtticTaskRowMetrics.detailsIconSize, ink: due.isUrgent ? .priorityHigh : .icon)
                    AtticText(verbatim: due.text, style: .rowMeta, ink: due.isUrgent ? .dueText : .helper)
                }
            }
            ForEach(model.tags, id: \.self) { AtticTagChip(name: $0) }
            if let subtasks = model.subtasks {
                AtticText(verbatim: "\(subtasks.done)/\(subtasks.total)", style: .count, ink: .helper)
            }
        }
    }
}

// MARK: - Tag

/// A tag: the accent (grey on Original), sentence of `#word`. `inline` is
/// plain text for details lines; `chip` is a recessed pill that follows the
/// control corner rule (18 tall, radius 7.5).
struct AtticTagChip: View {
    enum Style { case chip, inline }

    let name: String
    var style: Style = .chip
    var isSelected = false

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @State private var hovered = false
    @State private var probeID = UUID()

    var body: some View {
        let tokens = design.tokens
        let height = AtticControlSize.tagHeight
        let radius = AtticRadius.control(height: height)
        let hover = forced == .hover || hovered
        let fill: AtticRGBA = isSelected ? tokens.tagFillSelected : (hover ? tokens.hover.over(tokens.tagFill) : tokens.tagFill)
        switch style {
        case .inline:
            AtticText(verbatim: "#" + name, style: .rowMeta, ink: .accentText)
        case .chip:
            AtticText(verbatim: "#" + name, style: .tag, ink: .accentText)
                .padding(.horizontal, AtticTagMetrics.horizontalPadding)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill.color))
                .onHover { hovered = $0 }
                .accessibilityLabel(String(localized: "Tag \(name)"))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .atticControlProbe("Tag", id: probeID, expectedSize: nil, radius: radius, expectedRadius: 7.5)
        }
    }
}
