import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The Settings window as AppKit really lays it out: its traffic lights
/// sit on the page title's line, keep the system's spacing, still take
/// clicks there, and stay put through resizes.
@MainActor
final class SettingsWindowHostedTests: XCTestCase {
    private var window: SettingsWindow?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window?.close()
        window = nil
        try await super.tearDown()
    }

    private func spin(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testR24ScrollContentFillsWideShortAndNarrowTallHost() throws {
        let suite = "SettingsR24.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let settings = AppSettings(defaults: defaults)
        let host = NSHostingView(rootView: SettingsView(
            settings: settings,
            loginItemService: LoginItemService(readStatus: { .notRegistered }, changeRegistration: { _ in }),
            agentServer: AgentServer(port: 0, bearerToken: "test", handler: MCPRequestHandler(tools: AgentTaskTools(store: store))),
            globalHotKey: GlobalHotKey(combination: .newTask), library: nil))
        let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 860, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // SwiftUI creates the native scroll hierarchy when the hosting
        // window is presented. Keep the test window off-screen, as in UX2,
        // but make it visible to AppKit before looking for NSScrollView.
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }

        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
        }
        for size in [CGSize(width: 860, height: 420), CGSize(width: 580, height: 650)] {
            window.setContentSize(size)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            spin(0.2)
            host.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(scrollViews(in: host).first { abs($0.frame.width - size.width) < 2 },
                                       "The undersized Settings host must offer scrolling")
            let content = try XCTUnwrap(scroll.documentView)
            XCTAssertGreaterThanOrEqual(content.frame.width, max(640, size.width) - 2,
                                        "Sidebar background and page card must fill the wide host")
            XCTAssertGreaterThanOrEqual(content.frame.height, max(460, size.height) - 2,
                                        "Content must fill the tall host without leaving a bare strip")
        }
    }

    func testR24ScrollThresholdDoesNotRemountPageLocalState() {
        var appearances = 0
        let host = NSHostingView(rootView: GeometryReader { available in
            SettingsAdaptiveScroll(size: available.size) {
                Text("Settings page state")
                    .onAppear { appearances += 1 }
            }
        })
        let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 860, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for size in [CGSize(width: 860, height: 650), CGSize(width: 860, height: 420),
                     CGSize(width: 580, height: 650), CGSize(width: 860, height: 650)] {
            window.setContentSize(size)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            spin(0.05)
            XCTAssertEqual(appearances, 1, "Changing the scroll threshold must keep the current Settings page mounted")
        }
    }

    func testUX2DefaultWindowKeepsSettingsContentWithinViewport() throws {
        let suite = "SettingsUX2.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let settings = AppSettings(defaults: defaults)
        let host = NSHostingView(rootView: SettingsView(
            settings: settings,
            loginItemService: LoginItemService(readStatus: { .notRegistered }, changeRegistration: { _ in }),
            agentServer: AgentServer(port: 0, bearerToken: "test", handler: MCPRequestHandler(tools: AgentTaskTools(store: store))),
            globalHotKey: GlobalHotKey(combination: .newTask), library: nil))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -6_000, y: -6_000),
                                                  size: SettingsWindowLayout.preferredContentSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        spin(0.3)

        func elements(_ root: AnyObject) -> [AnyObject] {
            [root] + ((root.accessibilityChildren?() ?? nil) ?? []).flatMap { elements($0 as AnyObject) }
        }
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
        }
        func element(_ id: String) -> AnyObject? {
            host.layoutSubtreeIfNeeded()
            return elements(host).first { $0.accessibilityIdentifier?() == id }
        }
        func frame(_ id: String) throws -> CGRect {
            let item = try XCTUnwrap(element(id), "\(id) should appear in the page")
            return try XCTUnwrap((item as? NSAccessibilityElementProtocol)?.accessibilityFrame())
        }
        func assertContentFits(_ identifiers: [String], at size: CGSize) throws {
            host.layoutSubtreeIfNeeded()
            spin(0.1)
            host.layoutSubtreeIfNeeded()
            for id in identifiers {
                let bounds = try frame(id)
                XCTAssertGreaterThan(bounds.width, 0, "\(id) is laid out")
                XCTAssertGreaterThanOrEqual(bounds.minX, window.frame.minX + AtticLayout.settingsSidebarWidth - 2,
                                            "\(id) stays clear of the sidebar at \(size): \(bounds)")
                XCTAssertLessThanOrEqual(bounds.maxX, window.frame.maxX - AtticSpacing.settingsCardInset + 2,
                                         "\(id) fits inside the page at \(size): \(bounds)")
            }
        }

        for size in [SettingsWindowLayout.preferredContentSize, SettingsWindowLayout.minimumContentSize] {
            window.setContentSize(size)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(scrollViews(in: host).first { abs($0.frame.width - size.width) < 2 })
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertLessThanOrEqual(document.frame.width, scroll.contentView.bounds.width + 2,
                                     "No horizontal Settings content beyond \(size)")
            try assertContentFits(["setting-launch-at-login", "setting-animations", "setting-hide-animation",
                                   "setting-quick-capture-shortcut"], at: size)
            let sidebarBefore = try frame("settings-nav-general")
            let appearance = try XCTUnwrap(element("settings-nav-appearance"))
            XCTAssertTrue(appearance.accessibilityPerformPress?() ?? false)
            try assertContentFits(["setting-appearance-preview", "setting-appearance-system",
                                   "setting-appearance-light", "setting-appearance-dark",
                                   "setting-panel-surface", "setting-panel-theme"], at: size)
            let dark = try XCTUnwrap(element("setting-appearance-dark"))
            XCTAssertTrue(dark.accessibilityPerformPress?() ?? false)
            try assertContentFits(["setting-appearance-system", "setting-appearance-light",
                                   "setting-appearance-dark", "setting-panel-theme"], at: size)
            XCTAssertEqual(try frame("settings-nav-general").minX, sidebarBefore.minX, accuracy: 0.5,
                           "Choosing Dark must not scroll the sidebar horizontally")
            let general = try XCTUnwrap(element("settings-nav-general"))
            XCTAssertTrue(general.accessibilityPerformPress?() ?? false)
        }
    }

    private func makeWindow() -> SettingsWindow {
        let window = SettingsWindow(contentViewController: NSHostingController(rootView: Color.clear))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(SettingsWindowLayout.preferredContentSize)
        window.orderFront(nil)
        self.window = window
        spin()
        return window
    }

    /// Each button's centre, measured from the window's top-left, in points.
    private func centres(_ window: NSWindow) throws -> [CGPoint] {
        try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { type in
            let button = try XCTUnwrap(window.standardWindowButton(type))
            let rect = button.convert(button.bounds, to: nil)
            return CGPoint(x: rect.midX, y: window.frame.height - rect.midY)
        }
    }

    private func assertOnTitleLine(_ window: NSWindow, spacing expected: CGFloat? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> CGFloat {
        let points = try centres(window)
        for point in points {
            XCTAssertEqual(point.y, SettingsChromeLayout.titleLineCenterY, accuracy: 0.5, "on the title line", file: file, line: line)
        }
        let spacing = points[1].x - points[0].x
        XCTAssertEqual(points[2].x - points[1].x, spacing, accuracy: 0.5, "even spacing", file: file, line: line)
        if let expected { XCTAssertEqual(spacing, expected, accuracy: 0.5, "the system's spacing is kept", file: file, line: line) }
        // The buttons still take clicks where they are drawn.
        let frameView = try XCTUnwrap(window.contentView?.superview)
        for (index, point) in points.enumerated() {
            let location = NSPoint(x: point.x, y: window.frame.height - point.y)
            let hit = frameView.hitTest(frameView.convert(location, from: nil))
            let button = window.standardWindowButton([.closeButton, .miniaturizeButton, .zoomButton][index])
            XCTAssertTrue(hit === button || hit?.isDescendant(of: button!) == true, "button \(index) takes clicks", file: file, line: line)
        }
        return spacing
    }

    func testTrafficLightsSitOnTheTitleLineAndStayThroughResizes() throws {
        // AppKit's own spacing, from a plain window with the same style.
        let plain = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        plain.isReleasedWhenClosed = false
        plain.orderFront(nil)
        spin()
        let plainCentres = try centres(plain)
        let systemSpacing = plainCentres[1].x - plainCentres[0].x
        plain.orderOut(nil)
        plain.close()

        let window = makeWindow()
        XCTAssertNotEqual(plainCentres[0].y, SettingsChromeLayout.titleLineCenterY, "AppKit alone would put them elsewhere")
        _ = try assertOnTitleLine(window, spacing: systemSpacing)

        for size in [NSSize(width: 1_000, height: 780), SettingsWindowLayout.minimumContentSize, NSSize(width: 900, height: 700)] {
            window.setContentSize(size)
            window.contentView?.needsLayout = true
            window.layoutIfNeeded()
            spin(0.05)
            _ = try assertOnTitleLine(window, spacing: systemSpacing)
        }

        // Key and not key re-lay the title bar out too.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        window.placeTrafficLights()
        _ = try assertOnTitleLine(window, spacing: systemSpacing)
    }
}
