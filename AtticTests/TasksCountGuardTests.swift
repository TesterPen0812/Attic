import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Red-first count guards for the Tasks action audits of 18 Nov 2026
/// (`reports/perf-audit/tasks-actions.opus.md` F1, F3, F4, F7 and
/// `tasks-actions.astra.md` TA-02 to TA-05, TA-07), in the lead's fix order:
/// item 2 (the tick's breadth), then item 3 (reads that grow with the data).
///
/// Each guard counts work, never time. The item 3 guards run the same action
/// at two sizes of the dimension their finding names and fail when the count
/// grows with it. Each prints a `GUARD_` line with its counts, so a run shows
/// that the path ran (a non-zero count at the small size before the fix).
///
/// The page is the real `TasksPage`, hosted in a borderless window that is
/// never shown. A step is settled by letting the main queue drain (an
/// expectation, not a fixed wait) and then laying out and drawing, as a
/// frame would.
@MainActor
final class TasksCountGuardTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
        try await super.tearDown()
    }

    // MARK: - Item 2: the tick's breadth

    /// Opus F3, Astra TA-02 (item 2, third pull request: the publish turns and
    /// the rows-cache key). One tick on Now, through press, save and release,
    /// rebuilds Now's rows at most once: F3's own bound ("task_rows_cache_miss
    /// ≤ 1"). The page passes, model sends and the cells' broadcasts (F1,
    /// TA-07) are printed beside it, not asserted: those fixes need their own
    /// count or trace line.
    func testGuardTickRebuildsNowRowsAtMostOnce() throws {
        var bySize: [Int: Int] = [:]
        for size in [40, 400] {
            let store = try makeStore(open: size)
            var services = TasksPageServices()
            // The test takes each turn itself: the save, then the release.
            services.acknowledgementDelay = .seconds(25)
            services.doneHold = .seconds(25)
            let model = TasksPageModel(library: AtticLibrary(tasks: store), services: services)
            let hosting = page(model, store)
            let id = try XCTUnwrap(model.rows(for: .now).first?.id)
            var modelSends = 0, cellBroadcasts = 0
            let sends = model.objectWillChange.sink { modelSends += 1 }
            let broadcasts = model.cellUpdates.objectWillChange.sink { cellBroadcasts += 1 }
            defer { sends.cancel(); broadcasts.cancel() }
            let misses = model.rowsCacheMissCount, passes = TasksPage.tabsEvaluations
            let restates = model.rowsRestateCount[.now, default: 0]

            model.completeAcknowledged(id) { _ in }  // press: the row is held, ticked
            settle(hosting)
            XCTAssertNotNil(model.held[id], "the press holds the row")
            model.settlePendingCompletionAcknowledgements(through: id)  // the save
            settle(hosting)
            XCTAssertEqual(store.task(withID: id)?.status, .done)
            model.releaseHold(id)  // the release: the row leaves Now
            settle(hosting)
            settle(hosting)
            XCTAssertNil(model.held[id])

            let nowMisses = model.rowsCacheMissCount[.now, default: 0] - misses[.now, default: 0]
            let otherMisses = TasksTab.allCases.filter { $0 != .now }
                .map { model.rowsCacheMissCount[$0, default: 0] - misses[$0, default: 0] }.reduce(0, +)
            let pagePasses = TasksPage.tabsEvaluations - passes
            print("GUARD_TICK size=\(size) now_rows_cache_misses=\(nowMisses) other_tab_misses=\(otherMisses) "
                  + "now_rows_restated=\(model.rowsRestateCount[.now, default: 0] - restates) "
                  + "page_passes=\(pagePasses) model_sends=\(modelSends) cell_broadcasts=\(cellBroadcasts)")
            XCTAssertGreaterThan(pagePasses, 0, "the hosted page did not update, so its count proves nothing")
            XCTAssertLessThanOrEqual(nowMisses, 1, "F3/TA-02: one tick rebuilt Now's rows \(nowMisses) times (size \(size))")
            bySize[size] = nowMisses
        }
        XCTAssertEqual(bySize[40], bySize[400], "F3/TA-02: a tick's row rebuilds grew with the store")
    }

    /// The tick guard on dated rows (PR 30 review): Now with every kind of
    /// date group, a manual order that mixes them and an Overdue group over
    /// two days with clocks. A tick on the common path rebuilds Now's rows
    /// once (the release), the Overdue one included. The named fallback, a
    /// held row off its index after a rebuild during its hold (the second
    /// of two holds in one date group, once the first is released before it
    /// is saved), rebuilds at most twice: the save and the release.
    func testGuardDatedTicksRebuildNowRowsOncePerTick() throws {
        let (model, store) = try makeDatedModel([("H", -2, 600), ("X", 1, nil), ("Y", 0, 540), ("Q", -1, nil), ("Z", 1, nil),
                                                 ("W", 0, nil), ("A", -2, 540), ("V", 0, 480), ("U", nil, nil)])
        let hosting = page(model, store)
        XCTAssertEqual(model.rows(for: .now).map(\.model.title), ["A", "Q", "H", "V", "Y", "W", "X", "Z", "U"])
        func task(_ title: String) throws -> UUID { try XCTUnwrap(model.rows(for: .now).first { $0.model.title == title }?.id) }
        func misses() -> Int { model.rowsCacheMissCount[.now, default: 0] }
        func press(_ id: UUID) { model.completeAcknowledged(id) { _ in }; settle(hosting) }
        // The save reads Now's rows itself, so a rebuild at the save is
        // counted there even if the page did not read them (a restate is not
        // a miss).
        func save(_ id: UUID) {
            model.settlePendingCompletionAcknowledgements(through: id)
            settle(hosting)
            _ = model.rows(for: .now)
        }
        func release(_ id: UUID) { model.releaseHold(id); settle(hosting); settle(hosting) }

        // H: Overdue over two days, a clock on its day. X: Tomorrow, behind
        // Today's rows in the manual order. Y: Today, with a clock.
        for title in ["H", "X", "Y"] {
            let id = try task(title), start = misses()
            press(id)
            save(id)
            XCTAssertEqual(store.task(withID: id)?.status, .done)
            release(id)
            XCTAssertNil(model.held[id])
            print("GUARD_DATED_TICK row=\(title) now_rows_cache_misses=\(misses() - start)")
            XCTAssertEqual(misses() - start, 1, "\(title): one tick rebuilt Now's rows \(misses() - start) times")
        }

        // V and W, the whole of Today, held together; V is released before W
        // is saved, so W is put back at the end of its shorter group.
        XCTAssertEqual(model.rows(for: .now).map(\.model.title), ["Q", "A", "V", "W", "Z", "U"])
        let v = try task("V"), w = try task("W")
        var start = misses()
        press(v)
        press(w)
        save(v)
        release(v)
        print("GUARD_DATED_TICK row=V now_rows_cache_misses=\(misses() - start)")
        XCTAssertEqual(misses() - start, 1, "V: one tick rebuilt Now's rows \(misses() - start) times")
        let place = try XCTUnwrap(model.held[w]?.index)
        XCTAssertNotEqual(model.rows(for: .now).firstIndex { $0.id == w }, place,
                          "W is not at its index, so its save takes the fallback this guard bounds")
        start = misses()
        save(w)
        XCTAssertEqual(store.task(withID: w)?.status, .done)
        release(w)
        XCTAssertNil(model.held[w])
        print("GUARD_DATED_TICK row=W off_index now_rows_cache_misses=\(misses() - start)")
        XCTAssertLessThanOrEqual(misses() - start, 2, "W (off its index): its save and release rebuilt Now's rows \(misses() - start) times")
    }

    /// The tick's restated rows are the rows a full build gives (the oracle
    /// builds every restated list in full as well), on a Now with every kind
    /// of date group and clock, a folded group, a family, two holds at once,
    /// on Later, after a failed save and after Undo during a hold.
    func testTickRestatesHeldRowsAsAFullBuildWould() throws {
        TasksPageModel.checksRowsRestate = true
        defer { TasksPageModel.checksRowsRestate = false }
        struct Rejected: Error {}
        var fail = false
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        let calendar = Calendar.autoupdatingCurrent, now = Date()
        func day(_ offset: Int) -> DueDay { DueDay(date: calendar.date(byAdding: .day, value: offset, to: now)!, calendar: calendar) }
        var order: Int64 = 10_000_000
        var family: UUID?
        for index in 0..<30 {
            order -= 1_024
            let item = TaskItem(title: "Task \(index)", status: index % 10 == 9 ? .backlog : (index % 7 == 3 ? .inProgress : .todo),
                                createdAt: now, manualOrder: order)
            item.listOrderVersion = TaskItem.currentListOrderVersion
            switch index % 5 {
            case 0: item.dueDay = day(-2)
            case 1: item.dueDay = day(0); item.dueTimeMinutes = index % 2 == 0 ? 9 * 60 : nil
            case 2: item.dueDay = day(1)
            case 3: item.dueDay = day(4); item.dueTimeMinutes = 18 * 60 + index
            default: break
            }
            context.insert(item)
            if index == 6 {
                family = item.id
                for child in 0..<2 { context.insert(TaskItem(title: "Subtask \(child)", manualOrder: Int64(child), parentID: item.id)) }
            }
        }
        try context.save()
        let store = TaskStore(container: container, persist: { context in
            if fail { throw Rejected() }
            try context.save()
        })
        var services = TasksPageServices()
        services.acknowledgementDelay = .seconds(25)
        services.doneHold = .seconds(25)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: services)

        func press(_ id: UUID) -> [UUID] {
            let before = model.rows(for: model.tab).map(\.id)
            model.completeAcknowledged(id) { _ in }
            XCTAssertNotNil(model.held[id])
            XCTAssertEqual(model.rows(for: model.tab).map(\.id), before, "a press keeps every row in place")
            XCTAssertEqual(model.rowsRestateMismatches, 0, "a press's restated list differs from its full build")
            XCTAssertEqual(model.rows(for: model.tab).first { $0.id == id }?.model.state, .done)
            return before
        }
        func save(_ id: UUID, keeping before: [UUID]) {
            model.settlePendingCompletionAcknowledgements(through: id)
            XCTAssertEqual(model.rows(for: model.tab).map(\.id), before, "a save keeps the held row in place")
            XCTAssertEqual(model.rowsRestateMismatches, 0, "a save's restated list differs from its full build")
        }
        func release(_ id: UUID) {
            model.releaseHold(id)
            XCTAssertFalse(model.rows(for: model.tab).contains { $0.id == id }, "the released row leaves")
        }
        let rows = model.rows(for: .now)
        XCTAssertGreaterThan(model.sections(for: .now).groups.count, 3)
        // The first, a middle, the last row, the family's parent and a dated row with a clock.
        var picks = [rows.first!.id, rows[rows.count / 2].id, rows.last!.id, try XCTUnwrap(family)]
        if let clocked = store.tasks.first(where: { $0.dueTimeMinutes != nil && $0.status != .backlog && $0.parentID == nil }) {
            picks.append(clocked.id)
        }
        var seen = Set<UUID>()
        picks = picks.filter { seen.insert($0).inserted }
        for id in picks {
            let before = press(id)
            save(id, keeping: before)
            XCTAssertEqual(store.task(withID: id)?.status, .done)
            release(id)
        }
        // Two holds at once.
        let pair = Array(model.rows(for: .now).prefix(3).map(\.id).suffix(2))
        let first = press(pair[0])
        _ = press(pair[1])
        save(pair[0], keeping: first)
        save(pair[1], keeping: first)
        release(pair[0])
        release(pair[1])
        // A folded group: the press and save restate around it.
        let group = try XCTUnwrap(model.sections(for: .now).groups.first?.key)
        model.toggleGroup(group, on: .now)
        if let id = model.rows(for: .now).first?.id {
            let before = press(id)
            save(id, keeping: before)
            release(id)
        }
        model.toggleGroup(group, on: .now)
        // A failed save: the row comes back unticked, in place.
        let failing = try XCTUnwrap(model.rows(for: .now).first?.id)
        let unticked = model.rows(for: .now).map(\.id)
        fail = true
        _ = press(failing)
        model.settlePendingCompletionAcknowledgements(through: failing)
        fail = false
        XCTAssertNil(model.held[failing])
        XCTAssertEqual(model.rows(for: .now).map(\.id), unticked)
        XCTAssertNotEqual(model.rows(for: .now).first { $0.id == failing }?.model.state, .done)
        // Undo during the hold: the row is open again.
        let undone = try XCTUnwrap(model.rows(for: .now).first?.id)
        let held = press(undone)
        save(undone, keeping: held)
        XCTAssertTrue(model.undo().isApplied)
        XCTAssertNil(model.held[undone])
        XCTAssertNotEqual(store.task(withID: undone)?.status, .done)
        XCTAssertTrue(model.rows(for: .now).contains { $0.id == undone })
        // Later.
        model.select(tab: .backlog)
        let later = try XCTUnwrap(model.rows(for: .backlog).first?.id)
        let laterBefore = press(later)
        save(later, keeping: laterBefore)
        release(later)

        print("TICK_RESTATE now_restated=\(model.rowsRestateCount[.now, default: 0]) later_restated=\(model.rowsRestateCount[.backlog, default: 0]) "
              + "mismatches=\(model.rowsRestateMismatches) now_misses=\(model.rowsCacheMissCount[.now, default: 0])")
        XCTAssertEqual(model.rowsRestateMismatches, 0, "a restated list differs from its full build")
        XCTAssertGreaterThan(model.rowsRestateCount[.now, default: 0], 0)
        XCTAssertGreaterThan(model.rowsRestateCount[.backlog, default: 0], 0)
    }

    /// R-1 (review of PR 30): a held row stays where it was drawn through
    /// any full build of the list, also when the manual order mixes date
    /// groups. The full build put a held row back at its drawn index in the
    /// ungrouped list (ordered by state, then manual order), which moved it
    /// within its own group. The restate oracle is off: this is what the
    /// panel shows when anything rebuilds the list during a hold.
    func testHeldRowStaysPutThroughAFullBuildWhenManualOrderMixesDateGroups() throws {
        // Manual order X Y Z W V U, drawn Today (Y W V) · Tomorrow (X Z) · No date (U).
        let (model, store) = try makeDatedModel([("X", 1, nil), ("Y", 0, nil), ("Z", 1, nil), ("W", 0, nil), ("V", 0, nil), ("U", nil, nil)])
        XCTAssertEqual(model.rows(for: .now).map(\.model.title), ["Y", "W", "V", "X", "Z", "U"])
        /// The list after two full builds (the fold of "Completed today"
        /// changes the key, and Now draws no done rows).
        func rebuilt() -> [UUID] {
            let misses = model.rowsCacheMissCount[.now, default: 0]
            model.toggleCompletedToday()
            _ = model.rows(for: .now)
            model.toggleCompletedToday()
            let ids = model.rows(for: .now).map(\.id)
            XCTAssertEqual(model.rowsCacheMissCount[.now, default: 0], misses + 2, "the list was built in full")
            return ids
        }
        // X: the middle row, first of Tomorrow but behind Today's rows in
        // the manual order. Then one row of each other group.
        for title in ["X", "W", "U", "Z"] {
            let before = model.rows(for: .now).map(\.id)
            let id = try XCTUnwrap(model.rows(for: .now).first { $0.model.title == title }?.id)
            model.completeAcknowledged(id) { _ in }
            XCTAssertNotNil(model.held[id])
            XCTAssertEqual(model.rows(for: .now).map(\.id), before, "\(title): the press keeps every row in place")
            XCTAssertEqual(rebuilt(), before, "\(title): a full build during the hold keeps every row in place")
            model.settlePendingCompletionAcknowledgements(through: id)
            XCTAssertEqual(store.task(withID: id)?.status, .done)
            XCTAssertEqual(model.rows(for: .now).map(\.id), before, "\(title): the save keeps every row in place")
            XCTAssertEqual(rebuilt(), before, "\(title): a full build after the save keeps every row in place")
            model.releaseHold(id)
            XCTAssertFalse(model.rows(for: .now).contains { $0.id == id }, "\(title): the released row leaves")
        }
    }

    /// R-1, with the restate oracle on: ticks across every kind of date
    /// group in a manual order that mixes them (Overdue over two days with
    /// clocks, Today with clocks, Tomorrow, No date). Each press keeps every
    /// row in place, each save keeps the held row at its place, and no
    /// restated list differs from its full build.
    func testTickRestatesAsAFullBuildWouldWhenManualOrderMixesDateGroups() throws {
        TasksPageModel.checksRowsRestate = true
        defer { TasksPageModel.checksRowsRestate = false }
        let (model, store) = try makeDatedModel([("H", -2, 600), ("X", 1, nil), ("Y", 0, 540), ("Q", -1, nil), ("Z", 1, nil),
                                                 ("W", 0, nil), ("A", -2, 540), ("V", 0, 480), ("U", nil, nil)])
        // Overdue (A Q H: A and H share a day, ordered by clock) · Today (V Y W) · Tomorrow (X Z) · No date (U).
        XCTAssertEqual(model.rows(for: .now).map(\.model.title), ["A", "Q", "H", "V", "Y", "W", "X", "Z", "U"])
        let restates = model.rowsRestateCount[.now, default: 0]
        // H: Overdue over two days with clocks. Y: the middle row. X: the
        // first of Tomorrow, behind Today's rows in the manual order. U: the last.
        for title in ["H", "Y", "X", "U"] {
            let before = model.rows(for: .now).map(\.id)
            let id = try XCTUnwrap(model.rows(for: .now).first { $0.model.title == title }?.id)
            let index = try XCTUnwrap(before.firstIndex(of: id))
            model.completeAcknowledged(id) { _ in }
            XCTAssertNotNil(model.held[id])
            XCTAssertEqual(model.rows(for: .now).map(\.id), before, "\(title): the press keeps every row in place")
            XCTAssertEqual(model.rowsRestateMismatches, 0, "\(title): the press's restated list differs from its full build")
            model.settlePendingCompletionAcknowledgements(through: id)
            XCTAssertEqual(store.task(withID: id)?.status, .done)
            XCTAssertEqual(model.rows(for: .now).firstIndex { $0.id == id }, index, "\(title): the save keeps the held row in place")
            XCTAssertEqual(model.rowsRestateMismatches, 0, "\(title): the save's restated list differs from its full build")
            model.releaseHold(id)
            XCTAssertFalse(model.rows(for: .now).contains { $0.id == id }, "\(title): the released row leaves")
        }
        XCTAssertGreaterThan(model.rowsRestateCount[.now, default: 0], restates)
    }

    /// PR 30, accepted change to the full build: at the press, a full build
    /// of the list keeps the held row where it was drawn when the manual
    /// order mixes date groups. Only full builds are read (each read toggles
    /// "Completed today", which changes the list's key; Now draws no done
    /// rows). It uses no API the PR added, so it can be copied onto the
    /// trunk (this file is new in the PR).
    func testFullBuildKeepsAHeldRowInPlaceAtThePressWhenManualOrderMixesDateGroups() throws {
        // Manual order X Y Z W V U, drawn Today (Y W V) · Tomorrow (X Z) · No date (U).
        let (model, store) = try makeDatedModel([("X", 1, nil), ("Y", 0, nil), ("Z", 1, nil), ("W", 0, nil), ("V", 0, nil), ("U", nil, nil)])
        func fullBuild() -> [UUID] {
            model.toggleCompletedToday()
            let ids = model.rows(for: .now).map(\.id)
            model.toggleCompletedToday()
            return ids
        }
        XCTAssertEqual(model.rows(for: .now).map(\.model.title), ["Y", "W", "V", "X", "Z", "U"])
        for title in ["X", "Z", "W", "U"] {
            let before = fullBuild()
            let id = try XCTUnwrap(model.rows(for: .now).first { $0.model.title == title }?.id)
            model.completeAcknowledged(id) { _ in }
            XCTAssertNotNil(model.held[id])
            XCTAssertEqual(fullBuild(), before, "\(title): the full build keeps the held row in place at the press")
            model.settlePendingCompletionAcknowledgements(through: id)
            XCTAssertEqual(store.task(withID: id)?.status, .done)
            model.releaseHold(id)
            XCTAssertFalse(fullBuild().contains(id), "\(title): the released row leaves")
        }
    }

    /// PR 30 review: in an Overdue group over two days with a clock on the
    /// held row's day, the held row and every row around it keep their
    /// drawn places until the release, through the save and any full build.
    /// (Overdue orders each day's rows by clock within that day's slots in
    /// the store's order, and a save moves a finished task to the end of
    /// that order.) The rows may reorder at the release, as on the trunk.
    func testOverdueRowsKeepTheirPlacesUntilTheReleaseAcrossDaysWithClocks() throws {
        // Manual order H Q A U; Overdue draws A (9:00) in H's slot, then Q, then H (10:00) in A's.
        let (model, store) = try makeDatedModel([("H", -2, 600), ("Q", -1, nil), ("A", -2, 540), ("U", nil, nil)])
        func fullBuild() -> [UUID] {
            model.toggleCompletedToday()
            let ids = model.rows(for: .now).map(\.id)
            model.toggleCompletedToday()
            return ids
        }
        XCTAssertEqual(model.rows(for: .now).map(\.model.title), ["A", "Q", "H", "U"])
        let before = model.rows(for: .now).map(\.id)
        let id = try XCTUnwrap(model.rows(for: .now).first { $0.model.title == "H" }?.id)
        model.completeAcknowledged(id) { _ in }
        XCTAssertEqual(model.rows(for: .now).map(\.id), before, "the press keeps every row in place")
        XCTAssertEqual(fullBuild(), before, "a full build during the hold keeps every row in place")
        model.settlePendingCompletionAcknowledgements(through: id)
        XCTAssertEqual(store.task(withID: id)?.status, .done)
        XCTAssertEqual(model.rows(for: .now).map(\.id), before, "the save keeps every row in place")
        XCTAssertEqual(fullBuild(), before, "a full build after the save keeps every row in place")
        model.releaseHold(id)
        XCTAssertFalse(model.rows(for: .now).contains { $0.id == id }, "the released row leaves")
    }

    /// `rowsBuiltOrder` (PR 30 ruling, condition 1): each full build
    /// replaces it with the rows it built, so a deleted task's id, held or
    /// not, is gone from it after the next build.
    func testBuiltOrderHoldsOnlyTheRowsLastBuilt() throws {
        let (model, _) = try makeDatedModel([("K", nil, nil), ("D", nil, nil), ("E", 0, nil), ("F", nil, nil)])
        func task(_ title: String) throws -> UUID { try XCTUnwrap(model.rows(for: .now).first { $0.model.title == title }?.id) }
        let deleted = try task("D"), held = try task("F")
        XCTAssertTrue(try XCTUnwrap(model.rowsBuiltOrderForTesting[.now]).contains(deleted))
        model.completeAcknowledged(held) { _ in }
        XCTAssertNotNil(model.held[held])
        _ = model.rows(for: .now)
        XCTAssertTrue(model.library.deleteTasks([deleted, held]).isApplied)
        let built = model.rows(for: .now).map(\.id)
        XCTAssertFalse(built.contains(deleted))
        XCTAssertFalse(built.contains(held))
        let order = try XCTUnwrap(model.rowsBuiltOrderForTesting[.now])
        XCTAssertFalse(order.contains(deleted), "a deleted task's id stays in the built order")
        XCTAssertFalse(order.contains(held), "a deleted held task's id stays in the built order")
        XCTAssertEqual(Set(order), Set(built), "the built order holds exactly the rows built")
    }

    /// PR 30 ruling, condition 3 (a): a row held in Find, with Find cleared
    /// during its hold. Its index is a place in the Find list, so the list
    /// without Find shows it as the trunk's full build does, at every step.
    /// The trunk's lists are traced from 2715d5da's `buildRows`: the held
    /// task goes back at its index in the ungrouped list (Q A, so H Q A),
    /// and Overdue then orders day -2's rows by clock in that day's places.
    func testRowHeldInFindShowsAsTheTrunkDoesOnceFindIsCleared() throws {
        let (model, store) = try makeDatedModel([("Q", -1, nil), ("H", -2, 600), ("A", -2, 540)])
        func check(_ trunk: [String], _ step: String) {
            XCTAssertEqual(model.rows(for: .now).map(\.model.title), trunk, "\(step): the rows shown")
            model.toggleCompletedToday()
            XCTAssertEqual(model.rows(for: .now).map(\.model.title), trunk, "\(step): a full build")
            model.toggleCompletedToday()
        }
        check(["Q", "A", "H"], "start")
        model.setSearchQuery("H", for: .now)
        check(["H"], "Find")
        let id = try XCTUnwrap(model.rows(for: .now).first { $0.model.title == "H" }?.id)
        model.completeAcknowledged(id) { _ in }
        XCTAssertNotNil(model.held[id])
        check(["H"], "the press, in Find")
        model.setSearchQuery("", for: .now)
        check(["A", "Q", "H"], "Find cleared during the hold")
        model.settlePendingCompletionAcknowledgements(through: id)
        XCTAssertEqual(store.task(withID: id)?.status, .done)
        check(["A", "Q", "H"], "the save")
        model.releaseHold(id)
        check(["Q", "A"], "the release")
    }

    /// PR 30 ruling, condition 3 (b): the task before the held task in the
    /// order (P) moves during the hold (to in progress, which goes first).
    /// The rows show as the trunk's full build gives them, at every step.
    /// The trunk's lists are traced from 2715d5da's `buildRows`: the held
    /// task goes back at its index (2) in the ungrouped list, and Overdue
    /// orders day -2's rows by clock in that day's places.
    func testHeldRowWhoseNeighbourMovesShowsAsTheTrunkDoes() throws {
        let (model, store) = try makeDatedModel([("Q", -1, nil), ("P", nil, nil), ("H", -2, 600), ("A", -2, 540)])
        func check(_ trunk: [String], _ step: String) {
            XCTAssertEqual(model.rows(for: .now).map(\.model.title), trunk, "\(step): the rows shown")
            model.toggleCompletedToday()
            XCTAssertEqual(model.rows(for: .now).map(\.model.title), trunk, "\(step): a full build")
            model.toggleCompletedToday()
        }
        check(["Q", "A", "H", "P"], "start")
        func task(_ title: String) throws -> UUID { try XCTUnwrap(model.rows(for: .now).first { $0.model.title == title }?.id) }
        let id = try task("H"), before = try task("P")
        model.completeAcknowledged(id) { _ in }
        XCTAssertNotNil(model.held[id])
        check(["Q", "A", "H", "P"], "the press")
        XCTAssertTrue(model.library.updateTask(before, status: .inProgress).isApplied)
        check(["Q", "A", "H", "P"], "the task before the held one moved")
        model.settlePendingCompletionAcknowledgements(through: id)
        XCTAssertEqual(store.task(withID: id)?.status, .done)
        check(["Q", "A", "H", "P"], "the save")
        model.releaseHold(id)
        check(["Q", "A", "P"], "the release")
    }

    /// PR 30 round 3: the view's filter changes during a hold (a row held
    /// with To Do picked, then Any Status again). Its index is a place in the
    /// filtered list, so the list shows as the trunk's full build gives it,
    /// at every step. The trunk's lists are traced from 2715d5da's
    /// `buildRows`: the held task goes back at its index in the ungrouped
    /// list, and Overdue orders day -2's rows by clock in that day's places.
    /// Uses no API the PR added.
    func testRowHeldUnderAViewFilterShowsAsTheTrunkDoesOnceTheFilterChanges() throws {
        let (model, store) = try makeDatedModel([("Q", -1, nil), ("H", -2, 600), ("A", -2, 540), ("U", nil, nil)])
        func check(_ trunk: [String], _ step: String) {
            XCTAssertEqual(model.rows(for: .now).map(\.model.title), trunk, "\(step): the rows shown")
            model.toggleCompletedToday()
            XCTAssertEqual(model.rows(for: .now).map(\.model.title), trunk, "\(step): a full build")
            model.toggleCompletedToday()
        }
        func task(_ title: String) throws -> UUID { try XCTUnwrap(model.rows(for: .now).first { $0.model.title == title }?.id) }
        // Q in progress goes first in the order: Q H A U.
        XCTAssertTrue(model.library.updateTask(try task("Q"), status: .inProgress).isApplied)
        check(["Q", "A", "H", "U"], "start")
        model.setViewOptions(TasksViewOptions(status: .toDo), for: .now)
        check(["A", "H", "U"], "To Do")
        let id = try task("H")
        model.completeAcknowledged(id) { _ in }
        XCTAssertNotNil(model.held[id])
        check(["A", "H", "U"], "the press, with To Do")
        model.setViewOptions(TasksViewOptions(), for: .now)
        check(["Q", "A", "H", "U"], "Any Status again during the hold")
        model.settlePendingCompletionAcknowledgements(through: id)
        XCTAssertEqual(store.task(withID: id)?.status, .done)
        check(["Q", "A", "H", "U"], "the save")
        model.releaseHold(id)
        check(["Q", "A", "U"], "the release")
    }

    /// PR 30 round 3: the tag picks change during a hold (a row held with
    /// one tag picked, then All again). As the view filter above, traced from
    /// 2715d5da's `buildRows`. Uses no API the PR added.
    func testRowHeldUnderATagPickShowsAsTheTrunkDoesOnceThePickChanges() throws {
        let (model, store) = try makeDatedModel([("Q", -1, nil), ("H", -2, 600), ("A", -2, 540), ("U", nil, nil)])
        func check(_ trunk: [String], _ step: String) {
            XCTAssertEqual(model.rows(for: .now).map(\.model.title), trunk, "\(step): the rows shown")
            model.toggleCompletedToday()
            XCTAssertEqual(model.rows(for: .now).map(\.model.title), trunk, "\(step): a full build")
            model.toggleCompletedToday()
        }
        func task(_ title: String) throws -> UUID { try XCTUnwrap(model.rows(for: .now).first { $0.model.title == title }?.id) }
        for title in ["H", "A", "U"] { XCTAssertTrue(model.library.updateTask(try task(title), tags: ["picked"]).isApplied) }
        check(["Q", "A", "H", "U"], "start")
        model.setTagPicks(TagPicks(["picked"]))
        check(["A", "H", "U"], "the pick")
        let id = try task("H")
        model.completeAcknowledged(id) { _ in }
        XCTAssertNotNil(model.held[id])
        check(["A", "H", "U"], "the press, with the pick")
        model.setTagPicks(TagPicks.none)
        check(["Q", "A", "H", "U"], "All again during the hold")
        model.settlePendingCompletionAcknowledgements(through: id)
        XCTAssertEqual(store.task(withID: id)?.status, .done)
        check(["Q", "A", "H", "U"], "the save")
        model.releaseHold(id)
        check(["Q", "A", "U"], "the release")
    }

    /// PR 30 round 3, R-4: folding a group above a held row during its hold
    /// leaves the row where the trunk's full build puts it. Its index was
    /// taken with Today open, so it is a place in that list only. Traced
    /// from 2715d5da's `buildRows`: Z goes back at index 4 of the ungrouped
    /// list (Y W V X Z T U), so Tomorrow stays X Z T and folded Today's rows
    /// are left out. Uses no API the PR added.
    func testFoldAboveAHeldRowLeavesItAsTheTrunkDoes() throws {
        let (model, store) = try makeDatedModel([("Y", 0, nil), ("W", 0, nil), ("V", 0, nil), ("X", 1, nil), ("Z", 1, nil),
                                                 ("T", 1, nil), ("U", nil, nil)])
        func check(_ trunk: [String], _ step: String) {
            XCTAssertEqual(model.rows(for: .now).map(\.model.title), trunk, "\(step): the rows shown")
            model.toggleCompletedToday()
            XCTAssertEqual(model.rows(for: .now).map(\.model.title), trunk, "\(step): a full build")
            model.toggleCompletedToday()
        }
        check(["Y", "W", "V", "X", "Z", "T", "U"], "start")
        let today = try XCTUnwrap(model.sections(for: .now).groups.first { $0.kind == .today }?.key)
        let id = try XCTUnwrap(model.rows(for: .now).first { $0.model.title == "Z" }?.id)
        model.completeAcknowledged(id) { _ in }
        XCTAssertNotNil(model.held[id])
        check(["Y", "W", "V", "X", "Z", "T", "U"], "the press")
        model.toggleGroup(today, on: .now)
        check(["X", "Z", "T", "U"], "Today folded during the hold")
        model.settlePendingCompletionAcknowledgements(through: id)
        XCTAssertEqual(store.task(withID: id)?.status, .done)
        check(["X", "Z", "T", "U"], "the save")
        model.releaseHold(id)
        check(["X", "T", "U"], "the release")
    }

    /// PR 30 R-2: a reader of the rows that runs before the model hears of a
    /// store change (here the store's `objectWillChange`, which is sent
    /// before any `$revision` subscriber runs, at the moment the store's
    /// data revision has moved), during a new hold, gets a full build, never
    /// a restate: the restate would clear a change set the model has not yet
    /// noted. Red on e70d134e, where that read restated only the held row.
    /// It does not assert the changed row's title: a full build there reuses
    /// the row's cached projection, as the trunk does (R-5, board row
    /// rows-early-read-stale-projection, its own PR).
    func testRowsReadBeforeTheModelHearsOfAChangeAreBuiltInFull() throws {
        let (model, store) = try makeDatedModel([("K", nil, nil), ("L", nil, nil), ("M", nil, nil)])
        func task(_ title: String) throws -> UUID { try XCTUnwrap(model.rows(for: .now).first { $0.model.title == title }?.id) }
        let held = try task("K"), changed = try task("L")
        var seen = store.taskDataRevision, earlyReads = 0, earlyMisses = 0, earlyRestates = 0
        let early = store.objectWillChange.sink { _ in
            guard store.taskDataRevision != seen else { return }
            seen = store.taskDataRevision
            earlyReads += 1
            let misses = model.rowsCacheMissCount[.now, default: 0], restates = model.rowsRestateCount[.now, default: 0]
            _ = model.rows(for: .now)
            earlyMisses += model.rowsCacheMissCount[.now, default: 0] - misses
            earlyRestates += model.rowsRestateCount[.now, default: 0] - restates
        }
        defer { early.cancel() }
        model.completeAcknowledged(held) { _ in }
        XCTAssertNotNil(model.held[held])
        XCTAssertTrue(model.library.updateTask(changed, title: "L renamed").isApplied)
        XCTAssertEqual(earlyReads, 1, "the early reader ran during the store's publication")
        XCTAssertEqual(earlyRestates, 0, "R-2: a read before the model noted the change restated the list")
        XCTAssertEqual(earlyMisses, 1, "R-2: a read before the model noted the change was not a full build")
        XCTAssertEqual(model.rows(for: .now).map(\.id), [held, changed, try task("M")])
    }

    // MARK: - Plain waste

    /// The night job's a2f6599d: the list page watches the snapshot's
    /// ordered IDs for the keyboard's completion focus transfer instead of
    /// projecting its rows' IDs again on every pass. The watch sees the
    /// same values only if the snapshot's IDs are its rows' order on every
    /// path that makes a snapshot. One tick on a tracker-shaped Now (80
    /// open, tagged): after the press and the save (the held row restated
    /// in place, which carries the built IDs over) and after the release (a
    /// full build), on Now and Later.
    func testGuardCompletionSnapshotIDsAreTheRowsOrder() throws {
        let store = try makeStore(open: 80, later: 12, tagged: true)
        var services = TasksPageServices()
        services.acknowledgementDelay = .seconds(25)
        services.doneHold = .seconds(25)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: services)
        let hosting = page(model, store)
        func assertSnapshotOrder(_ when: String) {
            for tab in [TasksTab.now, .backlog] {
                let snapshot = model.listSnapshot(for: tab)
                XCTAssertFalse(snapshot.ids.isEmpty, "\(tab) has rows \(when)")
                XCTAssertEqual(snapshot.ids, snapshot.rows.map(\.id), "\(tab)'s snapshot IDs are its rows' order \(when)")
            }
        }
        assertSnapshotOrder("before the tick")
        let id = try XCTUnwrap(model.rows(for: .now).first?.id)
        let restates = model.rowsRestateCount[.now, default: 0]

        model.completeAcknowledged(id) { _ in }  // press: the row is held, ticked
        settle(hosting)
        XCTAssertNotNil(model.held[id], "the press holds the row")
        assertSnapshotOrder("after the press")
        model.settlePendingCompletionAcknowledgements(through: id)  // the save
        settle(hosting)
        XCTAssertEqual(store.task(withID: id)?.status, .done)
        assertSnapshotOrder("after the save")
        let restated = model.rowsRestateCount[.now, default: 0] - restates
        XCTAssertGreaterThan(restated, 0, "the hold restated Now in place, so that path was checked")
        model.releaseHold(id)  // the release: the row leaves Now
        settle(hosting)
        settle(hosting)
        XCTAssertNil(model.held[id])
        XCTAssertFalse(model.listSnapshot(for: .now).ids.contains(id), "the ticked row left Now")
        assertSnapshotOrder("after the release")
        print("GUARD_COMPLETION_IDS open=80 now_restated_during_hold=\(restated)")
    }

    // MARK: - Rig

    private static let size = CGSize(width: 344, height: 520)

    /// Open tasks on Now, tasks in Later, finished tasks in the Done log
    /// (finished before today) and unrelated notes.
    private func makeStore(open: Int, later: Int = 0, logged: Int = 0, notes: Int = 0, tagged: Bool = false) throws -> TaskStore {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        let now = Date()
        var order: Int64 = 10_000_000
        func insert(_ title: String, _ status: TaskStatus, completed: Date? = nil, tags: [String] = []) {
            order -= 1_024
            let item = TaskItem(title: title, status: status, createdAt: now, completedAt: completed, manualOrder: order)
            item.listOrderVersion = TaskItem.currentListOrderVersion
            if let completed { item.doneLoggedAt = completed }
            if !tags.isEmpty { item.tags = tags }
            context.insert(item)
        }
        for index in 0..<open { insert("Open task \(index)", .todo, tags: tagged ? ["open\(index % 5)"] : []) }
        for index in 0..<later { insert("Later task \(index)", .backlog) }
        for index in 0..<logged {
            insert("Finished task \(index)", .done, completed: now.addingTimeInterval(-86_400 - Double(index + 1) * 3_600),
                   tags: tagged ? ["done\(index % 7)"] : [])
        }
        for index in 0..<notes { context.insert(NoteItem(title: "Note \(index)", body: "Unrelated note \(index)")) }
        try context.save()
        return TaskStore(container: container)
    }

    /// Open tasks on Now in this manual order (the first is first), each
    /// with its due day as days from today and its clock in minutes, and the
    /// model on them, with the save and the release left to the test.
    private func makeDatedModel(_ specs: [(title: String, day: Int?, clock: Int?)]) throws -> (TasksPageModel, TaskStore) {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        let calendar = Calendar.autoupdatingCurrent, now = Date()
        var order: Int64 = 10_000_000
        for spec in specs {
            order -= 1_024
            let item = TaskItem(title: spec.title, status: .todo, createdAt: now, manualOrder: order)
            item.listOrderVersion = TaskItem.currentListOrderVersion
            if let day = spec.day {
                item.dueDay = DueDay(date: calendar.date(byAdding: .day, value: day, to: now)!, calendar: calendar)
                item.dueTimeMinutes = spec.clock
            }
            context.insert(item)
        }
        try context.save()
        let store = TaskStore(container: container)
        var services = TasksPageServices()
        services.acknowledgementDelay = .seconds(25)
        services.doneHold = .seconds(25)
        return (TasksPageModel(library: AtticLibrary(tasks: store), services: services), store)
    }

    private func page(_ model: TasksPageModel, _ store: TaskStore) -> NSView {
        host(TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: Self.size),
                       addBarFocused: .constant(false)))
    }

    private func host<Content: View>(_ content: Content) -> NSView {
        let hosting = NSHostingView(rootView: content.frame(width: Self.size.width, height: Self.size.height).atticDesign(.default))
        hosting.frame = CGRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        self.window?.close()
        self.window = window
        settle(hosting)
        return hosting
    }

    /// One update: the main queue drains, then the view lays out and draws.
    private func settle(_ hosting: NSView) {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
        hosting.layoutSubtreeIfNeeded()
        hosting.window?.displayIfNeeded()
    }
}
