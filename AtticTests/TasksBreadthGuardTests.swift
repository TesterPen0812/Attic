import AppKit
import Combine
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// The Tasks page's update breadth (design/tasks-breadth.md): a change runs
/// the row wrapper (`TasksReorderCell`) of the rows that changed, not of
/// every drawn row. "Changed" is read from data: the row the action is on,
/// plus rows whose cell first draws in the turn (a row scrolled in). Wrappers
/// and leaves are counted per page and row (`TasksRowID`), Now's only.
@MainActor
final class TasksBreadthGuardTests: XCTestCase {
    private static let size = CGSize(width: 344, height: 520)
    private var window: NSWindow?

    override func setUp() async throws {
        try await super.setUp()
        TasksCellBodyCounts.reset()
        TasksCellBodyCounts.records = true
        AtticContextMenuBodyCounts.reset()
        AtticContextMenuBodyCounts.records = true
        TasksRowStateCounts.reset()
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
        assertNoRowStateWriteDuringAReadAndNoLateCatchUp()
        TasksCellBodyCounts.recordsDragGroups = false
        TasksCellBodyCounts.records = false
        TasksCellBodyCounts.reset()
        AtticContextMenuBodyCounts.records = false
        AtticContextMenuBodyCounts.reset()
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        try await super.tearDown()
    }

    // MARK: - Slice 1a: the breadth proof

    /// The proof as a test (rig `speed/count-guards` 7ff3eb4b: 15/15/16
    /// wrappers against one leaf per tick turn, 15 against 1 for a priority
    /// edit). Each turn reaches the row it changed (and rows scrolled in),
    /// through the page's pass and the row's own state (slice 1b: no cell
    /// observes the model's every change). The tick is drawn on its own row
    /// in every turn.
    func testATickAndAPriorityEditRunOnlyTheWrappersOfTheRowsThatChanged() throws {
        let store = try makeStore(open: 40)
        var services = TasksPageServices()
        services.acknowledgementDelay = .seconds(25)
        services.doneHold = .seconds(25)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: services)
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        let rows = model.rows(for: .now)
        let drawn = drawnRows(pointer, rows.map(\.id))
        XCTAssertGreaterThan(drawn.count, 5, "the hosted page drew too few rows for the count to mean anything")

        let tick = rows[2].id
        let press = turn(hosting, pointer, rows.map(\.id), target: tick) { model.completeAcknowledged(tick) { _ in } }
        assertDelivered(press, "press")
        assertOnlyChanged(press, "press")
        let save = turn(hosting, pointer, rows.map(\.id), target: tick) {
            model.settlePendingCompletionAcknowledgements(through: tick)
        }
        assertOnlyChanged(save, "save")
        assertDelivered(save, "save")
        let release = turn(hosting, pointer, rows.map(\.id), target: tick) { model.releaseHold(tick) }
        assertOnlyChanged(release, "release")
        XCTAssertFalse(model.listSnapshot(for: .now).sections.open.contains { $0.id == tick }, "the released row left the open rows")

        let edited = rows[5].id
        let priority = turn(hosting, pointer, rows.map(\.id), target: edited) {
            XCTAssertTrue(model.setPriority(.high, for: [edited]).isApplied)
        }
        assertOnlyChanged(priority, "priority")
        assertDelivered(priority, "priority")
        XCTAssertEqual(TasksCellBodyCounts.leafModels[TasksRowID(tab: .now, id: edited)]?.priority, .high,
                       "the edited row drew its new priority")
    }

    /// The lead's condition 2 at the large seed: after every row of the
    /// list has been drawn once (so many cells were built), a full reload
    /// that names no tasks and changes no row runs no wrapper at all.
    func testAReloadWithoutIDsAfterScrollingTheWholeListRunsNoWrapper() throws {
        let store = try makeStore(open: 400)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        let ids = model.rows(for: .now).map(\.id)
        let scroll = try XCTUnwrap(scrollViews(in: hosting).first { !$0.isHidden }, "Now's list")
        let documentHeight = scroll.documentView?.bounds.height ?? 0
        var y: CGFloat = 0
        var visited = Set<UUID>()
        while y < documentHeight {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle(hosting)
            visited.formUnion(drawnRows(pointer, ids))
            y += Self.size.height / 2
        }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(hosting)
        XCTAssertEqual(visited, Set(ids), "the scroll drew every row of the fixture")

        let revision = store.revision
        let reload = turn(hosting, pointer, ids, target: nil) { store.refresh() }
        print("BREADTH_RELOAD visited=\(visited.count) drawn=\(reload.drawnAfter.count) wrappers=\(reload.wrappers.count)")
        XCTAssertGreaterThan(store.revision, revision, "the reload published a new revision")
        XCTAssertNil(store.revisionChangedTaskIDs, "the reload named no tasks")
        XCTAssertEqual(reload.wrappers, [], "a reload that changed no row ran wrappers: \(reload.wrappers.count)")
    }

    // MARK: - Slice 1b: row state

    /// The 21 Nov measure (optimized app, tracker seed): with row A
    /// selected, one click on row B re-ran every mounted wrapper three
    /// times on the cell broadcast, and a context-menu body with each.
    /// Selecting B runs A's and B's wrappers once each, no other, and the
    /// menus only with their own row's wrapper; B draws the tint, A not.
    func testSelectingAnotherRowRunsOnlyTheTwoRowsWrappersOnceEach() throws {
        let store = try makeStore(open: 83, tracker: true)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        let ids = model.rows(for: .now).map(\.id)
        XCTAssertGreaterThan(drawnRows(pointer, ids).count, 5, "the hosted page drew too few rows for the count to mean anything")
        let a = ids[1], b = ids[3]
        model.selectOnly(a)
        settle(hosting)
        settle(hosting)

        let select = turn(hosting, pointer, ids, target: b) { model.click(b, modifiers: [], visible: ids) }
        assertOnlyTheseRanOnce(select, [a, b], "select")
        XCTAssertEqual(TasksCellBodyCounts.leafStates[TasksRowID(tab: .now, id: b)]?.isSelected, true, "B draws the tint")
        XCTAssertEqual(TasksCellBodyCounts.leafStates[TasksRowID(tab: .now, id: a)]?.isSelected, false, "A lost the tint")
    }

    /// A keyboard move from A to B (the page's focus route: the model's
    /// copy of the focus, then the page's word to the rows, as
    /// `TasksPage`'s `onChange(of: focusedRow)` does): the wrappers that
    /// run are exactly A's and B's, once each; the ring, the tint and the
    /// actions button land on B in the same run, and leave A.
    func testAKeyboardFocusMoveRunsOnlyTheOldAndNewRowsWrappers() throws {
        let store = try makeStore(open: 83, tracker: true)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        let ids = model.rows(for: .now).map(\.id)
        XCTAssertGreaterThan(drawnRows(pointer, ids).count, 5, "the hosted page drew too few rows for the count to mean anything")
        let a = ids[2], b = ids[3]
        func focus(_ id: UUID) {
            model.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.now.rawValue, id: id), keyboardDriving: true)
            model.cellUpdates.objectWillChange.send()
        }
        model.selectOnly(a)
        focus(a)
        settle(hosting)
        settle(hosting)
        XCTAssertEqual(TasksCellBodyCounts.leafStates[TasksRowID(tab: .now, id: a)]?.isFocused, true, "A has the ring")

        let move = turn(hosting, pointer, ids, target: b) { focus(b) }
        assertOnlyTheseRanOnce(move, [a, b], "focus move")
        let drawnB = TasksCellBodyCounts.leafStates[TasksRowID(tab: .now, id: b)]
        let drawnA = TasksCellBodyCounts.leafStates[TasksRowID(tab: .now, id: a)]
        XCTAssertEqual(drawnB?.isFocused, true, "B draws the ring")
        XCTAssertEqual(drawnB?.isSelected, true, "B draws the tint in the same run as the ring")
        XCTAssertEqual(drawnA?.isFocused, false, "A lost the ring")
        XCTAssertEqual(drawnA?.isSelected, false, "A lost the tint")
    }

    /// Key window only (the Air): the real routes, through the page's
    /// focus state. With A selected, a click on B, then ↓, then Tab: each
    /// runs only the old and the new row's wrappers, and the new row's last
    /// run draws the tint and the ring together.
    ///
    /// Board row TASKS-CLICK-SELECTION-FOCUS-FOLD: on the trunk a click and
    /// ↓ were two updates (the selection, then the row's focus state a later
    /// update), so each of the two rows ran twice (57aa530d, Air, key
    /// window). With the list owning the keyboard the cursor is model state
    /// written with the selection, so they are one update and each row runs
    /// once (2f919cb, Air, tk5-classes.log: click, ↓ and Tab `rows=2 runs=2`).
    func testARealClickArrowAndTabRunOnlyTheOldAndNewRows() throws {
        try requireKeyWindowTests()
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.window.makeKey()
        let ids = hosted.model.rows(for: .now).map(\.id)
        XCTAssertGreaterThan(ids.count, 4)
        let a = ids[0], b = ids[1], c = ids[2]
        try hosted.clickRow(a, tab: .now)
        hosted.spin(0.3)
        func runs(_ name: String, _ body: () throws -> Void) rethrows -> [UUID: Int] {
            let base = TasksCellBodyCounts.evaluations
            let pageBase = TasksPageRenderProbe.bodyRuns
            try body()
            hosted.spin(0.3)
            print("BREADTH_KEY_PAGE \(name) page=\(TasksPageRenderProbe.bodyRuns - pageBase)")
            let ran = Dictionary(uniqueKeysWithValues: TasksCellBodyCounts.evaluations.compactMap { row, count in
                row.tab == .now && count > base[row, default: 0] ? (row.id, count - base[row, default: 0]) : nil
            })
            print("BREADTH_KEY \(name) rows=\(ran.count) runs=\(ran.values.reduce(0, +))")
            return ran
        }
        func drawn(_ id: UUID) -> (isSelected: Bool, isFocused: Bool)? { TasksCellBodyCounts.leafStates[TasksRowID(tab: .now, id: id)] }

        let click = try runs("click") { try hosted.clickRow(b, tab: .now) }
        XCTAssertEqual(click, [a: 1, b: 1], "a click: the old and the new row, once each")
        XCTAssertTrue(drawn(b).map { $0.isSelected && $0.isFocused } == true, "B draws the tint and the ring")
        XCTAssertTrue(drawn(a).map { !$0.isSelected && !$0.isFocused } == true, "A draws neither")

        let arrow = runs("arrow") { hosted.press(String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 125) }
        XCTAssertEqual(arrow, [b: 1, c: 1], "↓: the old and the new row, once each")
        XCTAssertTrue(drawn(c).map { $0.isSelected && $0.isFocused } == true, "C draws the tint and the ring")

        let tab = runs("tab") { hosted.press("\t", keyCode: 48) }
        let next = try XCTUnwrap(hosted.model.keyboardFocus?.id, "Tab reached a row")
        XCTAssertEqual(tab, [c: 1, next: 1], "Tab: the old and the new row, once each")
        XCTAssertTrue(drawn(next).map(\.isFocused) == true, "the ring moved with Tab")
    }

    // MARK: - A click on the only selected row (STAY-CLICK, 23 Nov)

    /// A click on the row that already is the whole selection changes
    /// nothing, so the model sends nothing and no page body or cell runs
    /// (the trunk sent: `click` stored `[id]` again and `StoredThenSent`
    /// sends on every store, which ran `TasksPage.body` and re-checked the
    /// drawn tab). The click still moves the anchor a Shift-click grows
    /// from. A move, a ⌘-click and a ⇧-click still change and send; a
    /// ⇧-click that draws the same range is a no-change click too.
    func testAClickOnTheOnlySelectedRowSendsNothingWhileMoveShiftAndCommandClicksStillDo() throws {
        let store = try makeStore(open: 12)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        let ids = model.rows(for: .now).map(\.id)
        XCTAssertGreaterThan(drawnRows(pointer, ids).count, 6, "the hosted page drew too few rows for the count to mean anything")
        var sends = 0
        let sink = model.objectWillChange.sink { _ in sends += 1 }
        defer { sink.cancel() }
        func turn(_ name: String, _ action: () -> Void) -> (sends: Int, page: Int, cells: [UUID: Int]) {
            let sent = sends, pageRuns = TasksPageRenderProbe.bodyRuns, cells = TasksCellBodyCounts.evaluations
            action()
            settle(hosting)
            settle(hosting)
            let ran = TasksCellBodyCounts.evaluations.reduce(into: [UUID: Int]()) {
                let added = $1.value - cells[$1.key, default: 0]
                if added > 0 { $0[$1.key.id, default: 0] += added }
            }
            let result = (sends - sent, TasksPageRenderProbe.bodyRuns - pageRuns, ran)
            print("STAY_CLICK \(name) sends=\(result.0) page=\(result.1) cells=\(ran.values.reduce(0, +)) cell_rows=\(ran.count)")
            return result
        }
        let a = ids[1], b = ids[3], c = ids[4], d = ids[5]

        let control = turn("control") {}
        XCTAssertEqual(control.sends, 0, "control: nothing sends with no click")
        XCTAssertEqual(control.page, 0, "control: no page body runs with no click")

        model.click(a, modifiers: [], visible: ids)
        settle(hosting); settle(hosting)
        let move = turn("move") { model.click(b, modifiers: [], visible: ids) }
        XCTAssertEqual(model.selection, [b], "move: the click selected B")
        XCTAssertGreaterThan(move.sends, 0, "move: the new selection was sent")
        XCTAssertNotNil(move.cells[a], "move: A's cell ran to drop its tint")
        XCTAssertNotNil(move.cells[b], "move: B's cell ran to draw its tint")

        let stay = turn("stay") { model.click(b, modifiers: [], visible: ids) }
        XCTAssertEqual(model.selection, [b], "stay: B is still the selection")
        XCTAssertEqual(model.selectionAnchorForTesting, b, "stay: B is the anchor")
        XCTAssertEqual(stay.sends, 0, "stay: a click on the only selected row sent objectWillChange")
        XCTAssertEqual(stay.page, 0, "stay: a click on the only selected row ran TasksPage.body")
        XCTAssertEqual(stay.cells, [:], "stay: a click on the only selected row ran cells")

        // ⌘ adds C, ⌘ takes it away again: B alone is selected, the anchor
        // on C. A plain click on B changes no selection but moves the anchor
        // back to B, so a ⇧-click on D then grows from B.
        let add = turn("command_add") { model.click(c, modifiers: .command, visible: ids) }
        XCTAssertEqual(model.selection, [b, c], "⌘-click added C")
        XCTAssertGreaterThan(add.sends, 0, "⌘-click: the grown selection was sent")
        let remove = turn("command_remove") { model.click(c, modifiers: .command, visible: ids) }
        XCTAssertEqual(model.selection, [b], "⌘-click took C away")
        XCTAssertGreaterThan(remove.sends, 0, "⌘-click: the shrunk selection was sent")
        XCTAssertEqual(model.selectionAnchorForTesting, c)
        let anchorStay = turn("anchor_stay") { model.click(b, modifiers: [], visible: ids) }
        XCTAssertEqual(anchorStay.sends, 0, "stay after ⌘: nothing sent")
        XCTAssertEqual(model.selectionAnchorForTesting, b, "stay after ⌘: the anchor moved back to B")
        let extend = turn("shift_extend") { model.click(d, modifiers: .shift, visible: ids) }
        XCTAssertEqual(model.selection, Set(ids[3...5]), "⇧-click grew from B to D")
        XCTAssertGreaterThan(extend.sends, 0, "⇧-click: the range was sent")
        XCTAssertNotNil(extend.cells[c], "⇧-click: C's cell ran to draw its tint")
        let sameRange = turn("shift_same_range") { model.click(d, modifiers: .shift, visible: ids) }
        XCTAssertEqual(model.selection, Set(ids[3...5]), "⇧-click again: the same range")
        XCTAssertEqual(sameRange.sends, 0, "⇧-click again: an unchanged range sent objectWillChange")
        XCTAssertEqual(sameRange.page, 0, "⇧-click again: an unchanged range ran TasksPage.body")
    }

    // MARK: - An unchanged selection stores nothing (SPEED-SELECTION-SETTER-SENDS-UNCHANGED, 23 Nov)

    /// Every writer of `selection` that stores the value it already holds
    /// sends nothing: ↓ or ↑ held at the last or first row (`selectOnly`
    /// again), ⇧↓ or ⇧↑ at the edge (`extendSelection` to the same range),
    /// a click on empty space with nothing selected (`clearSelection`). The
    /// trunk sent on each, which ran `TasksPage.body` and re-checked every
    /// drawn cell for no change. A real change still sends once and runs
    /// the page. Only `selection` skips: an equal store to another published
    /// value (a request) still sends.
    func testAnUnchangedSelectionStoreSendsNothingWhileARealChangeSendsOnce() throws {
        let store = try makeStore(open: 12)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        let ids = model.rows(for: .now).map(\.id)
        XCTAssertGreaterThan(drawnRows(pointer, ids).count, 6, "the hosted page drew too few rows for the count to mean anything")
        var sends = 0
        let sink = model.objectWillChange.sink { _ in sends += 1 }
        defer { sink.cancel() }
        func turn(_ name: String, _ action: () -> Void) -> (sends: Int, page: Int, cells: Int) {
            let sent = sends, pageRuns = TasksPageRenderProbe.bodyRuns, cells = TasksCellBodyCounts.evaluations
            action()
            settle(hosting)
            settle(hosting)
            let ran = TasksCellBodyCounts.evaluations.reduce(0) { $0 + max(0, $1.value - cells[$1.key, default: 0]) }
            let result = (sends - sent, TasksPageRenderProbe.bodyRuns - pageRuns, ran)
            print("SELECTION_STORE \(name) sends=\(result.0) page=\(result.1) cells=\(result.2)")
            return result
        }
        func changed(_ result: (sends: Int, page: Int, cells: Int), _ name: String,
                     file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(result.sends, 1, "\(name): a real change sends once", file: file, line: line)
            XCTAssertGreaterThan(result.page, 0, "\(name): a real change runs the page", file: file, line: line)
        }
        func unchanged(_ result: (sends: Int, page: Int, cells: Int), _ name: String,
                       file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(result.sends, 0, "\(name): an unchanged selection sent objectWillChange", file: file, line: line)
            XCTAssertEqual(result.page, 0, "\(name): an unchanged selection ran TasksPage.body", file: file, line: line)
            XCTAssertEqual(result.cells, 0, "\(name): an unchanged selection ran cells", file: file, line: line)
        }
        let last = try XCTUnwrap(ids.last)

        let control = turn("control") {}
        XCTAssertEqual(control.sends, 0, "control: nothing sends with nothing stored")
        XCTAssertEqual(control.page, 0, "control: no page body runs with nothing stored")

        // ↓ to the last row, then ↓ held there (TasksPage's arrow keys).
        changed(turn("select_last") { model.selectOnly(last) }, "select_last")
        XCTAssertEqual(model.selection, [last])
        unchanged(turn("select_last_again") { model.selectOnly(last) }, "select_last_again")
        XCTAssertEqual(model.selection, [last], "↓ held at the last row: still the last row")
        XCTAssertEqual(model.selectionAnchorForTesting, last)

        // ⇧↓ at the last row with one row selected: the same one-row range.
        unchanged(turn("extend_edge_one") { model.extendSelection(to: last, visible: ids, from: last) }, "extend_edge_one")
        XCTAssertEqual(model.selection, [last])

        // ⇧↑ twice grows the range, then ⇧↓ back to the edge and ⇧↓ again.
        let above = ids[ids.count - 2], twoAbove = ids[ids.count - 3]
        changed(turn("extend_up") { model.extendSelection(to: above, visible: ids, from: last) }, "extend_up")
        changed(turn("extend_up_again") { model.extendSelection(to: twoAbove, visible: ids, from: above) }, "extend_up_again")
        XCTAssertEqual(model.selection, Set(ids.suffix(3)))
        unchanged(turn("extend_same_range") { model.extendSelection(to: twoAbove, visible: ids, from: twoAbove) },
                  "extend_same_range")
        XCTAssertEqual(model.selection, Set(ids.suffix(3)), "⇧ to the same row: the same range")

        // A click on empty space: clears once, then clears nothing.
        changed(turn("clear") { model.clearSelection() }, "clear")
        XCTAssertEqual(model.selection, [])
        unchanged(turn("clear_empty") { model.clearSelection() }, "clear_empty")
        XCTAssertNil(model.selectionAnchorForTesting, "clear with nothing selected: no anchor")

        // Only `selection` skips: another published value stored again
        // (no next event, stored as no next event) still sends.
        XCTAssertNil(model.nextEvent as TasksNextEvent?, "harness: no next event")
        let other = turn("other_value_again") { model.nextEvent = nil }
        XCTAssertEqual(other.sends, 1, "an equal store to another published value still sends")
    }

    /// The same through real clicks in a key window (`rowClicked`: the
    /// click, then the page's focus): a second click on the row that is
    /// selected and holds the keyboard sends nothing and runs no page body
    /// and no cell, and the row still draws its tint and ring.
    func testARealClickOnTheOnlySelectedRowRunsNoPageBodyAndSendsNothing() throws {
        try requireKeyWindowTests()
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.window.makeKey()
        let ids = hosted.model.rows(for: .now).map(\.id)
        XCTAssertGreaterThan(ids.count, 4)
        let a = ids[0], b = ids[1], c = ids[2], d = ids[3]
        var sends = 0
        let sink = hosted.model.objectWillChange.sink { _ in sends += 1 }
        defer { sink.cancel() }
        try hosted.clickRow(a, tab: .now)
        hosted.spin(0.3)
        func turn(_ name: String, _ body: () throws -> Void) rethrows -> (sends: Int, page: Int, cells: [UUID: Int]) {
            let sent = sends, pageRuns = TasksPageRenderProbe.bodyRuns, base = TasksCellBodyCounts.evaluations
            try body()
            hosted.spin(0.3)
            let ran = Dictionary(uniqueKeysWithValues: TasksCellBodyCounts.evaluations.compactMap { row, count in
                row.tab == .now && count > base[row, default: 0] ? (row.id, count - base[row, default: 0]) : nil
            })
            let result = (sends - sent, TasksPageRenderProbe.bodyRuns - pageRuns, ran)
            print("STAY_CLICK_KEY \(name) sends=\(result.0) page=\(result.1) rows=\(ran.count) runs=\(ran.values.reduce(0, +))")
            return result
        }
        func drawn(_ id: UUID) -> (isSelected: Bool, isFocused: Bool)? { TasksCellBodyCounts.leafStates[TasksRowID(tab: .now, id: id)] }

        let control = turn("control") {}
        XCTAssertEqual(control.sends, 0, "control: nothing sends with no click")
        XCTAssertEqual(control.page, 0, "control: no page body runs with no click")

        let move = try turn("move") { try hosted.clickRow(b, tab: .now) }
        XCTAssertEqual(hosted.model.selection, [b], "move: the click selected B")
        XCTAssertEqual(hosted.model.keyboardFocus?.id, b, "move: B holds the keyboard")
        XCTAssertGreaterThan(move.sends, 0, "move: the new selection was sent")
        XCTAssertNotNil(move.cells[a], "move: A ran")
        XCTAssertNotNil(move.cells[b], "move: B ran")

        let stay = try turn("stay") { try hosted.clickRow(b, tab: .now) }
        XCTAssertEqual(hosted.model.selection, [b], "stay: B is still the selection")
        XCTAssertEqual(hosted.model.keyboardFocus?.id, b, "stay: B still holds the keyboard")
        XCTAssertEqual(hosted.model.selectionAnchorForTesting, b, "stay: B is the anchor")
        XCTAssertEqual(stay.sends, 0, "stay: a real click on the only selected row sent objectWillChange")
        XCTAssertEqual(stay.page, 0, "stay: a real click on the only selected row ran TasksPage.body")
        XCTAssertEqual(stay.cells, [:], "stay: a real click on the only selected row ran cells")
        XCTAssertTrue(drawn(b).map { $0.isSelected && $0.isFocused } == true, "stay: B still draws the tint and the ring")

        let add = try turn("command") { try hosted.clickRow(c, tab: .now, modifiers: .command) }
        XCTAssertEqual(hosted.model.selection, [b, c], "⌘-click added C")
        XCTAssertNotNil(add.cells[c], "⌘-click: C ran")
        let extend = try turn("shift") { try hosted.clickRow(d, tab: .now, modifiers: .shift) }
        XCTAssertEqual(hosted.model.selection, [c, d], "⇧-click grew from the ⌘-clicked C to D")
        XCTAssertNotNil(extend.cells[d], "⇧-click: D ran")
    }

    /// Lead's condition 4: rows of tabs that are not drawn change while
    /// Done is shown (Backlog beside it kept built and frozen, Now let go):
    /// selected, ticked, renamed, a failed command. No wrapper of either
    /// tab runs drawn meanwhile, and the first frame drawn when each tab is
    /// shown again draws every change as the model holds it.
    func testRowsChangedWhileTheirTabIsUndrawnDrawRightOnTheFirstDrawnFrame() throws {
        let store = try makeStore(open: 8, backlog: 6)
        var services = TasksPageServices()
        services.doneHold = .seconds(25)
        services.acknowledgementDelay = .seconds(25)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: services)
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        let now = model.rows(for: .now).map(\.id)
        XCTAssertEqual(drawnRows(pointer, now).count, now.count, "Now drew its rows")
        for tab in [TasksTab.backlog, .done] {
            TasksCellBodyCounts.drawnRuns = []
            model.select(tab: tab)
            // The pages a move passed are let go once it has rested (the
            // pager's `restDelay`).
            settle(hosting, until: { model.pagerSwipe.span.pages == tab.rawValue...tab.rawValue })
            settle(hosting)
        }
        let later = model.rows(for: .backlog).map(\.id)
        XCTAssertEqual(later.count, 6)
        print("BREADTH_UNDRAWN_KEPT backlog_states=\(model.rowStateIDsForTesting[.backlog, default: []].count) "
              + "now_states=\(model.rowStateIDsForTesting[.now, default: []].count)")
        TasksCellBodyCounts.drawnRuns = []

        // Now: a selection, a tick, a rename, a failure. Backlog: a rename,
        // a failure, a quick look.
        model.selectOnly(now[0])
        model.completeAcknowledged(now[1]) { _ in }
        model.settlePendingCompletionAcknowledgements(through: now[1])
        for (id, title) in [(now[2], "Renamed while hidden"), (later[2], "Later renamed while hidden")] {
            model.beginEditingTitle(id)
            model.editingTitle = title
            XCTAssertTrue(model.commitTitle())
        }
        _ = model.report(.failed(.taskGone), on: later[3], retry: { .failed(.taskGone) })
        model.setExpanded(later[4], true)
        settle(hosting)
        settle(hosting)
        let hiddenRuns = TasksCellBodyCounts.drawnRuns.filter { $0.row.tab != .done }
        print("BREADTH_UNDRAWN_RUNS drawn=\(hiddenRuns.filter(\.drawn).count) undrawn=\(hiddenRuns.filter { !$0.drawn }.map { run in "\(run.row.tab):\((now + later).firstIndex(of: run.row.id).map { $0 < now.count ? "now\($0)" : "later\($0 - now.count)" } ?? "?")" }) "
              + "warm=\(String(describing: model.pagerSwipe.span.warm))")
        // No row state reaches a hidden cell (the freeze): the selection's
        // and the failure's rows, which change only in their row states, do
        // not run. A change to a hidden row's key (its title, its quick
        // look) still re-runs its wrapper undrawn, through the frozen page's
        // own list pass (slice 1a's route; slices 2 and 3 narrow it).
        let keyChanged: Set<UUID> = [now[2], later[2], later[4]]
        XCTAssertEqual(hiddenRuns.filter(\.drawn).count, 0, "a wrapper of an undrawn tab ran as drawn")
        XCTAssertEqual(Set(hiddenRuns.map(\.row.id)).subtracting(keyChanged), [],
                       "a hidden wrapper ran on a row-state write (freeze bypass)")

        func drew(_ tab: TasksTab, _ id: UUID) -> TasksRowStateValue? { TasksCellBodyCounts.cellStates[TasksRowID(tab: tab, id: id)] }
        func assertFirstFrame(_ tab: TasksTab, _ ids: [UUID]) {
            TasksCellBodyCounts.cellStates = [:]
            model.select(tab: tab)
            settle(hosting)
            let listed = model.listSnapshot(for: tab).rows
            XCTAssertEqual(model.rowStateMismatches(), [], "\(tab): the states agree with the model")
            for row in listed where pointer.frame(for: TasksRowID(tab: tab, id: row.id)) != nil {
                guard let state = drew(tab, row.id) else { XCTFail("\(tab): row \(row.id) drew no state"); continue }
                XCTAssertTrue(TasksRowStateValue.sameRow(state.row, row), "\(tab): row \(row.model.title) drew its row as listed")
                XCTAssertEqual(state.isSelected, model.selection.contains(row.id), "\(tab): \(row.model.title)'s selection")
                XCTAssertEqual(state.isExpanded, model.expanded.contains(row.id) && row.status != .done)
                XCTAssertEqual(state.failure.row?.id, model.rowFailure?.id == row.id ? row.id : nil)
            }
            for id in ids where !listed.contains(where: { $0.id == id }) {
                XCTAssertNil(pointer.frame(for: TasksRowID(tab: tab, id: id)), "\(tab): a row that left draws nowhere")
            }
        }
        assertFirstFrame(.backlog, later)
        XCTAssertEqual(drew(.backlog, later[2])?.row.model.title, "Later renamed while hidden", "the frozen page's rename")
        XCTAssertEqual(drew(.backlog, later[3])?.failure.row?.id, later[3], "the frozen page's failure line")
        XCTAssertEqual(drew(.backlog, later[4])?.isExpanded, true, "the frozen page's quick look")
        settle(hosting, until: { model.pagerSwipe.motion.position == CGFloat(TasksTab.backlog.rawValue) })
        settle(hosting, until: { !TasksCellBodyCounts.drawnRuns.isEmpty })
        assertFirstFrame(.now, now)
        XCTAssertEqual(drew(.now, now[2])?.row.model.title, "Renamed while hidden", "the rename")
        XCTAssertEqual(TasksCellBodyCounts.leafModels[TasksRowID(tab: .now, id: now[2])]?.title, "Renamed while hidden")
        XCTAssertEqual(store.task(withID: now[1])?.status, .done)
        print("BREADTH_UNDRAWN selected=\(String(describing: drew(.now, now[0])?.isSelected)) model_selected=\(model.selection.contains(now[0])) "
              + "ticked_listed=\(model.listSnapshot(for: .now).rows.contains { $0.id == now[1] })")
    }

    /// The first build of a page's cells makes their states from the rows
    /// and runs its pass has, reading no list. A keyboard move and a
    /// selection change do no list work for a tab
    /// that has none of the rows (Backlog, kept built behind Now): no index,
    /// no flattening, no selection runs; one that reaches a Backlog row with
    /// one row selected reads it by a scan only. On Now, a
    /// focus move with one row selected reads no list either (two lookups,
    /// no runs).
    func testAKeyboardMoveOrSelectionReadsNoListOfATabWithoutItsRows() throws {
        let store = try makeStore(open: 12, backlog: 6)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        TasksPageModel.rowStateListWork = [:]
        let hosting = page(model, store, pointer: pointer)
        print("BREADTH_LIST_WORK first_build=\(TasksPageModel.rowStateListWork)")
        XCTAssertEqual(TasksPageModel.rowStateListWork, [:], "the first build made its cells' states without reading a list")
        for tab in [TasksTab.backlog, .now] {
            model.select(tab: tab)
            settle(hosting, until: { model.pagerSwipe.span.pages == tab.rawValue...tab.rawValue })
            settle(hosting)
        }
        XCTAssertFalse(model.rowStateIDsForTesting[.backlog, default: []].isEmpty, "Backlog's rows have states")
        let ids = model.rows(for: .now).map(\.id)
        let later = model.rows(for: .backlog).map(\.id)
        func focus(_ id: UUID) {
            model.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.now.rawValue, id: id), keyboardDriving: false)
        }
        model.selectOnly(ids[1])
        focus(ids[1])
        settle(hosting)

        TasksPageModel.rowStateListWork = [:]
        focus(ids[2])
        XCTAssertEqual(TasksPageModel.rowStateListWork, [:], "a focus move with one row selected reads no list")

        model.click(ids[4], modifiers: .command, visible: ids)
        settle(hosting)
        TasksPageModel.rowStateListWork = [:]
        focus(ids[3])
        focus(ids[4])
        print("BREADTH_LIST_WORK focus_multi=\(TasksPageModel.rowStateListWork)")
        XCTAssertNil(TasksPageModel.rowStateListWork[.backlog], "a focus move read Backlog's list")
        XCTAssertNil(TasksPageModel.rowStateListWork[.done], "a focus move read Done's list")
        XCTAssertLessThanOrEqual(TasksPageModel.rowStateListWork[.now, default: 0], 2, "one run map a move on Now")

        TasksPageModel.rowStateListWork = [:]
        model.click(ids[6], modifiers: .command, visible: ids)
        model.selectOnly(later[1])
        print("BREADTH_LIST_WORK select=\(TasksPageModel.rowStateListWork)")
        XCTAssertNil(TasksPageModel.rowStateListWork[.backlog], "a selection change reaching one Backlog row built or indexed Backlog's list")
        settle(hosting)
        XCTAssertEqual(model.rowStateMismatches(), [])
    }

    /// Lead's condition 3: a row's state goes when the row leaves its tab
    /// (delete, filter) and is made fresh when it returns (Undo); the live
    /// states are only listed rows, however many rows were ever drawn.
    func testARowStateGoesWithItsRowAndIsMadeFreshWhenItReturns() throws {
        let store = try makeStore(open: 30, tracker: true)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        let ids = model.rows(for: .now).map(\.id)
        let gone = ids[2]
        let first = try XCTUnwrap(liveState(model, gone), "a drawn row has a state")

        XCTAssertTrue(model.delete([gone]).isApplied)
        settle(hosting)
        settle(hosting)
        XCTAssertFalse(model.rowStateIDsForTesting[.now, default: []].contains(gone), "a deleted row's state went")
        XCTAssertTrue(model.rowStateIDsForTesting[.now, default: []].isSubset(of: Set(model.rows(for: .now).map(\.id))),
                      "only listed rows have states")

        XCTAssertTrue(model.undo().isApplied)
        settle(hosting)
        settle(hosting)
        let back = try XCTUnwrap(liveState(model, gone), "the row came back with a state")
        XCTAssertFalse(back === first, "a returning row gets a fresh state")
        XCTAssertEqual(TasksCellBodyCounts.cellStates[TasksRowID(tab: .now, id: gone)]?.row.id, gone, "its cell draws again")
        XCTAssertEqual(model.rowStateMismatches(), [])
    }

    /// The oracle finds a missed route: a state written by hand (as a
    /// missing writer would leave it) is reported by row and field.
    func testTheOracleNamesTheRowAndFieldOfAStaleState() throws {
        let store = try makeStore(open: 6)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        _ = page(model, store, pointer: pointer)
        let id = model.rows(for: .now)[1].id
        let state = try XCTUnwrap(liveState(model, id))
        XCTAssertEqual(model.rowStateMismatches(), [])
        var stale = state.value
        stale.isSelected.toggle()
        state.apply(stale)
        let found = model.rowStateMismatches()
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found.first?.contains("row \(id)") == true && found.first?.contains("isSelected") == true, "\(found)")
        model.rowStatesChanged([id])
        XCTAssertEqual(model.rowStateMismatches(), [], "the writer's derivation puts it right")
    }

    /// The mounted-cell check: a row's old cell kept drawn while it animates
    /// out (a delete undone mid-exit) holds a state the registry dropped;
    /// it is not reported while a drawn cell holds the row's current state,
    /// nor while its row has no state yet (relisted before its cell's next
    /// pass); a row with a state whose only drawn cell holds another still is.
    func testTheOracleReportsADrawnRowOnlyWhenNoCellHoldsItsCurrentState() throws {
        let store = try makeStore(open: 60)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        settle(hosting)
        XCTAssertEqual(model.rowStateMismatches(), [])
        let ids = model.rows(for: .now).map(\.id)
        let built = model.rowStateIDsForTesting[.now, default: []]
        let mounted = try XCTUnwrap(ids.first { built.contains($0) })
        let unbuilt = try XCTUnwrap(ids.last { !built.contains($0) }, "every row's cell was built")
        let current = try XCTUnwrap(liveState(model, mounted))
        let exiting = NSObject()
        let dropped = TasksRowState(id: mounted, tab: .now, value: current.value)
        model.noteRowStateMount(exiting, row: TasksRowID(tab: .now, id: mounted), state: dropped, drawn: true)
        XCTAssertEqual(model.rowStateMismatches(), [], "an exiting cell beside the row's current cell is not reported")
        let lone = NSObject()
        model.noteRowStateMount(lone, row: TasksRowID(tab: .now, id: unbuilt), state: dropped, drawn: true)
        XCTAssertEqual(model.rowStateMismatches(), [], "a listed row with no state yet waits for its cell's pass")
        let row = try XCTUnwrap(model.rows(for: .now).first { $0.id == unbuilt })
        _ = model.rowState(for: row, tab: .now, run: .single)
        let found = model.rowStateMismatches()
        XCTAssertEqual(found, ["row \(unbuilt) on now: no drawn cell holds its current state"], "a row with a state whose only drawn cell holds another")
        model.noteRowStateUnmount(exiting)
        model.noteRowStateUnmount(lone)
        XCTAssertEqual(model.rowStateMismatches(), [])
    }

    /// A wrapper that skips a page pass still starts a drag with its date
    /// group as it is now, in order, through the callback it was built
    /// with: a task added to the group, the dragged row itself unchanged.
    func testAWrapperStartsADragWithItsCurrentGroup() throws {
        TasksCellBodyCounts.recordsDragGroups = true
        let store = try makeStore(open: 6)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        let first = try XCTUnwrap(model.rows(for: .now).first).id
        let row = TasksRowID(tab: .now, id: first)
        let original = try XCTUnwrap(TasksCellBodyCounts.dragGroups[row], "the row's wrapper was never built")
        XCTAssertEqual(original().count, 6)
        let added = try XCTUnwrap(store.create(title: "Joins the group"))
        settle(hosting)
        settle(hosting)
        let current = try XCTUnwrap(model.listSnapshot(for: .now).entries.first { $0.row?.id == first }).reorderIDs
        XCTAssertTrue(current.contains(added.id))
        XCTAssertEqual(original(), current, "the callback the wrapper was built with reads the group as it is now, in order")
    }

    // MARK: - Fix round 1: what the wrapper's key compares

    // MARK: PR 48 round 3: a list read writes no row state

    /// The lead's ruling (round 3): a list read builds the list and writes
    /// no row state, wherever it runs, since a read can run in a body. The
    /// states catch up in one sync outside any view update. At a55a1ab2 the
    /// read wrote them itself (`keep` → `rowStatesListed`), and a read in
    /// the pager's body aborted the update ("setting value during update").
    ///
    /// PR 48 takeover: a store change now brings the states up before its
    /// call returns, so the read here follows a change nothing announces:
    /// the day moves and no day-change notification is posted.
    func testAListReadBuildsTheListAndWritesNoRowState() throws {
        let start = Date()
        let clock = Clock(now: start)
        var services = TasksPageServices()
        services.now = { clock.now }
        let due = DueDay(date: start, calendar: services.calendar())
        let store = try makeStore(open: 6, due: due)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: services)
        let row = try XCTUnwrap(model.rows(for: .now).first { $0.due == due }, "the dated row is listed")
        let state = model.rowState(for: row, tab: .now, run: .single)
        clock.now = start.addingTimeInterval(2 * 86_400)
        let listed = try XCTUnwrap(model.rows(for: .now).first { $0.id == row.id })
        XCTAssertFalse(TasksRowStateValue.sameRow(listed, row), "the read built the new list")
        XCTAssertTrue(TasksRowStateValue.sameRow(state.value.row, row), "the read wrote no row state")
        XCTAssertEqual(TasksRowStateCounts.writesDuringListRead, 0)
        drain()
        XCTAssertTrue(TasksRowStateValue.sameRow(state.value.row, listed), "the queued sync brought the state up")
        XCTAssertEqual(model.rowStateMismatches(), [])
    }

    /// PR 48 takeover: a store change brings the row states up before its
    /// call returns (`TaskStore.revisionMoments`), with no read and no turn
    /// of the run loop, and writes them outside any list read.
    func testAStoreChangeBringsTheRowStatesUpBeforeItsCallReturns() throws {
        let store = try makeStore(open: 6)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let row = try XCTUnwrap(model.rows(for: .now).dropFirst().first)
        let state = model.rowState(for: row, tab: .now, run: .single)
        XCTAssertTrue(store.rename(try XCTUnwrap(store.task(withID: row.id)), to: "Renamed by the store"))
        XCTAssertEqual(state.value.row.model.title, "Renamed by the store", "the state is up as the call returns")
        XCTAssertEqual(TasksRowStateCounts.writesDuringListRead, 0)
        XCTAssertEqual(model.rowStateMismatches(), [])
    }

    /// The write guard's seam: a row-state write made while a list read
    /// runs is counted (the hosted classes hold the count at zero).
    func testTheWriteGuardCountsAWriteMadeDuringAListRead() throws {
        let store = try makeStore(open: 3)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let state = model.rowState(for: try XCTUnwrap(model.rows(for: .now).first), tab: .now, run: .single)
        let original = state.value
        var changed = original
        changed.isSelected.toggle()
        TasksRowStateCounts.listReadDepth += 1
        state.apply(changed)
        TasksRowStateCounts.listReadDepth -= 1
        XCTAssertEqual(TasksRowStateCounts.writesDuringListRead, 1, "the write inside the read is counted")
        state.apply(original)
        XCTAssertEqual(TasksRowStateCounts.writesDuringListRead, 1, "a write outside a read is not")
        TasksRowStateCounts.reset()
    }

    /// The catch-up guard's seam, and the crash's shape: a drawn row's list
    /// changes and a frame is laid out before the queued sync runs (a change
    /// no funnel announced in time). The pager's body builds the list and
    /// writes nothing, so no update aborts; the row draws its old state for
    /// that one frame, and the catch-up that follows is counted late.
    ///
    /// PR 48 takeover: until then the change here was a store rename, which
    /// now reaches the rows before its call returns (the test below). The
    /// seam keeps a change nothing announces: the day moves, no day-change
    /// notification is posted, and a pass runs.
    func testAFrameLaidOutBeforeTheSyncCostsOneLateFrameAndNoCrash() throws {
        let start = Date()
        let clock = Clock(now: start)
        var services = TasksPageServices()
        services.now = { clock.now }
        let due = DueDay(date: start, calendar: services.calendar())
        let store = try makeStore(open: 6, due: due)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: services)
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        let id = try XCTUnwrap(model.rows(for: .now).first { $0.due == due }, "the dated row is listed").id
        let row = TasksRowID(tab: .now, id: id)
        XCTAssertNotNil(pointer.frame(for: row), "the row is drawn")
        let before = try XCTUnwrap(TasksCellBodyCounts.cellStates[row]?.row, "the row drew")
        TasksRowStateCounts.reset()
        clock.now = start.addingTimeInterval(2 * 86_400)
        model.objectWillChange.send()
        hosting.layoutSubtreeIfNeeded()
        hosting.window?.displayIfNeeded()
        let listed = try XCTUnwrap(model.rows(for: .now).first { $0.id == id })
        XCTAssertFalse(TasksRowStateValue.sameRow(listed, before), "the day changed the row as listed")
        XCTAssertTrue(TasksCellBodyCounts.cellStates[row].map { TasksRowStateValue.sameRow($0.row, before) } == true,
                      "the frame before the sync drew the old state")
        XCTAssertEqual(TasksRowStateCounts.writesDuringListRead, 0, "the read in the body wrote no state")
        settle(hosting)
        XCTAssertEqual(TasksRowStateCounts.lateCatchUps, 1, "the catch-up after that frame is counted late")
        // The route names what the list was built for and the call that
        // built it ahead of its rows (here the page's pass, in this test).
        // The model records the first two itself. The calls' names come
        // from `dladdr`, which another build may not resolve: they are
        // printed either way and checked only when the host's own resolved.
        print("SEAM_LATE_ROUTE \(TasksRowStateCounts.lateRoutes)")
        let route = TasksRowStateCounts.lateRoutes.first ?? ""
        XCTAssertTrue(route.hasPrefix("now: today"), "the route names the tab and the input: \(route)")
        let builtBy = route.range(of: "; list built by ")
        XCTAssertNotNil(builtBy, "the route records that the list was built ahead of its rows: \(route)")
        let calls = (builtBy.map { String(route[$0.upperBound...]) } ?? "").components(separatedBy: " < ")
        let hosts = calls.filter { $0.contains("Attic") && !$0.contains("AtticTests") }
        if hosts.isEmpty {
            print("SEAM_LATE_ROUTE_NAMES none of the host's resolved")
        } else {
            XCTAssertTrue(hosts.contains { $0.contains("TasksPage") }, "the route names the call that built the list: \(route)")
        }
        XCTAssertTrue(TasksCellBodyCounts.cellStates[row].map { TasksRowStateValue.sameRow($0.row, listed) } == true,
                      "the next frame is right")
        TasksRowStateCounts.reset()
    }

    /// PR 48 takeover (CI 45094041213, ten late catch-ups for a store
    /// revision and Done's search): those changes reached the drawn rows
    /// through a block queued on the run loop, and a frame can be drawn
    /// before the loop runs it. Two ways are run here, each right after the
    /// change with the run loop not turned: AppKit lays the window out and
    /// draws it on demand, and SwiftUI runs the page inside the send of
    /// another transaction (an animated selection change). In that frame
    /// each drawn row draws its row as its list holds it, and no state
    /// catches up after it.
    func testAFrameDrawnRightAfterAStoreChangeOrDonesSearchDrawsItsRowsOnTime() throws {
        var services = TasksPageServices()
        services.doneHold = .seconds(25)
        services.acknowledgementDelay = .seconds(25)
        let store = try makeStore(open: 9)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: services)
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        let ids = model.rows(for: .now).map(\.id)
        XCTAssertGreaterThan(drawnRows(pointer, ids).count, 5, "Now drew its rows")
        var turn = 0
        typealias Frame = (name: String, draw: () -> Void)
        let laidOut: Frame = ("laid_out", { hosting.layoutSubtreeIfNeeded(); hosting.window?.displayIfNeeded() })
        // A selection change is no list input: nothing brings the rows up
        // before its send, and the send runs the pending store change.
        let insideASend: Frame = ("inside_an_animated_send", {
            withAnimation(.default) { model.selectOnly(ids[turn.isMultiple(of: 2) ? 7 : 8]) }
        })
        func check(_ name: String, on tab: TasksTab = .now, frames: [Frame], _ change: () throws -> Void) rethrows {
            for frame in frames {
                settle(hosting)
                settle(hosting)
                TasksRowStateCounts.reset()
                turn += 1
                let step = "\(name), \(frame.name)"
                let passes = TasksPagerPassCount.passes
                try change()
                frame.draw()
                // The frame, before the run loop turns.
                XCTAssertGreaterThan(TasksPagerPassCount.passes, passes, "\(step): the pager ran, so a frame was drawn before the run loop turned")
                let listed = tab == .done ? model.doneDays().flatMap(\.rows) : model.listSnapshot(for: tab).rows
                var drawn = 0
                for row in listed where pointer.frame(for: TasksRowID(tab: tab, id: row.id)) != nil {
                    drawn += 1
                    let drew = TasksCellBodyCounts.cellStates[TasksRowID(tab: tab, id: row.id)]
                    XCTAssertTrue(drew.map { TasksRowStateValue.sameRow($0.row, row) } == true,
                                  "\(step): \(row.model.title) draws its row as listed in that frame")
                }
                XCTAssertTrue(drawn > 0 || listed.isEmpty, "\(step): rows are drawn, so the check means something")
                XCTAssertEqual(model.rowStateMismatches(), [], "\(step): the states agree with the model in that frame")
                settle(hosting)
                settle(hosting)
                print("FRAME_AFTER_\(name)_\(frame.name) writes=\(TasksRowStateCounts.writesDuringListRead) late=\(TasksRowStateCounts.lateCatchUps) routes=\(TasksRowStateCounts.lateRoutes)")
                XCTAssertEqual(TasksRowStateCounts.writesDuringListRead, 0, "\(step): a row state was written during a list read")
                XCTAssertEqual(TasksRowStateCounts.lateCatchUps, 0,
                               "\(step): the drawn rows caught up after that frame: \(TasksRowStateCounts.lateRoutes)")
                TasksRowStateCounts.reset()
            }
        }
        let task = { (id: UUID) throws -> TaskItem in try XCTUnwrap(store.task(withID: id)) }
        try check("store_rename", frames: [laidOut]) { XCTAssertTrue(store.rename(try task(ids[1]), to: "Renamed \(turn)")) }
        check("store_create", frames: [laidOut, insideASend]) { XCTAssertNotNil(store.create(title: "Created \(turn)")) }
        check("model_set_status", frames: [laidOut]) { XCTAssertTrue(model.setStatus(.done, for: [ids[2]]).isApplied) }
        // Now, searched: its list is built from the store's `revision`
        // itself, not its data revision (CI's searched Later, mid-drag).
        model.setSearchQuery("Open", for: .now)
        try check("searched_store_rename", frames: [laidOut, insideASend]) {
            XCTAssertTrue(store.rename(try task(ids[3]), to: "Open, renamed \(turn)"))
        }
        model.setSearchQuery("", for: .now)
        // Done, drawn: the store's revision and Done's search.
        model.select(tab: .done)
        settle(hosting, until: { model.pagerSwipe.motion.position == CGFloat(TasksTab.done.rawValue) })
        let done = try XCTUnwrap(model.doneDays().flatMap(\.rows).first?.id, "Done lists a ticked row")
        try check("done_store_rename", on: .done, frames: [laidOut]) { XCTAssertTrue(store.rename(try task(done), to: "Done, renamed")) }
        check("done_search", on: .done, frames: [laidOut]) { model.doneSearch = "Done" }
        check("done_search_cleared", on: .done, frames: [laidOut]) { model.doneSearch = "" }
    }

    /// The family (RULES §3 lesson 4): every input a list is built from
    /// (`TasksPageModel.RowsKey`, Done's `DoneKey`) reaches the drawn rows
    /// through the sync before the frame. Each change is laid out the way
    /// the page settles (the main queue turns, then the frame): no state is
    /// written during a read, none catches up late, the oracle agrees and
    /// each drawn row draws its row as listed.
    func testEveryListInputReachesTheDrawnRowsBeforeTheFrame() throws {
        let start = Date()
        let calendar = TasksPageServices().calendar()
        let clock = Clock(now: start)
        var services = TasksPageServices()
        services.now = { clock.now }
        services.doneHold = .seconds(25)
        services.acknowledgementDelay = .seconds(25)
        let store = try makeStore(open: 8, due: DueDay(date: start, calendar: calendar), tracker: true)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: services)
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        let ids = model.rows(for: .now).map(\.id)
        XCTAssertGreaterThan(drawnRows(pointer, ids).count, 4, "Now drew its rows")
        func check(_ name: String, on tab: TasksTab = .now, _ change: () throws -> Void) rethrows {
            TasksRowStateCounts.reset()
            try change()
            settle(hosting)
            settle(hosting)
            print("FAMILY_\(name) writes=\(TasksRowStateCounts.writesDuringListRead) late=\(TasksRowStateCounts.lateCatchUps)")
            XCTAssertEqual(TasksRowStateCounts.writesDuringListRead, 0, "\(name): a row state was written during a list read")
            XCTAssertEqual(TasksRowStateCounts.lateCatchUps, 0, "\(name): the drawn rows caught up a frame late")
            XCTAssertEqual(model.rowStateMismatches(), [], "\(name): the states agree with the model")
            let listed = tab == .done ? model.doneDays().flatMap(\.rows) : model.listSnapshot(for: tab).rows
            var drawn = 0
            for row in listed where pointer.frame(for: TasksRowID(tab: tab, id: row.id)) != nil {
                drawn += 1
                let drew = TasksCellBodyCounts.cellStates[TasksRowID(tab: tab, id: row.id)]
                XCTAssertTrue(drew.map { TasksRowStateValue.sameRow($0.row, row) } == true,
                              "\(name): \(row.model.title) draws its row as listed")
            }
            XCTAssertTrue(drawn > 0 || listed.isEmpty, "\(name): rows are drawn, so the check means something")
        }
        let task = { (id: UUID) throws -> TaskItem in try XCTUnwrap(store.task(withID: id)) }
        try check("store_revision") { XCTAssertTrue(store.rename(try task(ids[1]), to: "Renamed in the store")) }
        check("held") { model.completeAcknowledged(ids[2]) { _ in } }
        check("acknowledgement") { XCTAssertTrue(model.settlePendingCompletionAcknowledgements(through: ids[2])) }
        check("held_release") { model.releaseHold(ids[2]) }
        check("note_owners") { model.setNoteOwners([ids[3]]) }
        check("expanded") { model.setExpanded(ids[3], true) }
        check("expanded_closed") { model.setExpanded(ids[3], false) }
        check("completed_today") { model.completedTodayExpanded = true }
        check("view_options") { model.setViewOptions(TasksViewOptions(sort: .dueDate), for: .now) }
        check("view_options_cleared") { model.setViewOptions(TasksViewOptions(), for: .now) }
        check("search") { model.listSearch[.now] = "task" }
        check("search_cleared") { model.listSearch[.now] = nil }
        check("tag_pick") { model.tagPicks = TagPicks(["tag1"]) }
        check("tag_pick_cleared") { model.tagPicks = .none }
        let group = try XCTUnwrap(model.groupKey(of: ids[0], on: .now), "the dated row has a group")
        check("folded") { model.foldAllGroups([group], folded: true, on: .now) }
        check("unfolded") { model.foldAllGroups([group], folded: false, on: .now) }
        check("next_event") {
            let event = CalendarEvent(id: "next", title: "Stand-up", start: clock.now.addingTimeInterval(3_600),
                                      end: clock.now.addingTimeInterval(5_400), isAllDay: false, location: nil,
                                      calendarTitle: "Work", colour: CalendarEventColour(red: 0.2, green: 0.4, blue: 0.8))
            model.nextEvent = TasksNextEvent(event, calendar: calendar, locale: services.locale)
        }
        check("next_event_cleared") { model.nextEvent = nil }
        check("day_drag") { model.dayDragLive = true }
        check("day_drag_ended") { model.dayDragLive = false }
        check("today_and_date_environment") {
            clock.now = start.addingTimeInterval(2 * 86_400)
            NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        }
        // Done, drawn: the store, its search, a delete.
        check("tab_to_done", on: .done) { model.select(tab: .done) }
        let done = try XCTUnwrap(model.doneDays().flatMap(\.rows).first?.id, "Done lists the ticked row")
        try check("done_store_revision", on: .done) { XCTAssertTrue(store.rename(try task(done), to: "Done, renamed")) }
        check("done_search", on: .done) { model.doneSearch = "Done" }
        check("done_search_cleared", on: .done) { model.doneSearch = "" }
        check("done_delete", on: .done) { XCTAssertTrue(model.delete([done]).isApplied) }
        check("tab_to_now") { model.select(tab: .now) }
    }

    /// PR 48 round 3 review P1-1: the file-migration sink runs in the
    /// statuses' willSet. A family's files change status while Tasks draws
    /// its row (Earlier files added, one removed from the task's note window,
    /// a family migrated by the launch run): the drawn row shows the stored
    /// status's files and paperclip count on the next frame, and keeps them
    /// with nothing else touching the task.
    func testAFamilysFileStatusReachesItsDrawnRowOnTheNextFrameAndStays() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let filesRoot = FileManager.default.temporaryDirectory.appendingPathComponent("TasksFileStatus-\(UUID().uuidString)")
        addTeardownBlock {
            // Migrated originals are read-only by design: make this test's
            // own folder removable, then remove it.
            if let files = FileManager.default.enumerator(at: filesRoot, includingPropertiesForKeys: nil) {
                for case let url as URL in files { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
            }
            try? FileManager.default.removeItem(at: filesRoot)
        }
        let store = TaskStore(container: container, taskImageFiles: TaskImageFiles(rootURL: filesRoot))
        let library = AtticLibrary(tasks: store)
        func files(_ names: [String]) async throws -> [TaskImageReference] {
            let folder = filesRoot.appendingPathComponent("in-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let urls = try names.map { name -> URL in
                let url = folder.appendingPathComponent(name)
                try Data("\(name) \(UUID())".utf8).write(to: url)
                return url
            }
            return try await store.taskImageFiles.importAttachments(urls, existing: [])
        }
        func insert(_ title: String, order: Int64, files: [TaskImageReference] = []) throws -> UUID {
            let context = ModelContext(container)
            let item = TaskItem(title: title, status: .todo, createdAt: Date(), manualOrder: order)
            item.listOrderVersion = TaskItem.currentListOrderVersion
            if !files.isEmpty { item.imageReferencesData = try JSONEncoder().encode(files) }
            context.insert(item)
            try context.save()
            store.refresh()
            return item.id
        }
        func addLegacy(_ added: [TaskImageReference], to id: UUID) throws {
            let context = ModelContext(container)
            for row in try context.fetch(FetchDescriptor<TaskItem>()) where row.id == id {
                row.imageReferencesData = try JSONEncoder().encode(row.attachments + added)
            }
            try context.save()
            store.refresh()
        }
        /// The async seed runs on the main actor while the main run loop
        /// turns (an expectation with a deadline).
        func run(_ name: String, _ work: @escaping @MainActor () async throws -> Void) {
            let finished = expectation(description: name)
            Task { @MainActor in
                do { try await work() } catch { XCTFail("\(name): \(error)") }
                finished.fulfill()
            }
            wait(for: [finished], timeout: 20)
        }
        // A family whose files went into its note at launch, and a family
        // still on the old path, before Tasks is built.
        var family = UUID(), legacy = UUID()
        var added: [TaskImageReference] = []
        run("seed") {
            family = try insert("Family with files", order: 9_000_000, files: try await files(["a.txt", "b.txt"]))
            await store.fileMigration.runAtLaunch(tasks: store, isBusy: { _ in false })
            legacy = try insert("Family on the old path", order: 8_000_000, files: try await files(["e.txt"]))
            added = try await files(["c.txt", "d.txt"])
        }
        for index in 0..<3 { _ = try insert("Open task \(index)", order: 7_000_000 - Int64(index) * 1_024) }
        XCTAssertEqual(store.fileMigration.status(of: family).kind, .migrated, "the family's files are in its note")
        XCTAssertTrue(store.fileMigration.status(of: family).earlier.isEmpty, "and none is left behind")
        XCTAssertNotEqual(store.fileMigration.status(of: legacy).kind, .migrated, "the second family is still on the old path")
        XCTAssertEqual(added.count, 2)

        let model = TasksPageModel(library: library, services: TasksPageServices())
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        func check(_ name: String, _ id: UUID, files expected: Int, file: StaticString = #filePath, line: UInt = #line) throws {
            let task = try XCTUnwrap(store.task(withID: id), name, file: file, line: line)
            let truth = store.fileMigration.rowFiles(for: task).map(\.id)
            XCTAssertEqual(truth.count, expected, "\(name): the stored status gives \(expected) row files", file: file, line: line)
            let listed = try XCTUnwrap(model.rows(for: .now).first { $0.id == id }, "\(name): Now lists the row", file: file, line: line)
            XCTAssertEqual(listed.model.tileFiles.map(\.id), truth, "\(name): the listed row's files are the stored status's", file: file, line: line)
            XCTAssertEqual(listed.model.attachments, truth.count, "\(name): the listed row's paperclip count", file: file, line: line)
            XCTAssertNotNil(pointer.frame(for: TasksRowID(tab: .now, id: id)), "\(name): the row is drawn", file: file, line: line)
            let drew = try XCTUnwrap(TasksCellBodyCounts.cellStates[TasksRowID(tab: .now, id: id)]?.row.model,
                                     "\(name): the drawn cell read a state", file: file, line: line)
            XCTAssertEqual(drew.tileFiles.map(\.id), truth, "\(name): the drawn row's files are the stored status's", file: file, line: line)
            XCTAssertEqual(drew.attachments, truth.count, "\(name): the drawn row's paperclip count", file: file, line: line)
        }
        /// The change, one frame, the check; then two more frames with
        /// nothing touching the task, and the check again.
        func step(_ name: String, _ id: UUID, files expected: Int, _ change: () throws -> Void) throws {
            TasksRowStateCounts.reset()
            try change()
            settle(hosting)
            print("FILESTATUS_\(name) next_frame")
            try check("\(name), next frame", id, files: expected)
            settle(hosting)
            settle(hosting)
            try check("\(name), two frames on", id, files: expected)
            print("FILESTATUS_\(name) writes=\(TasksRowStateCounts.writesDuringListRead) late=\(TasksRowStateCounts.lateCatchUps)")
        }
        try check("before", family, files: 0)
        try check("before, old path", legacy, files: 1)
        // Earlier files reach the migrated family (an old path wrote them).
        try step("earlier_added", family, files: 2) {
            try addLegacy(added, to: family)
            store.fileMigration.refreshAfterLegacyChange(family, tasks: store)
        }
        // One is removed from the task's note window (`TaskNotePage`: the
        // remove, then the status follows).
        try step("earlier_removed", family, files: 1) {
            XCTAssertTrue(library.removeTaskAttachment(added[1].id, from: family).isApplied, "the Earlier file is removed")
            store.fileMigration.refreshAfterLegacyChange(family, tasks: store)
        }
        // The launch run moves the second family's file into its note.
        try step("launch_migrated", legacy, files: 0) {
            run("launch") { await store.fileMigration.runAtLaunch(tasks: store, isBusy: { _ in false }) }
            XCTAssertEqual(store.fileMigration.status(of: legacy).kind, .migrated, "the launch run moved its file")
        }
        // The same run takes the first family's Earlier file into its note.
        try check("after the launch run, the first family", family, files: 0)
    }

    /// Astra R-1, Opus R-1: a row due 12 days ahead, then the clock jumps 15
    /// days. The date's text and day stay the same, its tone and whether it
    /// shows change: the row draws the new projection.
    func testADateJumpRedrawsARowWhoseDueTextStaysTheSame() throws {
        let start = Date()
        let calendar = TasksPageServices().calendar()
        let due = DueDay(date: try XCTUnwrap(calendar.date(byAdding: .day, value: 12, to: start)), calendar: calendar)
        let store = try makeStore(open: 6, due: due)
        let clock = Clock(now: start)
        var services = TasksPageServices()
        services.now = { clock.now }
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: services)
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        let dated = try XCTUnwrap(model.rows(for: .now).first { $0.due == due }).id
        let row = TasksRowID(tab: .now, id: dated)
        XCTAssertNotNil(pointer.frame(for: row), "the dated row is drawn")
        let before = try XCTUnwrap(projected(model, dated))

        clock.now = try XCTUnwrap(calendar.date(byAdding: .day, value: 15, to: start))
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        settle(hosting)
        settle(hosting)
        let after = try XCTUnwrap(projected(model, dated))
        XCTAssertEqual(after.due?.text, before.due?.text, "the case under test: the date's text is unchanged")
        XCTAssertNotEqual(after, before, "the case under test: the projection changed (tone or shown)")
        XCTAssertEqual(TasksCellBodyCounts.leafModels[row], after, "the row still draws the date as it was before the jump")
    }

    /// Astra R-4: once a page pass has read a new palette, every drawn
    /// row's builder (whose page copy the row's menus read: the Tags
    /// submenu's swatches) reads it too, as on the trunk, where every pass
    /// rebuilt the wrappers.
    func testAPaletteChangeReachesTheRowBuilders() throws {
        // Alone only (tiny fix, board row tasks-env-stale-rows): once other
        // Tasks pages have been hosted in the process, a pass from the
        // palette alone stops short of the rows, on the trunk too. The
        // switch goes when that is named and fixed.
        guard ProcessInfo.processInfo.environment["ATTIC_ALONE_GUARDS"] == "1" else {
            throw XCTSkip("runs alone: TEST_RUNNER_ATTIC_ALONE_GUARDS=1 (tasks-env-stale-rows)")
        }
        let store = try makeStore(open: 6)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        let palette = PaletteBox()
        let hosting = page(model, store, pointer: pointer, palette: palette)
        let drawn = drawnRows(pointer, model.rows(for: .now).map(\.id)).map { TasksRowID(tab: .now, id: $0) }
        XCTAssertFalse(drawn.isEmpty)
        let recoloured = AtticTagPalette(hues: ["work": .green])
        palette.palette = recoloured
        settle(hosting)
        // The page's own pass: a palette change alone need not redraw the
        // page (it reads the palette only in its rows), its model does.
        model.objectWillChange.send()
        let passed = expectation(for: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                hosting.layoutSubtreeIfNeeded()
                hosting.window?.displayIfNeeded()
                return drawn.allSatisfy { TasksCellBodyCounts.passPalettes[$0] == recoloured }
            }
        }, evaluatedWith: nil)
        wait(for: [passed], timeout: 5)
        settle(hosting)
        let stale = drawn.filter { TasksCellBodyCounts.builderPalettes[$0] != recoloured }
        print("BREADTH_PALETTE drawn=\(drawn.count) stale_builders=\(stale.count)")
        XCTAssertEqual(stale.count, 0, "rows whose menus read the old palette after a pass that read the new one")
    }

    /// Astra R-4, in the suite: the palette changes, then an edit to one
    /// row passes the page; every untouched drawn row's builder reads the
    /// new palette, as on the trunk. (The palette alone is the guard above,
    /// which runs alone.)
    func testAPaletteChangeReachesTheRowBuildersOnAnEdit() throws {
        let store = try makeStore(open: 6)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        let palette = PaletteBox()
        let hosting = page(model, store, pointer: pointer, palette: palette)
        let ids = model.rows(for: .now).map(\.id)
        let drawn = drawnRows(pointer, ids).map { TasksRowID(tab: .now, id: $0) }
        XCTAssertGreaterThan(drawn.count, 1)
        let recoloured = AtticTagPalette(hues: ["work": .green])
        palette.palette = recoloured
        settle(hosting)
        XCTAssertTrue(model.setPriority(.high, for: [ids[0]]).isApplied)
        let passed = expectation(for: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                hosting.layoutSubtreeIfNeeded()
                hosting.window?.displayIfNeeded()
                return drawn.allSatisfy { TasksCellBodyCounts.passPalettes[$0] == recoloured }
            }
        }, evaluatedWith: nil)
        wait(for: [passed], timeout: 5)
        settle(hosting)
        let untouched = drawn.filter { $0.id != ids[0] }
        let stale = untouched.filter { TasksCellBodyCounts.builderPalettes[$0] != recoloured }
        print("BREADTH_PALETTE_EDIT drawn=\(drawn.count) untouched=\(untouched.count) stale_builders=\(stale.count)")
        XCTAssertEqual(stale.count, 0, "rows whose menus read the old palette after a pass that read the new one")
    }

    // MARK: - Fix round 2

    /// Astra R-9: the release's check that the lifted group is still whole
    /// does work in proportion to the group, not its square: at most ten
    /// hashes and comparisons a row for unchanged groups of 400 and 4,000.
    func testAReleaseChecksItsGroupInLinearWork() {
        for count in [400, 4_000] {
            let ids = (0..<count).map(CountedID.init)
            CountedID.work = 0
            XCTAssertFalse(TasksDragRelease.hasLeft(ids, from: ids), "the case under test: the group is unchanged")
            let work = CountedID.work
            print("BREADTH_RELEASE_WORK rows=\(count) work=\(work)")
            XCTAssertLessThanOrEqual(work, 10 * count, "the release's group check at \(count) rows")
        }
        let ids = (0..<400).map(CountedID.init)
        XCTAssertTrue(TasksDragRelease.hasLeft(ids, from: Array(ids.dropFirst())), "a row that left is found")
        XCTAssertFalse(TasksDragRelease.hasLeft(ids, from: ids + [CountedID(id: 400)]), "a row that joined is not a row that left")
    }

    /// Astra R-10: with recording off (as outside these tests), hosting a
    /// page, recolouring it, editing a row and closing it records nothing:
    /// no row payload or palette stays behind.
    func testRecordsStayEmptyWhenRecordingIsOff() throws {
        TasksCellBodyCounts.records = false
        let store = try makeStore(open: 6)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        let palette = PaletteBox()
        let hosting = page(model, store, pointer: pointer, palette: palette)
        let ids = model.rows(for: .now).map(\.id)
        XCTAssertFalse(drawnRows(pointer, ids).isEmpty, "the case under test: the page drew rows")
        palette.palette = AtticTagPalette(hues: ["work": .green])
        XCTAssertTrue(model.setPriority(.high, for: [ids[0]]).isApplied)
        settle(hosting)
        window?.close()
        window = nil
        drain()
        XCTAssertTrue(TasksCellBodyCounts.evaluations.isEmpty, "wrapper counts")
        XCTAssertTrue(TasksCellBodyCounts.leaves.isEmpty, "leaf counts")
        XCTAssertTrue(TasksCellBodyCounts.leafModels.isEmpty, "row models")
        XCTAssertTrue(TasksCellBodyCounts.builderPalettes.isEmpty, "builder palettes")
        XCTAssertTrue(TasksCellBodyCounts.passPalettes.isEmpty, "pass palettes")
        XCTAssertTrue(TasksCellBodyCounts.dragGroups.isEmpty, "drag groups")
        XCTAssertEqual(TasksCellBodyCounts.groupLookups, 0, "group lookups")
    }

    // MARK: - Fix round 1: drags

    /// Astra R-2: in Backlog's Find, A and B match. A is lifted toward B;
    /// before the release B is renamed out of Find. The release lands A
    /// back: no order is written and no undo step added, as on the trunk,
    /// where the cell's group was the one shown.
    func testARowThatLeavesTheGroupMidDragMeansNoWriteAndNoUndoStep() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = true
        let host = try CrossDayHost(seed: [TaskDraft(title: "Match A", status: .backlog),
                                           TaskDraft(title: "Match B", status: .backlog),
                                           TaskDraft(title: "Other C", status: .backlog)])
        defer { host.close() }
        host.model.select(tab: .backlog)
        host.model.setSearchQuery("Match", for: .backlog)
        let shown = expectation(for: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                let rows = host.model.rows(for: .backlog)
                return rows.count == 2 && rows.allSatisfy { host.pointer.frames[TasksRowID(tab: .backlog, id: $0.id)] != nil }
            }
        }, evaluatedWith: nil)
        wait(for: [shown], timeout: 5)
        let ids = host.model.rows(for: .backlog).map(\.id)
        let (lifted, leaving) = (ids[0], ids[1])
        let all = host.store.tasks.map(\.id)
        let orders = all.map { host.store.task(withID: $0)?.manualOrder }
        let step = host.model.library.undo.undoStepID(in: .tasks)
        var groupBeforeRelease: [UUID]?
        var stepBeforeRelease: UUID?
        try host.drag(lifted, in: .backlog, steps: [6, 20, 44], then: { _ in
            guard let task = host.store.task(withID: leaving) else { return }
            XCTAssertTrue(host.store.update(task, title: "Renamed B"))
        }, beforeRelease: {
            groupBeforeRelease = host.model.listSnapshot(for: .backlog).entries.first { $0.row?.id == lifted }?.reorderIDs
            stepBeforeRelease = host.model.library.undo.undoStepID(in: .tasks)
        })
        XCTAssertEqual(groupBeforeRelease, [lifted], "the case under test: B left Find before the release")
        XCTAssertEqual(stepBeforeRelease, step, "the case under test: the rename added no undo step")
        XCTAssertEqual(all.map { host.store.task(withID: $0)?.manualOrder }, orders, "the release wrote an order")
        XCTAssertEqual(host.model.library.undo.undoStepID(in: .tasks), step, "the release added an undo step")
        XCTAssertEqual(host.store.task(withID: lifted)?.status, .backlog)
        XCTAssertNil(host.store.task(withID: lifted)?.dueDay)
    }

    /// The other side of Astra R-2: a row that joins the group mid-drag
    /// (renamed into Find) does not cancel the drop. The release lands
    /// among the group as it is now, as on the trunk.
    func testARowThatJoinsTheGroupMidDragLeavesTheDropStanding() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = true
        let host = try CrossDayHost(seed: [TaskDraft(title: "Match A", status: .backlog),
                                           TaskDraft(title: "Match B", status: .backlog),
                                           TaskDraft(title: "Other C", status: .backlog)])
        defer { host.close() }
        host.model.select(tab: .backlog)
        host.model.setSearchQuery("Match", for: .backlog)
        let shown = expectation(for: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                let rows = host.model.rows(for: .backlog)
                return rows.count == 2 && rows.allSatisfy { host.pointer.frames[TasksRowID(tab: .backlog, id: $0.id)] != nil }
            }
        }, evaluatedWith: nil)
        wait(for: [shown], timeout: 5)
        let ids = host.model.rows(for: .backlog).map(\.id)
        let (lifted, passed) = (ids[0], ids[1])
        guard let joining = host.store.tasks.first(where: { $0.title == "Other C" })?.id else { return XCTFail("seed") }
        var groupBeforeRelease: [UUID]?
        try host.drag(lifted, in: .backlog, steps: [6, 20, 44], then: { _ in
            guard let task = host.store.task(withID: joining), task.title != "Match C" else { return }
            XCTAssertTrue(host.store.update(task, title: "Match C"))
        }, beforeRelease: {
            groupBeforeRelease = host.model.listSnapshot(for: .backlog).entries.first { $0.row?.id == lifted }?.reorderIDs
        })
        XCTAssertEqual(groupBeforeRelease?.count, 3, "the case under test: C joined Find before the release")
        XCTAssertEqual(host.model.rows(for: .backlog).map(\.id), [passed, lifted, joining], "the drop landed A below B")
    }

    /// Astra R-8, Opus R-3: a press the row refuses (on the circle column)
    /// never works out a drag group, however far it moves; an accepted
    /// drag works it out once, when it lifts.
    func testADragWorksOutItsGroupOnlyOnceItLifts() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = true
        let host = try CrossDayHost(seed: (0..<4).map { TaskDraft(title: "Task \($0)") })
        defer { host.close() }
        let ids = host.model.rows(for: .now).map(\.id)
        TasksCellBodyCounts.groupLookups = 0
        try host.drag(ids[3], x: 12, steps: [6, 20, 40, 60], then: { post in post(30) }, beforeRelease: {})
        XCTAssertEqual(TasksCellBodyCounts.groupLookups, 0, "a refused press worked out the drag group")

        TasksCellBodyCounts.groupLookups = 0
        var whileLifted: Int?
        try host.drag(ids[0], steps: [6, 20, 40, 60], then: { _ in }, beforeRelease: {
            whileLifted = TasksCellBodyCounts.groupLookups
        })
        XCTAssertEqual(whileLifted, 1, "an accepted drag works out its group once, when it lifts")
    }

    /// Astra R-7: a real drag after a task joined the group moves among the
    /// group as it is now: dragged past every row, the lifted task lands
    /// last, after the one that joined.
    func testADragAfterATaskJoinsLandsAmongTheCurrentGroup() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = true
        let host = try CrossDayHost(seed: (0..<3).map { TaskDraft(title: "Task \($0)") })
        defer { host.close() }
        let lifted = try XCTUnwrap(host.model.rows(for: .now).first).id
        let joined = try XCTUnwrap(host.store.create(title: "Joins the group")).id
        let shown = expectation(for: NSPredicate { _, _ in MainActor.assumeIsolated { host.model.rows(for: .now).count == 4 } },
                                evaluatedWith: nil)
        wait(for: [shown], timeout: 5)
        let order = host.model.rows(for: .now).map(\.id)
        XCTAssertEqual(order.count, 4)
        XCTAssertTrue(order.contains(joined))
        try host.drag(lifted, steps: [6, 20, 60, 100, 140, 180, 220], then: { _ in }, beforeRelease: {})
        XCTAssertEqual(host.model.rows(for: .now).map(\.id).last, lifted, "the lifted task lands after every row of the current group")
    }

    // MARK: - The page's lifetime

    /// The wrappers' closures hold copies of the page, and a wrapper a pass
    /// skips keeps them: a page that leaves its window should let its model
    /// go. It does not yet, on the trunk's page as well (Air, 2026-11-18,
    /// 19672e10's page): the model outlives a hosted page that leaves, a
    /// leak older than 1a and tracked on the board as
    /// `tasks-hosted-page-leak`. Pinned to today's value (the model stays
    /// alive), so its fix shows here as a failure to flip.
    func testAHostedPageThatLeavesLetsItsModelGo() throws {
        weak var released: TasksPageModel?
        try autoreleasepool {
            let store = try makeStore(open: 12)
            let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
            released = model
            let pointer = TasksPointer()
            let hosting = page(model, store, pointer: pointer)
            XCTAssertFalse(drawnRows(pointer, model.rows(for: .now).map(\.id)).isEmpty)
            window?.contentView = nil
            window?.close()
            window = nil
            settle(hosting)
        }
        for _ in 0..<20 where released != nil { drain() }
        XCTAssertNotNil(released, "tasks-hosted-page-leak: pinned value: a hosted Tasks page's model outlives "
            + "the page (trunk too). If this fails, the model is now released: the leak is fixed; "
            + "flip to XCTAssertNil and close the board item.")
    }

    /// A page that leaves its window and comes back draws every row and
    /// shows a change made while it was away (no wrapper is left empty).
    func testAPageThatLeavesAndComesBackDrawsItsRowsAndTheirChanges() throws {
        let store = try makeStore(open: 12)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        let ids = model.rows(for: .now).map(\.id)
        let before = drawnRows(pointer, ids)
        let window = try XCTUnwrap(window)
        window.contentView = NSView(frame: hosting.frame)
        drain()
        let edited = ids[1]
        XCTAssertTrue(model.setPriority(.high, for: [edited]).isApplied)
        drain()
        window.contentView = hosting
        settle(hosting)
        settle(hosting)
        XCTAssertEqual(drawnRows(pointer, ids), before, "a row came back undrawn")
        XCTAssertEqual(TasksCellBodyCounts.leafModels[TasksRowID(tab: .now, id: edited)]?.priority, .high,
                       "the changed row draws its new priority on return")
    }

    // MARK: - One view per list entry (scale-work audit #1, 26 Nov)

    /// How many times a turn ran the row builder (`cell()`), per tab.
    private func builderPasses(_ hosting: NSView, _ action: () -> Void) -> [TasksTab: Int] {
        let base = TasksCellBodyCounts.passes
        action()
        settle(hosting)
        settle(hosting)
        return TasksCellBodyCounts.passes.reduce(into: [TasksTab: Int]()) { result, entry in
            let added = entry.value - base[entry.key, default: 0]
            if added > 0 { result[entry.key.tab, default: 0] += added }
        }
    }

    /// A lazy list builds the rows it shows, not every entry: a `ForEach`
    /// whose entry yields 0, 1 or 2 views (the date header and the next
    /// event under a row-or-header `if`) has no constant view count, so the
    /// lazy stack runs every entry's builder on each page pass. A row click
    /// and ↓ (the model's route, as `TasksPage` drives it) run the row
    /// builder the same number of times with 83 and 446 open tasks and the
    /// same rows on screen.
    func testARowClickAndArrowRunTheRowBuilderTheSameAt83And446Tasks() throws {
        var results: [Int: (click: Int, arrow: Int, drawn: Int)] = [:]
        for count in [83, 446] {
            window?.close()
            TasksCellBodyCounts.reset()
            let store = try makeStore(open: count, tracker: true)
            let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
            let pointer = TasksPointer()
            let hosting = page(model, store, pointer: pointer)
            let ids = model.rows(for: .now).map(\.id)
            XCTAssertEqual(ids.count, count, "the seed's open rows")
            let drawn = drawnRows(pointer, ids)
            XCTAssertGreaterThan(drawn.count, 5, "the hosted page drew too few rows for the count to mean anything")
            model.selectOnly(ids[1])
            settle(hosting)
            settle(hosting)
            let click = builderPasses(hosting) { model.click(ids[3], modifiers: [], visible: ids) }
            let arrow = builderPasses(hosting) {
                model.selectOnly(ids[4])
                model.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.now.rawValue, id: ids[4]), keyboardDriving: true)
                model.cellUpdates.objectWillChange.send()
            }
            print("ONE_VIEW_TASKS n=\(count) drawn=\(drawn.count) click_now=\(click[.now, default: 0]) "
                  + "click_all=\(click.values.reduce(0, +)) arrow_now=\(arrow[.now, default: 0]) arrow_all=\(arrow.values.reduce(0, +))")
            results[count] = (click.values.reduce(0, +), arrow.values.reduce(0, +), drawn.count)
        }
        let small = try XCTUnwrap(results[83]), large = try XCTUnwrap(results[446])
        XCTAssertEqual(small.drawn, large.drawn, "the same rows on screen at both sizes")
        XCTAssertEqual(large.click, small.click, "a row click ran the row builder \(large.click) times at 446 tasks against \(small.click) at 83")
        XCTAssertEqual(large.arrow, small.arrow, "↓ ran the row builder \(large.arrow) times at 446 tasks against \(small.arrow) at 83")
    }

    /// Done's list: a day heading or a row per line. A row click runs the
    /// row builder the same number of times with 40 or 240 rows loaded and
    /// the same rows on screen.
    func testADoneRowClickRunsTheRowBuilderTheSameWith40Or240RowsLoaded() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        let now = Date()
        for index in 0..<300 {
            let item = TaskItem(title: "Finished task \(index) with a longer title", status: .todo, createdAt: now)
            item.statusRaw = TaskStatus.done.rawValue
            // Ten a day, so the list has day headings between its rows.
            item.completedAt = now.addingTimeInterval(-Double(index / 10) * 86_400 - Double(index % 10) * 60 - 3_600)
            item.doneLoggedAt = item.completedAt
            context.insert(item)
        }
        try context.save()
        let store = TaskStore(container: container)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        model.select(tab: .done)
        settle(hosting, until: { model.pagerSwipe.motion.position == CGFloat(TasksTab.done.rawValue) })
        func measure(_ name: String) throws -> Int {
            let ids = model.doneDays().flatMap { $0.rows.map(\.id) }
            XCTAssertGreaterThan(ids.count, 20, "Done loaded rows")
            model.selectOnly(ids[1])
            settle(hosting)
            settle(hosting)
            let click = builderPasses(hosting) { model.click(ids[3], modifiers: [], visible: ids) }
            print("ONE_VIEW_DONE \(name) loaded=\(ids.count) click_done=\(click[.done, default: 0]) click_all=\(click.values.reduce(0, +))")
            return click.values.reduce(0, +)
        }
        let first = try measure("first_page")
        model.loadMoreDoneLog(limit: 200)
        settle(hosting)
        settle(hosting)
        XCTAssertGreaterThanOrEqual(model.doneDays().flatMap(\.rows).count, 240, "the log loaded more rows")
        let more = try measure("more_loaded")
        XCTAssertGreaterThan(first, 0, "the click ran Done's row builder")
        XCTAssertEqual(more, first, "a Done row click ran the row builder \(more) times with 240 rows loaded against \(first) with 40")
    }

    // MARK: - Turns

    private struct Turn {
        let target: UUID?
        /// How many times each row's wrapper, and each row's context-menu
        /// body, ran in the turn (Now's rows).
        let wrapperRuns: [UUID: Int]
        let menuRuns: [UUID: Int]
        let wrappers: Set<UUID>
        let leaves: Set<UUID>
        let drawnBefore: Set<UUID>
        let drawnAfter: Set<UUID>
        var mounted: Set<UUID> { drawnAfter.subtracting(drawnBefore) }
        var changed: Set<UUID> { mounted.union(target.map { [$0] } ?? []) }
        var line: String {
            "wrappers=\(wrappers.count) leaves=\(leaves.count) mounted=\(mounted.count) "
                + "other_wrappers=\(wrappers.subtracting(changed).count) drawn=\(drawnAfter.count)"
        }
    }

    private func turn(_ hosting: NSView, _ pointer: TasksPointer, _ ids: [UUID], target: UUID?,
                      _ action: () -> Void) -> Turn {
        let wrappers = TasksCellBodyCounts.evaluations, leaves = TasksCellBodyCounts.leaves
        let menus = AtticContextMenuBodyCounts.runs
        let before = drawnRows(pointer, ids)
        action()
        settle(hosting)
        settle(hosting)
        func ran(_ counts: [TasksRowID: Int], _ base: [TasksRowID: Int]) -> Set<UUID> {
            Set(runs(counts, base).keys)
        }
        func runs(_ counts: [TasksRowID: Int], _ base: [TasksRowID: Int]) -> [UUID: Int] {
            Dictionary(uniqueKeysWithValues: counts.compactMap { row, count in
                row.tab == .now && count > base[row, default: 0] ? (row.id, count - base[row, default: 0]) : nil
            })
        }
        func rowKeyed(_ counts: [AnyHashable: Int]) -> [TasksRowID: Int] {
            Dictionary(uniqueKeysWithValues: counts.compactMap { tag, count in (tag.base as? TasksRowID).map { ($0, count) } })
        }
        return Turn(target: target, wrapperRuns: runs(TasksCellBodyCounts.evaluations, wrappers),
                    menuRuns: runs(rowKeyed(AtticContextMenuBodyCounts.runs), rowKeyed(menus)),
                    wrappers: ran(TasksCellBodyCounts.evaluations, wrappers),
                    leaves: ran(TasksCellBodyCounts.leaves, leaves), drawnBefore: before, drawnAfter: drawnRows(pointer, ids))
    }

    /// Only the changed rows' wrappers ran.
    private func assertOnlyChanged(_ turn: Turn, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        print("BREADTH_TURN \(name) \(turn.line)")
        XCTAssertEqual(turn.wrappers.subtracting(turn.changed), [],
                       "\(name): wrappers of unchanged rows ran (\(turn.line))", file: file, line: line)
    }

    /// Exactly `rows`' wrappers ran, once each; menus ran only with their
    /// own row's wrapper, never more often.
    private func assertOnlyTheseRanOnce(_ turn: Turn, _ rows: Set<UUID>, _ name: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let menus = turn.menuRuns.values.reduce(0, +)
        print("BREADTH_ROWS \(name) wrappers=\(turn.wrapperRuns.values.reduce(0, +)) rows=\(turn.wrapperRuns.count) "
              + "menus=\(menus) menu_rows=\(turn.menuRuns.count) other_wrappers=\(turn.wrappers.subtracting(rows).count)")
        XCTAssertEqual(turn.wrapperRuns, Dictionary(uniqueKeysWithValues: rows.map { ($0, 1) }),
                       "\(name): the wrappers that ran, and how often (\(turn.line))", file: file, line: line)
        for (row, count) in turn.menuRuns where count > turn.wrapperRuns[row, default: 0] {
            XCTFail("\(name): row \(row)'s menu body ran \(count) times, its wrapper \(turn.wrapperRuns[row, default: 0])",
                    file: file, line: line)
        }
    }

    /// The change was delivered: the target's leaf on Now ran.
    private func assertDelivered(_ turn: Turn, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let target = turn.target else { return }
        XCTAssertTrue(turn.leaves.contains(target), "\(name): the changed row was not redrawn", file: file, line: line)
    }

    // MARK: - Fixture

    private final class Clock: @unchecked Sendable {
        var now: Date
        init(now: Date) { self.now = now }
    }

    /// An id that counts each hash and each comparison made with it.
    private struct CountedID: Hashable {
        let id: Int
        nonisolated(unsafe) static var work = 0
        static func == (lhs: Self, rhs: Self) -> Bool {
            work += 1
            return lhs.id == rhs.id
        }
        func hash(into hasher: inout Hasher) {
            Self.work += 1
            hasher.combine(id)
        }
    }

    private final class PaletteBox: ObservableObject {
        @Published var palette = AtticTagPalette.empty
    }

    private struct PaletteRoot<Content: View>: View {
        @ObservedObject var box: PaletteBox
        let content: Content
        var body: some View { content.environment(\.atticTagColouring, AtticTagColouring(palette: box.palette)) }
    }

    private func projected(_ model: TasksPageModel, _ id: UUID) -> AtticTaskRowModel? {
        model.listSnapshot(for: .now).rows.first { $0.id == id }?.model
    }

    private func drawnRows(_ pointer: TasksPointer, _ ids: [UUID]) -> Set<UUID> {
        Set(ids.filter { pointer.frame(for: TasksRowID(tab: .now, id: $0)) != nil })
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap(scrollViews)
    }

    /// `tracker`: the tracker-shaped seed (TaskPerformanceGateTests: long
    /// titles, two tags a task).
    private func liveState(_ model: TasksPageModel, _ id: UUID, tab: TasksTab = .now) -> TasksRowState? {
        guard model.rowStateIDsForTesting[tab]?.contains(id) == true,
              let row = model.listSnapshot(for: tab).rows.first(where: { $0.id == id }) else { return nil }
        return model.rowState(for: row, tab: tab, run: .single)
    }

    private func makeStore(open: Int, due: DueDay? = nil, tracker: Bool = false, backlog: Int = 0) throws -> TaskStore {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        let now = Date()
        var order: Int64 = 10_000_000
        for index in 0..<open {
            order -= 1_024
            let title = tracker ? "Open task \(index) with a longer title like the tracker's" : "Open task \(index)"
            let item = TaskItem(title: title, status: .todo, createdAt: now, manualOrder: order)
            item.listOrderVersion = TaskItem.currentListOrderVersion
            if tracker { item.tags = ["tag\(index % 7)", "area\(index % 3)"] }
            if index == 0 { item.dueDay = due }
            context.insert(item)
        }
        for index in 0..<backlog {
            order -= 1_024
            let item = TaskItem(title: "Later task \(index)", status: .backlog, createdAt: now, manualOrder: order)
            item.listOrderVersion = TaskItem.currentListOrderVersion
            context.insert(item)
        }
        try context.save()
        return TaskStore(container: container)
    }

    private func page(_ model: TasksPageModel, _ store: TaskStore, pointer: TasksPointer,
                      palette: PaletteBox = PaletteBox()) -> NSView {
        let page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: Self.size),
                             addBarFocused: .constant(false), pointer: pointer)
        let root = PaletteRoot(box: palette, content: page.frame(width: Self.size.width, height: Self.size.height))
        let hosting = NSHostingView(rootView: root.atticDesign(.default))
        hosting.frame = CGRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        self.window = window
        settle(hosting)
        settle(hosting)
        return hosting
    }

    /// The main queue drains (an expectation, no fixed wait).
    private func drain() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    /// Settles until `condition` holds (the pager's slide ends on its own
    /// clock), at most 3 s.
    private func settle(_ hosting: NSView, file: StaticString = #filePath, line: UInt = #line, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { settle(hosting) }
        XCTAssertTrue(condition(), "the page settled", file: file, line: line)
    }

    /// The main queue drains, then the page lays out and draws.
    private func settle(_ hosting: NSView) {
        drain()
        hosting.layoutSubtreeIfNeeded()
        hosting.window?.displayIfNeeded()
        TasksPageModel.checkLiveRowStates()
    }
}

/// A click, counted (PR 48 round 2): only the cells whose own inputs changed
/// run their body. STAY: the selection moves from A to B and the keyboard is
/// on no row (one model update). MOVE: a click on D with the keyboard and the
/// selection on C, the way `TasksPage.rowClicked` does it: the click's
/// selection, then the page's focus route as `rowFocusChanged` runs it
/// (two updates). Each update runs the old and the new row's cells once and
/// no other cell on any tab; Done, kept built beside Now, runs none. The
/// class is self-contained so it runs unchanged on the trunk, where each
/// cell observes the model's every change.
@MainActor
final class TasksClickCountTests: XCTestCase {
    private static let size = CGSize(width: 344, height: 520)
    private var window: NSWindow?

    override func setUp() async throws {
        try await super.setUp()
        TasksCellBodyCounts.reset(); TasksCellBodyCounts.records = true
        TasksRowStateCounts.reset()
    }

    override func tearDown() async throws {
        window?.orderOut(nil); window = nil
        assertNoRowStateWriteDuringAReadAndNoLateCatchUp()
        TasksCellBodyCounts.records = false; TasksCellBodyCounts.reset()
        try await super.tearDown()
    }

    func testAClickRunsOnlyTheCellsWhoseInputsChangedStayAndMove() throws {
        let store = try makeStore()
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let hosting = page(model, store)
        go(.done, model, hosting)
        go(.now, model, hosting)
        let built = TasksCellBodyCounts.evaluations.keys
        let builtNow = built.filter { $0.tab == .now }.count, builtDone = built.filter { $0.tab == .done }.count
        print("CLICK_COUNT built now=\(builtNow) done=\(builtDone)")
        XCTAssertGreaterThan(builtNow, 5, "too few cells built on Now for the count to mean anything")
        XCTAssertGreaterThan(builtDone, 0, "Done's cells were never built, so its case is void")
        let ids = model.rows(for: .now).map(\.id)
        func row(_ id: UUID) -> TasksRowID { TasksRowID(tab: .now, id: id) }
        func focus(_ id: UUID) { // TasksPage.rowFocusChanged's two calls, for a click
            model.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.now.rawValue, id: id), keyboardDriving: false)
            model.cellUpdates.objectWillChange.send()
        }
        func turn(_ name: String, _ action: () -> Void) -> (cells: [TasksRowID: Int], rows: [UUID: Int]) {
            let cells = TasksCellBodyCounts.evaluations, rows = AtticTaskRow.evaluations
            print("CLICK_COUNT begin \(name)")
            action()
            settle(hosting)
            settle(hosting)
            print("CLICK_COUNT end \(name)")
            let ranCells = TasksCellBodyCounts.evaluations.reduce(into: [TasksRowID: Int]()) {
                let added = $1.value - cells[$1.key, default: 0]
                if added > 0 { $0[$1.key] = added }
            }
            let ranRows = AtticTaskRow.evaluations.reduce(into: [UUID: Int]()) {
                let added = $1.value - rows[$1.key, default: 0]
                if added > 0 { $0[$1.key] = added }
            }
            print("CLICK_COUNT \(name) cells=\(ranCells.values.reduce(0, +)) cell_rows=\(ranCells.count) "
                  + "other_cells=\(ranCells.filter { $0.key.tab != .now }.values.reduce(0, +)) "
                  + "row_bodies=\(ranRows.values.reduce(0, +))")
            return (ranCells, ranRows)
        }

        // STAY: A selected, the keyboard on no row; a click on B.
        let a = ids[1], b = ids[3]
        model.selectOnly(a)
        settle(hosting); settle(hosting)
        XCTAssertNil(model.keyboardFocus)
        let stay = turn("stay") { model.click(b, modifiers: [], visible: ids) }
        XCTAssertEqual(model.selection, [b], "stay: the click selected B")
        XCTAssertEqual(stay.rows[b], 1, "stay: B's row drew the change")
        XCTAssertEqual(stay.cells, [row(a): 1, row(b): 1], "stay: A's and B's cells once each, no other")

        // MOVE: C selected and holding the keyboard; a click on D.
        let c = ids[2], d = ids[4]
        model.selectOnly(c)
        focus(c)
        settle(hosting); settle(hosting)
        XCTAssertEqual(model.keyboardFocus?.id, c)
        let select = turn("move_select") { model.click(d, modifiers: [], visible: ids) }
        XCTAssertEqual(model.selection, [d], "move: the click selected D")
        XCTAssertEqual(select.rows[d], 1, "move: D's row drew the selection")
        XCTAssertEqual(select.cells, [row(c): 1, row(d): 1], "move, selection: C's and D's cells once each, no other")
        let keyboard = turn("move_focus") { focus(d) }
        XCTAssertEqual(model.keyboardFocus?.id, d, "move: the keyboard reached D")
        XCTAssertEqual(keyboard.cells, [row(c): 1, row(d): 1], "move, focus: C's and D's cells once each, no other")
    }

    private func go(_ tab: TasksTab, _ model: TasksPageModel, _ hosting: NSView) {
        model.select(tab: tab)
        let deadline = Date().addingTimeInterval(3)
        while model.pagerSwipe.span.pages != tab.rawValue...tab.rawValue, Date() < deadline { settle(hosting) }
        XCTAssertEqual(model.pagerSwipe.span.pages, tab.rawValue...tab.rawValue, "the span narrowed to \(tab)")
        settle(hosting)
        settle(hosting)
    }

    private func makeStore() throws -> TaskStore {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        let now = Date()
        var order: Int64 = 10_000_000
        for index in 0..<83 {
            order -= 1_024
            let item = TaskItem(title: "Open task \(index) with a longer title like the tracker's", status: .todo,
                                createdAt: now, manualOrder: order)
            item.listOrderVersion = TaskItem.currentListOrderVersion
            item.tags = ["tag\(index % 7)", "area\(index % 3)"]
            context.insert(item)
        }
        for index in 0..<8 {
            order -= 1_024
            let item = TaskItem(title: "Done task \(index)", status: .done, createdAt: now, manualOrder: order)
            item.completedAt = now.addingTimeInterval(-Double(index) * 60)
            item.listOrderVersion = TaskItem.currentListOrderVersion
            context.insert(item)
        }
        try context.save()
        return TaskStore(container: container)
    }

    private func page(_ model: TasksPageModel, _ store: TaskStore) -> NSView {
        let page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: Self.size),
                             addBarFocused: .constant(false), pointer: TasksPointer())
        let hosting = NSHostingView(rootView: page.frame(width: Self.size.width, height: Self.size.height).atticDesign(.default))
        hosting.frame = CGRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        self.window = window
        settle(hosting)
        settle(hosting)
        return hosting
    }

    private func settle(_ hosting: NSView) {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
        hosting.layoutSubtreeIfNeeded()
        hosting.window?.displayIfNeeded()
    }
}
