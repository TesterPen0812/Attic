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
        // Declared fileprivate and set where they are read; and the DEBUG
        // context-menu count tag, which `tasksCountTag` sets on each cell
        // inside the host (`TasksReorderCell`), above the menus that read it.
        let setInside: Set<String> = ["atticMenuEntranceTime", "atticMaterialProbeID", "atticContextMenuCountTag"]
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

    /// The return from hidden with the hidden value handed back
    /// (rows-rerun-fable.md, "Code shape of the lever"): hidden, the content
    /// keeps the values it was hidden with, whatever changes above it and
    /// however many passes run; the update that draws it brings the current
    /// theme, palette, font and row hover gate before its first frame; and
    /// hidden a second time, it keeps that return's values, never the first
    /// hiding's.
    func testAHostHiddenTwiceKeepsEachHidingsValuesAndShowsTheCurrentOnesOnEachReturn() {
        struct Read: Equatable {
            var scheme: ColorScheme?, palette: AtticPanelThemePalette?, font: Font?, gate: ObjectIdentifier?
        }
        final class Seen { var read = Read(), rootPass = 0 }
        final class Outer: ObservableObject {
            @Published var drawn = true
            @Published var dark = false
            @Published var pass = 0
        }
        struct Probe: View {
            let seen: Seen
            @Environment(\.colorScheme) private var scheme
            @Environment(\.atticPanelThemePalette) private var palette
            @Environment(\.font) private var font
            @Environment(\.atticRowHoverGate) private var gate
            var body: some View {
                let _ = { seen.read = Read(scheme: scheme, palette: palette, font: font, gate: gate.map { ObjectIdentifier($0) }) }()
                Color.clear
            }
        }
        let gates = (light: AtticRowHoverGate(), dark: AtticRowHoverGate())
        func expected(dark: Bool) -> Read {
            Read(scheme: dark ? .dark : .light,
                 palette: (dark ? AtticPanelTheme.midnightCobalt : .original).palette(for: dark ? AtticPanelThemeAppearance.dark : .light),
                 font: dark ? .title : .body,
                 gate: ObjectIdentifier(dark ? gates.dark : gates.light))
        }
        struct Root: View {
            @ObservedObject var outer: Outer
            let seen: Seen
            let gates: (light: AtticRowHoverGate, dark: AtticRowHoverGate)
            var body: some View {
                let dark = outer.dark
                let _ = { seen.rootPass = outer.pass }()
                KeptContentHost(drawn: outer.drawn, interactive: outer.drawn) { Probe(seen: seen) }
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.atticPanelThemePalette,
                                 (dark ? AtticPanelTheme.midnightCobalt : .original).palette(for: dark ? AtticPanelThemeAppearance.dark : .light))
                    .environment(\.font, dark ? .title : .body)
                    .environment(\.atticRowHoverGate, dark ? gates.dark : gates.light)
                    .frame(width: 100, height: 100 + CGFloat(outer.pass % 2))
            }
        }
        let seen = Seen(), outer = Outer()
        let window = NSWindow(contentRect: CGRect(x: -6_000, y: -6_000, width: 100, height: 101),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSHostingView(rootView: Root(outer: outer, seen: seen, gates: gates))
        window.contentView = root
        window.orderFront(nil)
        /// A pass of the root (and a size write of the host), waited for, bounded.
        func pass() {
            outer.pass += 1
            waitForTestOperation("the root's pass") {
                root.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                return seen.rootPass == outer.pass
            }
            root.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        /// Draws the host: the update that draws it, and its first frame,
        /// with no turn of the run loop.
        func draw() {
            outer.drawn = true
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        pass()
        XCTAssertEqual(seen.read, expected(dark: false), "drawn, with the values set above")

        outer.drawn = false
        pass()
        outer.dark = true
        #if DEBUG
        KeptContentHostCounts.reset()
        #endif
        for _ in 0..<4 { pass() }
        #if DEBUG
        print("KEPT_RETURN hidden passes=4 env_hidden=\(KeptContentHostCounts.environments.off) updates_hidden=\(KeptContentHostCounts.updates.off)")
        #endif
        XCTAssertEqual(seen.read, expected(dark: false), "hidden: it keeps the values it was hidden with")
        draw()
        XCTAssertEqual(seen.read, expected(dark: true), "its first frame back has the current values")

        outer.drawn = false
        pass()
        outer.dark = false
        for _ in 0..<4 { pass() }
        XCTAssertEqual(seen.read, expected(dark: true), "hidden again: it keeps this hiding's values, not the first's")
        draw()
        XCTAssertEqual(seen.read, expected(dark: false), "its second return has the current values")
    }

    /// PR 63 review (P3): a host drawn and hidden again before its drawn
    /// root's environment ran (a fast tab switch, a switch during a live
    /// resize) takes the values of this hiding, not the value its first
    /// hiding stored. Only the clear in `KeptContentHost.root` covers it: no
    /// drawn run came between to clear the stored value.
    func testAHostDrawnAndHiddenAgainBeforeItsDrawnRootRunsTakesThisHidingsValues() {
        final class Seen { var scheme: ColorScheme?, font: Font?, rootPass = 0 }
        final class Outer: ObservableObject {
            @Published var drawn = true
            @Published var dark = false
            @Published var pass = 0
        }
        struct Probe: View {
            let seen: Seen
            @Environment(\.colorScheme) private var scheme
            @Environment(\.font) private var font
            var body: some View {
                let _ = { seen.scheme = scheme; seen.font = font }()
                Color.clear
            }
        }
        struct Root: View {
            @ObservedObject var outer: Outer
            let seen: Seen
            var body: some View {
                let _ = { seen.rootPass = outer.pass }()
                KeptContentHost(drawn: outer.drawn, interactive: outer.drawn) { Probe(seen: seen) }
                    .environment(\.colorScheme, outer.dark ? .dark : .light)
                    .environment(\.font, outer.dark ? .title : .body)
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
        /// A pass of the root and the host, waited for, bounded.
        func settle() {
            outer.pass += 1
            waitForTestOperation("the root's pass") {
                root.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                return seen.rootPass == outer.pass
            }
            root.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        /// The root's own update alone (its representables update and set
        /// their roots); the host's content is not updated.
        func rootOnly() {
            outer.pass += 1
            root.layout()
            XCTAssertEqual(seen.rootPass, outer.pass, "the root's own update ran")
        }
        settle()
        XCTAssertEqual(seen.scheme, .light)
        outer.drawn = false
        settle()
        for _ in 0..<2 { settle() }
        XCTAssertEqual(seen.scheme, .light, "hidden with the values it was hidden with")

        outer.dark = true
        #if DEBUG
        KeptContentHostCounts.reset()
        #endif
        outer.drawn = true
        rootOnly()
        outer.drawn = false
        rootOnly()
        #if DEBUG
        XCTAssertEqual(KeptContentHostCounts.roots, KeptContentHostCounts.Split(on: 1, off: 1),
                       "a drawn root, then a hidden one")
        XCTAssertEqual(KeptContentHostCounts.environments.on, 0, "the drawn root's environment never ran")
        #endif
        settle()
        XCTAssertEqual(seen.scheme, .dark, "hidden again: this hiding's values, not the first hiding's")
        XCTAssertEqual(seen.font, .title)
    }

    /// HB-03: a nested host's own update runs inside the overlay layout
    /// guard, as the panel's root does, so an overlay anchor made or
    /// dismantled there changes the hierarchy only after the pass.
    /// Counts the placements of what it lays out.
    private struct CountingLayout: Layout {
        final class Count { var placements = 0 }
        let count: Count

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            proposal.replacingUnspecifiedDimensions()
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            count.placements += 1
            for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
        }
    }

    /// PR 41 (Find close): a drawn root is laid out in the pass that sets
    /// it, under that pass's transaction. Left to AppKit, the layout came
    /// about 0.1 s later in an un-animated pass of its own, and the Now
    /// list's returning rows were drawn thin for about 1.3 s.
    func testADrawnRootIsLaidOutInThePassThatSetsIt() {
        let count = CountingLayout.Count()
        func root(_ rows: Int) -> AnyView {
            AnyView(CountingLayout(count: count) {
                VStack { ForEach(0..<rows, id: \.self) { Text("row \($0)") } }
            })
        }
        let host = KeptContentHostingView(rootView: root(2))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        host.frame = window.contentLayoutRect
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let before = count.placements
        XCTAssertGreaterThan(before, 0, "the first root was placed, so the count means something")

        host.setRoot(root(5), laidOut: true, under: Transaction(animation: .default))
        XCTAssertGreaterThan(count.placements, before, "the new root was placed before the pass that set it returned")
        XCTAssertFalse(host.needsLayout, "no layout of the new root is left for a later pass")

        let drawn = count.placements
        host.setRoot(root(7), laidOut: false, under: Transaction())
        XCTAssertEqual(count.placements, drawn, "a hidden root is not laid out by the pass that sets it")
    }

    /// Which roots the boundary lays out as it sets them: one that changes
    /// the rows of the drawn root before it, and no other.
    func testOnlyAChangeOfDrawnRowsIsLaidOutInThePassThatSetsIt() {
        typealias Host = KeptContentHost<EmptyView>
        XCTAssertTrue(Host.movesRows(from: AnyHashable([1, 2]), to: AnyHashable([1, 2, 3])), "rows came")
        XCTAssertFalse(Host.movesRows(from: AnyHashable([1, 2]), to: AnyHashable([1, 2])), "the same rows (a click, a hover)")
        XCTAssertFalse(Host.movesRows(from: nil, to: AnyHashable([1, 2])), "a root revealed: nothing was drawn before it")
        XCTAssertFalse(Host.movesRows(from: AnyHashable([1, 2]), to: nil), "a hidden root, or content with no rows")
    }

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
