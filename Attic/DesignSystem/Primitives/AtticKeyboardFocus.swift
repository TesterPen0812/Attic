import AppKit
import Combine
import SwiftUI

/// Whether focus rings show: only while the keyboard is driving (owner
/// decision 2026-09-25: "focus rings appear only for keyboard navigation;
/// a mouse click must not show a ring"). Components that draw Attic's own
/// ring read it; it defaults to true, so the gallery and captures, which
/// pin the focused state, still draw it.
private struct AtticKeyboardFocusVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var atticKeyboardFocusVisible: Bool {
        get { self[AtticKeyboardFocusVisibleKey.self] }
        set { self[AtticKeyboardFocusVisibleKey.self] = newValue }
    }
}

/// Follows how the person is moving around: a navigation key (Tab, the
/// arrows) turns rings on, a click turns them off. Event-driven (a local
/// event monitor, installed only while the view is on screen); nothing is
/// polled.
@MainActor
final class AtticKeyboardFocusTracker: ObservableObject {
    @Published private(set) var isKeyboardDriving = false
    private var monitor: Any?
    /// Whether it is watching events (on screen).
    var isTracking: Bool { monitor != nil }

    /// Tab, and the four arrows.
    static let navigationKeyCodes: Set<UInt16> = [48, 123, 124, 125, 126]

    /// Starting and stopping each begin with no rings: a tracker that was
    /// off screen saw no clicks, so a ring it left on would stay on after
    /// the person clicked elsewhere (round 5: the Done page's first row).
    func start() {
        guard monitor == nil else { return }
        if isKeyboardDriving { isKeyboardDriving = false }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.observe(event.type, keyCode: event.type == .keyDown ? event.keyCode : nil,
                          inField: AtticTextInput.isTyping(event.window?.firstResponder))
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isKeyboardDriving { isKeyboardDriving = false }
    }

    /// Exposed for tests: what one event does to the state.
    /// `inField`: a text field has the keyboard, where the arrows move the
    /// insertion point, not focus (only Tab moves on from a field).
    func observe(_ type: NSEvent.EventType, keyCode: UInt16?, inField: Bool = false) {
        switch type {
        case .keyDown:
            guard let keyCode, Self.navigationKeyCodes.contains(keyCode), !inField || keyCode == 48 else { break }
            if !isKeyboardDriving { isKeyboardDriving = true }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if isKeyboardDriving { isKeyboardDriving = false }
        default:
            break
        }
    }

    /// Something the keyboard did outside the monitored keys (a shortcut
    /// that moves focus) counts as keyboard driving too.
    func noteKeyboardNavigation() {
        if !isKeyboardDriving { isKeyboardDriving = true }
    }
}

private struct AtticKeyboardFocusTracking: ViewModifier {
    @ObservedObject var tracker: AtticKeyboardFocusTracker

    func body(content: Content) -> some View {
        content
            .environment(\.atticKeyboardFocusVisible, tracker.isKeyboardDriving)
            .onAppear { tracker.start() }
            .onDisappear { tracker.stop() }
    }
}

extension View {
    /// Shows Attic's focus rings in this subtree only while the keyboard is
    /// driving (`AtticKeyboardFocusTracker`).
    func atticKeyboardFocusTracking(_ tracker: AtticKeyboardFocusTracker) -> some View {
        modifier(AtticKeyboardFocusTracking(tracker: tracker))
    }
}

// MARK: - Focus requests (a page's own Tab order)

/// Hands keyboard focus to views that keep their own `FocusState` (a
/// subtask line, a strip button) when a page moves the keyboard itself (its
/// own Tab order, a closed pop-over giving the keyboard back), and records
/// which of them has it. Nothing observes it: a request is a message to the
/// one view it names, so asking never redraws a list (A10: the panel's key
/// loop is AppKit's, so SwiftUI no longer walks focusable views in layout,
/// and the pages order Tab themselves).
@MainActor
final class AtticFocusRequests {
    let requests = PassthroughSubject<AnyHashable, Never>()
    /// The target that has the keyboard, as its view last reported.
    private(set) var current: AnyHashable?

    func focus(_ target: AnyHashable) { requests.send(target) }

    func note(_ target: AnyHashable, focused: Bool) {
        if focused { current = target } else if current == target { current = nil }
    }
}

private struct AtticFocusRequestsKey: EnvironmentKey {
    static let defaultValue: AtticFocusRequests? = nil
}

extension EnvironmentValues {
    var atticFocusRequests: AtticFocusRequests? {
        get { self[AtticFocusRequestsKey.self] }
        set { self[AtticFocusRequestsKey.self] = newValue }
    }
}

private struct AtticFocusRequestTarget: ViewModifier {
    let target: AnyHashable
    var focused: FocusState<Bool>.Binding
    @Environment(\.atticFocusRequests) private var requests

    func body(content: Content) -> some View {
        if let requests {
            content
                .onReceive(requests.requests) { asked in
                    if asked == target, !focused.wrappedValue { focused.wrappedValue = true }
                }
                .onChange(of: focused.wrappedValue) { _, now in requests.note(target, focused: now) }
                .onDisappear { if focused.wrappedValue { requests.note(target, focused: false) } }
        } else {
            content
        }
    }
}

extension View {
    /// This view takes the keyboard when its page's `AtticFocusRequests`
    /// asks for `target`, and reports when it has it.
    func atticFocusRequestTarget(_ target: AnyHashable, focused: FocusState<Bool>.Binding) -> some View {
        modifier(AtticFocusRequestTarget(target: target, focused: focused))
    }
}

#if DEBUG
private struct AtticFocusCensusScopeKey: EnvironmentKey {
    static let defaultValue = "outside"
}

extension EnvironmentValues {
    /// DEBUG only: "list" inside a Tasks list cell, "task-row" inside any
    /// other `AtticTaskRow`, for the ring census
    /// (`AtticFocusReaderCensus.ringRuns`). Constant per subtree.
    var atticFocusCensusScope: String {
        get { self[AtticFocusCensusScopeKey.self] }
        set { self[AtticFocusCensusScopeKey.self] = newValue }
    }
}

/// DEBUG census of the views that hold a `@FocusState` only to draw
/// something for the keyboard (a ring, a row's •••). Every such holder is a
/// focus reader: SwiftUI re-checks it on each focus change in its graph,
/// hidden pages included, whether or not anything can show. Each holder
/// records itself, by instance, on every body run while `records` is on.
@MainActor
enum AtticFocusReaderCensus {
    struct Ring: Equatable {
        /// `atticKeyboardFocusVisible` as the holder last saw it.
        var keyboardFocusVisible: Bool
        /// Whether it drew its ring on that run.
        var shown: Bool
        var outline: String
    }

    static var records = false
    /// Ring focus-state holders, by instance.
    static var rings: [UUID: Ring] = [:]
    /// `NotesLibraryRow` instances whose own stored properties hold a focus state.
    static var notesRows: Set<UUID> = []
    /// The Notes rows' ••• buttons that hold their own focus state, with
    /// whether each had the keyboard on its last run.
    static var notesRowActions: [UUID: Bool] = [:]

    /// SPEED-FOCUSSTATE-FANOUT: Attic's own focus rings' work per focus
    /// move, keyed "scope|layer|site": scope "list" inside a Tasks list cell
    /// (`TasksReorderCell`), "task-row" inside an `AtticTaskRow` anywhere
    /// else (the Calendar agenda's), or "outside"; layer "live" (`AtticLiveOwnFocusRing`'s
    /// body), "kbd" (`AtticKeyboardOwnFocusRing`'s body) or "check" (its
    /// focus state's `update()`, run on each focus re-check of that holder
    /// even when its body is skipped); site the `atticOwnFocusRing` call's
    /// file and line. Counted while `records` is on; read as deltas.
    static var ringRuns: [String: Int] = [:]

    static func noteRingRun(_ layer: String, scope: String, site: String) {
        if records { ringRuns["\(scope)|\(layer)|\(site)", default: 0] += 1 }
    }

    static func noteRing(_ id: UUID, keyboardFocusVisible: Bool, shown: Bool, outline: AtticOwnFocusRing.Outline) {
        guard records else { return }
        rings[id] = Ring(keyboardFocusVisible: keyboardFocusVisible, shown: shown, outline: "\(outline)")
    }

    /// Records the row when its own stored properties hold a focus state.
    static func noteNotesRow(_ id: UUID, _ row: Any) {
        guard records else { return }
        if Mirror(reflecting: row).children.contains(where: { "\(type(of: $0.value))".hasPrefix("FocusState<") }) {
            notesRows.insert(id)
        }
    }

    static func noteNotesRowActions(_ id: UUID, focused: Bool) {
        if records { notesRowActions[id] = focused }
    }

    /// Focus checks per panel region, counted by `AtticFocusCheckProbe`
    /// (one sentinel reader per page). Counted whether or not `records` is on;
    /// read as deltas.
    static var focusChecks: [String: Int] = [:]

    static func noteFocusCheck(_ region: String) {
        focusChecks[region, default: 0] += 1
        // The input phase the check ran in (`AtticPanel.sendEvent`).
        phaseChecks["\(region)@\(phase)", default: 0] += 1
    }
    /// The panel's input phase, set by `AtticPanel.sendEvent` (DEBUG): "md"
    /// while a mouse-down is handled, "after-md" until the next input, and
    /// the same for mouse-up and key-down. A check in "after-md" ran in the
    /// pass after the mouse-down's handler.
    static var phase = "idle"
    static var phaseChecks: [String: Int] = [:]

    static func reset() {
        phaseChecks = [:]
        ringRuns = [:]
        rings = [:]
        notesRows = []
        notesRowActions = [:]
        focusChecks = [:]
    }
}

/// DEBUG sentinel focus reader for one panel region (SPEED-FOCUS-HIDDEN-PAGES).
/// It holds an unbound `@FocusState`, as SwiftUI's own focus readers in a
/// page do (a Button's `OnCommandModifier`, a ring's focus state): each
/// focus change in the window's graph re-checks it, which runs its dynamic
/// property's `update()` even when its body is skipped. So its count is the
/// number of times a focus change reached that region's part of the graph.
struct AtticFocusCheckProbe: View {
    let region: String
    private let check: Check

    init(region: String) {
        self.region = region
        check = Check(region: region)
    }

    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
    }

    struct Check: DynamicProperty {
        @FocusState private var focused: Bool
        let region: String
        func update() { MainActor.assumeIsolated { AtticFocusReaderCensus.noteFocusCheck(region) } }
    }
}
#endif

extension View {
    /// DEBUG only: a sentinel focus reader for the region (`AtticFocusCheckProbe`).
    @ViewBuilder
    func atticFocusCheckProbe(_ region: String) -> some View {
        #if DEBUG
        background(AtticFocusCheckProbe(region: region))
        #else
        self
        #endif
    }
}
