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
    private var enhanced: Any?

    /// SwiftUI builds a window's accessibility tree only for a client; these
    /// tests ask as one (as `AdaptiveTagsTests.withAccessibility` does).
    override func setUp() {
        super.setUp()
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        enhanced = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
    }

    override func tearDown() {
        NSApp.accessibilitySetValue(enhanced, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        super.tearDown()
    }

    private final class Shown: ObservableObject {
        @Published var first = true
        /// Drawn but not in use (a neighbour a swipe shows, HB-01).
        @Published var firstInteractive: Bool?
        @Published var tick = 0
    }

    /// Observed only inside the first host: a change runs that host alone.
    private final class Inner: ObservableObject {
        @Published var value = 0
    }

    /// Records whether its update ran inside the overlay layout guard.
    private struct GuardProbe: NSViewRepresentable {
        let value: Int
        static var updatesOutsideGuard = 0
        static var updates = 0
        func makeNSView(context: Context) -> NSView { NSView() }
        func updateNSView(_ view: NSView, context: Context) {
            Self.updates += 1
            if !AtticOverlayHierarchy.isInLayoutPass { Self.updatesOutsideGuard += 1 }
        }
    }

    private struct InnerView: View {
        @ObservedObject var inner: Inner
        var body: some View { GuardProbe(value: inner.value).frame(width: 10, height: 10) }
    }

    /// Two hosts on the same place: the first shown or not as `state` says,
    /// the second always hidden.
    private struct Pair: View {
        @ObservedObject var state: Shown
        let inner: Inner

        var body: some View {
            let _ = state.tick
            ZStack {
                KeptContentHost(drawn: state.first, interactive: state.firstInteractive ?? state.first) {
                    ZStack {
                        Button("First") {}.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("First")
                        InnerView(inner: inner)
                    }
                }
                KeptContentHost(drawn: false, interactive: false) {
                    Button("Hidden") {}.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("Hidden")
                }
            }
            .frame(width: 300, height: 200)
        }
    }

    private struct Fixture {
        let window: NSWindow
        let root: NSHostingView<Pair>
        let state: Shown
        let inner: Inner

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
        let inner = Inner()
        let root = NSHostingView(rootView: Pair(state: state, inner: inner))
        window.contentView = root
        // Ordered in (off screen, as the hosted Tasks tests do): SwiftUI builds
        // a window's accessibility tree only once it is on a screen list.
        window.orderFront(nil)
        let fixture = Fixture(window: window, root: root, state: state, inner: inner)
        fixture.settle()
        return fixture
    }

    private func label(_ element: AnyObject?) -> String? {
        guard let element else { return nil }
        // The content's identifier (as the hosted panel tests match elements).
        let identifier = element.accessibilityIdentifier?() ?? ""
        return identifier.isEmpty ? nil : identifier
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
        let hidden = try XCTUnwrap(hosts.first { !$0.isInteractive })
        let shown = try XCTUnwrap(hosts.first { $0.isInteractive })
        let centre = NSPoint(x: hidden.bounds.midX, y: hidden.bounds.midY)
        XCTAssertNil(hidden.hitTest(hidden.convert(centre, to: hidden.superview)), "a hidden host takes no click")
        XCTAssertEqual(hidden.accessibilityChildren()?.count ?? 0, 0, "a hidden host has no accessibility children")
        XCTAssertNil(hidden.accessibilityHitTest(fixture.screenCentre), "a hidden host answers no accessibility hit")
        XCTAssertTrue(labels(under: fixture.root).contains("First"), "the window's tree reads the shown host's content")
        XCTAssertFalse(labels(under: fixture.root).contains("Hidden"), "and nothing of the hidden one")
        XCTAssertTrue(shown.isAccessibilityElement() || (shown.accessibilityChildren()?.count ?? 0) > 0, "the shown host answers")
        XCTAssertTrue(shown.acceptsFirstMouse(for: nil), "the panel takes its first press in a nested host")
    }

    func testShowingAHostRestoresItsAccessibility() throws {
        let fixture = makeFixture(firstShown: false)
        defer { fixture.window.close() }
        let first = try XCTUnwrap(fixture.hosts.first, "the first host in tree order")
        XCTAssertFalse(first.isInteractive)
        XCTAssertFalse(labels(under: fixture.root).contains("First"), "hidden, the window's tree has no First")
        fixture.state.first = true
        fixture.settle()
        XCTAssertTrue(first.isInteractive)
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
        XCTAssertEqual(KeptContentHostCounts.roots.off, 0, "two hidden updates in a row set no root")
        fixture.state.first = true
        fixture.settle()
        XCTAssertEqual(KeptContentHostCounts.roots.on, 1, "showing it sets its root once")
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
        let first = try XCTUnwrap(fixture.hosts.first { $0.isInteractive })
        fixture.window.makeFirstResponder(first)
        XCTAssertTrue(fixture.window.firstResponder === first)
        fixture.state.first = false
        fixture.settle()
        let responder = fixture.window.firstResponder as? NSView
        XCTAssertFalse(responder.map { $0 === first || $0.isDescendant(of: first) } ?? false,
                       "no key reaches a hidden host's graph")
    }

    /// HB-01: drawn is not in use. A neighbour a swipe draws takes no
    /// click, no keyboard and no read.
    func testADrawnHostThatIsNotInUseTakesNoInputOrReads() throws {
        let fixture = makeFixture()
        defer { fixture.window.close() }
        fixture.state.firstInteractive = false
        fixture.settle()
        let first = try XCTUnwrap(fixture.hosts.first)
        let centre = NSPoint(x: first.bounds.midX, y: first.bounds.midY)
        XCTAssertNil(first.hitTest(first.convert(centre, to: first.superview)), "no click")
        XCTAssertFalse(first.acceptsFirstResponder, "no keyboard")
        XCTAssertFalse(first.canBecomeKeyView, "not in the key-view loop")
        XCTAssertFalse(first.isAccessibilityElement(), "not an accessibility element")
        XCTAssertEqual(first.accessibilityChildren()?.count ?? 0, 0, "no children")
        XCTAssertFalse(labels(under: fixture.root).contains("First"), "the window's tree has no First")
        fixture.state.firstInteractive = true
        fixture.settle()
        XCTAssertTrue(labels(under: fixture.root).contains("First"), "in use again, it is read")
    }

    /// HB-03: a nested host's own update runs inside the overlay layout
    /// guard, as the panel's root does, so an overlay anchor made or
    /// dismantled there changes the hierarchy only after the pass.
    func testANestedHostsOwnUpdateRunsInsideTheOverlayLayoutGuard() {
        let fixture = makeFixture()
        defer { fixture.window.close() }
        GuardProbe.updates = 0
        GuardProbe.updatesOutsideGuard = 0
        for _ in 0..<3 {
            fixture.inner.value += 1
            fixture.settle()
        }
        XCTAssertGreaterThan(GuardProbe.updates, 0, "the host updated alone, so the count means something")
        XCTAssertEqual(GuardProbe.updatesOutsideGuard, 0, "every update inside the host ran inside the guard")
    }
}
