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

// MARK: - 3. Thin overlay scrollers, hidden during page swipes

@MainActor
final class OwnerFindingsScrollerTests: XCTestCase {
    func testTwoFingersHideTheScrollersUntilTheGestureIsVertical() {
        typealias Rule = TasksScrollerRule
        XCTAssertEqual(Rule.change(phase: .mayBegin, momentum: false, axis: nil), .hide, "fingers down: nothing yet")
        XCTAssertEqual(Rule.change(phase: .began, momentum: false, axis: .undecided), .hide)
        XCTAssertEqual(Rule.change(phase: .changed, momentum: false, axis: .horizontal), .hide, "a page swipe")
        XCTAssertEqual(Rule.change(phase: .changed, momentum: false, axis: .turned), .hide)
        XCTAssertEqual(Rule.change(phase: .changed, momentum: false, axis: .vertical), .show, "a vertical scroll")
        XCTAssertEqual(Rule.change(phase: .changed, momentum: false, axis: .foreign), .show, "not over the pager")
        XCTAssertEqual(Rule.change(phase: .ended, momentum: false, axis: .horizontal), .showLater, "after the swipe's flash")
        XCTAssertEqual(Rule.change(phase: .ended, momentum: false, axis: .vertical), .keep)
        XCTAssertEqual(Rule.change(phase: .changed, momentum: true, axis: .horizontal), .keep, "momentum changes nothing")
        XCTAssertEqual(Rule.change(phase: .none, momentum: false, axis: nil), .show, "a mouse wheel scrolls vertically")
    }

    /// The lists keep thin overlay scrollers whatever the system setting,
    /// even when AppKit (a setting change) or SwiftUI sets them back.
    func testTheListsKeepThinOverlayScrollers() throws {
        let hosted = try Hosted(height: 520, long: true)
        defer { hosted.close() }
        hosted.spin(1)
        let content = try XCTUnwrap(hosted.window.contentView)
        let lists = hosted.lists(in: content).filter { $0.verticalScroller != nil && $0.frame.height > 200 }
        XCTAssertFalse(lists.isEmpty)
        for list in lists {
            XCTAssertEqual(list.scrollerStyle, .overlay)
            XCTAssertEqual(list.verticalScroller?.controlSize, .small, "thin")
            list.scrollerStyle = .legacy
            NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
            hosted.spin(0.5)
            XCTAssertEqual(list.scrollerStyle, .overlay, "set back when the system setting changes")
            list.scrollerStyle = .legacy
            list.contentView.scroll(to: CGPoint(x: 0, y: 40))
            list.reflectScrolledClipView(list.contentView)
            hosted.spin(0.2)
            XCTAssertEqual(list.scrollerStyle, .overlay, "and as the list scrolls")
        }
        let proxies = TasksListProxies()
        let list = try XCTUnwrap(lists.first)
        proxies.scrollViews = [.now: list]
        proxies.apply(.hide)
        XCTAssertEqual(list.verticalScroller?.isHidden, true, "hidden during a swipe")
        proxies.apply(.show)
        XCTAssertEqual(list.verticalScroller?.isHidden, false, "back for vertical scrolling")
        let note = NoteDocumentScrollView()
        note.scrollerStyle = .legacy
        XCTAssertEqual(note.scrollerStyle, .overlay, "the note editor too")
    }
}
