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
