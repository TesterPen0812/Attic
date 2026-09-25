import AppKit
import SwiftData
import SwiftUI

enum SettingsWindowLayout {
    static let preferredContentSize = NSSize(width: 860, height: 650)
    static let minimumContentSize = NSSize(width: 640, height: 460)
    static let maximumContentSize = NSSize(width: 1_100, height: 900)
    static let screenMargin: CGFloat = 24

    static func fittedContentSize(to visibleFrame: NSRect) -> NSSize {
        NSSize(
            width: max(
                minimumContentSize.width,
                min(preferredContentSize.width, visibleFrame.width - (screenMargin * 2))
            ),
            height: max(
                minimumContentSize.height,
                min(preferredContentSize.height, visibleFrame.height - (screenMargin * 2))
            )
        )
    }

    /// The traffic lights' frame origins inside a title bar container
    /// `containerHeight` tall, so their centres sit on the page title's line
    /// (`SettingsChromeLayout.titleLineCenterY`) and keep the system's
    /// spacing (`spacing`, measured from the live buttons).
    static func trafficLightOrigins(buttonSize: NSSize, spacing: CGFloat) -> [NSPoint] {
        let y = SettingsChromeLayout.titleLineCenterY - buttonSize.height / 2
        return (0..<3).map { index in
            NSPoint(x: SettingsChromeLayout.trafficLightsLeading + CGFloat(index) * spacing, y: y)
        }
    }

    /// The title bar container's height: twice the title line's depth, so
    /// the buttons centre in it.
    static var trafficLightContainerHeight: CGFloat {
        SettingsChromeLayout.titleLineCenterY * 2
    }
}

/// The Settings window keeps its traffic lights on the page title's line
/// (spec § Settings: "the page title shares the traffic-light line").
/// AppKit lays the title bar out again on every resize, so the buttons are
/// placed after each layout pass. The window has no title bar of its own
/// otherwise: the content runs to the top, and the sidebar's top strip and
/// the page header move the window.
final class SettingsWindow: NSWindow {
    private var buttonSpacing: CGFloat?

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        placeTrafficLights()
    }

    func placeTrafficLights() {
        guard !styleMask.contains(.fullScreen),
              let close = standardWindowButton(.closeButton),
              let miniaturize = standardWindowButton(.miniaturizeButton),
              let zoom = standardWindowButton(.zoomButton),
              let container = close.superview?.superview else { return }
        // The system's own spacing, read once from its first layout.
        let spacing = buttonSpacing ?? max(miniaturize.frame.minX - close.frame.minX, close.frame.width)
        buttonSpacing = spacing
        let height = SettingsWindowLayout.trafficLightContainerHeight
        var frame = container.frame
        if frame.height != height || frame.maxY != self.frame.height {
            frame.size.height = height
            frame.origin.y = self.frame.height - height
            container.frame = frame
        }
        // The buttons live in the title bar view, which fills the container.
        let origins = SettingsWindowLayout.trafficLightOrigins(buttonSize: close.frame.size, spacing: spacing)
        let titlebarHeight = close.superview?.frame.height ?? height
        for (button, origin) in zip([close, miniaturize, zoom], origins) {
            // AppKit's title bar is flipped the other way: y grows upward.
            let target = NSPoint(x: origin.x, y: titlebarHeight - origin.y - button.frame.height)
            if button.frame.origin != target { button.setFrameOrigin(target) }
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private static let frameAutosaveName = "AtticSettingsWindow"
    private var hasPositionedWindow = false
    private var observers: [NSObjectProtocol] = []

    init(
        settings: AppSettings,
        loginItemService: LoginItemService,
        agentServer: AgentServer,
        globalHotKey: GlobalHotKey,
        library: AtticLibrary?
    ) {
        // Sync controls are intentionally absent while Attic is macOS-first
        // and local-only.
        let rootView = SettingsView(
            settings: settings,
            loginItemService: loginItemService,
            agentServer: agentServer,
            globalHotKey: globalHotKey,
            library: library
        )
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.safeAreaRegions = []
        let window = SettingsWindow(contentViewController: hostingController)

        window.title = "Attic Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.setContentSize(SettingsWindowLayout.preferredContentSize)
        window.contentMinSize = SettingsWindowLayout.minimumContentSize
        window.contentMaxSize = SettingsWindowLayout.maximumContentSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        window.isMovableByWindowBackground = false

        let restoredFrame = window.setFrameUsingName(Self.frameAutosaveName)
        _ = window.setFrameAutosaveName(Self.frameAutosaveName)

        super.init(window: window)
        hasPositionedWindow = restoredFrame

        // Resizing, changing screens or going in and out of key re-runs the
        // title bar's layout; put the traffic lights back each time.
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeBackingPropertiesNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { window?.placeTrafficLights() }
            })
        }

        Self.seedRecentlyDeletedForUITesting(library)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window = window as? SettingsWindow else { return }

        if let screen = window.screen ?? NSScreen.main {
            if hasPositionedWindow {
                let constrainedFrame = window.constrainFrameRect(window.frame, to: screen)
                window.setFrame(constrainedFrame, display: false)
            } else {
                window.setContentSize(
                    SettingsWindowLayout.fittedContentSize(to: screen.visibleFrame)
                )
                window.center()
                hasPositionedWindow = true
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.placeTrafficLights()
    }

    /// UI-test seam: with `ATTIC_UI_TEST_SEED_RECENTLY_DELETED=1` a UI-test
    /// launch (whose store lives in memory) starts with a deleted task and
    /// a deleted note, so the Recently Deleted page can be driven without
    /// depending on the panel. Never runs against a persistent store.
    private static func seedRecentlyDeletedForUITesting(_ library: AtticLibrary?) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ATTIC_UI_TESTING"] == "1",
              environment["ATTIC_UI_TEST_SEED_RECENTLY_DELETED"] == "1",
              let library,
              library.tasks.container.configurations.allSatisfy(\.isStoredInMemoryOnly) else { return }
        if let task = library.tasks.create(title: "Plan the launch") {
            _ = library.tasks.create(title: "Write the announcement", parentID: task.id)
            library.delete(AtticItemRef(.task, task.id))
        }
        if let notes = library.notes, let note = notes.create(title: "Meeting notes", body: "Agenda") {
            library.delete(AtticItemRef(.note, note.id))
        }
    }
}
