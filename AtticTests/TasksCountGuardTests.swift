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
