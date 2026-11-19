import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Each Tasks tab in its own host (ops/design/host-boundary.md, step 1):
/// the tab in use takes input and is read; the others keep their hosts and
/// rows, get no new root on updates, and are never reached by a click, a
/// key or the panel's accessibility hit walk.
@MainActor
final class TasksTabHostTests: XCTestCase {
    private func hosts(_ hosted: Hosted) -> [KeptContentHostingView] {
        func walk(_ view: NSView) -> [KeptContentHostingView] {
            if let host = view as? KeptContentHostingView { return [host] }
            return view.subviews.flatMap(walk)
        }
        guard let content = hosted.window.contentView else { return [] }
        content.layoutSubtreeIfNeeded()
        return walk(content)
    }

    private func warmed() throws -> Hosted {
        let hosted = try Hosted(height: 520)
        hosted.spin(1.5)
        XCTAssertEqual(hosted.model.pagerSwipe.span.warm, 0...2, "every tab kept built")
        return hosted
    }

    func testEachTabLivesInItsOwnHostAndOnlyTheTabInUseTakesPart() throws {
        let hosted = try warmed()
        defer { hosted.close() }
        let before = hosts(hosted)
        XCTAssertEqual(before.count, 3, "one host per tab")
        XCTAssertEqual(before.filter(\.isInteractive).count, 1, "only Now takes part")
        hosted.go(to: .backlog)
        let after = hosts(hosted)
        XCTAssertEqual(Set(after.map(ObjectIdentifier.init)), Set(before.map(ObjectIdentifier.init)),
                       "a tab switch keeps every host: nothing is rebuilt")
        XCTAssertEqual(after.filter(\.isInteractive).count, 1, "only Later takes part")
        hosted.model.isPageShown = false
        hosted.spin(0.2)
        XCTAssertEqual(hosts(hosted).filter(\.isInteractive).count, 0,
                       "a covered Tasks page takes part in nothing (HB-01)")
    }

    #if DEBUG
    /// The guard (§8.1, HB-07): updates on the tab shown set no root in a
    /// hidden host and run no hidden row; a resize step is reported.
    func testHiddenTabsGetNoRootAndRunNoRowOnTheShownTabsUpdates() throws {
        let hosted = try warmed()
        defer { hosted.close() }
        KeptContentHostCounts.reset()
        TasksCellBodyCounts.records = true
        TasksCellBodyCounts.leaves = [:]
        defer { TasksCellBodyCounts.records = false }
        let added = try XCTUnwrap(hosted.store.create(title: "Host guard task"))
        hosted.model.selectOnly(added.id)
        hosted.spin(0.3)
        hosted.window.contentView?.layoutSubtreeIfNeeded()
        let hiddenLeaves = TasksCellBodyCounts.leaves.filter { $0.key.tab != .now }.values.reduce(0, +)
        XCTAssertEqual(KeptContentHostCounts.roots.off, 0, "no root set in a hidden tab's host")
        XCTAssertEqual(hiddenLeaves, 0, "no row of a hidden tab ran on a save and a selection")
        XCTAssertGreaterThan(KeptContentHostCounts.roots.on, 0, "the tab shown did update, so the counts mean something")

        KeptContentHostCounts.reset()
        TasksCellBodyCounts.leaves = [:]
        var frame = hosted.window.frame
        frame.size.width += 24
        hosted.window.setFrame(frame, display: true)
        hosted.spin(0.2)
        let resizeLeaves = TasksCellBodyCounts.leaves.filter { $0.key.tab != .now }.values.reduce(0, +)
        print("HOST_GUARD resize roots_off=\(KeptContentHostCounts.roots.off) layouts_off=\(KeptContentHostCounts.layouts.off) layouts_on=\(KeptContentHostCounts.layouts.on) hidden_leaves=\(resizeLeaves)")
        XCTAssertEqual(KeptContentHostCounts.roots.off, 0, "a resize step sets no root in a hidden host")
    }
    #endif

    /// The panel's accessibility hit walk (condition 3): it reaches a row in
    /// the tab shown, inside that tab's nested host, and nothing it returns
    /// lies in a host not in use.
    func testTheHitWalkReachesTheShownTabsRowAndNeverAHiddenTab() throws {
        try withAccessibility { try hitWalk() }
    }

    /// SwiftUI builds a window's accessibility tree only for a client; the
    /// tests ask as one (as `AdaptiveTagsTests.withAccessibility` does).
    private func withAccessibility(_ body: () throws -> Void) rethrows {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        try body()
    }

    private func hitWalk() throws {
        let hosted = try warmed()
        defer { hosted.close() }
        hosted.go(to: .backlog)
        let content = try XCTUnwrap(hosted.window.contentView)
        let row = try XCTUnwrap(hosted.model.rows(for: .backlog).first)
        hosted.window.displayIfNeeded()
        let frame = try XCTUnwrap(hosted.pointer.frame(for: TasksRowID(tab: .backlog, id: row.id)), "Later's first row laid out")
        // The pointer's frames are in the page's space, which is the hosted
        // window's content (top-left origin).
        let local = NSPoint(x: frame.midX, y: content.isFlipped ? frame.midY : content.bounds.height - frame.midY)
        let screen = hosted.window.convertPoint(toScreen: content.convert(local, to: nil))
        let hit = try XCTUnwrap(AtticPanelHostingView.topmostElement(in: content, at: screen) as AnyObject?,
                                "the walk finds an element at the row's centre")
        var hosts: [KeptContentHostingView] = []
        var node: AnyObject? = hit
        var depth = 0
        while let current = node, depth < 64 {
            if let host = current as? KeptContentHostingView { hosts.append(host) }
            node = (current.accessibilityParent?() ?? nil) as AnyObject?
            depth += 1
        }
        XCTAssertFalse(hosts.contains { !$0.isInteractive }, "nothing from a host not in use")
    }

    /// Condition 3 and HB-02: after a switch the page acts on the tab
    /// shown's focus. Arrows move the ring on the tab shown only.
    func testArrowsMoveTheKeyboardOnTheTabShownAfterASwitch() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" else {
            throw XCTSkip("key window only: real key events need a key panel")
        }
        let hosted = try warmed()
        defer { hosted.close() }
        hosted.press("\u{F701}", keyCode: 125)
        hosted.spin(0.3)
        XCTAssertEqual(hosted.model.keyboardFocus?.page, TasksTab.now.rawValue, "↓ on Now reaches a Now row")
        hosted.go(to: .backlog)
        XCTAssertNotEqual(hosted.model.keyboardFocus?.page, TasksTab.now.rawValue, "Now's row let go on leaving")
        hosted.press("\u{F701}", keyCode: 125)
        hosted.spin(0.3)
        XCTAssertEqual(hosted.model.keyboardFocus?.page, TasksTab.backlog.rawValue, "↓ on Later reaches a Later row")
        hosted.go(to: .now)
        hosted.press("\u{F701}", keyCode: 125)
        hosted.spin(0.3)
        XCTAssertEqual(hosted.model.keyboardFocus?.page, TasksTab.now.rawValue, "and on Now again")
    }
}
