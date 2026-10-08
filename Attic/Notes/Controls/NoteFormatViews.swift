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

    /// The bottom row's coordinate space (Aa's frame is read in it).
    static let rowSpace = "notes-format-row-space"

    /// One channel of the format row's motion: a delay, then a spring from
    /// rest (SwiftUI's perceptual duration and bounce, as the app's motion
    /// presets give them).
    struct Spring: Equatable {
        var delay: Double = 0
        let response: Double
        var bounce: Double = 0

        init(delay: Double = 0, response: Double, bounce: Double = 0) {
            self.delay = delay
            self.response = response
            self.bounce = bounce
        }

        init(delay: Double = 0, _ spring: AtticMotionSpring) {
            self.init(delay: delay, response: spring.response, bounce: spring.bounce)
        }

        var animation: Animation { undelayed.delay(delay) }

        /// The spring alone (the caller starts it at `delay`).
        var undelayed: Animation { .spring(duration: response, bounce: bounce) }

        /// The spring's progress `t` seconds after it was asked to start
        /// (0 before its delay, settling on 1), as SwiftUI runs it.
        func value(at t: Double) -> Double {
            let t = t - delay
            guard t > 0 else { return 0 }
            let omega = 2 * Double.pi / response
            let zeta = 1 - bounce
            if zeta >= 1 { return 1 - (1 + omega * t) * exp(-omega * t) }
            let damped = omega * (1 - zeta * zeta).squareRoot()
            return 1 - exp(-zeta * omega * t) * (cos(damped * t) + zeta * omega / damped * sin(damped * t))
        }
    }

    /// Aa grows into the bar (p2-37 draft 1) on the app's own springs in
    /// the chosen feel (owner, 2026-10-06: "springy like the rest of the
    /// motion in our app"). The glass is `expand` (a card growing out of
    /// its button and back); the controls come in as a bar does
    /// (`popover`) and go with its leave; the neighbours slide into the
    /// row's sides on the glass's spring. Every delay is a share of those
    /// springs. Opening, both glass edges and both neighbours move together
    /// at once, and the controls come once it is about half grown. Closing,
    /// the controls start to go and the glass follows within half a leave;
    /// New note rides back in with the glass's trailing edge (the 8 pt gap
    /// held, as it was pushed out), and All notes and the status come back
    /// once the glass has cleared their places (A32). Animations: Reduced
    /// and Reduce Motion swap at once (the switch never asks for these).
    struct Plan: Equatable {
        /// The format controls leaving.
        let leave: Spring
        /// A neighbour coming back.
        let comeBack: Spring
        /// Both edges answer the click together on the same spring.
        let openLeading: Spring
        let openTrailing: Spring
        let openControls: Spring
        let closeControls: Spring
        let closeGrow: Spring
        /// New note's way back: the glass's own closing spring, so it
        /// follows the trailing edge in.
        let newNoteBack: Spring
        /// When All notes and the status come back, from the start of closing.
        let allNotesReturns: Double
        let statusReturns: Double

        init(_ tuning: AtticMotionTuning) {
            let tuck = tuning.leave == .spring
            let leaving = tuck ? tuning.leaveResponse : tuning.popover.response
            leave = Spring(response: leaving, bounce: tuck ? 0 : tuning.popover.bounce)
            comeBack = Spring(tuning.popover)
            let expand = tuning.expand.response
            openLeading = Spring(delay: 0, tuning.expand)
            openTrailing = openLeading
            openControls = Spring(delay: 0.55 * expand, tuning.popover)
            closeControls = leave
            // Half a leave: the controls are on their way out, and the glass
            // never stands wide and empty (A32: 0.8 of a leave held it still
            // for up to ten frames in Calm).
            closeGrow = Spring(delay: 0.4 * leaving, tuning.expand)
            newNoteBack = closeGrow
            allNotesReturns = closeGrow.delay + 0.35 * expand
            statusReturns = closeGrow.delay + 0.9 * expand
        }

        /// The plan in the feel in use now.
        static var current: Plan { Plan(.current) }
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
    var height: CGFloat = AtticControlSize.smallHeight
    var isKeyboardFocused = false
    /// An action (outdent, indent): no on/off value.
    var announcesState = true

    var body: some View {
        let snapshot = model.snapshot
        let label = NoteCommandCatalog.menuTitle(command).replacingOccurrences(of: "…", with: "")
        Group {
            if command == .mark(.highlight) {
                AtticFormatToggle(value: snapshot.value(command), label: label, help: NoteFormatModel.help(command),
                                  width: width, height: height, isKeyboardFocused: isKeyboardFocused,
                                  disabledReason: snapshot.disabledReason, action: run) { ink in
                    AtticHighlightGlyph(ink: ink, swatch: model.highlightSwatch)
                }
            } else {
                AtticFormatToggle(systemName: NoteCommandCatalog.symbol(command), value: snapshot.value(command),
                                  label: label, help: NoteFormatModel.help(command), width: width, height: height,
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
    /// While it grows out of Aa or returns into it (nil at rest).
    var growth: AtticFormatRowGrowth?
    /// The controls' fade (1 at rest).
    var controlsOpacity: Double = 1
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
        let m = AtticNoteFormatMetrics.self
        let focus = model.rowKeyboardIndex
        let lists = NoteCommandCatalog.lists
        let indents = NoteCommandCatalog.indents
        return AtticFormatRowSurface(growth: growth, contentOpacity: controlsOpacity) {
            NoteFormatStylePill(model: model, isKeyboardFocused: focus == 0)
            AtticFormatSeparator()
            AtticFormatGroup {
                ForEach(Array(lists.enumerated()), id: \.offset) { offset, command in
                    NoteFormatToggle(model: model, command: command, surface: .formatBar, width: toggleWidth,
                                     height: m.rowCellHeight, isKeyboardFocused: focus == 1 + offset)
                }
            }
            AtticFormatSeparator()
            AtticFormatGroup {
                ForEach(Array(indents.enumerated()), id: \.offset) { offset, command in
                    NoteFormatToggle(model: model, command: command, surface: .formatBar, width: toggleWidth,
                                     height: m.rowCellHeight, isKeyboardFocused: focus == 1 + lists.count + offset,
                                     announcesState: false)
                }
            }
            Spacer(minLength: 0)
            AtticFormatToggle(systemName: "xmark", value: .off, label: String(localized: "Close Format"),
                              help: String(localized: "Close (Esc)"), width: toggleWidth, height: m.rowCellHeight,
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
///
/// Opening, Aa's own glass becomes the row's and grows into the bar (p2-37
/// draft 1, `NoteFormatMotion.Plan`): both edges move together, New note
/// slides right and All notes left, the status clears at once, and controls come once the glass is
/// wide. They are the glass's content, so nothing is drawn under it. ✕ or
/// Esc runs it back into Aa. Animations: Reduced
/// and Reduce Motion swap at once. While either is on its way out it is
/// hidden from VoiceOver and the pointer, and once open the bottom row is
/// disabled. The motion is this view's own state: the page and the note
/// never redraw for it.
struct NoteFormatRowSwitch<Row: View>: View {
    @ObservedObject var state: NoteFormatRowState
    /// The format model of the note on screen (read as the row opens).
    let model: () -> NoteFormatModel?
    @ViewBuilder let row: Row

    @Environment(\.atticDesign) private var design
    @State private var phase = NoteFormatRowPhase.closed
    @State private var channels = NoteFormatRowChannels.closed
    @State private var shownModel: NoteFormatModel?
    @State private var geometry = NoteFormatRowGeometry()
    @State private var source: CGRect = .zero
    @State private var width: CGFloat = 0
    /// The current motion; pending neighbour changes of older ones lapse.
    @State private var motionToken = 0
    @State private var allNotesGone = false
    @State private var newNoteGone = false
    @State private var statusHidden = false
    /// The row's surface is in the tree, dormant (no glass, nothing drawn)
    /// while closed, so opening animates it on the very next frame.
    @State private var surfaceMounted = false

    var body: some View {
        ZStack(alignment: .leading) {
            // Always in the tree (mounting it again as the row closes
            // stalled the first frames of the motion, A29 round 2); while the
            // row is open it is away, disabled and out of the keyboard loop.
            let away = phase != .closed
            row
                .environment(\.noteFormatRowStage, NoteFormatRowStage(allNotes: channels.allNotes,
                                                                      newNoteAndStatus: channels.newNoteAndStatus,
                                                                      allNotesGone: allNotesGone,
                                                                      newNoteAndStatusGone: newNoteGone,
                                                                      statusHidden: statusHidden,
                                                                      sourceHidden: away))
                .environment(\.noteFormatRowGeometry, geometry)
                .disabled(phase == .open)
                .allowsHitTesting(!away)
                .accessibilityHidden(away)
            if let model = shownModel ?? model() {
                let dormant = phase == .closed
                NoteFormatRowView(model: model,
                                  growth: AtticFormatRowGrowth(source: source, rowWidth: width,
                                                               leading: channels.leading, trailing: channels.trailing,
                                                               sourceSymbol: NoteFormatRowSource.symbol),
                                  controlsOpacity: channels.controls) { state.close() }
                    .environment(\.atticControlGone, dormant)
                    .allowsHitTesting(!dormant && state.isOpen)
                    .accessibilityHidden(dormant || !state.isOpen)
                    .onAppear { surfaceMounted = true }
                    .onDisappear { surfaceMounted = false }
            }
        }
        .coordinateSpace(.named(NoteFormatMotion.rowSpace))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
            if abs(new - width) > 0.5 { width = new }
        }
        .onChange(of: state.isOpen) { _, open in
            if open { self.open() } else { close() }
        }
        .onAppear {
            guard state.isOpen, let model = model() else { return }
            shownModel = model
            source = sourceFrame
            phase = .open
            channels = .open
            statusHidden = true
        }
    }

    /// Aa's frame in the row, or where it stands when it isn't measured.
    private var sourceFrame: CGRect {
        if geometry.source.width > 0 { return geometry.source }
        let size = AtticControlSize.panelButton
        return CGRect(x: width - size.width * 2 - AtticNoteMetrics.formatButtonGap, y: 0, width: size.width, height: size.height)
    }

    private func open() {
        guard let model = model() else { return }
        if design.reduceMotion {
            motionToken += 1
            instantly {
                shownModel = model
                source = sourceFrame
                phase = .open
                channels = .open
                allNotesGone = true
                newNoteGone = true
                statusHidden = true
            }
            return
        }
        if phase == .closed {
            // Aa's glass becomes the row's where Aa stands, in this frame,
            // and both edges move on the next. The surface is already
            // in the tree (dormant), so it animates from where it is; only if
            // it was not yet mounted does the motion wait one turn for it.
            motionToken += 1
            let mounted = surfaceMounted
            instantly {
                shownModel = model
                source = sourceFrame
                channels.leading = 0
                channels.trailing = 0
                channels.controls = 0
                statusHidden = true
                phase = .moving
            }
            if mounted {
                runOpen()
            } else {
                DispatchQueue.main.async { if state.isOpen { runOpen() } }
            }
        } else {
            runOpen()
        }
    }

    /// The neighbours' glass changes at the moment it should: an animation
    /// delay is not honoured by glass turning to or from the identity glass
    /// (it either jumped at once or lingered as a faint ring, A29 round 2),
    /// so each neighbour is sent away or back on its own clock with an
    /// undelayed animation. A newer motion cancels what is still pending.
    private func runOpen() {
        motionToken += 1
        let token = motionToken
        let plan = NoteFormatMotion.Plan.current
        // Both neighbours travel away from the growing glass on its spring,
        // including a reversal while either had begun coming back.
        if !statusHidden { instantly { statusHidden = true } }
        withAnimation(plan.openControls.animation) {
            channels.controls = 1
        }
        withAnimation(plan.openLeading.undelayed, completionCriteria: .logicallyComplete) {
            channels.leading = 1
            channels.trailing = 1
            channels.allNotes = 1
            channels.newNoteAndStatus = 1
        } completion: {
            guard motionToken == token, state.isOpen, phase == .moving else { return }
            instantly {
                phase = .open
                allNotesGone = true
                newNoteGone = true
            }
        }
    }

    private func close() {
        if design.reduceMotion || phase == .closed {
            motionToken += 1
            instantly {
                phase = .closed
                channels = .closed
                allNotesGone = false
                newNoteGone = false
                statusHidden = false
                shownModel = nil
            }
            return
        }
        if phase == .open { instantly { phase = .moving } }
        runClose()
    }

    private func runClose() {
        motionToken += 1
        let token = motionToken
        let plan = NoteFormatMotion.Plan.current
        withAnimation(plan.closeControls.animation) { channels.controls = 0 }
        if channels.allNotes > 0 {
            after(plan.allNotesReturns, token: token) {
                returnNeighbour(token: token, gone: $allNotesGone, spring: plan.comeBack) { channels.allNotes = 0 }
            }
        }
        if statusHidden {
            after(plan.statusReturns, token: token) {
                withAnimation(plan.comeBack.undelayed) { statusHidden = false }
            }
        }
        // New note's glass comes back whole but still beyond the row's
        // edge (nothing of it is drawn yet), and rides in with the glass.
        if newNoteGone { instantly { newNoteGone = false } }
        withAnimation(plan.closeGrow.animation, completionCriteria: .logicallyComplete) {
            channels.leading = 0
            channels.trailing = 0
            channels.newNoteAndStatus = 0
        } completion: {
            guard motionToken == token, !state.isOpen, phase == .moving else { return }
            // Aa takes its glass back; a neighbour still due keeps its clock.
            instantly {
                phase = .closed
                channels.leading = 0
                channels.trailing = 0
                channels.controls = 0
                shownModel = nil
            }
        }
    }

    /// A neighbour comes back: restore its glass while it is clipped
    /// outside its slot, then spring it in on the next turn.
    private func returnNeighbour(token: Int, gone: Binding<Bool>, spring plan: NoteFormatMotion.Spring,
                                 _ change: @escaping () -> Void) {
        let spring = plan.undelayed
        if gone.wrappedValue {
            instantly { gone.wrappedValue = false }
            DispatchQueue.main.async {
                guard motionToken == token else { return }
                withAnimation(spring, change)
            }
        } else {
            withAnimation(spring, change)
        }
    }

    /// Runs `work` after `delay` unless a newer motion has started.
    private func after(_ delay: Double, token: Int, _ work: @escaping () -> Void) {
        guard delay > 0 else { work(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if motionToken == token { work() }
        }
    }

    private func instantly(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
}

/// Where the format row is: the bottom row alone, the two on their way
/// (opening or closing), or the row alone (the bottom row still in the
/// tree, away and disabled).
enum NoteFormatRowPhase: Equatable {
    case closed, moving, open
}

/// The format row's motion channels, each 0 (the bottom row) to 1 (the
/// format row), driven by `NoteFormatMotion`'s springs.
struct NoteFormatRowChannels: Equatable {
    /// Aa's glass's leading edge, from Aa's (0) to the row's (1).
    var leading: CGFloat
    /// The trailing edge (New note's side).
    var trailing: CGFloat
    /// The row's controls.
    var controls: Double
    /// All notes' outward travel.
    var allNotes: Double
    /// New note's outward travel and the note status's return.
    var newNoteAndStatus: Double

    static let closed = NoteFormatRowChannels(leading: 0, trailing: 0, controls: 0, allNotes: 0, newNoteAndStatus: 0)
    static let open = NoteFormatRowChannels(leading: 1, trailing: 1, controls: 1, allNotes: 1, newNoteAndStatus: 1)
}

/// What the bottom row's pieces read while the format row comes and goes.
struct NoteFormatRowStage: Equatable {
    var allNotes: Double = 0
    var newNoteAndStatus: Double = 0
    /// Gone and settled: no glass left at all (`atticControlGone`).
    var allNotesGone = false
    var newNoteAndStatusGone = false
    /// The status (plain text, under where the glass's leading edge goes
    /// first) is hidden at once as the row opens.
    var statusHidden = false
    /// Aa's glass is the format row's for now: Aa itself is not drawn.
    var sourceHidden = false
}

/// Aa's frame in the bottom row, kept without redrawing anything.
final class NoteFormatRowGeometry {
    var source: CGRect = .zero
}

private struct NoteFormatRowStageKey: EnvironmentKey {
    static let defaultValue = NoteFormatRowStage()
}

private struct NoteFormatRowGeometryKey: EnvironmentKey {
    static let defaultValue: NoteFormatRowGeometry? = nil
}

extension EnvironmentValues {
    var noteFormatRowStage: NoteFormatRowStage {
        get { self[NoteFormatRowStageKey.self] }
        set { self[NoteFormatRowStageKey.self] = newValue }
    }

    var noteFormatRowGeometry: NoteFormatRowGeometry? {
        get { self[NoteFormatRowGeometryKey.self] }
        set { self[NoteFormatRowGeometryKey.self] = newValue }
    }
}

/// The neighbours slide into their respective row edges as Aa grows.
/// The status is plain text and hides at once to clear the glass's path.
enum NoteFormatRowNeighbour {
    case allNotes, status, newNote

    /// A whole button and the Aa gap: enough to clear the row edge while
    /// preserving that gap beside Aa's moving trailing edge.
    static let exitDistance = AtticControlSize.panelButton.width + AtticNoteMetrics.formatButtonGap

    func offset(at progress: Double) -> CGFloat {
        let travel = Self.exitDistance * CGFloat(min(1, max(0, progress)))
        switch self {
        case .allNotes: return -travel
        case .newNote: return travel
        case .status: return 0
        }
    }

    /// What is left inside the slot after `offset(at:)`: the side the
    /// button travels toward is cut by the distance it has gone, so it
    /// passes under the row's edge.
    func reveal(at progress: Double) -> AtticControlReveal? {
        let travel = abs(offset(at: progress))
        switch self {
        case .allNotes: return AtticControlReveal(leading: travel)
        case .newNote: return AtticControlReveal(trailing: travel)
        case .status: return nil
        }
    }
}

private struct NoteFormatRowLeaving: ViewModifier {
    let neighbour: NoteFormatRowNeighbour
    @Environment(\.noteFormatRowStage) private var stage

    func body(content: Content) -> some View {
        let progress = neighbour == .allNotes ? stage.allNotes : stage.newNoteAndStatus
        let gone = neighbour == .allNotes ? stage.allNotesGone : stage.newNoteAndStatusGone
        if neighbour == .status {
            content.opacity(stage.statusHidden ? 0 : 1)
        } else {
            content
                .environment(\.atticControlAway, false)
                .environment(\.atticControlGone, gone)
                .modifier(NoteFormatRowSlide(neighbour: neighbour, progress: progress))
        }
    }
}

/// Clip at the button's outer slot edge, preserving vertical shadow room.
/// Clamping each interpolated frame prevents a returning spring from
/// overshooting inward into Aa's 8 pt gap. A glass container ignores the
/// clip on its members' glass (A32: the buttons were left half out over
/// the panel's margin, then vanished at once), so the button's glass
/// itself narrows to the part still inside its slot
/// (`atticControlReveal`); the clip remains for the drawn controls.
private struct NoteFormatRowSlide: ViewModifier, Animatable {
    let neighbour: NoteFormatRowNeighbour
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.atticControlReveal, neighbour.reveal(at: progress))
            .offset(x: neighbour.offset(at: progress))
            .padding(.vertical, AtticNoteFormatMetrics.shadowRoom)
            .clipped()
            .padding(.vertical, -AtticNoteFormatMetrics.shadowRoom)
    }
}

/// Aa: the format row's glass starts as Aa's, so Aa reports where it is
/// and is not drawn while the row's glass stands in for it.
struct NoteFormatRowSource: ViewModifier {
    static let symbol = "textformat"

    @Environment(\.noteFormatRowStage) private var stage
    @Environment(\.noteFormatRowGeometry) private var geometry

    func body(content: Content) -> some View {
        content
            .environment(\.atticControlAway, stage.sourceHidden)
            .environment(\.atticControlGone, stage.sourceHidden)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(NoteFormatMotion.rowSpace)) } action: { frame in
                geometry?.source = frame
            }
    }
}

extension View {
    /// A bottom-row control making way for the format row.
    func noteFormatRowLeaving(_ neighbour: NoteFormatRowNeighbour) -> some View {
        modifier(NoteFormatRowLeaving(neighbour: neighbour))
    }

    /// Aa, the format row's source.
    func noteFormatRowSource() -> some View {
        modifier(NoteFormatRowSource())
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
            AtticFormatStyleFace(title: name, isKeyboardFocused: isKeyboardFocused, isEnabled: enabled,
                                 height: AtticNoteFormatMetrics.rowCellHeight)
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
