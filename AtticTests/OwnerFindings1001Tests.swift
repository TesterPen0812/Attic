import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The owner's hands-on findings on Phase 1 (2026-10-01, on `c2b41d0`).
@MainActor
final class OwnerFindings1001Tests: XCTestCase {
    // MARK: - 1. Hover is a soft tint only

    /// The pointer's hover tints the row and nothing moves: the actions
    /// button (which pushed the date aside) is the keyboard's only.
    func testHoverIsATintOnlyAndMovesNothing() {
        XCTAssertFalse(AtticTaskRow.showsActionsButton(forced: nil, keyboardFocused: false), "at rest")
        XCTAssertFalse(AtticTaskRow.showsActionsButton(forced: .hover, keyboardFocused: false), "hovered: a tint only")
        XCTAssertTrue(AtticTaskRow.showsActionsButton(forced: nil, keyboardFocused: true), "the keyboard's row")
        XCTAssertTrue(AtticTaskRow.showsActionsButton(forced: .focused, keyboardFocused: false), "the gallery's focused state")
    }

    // MARK: - 2. One click activates the panel and acts

    private final class Recorder: NSView {
        var presses = 0
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
        override func mouseDown(with event: NSEvent) { presses += 1 }
        override func rightMouseDown(with event: NSEvent) { presses += 1 }
    }

    /// A press on a panel that is not key reaches the control under it at
    /// once, even one that does not accept the first mouse (SwiftUI's own
    /// views in a list), and the panel becomes key without activating Attic.
    func testOneClickOnAnInactivePanelBothActivatesItAndActs() throws {
        let other = NSWindow(contentRect: CGRect(x: -6_000, y: -6_000, width: 200, height: 200), styleMask: [.titled],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        let panel = AtticPanel(contentRect: CGRect(x: -5_000, y: -5_000, width: 300, height: 300),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let recorder = Recorder(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        panel.contentView = recorder
        panel.orderFront(nil)
        other.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(panel.isKeyWindow, "the panel starts inactive")

        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown] {
            other.makeKeyAndOrderFront(nil)
            let before = recorder.presses
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: 150, y: 150), modifierFlags: [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                                         clickCount: 1, pressure: 1))
            panel.sendEvent(event)
            XCTAssertEqual(recorder.presses, before + 1, "\(type): the first click acts")
            XCTAssertTrue(panel.isKeyWindow, "\(type): and the panel is key")
        }
    }
}
