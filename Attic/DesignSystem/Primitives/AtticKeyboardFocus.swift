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
