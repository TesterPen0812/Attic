import AppKit
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

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.observe(event.type, keyCode: event.type == .keyDown ? event.keyCode : nil)
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Exposed for tests: what one event does to the state.
    func observe(_ type: NSEvent.EventType, keyCode: UInt16?) {
        switch type {
        case .keyDown:
            if let keyCode, Self.navigationKeyCodes.contains(keyCode), !isKeyboardDriving { isKeyboardDriving = true }
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
