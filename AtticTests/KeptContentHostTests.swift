import AppKit
import Combine
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

    /// Counts its changes, and the pass that last read it records which
    /// one it saw: a settle waits for that pass, not for a fixed time.
    private class Passes: ObservableObject {
        private(set) var changes = 0
        var seen = 0
        private var counting: AnyCancellable?
        init() { counting = objectWillChange.sink { [unowned self] in self.changes += 1 } }
        var isCurrent: Bool { seen == changes }
    }

    private final class Shown: Passes {
        @Published var first = true
        /// Drawn but not in use (a neighbour a swipe shows, HB-01).
        @Published var firstInteractive: Bool?
        @Published var tick = 0
    }

    /// Observed only inside the first host: a change runs that host alone.
    private final class Inner: Passes {
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
        var body: some View {
            let _ = { inner.seen = inner.changes }()
            GuardProbe(value: inner.value).frame(width: 10, height: 10)
        }
    }

    /// Two hosts on the same place: the first shown or not as `state` says,
    /// the second always hidden.
    private struct Pair: View {
        @ObservedObject var state: Shown
        let inner: Inner

        var body: some View {
            let _ = state.tick
            let _ = { state.seen = state.changes }()
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

        /// Waits, bounded, for the pass that reads the latest change (the
        /// pair's and the first host's own) and for every host in use to
        /// join accessibility after its first frame. It reads no
        /// accessibility itself.
        @MainActor func settle(file: StaticString = #filePath, line: UInt = #line) {
            waitForTestOperation("the pair's pass and the hosts' accessibility join", file: file, line: line) {
                root.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                return state.isCurrent && inner.isCurrent && hosts.allSatisfy { !$0.isInteractive || $0.isAccessible }
            }
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

    /// HB-05: a host coming into use takes clicks and the keyboard at
    /// once, and joins accessibility only after its first frame, so a read
    /// does not mount rows in the reveal's frame.
    func testAHostComingIntoUseIsInteractiveAtOnceAndReadAfterItsFirstFrame() throws {
        let fixture = makeFixture(firstShown: false)
        defer { fixture.window.close() }
        let first = try XCTUnwrap(fixture.hosts.first)
        XCTAssertFalse(first.isInteractive)
        fixture.state.first = true
        // The update that shows it, and no turn of the run loop yet.
        fixture.root.needsLayout = true
        fixture.root.layoutSubtreeIfNeeded()
        XCTAssertTrue(first.isInteractive, "in use at once")
        XCTAssertTrue(first.acceptsFirstMouse(for: nil))
        let centre = NSPoint(x: first.bounds.midX, y: first.bounds.midY)
        XCTAssertNotNil(first.hitTest(first.convert(centre, to: first.superview)), "takes a click at once")
        XCTAssertFalse(first.isAccessible, "not read in the reveal's frame")
        XCTAssertEqual(first.accessibilityChildren()?.count ?? 0, 0, "no children in the reveal's frame")
        XCTAssertNil(first.accessibilityHitTest(fixture.screenCentre), "no hit in the reveal's frame")
        fixture.settle()
        XCTAssertTrue(first.isAccessible, "read after its first frame")
        XCTAssertTrue(labels(under: fixture.root).contains("First"), "and its content is read")
        // Out of use again: not read at once.
        fixture.state.first = false
        fixture.root.needsLayout = true
        fixture.root.layoutSubtreeIfNeeded()
        XCTAssertFalse(first.isAccessible)
    }

    /// A host made already in use (a tab not yet warmed) comes into use
    /// once it has a window: not read until its first frame, then read
    /// (§5.1, the first switch to a tab not yet warmed).
    func testAHostMadeInUseIsReadOnlyAfterItsFirstFrameInAWindow() throws {
        let state = Shown()
        let window = NSWindow(contentRect: CGRect(x: -6_000, y: -6_000, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let inner = Inner()
        let root = NSHostingView(rootView: Pair(state: state, inner: inner))
        window.contentView = root
        window.orderFront(nil)
        root.layoutSubtreeIfNeeded()
        let fixture = Fixture(window: window, root: root, state: state, inner: inner)
        let first = try XCTUnwrap(fixture.hosts.first { $0.isInteractive }, "the host made in use")
        XCTAssertNotNil(first.window)
        XCTAssertFalse(first.isAccessible, "not read before its first frame")
        XCTAssertEqual(first.accessibilityChildren()?.count ?? 0, 0, "no children before its first frame")
        fixture.settle()
        XCTAssertTrue(first.isAccessible, "read after its first frame")
        XCTAssertTrue(labels(under: root).contains("First"), "and its content is read")
    }

    /// The content's environment is forwarded by name, never whole (the
    /// whole copy carried the panel host's focus values and its focus
    /// bridge took the keyboard back, §5). Every value the Tasks content
    /// reads is forwarded, derived by the host from its window, or set
    /// inside the content itself.
    func testTheTasksContentReadsOnlyForwardedOrHostDerivedValues() throws {
        let forwarded = Set(KeptEnvironment.entries.map(\.name))
        XCTAssertEqual(forwarded.count, KeptEnvironment.entries.count, "each value named once")
        let derivedByTheHost: Set<String> = [
            "accessibilityReduceMotion", "accessibilityReduceTransparency", "accessibilityDifferentiateWithoutColor",
            "colorSchemeContrast", "displayScale", "appearsActive", "isFocused", "undoManager", "openURL", "dismiss",
            // The whole environment, read where it is handed on.
            "self",
            // The kept host itself, set at its root (HB-09's key).
            "keptHost",
        ]
        // Declared fileprivate and set where they are read.
        let setInside: Set<String> = ["atticMenuEntranceTime", "atticMaterialProbeID"]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Attic")
        let folders = ["Tasks", "DesignSystem", "Design"].map { root.appendingPathComponent($0) }
        let pattern = try NSRegularExpression(pattern: #"@Environment\(\\\.([A-Za-z]+)"#)
        var missing: [String: String] = [:]
        var scanned = 0
        for folder in folders {
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && !$0.path.contains("/Gallery/") } ?? []
            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                scanned += 1
                let range = NSRange(source.startIndex..., in: source)
                for match in pattern.matches(in: source, range: range) {
                    guard let name = Range(match.range(at: 1), in: source).map({ String(source[$0]) }) else { continue }
                    if !forwarded.contains(name), !derivedByTheHost.contains(name), !setInside.contains(name) {
                        missing[name] = file.lastPathComponent
                    }
                }
            }
        }
        XCTAssertGreaterThan(scanned, 20, "the scan found the sources")
        XCTAssertEqual(missing, [:], "read inside a kept host but not forwarded (KeptEnvironment.entries)")
    }

    /// What the whole copy gave for free still arrives (§5): values set
    /// above the host (colour scheme, theme, enabled, key state, locale,
    /// direction) and values the host reads from its window (reduce motion)
    /// are the same inside the host as just outside it.
    func testForwardedValuesReachTheContent() {
        struct Read: Equatable {
            var scheme: ColorScheme?, enabled: Bool?, active: ControlActiveState?
            var locale: String?, direction: LayoutDirection?, reduceMotion: Bool?, design: AtticDesignContext?
        }
        final class Seen { var outside = Read(); var inside = Read() }
        struct Probe: View {
            let seen: Seen
            let inside: Bool
            @Environment(\.colorScheme) private var scheme
            @Environment(\.isEnabled) private var enabled
            @Environment(\.controlActiveState) private var active
            @Environment(\.locale) private var locale
            @Environment(\.layoutDirection) private var direction
            @Environment(\.accessibilityReduceMotion) private var reduceMotion
            @Environment(\.atticDesign) private var design
            var body: some View {
                let read = Read(scheme: scheme, enabled: enabled, active: active, locale: locale.identifier,
                                direction: direction, reduceMotion: reduceMotion, design: design)
                let _ = { if inside { seen.inside = read } else { seen.outside = read } }()
                Color.clear
            }
        }
        let seen = Seen()
        let design = AtticDesignContext(mode: .dark)
        let window = NSWindow(contentRect: CGRect(x: -6_000, y: -6_000, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: ZStack {
            Probe(seen: seen, inside: false)
            KeptContentHost(drawn: true, interactive: true) { Probe(seen: seen, inside: true) }
        }
            .disabled(true)
            .environment(\.colorScheme, .dark)
            .environment(\.controlActiveState, .key)
            .environment(\.locale, Locale(identifier: "ar_EG"))
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.atticDesign, design)
            .frame(width: 100, height: 100))
        window.orderFront(nil)
        waitForTestOperation("both probes' first read") {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return seen.outside.scheme != nil && seen.inside.scheme != nil
        }
        XCTAssertEqual(seen.outside.scheme, .dark, "the probe outside read the values set above")
        XCTAssertEqual(seen.outside.locale, "ar_EG")
        XCTAssertEqual(seen.inside, seen.outside, "inside the host as just outside it")
    }

    /// §4.2 and the lead's ruling (19 Nov): a host that is not drawn takes
    /// no new environment, and the update that draws it brings the current
    /// values before its first frame (a theme changed while Later was
    /// hidden shows on its first reveal, not a frame later).
    func testAHostRevealedAfterAThemeChangeWhileHiddenShowsTheCurrentThemeInItsFirstFrame() {
        final class Seen { var scheme: ColorScheme?; var design: AtticDesignContext?; var rootDark: Bool? }
        final class Outer: ObservableObject {
            @Published var drawn = false
            @Published var dark = false
        }
        struct Probe: View {
            let seen: Seen
            @Environment(\.colorScheme) private var scheme
            @Environment(\.atticDesign) private var design
            var body: some View {
                let _ = { seen.scheme = scheme; seen.design = design }()
                Color.clear
            }
        }
        struct Root: View {
            @ObservedObject var outer: Outer
            let seen: Seen
            var body: some View {
                let _ = { seen.rootDark = outer.dark }()
                KeptContentHost(drawn: outer.drawn, interactive: outer.drawn) { Probe(seen: seen) }
                    .environment(\.colorScheme, outer.dark ? .dark : .light)
                    .environment(\.atticDesign, AtticDesignContext(mode: outer.dark ? .dark : .light))
                    .frame(width: 100, height: 100)
            }
        }
        let seen = Seen(), outer = Outer()
        let window = NSWindow(contentRect: CGRect(x: -6_000, y: -6_000, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSHostingView(rootView: Root(outer: outer, seen: seen))
        window.contentView = root
        window.orderFront(nil)
        /// Waits, bounded, for the root's pass with the current theme (the
        /// host's own reads are what the test asserts, so they are not it).
        func settle() {
            waitForTestOperation("the root's pass") {
                root.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                return seen.rootDark == outer.dark
            }
            root.layoutSubtreeIfNeeded()
        }
        settle()
        XCTAssertEqual(seen.scheme, .light, "hidden from the start, with the values it was made with")
        outer.dark = true
        settle()
        XCTAssertEqual(seen.scheme, .light, "hidden: the theme change does not reach it")
        outer.drawn = true
        // The update that draws it, and its first frame, with no turn of the run loop.
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        XCTAssertEqual(seen.scheme, .dark, "its first frame has the current scheme")
        XCTAssertEqual(seen.design, AtticDesignContext(mode: .dark), "and the current design")
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
