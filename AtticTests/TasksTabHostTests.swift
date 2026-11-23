import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Each Tasks tab in its own host (ops/design/host-boundary.md, step 1):
/// the tab in use takes input and is read; the others keep their hosts and
/// rows, get no new root on updates, and are never reached by a click, a
/// key or the panel's accessibility hit walk.
@MainActor
final class TasksTabHostTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { TasksRowStateCounts.reset() }
    }

    override func tearDown() async throws {
        await MainActor.run { assertNoRowStateWriteDuringAReadAndNoLateCatchUp() }
        try await super.tearDown()
    }

    private func hosts(_ hosted: Hosted) -> [KeptContentHostingView] {
        func walk(_ view: NSView) -> [KeptContentHostingView] {
            if let host = view as? KeptContentHostingView { return [host] }
            return view.subviews.flatMap(walk)
        }
        guard let content = hosted.window.contentView else { return [] }
        content.layoutSubtreeIfNeeded()
        return walk(content)
    }

    /// Every tab kept built, each in its own host. Warming waits for idle
    /// input, so this waits, bounded, for the span and the three hosts.
    private func warmed(laterRows: Int = 0, atticPanel: Bool = false, followsWindow: Bool = false,
                        line: UInt = #line) throws -> Hosted {
        let hosted = try Hosted(height: 520, atticPanel: atticPanel, followsWindow: followsWindow)
        for index in 0..<laterRows { _ = hosted.store.create(title: "Later \(index + 1)", status: .backlog) }
        waitForTestOperation("every tab kept built, each in its own host", line: line) {
            hosted.spin(0.05)
            return hosted.model.pagerSwipe.span.warm == 0...2 && hosts(hosted).count == TasksTab.allCases.count
        }
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
    /// PR 41: only a root that moves the list's rows is laid out in the pass
    /// that sets it. A row click's root moves none, so AppKit lays the host
    /// in use out once, with the click's focus change; laid out as it was
    /// set, the host was laid out a second time for that change.
    func testOnlyARootThatMovesRowsIsLaidOutInThePassThatSetsIt() throws {
        let hosted = try warmed()
        defer { hosted.close() }
        hosted.spin(0.5)
        let rows = hosted.model.rows(for: .now).filter { $0.status != .done }
        XCTAssertGreaterThanOrEqual(rows.count, 2, "two rows to click in turn")
        for round in 0..<5 {
            KeptContentHostCounts.reset()
            try hosted.clickRow(rows[round % 2].id, tab: .now)
            hosted.spin(0.4)
            // The first click also brings the keyboard to the list.
            guard round > 0 else { continue }
            let roots = KeptContentHostCounts.roots.on
            XCTAssertGreaterThan(roots, 0, "click \(round) set the root of the host in use, so the counts mean something")
            XCTAssertEqual(KeptContentHostCounts.laidOutInSet, 0, "click \(round) moved no row: its root is left to AppKit's pass")
            // One root a click alone; a late update in the same wait sets
            // another, with a pass of its own.
            XCTAssertLessThanOrEqual(KeptContentHostCounts.layouts.on, roots, "click \(round): the host in use is laid out once a root")
            print("ROWCLICK click=\(round) roots_on=\(roots) layouts_on=\(KeptContentHostCounts.layouts.on) laid_out_in_set=\(KeptContentHostCounts.laidOutInSet)")
        }
        KeptContentHostCounts.reset()
        XCTAssertNotNil(hosted.store.create(title: "One more row"))
        hosted.spin(0.4)
        XCTAssertGreaterThan(KeptContentHostCounts.laidOutInSet, 0, "a root that adds a row is laid out in the pass that sets it")
    }

    /// PR 41 review B1: Done draws its own list (`TasksDonePage`), not the
    /// row list the other tabs share, so its host is handed no ids. While
    /// Done is shown, a store change (here a task restored from Done)
    /// builds no shared row list for it and lays its host out in no set pass.
    func testAStoreChangeWhileDoneIsShownBuildsNoSharedRowListAndNoSetPassLayout() throws {
        let hosted = try warmed()
        defer { hosted.close() }
        let id = try XCTUnwrap(hosted.store.create(title: "Restored from Done")).id
        hosted.spin(0.2)
        hosted.model.setStatus(.done, for: [id])
        hosted.spin(2.0)
        hosted.go(to: .done)
        hosted.spin(0.6)
        let missesBefore = hosted.model.rowsCacheMissCount[.done, default: 0]
        KeptContentHostCounts.reset()
        hosted.model.setStatus(.todo, for: [id])
        hosted.spin(0.6)
        XCTAssertGreaterThan(KeptContentHostCounts.roots.on, 0, "the change set the root of the Done host, so the counts mean something")
        XCTAssertEqual(hosted.model.rowsCacheMissCount[.done, default: 0], missesBefore,
                       "no shared row list is built for Done, which never draws one")
        XCTAssertEqual(KeptContentHostCounts.laidOutInSet, 0, "the Done host is left to AppKit's pass")
    }

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
    // MARK: Hidden tab hosts do no work (speed/hidden-host-no-layout)

    /// Each host's own layout count since the last reset, in tab order.
    private func layoutCounts(_ tabHosts: [KeptContentHostingView]) -> [Int] {
        tabHosts.map { KeptContentHostCounts.layoutsByHost[ObjectIdentifier($0), default: 0] }
    }

    /// What one action reached: each host's layouts in tab order, hidden
    /// tabs' row bodies, the environments the hosts' content took as new,
    /// and the hosts' updates (both split drawn or hidden).
    private struct HiddenHostReach {
        let label: String
        let layouts: [Int]
        let hiddenLeaves: Int
        let environments: KeptContentHostCounts.Split
        let updates: KeptContentHostCounts.Split
    }

    /// Row clicks on Now (moving focus and staying) and a resize, with
    /// Later and Done hidden; what each reached, recorded and printed.
    private func reachOfClicksAndAResize() throws -> [HiddenHostReach] {
        let hosted = try warmed(followsWindow: true)
        defer { hosted.close() }
        hosted.spin(0.5)
        let tabHosts = hosts(hosted)
        XCTAssertEqual(tabHosts.map(\.isInteractive), [true, false, false], "Now is shown; Later and Done are hidden")
        let rows = hosted.model.rows(for: .now).filter { $0.status != .done }
        XCTAssertGreaterThanOrEqual(rows.count, 2, "two rows to click in turn")
        guard rows.count >= 2 else { return [] }
        // The first click also brings the keyboard to the list.
        try hosted.clickRow(rows[0].id, tab: .now)
        hosted.spin(0.4)
        TasksCellBodyCounts.records = true
        defer { TasksCellBodyCounts.records = false }
        func measure(_ label: String, _ action: () throws -> Void) rethrows -> HiddenHostReach {
            KeptContentHostCounts.reset()
            TasksCellBodyCounts.leaves = [:]
            try action()
            let reach = HiddenHostReach(label: label, layouts: layoutCounts(tabHosts),
                                        hiddenLeaves: TasksCellBodyCounts.leaves.filter { $0.key.tab != .now }.values.reduce(0, +),
                                        environments: KeptContentHostCounts.environments,
                                        updates: KeptContentHostCounts.updates)
            print("HIDDEN_HOST \(label) now=\(reach.layouts[0]) later=\(reach.layouts[1]) done=\(reach.layouts[2]) hidden_leaves=\(reach.hiddenLeaves) env_drawn=\(reach.environments.on) env_hidden=\(reach.environments.off) updates_drawn=\(reach.updates.on) updates_hidden=\(reach.updates.off)")
            return reach
        }
        var reaches: [HiddenHostReach] = []
        for (label, row) in [("click-move-1", rows[1]), ("click-stay-1", rows[1]),
                             ("click-move-2", rows[0]), ("click-stay-2", rows[0])] {
            reaches.append(try measure(label) {
                try hosted.clickRow(row.id, tab: .now)
                hosted.spin(0.4)
            })
        }
        reaches.append(measure("resize") { resize(hosted) })
        // One size write at a time, as a corner drag's frames come.
        for step in 1...3 {
            reaches.append(measure("size-write-\(step)") { resize(hosted, steps: 1) })
        }
        return reaches
    }

    /// rows-rerun-fable.md, probe 3 (Air preview, unqueried): on every size
    /// write and every click's action pass the two hidden hosts' content was
    /// handed a rebuilt environment, the same values with a new identity, so
    /// every environment reader in a hidden tab re-checked (2 a size write,
    /// one a hidden host). A hidden host's content is handed back the value
    /// it had; the shown host's still takes each new one.
    func testHiddenTabHostsTakeNoNewEnvironmentOnRowClicksAndSizeWrites() throws {
        let reaches = try reachOfClicksAndAResize()
        for reach in reaches {
            XCTAssertEqual(reach.environments.off, 0, "\(reach.label): a hidden host's content took a new environment")
        }
        let clicks = reaches.filter { $0.label.hasPrefix("click") }
        XCTAssertGreaterThan(clicks.map(\.environments.on).reduce(0, +), 0,
                             "the shown host's content still takes a new environment on clicks (the counter counts)")
        XCTAssertGreaterThan(clicks.map(\.updates.off).reduce(0, +), 0,
                             "the hidden hosts were updated on clicks, so their zero means something")
        // Size writes: this host's size writes replaced no hidden
        // environment on the trunk either (a3829c89), so this half guards
        // nothing yet; the preview's 2 a size write is not reproduced here.
        for write in reaches.filter({ $0.label.hasPrefix("size-write") }) {
            XCTAssertGreaterThan(write.environments.on, 0, "\(write.label): the shown host's content took no new environment")
            XCTAssertGreaterThan(write.updates.off, 0, "\(write.label): the hidden hosts were not updated")
        }
    }

    /// Air, PR 41 844907fb (-O, queried): the hidden Later and Done hosts
    /// each laid out once on every row click, moving focus or not, and about
    /// as often as the shown host on every resize frame
    /// (job1-ax-focus-per-click.md, "Why the whole host lays out"). A hidden
    /// host lays out on neither and runs no row; the shown host still lays out.
    func testHiddenTabHostsRunNoLayoutOnRowClicksAndAResize() throws {
        let reaches = try reachOfClicksAndAResize()
        for reach in reaches {
            XCTAssertEqual(reach.layouts[1], 0, "\(reach.label): the hidden Later host laid out")
            XCTAssertEqual(reach.layouts[2], 0, "\(reach.label): the hidden Done host laid out")
            XCTAssertEqual(reach.hiddenLeaves, 0, "\(reach.label): a hidden tab's row ran")
        }
        let clicks = reaches.filter { $0.label.hasPrefix("click") }.map { $0.layouts[0] }.reduce(0, +)
        XCTAssertGreaterThan(clicks, 0, "the shown host still lays out on row clicks")
        XCTAssertGreaterThan(reaches.first { $0.label == "resize" }?.layouts[0] ?? 0, 0, "the shown host still lays out on a resize")
    }

    /// Records each host's layouts on a tab switch, plain, after row clicks
    /// and straight after a resize (PR 41 recorded 20 to 21 in use). The
    /// lead compares these before and after a change to the hidden hosts.
    func testTabSwitchLayoutCountsAreRecorded() throws {
        let hosted = try warmed(followsWindow: true)
        defer { hosted.close() }
        hosted.spin(0.5)
        let tabHosts = hosts(hosted)
        func switchTo(_ tab: TasksTab, _ label: String) {
            KeptContentHostCounts.reset()
            hosted.go(to: tab)
            let counts = layoutCounts(tabHosts)
            print("TAB_SWITCH \(label) now=\(counts[0]) later=\(counts[1]) done=\(counts[2]) on=\(KeptContentHostCounts.layouts.on) off=\(KeptContentHostCounts.layouts.off) laid_out_in_set=\(KeptContentHostCounts.laidOutInSet) roots_on=\(KeptContentHostCounts.roots.on)")
            // Every switch here is between Now and Later: Done is hidden
            // throughout and lays out on none (19 a switch before the fix).
            XCTAssertEqual(counts[2], 0, "\(label): the hidden Done host laid out during the switch")
        }
        switchTo(.backlog, "plain-to-later")
        XCTAssertEqual(tabHosts.map(\.isInteractive), [false, true, false], "the hosts are in tab order")
        switchTo(.now, "plain-to-now")
        let rows = hosted.model.rows(for: .now).filter { $0.status != .done }
        for row in rows.prefix(2) {
            try hosted.clickRow(row.id, tab: .now)
            hosted.spin(0.3)
        }
        switchTo(.backlog, "after-clicks-to-later")
        switchTo(.now, "after-clicks-to-now")
        resize(hosted)
        switchTo(.backlog, "after-resize-to-later")
        switchTo(.now, "after-resize-to-now")
    }

    /// Records what warming builds in the hidden hosts, and what the first
    /// switch to a warmed Later then runs (its rows' bodies and layouts):
    /// a hidden host that holds its layouts must still be built by warming.
    func testWarmingBuildsTheHiddenTabsAndTheFirstSwitchIsRecorded() throws {
        KeptContentHostCounts.reset()
        TasksCellBodyCounts.records = true
        TasksCellBodyCounts.leaves = [:]
        defer { TasksCellBodyCounts.records = false }
        let hosted = try warmed(laterRows: 4, followsWindow: true)
        defer { hosted.close() }
        hosted.spin(0.8)
        let tabHosts = hosts(hosted)
        func leaves(_ tab: TasksTab) -> Int { TasksCellBodyCounts.leaves.filter { $0.key.tab == tab }.values.reduce(0, +) }
        func rowsBuilt(_ tab: TasksTab) -> Int { TasksCellBodyCounts.leaves.keys.filter { $0.tab == tab }.count }
        var counts = layoutCounts(tabHosts)
        print("WARM built now=\(counts[0]) later=\(counts[1]) done=\(counts[2]) later_rows=\(rowsBuilt(.backlog)) later_leaves=\(leaves(.backlog))")
        XCTAssertGreaterThan(counts[1], 0, "warming lays the hidden Later host out")
        XCTAssertGreaterThan(rowsBuilt(.backlog), 0, "warming builds Later's rows")
        KeptContentHostCounts.reset()
        TasksCellBodyCounts.leaves = [:]
        hosted.go(to: .backlog)
        counts = layoutCounts(tabHosts)
        print("WARM first-switch now=\(counts[0]) later=\(counts[1]) done=\(counts[2]) later_rows=\(rowsBuilt(.backlog)) later_leaves=\(leaves(.backlog))")
    }
    #endif

    // MARK: A hidden tab is right in its first frame

    /// Widens and lengthens the window in steps, as a corner drag does
    /// (the top stays put, so the page's clicks keep their places).
    private func resize(_ hosted: Hosted, steps: Int = 8, by step: CGFloat = 6) {
        for _ in 0..<steps {
            var frame = hosted.window.frame
            frame.size.width += step
            frame.size.height += step
            frame.origin.y -= step
            hosted.window.setFrame(frame, display: true)
            hosted.spin(0.03)
        }
        hosted.spin(0.2)
    }

    /// The Later list as drawn: the width of its list and each row's frame
    /// in its slot, by title.
    private struct LaterDrawing: Equatable {
        var listWidth: CGFloat
        var listHeight: CGFloat
        var rows: [String: CGRect]
        var summary: String {
            "list=\(listWidth)x\(listHeight) rows=\(rows.count) " + rows.sorted { $0.value.minY < $1.value.minY }
                .prefix(3).map { "\($0.key)@\(Int($0.value.minX)),\(Int($0.value.minY)),\(Int($0.value.width))x\(Int($0.value.height))" }
                .joined(separator: " ")
        }
    }

    /// `tracked`: rows read by id whether or not the model still lists them
    /// (a row ticked or deleted while the tab was not drawn must have no
    /// frame once it is drawn again).
    private func laterDrawing(_ hosted: Hosted, host: KeptContentHostingView, tab: TasksTab = .backlog,
                              tracked: [UUID: String] = [:]) -> LaterDrawing {
        let list = hosted.lists(in: host).filter { !$0.isHidden }.max { $0.frame.height < $1.frame.height }
        var rows: [String: CGRect] = [:]
        // Done draws its own list, by day (`TasksDonePage`).
        let listed = tab == .done ? hosted.model.doneDays().flatMap(\.rows) : hosted.model.rows(for: tab)
        var titles = tracked
        for row in listed { titles[row.id] = row.model.title }
        for (id, title) in titles {
            guard let frame = hosted.pointer.frame(for: TasksRowID(tab: tab, id: id)) else { continue }
            // The pointer adds the slide's offset and this takes it off
            // again: rounded to a thousandth of a point, so the arithmetic's
            // 1e-14 is not read as a move.
            let local = frame.offsetBy(dx: -hosted.pointer.pageOffset(tab), dy: 0)
            func round(_ value: CGFloat) -> CGFloat { (value * 1000).rounded() / 1000 }
            rows[title] = CGRect(x: round(local.minX), y: round(local.minY), width: round(local.width), height: round(local.height))
        }
        return LaterDrawing(listWidth: list?.frame.width ?? -1, listHeight: list?.frame.height ?? -1, rows: rows)
    }

    /// Makes `change` while Later is hidden, switches to Later, and reads the
    /// list in the switch's first frame. It must equal the list once
    /// settled (no stale frame, no one-frame jump) and a Later list shown
    /// throughout the same change.
    /// `matchesRows` false: a tab shown keeps a row completed on it for a
    /// while, and a hidden one drops it at once, so only the width is
    /// compared with the tab shown throughout.
    /// `from`: the tab shown while the change is made (Now is let go when
    /// Done is shown). Every row the tab listed before the change is read
    /// in each frame, listed or not: until 22 Nov this read only the rows
    /// the model still listed, so a row ticked while Now was not drawn and
    /// still drawn in Now's first frame back went unread.
    /// `resizes` false: the change leaves the list's size alone and changes
    /// its rows.
    private func checkLatersFirstFrame(_ label: String, tab: TasksTab = .backlog, from: TasksTab? = nil,
                                       matchesRows: Bool = true, resizes: Bool = true,
                                       after change: (Hosted) throws -> Void) throws {
        let reference = try warmed(laterRows: 4, followsWindow: true)
        defer { reference.close() }
        let slot = try XCTUnwrap(TasksTab.allCases.firstIndex(of: tab))
        reference.go(to: tab)
        let referenceHost = hosts(reference)[slot]
        let before = laterDrawing(reference, host: referenceHost, tab: tab)
        try change(reference)
        reference.spin(0.6)
        // A row ticked on the tab shown is held in its place for a while
        // (`TasksPageModel.hold`); the reference is read once it has gone.
        for id in reference.model.held.keys { reference.model.releaseHold(id) }
        reference.spin(0.6)
        let expected = laterDrawing(reference, host: referenceHost, tab: tab)
        if resizes {
            XCTAssertNotEqual(expected.listHeight, before.listHeight, "\(label): the change resizes the list, so the first frame can be stale")
        } else {
            XCTAssertNotEqual(Set(expected.rows.keys), Set(before.rows.keys), "\(label): the change changes the rows, so the first frame can be stale")
        }

        let hosted = try warmed(laterRows: 4, followsWindow: true)
        defer { hosted.close() }
        hosted.spin(0.3)
        let laterHost = hosts(hosted)[slot]
        if let from { hosted.go(to: from) }
        XCTAssertFalse(laterHost.isInteractive, "\(label): the tab is hidden")
        let listed = tab == .done ? hosted.model.doneDays().flatMap(\.rows) : hosted.model.rows(for: tab)
        let tracked = Dictionary(listed.map { ($0.id, $0.model.title) }, uniquingKeysWith: { first, _ in first })
        try change(hosted)
        hosted.spin(0.6)
        withAnimation(AtticMotionPreset.slide.animation(reduceMotion: false)) { hosted.model.select(tab: tab) }
        // The app's own frames: each turn of the run loop commits, and the
        // commit runs the window's layout and display; nothing is laid out
        // by hand. Read once a turn, after the commit (before the loop
        // waits), until the slide has ended and two turns read the same.
        var drawings: [LaterDrawing] = []
        let sampler = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_100_000) { _, _ in
            MainActor.assumeIsolated { drawings.append(self.laterDrawing(hosted, host: laterHost, tab: tab, tracked: tracked)) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), sampler, .commonModes)
        waitForTestOperation("\(label): the slide to the tab ends and its list settles") {
            hosted.model.pagerSwipe.motion.position == CGFloat(slot) && drawings.count >= 2
                && drawings[drawings.count - 1] == drawings[drawings.count - 2] && drawings[drawings.count - 1].listWidth > 0
        }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), sampler, .commonModes)
        CFRunLoopObserverInvalidate(sampler)
        let settled = drawings.last ?? laterDrawing(hosted, host: laterHost, tab: tab, tracked: tracked)
        let shown = drawings.firstIndex { $0.listWidth > 0 }
        let first = shown.map { drawings[$0] } ?? settled
        let differing = shown.map { drawings[$0...].filter { $0 != settled }.count } ?? -1
        print("FIRST_FRAME \(label) first_drawn_read=\(shown ?? -1) of \(drawings.count) differing_after=\(differing) first=\(first.summary) | settled=\(settled.summary) | reference=\(expected.summary)")
        if let shown {
            for (index, drawing) in drawings.enumerated().dropFirst(shown) where drawing != settled {
                let rows = drawing.rows.filter { settled.rows[$0.key] != $0.value }
                    .map { "\($0.key)@\($0.value) settled \(settled.rows[$0.key].map { "\($0)" } ?? "absent")" }
                let gone = settled.rows.keys.filter { drawing.rows[$0] == nil }
                print("FIRST_FRAME_DIFF \(label) read=\(index) list=\(drawing.listWidth)x\(drawing.listHeight) rows=\(rows.prefix(4)) missing=\(gone.prefix(4))")
            }
        }
        XCTAssertNotNil(shown, "\(label): Later's list is drawn during the switch")
        XCTAssertEqual(Set(first.rows.keys).subtracting(settled.rows.keys), [],
                       "\(label): no row that left while the tab was not drawn is drawn in its first frame back")
        XCTAssertEqual(Set(settled.rows.keys).subtracting(first.rows.keys), [],
                       "\(label): every row the tab settles with is drawn in its first frame back")
        XCTAssertEqual(differing, 0, "\(label): from its first drawn frame on, Later's list never differs from its settled state (no stale frame, no jump)")
        XCTAssertGreaterThan(settled.rows.count, 0, "\(label): Later has rows to compare")
        XCTAssertEqual(first.listWidth, settled.listWidth, "\(label): the list's width in the first frame")
        XCTAssertEqual(first.listHeight, settled.listHeight, "\(label): the list's height in the first frame")
        XCTAssertEqual(first.rows, settled.rows, "\(label): the rows' frames in the first frame")
        XCTAssertEqual(settled.listWidth, expected.listWidth, "\(label): the list's width matches a Later shown throughout")
        XCTAssertEqual(settled.listHeight, expected.listHeight, "\(label): the list's height matches a Later shown throughout")
        if matchesRows, tab == .done {
            // Two windows seeded apart can order Done's ties differently
            // (inferred: same-day rows by completion time, stamped at each
            // seed), so Done is matched by its titles and its row geometry.
            XCTAssertEqual(Set(settled.rows.keys), Set(expected.rows.keys), "\(label): the rows match a Done shown throughout")
            let places = { (drawing: LaterDrawing) in drawing.rows.values.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) } }
            XCTAssertEqual(places(settled), places(expected), "\(label): the rows' places match a Done shown throughout")
        } else if matchesRows {
            XCTAssertEqual(settled.rows, expected.rows, "\(label): the rows match a Later shown throughout")
        }
    }

    func testLaterIsRightInItsFirstFrameAfterAResizeWhileHidden() throws {
        try checkLatersFirstFrame("resize") { resize($0, by: 6) }
    }

    /// Done holds its layouts while hidden too. Not red on the base: there
    /// a hidden host laid out at every resize step, so it was never stale.
    func testDoneIsRightInItsFirstFrameAfterAResizeWhileHidden() throws {
        try checkLatersFirstFrame("done-resize", tab: .done) { resize($0, by: 6) }
    }

    func testLaterIsRightInItsFirstFrameAfterARowIsAddedWhileHidden() throws {
        try checkLatersFirstFrame("add") { hosted in
            resize(hosted, by: 6)
            XCTAssertNotNil(hosted.store.create(title: "Added while Later is hidden", status: .backlog))
        }
    }

    func testLaterIsRightInItsFirstFrameAfterARowIsCompletedWhileHidden() throws {
        try checkLatersFirstFrame("complete", matchesRows: false) { hosted in
            resize(hosted, by: 6)
            let row = try XCTUnwrap(hosted.model.rows(for: .backlog).first { $0.status != .done })
            hosted.model.setStatus(.done, for: [row.id])
        }
    }

    // PR 48 takeover follow-up: a tab the pager's span draws (a swipe's
    // neighbour) after a store change made while it was not drawn. The
    // trunk draws that first frame right: its rows read the model.

    /// The rows `tabs` drew since `drawnRuns` was emptied are their listed
    /// rows, and the row states agree with the model.
    private func assertTheRowsDrawnAreTheRowsListed(_ step: String, _ hosted: Hosted, tabs: [TasksTab]) {
        for tab in tabs {
            let listed = tab == .done ? hosted.model.doneDays().flatMap(\.rows) : hosted.model.rows(for: tab)
            let rows = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let drawn = Set(TasksCellBodyCounts.drawnRuns.filter { $0.drawn && $0.row.tab == tab }.map(\.row))
            let checked = drawn.filter { rows[$0.id] != nil }
            XCTAssertTrue(!checked.isEmpty || listed.isEmpty, "\(step): \(tab) drew its rows in that frame, so the check means something")
            for row in checked {
                guard let listedRow = rows[row.id] else { continue }
                XCTAssertTrue(TasksCellBodyCounts.cellStates[row].map { TasksRowStateValue.sameRow($0.row, listedRow) } == true,
                              "\(step): \(tab)'s \(listedRow.model.title) draws its row as listed in that frame")
            }
        }
        XCTAssertEqual(hosted.model.rowStateMismatches(), [], "\(step): the states agree with the model in that frame")
    }

    /// Makes `change` while only the tab shown is drawn, starts a swipe and
    /// draws a frame. Each of `neighbours` is then in the span: its drawn
    /// rows must be its listed rows, no row state written during a list
    /// read and none catching up after the frame. `laidOut`: the frame is
    /// laid out and displayed at once, before the run loop turns (what a
    /// send of another transaction or AppKit's on-demand layout does);
    /// otherwise it is the app's own next frame, waited for by what it
    /// draws. The swipe is then let go where it began.
    private func checkASwipesNeighbours(_ name: String, _ hosted: Hosted, on shown: TasksTab, neighbours: [TasksTab],
                                        laidOut: Bool, change: () throws -> Void) rethrows {
        hosted.spin(0.8)
        let step = "\(name), \(laidOut ? "laid_out" : "own_frame")"
        XCTAssertEqual(hosted.model.tab, shown, "\(step): the tab shown")
        let span = hosted.model.pagerSwipe.span
        let slots = neighbours.compactMap { TasksTab.allCases.firstIndex(of: $0) }
        XCTAssertTrue(slots.allSatisfy { !span.pages.contains($0) }, "\(step): the neighbours are not drawn before the swipe")
        try change()
        hosted.spin(0.6)
        XCTAssertEqual(TasksRowStateCounts.lateCatchUps, 0, "\(step): the change itself is on time: \(TasksRowStateCounts.lateRoutes)")
        TasksRowStateCounts.reset()
        TasksCellBodyCounts.drawnRuns = []
        let passes = TasksPagerPassCount.passes
        var time = CACurrentMediaTime()
        func send(_ phase: TasksPagerSwipe.Sample.Phase, dx: CGFloat = 0) {
            time += 1.0 / 120
            _ = hosted.model.pagerScrolled(.init(phase: phase, momentum: false, dx: dx, dy: 0, time: time, precise: true),
                                           allowed: true)
        }
        send(.began)
        send(.changed, dx: -14)
        XCTAssertTrue(slots.allSatisfy { span.pages.contains($0) }, "\(step): the swipe put the neighbours in the span")
        if laidOut {
            hosted.window.contentView?.layoutSubtreeIfNeeded()
            hosted.window.displayIfNeeded()
        } else {
            waitForTestOperation("\(step): the app's own frame draws the pager and the neighbours' rows") {
                TasksPagerPassCount.passes > passes && neighbours.allSatisfy { tab in
                    (tab == .done ? hosted.model.doneDays().isEmpty : hosted.model.rows(for: tab).isEmpty)
                        || TasksCellBodyCounts.drawnRuns.contains { $0.drawn && $0.row.tab == tab }
                }
            }
        }
        XCTAssertGreaterThan(TasksPagerPassCount.passes, passes, "\(step): the pager ran, so a frame was drawn")
        assertTheRowsDrawnAreTheRowsListed(step, hosted, tabs: neighbours)
        // The fingers go back and lift: the page stays where it was.
        send(.changed, dx: 14)
        send(.ended)
        hosted.spin(0.8)
        XCTAssertEqual(hosted.model.tab, shown, "\(step): the swipe was let go where it began")
        print("SPAN_FRAME_\(name)_\(laidOut ? "laid_out" : "own_frame") writes=\(TasksRowStateCounts.writesDuringListRead) late=\(TasksRowStateCounts.lateCatchUps) routes=\(TasksRowStateCounts.lateRoutes.map { $0.prefix(60) })")
        XCTAssertEqual(TasksRowStateCounts.writesDuringListRead, 0, "\(step): a row state was written during a list read")
        XCTAssertEqual(TasksRowStateCounts.lateCatchUps, 0,
                       "\(step): the neighbour's rows caught up after that frame: \(TasksRowStateCounts.lateRoutes)")
        TasksRowStateCounts.reset()
    }

    func testATabASwipeDrawsAfterAStoreChangeMadeWhileItWasNotDrawnDrawsItsRowsOnTime() throws {
        let hosted = try warmed(laterRows: 5)
        defer { hosted.close() }
        TasksCellBodyCounts.records = true
        defer { TasksCellBodyCounts.records = false }
        // Done has loaded its log once, as it has in use.
        hosted.go(to: .done)
        hosted.go(to: .now)
        var turn = 0
        let task = { (id: UUID) throws -> TaskItem in try XCTUnwrap(hosted.store.task(withID: id)) }
        // Now is shown: a swipe draws Later beside it.
        for laidOut in [true, false] {
            turn += 1
            checkASwipesNeighbours("later_create", hosted, on: .now, neighbours: [.backlog], laidOut: laidOut) {
                XCTAssertNotNil(hosted.store.create(title: "Added while Later is not drawn \(turn)", status: .backlog))
            }
            try checkASwipesNeighbours("later_rename", hosted, on: .now, neighbours: [.backlog], laidOut: laidOut) {
                let row = try XCTUnwrap(hosted.model.rows(for: .backlog).last { $0.status != .done })
                XCTAssertTrue(hosted.store.rename(try task(row.id), to: "Renamed while Later is not drawn \(turn)"))
            }
            try checkASwipesNeighbours("later_complete", hosted, on: .now, neighbours: [.backlog], laidOut: laidOut) {
                let row = try XCTUnwrap(hosted.model.rows(for: .backlog).first { $0.status != .done })
                XCTAssertTrue(hosted.model.setStatus(.done, for: [row.id]).isApplied)
            }
        }
        // Later is shown: a swipe draws Now and Done beside it.
        hosted.go(to: .backlog)
        for laidOut in [true, false] {
            turn += 1
            try checkASwipesNeighbours("now_create_and_complete", hosted, on: .backlog, neighbours: [.now, .done], laidOut: laidOut) {
                XCTAssertNotNil(hosted.store.create(title: "Added while Now is not drawn \(turn)"))
                let row = try XCTUnwrap(hosted.model.rows(for: .now).last { $0.status != .done })
                XCTAssertTrue(hosted.model.setStatus(.done, for: [row.id]).isApplied)
            }
        }
    }

    /// The pager's span is also set when Tasks is shown again from another
    /// page (`isPageShown`, TasksPageHost's calls), where the rows are now
    /// brought up too. Store changes made while Tasks was away: the first
    /// frame back draws the listed rows, with nothing written during a
    /// list read and nothing catching up after it.
    func testTheFirstFrameBackOnTasksAfterStoreChangesMadeWhileAwayDrawsItsRowsOnTime() throws {
        let hosted = try warmed(laterRows: 5)
        defer { hosted.close() }
        TasksCellBodyCounts.records = true
        defer { TasksCellBodyCounts.records = false }
        for laidOut in [true, false] {
            let step = "back on Tasks, \(laidOut ? "laid_out" : "own_frame")"
            hosted.spin(0.6)
            hosted.model.isPageShown = false
            hosted.spin(0.3)
            XCTAssertNotNil(hosted.store.create(title: "Added while Tasks is away, \(step)"))
            let row = try XCTUnwrap(hosted.model.rows(for: .now).last { $0.status != .done })
            XCTAssertTrue(hosted.store.rename(try XCTUnwrap(hosted.store.task(withID: row.id)), to: "Renamed while Tasks is away, \(step)"))
            hosted.spin(0.6)
            XCTAssertEqual(TasksRowStateCounts.lateCatchUps, 0, "\(step): nothing is late while away: \(TasksRowStateCounts.lateRoutes)")
            TasksRowStateCounts.reset()
            TasksCellBodyCounts.drawnRuns = []
            hosted.model.isPageShown = true
            hosted.model.pageDidReturn()
            if laidOut {
                hosted.window.contentView?.layoutSubtreeIfNeeded()
                hosted.window.displayIfNeeded()
            } else {
                waitForTestOperation("\(step): the app's own frame draws Now's rows") {
                    TasksCellBodyCounts.drawnRuns.contains { $0.drawn && $0.row.tab == .now }
                }
            }
            assertTheRowsDrawnAreTheRowsListed(step, hosted, tabs: [.now])
            hosted.spin(0.8)
            print("SPAN_FRAME_back_on_tasks_\(laidOut ? "laid_out" : "own_frame") writes=\(TasksRowStateCounts.writesDuringListRead) late=\(TasksRowStateCounts.lateCatchUps) routes=\(TasksRowStateCounts.lateRoutes.map { $0.prefix(60) })")
            XCTAssertEqual(TasksRowStateCounts.writesDuringListRead, 0, "\(step): a row state was written during a list read")
            XCTAssertEqual(TasksRowStateCounts.lateCatchUps, 0, "\(step): Now's rows caught up after that frame: \(TasksRowStateCounts.lateRoutes)")
            TasksRowStateCounts.reset()
        }
    }

    // Now returns from Done after a change made while it was not drawn: the
    // change is laid out in its first frame back, with no motion (a row
    // that left has no frame, one that came is already in its place).
    // Red on trunk a1597202: the ticked row kept its frame in Now's first
    // frame back and left during the slide (PR 48's probe, 22 Nov).

    /// The second open row of Now, by id.
    private func nowsSecondRow(_ hosted: Hosted) throws -> UUID {
        let open = hosted.model.rows(for: .now).filter { $0.status != .done }
        XCTAssertGreaterThan(open.count, 1, "Now has open rows to change")
        return try XCTUnwrap(open.dropFirst().first).id
    }

    func testNowIsRightInItsFirstFrameBackAfterARowIsTickedFromDone() throws {
        try checkLatersFirstFrame("now-tick", tab: .now, from: .done, matchesRows: false, resizes: false) { hosted in
            let id = try nowsSecondRow(hosted)
            hosted.model.completeAcknowledged(id) { _ in }
            XCTAssertTrue(hosted.model.settlePendingCompletionAcknowledgements(through: id), "the tick is saved")
        }
    }

    func testNowIsRightInItsFirstFrameBackAfterARowIsDeletedFromDone() throws {
        try checkLatersFirstFrame("now-delete", tab: .now, from: .done, resizes: false) { hosted in
            let id = try nowsSecondRow(hosted)
            XCTAssertTrue(hosted.model.delete([id]).isApplied, "the delete is saved")
        }
    }

    func testNowIsRightInItsFirstFrameBackAfterARowIsAddedFromDone() throws {
        try checkLatersFirstFrame("now-add", tab: .now, from: .done, resizes: false) { hosted in
            XCTAssertNotNil(hosted.store.create(title: "Added while Now is not drawn", status: .todo))
        }
    }

    // The family: a row that leaves any tab's list while that tab is not
    // drawn. Later draws the same list as Now; Done draws its own
    // (`TasksDonePage`), whose rows have no exit today, and is guarded so
    // one added later cannot bring the fault back unseen.

    /// How many reads of the return to `tab`, from the first in which its
    /// list is drawn, still draw the row `id`, which left the tab while it
    /// was not drawn.
    private func staleReadsOnReturn(_ hosted: Hosted, to tab: TasksTab, of id: UUID, label: String) throws -> Int {
        let slot = try XCTUnwrap(TasksTab.allCases.firstIndex(of: tab))
        let host = hosts(hosted)[slot]
        let row = TasksRowID(tab: tab, id: id)
        var drawings: [LaterDrawing] = []
        var still: [Bool] = []
        withAnimation(AtticMotionPreset.slide.animation(reduceMotion: false)) { hosted.model.select(tab: tab) }
        let sampler = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_100_000) { _, _ in
            MainActor.assumeIsolated {
                drawings.append(self.laterDrawing(hosted, host: host, tab: tab))
                still.append(hosted.pointer.frame(for: row) != nil)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), sampler, .commonModes)
        waitForTestOperation("\(label): the slide to the tab ends, its list settles and the row has gone") {
            hosted.model.pagerSwipe.motion.position == CGFloat(slot) && drawings.count >= 2
                && drawings[drawings.count - 1] == drawings[drawings.count - 2] && drawings[drawings.count - 1].listWidth > 0
                && still.last == false
        }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), sampler, .commonModes)
        CFRunLoopObserverInvalidate(sampler)
        let shown = try XCTUnwrap(drawings.firstIndex { $0.listWidth > 0 }, "\(label): the list is drawn during the switch")
        let stale = still[shown...].filter { $0 }.count
        print("RETURN_STALE \(label) reads=\(drawings.count) first_drawn_read=\(shown) stale_reads=\(stale)")
        return stale
    }

    func testLaterIsRightInItsFirstFrameBackAfterARowIsDeletedFromNow() throws {
        let hosted = try warmed(laterRows: 4, followsWindow: true)
        defer { hosted.close() }
        hosted.go(to: .backlog)
        let id = try XCTUnwrap(hosted.model.rows(for: .backlog).dropFirst().first).id
        XCTAssertNotNil(hosted.pointer.frame(for: TasksRowID(tab: .backlog, id: id)), "the row is drawn on Later")
        hosted.go(to: .now)
        XCTAssertTrue(hosted.model.delete([id]).isApplied, "the delete is saved")
        hosted.spin(0.6)
        XCTAssertEqual(try staleReadsOnReturn(hosted, to: .backlog, of: id, label: "later-delete"), 0,
                       "a row deleted while Later was not drawn is not drawn in Later's first frame back")
    }

    /// PR 48 round 3, the family through the send (RULES §3 lesson 4): each
    /// value a list is built from is set right after a pending transaction
    /// (a plain selection change), the recipe
    /// `testReleasingAHeldRowNeverReadsItHeldInsideTheSend` uses for `held`.
    /// A flush inside the send runs the pager and the page, which read the
    /// lists: the drawn rows are up to them already. Done's inputs come
    /// through a drawn Done page. The tear-down holds both row-state counts
    /// at zero; each step is also checked on its own, by name.
    func testEveryListInputSentAfterAPendingChangeDrawsItsRowsOnTime() throws {
        try requireKeyWindowTests()
        var services = TasksPageServices()
        services.doneHold = .seconds(3_600)
        services.acknowledgementDelay = .seconds(3_600)
        let hosted = try Hosted(height: 520, services: services)
        defer { hosted.close() }
        hosted.spin(0.3)
        let model = hosted.model
        let ids = model.rows(for: .now).filter { $0.status != .done }.map(\.id)
        XCTAssertGreaterThan(ids.count, 3)
        var turn = 0
        func step(_ name: String, _ change: () throws -> Void) rethrows {
            TasksRowStateCounts.reset()
            turn += 1
            if turn.isMultiple(of: 2) { model.selectOnly(ids[0]) } else { model.clearSelection() }
            try change()
            hosted.spin(0.3)
            let writes = TasksRowStateCounts.writesDuringListRead, late = TasksRowStateCounts.lateCatchUps
            print("FAMILY_SEND_\(name) writes=\(writes) late=\(late)")
            XCTAssertEqual(writes, 0, "\(name): a row state was written during a list read")
            XCTAssertEqual(late, 0, "\(name): the drawn rows caught up a frame late")
            XCTAssertEqual(model.rowStateMismatches(), [], "\(name): the states agree with the model")
        }
        step("held") { model.completeAcknowledged(ids[2]) { _ in } }
        step("acknowledgement") { _ = model.settlePendingCompletionAcknowledgements(through: ids[2]) }
        step("held_release") { model.releaseHold(ids[2]) }
        step("note_owners") { model.setNoteOwners([ids[0]]) }
        step("expanded") { model.setExpanded(ids[1], true) }
        step("expanded_closed") { model.setExpanded(ids[1], false) }
        step("completed_today") { model.completedTodayExpanded = true }
        step("view_options") { model.setViewOptions(TasksViewOptions(sort: .dueDate), for: .now) }
        step("view_options_cleared") { model.setViewOptions(TasksViewOptions(), for: .now) }
        step("search") { model.listSearch[.now] = "a" }
        step("search_cleared") { model.listSearch[.now] = nil }
        step("tag_pick") { model.tagPicks = TagPicks(["round3"]) }
        step("tag_pick_cleared") { model.tagPicks = .none }
        if let group = model.rows(for: .now).lazy.compactMap({ model.groupKey(of: $0.id, on: .now) }).first {
            step("folded") { model.foldAllGroups([group], folded: true, on: .now) }
            step("unfolded") { model.foldAllGroups([group], folded: false, on: .now) }
        } else {
            XCTFail("the demo has a date group to fold")
        }
        step("next_event") {
            let start = Date().addingTimeInterval(3_600)
            let event = CalendarEvent(id: "round3", title: "Stand-up", start: start, end: start.addingTimeInterval(1_800),
                                      isAllDay: false, location: nil, calendarTitle: "Work",
                                      colour: CalendarEventColour(red: 0.2, green: 0.4, blue: 0.8))
            model.nextEvent = TasksNextEvent(event, calendar: model.services.calendar(), locale: model.services.locale)
        }
        step("next_event_cleared") { model.nextEvent = nil }
        step("day_drag") { model.dayDragLive = true }
        step("day_drag_ended") { model.dayDragLive = false }
        hosted.go(to: .done)
        XCTAssertEqual(TasksRowStateCounts.lateCatchUps, 0, "Done's first frame is on time")
        step("done_search") { model.doneSearch = "a" }
        step("done_search_cleared") { model.doneSearch = "" }
        step("done_load_more") { model.loadMoreDoneLog() }
        let done = try XCTUnwrap(model.doneDays().flatMap(\.rows).first?.id, "Done lists a row")
        step("done_store_revision") { model.setStatus(.todo, for: [done]) }
        hosted.go(to: .now)
    }

    func testDoneIsRightInItsFirstFrameBackAfterARowIsDeletedFromNow() throws {
        let hosted = try warmed(laterRows: 4, followsWindow: true)
        defer { hosted.close() }
        let id = try nowsSecondRow(hosted)
        hosted.model.completeAcknowledged(id) { _ in }
        XCTAssertTrue(hosted.model.settlePendingCompletionAcknowledgements(through: id), "the tick is saved")
        hosted.go(to: .done)
        XCTAssertNotNil(hosted.pointer.frame(for: TasksRowID(tab: .done, id: id)), "the row is drawn on Done")
        hosted.go(to: .now)
        XCTAssertTrue(hosted.model.delete([id]).isApplied, "the delete is saved")
        hosted.spin(0.6)
        XCTAssertEqual(try staleReadsOnReturn(hosted, to: .done, of: id, label: "done-delete"), 0,
                       "a row deleted while Done was not drawn is not drawn in Done's first frame back")
    }

    /// Only the return is laid out without motion: a row deleted on Now once
    /// it is drawn again still leaves with its exit (it keeps a frame while
    /// it goes, then has none).
    func testNowKeepsItsDeleteMotionAfterTheReturnFromDone() throws {
        let hosted = try warmed(laterRows: 4, followsWindow: true)
        defer { hosted.close() }
        hosted.go(to: .done)
        hosted.go(to: .now)
        let id = try nowsSecondRow(hosted)
        let row = TasksRowID(tab: .now, id: id)
        XCTAssertNotNil(hosted.pointer.frame(for: row), "the row is drawn before the delete")
        var reads: [Bool] = []
        let sampler = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_100_000) { _, _ in
            MainActor.assumeIsolated { reads.append(hosted.pointer.frame(for: row) != nil) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), sampler, .commonModes)
        XCTAssertTrue(hosted.model.delete([id]).isApplied, "the delete is saved")
        waitForTestOperation("the deleted row leaves") { reads.last == false }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), sampler, .commonModes)
        CFRunLoopObserverInvalidate(sampler)
        print("DELETE_MOTION reads=\(reads.count) framed=\(reads.filter { $0 }.count)")
        XCTAssertGreaterThan(reads.prefix { $0 }.count, 1, "the row keeps its frame for more than one frame while it leaves (its exit plays)")
    }

    /// TAB-STALL (host-boundary.md §5.1): a switch made by code inside
    /// `withAnimation`, outside an event, reaches the page: its body reads the
    /// new tab. At e6bf266c the tab's publish went out before the store, a
    /// synchronous flush ran the page's body with the old tab, and nothing
    /// published again: the tab bar, the search field and the shown index
    /// stayed on the old tab (hb-ab2 run 4; 14 of 64 switches in hb-ab).
    func testCodeDrivenAnimatedSwitchesReachThePage() throws {
        try requireKeyWindowTests()
        let hosted = try warmed()
        defer { hosted.close() }
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

    #if DEBUG
    /// Store before send (hb09-key-note §2; item 4, TasksPageUITests
    /// `testCompletingOnLaterHoldsThenLeaves`): a held row's release sends
    /// `held`'s change. With a transaction pending on the page's graphs, a
    /// flush inside that send runs the page and Later's list there; sent
    /// before the store, they read the row still held and are marked clean,
    /// so the row stays. Each release here follows a pending transaction:
    /// a row focus write in Later's host, a plain selection change, both,
    /// or neither. No read inside the send may see the row held.
    func testReleasingAHeldRowNeverReadsItHeldInsideTheSend() throws {
        try requireKeyWindowTests()
        var services = TasksPageServices()
        // The test releases each hold itself.
        services.doneHold = .seconds(3_600)
        let hosted = try Hosted(height: 520, services: services)
        defer { hosted.close() }
        let stays = (0..<4).compactMap { hosted.store.create(title: "Later stays \($0 + 1)", status: .backlog)?.id }
        let finished = (0..<12).compactMap { hosted.store.create(title: "Later done \($0 + 1)", status: .backlog)?.id }
        XCTAssertEqual(stays.count + finished.count, 16)
        waitForTestOperation("every tab kept built, each in its own host") {
            hosted.spin(0.05)
            return hosted.model.pagerSwipe.span.warm == 0...2 && hosts(hosted).count == TasksTab.allCases.count
        }
        hosted.go(to: .backlog)
        hosted.spin(0.3)
        for id in finished {
            hosted.model.setStatus(.done, for: [id])
            hosted.spin(0.05)
        }
        hosted.spin(0.5)
        XCTAssertEqual(Set(hosted.model.held.keys), Set(finished), "every finished row is held on Later")
        let link = try XCTUnwrap(TasksRowFocusLink.current)
        TasksPageRenderProbe.heldReads = (0, 0)
        TasksPageRenderProbe.staleHeldReads = (0, 0)
        var staleBy: [String] = []
        for (n, id) in finished.enumerated() {
            let before = TasksPageRenderProbe.staleHeldReads
            let other = stays[n % stays.count]
            switch n % 4 {
            case 0: link.setValue(AtticRowFocusID(page: TasksTab.backlog.rawValue, id: other))
            case 1: hosted.model.selectOnly(other)
            case 2:
                hosted.model.selectOnly(other)
                link.setValue(AtticRowFocusID(page: TasksTab.backlog.rawValue, id: other))
            default: break
            }
            hosted.model.releaseHold(id)
            let after = TasksPageRenderProbe.staleHeldReads
            if after != before { staleBy.append("\(n % 4):page+\(after.page - before.page),list+\(after.list - before.list)") }
            hosted.spin(0.3)
        }
        let reads = TasksPageRenderProbe.heldReads, stale = TasksPageRenderProbe.staleHeldReads
        print("HELD-STALL reads inside the send: page \(reads.page) list \(reads.list); still held: page \(stale.page) list \(stale.list); by variant \(staleBy)")
        XCTAssertTrue(hosted.model.held.isEmpty, "every hold released")
        XCTAssertEqual(stale.list, 0, "Later's list never reads a released row as held inside the send")
        XCTAssertEqual(stale.page, 0, "the page's body never reads a released row as held inside the send")
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

    /// An assistive client starting, stopping and starting again while
    /// Later is hidden (VoiceOver turned on, off and on), then a switch:
    /// the panel's hit walk reaches Later's row, inside Later's host.
    func testTheHitWalkReachesTheShownTabsRowAfterAnAssistiveClientRestartsWhileItIsHidden() throws {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        // More Later rows than its page shows, so a read that mounted rows
        // for a client would show as new rows run.
        let hosted = try warmed(laterRows: 30)
        defer { hosted.close() }
        let content = try XCTUnwrap(hosted.window.contentView)
        #if DEBUG
        TasksCellBodyCounts.records = true
        TasksCellBodyCounts.leaves = [:]
        defer { TasksCellBodyCounts.records = false }
        func laterRowsRun() -> Set<UUID> { Set(TasksCellBodyCounts.leaves.keys.filter { $0.tab == .backlog }.map(\.id)) }
        #endif
        for on in [true, false, true] {
            NSApp.accessibilitySetValue(on, forAttribute: enhanced)
            // A client's read of the panel, as an assistive client makes.
            _ = content.accessibilityChildren()
            hosted.spin(0.5)
            #if DEBUG
            XCTAssertEqual(laterRowsRun(), [], "a read while Later is hidden mounts and runs none of its rows")
            #endif
        }
        XCTAssertGreaterThan(hosted.model.rows(for: .backlog).count, 20, "more Later rows than its page shows")
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
        assertTheHit(hit, names: row.model.title)
    }

    /// Whether `element`, or one of its children to `depth` levels, reads
    /// `title` (a row's button carries no label of its own; its title is a
    /// child).
    private static func names(_ element: AnyObject, _ title: String, depth: Int) -> Bool {
        let label = element.accessibilityLabel?() ?? ""
        let raw: Any?? = element.accessibilityValue?()
        let value = (raw ?? nil) as? String ?? ""
        let text = element.accessibilityTitle?() ?? ""
        if label.contains(title) || value.contains(title) || text.contains(title) { return true }
        guard depth > 0, let children = element.accessibilityChildren?() else { return false }
        return children.contains { names($0 as AnyObject, title, depth: depth - 1) }
    }

    /// The hit, its children or an ancestor of it names `title` (the
    /// expected Later task, not just some row), and nothing on the way
    /// comes from a host not in use.
    private func assertTheHit(_ hit: AnyObject, names title: String, line: UInt = #line) {
        var hosts: [KeptContentHostingView] = []
        var named = false
        var node: AnyObject? = hit
        var depth = 0
        while let current = node, depth < 64 {
            if let host = current as? KeptContentHostingView { hosts.append(host) }
            if Self.names(current, title, depth: current === hit ? 3 : 0) { named = true }
            node = (current.accessibilityParent?() ?? nil) as AnyObject?
            depth += 1
        }
        XCTAssertTrue(named, "the hit, its children or an ancestor is Later's task \"\(title)\"", line: line)
        XCTAssertFalse(hosts.contains { !$0.isInteractive }, "nothing from a host not in use", line: line)
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
        assertTheHit(hit, names: row.model.title)
    }

    // MARK: Keyboard ownership (host-boundary.md §5.1, one test per row)

    /// Real key events need a key panel (the shared gate, TestSupport).
    private func keyWindowOnly() throws { try requireKeyWindowTests() }

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

    /// No row focus is left on a tab not in use (§5.1, KB-CLAIM-RACE): the
    /// leaving host's focus state goes nil with the keyboard, unwritten.
    private func assertNoFocusLeftBehind(_ hosted: Hosted, line: UInt = #line) {
        #if DEBUG
        let link = TasksRowFocusLink.current
        let left = link?.tabsHoldingFocus(besides: hosted.model.tab) ?? []
        // HB-479-LEFTOVER-FOCUS (boarded, one sighting): the state the
        // next sighting needs, named in the message.
        let state = left.isEmpty ? "" : {
            let hostStates = hosts(hosted).enumerated().map { index, host in
                "host\(index)(window=\(host.window != nil) inUse=\(host.isInteractive) hidden=\(host.isHiddenOrHasHiddenAncestor) holds=\(Self.holdsTheKeyboard(host)))"
            }
            return "; tab in use \(hosted.model.tab), skippedLetGos \(link?.skippedLetGos ?? -1), first responder \(String(describing: hosted.window.firstResponder)), \(hostStates.joined(separator: " "))"
        }()
        XCTAssertEqual(left, [], "no row focus is left on a tab not in use" + state, line: line)
        #endif
    }

    private static func holdsTheKeyboard(_ host: KeptContentHostingView) -> Bool {
        guard let responder = host.window?.firstResponder as? NSView else { return false }
        return responder === host || responder.isDescendant(of: host)
    }

    private func assertTheArrivingTabHasTheKeyboard(_ hosted: Hosted, _ tab: TasksTab, line: UInt = #line) throws {
        assertNoFocusLeftBehind(hosted, line: line)
        XCTAssertTrue(keyboardHost(hosted) === (try inUse(hosted)), "the arriving tab's host claimed the keyboard: \(String(describing: hosted.window.firstResponder))", line: line)
        down(hosted)
        XCTAssertEqual(hosted.model.keyboardFocus?.page, tab.rawValue, "↓ reaches a row of the arriving tab", line: line)
    }

    /// §5.1 row "first switch to a tab not yet warmed" (PR 41 review,
    /// finding 1): Later's host is made already in use, so it never turns
    /// into use; it claims the keyboard at its first frame, just before it
    /// joins accessibility, under the same rules as every claim.
    func testOwnershipTheFirstSwitchToATabNotYetWarmedMovesTheKeyboardToIt() throws {
        try keyWindowOnly()
        let hosted = try Hosted(height: 520, warms: false)
        defer { hosted.close() }
        waitForTestOperation("Now's host") {
            hosted.spin(0.05)
            return hosts(hosted).contains(where: \.isInteractive)
        }
        XCTAssertEqual(hosts(hosted).count, 1, "only Now is built: Later has no host yet")
        try focusANowRow(hosted)
        let departing = try inUse(hosted)
        hosted.go(to: .backlog)
        try waitForTheSwitch(hosted, to: "Later", from: departing, joined: true)
        try assertTheArrivingTabHasTheKeyboard(hosted, .backlog)
    }

    /// What a key does after a swipe to Later: who has the keyboard, the
    /// row focus, an open rename, and what changed in each tab's tasks
    /// (by title, so two fixtures compare).
    private struct AfterTheSwipe: Equatable {
        var keyboardInTheTabInUse = false
        var focusPage: Int?
        var renaming: String?
        var changedInNow: [String] = []
        var changedInLater: [String] = []
    }

    private func tasksByID(_ hosted: Hosted) -> [UUID: TaskItem] {
        let items = (try? ModelContext(hosted.store.container).fetch(FetchDescriptor<TaskItem>())) ?? []
        return Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func state(of task: TaskItem?) -> String {
        guard let task else { return "gone" }
        return "\(task.statusRaw) completed=\(task.completedAt != nil) deleted=\(task.deletedAt != nil)"
    }

    /// A real click on the date chip of the focused Now row (↓ moves on to
    /// a row with a date first).
    private func openTheDatePicker(_ hosted: Hosted, line: UInt = #line) throws {
        func focused() -> TaskItem? { hosted.model.keyboardFocus.flatMap { tasksByID(hosted)[$0.id] } }
        var steps = 0
        while focused()?.dueDay == nil, hosted.model.keyboardFocus?.page == TasksTab.now.rawValue, steps < 12 {
            down(hosted)
            steps += 1
        }
        let title = try XCTUnwrap(focused()?.dueDay != nil ? focused()?.title : nil, "a focused Now row with a date", line: line)
        var rows: [CGRect] = [], chips: [CGRect] = []
        func walk(_ element: AnyObject, depth: Int) {
            let label = element.accessibilityLabel?() ?? ""
            let rect: CGRect? = element.accessibilityFrame?()
            if label.hasPrefix("Due ") { chips.append(rect ?? .zero) }
            if label.contains(title) || (element.accessibilityTitle?() ?? "").contains(title) { rows.append(rect ?? .zero) }
            guard depth > 0, let children = element.accessibilityChildren?() else { return }
            for child in children { walk(child as AnyObject, depth: depth - 1) }
        }
        walk(try inUse(hosted), depth: 30)
        let row = try XCTUnwrap(rows.max { $0.height < $1.height }, "the focused row", line: line)
        let chip = try XCTUnwrap(chips.first { $0.midY >= row.minY && $0.midY <= row.maxY }, "its date chip", line: line)
        let point = hosted.window.convertPoint(fromScreen: CGPoint(x: chip.midX, y: chip.midY))
        hosted.click(y: hosted.height - point.y, x: point.x)
        waitForTestOperation("the date picker opens", line: line) {
            hosted.spin(0.05)
            return AtticDropdownPresenter.openCount > 0
        }
    }

    /// A Now row focused, the date picker open or not, a swipe to Later
    /// (which closes the picker), then `key`.
    private func afterTheSwipe(press key: (String, UInt16), pickerOpen: Bool, line: UInt = #line) throws -> AfterTheSwipe {
        let hosted = try warmed(line: line)
        defer { hosted.close() }
        try focusANowRow(hosted, line: line)
        if pickerOpen { try openTheDatePicker(hosted, line: line) }
        let departing = try inUse(hosted)
        swipe(hosted) {}
        waitForTestOperation("the swipe reaches Later and no card is open", line: line) {
            hosted.spin(0.05)
            return hosted.model.tab == .backlog && AtticDropdownPresenter.openCount == 0
        }
        try waitForTheSwitch(hosted, to: "Later", from: departing, joined: true, line: line)
        var after = AfterTheSwipe()
        after.keyboardInTheTabInUse = keyboardHost(hosted) === (try inUse(hosted))
        let now = Set(hosted.model.rows(for: .now).map(\.id))
        let later = Set(hosted.model.rows(for: .backlog).map(\.id))
        let before = tasksByID(hosted).mapValues(state)
        let titles = tasksByID(hosted).mapValues(\.title)
        hosted.press(key.0, keyCode: key.1)
        hosted.spin(0.5)
        let afterKey = tasksByID(hosted)
        let changed = before.keys.filter { before[$0] != state(of: afterKey[$0]) }
        func describe(_ id: UUID) -> String { "\(titles[id] ?? "?"): \(before[id] ?? "?") -> \(state(of: afterKey[id]))" }
        after.changedInNow = changed.filter(now.contains).map(describe).sorted()
        after.changedInLater = changed.filter(later.contains).map(describe).sorted()
        after.focusPage = hosted.model.keyboardFocus?.page
        after.renaming = hosted.model.editingTitleID.flatMap { titles[$0] }
        return after
    }

    /// §5.1 (HB-DROPDOWN-RESTORE-HIDDEN): a card open when a swipe leaves
    /// its tab closes with the tab change, and never gives the keyboard
    /// back to the host that left use; the tab in use claims it. Return,
    /// Space and Delete then do exactly what they do after a plain swipe,
    /// and nothing in Now changes.
    func testOwnershipAPickerClosedByASwipeLeavesTheKeysAsAPlainSwipeDoes() throws {
        try keyWindowOnly()
        for key in [("\r", UInt16(36)), (" ", UInt16(49)), ("\u{7F}", UInt16(51))] {
            let plain = try afterTheSwipe(press: key, pickerOpen: false)
            let picker = try afterTheSwipe(press: key, pickerOpen: true)
            XCTAssertTrue(plain.keyboardInTheTabInUse, "a plain swipe leaves the keyboard with the tab in use (key \(key.1))")
            XCTAssertEqual(picker, plain, "after the picker closed by the swipe, key \(key.1) does what it does after a plain swipe")
            XCTAssertEqual(picker.changedInNow, [], "nothing in Now changes (key \(key.1))")
        }
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
        var crossed = false
        swipe(hosted) {
            if hosted.model.tab == .now {
                XCTAssertTrue(keyboardHost(hosted) === departing, "before the crossing, Now's host has the keyboard")
            } else {
                crossed = true
            }
        }
        XCTAssertTrue(crossed, "the swipe crossed halfway to Later")
        try waitForTheSwitch(hosted, to: "Later", from: departing, joined: false)
        try assertTheArrivingTabHasTheKeyboard(hosted, .backlog)
    }

    /// A trackpad swipe toward the next tab, through the page's scroll
    /// path (`pagerScrolled`): began, movements, the fingers lift, then
    /// its momentum. `step` runs after each movement.
    private func swipe(_ hosted: Hosted, steps: Int = 30, dx: CGFloat = -14, step: () -> Void) {
        var time = CACurrentMediaTime()
        func send(_ phase: TasksPagerSwipe.Sample.Phase, dx: CGFloat = 0, momentum: Bool = false) {
            time += 1.0 / 120
            _ = hosted.model.pagerScrolled(.init(phase: phase, momentum: momentum, dx: dx, dy: 0, time: time, precise: true),
                                           allowed: true)
        }
        send(.began)
        for _ in 0..<steps {
            send(.changed, dx: dx)
            hosted.spin(1.0 / 120)
            step()
        }
        send(.ended)
        for _ in 0..<20 { send(.none, dx: dx, momentum: true) }
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
        XCTAssertEqual(hosted.model.editingTitleID, row, "the rename is open")
        waitForTestOperation("the rename's field takes the keyboard") {
            hosted.spin(0.05)
            return hosted.window.firstResponder is NSTextView
        }
        let editor = try XCTUnwrap(hosted.window.firstResponder as? NSTextView)
        let renamed = "Renamed by the switch \(UUID().uuidString.prefix(6))"
        editor.selectAll(nil)
        editor.insertText(renamed, replacementRange: editor.selectedRange())
        hosted.go(to: .backlog)
        XCTAssertNil(hosted.model.editingTitleID, "the switch closed the rename")
        XCTAssertEqual(hosted.model.tab, .backlog, "Later is shown")
        let fresh = ModelContext(hosted.store.container)
        let saved = try fresh.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == row })).first
        XCTAssertEqual(saved?.title, renamed, "the switch saved the typed title (a fresh read of the store)")
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
        try requireKeyWindowTests()
        let hosted = try warmed()
        defer { hosted.close() }
        hosted.press("\u{F701}", keyCode: 125)
        hosted.spin(0.3)
        XCTAssertEqual(hosted.model.keyboardFocus?.page, TasksTab.now.rawValue, "↓ on Now reaches a Now row")
        hosted.go(to: .backlog)
        XCTAssertNotEqual(hosted.model.keyboardFocus?.page, TasksTab.now.rawValue, "Now's row let go on leaving")
        assertNoFocusLeftBehind(hosted)
        hosted.press("\u{F701}", keyCode: 125)
        hosted.spin(0.3)
        XCTAssertEqual(hosted.model.keyboardFocus?.page, TasksTab.backlog.rawValue, "↓ on Later reaches a Later row")
        hosted.go(to: .now)
        assertNoFocusLeftBehind(hosted)
        XCTAssertNil(hosted.model.keyboardFocus, "back on Now, no row is remembered (as on the trunk)")
        hosted.press("\u{F701}", keyCode: 125)
        hosted.spin(0.3)
        XCTAssertEqual(hosted.model.keyboardFocus?.page, TasksTab.now.rawValue, "and on Now again")
    }

    // MARK: HB-09, a tab host's pass releases only its own keyboard

    /// HB-09 (host-boundary.md §5.1; ScrollEdgeUITests' Find rows): Find's
    /// field is on the tabs' line, outside every tab host. Back in the field
    /// from a row (a click does this), the page lets the row go
    /// (`focusedRow = nil`) while the field already holds the keyboard; the
    /// tab host's SwiftUI pass applies that, and it must not take the
    /// keyboard from the field. Driven by the window's own layout pass.
    func testHB09ARowLettingGoInTheTabsPassLeavesFindsFieldTheKeyboard() throws {
        try checkARowLettingGo(outsideTheWindowsPass: false)
    }

    /// HB-09, the same with the row's focus let go by a direct write, outside
    /// any window layout pass: no release reaches the field there either.
    func testHB09ARowLettingGoOutsideTheWindowsPassLeavesFindsFieldTheKeyboard() throws {
        try checkARowLettingGo(outsideTheWindowsPass: true)
    }

    #if DEBUG
    /// HB-09's key (hb09-key-note §1), at the write: back in Find's field
    /// from a row, the page's nil for the row is not written, as a view
    /// outside Now's host holds the keyboard. The row's focus state goes nil
    /// by itself (the row lost the keyboard), and Find keeps the keyboard.
    func testHB09ANilIsNotWrittenWhileFindHoldsTheKeyboardAndTheRowLetsGoByItself() throws {
        try keyWindowOnly()
        let hosted = try warmed(atticPanel: true)
        defer { hosted.close() }
        let saved = NSApp.mainMenu
        let menu = NSMenu()
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: "Edit")
        let find = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        edit.submenu?.addItem(find)
        menu.addItem(edit)
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = saved }
        hosted.press("f", keyCode: 3, modifiers: .command)
        hosted.press("e", keyCode: 14)
        let field = try XCTUnwrap(hosted.window.contentView.flatMap { AtticTabsSearchField.searchField(in: $0, placeholder: "Search Now") })
        let now = try inUse(hosted)
        down(hosted)
        let link = try XCTUnwrap(TasksRowFocusLink.current)
        if keyboardHost(hosted) !== now, let selected = hosted.model.selection.first {
            link.setValue(AtticRowFocusID(page: TasksTab.now.rawValue, id: selected))
            hosted.spin(0.3)
        }
        XCTAssertTrue(keyboardHost(hosted) === now, "a Now row has the keyboard: \(String(describing: hosted.window.firstResponder))")
        let row = try XCTUnwrap(link.value(preferring: .now), "the row's focus state holds the row")
        let skipped = link.skippedLetGos
        XCTAssertTrue(hosted.window.makeFirstResponder(field))
        XCTAssertTrue(hosted.searchHasKeyboard, "the field has the keyboard")
        // The caret at the end, where a click after the text puts it.
        if let editor = hosted.window.firstResponder as? NSTextView { editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0)) }
        // The row still holds its focus state; the page lets it go.
        XCTAssertEqual(link.value(preferring: .now), row, "not yet let go")
        link.setValue(nil)
        XCTAssertGreaterThan(link.skippedLetGos, skipped, "the nil is not written while Find's field holds the keyboard")
        hosted.spin(0.5)
        XCTAssertNil(link.value(preferring: .now), "the row's focus state went nil by itself")
        XCTAssertTrue(link.tabsHoldingFocus(besides: .now).isEmpty, "no tab holds a row")
        XCTAssertTrue(hosted.searchHasKeyboard, "Find's field keeps the keyboard: \(String(describing: hosted.window.firstResponder))")
        hosted.press("x", keyCode: 7)
        XCTAssertEqual(hosted.model.searchQuery(for: .now), "ex", "typing reaches Find's field")
    }
    #endif

    private func checkARowLettingGo(outsideTheWindowsPass: Bool, line: UInt = #line) throws {
        try keyWindowOnly()
        let hosted = try warmed(atticPanel: true, line: line)
        defer { hosted.close() }
        XCTAssertTrue(hosted.window is AtticPanel, "the app's panel", line: line)
        // The app's Edit menu has Find on ⌘F (as TasksRound6Tests sets it up).
        let saved = NSApp.mainMenu
        let menu = NSMenu()
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: "Edit")
        let find = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        edit.submenu?.addItem(find)
        menu.addItem(edit)
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = saved }
        // Find, with a query (it stays open whoever has the keyboard).
        hosted.press("f", keyCode: 3, modifiers: .command)
        XCTAssertTrue(hosted.searchHasKeyboard, "⌘F gives Find's field the keyboard: \(String(describing: hosted.window.firstResponder))", line: line)
        hosted.press("e", keyCode: 14)
        let field = try XCTUnwrap(hosted.window.contentView.flatMap { AtticTabsSearchField.searchField(in: $0, placeholder: "Search Now") },
                                  "Find's field", line: line)
        XCTAssertNil(KeptContentHostingView.enclosing(field), "Find's field is outside every tab host", line: line)
        // ↓: the first match, a row of Now, is selected and takes the
        // keyboard in Now's host. ↓ out of Find sometimes leaves the keyboard
        // with the panel (not this rule): the row is then given it directly.
        let now = try inUse(hosted)
        down(hosted)
        #if DEBUG
        let link = try XCTUnwrap(TasksRowFocusLink.current, line: line)
        if keyboardHost(hosted) !== now, let selected = hosted.model.selection.first {
            link.setValue(AtticRowFocusID(page: TasksTab.now.rawValue, id: selected))
            hosted.spin(0.3)
        }
        #endif
        XCTAssertTrue(keyboardHost(hosted) === now, "a Now row has the keyboard: \(String(describing: hosted.window.firstResponder))", line: line)
        #if DEBUG
        _ = try XCTUnwrap(link.value(preferring: .now), "the row's focus state holds the row", line: line)
        #endif
        // Back in the field, as a click puts it there (AppKit gives the
        // field the keyboard; the page then lets the row go).
        XCTAssertTrue(hosted.window.makeFirstResponder(field), line: line)
        XCTAssertTrue(hosted.searchHasKeyboard, "the field has the keyboard again", line: line)
        // The caret at the end, where a click after the text puts it.
        if let editor = hosted.window.firstResponder as? NSTextView { editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0)) }
        #if DEBUG
        if outsideTheWindowsPass {
            // The row's focus goes from the row to nil by a direct write,
            // outside any layout pass.
            link.setValue(nil)
            XCTAssertTrue(hosted.searchHasKeyboard,
                          "no release outside a pass: \(String(describing: hosted.window.firstResponder))", line: line)
        }
        #endif
        hosted.spin(0.5)
        XCTAssertTrue(hosted.searchHasKeyboard, "Find's field keeps the keyboard: \(String(describing: hosted.window.firstResponder))", line: line)
        XCTAssertEqual(hosted.model.searchQuery(for: .now), "e", "the query is kept", line: line)
        hosted.press("x", keyCode: 7)
        XCTAssertEqual(hosted.model.searchQuery(for: .now), "ex", "typing reaches Find's field", line: line)
    }
}
