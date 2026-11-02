import AppKit
import XCTest
@testable import Attic

// One click always registers (Planning, "Owner notes on Attic Wave 2": a
// single click on the panel, wherever it lands, makes it active and does
// what it was aimed at; owner, 2 Nov: "Sometimes I have to click the panel
// twice for it to become active when it's inactive. This keeps coming
// back."). A first click is lost in one of two places, and these guards
// cover both for every page, the island and the states the panel can be in:
// - before Attic sees it: the window server sends it to the window behind;
// - inside Attic: the window spends it on activation, or a redraw rebuilds
//   the control under it (`O14FirstClickKeyLookTests`).

/// Where the window server sends a click on the panel or the island: to
/// them, at every point of the surface and the island's capsule, at rest,
/// through a reveal and with a card open. A window ordered out forgets its
/// explicit `ignoresMouseEvents`, and until the property is written again
/// the window server routes each click by the window's drawn alpha, so a
/// point the reveal has not drawn yet, a fading label or the island's
/// handed-off content passed the click to the app behind.
@MainActor
final class FirstClickWindowServerTests: XCTestCase {
    func testEveryPointOfThePanelAndTheIslandTakesTheClickThroughARevealOnEveryPage() throws {
        try requireKeyWindowTests()
        var misses: [String] = []
        for reduceMotion in [false, true] {
            try FirstClickHarness.withController(self, reduceMotion: reduceMotion) { harness in
                for section in [PanelSection.tasks, .notes, .calendar, .canvas] {
                    harness.state.selectSection(section)
                    harness.spin(1.2)
                    try harness.hide()
                    let other = FirstClickHarness.otherKeyWindow()
                    defer { other.orderOut(nil) }
                    harness.spin(0.2)
                    // A reveal from hidden, as the corner or the shortcut
                    // shows it: the panel isn't key.
                    try harness.reveal()
                    for (index, wait) in [0.02, 0.06, 0.12, 0.25, 1.0].enumerated() {
                        harness.spin(wait)
                        let name = "\(section), Reduce Motion \(reduceMotion ? "on" : "off"), sample \(index)"
                        misses += harness.windowServerMisses(name)
                    }
                }
            }
        }
        XCTAssertEqual(misses, [], "points the window server sends past the panel or the island")
    }

    func testWithTheCardOrTheCanvasMenuOpenEveryPointStillTakesTheClick() throws {
        try requireKeyWindowTests()
        var misses: [String] = []
        try FirstClickHarness.withController(self, reduceMotion: true) { harness in
            for (section, control) in [(PanelSection.tasks, "tasks-new-task"), (.notes, "notes-new-note"),
                                       (.calendar, "calendar-new-task"), (.canvas, "draw-title")] {
                harness.state.selectSection(section)
                harness.spin(1.2)
                try harness.hide()
                let other = FirstClickHarness.otherKeyWindow()
                defer { other.orderOut(nil) }
                try harness.reveal()
                harness.spin(0.8)
                try harness.press(control)
                other.makeKeyAndOrderFront(nil)
                harness.spin(0.4)
                misses += harness.windowServerMisses("\(section) with \(control) open")
                harness.host.cancelActiveInteraction(reason: .lostWindow)
            }
        }
        XCTAssertEqual(misses, [], "points the window server sends past the panel or the island")
    }

    /// A pulled-out page's own panel (an `AtticPanel` that never passes
    /// clicks through) takes every click on it, each time it shows.
    func testAFloatingPanelTakesEveryClickOnItsSurfaceEachTimeItShows() throws {
        try requireKeyWindowTests()
        let floating = AtticPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        floating.isReleasedWhenClosed = false
        floating.isOpaque = false
        floating.backgroundColor = .clear
        floating.level = PanelPullOutController.floatingLevel
        floating.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        defer { floating.close() }
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        floating.setVisibleContentFrame(CGRect(x: visible.midX - 100, y: visible.midY - 100, width: 200, height: 200),
                                        display: false)
        var misses: [String] = []
        for showing in 1...2 {
            floating.orderFrontRegardless()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let frame = floating.frame
            var missed: [String] = []
            for x in stride(from: frame.minX + 10, to: frame.maxX - 10, by: 20) {
                for y in stride(from: frame.minY + 10, to: frame.maxY - 10, by: 20) {
                    let number = NSWindow.windowNumber(at: CGPoint(x: x, y: y), belowWindowWithWindowNumber: 0)
                    guard FirstClickHarness.passesThrough(to: number, past: [floating.windowNumber]) else { continue }
                    let window = NSApp.windows.first { $0.windowNumber == number }
                    missed.append("(\(Int(x - frame.minX)), \(Int(y - frame.minY))) → \(window.map { String(describing: type(of: $0)) } ?? "another app's window")")
                }
            }
            if !missed.isEmpty { misses.append("showing \(showing): \(missed.count) points, \(missed.prefix(3))") }
            floating.orderOut(nil)
        }
        XCTAssertEqual(misses, [], "a clear floating panel passes clicks to the app behind")
    }
}

/// Wherever a press reaches the panel or the island before it is key, the
/// view under it takes it: the windows apply the first-press policy to
/// whatever view a press hits, including views in the panel's overlay layer
/// (cards, menus, Notes' bars) and in the island, which never pass through
/// the page's hosting view. A new view that refuses the first mouse is
/// covered by default; one that bypasses the windows turns these red.
@MainActor
final class FirstClickFirstMouseTests: XCTestCase {
    private final class RefusingInOverlay: NSView {
        override dynamic func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
        override func mouseDown(with event: NSEvent) {}
    }
    private final class RefusingInIsland: NSView {
        override dynamic func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
        override func mouseDown(with event: NSEvent) {}
    }
    private final class RefusingElsewhere: NSView {
        override dynamic func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    }

    private func event(_ type: NSEvent.EventType, _ window: NSWindow, at view: NSView) -> NSEvent {
        let location = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                  pressure: type == .leftMouseDown ? 1 : 0)!
    }

    func testAViewThatRefusesTheFirstMouseTakesAPressInThePanelsOverlayLayer() throws {
        let size = CGSize(width: 300, height: 300)
        let host = AtticPanelHostingView(rootView: FirstClickHarness.emptyPanelView(self), panelCornerRadius: 24,
                                         dockedCorner: .topRight, chromeInteractionState: PanelChromeInteractionState())
        let container = AtticPanelContentContainer(hostingView: host, visibleSize: size, perimeter: 0)
        let panel = AtticPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = container
        defer { panel.close() }
        let card = RefusingInOverlay(frame: CGRect(x: 100, y: 100, width: 80, height: 60))
        container.overlayLayer.addSubview(card)
        let down = event(.leftMouseDown, panel, at: card)
        XCTAssertTrue(container.hitTest(down.locationInWindow) === card, "the press lands on the card in the overlay layer")
        panel.sendEvent(down)
        panel.sendEvent(event(.leftMouseUp, panel, at: card))
        XCTAssertTrue(card.acceptsFirstMouse(for: down), "the panel's first press reaches a card's own views")
    }

    func testAViewThatRefusesTheFirstMouseTakesAPressOnTheIsland() throws {
        let island = PanelIslandWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 60, height: 200),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        island.isReleasedWhenClosed = false
        defer { island.close() }
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 60, height: 200))
        let item = RefusingInIsland(frame: CGRect(x: 10, y: 10, width: 40, height: 40))
        content.addSubview(item)
        island.contentView = content
        let down = event(.leftMouseDown, island, at: item)
        island.sendEvent(down)
        island.sendEvent(event(.leftMouseUp, island, at: item))
        XCTAssertTrue(item.acceptsFirstMouse(for: down), "the island's first press reaches whatever view it hits")
        XCTAssertTrue(AtticPanel.acceptsEveryFirstMouse(in: island))
    }

    func testOtherWindowsKeepTheirViewsOwnAnswer() {
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 100, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = RefusingElsewhere(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView = view
        let down = event(.leftMouseDown, window, at: view)
        window.sendEvent(down)
        XCTAssertFalse(view.acceptsFirstMouse(for: down))
        XCTAssertFalse(AtticPanel.acceptsEveryFirstMouse(in: window))
    }
}

/// Safe in the invisible host: observe activation requests without enabling
/// activation, making a window key, or posting input outside this process.
@MainActor
final class FirstClickActivationRequestTests: XCTestCase {
    private final class PressCounter: NSView {
        var presses = 0
        override dynamic func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
        override func mouseDown(with event: NSEvent) { presses += 1 }
    }

    func testOnlyTheFirstPressRequestsActivationAndStillReachesEverySurface() throws {
        guard TestPresentationPolicy.isInvisible else { throw XCTSkip("Invisible-host activation spy") }
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
        defer {
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        let method = try XCTUnwrap(class_getInstanceMethod(NSApplication.self, NSSelectorFromString("activate")))
        let original = method_getImplementation(method)
        var requests = 0
        let spy: @convention(block) (NSApplication) -> Void = { _ in
            MainActor.assumeIsolated { requests += 1 }
        }
        let implementation = imp_implementationWithBlock(spy)
        method_setImplementation(method, implementation)
        defer { method_setImplementation(method, original); imp_removeBlock(implementation) }

        for surface in ["docked", "island", "floating"] {
            let frame = CGRect(x: -4_000, y: -4_000, width: 200, height: 200)
            let window: NSPanel = surface == "island"
                ? PanelIslandWindow(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                : AtticPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let root = NSView(frame: CGRect(origin: .zero, size: frame.size))
            let target = PressCounter(frame: CGRect(x: 50, y: 50, width: 80, height: 80))
            root.addSubview(target)
            window.contentView = root
            requests = 0
            window.orderFrontRegardless()
            XCTAssertEqual(requests, 0, "\(surface): reveal cannot activate")
            func send(_ type: NSEvent.EventType, at point: CGPoint) throws {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                window.sendEvent(event)
            }
            let point = target.convert(CGPoint(x: 40, y: 40), to: nil)
            try send(.mouseMoved, at: point)
            XCTAssertEqual(requests, 0, "\(surface): hover cannot activate")
            try send(.leftMouseDown, at: point)
            XCTAssertEqual(requests, 1, "\(surface): activation belongs to the first press")
            XCTAssertEqual(target.presses, 1, "\(surface): activation cannot spend the press")
            try send(.leftMouseUp, at: point)
            XCTAssertEqual(requests, 1, "\(surface): release cannot request activation again")
            // Empty glass has no first-mouse-refusing subview to install on.
            try send(.leftMouseDown, at: CGPoint(x: 10, y: 10))
            try send(.leftMouseUp, at: CGPoint(x: 10, y: 10))
            XCTAssertEqual(requests, 2, "\(surface): empty glass activates too")
            XCTAssertFalse(NSApp.isActive, "the spy must never activate the host")
            XCTAssertFalse(window.isKeyWindow, "the host must never take the keyboard")
        }
    }
}

/// App activation is distinct from a non-activating panel becoming key.
/// These opt-in tests exercise the application's real activation state;
/// the HID/SCK check covers delivery and the resulting glass pixels.
@MainActor
final class FirstClickActivationTests: XCTestCase {
    private final class PressCounter: NSView {
        var presses = 0
        override dynamic func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
        override func mouseDown(with event: NSEvent) { presses += 1 }
    }

    func testOnePressActivatesTheAppAndActsOnDockedIslandAndFloatingSurfaces() throws {
        try requireKeyWindowTests()
        let previousPolicy = NSApp.activationPolicy()
        XCTAssertTrue(NSApp.setActivationPolicy(.accessory))
        defer {
            NSApp.deactivate()
            _ = NSApp.setActivationPolicy(previousPolicy)
        }
        try FirstClickHarness.withController(self, reduceMotion: true) { harness in
            let floating = AtticPanel(contentRect: CGRect(x: 200, y: 200, width: 200, height: 200),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            floating.isReleasedWhenClosed = false
            floating.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
            defer { floating.close() }
            let island = harness.controller.islandWindowsForTesting.island
            for (name, window) in [("docked", harness.panel as NSWindow), ("island", island), ("floating", floating)] {
                NSApp.deactivate()
                harness.spin(0.3)
                XCTAssertFalse(NSApp.isActive, "\(name): inactive starting state")
                window.orderFrontRegardless()
                harness.spin(0.2)
                XCTAssertFalse(NSApp.isActive, "\(name): showing must not activate the app")
                let root = try XCTUnwrap(window.contentView)
                let target = PressCounter(frame: CGRect(x: root.bounds.midX - 10, y: root.bounds.midY - 10,
                                                        width: 20, height: 20))
                root.addSubview(target)
                defer { target.removeFromSuperview() }
                let location = target.convert(CGPoint(x: 10, y: 10), to: nil)
                func event(_ type: NSEvent.EventType) throws -> NSEvent {
                    try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                }
                window.sendEvent(try event(.mouseMoved))
                harness.spin(0.1)
                XCTAssertFalse(NSApp.isActive, "\(name): pointing must not activate the app")
                window.sendEvent(try event(.leftMouseDown))
                window.sendEvent(try event(.leftMouseUp))
                harness.spin(0.3)
                XCTAssertEqual(target.presses, 1, "\(name): the first press still acts")
                XCTAssertTrue(NSApp.isActive, "\(name): one click must activate the app, not only its panel")
            }
        }
    }
}

/// A panel controller on screen (key-window runs), its island, and the
/// window server's view of where clicks go.
@MainActor
final class FirstClickHarness {
    let controller: AtticPanelController
    let state: PanelUIState
    let panel: AtticPanel
    let settings: AppSettings
    let host: AtticPanelHostingView
    private let screen: NSScreen

    private init(controller: AtticPanelController, state: PanelUIState, panel: AtticPanel, settings: AppSettings,
                 screen: NSScreen) throws {
        self.controller = controller
        self.state = state
        self.panel = panel
        self.settings = settings
        self.screen = screen
        host = try XCTUnwrap((panel.contentView as? AtticPanelContentContainer)?.hostingView)
    }

    static func emptyPanelView(_ test: XCTestCase) -> AtticPanelView {
        let container = try! PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let notes = NoteStore(container: container, attachmentFileStore: test.makeTestAttachmentFileStore())
        return AtticPanelView(store: TaskStore(container: container), noteStore: notes,
                              canvasSession: CanvasSession(store: CanvasStore(container: container)),
                              noteDraft: NoteDraftController(noteStore: notes),
                              chromeInteractionState: PanelChromeInteractionState(), uiState: PanelUIState(),
                              settings: AppSettings(defaults: UserDefaults(suiteName: "FirstClickEmpty.\(UUID().uuidString)")!),
                              tasksPageState: TasksPageState())
    }

    static func withController(_ test: XCTestCase, surface: PanelSurfaceStyle = .glass, reduceMotion: Bool,
                               _ body: (FirstClickHarness) throws -> Void) throws {
        AtticMotionPreference.systemReduceMotionOverride = reduceMotion
        AtticTransparencySeam.systemOverride = false
        defer {
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        let suite = "FirstClick.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedDemo(in: container)
        let store = TaskStore(container: container)
        let notes = NoteStore(container: container, attachmentFileStore: test.makeTestAttachmentFileStore())
        let state = PanelUIState()
        let settings = AppSettings(defaults: defaults)
        settings.panelSurfaceStyle = surface
        let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let controller = AtticPanelController(
            store: store, noteStore: notes, canvasSession: CanvasSession(store: CanvasStore(container: container)),
            noteDraft: NoteDraftController(noteStore: notes), settings: settings, uiState: state
        )
        let panel = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? AtticPanel }
            .first { !existing.contains(ObjectIdentifier($0)) })
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let screen = try XCTUnwrap(controller.currentScreen ?? NSScreen.main)
        let harness = try FirstClickHarness(controller: controller, state: state, panel: panel, settings: settings, screen: screen)
        try harness.reveal()
        harness.spin(1.0)
        defer {
            try? harness.hide()
            panel.orderOut(nil)
        }
        try body(harness)
    }

    static func otherKeyWindow() -> NSWindow {
        final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }
        let window = KeyPanel(contentRect: CGRect(x: -6_000, y: -6_000, width: 80, height: 80),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Whether the window server's choice at a point, `hit`, lies behind
    /// the windows meant to take the click there (`expected`): the click
    /// passed through them. Another app's window in front of them (a
    /// notification, a screen tool on the test Mac) is not a pass-through.
    static func passesThrough(to hit: Int, past expected: Set<Int>) -> Bool {
        guard !expected.contains(hit) else { return false }
        let order = NSWindow.windowNumbers(options: [.allApplications])?.map(\.intValue) ?? []
        guard let hitIndex = order.firstIndex(of: hit),
              let ownIndex = order.firstIndex(where: { expected.contains($0) }) else { return true }
        return hitIndex > ownIndex
    }

    func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    func reveal() throws {
        XCTAssertTrue(controller.show(on: screen, corner: .topRight))
        // The pointer is where the click goes: over the surface.
        let frame = panel.visibleContentFrame
        controller.updateMousePassthrough(at: CGPoint(x: frame.midX, y: frame.midY))
    }

    func hide() throws {
        var hidden = false
        _ = controller.requestHide { hidden = $0 == .hidden }
        let deadline = Date().addingTimeInterval(3)
        while !hidden, Date() < deadline { spin(0.02) }
        XCTAssertTrue(hidden, "the panel hid")
    }

    func press(_ identifier: String) throws {
        func elements(_ root: AnyObject) -> [AnyObject] {
            [root] + ((root.accessibilityChildren?() ?? nil) ?? []).flatMap { elements($0 as AnyObject) }
        }
        let element = try XCTUnwrap(elements(host).first { ($0.accessibilityIdentifier?() ?? "") == identifier },
                                    "\(identifier) is on the panel")
        XCTAssertTrue(element.accessibilityPerformPress?() ?? false, "\(identifier) presses")
        spin(0.8)
    }

    /// The points of the surface (inside its superellipse, a 10 pt grid)
    /// and the island's items whose click the window server sends to a
    /// window other than the panel, the island or an open menu card.
    func windowServerMisses(_ name: String) -> [String] {
        let windows = controller.islandWindowsForTesting
        let frame = panel.visibleContentFrame
        var points: [CGPoint] = []
        for x in stride(from: frame.minX + 6, to: frame.maxX - 6, by: 10) {
            for y in stride(from: frame.minY + 6, to: frame.maxY - 6, by: 10)
            where Squircle.contains(CGPoint(x: x - frame.minX, y: y - frame.minY), in: CGRect(origin: .zero, size: frame.size),
                                    cornerRadius: settings.panelCornerSize, exponent: AtticStyle.panelSquircleExponent) {
                points.append(CGPoint(x: x, y: y))
            }
        }
        let islandPoints = PanelIslandLayout.pages.indices.map { index -> CGPoint in
            let item = PanelIslandLayout.itemFrame(index, in: windows.islandFrame)
            return CGPoint(x: item.midX, y: item.midY)
        }
        let ours = Set([panel.windowNumber, windows.island.windowNumber]
            + NSApp.windows.filter { $0 is AtticGlassMenuWindow && $0.isVisible }.map(\.windowNumber))
        let missed = (points + islandPoints).filter {
            Self.passesThrough(to: NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: 0), past: ours)
        }
        guard let first = missed.first else { return [] }
        return ["\(name): \(missed.count) of \(points.count + islandPoints.count) points, first at \(first)"]
    }
}
