import AppKit

/// The OS boundary for a panel's borrowed activation. Tests replace requests,
/// never the invisible host's activation/key-window protections.
@MainActor
final class PanelActivation {
    static var shared = PanelActivation()

    struct System {
        var isActive: () -> Bool
        var frontmost: () -> NSRunningApplication?
        var windows: () -> [NSWindow]
        var prepare: (NSWindow) -> Void
        var activate: () -> Void
        var yield: (NSRunningApplication) -> Void
        var restore: (NSRunningApplication) -> Bool
        var terminated: (NSRunningApplication) -> Bool
        var deactivate: () -> Void

        static var live: System {
            System(isActive: { NSApp.isActive }, frontmost: {
                let app = NSWorkspace.shared.frontmostApplication
                return app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : app
            }, windows: { NSApp.windows }, prepare: { window in
                window.makeKey()
                window.makeMain()
            }, activate: { NSApp.activate() }, yield: { NSApp.yieldActivation(to: $0) },
            restore: { $0.activate(from: .current, options: []) },
            terminated: { $0.isTerminated }, deactivate: { NSApp.deactivate() })
        }
    }

    private let system: System
    private var observers: [NSObjectProtocol] = []

    init(system: System = .live) {
        self.system = system
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didBecomeActive() }
            })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func pressed(_ event: NSEvent, in window: NSWindow) {
        if AtticPanel.takesFirstPress(event.type), window.isVisible, !system.isActive() { system.activate() }
    }
    func released(in window: NSWindow) {}
    func hidden(_ window: NSWindow) {}
    func didBecomeActive() {}
    func isActivationWindow(_ window: NSWindow) -> Bool { false }
}
