import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The kept-content host's rules (ops/design/host-boundary.md §4.2 and §5):
/// a host that is not shown takes no clicks, answers no accessibility
/// queries, gets no new root on the parent's updates, and lets go of the
/// keyboard; the panel's accessibility hit walk reaches the shown host and
/// never a hidden one.
@MainActor
final class KeptContentHostTests: XCTestCase {
    private final class Shown: ObservableObject {
        @Published var first = true
        @Published var tick = 0
    }

    /// Two hosts on the same place: the first shown or not as `state` says,
    /// the second always hidden.
    private struct Pair: View {
        @ObservedObject var state: Shown

        var body: some View {
            let _ = state.tick
            ZStack {
                KeptContentHost(shown: state.first) {
                    Button("First") {}.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                KeptContentHost(shown: false) {
                    Button("Hidden") {}.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 300, height: 200)
        }
    }

    private struct Fixture {
        let window: NSWindow
        let root: NSHostingView<Pair>
        let state: Shown

        var hosts: [KeptContentHostingView] { Self.hosts(in: root) }

        static func hosts(in view: NSView) -> [KeptContentHostingView] {
            if let host = view as? KeptContentHostingView { return [host] }
            return view.subviews.flatMap { hosts(in: $0) }
        }

        func settle() {
            root.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            root.layoutSubtreeIfNeeded()
        }

        /// The centre of the pair, on screen (where accessibility frames are).
        var screenCentre: NSPoint {
            let local = NSPoint(x: root.bounds.midX, y: root.bounds.midY)
            return window.convertPoint(toScreen: root.convert(local, to: nil))
        }
    }

    private func makeFixture(firstShown: Bool = true) -> Fixture {
        let state = Shown()
        state.first = firstShown
        let window = NSWindow(contentRect: CGRect(x: -6_000, y: -6_000, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSHostingView(rootView: Pair(state: state))
        window.contentView = root
        let fixture = Fixture(window: window, root: root, state: state)
        fixture.settle()
        return fixture
    }

    private func label(_ element: AnyObject?) -> String? {
        guard let element else { return nil }
        let label = element.accessibilityLabel?() ?? nil
        let title = element.accessibilityTitle?() ?? nil
        return [label, title].compactMap { $0 }.first { !$0.isEmpty }
    }

    private func labels(under element: AnyObject, depth: Int = 0) -> [String] {
        guard depth < 32 else { return [] }
        let children = (element.accessibilityChildren?() ?? nil) ?? []
        return children.flatMap { child -> [String] in
            let object = child as AnyObject
            return (label(object).map { [$0] } ?? []) + labels(under: object, depth: depth + 1)
        }
    }

    func testAHiddenHostTakesNoClicksAndAnswersNoAccessibility() throws {
        let fixture = makeFixture()
        defer { fixture.window.close() }
        let hosts = fixture.hosts
        XCTAssertEqual(hosts.count, 2)
        let hidden = try XCTUnwrap(hosts.first { !$0.isShown })
        let shown = try XCTUnwrap(hosts.first { $0.isShown })
        let centre = NSPoint(x: hidden.bounds.midX, y: hidden.bounds.midY)
        XCTAssertNil(hidden.hitTest(hidden.convert(centre, to: hidden.superview)), "a hidden host takes no click")
        XCTAssertEqual(hidden.accessibilityChildren()?.count ?? 0, 0, "a hidden host has no accessibility children")
        XCTAssertNil(hidden.accessibilityHitTest(fixture.screenCentre), "a hidden host answers no accessibility hit")
        XCTAssertTrue(labels(under: shown).contains("First"), "the shown host answers with its content")
        XCTAssertTrue(shown.acceptsFirstMouse(for: nil), "the panel takes its first press in a nested host")
    }

    func testShowingAHostRestoresItsAccessibility() throws {
        let fixture = makeFixture(firstShown: false)
        defer { fixture.window.close() }
        let first = try XCTUnwrap(fixture.hosts.first, "the first host in tree order")
        XCTAssertFalse(first.isShown)
        XCTAssertFalse(labels(under: fixture.root).contains("First"), "hidden, the window's tree has no First")
        fixture.state.first = true
        fixture.settle()
        XCTAssertTrue(first.isShown)
        XCTAssertTrue(labels(under: fixture.root).contains("First"), "shown again, its content is read")
        XCTAssertFalse(labels(under: fixture.root).contains("Hidden"), "the other host stays out")
    }

    #if DEBUG
    func testAHiddenHostGetsNoNewRootOnTheParentsUpdates() {
        let fixture = makeFixture(firstShown: false)
        defer { fixture.window.close() }
        KeptContentHostCounts.reset()
        for _ in 0..<3 {
            fixture.state.tick += 1
            fixture.settle()
        }
        XCTAssertEqual(KeptContentHostCounts.roots.hidden, 0, "two hidden updates in a row set no root")
        fixture.state.first = true
        fixture.settle()
        XCTAssertEqual(KeptContentHostCounts.roots.shown, 1, "showing it sets its root once")
    }
    #endif

    /// The panel's accessibility hit test (`AtticPanelHostingView.topmostElement`,
    /// what XCUITest's hit points rest on) reaches the shown nested host and
    /// never enters a hidden one, even where the hidden one lies on top.
    func testThePanelsHitWalkReachesTheShownHostAndNeverAHiddenOne() throws {
        let fixture = makeFixture()
        defer { fixture.window.close() }
        let hit = AtticPanelHostingView.topmostElement(in: fixture.root, at: fixture.screenCentre)
        XCTAssertEqual(label(hit), "First", "the walk finds the shown host's element at the point")

        fixture.state.first = false
        fixture.settle()
        let none = AtticPanelHostingView.topmostElement(in: fixture.root, at: fixture.screenCentre)
        XCTAssertNotEqual(label(none), "First", "nothing from a host once it is hidden")
        XCTAssertNotEqual(label(none), "Hidden", "nothing from a host that was never shown")
    }

    func testAHostThatHidesLetsGoOfTheKeyboard() throws {
        let fixture = makeFixture()
        defer { fixture.window.close() }
        let first = try XCTUnwrap(fixture.hosts.first { $0.isShown })
        fixture.window.makeFirstResponder(first)
        XCTAssertTrue(fixture.window.firstResponder === first)
        fixture.state.first = false
        fixture.settle()
        let responder = fixture.window.firstResponder as? NSView
        XCTAssertFalse(responder.map { $0 === first || $0.isDescendant(of: first) } ?? false,
                       "no key reaches a hidden host's graph")
    }
}
