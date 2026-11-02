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

    private weak var pressWindow: NSWindow?
    private var beforePress: NSRunningApplication?
    private var previousApp: NSRunningApplication?
    private weak var activationWindow: NSWindow?
    private var awaitingActivation = false
    private var borrowedActivation = false
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
        guard AtticPanel.takesFirstPress(event.type), window.isVisible else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let content = (window as? AtticPanel)?.visibleContentFrame
            ?? window.frame.insetBy(dx: PanelIslandLayout.windowMargin, dy: PanelIslandLayout.windowMargin)
        guard content.contains(point) else { pressWindow = nil; beforePress = nil; return }
        pressWindow = window
        beforePress = system.isActive() ? nil : system.frontmost()
    }

    func released(in window: NSWindow) {
        guard pressWindow === window else { return }
        pressWindow = nil
        defer { beforePress = nil }
        guard window.isVisible, !system.isActive() else { return }
        previousApp = beforePress
        borrowedActivation = true
        awaitingActivation = true
        // Activation raises both key and main windows. Temporarily make the
        // clicked panel both, so a document/Settings window cannot be raised
        // (or pull us to its Space). Island clicks belong to their parent.
        let surface = (window as? PanelIslandWindow)?.parent ?? window
        activationWindow = surface
        system.prepare(surface)
        system.activate()
    }

    func isActivationWindow(_ window: NSWindow) -> Bool { activationWindow === window }

    func hidden(_ window: NSWindow) {
        if pressWindow === window { pressWindow = nil; beforePress = nil }
        guard borrowedActivation else { return }
        if system.isActive() { returnFocusIfUnoccupied() }
        else if !awaitingActivation { clearBorrowedActivation() }
        // An asynchronous activation can still land after orderOut. Keep
        // its ownership until didBecomeActive, which returns it immediately.
    }

    func didBecomeActive() {
        guard awaitingActivation, system.isActive() else { return }
        awaitingActivation = false
        finishMainLease()
        returnFocusIfUnoccupied()
    }

    private func returnFocusIfUnoccupied() {
        guard borrowedActivation, system.isActive() else { return }
        let occupied = system.windows().contains { window in
            guard window.isVisible, !window.isMiniaturized,
                  !(window is PanelIslandWindow), !(window is AtticGlassMenuWindow) else { return false }
            return window is AtticPanel || window.styleMask.contains(.titled)
                || window.canBecomeKey || window.canBecomeMain
        }
        guard !occupied else { return }
        let previous = previousApp
        clearBorrowedActivation()
        guard let previous, !system.terminated(previous) else { system.deactivate(); return }
        // Cooperative activation requires the current app to yield before
        // the destination requests activation from it. Do not raise all windows.
        system.yield(previous)
        _ = system.restore(previous)
        // Acceptance is not completion. Relinquish our own activation even
        // if the destination is delayed or exits while accepting the request.
        system.deactivate()
    }

    private func finishMainLease() {
        // End eligibility only. AppKit owns main-window bookkeeping and
        // sends resignMain on hide/deactivation or another makeMain request.
        activationWindow = nil
    }

    private func clearBorrowedActivation() {
        borrowedActivation = false
        awaitingActivation = false
        previousApp = nil
        finishMainLease()
    }
}
