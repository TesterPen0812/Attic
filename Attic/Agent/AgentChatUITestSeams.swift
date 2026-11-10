#if DEBUG
import AppKit
import SwiftUI

/// UI-testing seams for the composer's menus, so a recorder can watch them
/// open with no pointer or key from outside the app: a control reports where
/// it is, a script line clicks it from inside (`tap:<id>`), and the menu that
/// opens can be answered (`menu-pick:<n>`) or dismissed (`menu-cancel`).
@MainActor
enum AgentChatUITestSeams {
    /// Each tagged control's frame in its window's content, top-left origin.
    static var frames: [String: (window: NSWindow?, frame: CGRect)] = [:]
    private static weak var openMenu: NSMenu?
    private static var observing = false

    static func watchMenus() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
                                               queue: .main) { note in
            MainActor.assumeIsolated { openMenu = note.object as? NSMenu }
        }
    }

    /// A click from inside the app, at the middle of the control.
    static func tap(_ id: String) {
        watchMenus()
        guard let entry = frames[id], let window = entry.window ?? NSApp.windows.first(where: { $0.isVisible }),
              let content = window.contentView else { return }
        let point = CGPoint(x: entry.frame.midX, y: content.bounds.height - entry.frame.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            window.sendEvent(event)
        }
    }

    static func pick(_ index: Int) {
        guard let menu = openMenu else { return }
        let enabled = menu.items.filter { !$0.isSeparatorItem }
        guard enabled.indices.contains(index), let at = menu.items.firstIndex(of: enabled[index]) else { return }
        menu.cancelTrackingWithoutAnimation()
        menu.performActionForItem(at: at)
    }

    static func cancel() { openMenu?.cancelTracking() }
}

extension View {
    /// Tags a control for `AgentChatUITestSeams.tap`.
    func agentChatUITestTarget(_ id: String) -> some View {
        background {
            AgentChatUITestProbe(id: id)
        }
    }
}

private struct AgentChatUITestProbe: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> NSView { Probe(id: id) }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.report() }

    final class Probe: NSView {
        let id: String
        init(id: String) { self.id = id; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func layout() { super.layout(); report() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func report() {
            guard let window, let content = window.contentView else { return }
            let inContent = content.convert(bounds, from: self)
            let flipped = content.isFlipped ? inContent
                : CGRect(x: inContent.minX, y: content.bounds.height - inContent.maxY, width: inContent.width, height: inContent.height)
            AgentChatUITestSeams.frames[id] = (window, flipped)
        }
    }
}
#else
import SwiftUI
extension View {
    func agentChatUITestTarget(_ id: String) -> some View { self }
}
#endif
