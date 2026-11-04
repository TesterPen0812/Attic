import AppKit
import ObjectiveC
import XCTest
@testable import Attic

@MainActor
final class PanelActivationTests: XCTestCase {
    private var previous: PanelActivation!
    private var fixture: Fixture!

    private final class Fixture {
        var active = false
        var quit = false
        var allowRestore = true
        var windows: [NSWindow] = []
        var events: [String] = []
        var prepared: NSWindow?
        // A stable process handle stands for the previous app. No request is
        // sent to it: every OS operation below records intent only.
        let app = NSRunningApplication.current
        var system: PanelActivation.System {
            .init(isActive: { self.active }, frontmost: { self.app }, windows: { self.windows },
                prepare: { self.prepared = $0; self.events.append("prepare") },
                activate: { self.events.append("activate"); return true },
                yield: { app in XCTAssertTrue(app === self.app); self.events.append("yield") },
                restore: { app in XCTAssertTrue(app === self.app); self.events.append("restore"); return self.allowRestore },
                terminated: { _ in self.quit }, deactivate: { self.active = false; self.events.append("deactivate") })
        }
    }

    override func setUpWithError() throws {
        guard TestPresentationPolicy.isInvisible else { throw XCTSkip("Invisible host only") }
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
        previous = PanelActivation.shared
        fixture = Fixture()
        PanelActivation.shared = PanelActivation(system: fixture.system)
    }
    override func tearDown() {
        fixture.windows.forEach { $0.close() }
        PanelActivation.shared = previous
        fixture = nil
        previous = nil
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
    }
    func testTearDownAfterSkippedSetupDoesNotReplaceSharedActivation() {
        let savedFixture = fixture, savedPrevious = previous
        let installed = PanelActivation.shared
        fixture = nil
        previous = nil
        defer {
            fixture = savedFixture
            previous = savedPrevious
        }
        // XCTest calls tearDown even when setUpWithError throws XCTSkip.
        tearDown()
        XCTAssertTrue(PanelActivation.shared === installed)
    }

    private func panel() -> AtticPanel {
        let window = AtticPanel(contentRect: CGRect(x: -4000, y: -4000, width: 200, height: 200),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        fixture.windows.append(window)
        window.orderFrontRegardless()
        return window
    }
    private func press(_ window: NSWindow, _ type: NSEvent.EventType) throws {
        window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: 70, y: 70),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
    }
    private func click(_ window: NSWindow) throws {
        try press(window, .leftMouseDown)
        try press(window, .leftMouseUp)
    }
    private func active() {
        fixture.active = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    }

    func testLiveActivityUsesRunningApplicationOwnershipInsteadOfAppKitFocus() throws {
        // On the Air a nonactivating panel made NSApp.isActive true while
        // Finder remained WindowServer's active app. Keep the invisible host's
        // NSApplication guard intact and vary only the read-only OS boundary.
        let method = try XCTUnwrap(class_getInstanceMethod(NSRunningApplication.self,
            NSSelectorFromString("isActive")))
        let original = method_getImplementation(method)
        typealias Read = @convention(c) (AnyObject, Selector) -> Bool
        let read = unsafeBitCast(original, to: Read.self)
        var ownsActivation = false
        let spy: @convention(block) (NSRunningApplication) -> Bool = { app in
            if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return ownsActivation }
            return read(app, NSSelectorFromString("isActive"))
        }
        let implementation = imp_implementationWithBlock(spy)
        method_setImplementation(method, implementation)
        defer { method_setImplementation(method, original); imp_removeBlock(implementation) }
        for active in [false, true, false] {
            ownsActivation = active
            XCTAssertEqual(PanelActivation.System.live.isActive(), active,
                           "AppKit's key-focus bookkeeping is not WindowServer activation")
        }
    }

    func testReleasePreparesOnlyTheClickedSurfaceBeforeRequestingActivation() throws {
        let clicked = panel(), other = panel()
        try press(clicked, .leftMouseDown)
        XCTAssertTrue(fixture.events.isEmpty, "active appearance waits for release")
        try press(clicked, .leftMouseUp)
        XCTAssertEqual(fixture.events, ["prepare", "activate"])
        XCTAssertTrue(fixture.prepared === clicked)
        XCTAssertTrue(PanelActivation.shared.isActivationWindow(clicked), "clicked surface holds the main-window lease")
        XCTAssertFalse(PanelActivation.shared.isActivationWindow(other))
        active()
        XCTAssertFalse(PanelActivation.shared.isActivationWindow(clicked), "the lease ends when activation arrives")
    }

    func testOrderOutYieldsThenRestoresFocusAndASecondHideDoesNothing() throws {
        let window = panel()
        try click(window); active(); fixture.events = []
        window.orderOut(nil)
        XCTAssertEqual(fixture.events, ["yield", "restore", "deactivate"], "cooperative activation: permission before request")
        window.orderOut(nil)
        XCTAssertEqual(fixture.events, ["yield", "restore", "deactivate"], "focus is returned once")
    }

    func testNativeSpaceReadmissionDoesNotReturnBorrowedActivation() throws {
        let window = panel()
        try click(window); active(); fixture.events = []
        // Replay WindowServer's off-Space state without taking the Pro's screen.
        XCTAssertTrue(PanelSpacePresentation.reassert(window, onActiveSpace: false))
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(fixture.events, [], "native re-admission is not a logical hide and must not restore another app")
        fixture.events = []
        window.orderOut(nil)
        XCTAssertEqual(fixture.events, ["yield", "restore", "deactivate"], "the later real hide keeps its focus handoff")
    }

    func testVisibleSettingsOrTaskNotePreventsFocusReturn() throws {
        for title in ["Settings", "Task Note"] {
            let window = panel()
            let other = NSWindow(contentRect: CGRect(x: -4500, y: -4500, width: 100, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false; other.title = title
            fixture.windows.append(other); other.orderFrontRegardless()
            fixture.active = false
            try click(window); active(); fixture.events = []
            window.orderOut(nil)
            XCTAssertTrue(fixture.events.isEmpty, title)
            other.orderOut(nil)
        }
    }

    func testAlreadyInactiveHideDoesNotTakeFocusFromTheUsersNewApp() throws {
        let window = panel()
        try click(window); active(); fixture.active = false; fixture.events = []
        window.orderOut(nil)
        XCTAssertTrue(fixture.events.isEmpty)
    }

    func testQuitPreviousAppAndRefusedRestorationDeactivateCleanly() throws {
        for quit in [true, false] {
            let window = panel(); fixture.active = false; fixture.quit = quit; fixture.allowRestore = false
            try click(window); active(); fixture.events = []
            window.orderOut(nil)
            XCTAssertEqual(fixture.events, quit ? ["deactivate"] : ["yield", "restore", "deactivate"])
        }
    }

    func testActivationArrivingAfterOrderOutIsReturnedWithoutRaisingAWindow() throws {
        let window = panel()
        try click(window)
        fixture.events = []
        window.orderOut(nil)
        XCTAssertTrue(fixture.events.isEmpty, "request is still pending")
        active()
        XCTAssertEqual(fixture.events, ["yield", "restore", "deactivate"])
        XCTAssertFalse(window.isVisible)
    }

    func testWorkspaceActivationCompletesAfterEarlyAppKitNotificationAndHide() throws {
        let window = panel()
        try click(window)
        // AppKit acquired nonactivating key focus before process activation.
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertTrue(PanelActivation.shared.isActivationWindow(window))
        window.orderOut(nil)
        fixture.events = []
        fixture.active = true
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared, userInfo: [NSWorkspace.applicationUserInfoKey: fixture.app])
        XCTAssertFalse(PanelActivation.shared.isActivationWindow(window))
        XCTAssertEqual(fixture.events, ["yield", "restore", "deactivate"])
        XCTAssertFalse(window.isVisible)
    }

    func testAcceptedRestorationRelinquishesActivationBeforeTheOtherAppResponds() throws {
        let window = panel()
        try click(window); active(); fixture.events = []
        // A true return from activate(from:) means accepted, not completed.
        // The fake destination deliberately never becomes active.
        window.orderOut(nil)
        XCTAssertFalse(fixture.active, "a hidden Attic must not retain typing while a permitted handoff is pending")
        XCTAssertEqual(fixture.events, ["yield", "restore", "deactivate"])
    }

    func testAnAlreadyActiveAppDoesNotBorrowFocus() throws {
        let window = panel(); fixture.active = true
        try click(window); window.orderOut(nil)
        XCTAssertTrue(fixture.events.isEmpty)
    }
}
