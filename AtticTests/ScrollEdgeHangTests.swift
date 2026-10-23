import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// ScrollEdgeUITests' hang (PR #11, CI runs 39860554817 and 39887675692):
/// with a draft in the composer, so the strip shows, the third scroll step
/// (−170, +11, +11) left the app's main thread busy for minutes. Hosted
/// here, on the invisible test host, with Reduce Motion as CI's runners
/// have it (on) and off; each step must return within 2 s.
@MainActor
final class ScrollEdgeHangTests: XCTestCase {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// Ends a stalled run with a crash (so its report carries the main
    /// thread's stack) instead of hanging the suite.
    private final class Watchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var started: Date?
        private var label = ""
        private var stopped = false

        init() {
            Thread.detachNewThread { [self] in
                while true {
                    Thread.sleep(forTimeInterval: 0.25)
                    lock.lock()
                    let done = stopped, since = started, what = label
                    lock.unlock()
                    if done { return }
                    if let since, Date().timeIntervalSince(since) > 20 {
                        FileHandle.standardError.write(Data("ATTIC_SCROLL_HANG stalled in \(what)\n".utf8))
                        abort()
                    }
                }
            }
        }

        func run<T>(_ what: String, _ body: () throws -> T) rethrows -> (T, TimeInterval) {
            lock.lock(); started = Date(); label = what; lock.unlock()
            let start = Date()
            defer { lock.lock(); started = nil; lock.unlock() }
            let value = try body()
            return (value, Date().timeIntervalSince(start))
        }

        func stop() { lock.lock(); stopped = true; lock.unlock() }
    }

    override func tearDown() {
        #if DEBUG
        AtticMotionPreference.systemReduceMotionOverride = nil
        #endif
        super.tearDown()
    }

    func testScrollingUnderTheStripReturnsWithReduceMotion() throws {
        try check(reduceMotion: true)
    }

    func testScrollingUnderTheStripReturnsWithoutReduceMotion() throws {
        try check(reduceMotion: false)
    }

    private func check(reduceMotion: Bool) throws {
        #if DEBUG
        AtticMotionPreference.systemReduceMotionOverride = reduceMotion
        #endif
        let watchdog = Watchdog()
        defer { watchdog.stop() }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedDemo(in: container, long: true)
        let store = TaskStore(container: container)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        // The UI test's panel: 320 × 464, solid, light.
        let size = CGSize(width: 320, height: 464)
        var focused = true
        let page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: size),
                             addBarFocused: Binding(get: { focused }, set: { focused = $0 }))
        let window = Panel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let design = AtticDesignContext(mode: .light, surface: .solid, reduceMotion: reduceMotion)
        window.contentView = NSHostingView(rootView: page.atticDesign(design).frame(width: size.width, height: size.height))
        window.orderFront(nil)
        window.makeKey()
        func frame() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        func settle(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { frame() }
        }
        _ = watchdog.run("launch") { settle(1) }

        // The draft, as typed: the strip shows its Date, Tag and Priority.
        let draft = "Water plants tomorrow #home !!"
        let (_, typed) = watchdog.run("draft") {
            model.addBarState.text.text = draft
            model.addBarState.caret = (draft as NSString).length
            settle(1)
        }
        XCTAssertLessThan(typed, 2.5, "the draft settles")
        let stripShown = Self.axFind("composer-date", in: window.contentView as Any, depth: 0)
        print("ATTIC_SCROLL_HANG strip_identified=\(stripShown) reduceMotion=\(reduceMotion)")

        let lists = window.contentView.map(Self.scrollViews) ?? []
        let list = try XCTUnwrap(lists.max { $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0 },
                                 "the Now list")
        for (index, delta) in [CGFloat(-170), 11, 11, 340].enumerated() {
            let (_, elapsed) = try watchdog.run("scroll \(index) by \(delta)") {
                // As the UI test's wheel: at the panel's middle, through the window.
                let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                                  wheel1: Int32(delta), wheel2: 0, wheel3: 0))
                let point = window.convertPoint(toScreen: CGPoint(x: size.width * 0.5, y: size.height * 0.48))
                let primary = NSScreen.screens.first?.frame.height ?? 0
                event.location = CGPoint(x: point.x, y: primary - point.y)
                let before = list.contentView.bounds.minY
                window.sendEvent(try XCTUnwrap(NSEvent(cgEvent: event)))
                frame()
                if abs(list.contentView.bounds.minY - before) < 0.5 {
                    // An off-screen window may not route the wheel: move the
                    // clip view as the wheel would.
                    let target = before - delta
                    list.contentView.scroll(to: CGPoint(x: 0, y: target))
                    list.reflectScrolledClipView(list.contentView)
                }
                settle(1)
            }
            print("ATTIC_SCROLL_HANG step=\(index) delta=\(delta) seconds=\(elapsed) offset=\(list.contentView.bounds.minY)")
            XCTAssertLessThan(elapsed, 2, "scroll step \(index) (\(delta)) returns: reduceMotion \(reduceMotion)")
            // What failed on CI was XCUITest's snapshot after the step: the
            // whole accessibility tree, read on the main thread.
            let (count, snapshot) = watchdog.run("snapshot \(index)") { Self.axCount(window.contentView as Any, depth: 0) }
            print("ATTIC_SCROLL_HANG step=\(index) ax_elements=\(count) ax_seconds=\(snapshot)")
            XCTAssertLessThan(snapshot, 2, "the accessibility snapshot after step \(index) returns: reduceMotion \(reduceMotion)")
        }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    /// Walks the accessibility tree as a snapshot does: every element's
    /// role, label, identifier, frame and children.
    private static func axCount(_ element: Any, depth: Int) -> Int {
        guard depth < 40, let node = element as? NSAccessibilityProtocol else { return 0 }
        _ = node.accessibilityRole(); _ = node.accessibilityLabel(); _ = node.accessibilityFrame()
        _ = node.accessibilityIdentifier()
        return 1 + (node.accessibilityChildren() ?? []).reduce(0) { $0 + axCount($1, depth: depth + 1) }
    }

    private static func axFind(_ identifier: String, in element: Any, depth: Int) -> Bool {
        guard depth < 40, let node = element as? NSAccessibilityProtocol else { return false }
        if node.accessibilityIdentifier() == identifier { return true }
        return (node.accessibilityChildren() ?? []).contains { axFind(identifier, in: $0, depth: depth + 1) }
    }
}
