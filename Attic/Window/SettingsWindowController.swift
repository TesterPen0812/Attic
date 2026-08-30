import AppKit
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
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private static let frameAutosaveName = "AtticSettingsWindow"
    private var hasPositionedWindow = false

    init(
        settings: AppSettings,
        loginItemService: LoginItemService,
        agentServer: AgentServer,
        store: TaskStore,
        agentAccessToken: String
    ) {
        // The coordinator still owns TaskStore. Sync controls are intentionally
        // absent while Attic is macOS-first and local-only.
        _ = store

        let rootView = SettingsView(
            settings: settings,
            loginItemService: loginItemService,
            agentServer: agentServer,
            agentAccessToken: agentAccessToken
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)

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
        window.collectionBehavior = [.moveToActiveSpace]
        window.isMovableByWindowBackground = false

        let restoredFrame = window.setFrameUsingName(Self.frameAutosaveName)
        _ = window.setFrameAutosaveName(Self.frameAutosaveName)

        super.init(window: window)
        hasPositionedWindow = restoredFrame
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }

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
    }
}
