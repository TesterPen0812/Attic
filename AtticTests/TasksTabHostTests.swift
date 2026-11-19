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

    /// TAB-STALL (host-boundary.md §5.1): a switch made by code inside
    /// `withAnimation`, outside an event, reaches the page: its body reads the
    /// new tab. At e6bf266c the tab's publish went out before the store, a
    /// synchronous flush ran the page's body with the old tab, and nothing
    /// published again: the tab bar, the search field and the shown index
    /// stayed on the old tab (hb-ab2 run 4; 14 of 64 switches in hb-ab).
    func testCodeDrivenAnimatedSwitchesReachThePage() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" else {
            throw XCTSkip("key window only")
        }
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1.5)
        var stalls: [String] = []
        var runs: [Int] = []
        TasksPageRenderProbe.announcedReads = (0, 0)
        TasksPageRenderProbe.staleReads = (0, 0)
        for (n, tab) in Array(repeating: [TasksTab.backlog, .now], count: 8).joined().enumerated() {
            let before = TasksPageRenderProbe.bodyRuns
            withAnimation(AtticMotionPreset.slide.animation(reduceMotion: false)) { hosted.model.select(tab: tab) }
            let deadline = Date().addingTimeInterval(3)
            while TasksPageRenderProbe.lastTab != tab, Date() < deadline { hosted.spin(0.05) }
            if TasksPageRenderProbe.lastTab != tab { stalls.append("\(n):\(tab)") }
            hosted.spin(0.5)
            runs.append(TasksPageRenderProbe.bodyRuns - before)
        }
        let announced = TasksPageRenderProbe.announcedReads, stale = TasksPageRenderProbe.staleReads
        print("TAB-STALL body runs per switch \(runs) total \(runs.reduce(0, +)); read inside the announcement: page \(announced.page) tab bar \(announced.tabBar); old tab: page \(stale.page) tab bar \(stale.tabBar)")
        // The mechanism, whenever the flush in the announcement happens (its
        // per-run trigger is unnamed, HB-SYNC-FLUSH-UNNAMED): no read of the
        // old tab there.
        XCTAssertEqual(stale.page, 0, "the page's body never reads the old tab inside the tab's announcement")
        XCTAssertEqual(stale.tabBar, 0, "the tab bar never reads the old tab inside the tab's announcement")
        XCTAssertEqual(stalls, [], "every switch reaches the page's body with the new tab")
    }

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

    /// An assistive client starting, stopping and starting again while
    /// Later is hidden (VoiceOver turned on, off and on), then a switch:
    /// the panel's hit walk reaches Later's row, inside Later's host.
    func testTheHitWalkReachesTheShownTabsRowAfterAnAssistiveClientRestartsWhileItIsHidden() throws {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let hosted = try warmed()
        defer { hosted.close() }
        let content = try XCTUnwrap(hosted.window.contentView)
        for on in [true, false, true] {
            NSApp.accessibilitySetValue(on, forAttribute: enhanced)
            // A client's read of the panel, as an assistive client makes.
            _ = content.accessibilityChildren()
            hosted.spin(0.5)
        }
        let departing = try inUse(hosted)
        hosted.go(to: .backlog)
        try waitForTheSwitch(hosted, to: "Later", from: departing, joined: true)
        let row = try XCTUnwrap(hosted.model.rows(for: .backlog).first)
        hosted.window.displayIfNeeded()
        let frame = try XCTUnwrap(hosted.pointer.frame(for: TasksRowID(tab: .backlog, id: row.id)), "Later's first row laid out")
        let local = NSPoint(x: frame.midX, y: content.isFlipped ? frame.midY : content.bounds.height - frame.midY)
        let screen = hosted.window.convertPoint(toScreen: content.convert(local, to: nil))
        let hit = try XCTUnwrap(AtticPanelHostingView.topmostElement(in: content, at: screen) as AnyObject?,
                                "the walk finds an element at Later's row")
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

    private func hitWalk() throws {
        let hosted = try warmed()
        defer { hosted.close() }
        let departing = try inUse(hosted)
        hosted.go(to: .backlog)
        try waitForTheSwitch(hosted, to: "Later", from: departing, joined: true)
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

    // MARK: Keyboard ownership (host-boundary.md §5.1, one test per row)

    private func keyWindowOnly() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" else {
            throw XCTSkip("key window only: real key events need a key panel")
        }
    }

    /// The tab host holding the window's keyboard, if any.
    private func keyboardHost(_ hosted: Hosted) -> KeptContentHostingView? {
        guard let view = hosted.window.firstResponder as? NSView else { return nil }
        return (view as? KeptContentHostingView) ?? KeptContentHostingView.enclosing(view)
    }

    private func inUse(_ hosted: Hosted) throws -> KeptContentHostingView {
        try XCTUnwrap(hosts(hosted).first(where: \.isInteractive), "a tab host in use")
    }

    private func down(_ hosted: Hosted) {
        hosted.press("\u{F701}", keyCode: 125)
        hosted.spin(0.3)
    }

    /// ↓ on Now: a Now row has the keyboard, inside Now's host.
    private func focusANowRow(_ hosted: Hosted, line: UInt = #line) throws {
        down(hosted)
        XCTAssertEqual(hosted.model.keyboardFocus?.page, TasksTab.now.rawValue, "↓ on Now reaches a Now row", line: line)
        XCTAssertTrue(keyboardHost(hosted) === (try inUse(hosted)), "the keyboard is in Now's host", line: line)
    }

    private struct TheSwitchNeverLanded: Error {}

    /// Waits, up to `timeout`, for a switch to land: the arriving tab's host
    /// in use (and, with `joined`, joined to accessibility). Never the
    /// keyboard's claim: that is what the ownership rows assert. It polls
    /// only (no layout, display or accessibility call), so the walk stays
    /// the first accessibility read. A switch that never applies fails here,
    /// by name: that is how the tab stall was found (host-boundary.md §5.1,
    /// TAB-STALL), where the page's body read the old tab.
    private func waitForTheSwitch(_ hosted: Hosted, to tab: String, from departing: KeptContentHostingView,
                                  joined: Bool, timeout: TimeInterval = 3, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let host = hosts(hosted).first(where: \.isInteractive), host !== departing, !joined || host.isAccessible { return }
            hosted.spin(0.05)
        } while Date() < deadline
        XCTFail("the switch never reached \(tab)'s host", line: line)
        throw TheSwitchNeverLanded()
    }

    private func assertTheArrivingTabHasTheKeyboard(_ hosted: Hosted, _ tab: TasksTab, line: UInt = #line) throws {
        XCTAssertTrue(keyboardHost(hosted) === (try inUse(hosted)), "the arriving tab's host claimed the keyboard: \(String(describing: hosted.window.firstResponder))", line: line)
        down(hosted)
        XCTAssertEqual(hosted.model.keyboardFocus?.page, tab.rawValue, "↓ reaches a row of the arriving tab", line: line)
    }

    func testOwnershipTabBarSwitchMovesTheKeyboardToTheArrivingTab() throws {
        try keyWindowOnly()
        let hosted = try warmed()
        defer { hosted.close() }
        try focusANowRow(hosted)
        var departing = try inUse(hosted)
        hosted.go(to: .backlog)
        try waitForTheSwitch(hosted, to: "Later", from: departing, joined: false)
        try assertTheArrivingTabHasTheKeyboard(hosted, .backlog)
        departing = try inUse(hosted)
        hosted.go(to: .now)
        try waitForTheSwitch(hosted, to: "Now", from: departing, joined: false)
        try assertTheArrivingTabHasTheKeyboard(hosted, .now)
    }

    func testOwnershipTheRootKeepsTheKeyboardAcrossASwitch() throws {
        try keyWindowOnly()
        let hosted = try warmed()
        defer { hosted.close() }
        XCTAssertNil(keyboardHost(hosted), "the panel's host has the keyboard (its tab bar, or nothing focused)")
        let before = hosted.window.firstResponder
        hosted.go(to: .backlog)
        XCTAssertNil(keyboardHost(hosted), "no claim from the panel's host")
        XCTAssertTrue(hosted.window.firstResponder === before, "the keyboard stays where it was")
        down(hosted)
        XCTAssertEqual(hosted.model.keyboardFocus?.page, TasksTab.backlog.rawValue, "↓ still reaches the shown tab's rows")
    }

    func testOwnershipSwipeMovesTheKeyboardToTheArrivingTab() throws {
        try keyWindowOnly()
        let hosted = try warmed()
        defer { hosted.close() }
        try focusANowRow(hosted)
        let departing = try inUse(hosted)
        withAnimation(AtticMotionPreset.slide.animation(reduceMotion: false)) { hosted.model.select(tab: .backlog, bySwipe: true) }
        hosted.spin(1.2)
        try waitForTheSwitch(hosted, to: "Later", from: departing, joined: false)
        try assertTheArrivingTabHasTheKeyboard(hosted, .backlog)
    }

    func testOwnershipPageAwayAndBack() throws {
        try keyWindowOnly()
        let hosted = try warmed()
        defer { hosted.close() }
        try focusANowRow(hosted)
        hosted.model.isPageShown = false
        hosted.spin(0.3)
        XCTAssertNil(keyboardHost(hosted), "a page not shown holds no keyboard")
        hosted.model.isPageShown = true
        hosted.spin(0.3)
        try assertTheArrivingTabHasTheKeyboard(hosted, .now)
    }

    func testOwnershipPanelHideAndShowKeepsTheKeyboard() throws {
        try keyWindowOnly()
        let hosted = try warmed()
        defer { hosted.close() }
        try focusANowRow(hosted)
        let holder = keyboardHost(hosted)
        hosted.window.orderOut(nil)
        hosted.spin(0.2)
        hosted.window.orderFront(nil)
        hosted.window.makeKey()
        hosted.spin(0.3)
        XCTAssertTrue(keyboardHost(hosted) === holder, "the same host has the keyboard again")
        down(hosted)
        XCTAssertEqual(hosted.model.keyboardFocus?.page, TasksTab.now.rawValue)
    }

    func testOwnershipNoClaimWhileThePanelIsNotKey() throws {
        try keyWindowOnly()
        let hosted = try warmed()
        defer { hosted.close() }
        try focusANowRow(hosted)
        let other = NSWindow(contentRect: CGRect(x: -3_000, y: -3_000, width: 80, height: 80),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        other.makeKeyAndOrderFront(nil)
        hosted.spin(0.2)
        XCTAssertFalse(hosted.window.isKeyWindow)
        hosted.go(to: .backlog)
        XCTAssertNil(keyboardHost(hosted), "a panel that is not key: no host claims")
    }

    func testOwnershipTypingContinuesAcrossASwitch() throws {
        try keyWindowOnly()
        let hosted = try Hosted(height: 520, addBarFocused: true)
        defer { hosted.close() }
        hosted.spin(1.5)
        let editor = try XCTUnwrap(hosted.window.firstResponder as? NSTextView, "the add bar has the keyboard")
        hosted.go(to: .backlog)
        XCTAssertTrue(hosted.window.firstResponder === editor, "no claim from a text editor")
        hosted.press("a", keyCode: 0)
        XCTAssertTrue(editor.string.contains("a"), "typing goes on: \(editor.string)")
    }

    /// The user's sequence (judged "no worse than the trunk"): ↓ on Now,
    /// a rename, then a switch: the switch saves the rename and Later is
    /// shown, as on the trunk. Where ↓ goes next is pinned in
    /// `TasksRound13Tests` (KB-DOWN-AFTER-RENAME-SWITCH).
    func testOwnershipRenameIsSavedByTheSwitch() throws {
        try keyWindowOnly()
        let hosted = try warmed()
        defer { hosted.close() }
        down(hosted)
        let row = try XCTUnwrap(hosted.model.keyboardFocus?.id, "↓ on Now reaches a Now row")
        hosted.model.beginEditingTitle(row)
        hosted.spin(0.4)
        XCTAssertEqual(hosted.model.editingTitleID, row, "the rename is open")
        hosted.go(to: .backlog)
        XCTAssertNil(hosted.model.editingTitleID, "the switch saved the rename")
        XCTAssertEqual(hosted.model.tab, .backlog, "Later is shown")
    }

    /// The user's sequence (the lead, 19 Nov: rows are judged "no worse
    /// than the trunk"): ↓ on Now, then a responder outside the tabs (as a
    /// dropdown's host) takes the keyboard, then a switch. It keeps the
    /// keyboard, as on the trunk (`TasksRound13Tests`, run on `4b55a9e8`).
    func testOwnershipNoClaimFromAResponderOutsideTheTabHosts() throws {
        final class StandIn: NSView { override var acceptsFirstResponder: Bool { true } }
        try keyWindowOnly()
        let hosted = try warmed()
        defer { hosted.close() }
        down(hosted)
        XCTAssertEqual(hosted.model.keyboardFocus?.page, TasksTab.now.rawValue, "↓ on Now reaches a Now row")
        let standIn = StandIn(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        hosted.window.contentView?.addSubview(standIn)
        defer { standIn.removeFromSuperview() }
        XCTAssertTrue(hosted.window.makeFirstResponder(standIn))
        hosted.spin(0.2)
        XCTAssertTrue(hosted.window.firstResponder === standIn, "it holds the keyboard before the switch")
        hosted.go(to: .backlog)
        XCTAssertTrue(hosted.window.firstResponder === standIn, "no claim from it: \(String(describing: hosted.window.firstResponder))")
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
