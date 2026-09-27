import AppKit
import SwiftUI

// MARK: - Actions

/// Everything a task row or card can do, and so what it offers: one
/// definition read by the keys (`AtticTaskKeys`), the buttons, VoiceOver
/// (`accessibilityActions(for:)`) and the page's right-click menu. A
/// command a row cannot perform is nil and is offered nowhere (a Done log
/// row cannot start working, move or be deleted). Phase 1 passes the
/// store's operations, the gallery records which one fired.
struct AtticTaskActions {
    /// The circle's click, Space (and ⌥Space): done, or a done task back to
    /// what it was (Direction A: one-click completion).
    let toggleDone: () -> Void
    /// ⇧Space, the right-click menu and VoiceOver: start or stop working
    /// on the task (the circle's centre dot).
    var toggleWorking: (() -> Void)?
    /// A click on the row, ⌘Return and VoiceOver "Open page" (named by
    /// `names.openPage`).
    let openPage: () -> Void
    /// ⌘B and VoiceOver "Move to Later" (or "Move to Now" on Later).
    var moveToBacklog: (() -> Void)?
    /// Delete and VoiceOver "Delete".
    var delete: (() -> Void)?
    /// Return on a focused row in a list, and VoiceOver "Edit title": edit
    /// the title in place (nil where the title cannot be edited).
    var editTitle: (() -> Void)? = nil
    /// The Done page's "Restore to Now" (to Now as to do, whatever the task
    /// was before), where it is offered.
    var restoreToNow: (() -> Void)? = nil
    /// What the commands are called where they differ from the defaults.
    var names = Names()

    struct Names {
        /// ⌘Return's command as VoiceOver says it: "Open page", or the
        /// Phase 1 labels' "Open files" / "Show details" / "Close details".
        var openPage = String(localized: "Open page")
    }

    /// The VoiceOver actions a task offers, named for its state: Complete
    /// (or Mark as not done), Start working (or Stop working), Restore to
    /// Now, Open page, Edit title, Move to Later, Delete; only those it can
    /// perform.
    func accessibilityActions(for state: AtticTaskState) -> [(name: String, handler: () -> Void)] {
        var list: [(name: String, handler: () -> Void)] = [
            (state == .done ? String(localized: "Mark as not done") : String(localized: "Complete"), toggleDone)
        ]
        if let toggleWorking {
            list.append((state == .inProgress ? String(localized: "Stop working") : String(localized: "Start working"), toggleWorking))
        }
        if let restoreToNow { list.append((String(localized: "Restore to Now"), restoreToNow)) }
        list.append((names.openPage, openPage))
        if let editTitle { list.append((String(localized: "Edit title"), editTitle)) }
        if let moveToBacklog {
            list.append((state == .backlog ? String(localized: "Move to Now") : String(localized: "Move to Later"), moveToBacklog))
        }
        if let delete { list.append((String(localized: "Delete"), delete)) }
        return list
    }
}

/// The task keys a focused row or card answers (spec § Keyboard map, as
/// Direction A changes it): Space (and ⌥Space) completes or un-completes,
/// ⇧Space starts or stops working, ⌘Return opens the page; rows also take
/// ⌘B (Later) and Delete. ↑ ↓ and ⌘↑ ⌘↓ belong to the list, and Return
/// (edit title) to the row's title editor.
enum AtticTaskKeys {
    enum Command: Equatable { case toggleDone, toggleWorking, openPage, moveToBacklog, delete, editTitle }

    /// The command for a key, or nil when the key is not a task key.
    static func command(key: KeyEquivalent, characters: String, modifiers: EventModifiers, listCommands: Bool) -> Command? {
        let relevant = modifiers.intersection([.command, .option, .control, .shift])
        // ⌥Space types a non-breaking space, so match the characters too.
        if key == .space || characters == " " || characters == "\u{A0}" {
            if relevant == [] || relevant == .option { return .toggleDone }
            if relevant == .shift { return .toggleWorking }
            return nil
        }
        if key == .return, relevant == .command { return .openPage }
        guard listCommands else { return nil }
        // Return edits the title. The row answers it itself: left to the
        // list, a focused row would take Return as a click.
        if key == .return, relevant == [] { return .editTitle }
        // Backspace arrives as U+007F (or U+0008), forward delete as U+F728.
        let deletes: Set<Character> = [KeyEquivalent.delete.character, KeyEquivalent.deleteForward.character, "\u{7F}", "\u{8}", "\u{F728}"]
        if deletes.contains(key.character) || characters.first.map(deletes.contains) == true, relevant == [] { return .delete }
        if relevant == .command, key.character == "b" || characters.lowercased() == "b" { return .moveToBacklog }
        return nil
    }

    static func perform(_ command: Command, _ actions: AtticTaskActions) {
        switch command {
        case .toggleDone: actions.toggleDone()
        case .toggleWorking: actions.toggleWorking?()
        case .openPage: actions.openPage()
        case .moveToBacklog: actions.moveToBacklog?()
        case .delete: actions.delete?()
        case .editTitle: actions.editTitle?()
        }
    }
}

private extension View {
    /// Keyboard focus for a task row or card: focusable, the system focus
    /// effect replaced by Attic's 2 pt ring (drawn by the caller from
    /// `isFocused`), and the task keys. Captures (`ImageRenderer`) have no
    /// focus system, so they get none of it.
    @ViewBuilder
    func atticTaskFocus(_ isFocused: Binding<Bool>, enabled: Bool, actions: AtticTaskActions, listCommands: Bool, live: Bool,
                        external: AtticRowFocus? = nil, answersKeys: Bool = true) -> some View {
        if live, let external {
            modifier(AtticListTaskFocusModifier(enabled: enabled, answersKeys: answersKeys, actions: actions,
                                                listCommands: listCommands, focus: external))
        } else if live {
            modifier(AtticTaskFocusModifier(isFocused: isFocused, enabled: enabled && answersKeys, actions: actions, listCommands: listCommands))
        } else {
            self
        }
    }

    /// The task's VoiceOver actions.
    func atticTaskAccessibilityActions(_ actions: AtticTaskActions, state: AtticTaskState) -> some View {
        accessibilityActions {
            ForEach(Array(actions.accessibilityActions(for: state).enumerated()), id: \.offset) { _, action in
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

/// A list's keyboard focus for one of its rows: the list owns one
/// `FocusState<UUID?>` for all its rows, so ↑ ↓ and a click can move focus
/// from row to row (Phase 1).
struct AtticRowFocus {
    let binding: FocusState<UUID?>.Binding
    let id: UUID
    /// Read when the list builds the row, as a value: the row redraws its
    /// ring the moment focus moves (a binding alone let it lag a row
    /// behind, the computer-use review's bug 4).
    let isFocused: Bool

    init(binding: FocusState<UUID?>.Binding, id: UUID) {
        self.binding = binding
        self.id = id
        isFocused = binding.wrappedValue == id
    }
}

/// The same keys as `AtticTaskFocusModifier`, with focus held by the list.
private struct AtticListTaskFocusModifier: ViewModifier {
    let enabled: Bool
    /// Off while the row's title is edited: the row stays focusable (so
    /// its focus never jumps elsewhere as the editor appears), but the
    /// editor, not the row, takes the keys.
    let answersKeys: Bool
    let actions: AtticTaskActions
    let listCommands: Bool
    let focus: AtticRowFocus

    func body(content: Content) -> some View {
        content
            .focusable(enabled)
            .focused(focus.binding, equals: focus.id)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                guard enabled, answersKeys, let command = AtticTaskKeys.command(
                    key: press.key, characters: press.characters, modifiers: press.modifiers, listCommands: listCommands
                ) else { return .ignored }
                AtticTaskKeys.perform(command, actions)
                return .handled
            }
    }
}

/// Editing a row's title in place (Return or a double-click): Return
/// saves, Esc cancels, and leaving the field saves (nothing typed is lost).
struct AtticTitleEditing {
    var text: Binding<String>
    /// Saves; false when the save failed, so the field stays open with the
    /// text and Return can try again.
    let commit: () -> Bool
    let cancel: () -> Void
    /// The title editor understands the add bar's shorthand (owner fix 4):
    /// what it draws as chips and what the field reports. nil keeps a
    /// plain field (the new-subtask line).
    var tokens: Tokens? = nil
    /// VoiceOver's name for the field ("Title", "New subtask of …").
    var accessibilityLabel = String(localized: "Title")

    struct Tokens {
        var chips: [NSRange]
        /// Backspace after a chip, edits and the caret, as in the add bar.
        let dismissChip: (NSRange) -> Void
        let edited: (NSRange, String) -> Void
        let caretMoved: (Int) -> Void
        let undoFallback: () -> Void
        let redoFallback: () -> Void
        /// The title's own undo history (text and pieces together).
        var undoDraft: (() -> (text: String, selection: NSRange)?)? = nil
        var redoDraft: (() -> (text: String, selection: NSRange)?)? = nil
        var selectionMoved: ((NSRange) -> Void)? = nil
    }
}

/// The title editor: the row's title style, in place, focused on appear.
/// With `tokens`, the add bar's native chip field (owner fix 4).
struct AtticRowTitleEditor: View {
    let editing: AtticTitleEditing

    @Environment(\.atticDesign) private var design
    @FocusState private var focused: Bool
    @State private var tokenFocused = true
    @State private var finished = false
    /// How often the editor took the keyboard back from a loss no input
    /// caused (the list settling as the editor appears).
    @State private var reclaims = 0

    var body: some View {
        if let tokens = editing.tokens {
            AtticTokenField(
                text: editing.text,
                chips: tokens.chips,
                isFocused: $tokenFocused,
                accessibilityLabel: editing.accessibilityLabel,
                actions: AtticTokenFieldActions(
                    submit: { _ in finish(commit: true) },
                    dismissChip: tokens.dismissChip,
                    multilinePaste: { _ in false },
                    escape: { finish(commit: false); return true },
                    undoFallback: tokens.undoFallback,
                    redoFallback: tokens.redoFallback,
                    edited: tokens.edited,
                    caretMoved: tokens.caretMoved,
                    undoDraft: tokens.undoDraft,
                    redoDraft: tokens.redoDraft,
                    selectionMoved: tokens.selectionMoved
                ),
                style: .rowTitle,
                ink: .heading,
                accessibilityIdentifier: "AtticTitleField"
            )
            .frame(height: AtticTaskRowMetrics.titleLineHeight)
            .onAppear { tokenFocused = true }
            .onChange(of: tokenFocused) { _, now in lost(now) { tokenFocused = true } }
            .onChange(of: editing.text.wrappedValue) { _, _ in finished = false }
        } else {
            TextField("", text: editing.text)
                .textFieldStyle(.plain)
                .font(AtticTextStyle.rowTitle.font)
                .foregroundStyle(design.tokens.color(.heading))
                .focused($focused)
                .onSubmit { finish(commit: true) }
                .onExitCommand { finish(commit: false) }
                .onAppear {
                    focused = true
                    // Again once the list has settled its own focus for this
                    // change, so the field keeps the keyboard.
                    DispatchQueue.main.async { if !finished { focused = true } }
                }
                .onChange(of: focused) { _, now in lost(now) { focused = true } }
                // A field that stays for the next entry (a new subtask) is
                // ready again once its text is cleared or changed.
                .onChange(of: editing.text.wrappedValue) { _, _ in finished = false }
                .accessibilityLabel(editing.accessibilityLabel)
        }
    }

    /// The field lost the keyboard. A person's departure (a click, a key)
    /// saves; a loss no input caused is the list settling its own focus as
    /// the editor is presented, and the editor takes the keyboard back, a
    /// couple of times at most (round 4: no timing guess, and a click
    /// elsewhere is never overridden).
    private func lost(_ now: Bool, refocus: @escaping () -> Void) {
        guard !now else { return }
        if Self.isPersonsDeparture(NSApp.currentEvent?.type) || reclaims >= 2 {
            finish(commit: true)
        } else {
            reclaims += 1
            DispatchQueue.main.async { if !finished { refocus() } }
        }
    }

    /// Input a person makes to leave a field.
    static func isPersonsDeparture(_ type: NSEvent.EventType?) -> Bool {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown: true
        default: false
        }
    }

    private func finish(commit: Bool) {
        guard !finished else { return }
        if commit {
            // A failed save leaves the editor ready to try again.
            finished = editing.commit()
        } else {
            finished = true
            editing.cancel()
        }
    }
}

// MARK: - Status circle

/// The status circle shows and changes a task's state (Direction A,
/// 2026-09-26: the circle is for completion; priority is a mark after the
/// title):
///
/// - **To do:** one confident ring (16 pt, 1.6 pt, the task text's ink),
///   whatever the priority.
/// - **In progress:** the same ring with a 5 pt filled centre dot
///   ("working on it") until a subtask is ticked; then a true pie of the
///   share ticked, with no minimum (owner, 2026-09-26). A task not started
///   keeps its empty ring whatever its subtasks say (its "☑ n/m" shows it).
/// - **Done:** a quiet grey disc with a darker grey check.
/// - **Backlog (Later):** the same ring, dashed.
///
/// Completing: the done disc sweeps in from 12 o'clock, then the check
/// draws and the haptic tick lands (springs, so a change of mind mid-way
/// reverses smoothly); Reduce Motion fades the done disc in. Disabled, the
/// ring takes the disabled icon colour (3 : 1), never faded below it.
struct AtticStatusCircle: View {
    let state: AtticTaskState
    /// Ticked and total subtasks: in progress, the pie once one is ticked.
    var subtasks: (done: Int, total: Int)?
    /// Pin the check's drawing progress (gallery); nil animates live.
    var checkProgress: Double?
    /// Pin the completion sweep, 0 (nothing) to 1 (the full disc)
    /// (gallery); nil animates live.
    var completionProgress: Double?
    var isDisabled = false
    /// Hovered, or its row has keyboard focus: an open ring steps up from
    /// its quiet rest to a firm ring (owner fix 1 + review 12), without
    /// changing its geometry.
    var isEmphasised = false

    @Environment(\.atticDesign) private var design
    @State private var completion: Double = 1
    @State private var drawnCheck: Double = 1
    @State private var discOpacity: Double = 1
    @State private var probeID = UUID()
    @State private var checkProbeID = UUID()

    /// Phase 0's confident circles: the ring is the task title's primary
    /// ink, open or working (the working one adds its centre dot).
    static let ringInk: AtticInk = .heading
    static let activeInk: AtticInk = .heading
    /// The appearance check's name for an open (to do or Later) ring.
    static let openRingProbeName = "open status ring"

    var body: some View {
        let tokens = design.tokens
        let m = AtticStatusCircleMetrics.self
        let ringInk: AtticInk = isDisabled ? .disabledIcon : (state == .inProgress ? Self.activeInk : Self.ringInk)
        let colour = tokens.color(ringInk)
        // An open ring (to do, Later) is the quiet ring of owner fix 1.
        let openColour = isDisabled ? colour : tokens.openRing(emphasised: isEmphasised).color
        let openForeground = isDisabled ? tokens.ink(ringInk) : tokens.openRing(emphasised: isEmphasised)
        let width = m.ringWidth(increaseContrast: design.increaseContrast)
        let size = AtticControlSize.statusCircle
        let motion = AtticMotionPreset.complete.animation(reduceMotion: design.reduceMotion)
        ZStack {
            switch state {
            case .todo:
                Circle().inset(by: m.edgeInset + width / 2).stroke(openColour, lineWidth: width)
                    .atticOpenRingProbe(id: probeID, ink: ringInk, foreground: openForeground, disabled: isDisabled)
            case .inProgress:
                Circle().inset(by: m.edgeInset + width / 2).stroke(colour, lineWidth: width)
                    .atticRingProbe(id: probeID, ink: ringInk, tokens: tokens)
                if let share = Self.pieShare(subtasks) {
                    AtticWedge(sweep: share, inset: m.wedgeInset(ringWidth: width))
                        .fill(colour)
                        .animation(motion, value: share)
                } else {
                    Circle().fill(colour)
                        .frame(width: m.activeDotDiameter, height: m.activeDotDiameter)
                }
            case .done:
                AtticCompletionMark(
                    completion: completionProgress ?? completion,
                    ring: tokens.color(isDisabled ? .disabledIcon : Self.ringInk), ringWidth: width, disc: tokens.doneDisc.color
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
                let backlogInk: AtticInk = isDisabled ? .disabledIcon : Self.ringInk
                Circle().inset(by: m.edgeInset + dashed / 2)
                    .stroke(openColour, style: StrokeStyle(lineWidth: dashed, dash: m.backlogDash))
                    .atticOpenRingProbe(id: probeID, ink: backlogInk, foreground: openForeground, disabled: isDisabled)
            }
        }
        .frame(width: size, height: size)
        // One confirmation per completion (round 4, review 22): the disc and
        // its check arrive together; the haptic is the command's (the page
        // ticks once when the change saved), never one per drawn circle.
        .onChange(of: state) { old, new in
            guard new == .done, old != .done, checkProgress == nil, completionProgress == nil else { return }
            if design.reduceMotion {
                completion = 1
                drawnCheck = 1
                discOpacity = 0
                withAnimation(motion) { discOpacity = 1 }
            } else {
                completion = 0
                drawnCheck = 0
                discOpacity = 1
                withAnimation(motion) {
                    completion = 1
                    drawnCheck = 1
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// In progress: the pie's share, or nil (the centre dot) while no
    /// subtask is ticked. A true share, with no minimum.
    static func pieShare(_ subtasks: (done: Int, total: Int)?) -> Double? {
        guard let subtasks, subtasks.total > 0, subtasks.done > 0 else { return nil }
        return min(1, Double(subtasks.done) / Double(subtasks.total))
    }

    /// The spoken state: "in progress, 1 of 3 subtasks".
    static func spokenState(_ state: AtticTaskState, subtasks: (done: Int, total: Int)?) -> String {
        guard state == .inProgress, let subtasks, subtasks.total > 0 else { return state.spokenName }
        return state.spokenName + ", " + String(localized: "\(subtasks.done) of \(subtasks.total) subtasks")
    }
}

/// Completing: the done disc sweeps in from 12 o'clock while the ring
/// fades. At 1 it is the done disc alone.
private struct AtticCompletionMark: View, Animatable {
    var completion: Double
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
        let inset = m.wedgeInset(ringWidth: ringWidth) * (1 - c) + m.edgeInset * c
        ZStack {
            if c < 1 {
                Circle().inset(by: m.edgeInset + ringWidth / 2).stroke(ring, lineWidth: ringWidth).opacity(1 - c)
            }
            AtticWedge(sweep: c, inset: inset).fill(disc)
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

    /// An open ring: named apart ("open status ring") so the appearance
    /// test's `OpenRingException` can hold it to the owner's quiet ring and
    /// nothing else. A disabled ring keeps the disabled icon's 3 : 1.
    func atticOpenRingProbe(id: UUID, ink: AtticInk, foreground: AtticRGBA, disabled: Bool) -> some View {
        atticProbe { specimen in
            AtticProbe(id: id, kind: .icon(name: disabled ? "status circle" : AtticStatusCircle.openRingProbeName),
                       ink: ink, foreground: foreground, specimen: specimen)
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

/// A wedge of a disc from 12 o'clock, clockwise (the completion sweep), inset from
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
    /// Spoken with the state ("to do, high priority"); not drawn.
    let priority: AtticPriority
    /// Ticked and total subtasks: "in progress, 1 of 3 subtasks".
    var subtasks: (done: Int, total: Int)?
    var isDisabled = false
    var isTabStop = true
    /// The row has keyboard focus: the open ring steps up.
    var isEmphasised = false
    /// A click: done, or back from done.
    let onToggle: () -> Void

    @Environment(\.atticForcedState) private var forced
    @State private var hovered = false

    var body: some View {
        Button(action: onToggle) {
            AtticStatusCircle(state: state, subtasks: subtasks, isDisabled: isDisabled,
                              isEmphasised: isEmphasised || hovered || forced == .hover)
                .frame(width: AtticControlSize.minimumHitTarget, height: AtticControlSize.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusable(isTabStop)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .atticOwnFocusRing(.circle(diameter: AtticControlSize.statusCircle))
        .disabled(isDisabled)
        .help(state == .done ? String(localized: "Mark as not done") : String(localized: "Complete"))
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

    /// The ring shows when the gallery pins it, or when the button has focus
    /// while the keyboard drives; a click that focuses it shows none.
    static func shows(pinned: Bool, focused: Bool, keyboardFocusVisible: Bool) -> Bool {
        pinned || (focused && keyboardFocusVisible)
    }

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
    @Environment(\.atticKeyboardFocusVisible) private var keyboardFocusVisible

    func body(content: Content) -> some View {
        // Only while the keyboard drives: a click that focuses the button
        // shows no ring (owner decision 2026-09-25).
        let shows = AtticOwnFocusRing.shows(pinned: pinned, focused: focused, keyboardFocusVisible: keyboardFocusVisible)
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

// MARK: - Page tabs

/// ← and → between pages, for the page tabs and the page button while one
/// has keyboard focus: the page to show, clamped to the ends (the same
/// page at an end, still handled), or nil for any other key.
enum AtticPageArrows {
    static func next(from selected: Int, key: KeyEquivalent, modifiers: EventModifiers, count: Int) -> Int? {
        guard modifiers.intersection([.command, .option, .control, .shift]).isEmpty, count > 0 else { return nil }
        let step: Int
        switch key {
        case .leftArrow: step = -1
        case .rightArrow: step = 1
        default: return nil
        }
        return min(max(selected + step, 0), count - 1)
    }
}

/// Direction A's page tabs under the header ("Now · Later · Done"), in
/// place of a page title and the page pill. Phase 0's qualities
/// (2026-09-26): quiet text labels, no chips: 11.5 pt medium, the selected
/// page semibold in the strong ink (owner, 2026-09-27), the others in the
/// secondary grey, a hovered one in the task text's ink. Each label keeps
/// its semibold width, so nothing shifts when the selection moves.
///
/// One control for the keyboard: it takes focus once, and ← → move between
/// the pages while it has it (a ring around the selected label, only while
/// the keyboard drives). VoiceOver reads one group, "Pages", with a named,
/// selectable choice per page.
struct AtticPageTabs<Page: Hashable>: View {
    struct Item: Identifiable {
        let page: Page
        let title: String
        /// For UI tests and automation.
        var accessibilityIdentifier: String?
        var id: String { title }
    }

    let items: [Item]
    @Binding var selection: Page
    /// The gallery pins a state (hover, focus) on one tab only.
    var statePinnedPage: Page?

    @Environment(\.atticDesign) private var design
    @Environment(\.atticCapture) private var capture
    @Environment(\.atticForcedState) private var forced
    @Environment(\.atticKeyboardFocusVisible) private var keyboardFocusVisible
    @FocusState private var focused: Bool
    @State private var hoveredPage: Page?

    var body: some View {
        let m = AtticPageTabsMetrics.self
        let selected = items.firstIndex { $0.page == selection } ?? 0
        HStack(spacing: m.spacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let isSelected = index == selected
                let pinned = statePinnedPage == item.page ? forced : nil
                let hovered = !isSelected && (pinned == .hover || (pinned == nil && hoveredPage == item.page))
                let ringed = pinned == .focused || (capture == nil && isSelected && focused && keyboardFocusVisible)
                Button { select(item.page) } label: {
                    ZStack(alignment: .leading) {
                        // The semibold width, reserved in every state.
                        AtticText(verbatim: item.title, style: .pageTabSelected, ink: .heading)
                            .fixedSize()
                            .hidden()
                            .accessibilityHidden(true)
                        AtticText(verbatim: item.title, style: isSelected ? .pageTabSelected : .pageTab,
                                  ink: isSelected ? .heading : (hovered ? .body : .helper))
                            .fixedSize()
                    }
                        .frame(height: AtticLayout.pageTabsHeight)
                        .background {
                            if ringed {
                                Color.clear
                                    .atticFocusRing(true, cornerRadius: m.focusRadius)
                                    .padding(.horizontal, -m.focusOutset)
                            }
                        }
                        // A comfortable target around the small label.
                        .contentShape(Rectangle().inset(by: -m.hitOutset))
                        .transaction { $0.animation = nil }
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { inside in
                    if inside { hoveredPage = item.page } else if hoveredPage == item.page { hoveredPage = nil }
                }
                .accessibilityLabel(item.title)
                .accessibilityIdentifier(item.accessibilityIdentifier ?? item.title)
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .focusable(capture == nil)
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
    }

    private func select(_ page: Page) {
        withAnimation(AtticMotionPreset.slide.animation(reduceMotion: design.reduceMotion)) {
            selection = page
        }
    }
}

// MARK: - Task row

/// What a task row shows. The design system's own model: Phase 1 fills it
/// from the store.
struct AtticTaskRowModel: Identifiable, Sendable {
    struct Due: Sendable {
        /// Direction A: red only for overdue; today reads in the body
        /// colour, medium weight; the rest is the quiet secondary grey.
        enum Tone: Sendable, Equatable { case quiet, today, overdue }

        let text: String
        var tone: Tone = .quiet
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

    /// A second line only when the task has tags or subtasks (or a page,
    /// files or links, or is open in a window); done rows never have one.
    /// The due date always stays at the right end of the title line.
    var hasDetails: Bool {
        state != .done && (!tags.isEmpty || subtasks != nil || hasPage || attachments > 0 || links > 0 || inWindow)
    }

    /// The due date at the right end of the title line (none once done).
    var trailingDue: Due? {
        state == .done ? nil : due
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

/// The priority mark after a task's title (Direction A): High "!!" in the
/// orange mark colour, Medium "!" in the secondary grey, Low and None
/// nothing. Done rows show none.
struct AtticPriorityMark: View {
    let priority: AtticPriority
    var disabled = false

    var body: some View {
        switch priority {
        case .high:
            AtticText(verbatim: "!!", style: .priorityMark, ink: disabled ? .disabledText : .priorityMark)
                .fixedSize()
                .accessibilityHidden(true)
        case .medium:
            AtticText(verbatim: "!", style: .priorityMark, ink: disabled ? .disabledText : .helper)
                .fixedSize()
                .accessibilityHidden(true)
        case .low, .none:
            EmptyView()
        }
    }
}

/// A task row: 34 pt (a 30 pt highlight, 2 pt clear above and below), 48
/// pt with a details line; in the page, the circle's left edge at 16 and
/// the title at 44 (28 and 56 in the panel); highlight inset 8, radius 10.
/// Three click targets: the circle (done, or back), the subtask checklist
/// on the details line (quick look), and the rest (select). Keyboard
/// focusable: a focused row draws the 2 pt accent ring and answers the
/// task keys (`AtticTaskKeys`).
struct AtticTaskRow: View {
    /// The row's own coordinate space, for its controls' frames.
    static let space = NamedCoordinateSpace.named("AtticTaskRow")

    let model: AtticTaskRowModel
    var isSelected = false
    var selectionRun: AtticSelectionRun = .single
    var isExpanded = false
    /// "Add to page" while a file hovers over the row.
    var dropLabel: String?
    let actions: AtticTaskActions
    /// The subtask count: opens or closes the quick look.
    let onToggleExpanded: () -> Void
    /// A click on the row (Phase 1: selects; the page arrives in Phase 3).
    /// nil opens the page, as the spec's row does.
    var onSelect: (() -> Void)? = nil
    /// The list's focus for this row (↑ ↓ move it); nil keeps its own.
    var focus: AtticRowFocus? = nil
    /// Editing the title in place.
    var titleEditing: AtticTitleEditing? = nil
    /// The date and tags as buttons with their pickers (owner fix 5 C);
    /// nil draws them as text (the Done log, captures).
    var meta: AtticRowMeta? = nil

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.atticCapture) private var capture
    @Environment(\.atticKeyboardFocusVisible) private var keyboardFocusVisible
    @State private var focused = false
    @State private var hovered = false
    @State private var dateHovered = false
    @State private var probeID = UUID()

    var body: some View {
        let tokens = design.tokens
        let m = AtticTaskRowMetrics.self
        let state = AtticStateResolver(forced: forced, isEnabled: isEnabled, isHovered: hovered, isPressed: false, isFocused: false).state
        // Captures have no focus system: FocusState is read only when live.
        // The ring shows only while the keyboard drives (a click shows none).
        let rowFocused = focus?.isFocused ?? focused
        let showsFocusRing = forced == .focused || (forced == nil && isEnabled && rowFocused && keyboardFocusVisible && titleEditing == nil)
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

            // The circle, centred on the title line (row top + 17), its
            // 28 pt hit area around the 14 pt drawing.
            AtticStatusButton(state: model.state, priority: model.priority, subtasks: model.subtasks, isDisabled: disabled, isTabStop: false,
                              isEmphasised: showsFocusRing, onToggle: actions.toggleDone)
                .atticForcedState(nil)
                .atticRowControl()
                .padding(.leading, AtticLayout.circleX + AtticControlSize.statusCircle / 2 - AtticControlSize.minimumHitTarget / 2)
                .padding(.top, m.circleCentreY(twoLine: twoLine) - m.pitchTopInset - AtticControlSize.minimumHitTarget / 2)

            // The title line (title, priority mark, and the date on the
            // title's baseline), then the details line.
            VStack(alignment: .leading, spacing: m.titleToDetails) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if let titleEditing, capture == nil {
                        AtticRowTitleEditor(editing: titleEditing)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: AtticPriorityMarkMetrics.titleGap) {
                            AtticText(
                                verbatim: model.title,
                                // Phase 0's qualities: SF Pro Rounded, medium
                                // while in progress, in the primary ink.
                                style: model.state == .inProgress ? .rowTitleActive : .rowTitle,
                                // Done fades the title, without a strike (v9).
                                ink: disabled ? .disabledText : (done ? .helper : .heading),
                                truncates: true
                            )
                            // The title gives way first (review 13): the
                            // mark and the date keep their room; the full
                            // title is the tooltip (and VoiceOver's label).
                            .layoutPriority(-1)
                            .help(model.title)
                            if !done {
                                AtticPriorityMark(priority: model.priority, disabled: disabled)
                            }
                        }
                    }
                    Spacer(minLength: m.trailingMinGap)
                    trailing(disabled: disabled)
                }
                .frame(height: m.titleLineHeight)
                if twoLine {
                    AtticTaskDetails(model: model, disabled: disabled, isExpanded: isExpanded, onToggleExpanded: onToggleExpanded,
                                     onTags: capture == nil ? meta?.onTags : nil)
                        .frame(height: m.detailsLineHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .popover(isPresented: tagsPresented(twoLine: true), arrowEdge: .bottom) { meta?.tagPicker() }
                }
            }
            .padding(.leading, AtticLayout.textX)
            .padding(.trailing, AtticLayout.rowHighlightInset + m.dateInset)
            .padding(.top, m.titleTop(twoLine: twoLine) - m.pitchTopInset)
            // "New Tag…" on a row with no tags: the list opens under the title.
            .background(alignment: .bottomLeading) {
                if !twoLine || model.tags.isEmpty {
                    Color.clear.frame(width: 1, height: 1)
                        .padding(.leading, AtticLayout.textX)
                        .popover(isPresented: tagsPresented(twoLine: false), arrowEdge: .bottom) { meta?.tagPicker() }
                }
            }
        }
        // The highlight and the content sit 1 pt below the row's top; the
        // row is exactly its pitch (no half-point centring).
        .frame(height: pitch - m.pitchTopInset, alignment: .top)
        .padding(.top, m.pitchTopInset)
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
        .onTapGesture { if isEnabled { (onSelect ?? actions.openPage)() } }
        .atticTaskFocus($focused, enabled: isEnabled, actions: actions, listCommands: true,
                        live: capture == nil, external: focus, answersKeys: titleEditing == nil)
        // While the title is edited, its field is its own element, so
        // VoiceOver (and a UI test) reaches the text being typed.
        .accessibilityElement(children: titleEditing == nil ? .combine : .contain)
        .accessibilityLabel(model.accessibilityDescription)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction { actions.openPage() }
        .atticTaskAccessibilityActions(actions, state: model.state)
        .accessibilityActions {
            if model.subtasks != nil, model.state != .done {
                Button(isExpanded ? String(localized: "Hide subtasks") : String(localized: "Show subtasks"), action: onToggleExpanded)
            }
            // The date and tags controls, for VoiceOver (review 17).
            if let meta, capture == nil {
                Button(String(localized: "Change date"), action: meta.onDate)
                Button(String(localized: "Change tags"), action: meta.onTags)
            }
        }
        .coordinateSpace(Self.space)
        .atticControlProbe(
            twoLine ? "Task row (details)" : "Task row", id: probeID,
            expectedSize: CGSize(width: 0, height: pitch), radius: AtticRadius.highlight, expectedRadius: 10
        )
    }

    /// The right-hand meta: the due date, always here, on the title's
    /// baseline (or "Add to page" while a file hovers over the row).
    @ViewBuilder
    private func trailing(disabled: Bool) -> some View {
        if let dropLabel {
            AtticText(verbatim: dropLabel, style: .dropLabel, ink: .accentText, allowsOverlap: true)
                .fixedSize()
        } else if let due = model.trailingDue {
            if let meta, capture == nil, !disabled {
                // A button (owner fix 5 C): hover shows its pill; a click
                // opens the date picker, which may reach past the panel.
                Button(action: meta.onDate) {
                    AtticDueText(due: due, disabled: disabled)
                        .fixedSize()
                        .background(AtticMetaPill(visible: dateHovered))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .onHover { dateHovered = $0 }
                .atticRowControl()
                .help(String(localized: "Change the date"))
                .accessibilityLabel(String(localized: "Due \(due.text)"))
                .accessibilityHint(String(localized: "Changes the date"))
                .popover(isPresented: meta.datePresented, arrowEdge: .bottom) { meta.datePicker() }
            } else {
                AtticDueText(due: due, disabled: disabled)
                    .fixedSize()
            }
        } else if let meta, capture == nil {
            // No date yet: "Pick a Date…" opens the picker from here.
            Color.clear.frame(width: 1, height: 1)
                .popover(isPresented: meta.datePresented, arrowEdge: .bottom) { meta.datePicker() }
        }
    }

    /// The tag list's presentation, attached where it points: the tags on
    /// the details line, or under the title when there are none.
    private func tagsPresented(twoLine attachedToDetails: Bool) -> Binding<Bool> {
        guard let meta, capture == nil else { return .constant(false) }
        let hasTagsLine = model.hasDetails && !model.tags.isEmpty
        guard attachedToDetails == hasTagsLine else { return .constant(false) }
        return meta.tagsPresented
    }
}

/// The frames of the controls inside a task row (its circle, checklist,
/// date and tags), in the row's own coordinate space
/// (`AtticTaskRow.space`), so a list can keep a drag from starting on
/// them (round 4: embedded controls keep their own presses).
struct AtticRowControlFramesKey: PreferenceKey {
    static var defaultValue: [CGRect] { [] }

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Reports this control's frame in its task row (see
    /// `AtticRowControlFramesKey`).
    func atticRowControl() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: AtticRowControlFramesKey.self, value: [proxy.frame(in: AtticTaskRow.space)])
        })
    }
}

/// A row's date and tags as controls (owner fix 5 C): their clicks and the
/// pickers they open, which the page supplies.
struct AtticRowMeta {
    let onDate: () -> Void
    let onTags: () -> Void
    var datePresented: Binding<Bool>
    var tagsPresented: Binding<Bool>
    /// The same as values: SwiftUI compares a row's inputs by value, and a
    /// binding alone does not tell it the row must redraw its popover.
    var isDateOpen = false
    var isTagsOpen = false
    let datePicker: () -> AnyView
    let tagPicker: () -> AnyView
}

/// A due date as rows and cards show it: overdue red, today the body
/// colour in medium weight, the rest the quiet secondary grey.
struct AtticDueText: View {
    let due: AtticTaskRowModel.Due
    var disabled = false

    var body: some View {
        switch due.tone {
        case .overdue:
            AtticText(verbatim: due.text, style: .rowMeta, ink: disabled ? .disabledText : .dueText)
        case .today:
            AtticText(verbatim: due.text, style: .rowMetaEmphasis, ink: disabled ? .disabledText : .body)
        case .quiet:
            AtticText(verbatim: due.text, style: .rowMeta, ink: disabled ? .disabledText : .helper)
        }
    }
}

/// The details line: tags, then the subtask checklist (a control: it opens
/// the quick look), then a page, files and links, only when present. No
/// separators (owner fix 2, between v16's 4a and 4b): items sit 14 pt
/// apart, each small icon 5 pt before its label.
///
/// Overflow (review 13): everything but the tags keeps its natural width,
/// so the checklist control always stays on the line; the tags take what
/// is left, falling back to "#first +N" and then to a truncated first tag
/// with its "+N". The full list is in VoiceOver and the tag popover.
struct AtticTaskDetails: View {
    let model: AtticTaskRowModel
    let disabled: Bool
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    /// A click on the tags (the row's tag popover); nil draws plain text.
    var onTags: (() -> Void)? = nil

    var body: some View {
        let m = AtticTaskRowMetrics.self
        let text: AtticInk = disabled ? .disabledText : .helper
        let icon: AtticInk = disabled ? .disabledIcon : .icon
        HStack(spacing: m.detailsItemSpacing) {
            if model.inWindow {
                HStack(spacing: m.detailsIconGap) {
                    AtticIcon(systemName: "macwindow", size: m.detailsIconSize, weight: .light, ink: icon)
                    AtticText("In window", style: .rowMeta, ink: text)
                }
                .fixedSize()
                .layoutPriority(1)
            }
            if !model.tags.isEmpty {
                AtticDetailsTags(tags: model.tags, disabled: disabled, onTags: onTags)
            }
            if let subtasks = model.subtasks {
                AtticSubtaskChecklistButton(
                    done: subtasks.done, total: subtasks.total, isExpanded: isExpanded, disabled: disabled, action: onToggleExpanded
                )
                .fixedSize()
                .layoutPriority(1)
            }
            if model.hasPage {
                HStack(spacing: m.detailsIconGap) {
                    AtticIcon(systemName: "doc.text", size: m.detailsIconSize, weight: .light, ink: icon)
                    AtticText("Page", style: .rowMeta, ink: text)
                }
                .fixedSize()
                .layoutPriority(1)
            }
            if model.attachments > 0 {
                HStack(spacing: m.detailsIconGap) {
                    AtticIcon(systemName: "paperclip", size: m.detailsIconSize, weight: .light, ink: icon)
                    AtticText(verbatim: "\(model.attachments)", style: .rowMeta, ink: text)
                }
                .fixedSize()
                .layoutPriority(1)
            }
            if model.links > 0 {
                AtticText(verbatim: String(localized: "\(model.links) links"), style: .rowMeta, ink: text)
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
        .lineLimit(1)
    }
}

/// The tags on a details line: all of them when they fit, else the first
/// and "+N", else the first truncated with its "+N". A click (with a hover
/// pill, owner fix 5 C) opens the row's tag popover when the row offers it.
private struct AtticDetailsTags: View {
    let tags: [String]
    let disabled: Bool
    let onTags: (() -> Void)?

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    var body: some View {
        let ink: AtticInk = disabled ? .disabledText : .accentText
        let content = ViewThatFits(in: .horizontal) {
            all(ink: ink)
            if tags.count > 1 {
                HStack(spacing: AtticTaskRowMetrics.detailsItemSpacing) {
                    AtticText(verbatim: "#" + tags[0], style: .rowMeta, ink: ink).fixedSize()
                    more(ink: ink)
                }
            }
            HStack(spacing: AtticTaskRowMetrics.detailsItemSpacing) {
                AtticText(verbatim: "#" + tags[0], style: .rowMeta, ink: ink, truncates: true)
                if tags.count > 1 { more(ink: ink) }
            }
        }
        if let onTags, !disabled {
            Button(action: onTags) {
                content
                    .background(AtticMetaPill(visible: hovered))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .onHover { hovered = $0 }
            .atticRowControl()
            .help(tags.map { "#" + $0 }.joined(separator: " "))
            .accessibilityLabel(String(localized: "Tags: \(tags.joined(separator: ", "))"))
            .accessibilityHint(String(localized: "Changes the tags"))
        } else {
            content
        }
    }

    private func all(ink: AtticInk) -> some View {
        HStack(spacing: AtticTaskRowMetrics.detailsItemSpacing) {
            ForEach(tags, id: \.self) { tag in
                AtticText(verbatim: "#" + tag, style: .rowMeta, ink: ink).fixedSize()
            }
        }
    }

    private func more(ink: AtticInk) -> some View {
        AtticText(verbatim: "+\(tags.count - 1)", style: .rowMeta, ink: disabled ? .disabledText : .helper)
            .fixedSize()
    }
}

/// The hover pill behind a row's clickable date or tags (owner fix 5 C):
/// it says "this is a button" without drawing one at rest.
struct AtticMetaPill: View {
    let visible: Bool

    @Environment(\.atticDesign) private var design

    var body: some View {
        let m = AtticTaskRowMetrics.self
        RoundedRectangle(cornerRadius: AtticRadius.control(height: m.metaPillHeight), style: .continuous)
            .fill((visible ? design.tokens.chipHover : .clear).color)
            .frame(height: m.metaPillHeight)
            .padding(.horizontal, -m.metaPillOutset)
            .allowsHitTesting(false)
    }
}

/// "☑ 1/3" on the details line: the second click target, which opens and
/// closes the quick look. A checklist glyph and the count, with a hover
/// fill so it reads as a control; its text stays on the details line.
private struct AtticSubtaskChecklistButton: View {
    let done: Int
    let total: Int
    let isExpanded: Bool
    let disabled: Bool
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @State private var hovered = false

    var body: some View {
        let m = AtticSubtaskChecklistMetrics.self
        let radius = AtticRadius.control(height: m.height)
        let hover = !disabled && (forced == .hover || hovered)
        Button(action: action) {
            HStack(spacing: m.iconGap) {
                AtticIcon(systemName: "checkmark.square", size: m.iconSize, weight: .regular, ink: disabled ? .disabledIcon : .icon)
                    .frame(width: m.iconSlot)
                AtticText(verbatim: "\(done)/\(total)", style: .count, ink: disabled ? .disabledText : .helper)
            }
            .padding(.horizontal, m.horizontalPadding)
            .frame(height: m.height)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill((hover ? design.tokens.chipHover : .clear).color)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .atticOwnFocusRing(.rounded(radius: radius, height: m.height))
        .disabled(disabled)
        .onHover { hovered = $0 }
        .padding(.horizontal, -m.horizontalPadding)
        .frame(height: AtticTaskRowMetrics.detailsLineHeight)
        .atticRowControl()
        .help(isExpanded ? String(localized: "Hide subtasks") : String(localized: "Show subtasks"))
        .accessibilityLabel(String(localized: "\(done) of \(total) subtasks"))
        .accessibilityValue(isExpanded ? String(localized: "expanded") : String(localized: "collapsed"))
        .accessibilityHint(isExpanded ? String(localized: "Collapses the quick look") : String(localized: "Expands the quick look"))
    }
}

/// "Completed today · N": the Now list's done section as a disclosure
/// (owner, 2026-09-26). Its chevron sits centred on the circles' line (›
/// shut, turning to ⌄ open), so the circle column is never empty for it,
/// and its text on the titles' line. Laid out across the row's width.
struct AtticCompletedLine: View {
    let title: String
    let count: Int
    let isExpanded: Bool
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @State private var hovered = false

    var body: some View {
        let m = AtticCompletedLineMetrics.self
        let hover = forced == .hover || hovered
        Button(action: action) {
            HStack(spacing: 0) {
                AtticIcon(systemName: "chevron.right", size: m.chevronSize, weight: .medium, ink: hover ? .body : .chevron)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: AtticControlSize.statusCircle)
                    .padding(.leading, AtticLayout.circleX)
                    .padding(.trailing, AtticLayout.textX - AtticLayout.circleX - AtticControlSize.statusCircle)
                HStack(spacing: m.gap) {
                    AtticText(verbatim: title, style: .sectionToggle, ink: hover ? .body : .helper)
                    AtticText(verbatim: "·", style: .sectionToggle, ink: .helper)
                    AtticText(verbatim: "\(count)", style: .sectionToggle, ink: hover ? .body : .helper)
                }
                Spacer(minLength: 0)
            }
            .frame(height: m.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(AtticMotionPreset.hover.animation(reduceMotion: design.reduceMotion), value: isExpanded)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue(isExpanded ? String(localized: "expanded") : String(localized: "collapsed"))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Quick look and subtasks

/// A subtask's rounded-square checkbox (tasks keep circles, so the two never
/// look alike). Done matches a done task: the quiet grey (`doneDisc`) with
/// a darker grey check (`doneCheck`, 3 : 1 on it); the fill is decoration,
/// the check is what the appearance check judges.
struct AtticSubtaskCheckbox: View {
    let isDone: Bool

    @Environment(\.atticDesign) private var design
    @State private var checkProbeID = UUID()
    @State private var probeID = UUID()

    var body: some View {
        let tokens = design.tokens
        let m = AtticSubtaskMetrics.self
        let size = AtticControlSize.subtaskCheckbox
        // A true squircle (superellipse, n = 4): the owner's choice, 2026-09-26.
        let shape = Squircle(cornerRadius: size / 2, exponent: AtticRadius.subtaskCheckboxExponent)
        let lineWidth = design.increaseContrast ? m.lineWidthIncreased : m.lineWidth
        ZStack {
            if isDone {
                shape.fill(tokens.doneDisc.color)
                AtticCheckShape()
                    .stroke(tokens.color(.doneCheck), style: StrokeStyle(lineWidth: m.checkLineWidth, lineCap: .round, lineJoin: .round))
                    .atticCheckProbe(id: checkProbeID, ink: .doneCheck, foreground: tokens.ink(.doneCheck))
                    .padding(m.checkInset)
            } else {
                shape.inset(by: lineWidth / 2).stroke(tokens.color(.priorityNone), lineWidth: lineWidth)
                    .atticProbe { [probeID] specimen in
                        AtticProbe(id: probeID, kind: .icon(name: "subtask checkbox"), ink: .priorityNone, foreground: tokens.ink(.priorityNone), specimen: specimen)
                    }
            }
        }
        .frame(width: size, height: size)
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
            AtticText(verbatim: subtask.title, style: .listBody, ink: subtask.isDone ? .helper : .body, strikethrough: subtask.isDone, truncates: true)
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
    /// While a subtask is being written (Phase 1): an unticked box and the
    /// title field in place of "Add subtask". Return adds it and keeps the
    /// field for the next one; Esc stops.
    var newSubtask: AtticTitleEditing? = nil

    @Environment(\.atticCapture) private var capture
    @Environment(\.atticDesign) private var design

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(subtasks) { subtask in
                AtticSubtaskRow(subtask: subtask) { onToggle(subtask) }
            }
            if let newSubtask, capture == nil {
                HStack(spacing: AtticSubtaskMetrics.titleGap) {
                    AtticSubtaskCheckbox(isDone: false)
                    AtticRowTitleEditor(editing: newSubtask)
                }
                .frame(height: AtticLayout.subtaskPitch)
            } else {
                AtticQuietAction(systemName: "plus", title: String(localized: "Add subtask"), action: onAddSubtask)
            }
            // "Open files" with Explicit Phase 1 Labels (a live task's files
            // and details panel until task pages arrive).
            AtticQuietAction(systemName: nil, title: AtticPhase1Labels.openLiveTaskAction(design.variants), trailingChevron: true, emphasised: true, action: onOpenPage)
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
                AtticStatusButton(state: model.state, priority: model.priority, subtasks: model.subtasks, isTabStop: false, onToggle: actions.toggleDone)
                    .atticForcedState(nil)
                    .padding(.leading, m.leadingInset - hitInset)
                    .padding(.top, m.circleTop)
                VStack(alignment: .leading, spacing: AtticTaskRowMetrics.titleToDetails) {
                    AtticText(verbatim: model.title, style: .rowTitle, ink: model.state == .done ? .helper : .body, truncates: true)
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
                        AtticQuietAction(systemName: "doc.text", title: AtticPhase1Labels.openLiveTaskAction(design.variants), emphasised: true, action: actions.openPage)
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
        .atticTaskAccessibilityActions(actions, state: model.state)
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
                    AtticIcon(systemName: "calendar", size: AtticTaskRowMetrics.detailsIconSize, ink: due.tone == .overdue ? .priorityHigh : .icon)
                    AtticDueText(due: due)
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
