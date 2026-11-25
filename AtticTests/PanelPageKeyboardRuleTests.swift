import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The panel's one keyboard rule (`PanelPageKeyboard`, fix B): a view
/// tagged with a page that is not shown, or under a kept host out of use,
/// never takes the keyboard, and Tab moves past it to the next view that
/// may. A bare `AtticPanel`, never ordered front.
@MainActor
final class PanelPageKeyboardRuleTests: XCTestCase {
    /// A view that takes the keyboard and is always in the key-view loop,
    /// so only the panel's rule can keep it out.
    private final class Stop: NSView {
        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }
    }

    private final class Shown {
        var pages: Set<PanelPage>
        init(_ pages: Set<PanelPage>) { self.pages = pages }
    }

    private func panel(showing shown: Shown) -> AtticPanel {
        let panel = AtticPanel(contentRect: CGRect(x: -5_000, y: -5_000, width: 300, height: 300),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        panel.showsPageQuery = { [shown] in shown.pages.contains($0) }
        return panel
    }

    private func stop(_ membership: PanelKeyboardMembership?, in parent: NSView, y: CGFloat) -> Stop {
        let view = Stop(frame: CGRect(x: 10, y: y, width: 100, height: 20))
        parent.addSubview(view)
        if let membership { PanelPageKeyboard.tag(view, membership) }
        return view
    }

    func testATaggedViewOfAHiddenPageIsRefusedAndTakesItWhenShown() throws {
        let shown = Shown([.calendar])
        let panel = panel(showing: shown)
        defer { panel.close() }
        let content = try XCTUnwrap(panel.contentView)
        let notes = stop(.page(.notes), in: content, y: 10)
        let chrome = stop(.chrome, in: content, y: 40)
        let inner = Stop(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        notes.addSubview(inner)

        XCTAssertFalse(panel.makeFirstResponder(notes), "a hidden page's view was given the keyboard")
        XCTAssertFalse(panel.makeFirstResponder(inner), "a view inside a hidden page's view was given the keyboard")
        XCTAssertFalse(PanelPageKeyboard.mayTakeKeyboard(inner))
        XCTAssertTrue(panel.makeFirstResponder(chrome), "the chrome takes the keyboard on any page")
        XCTAssertTrue(panel.firstResponder === chrome, "a refusal leaves the keyboard where it was")

        shown.pages = [.notes]
        XCTAssertTrue(panel.makeFirstResponder(inner), "shown, the page's views take the keyboard")
        XCTAssertEqual(PanelPageKeyboard.membership(of: notes), .page(.notes))
        XCTAssertEqual(PanelPageKeyboard.membership(of: chrome), .chrome)
        XCTAssertNil(PanelPageKeyboard.membership(of: inner), "the tag is the view's own, not inherited")
    }

    /// The addition's first half: a kept host out of use refuses what is
    /// under it (a SwiftUI field there cannot answer for itself).
    func testAKeptHostOutOfUseRefusesEverythingUnderIt() throws {
        let panel = panel(showing: Shown(Set(PanelPage.allCases)))
        defer { panel.close() }
        let content = try XCTUnwrap(panel.contentView)
        let host = KeptContentHostingView(rootView: AnyView(Color.clear))
        host.frame = content.bounds
        content.addSubview(host)
        let field = Stop(frame: CGRect(x: 10, y: 10, width: 100, height: 20))
        host.addSubview(field)

        host.isInteractive = false
        XCTAssertFalse(panel.makeFirstResponder(field), "a field under a kept host out of use took the keyboard")
        host.isInteractive = true
        XCTAssertTrue(panel.makeFirstResponder(field), "in use, the host's fields take the keyboard")
    }

    /// Tab and Shift-Tab skip views the rule refuses and still cycle
    /// through the ones that may take the keyboard.
    func testTabSkipsRefusedViewsAndStillCycles() throws {
        let panel = panel(showing: Shown([.calendar]))
        defer { panel.close() }
        let content = try XCTUnwrap(panel.contentView)
        let first = stop(.page(.calendar), in: content, y: 10)
        let hiddenA = stop(.page(.notes), in: content, y: 40)
        let hiddenB = stop(.page(.canvas), in: content, y: 70)
        let second = stop(.chrome, in: content, y: 100)
        first.nextKeyView = hiddenA
        hiddenA.nextKeyView = hiddenB
        hiddenB.nextKeyView = second
        second.nextKeyView = first

        XCTAssertTrue(panel.makeFirstResponder(first))
        panel.selectKeyView(following: first)
        XCTAssertTrue(panel.firstResponder === second, "Tab skipped the hidden pages' views")
        panel.selectKeyView(following: second)
        XCTAssertTrue(panel.firstResponder === first, "Tab cycled back")
        panel.selectKeyView(preceding: second)
        XCTAssertTrue(panel.firstResponder === first, "Shift-Tab skipped the hidden pages' views")
        panel.selectKeyView(preceding: first)
        XCTAssertTrue(panel.firstResponder === second, "Shift-Tab cycled back")
    }

    /// Review P2 (opus2): a real Tab, sent as a key event through the
    /// window, moves past a refused field that AppKit still counts as a
    /// key view (an AppKit text field here, like a tagged field without a
    /// `canBecomeKeyView` answer of its own), from a field and from the
    /// window itself, and Shift-Tab does the same.
    func testATabKeyThroughTheWindowMovesPastARefusedField() throws {
        let panel = panel(showing: Shown([.calendar]))
        defer { panel.close() }
        let content = try XCTUnwrap(panel.contentView)
        func field(_ membership: PanelKeyboardMembership, y: CGFloat) -> NSTextField {
            let field = NSTextField(frame: CGRect(x: 10, y: y, width: 200, height: 22))
            content.addSubview(field)
            PanelPageKeyboard.tag(field, membership)
            return field
        }
        let first = field(.page(.calendar), y: 10)
        let hidden = field(.page(.notes), y: 50)
        let second = field(.chrome, y: 90)
        // A closed loop through the content view, as AppKit builds it.
        content.nextKeyView = first
        first.nextKeyView = second
        second.nextKeyView = hidden
        hidden.nextKeyView = content
        panel.initialFirstResponder = hidden
        func holds(_ view: NSView) -> Bool { (panel.firstResponder as? NSView)?.isDescendant(of: view) == true }
        func name() -> String { panel.firstResponder.map { String(describing: type(of: $0)) } ?? "nil" }
        func tab(shift: Bool = false) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: panel.windowNumber, context: nil,
                                                       characters: shift ? "\u{19}" : "\t", charactersIgnoringModifiers: "\t",
                                                       isARepeat: false, keyCode: 48))
            panel.sendEvent(event)
        }

        XCTAssertTrue(panel.makeFirstResponder(second))
        try tab()
        XCTAssertTrue(holds(first), "Tab from a field did not move past the refused field (responder \(name()))")
        try tab(shift: true)
        XCTAssertTrue(holds(second), "Shift-Tab did not move past the refused field (responder \(name()))")

        // With the window holding the keyboard, Tab is the window's own
        // selectNextKeyView, where AppKit picks the candidate itself (here
        // `initialFirstResponder`, the refused field). A key event reaches
        // it only in a key window (run hb-tab: in the invisible host the
        // panel is not key and the key changed nothing, on either code), so
        // the call is made here and the key goes to CI's key-window lane.
        XCTAssertTrue(panel.makeFirstResponder(nil))
        panel.selectNextKeyView(nil)
        XCTAssertTrue(holds(first), "Tab from the window stalled on the refused field (responder \(name()))")
        XCTAssertTrue(panel.makeFirstResponder(nil))
        panel.selectPreviousKeyView(nil)
        XCTAssertTrue(holds(second), "Shift-Tab from the window stalled on the refused field (responder \(name()))")
    }

    /// The same, with the Tab key itself, from the window of a key panel.
    func testATabKeyFromAKeyPanelsWindowMovesPastARefusedField() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" else {
            throw XCTSkip("the window's own Tab key needs a key panel: runs on CI only")
        }
        let panel = panel(showing: Shown([.calendar]))
        defer { panel.close() }
        let content = try XCTUnwrap(panel.contentView)
        let first = NSTextField(frame: CGRect(x: 10, y: 10, width: 200, height: 22))
        let hidden = NSTextField(frame: CGRect(x: 10, y: 50, width: 200, height: 22))
        [first, hidden].forEach(content.addSubview)
        PanelPageKeyboard.tag(first, .page(.calendar))
        PanelPageKeyboard.tag(hidden, .page(.notes))
        first.nextKeyView = hidden
        hidden.nextKeyView = first
        content.nextKeyView = hidden
        panel.initialFirstResponder = hidden
        panel.makeKeyAndOrderFront(nil)
        XCTAssertTrue(panel.makeFirstResponder(nil))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: panel.windowNumber, context: nil, characters: "\t",
                                                   charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        panel.sendEvent(event)
        XCTAssertTrue((panel.firstResponder as? NSView)?.isDescendant(of: first) == true,
                      "the Tab key from the window stalled on the refused field")
    }

    /// Views outside an AtticPanel are not the panel's to refuse.
    func testViewsOutsideAPanelAreNotRefused() {
        let window = NSWindow(contentRect: CGRect(x: -5_000, y: -5_000, width: 200, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = Stop(frame: CGRect(x: 0, y: 0, width: 50, height: 20))
        window.contentView?.addSubview(view)
        PanelPageKeyboard.tag(view, .page(.notes))
        XCTAssertTrue(PanelPageKeyboard.mayTakeKeyboard(view))
        XCTAssertTrue(window.makeFirstResponder(view))
    }
}
