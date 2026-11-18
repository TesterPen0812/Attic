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
                  + "page_passes=\(pagePasses) model_sends=\(modelSends) cell_broadcasts=\(cellBroadcasts)")
            XCTAssertGreaterThan(pagePasses, 0, "the hosted page did not update, so its count proves nothing")
            XCTAssertLessThanOrEqual(nowMisses, 1, "F3/TA-02: one tick rebuilt Now's rows \(nowMisses) times (size \(size))")
            bySize[size] = nowMisses
        }
        XCTAssertEqual(bySize[40], bySize[400], "F3/TA-02: a tick's row rebuilds grew with the store")
    }

    // MARK: - Item 3: reads that grow with the data

    /// Astra TA-03. A plain create (no writing, tags or files) through the
    /// card's path reads the same number of records for its Undo step in a
    /// library ten times larger, with ten times the unrelated tasks and notes.
    func testGuardCreateReadsNoMoreRecordsInALargerLibrary() throws {
        var bySize: [Int: Int] = [:]
        for size in [100, 1_000] {
            let store = try makeStore(open: size, notes: size / 2)
            let library = AtticLibrary(tasks: store)
            var services = TasksPageServices()
            services.acknowledgementDelay = .seconds(25)
            let model = TasksPageModel(library: library, services: services)
            _ = model.rows(for: .now)
            let draft = TaskDraft(title: "Plain new task")
            let before = library.ownershipRecordsRead
            var created: TaskItem?
            _ = model.createAcknowledged(draft, save: { library.createTask(draft, writing: "", in: .tasks, id: $0) },
                                         settled: { created = $0 })
            model.settlePendingCompletionAcknowledgements()
            XCTAssertNotNil(created, "the create saved")
            let read = library.ownershipRecordsRead - before
            print("GUARD_CREATE tasks=\(size) notes=\(size / 2) ownership_records_read=\(read)")
            bySize[size] = read
        }
        XCTAssertEqual(bySize[100], bySize[1_000], "TA-03: a plain create's Undo ownership read grew with the library")
    }

    /// Astra TA-05. A priority edit on Now: the tag bar's chips visit the same
    /// number of Done log index entries with a Done log ten times longer.
    func testGuardPriorityEditVisitsNoMoreDoneLogEntriesForTheTagBar() throws {
        var bySize: [Int: Int] = [:]
        for logged in [50, 500] {
            let store = try makeStore(open: 20, logged: logged, tagged: true)
            let model = TasksPageModel(library: AtticLibrary(tasks: store))
            let hosting = page(model, store)
            let id = try XCTUnwrap(model.rows(for: .now).first?.id)
            let before = store.doneLogTagEntryVisits
            XCTAssertTrue(model.setPriority(.high, for: [id]).isApplied)
            settle(hosting)
            settle(hosting)
            let visits = store.doneLogTagEntryVisits - before
            print("GUARD_TAG_BAR open=20 done_log=\(logged) done_log_entries_visited=\(visits)")
            bySize[logged] = visits
        }
        XCTAssertEqual(bySize[50], bySize[500], "TA-05: a priority edit's tag bar walk grew with the Done log")
    }

    /// Opus F7. A store save reaches the panel's revision observer, which
    /// hands the same number of live task IDs on in a store ten times larger.
    func testGuardStoreSaveHandsNoMoreTaskIDsToThePanelObserver() throws {
        var bySize: [Int: Int] = [:]
        for size in [100, 1_000] {
            let store = try makeStore(open: size)
            let model = TasksPageModel(library: AtticLibrary(tasks: store))
            let uiState = PanelUIState()
            let hosting = host(PanelStoreRevisionObserver(store: store, uiState: uiState))
            let id = try XCTUnwrap(model.rows(for: .now).first?.id)
            let before = uiState.reconciledTaskIDCount
            XCTAssertTrue(model.setPriority(.high, for: [id]).isApplied)
            settle(hosting)
            settle(hosting)
            let handed = uiState.reconciledTaskIDCount - before
            print("GUARD_PANEL_OBSERVER tasks=\(size) task_ids_handed=\(handed)")
            bySize[size] = handed
        }
        XCTAssertEqual(bySize[100], bySize[1_000], "F7: a save's task-ID reconcile grew with the store")
    }

    /// Opus F4. With Done drawn, an edit to a Now task re-reads and
    /// re-projects the same number of Done log rows with four pages loaded
    /// as with one.
    func testGuardUnrelatedEditReadsNoMoreOfALongerLoadedDoneLog() throws {
        var reads: [Int: Int] = [:], projections: [Int: Int] = [:]
        for pages in [1, 4] {
            let (model, store, hosting) = try doneDrawn(loadedPages: pages)
            let id = try XCTUnwrap(store.tasks.first { $0.status == .todo }?.id)
            let parents = store.doneFamilyParentReadCount, pageReads = store.donePageReadCount
            let built = model.rowProjectionBuildCount
            XCTAssertTrue(model.setPriority(.high, for: [id]).isApplied)
            settle(hosting)
            settle(hosting)
            let parentReads = store.doneFamilyParentReadCount - parents
            let projected = model.rowProjectionBuildCount - built
            print("GUARD_DONE_UNRELATED_EDIT pages=\(pages) loaded=\(model.doneLogTasks.count) "
                  + "done_parent_reads=\(parentReads) done_page_reads=\(store.donePageReadCount - pageReads) row_projections=\(projected)")
            reads[pages] = parentReads
            projections[pages] = projected
        }
        XCTAssertEqual(reads[1], reads[4], "F4: an unrelated edit re-read more Done log rows with more pages loaded")
        XCTAssertEqual(projections[1], projections[4], "F4: an unrelated edit re-projected more rows with more pages loaded")
    }

    /// Astra TA-04. With Done drawn, appending one page projects the same
    /// number of rows with three pages loaded as with one, and an edit to one
    /// loaded archived task re-reads the same number of rows.
    func testGuardDonePageAppendAndArchivedEditDoNotGrowWithTheLoadedLog() throws {
        var appended: [Int: Int] = [:], edited: [Int: Int] = [:]
        for pages in [1, 3] {
            let (model, store, hosting) = try doneDrawn(loadedPages: pages)
            let built = model.rowProjectionBuildCount, parents = store.doneFamilyParentReadCount
            model.loadMoreDoneLog()
            settle(hosting)
            settle(hosting)
            let appendProjections = model.rowProjectionBuildCount - built
            let appendReads = store.doneFamilyParentReadCount - parents
            let archived = try XCTUnwrap(model.doneLogTasks.first?.id)
            let editParents = store.doneFamilyParentReadCount
            XCTAssertTrue(model.setPriority(.high, for: [archived]).isApplied)
            settle(hosting)
            settle(hosting)
            let editReads = store.doneFamilyParentReadCount - editParents
            print("GUARD_DONE_APPEND pages_before=\(pages) loaded_after=\(model.doneLogTasks.count) "
                  + "append_row_projections=\(appendProjections) append_parent_reads=\(appendReads) archived_edit_parent_reads=\(editReads)")
            appended[pages] = appendProjections
            edited[pages] = editReads
        }
        XCTAssertEqual(appended[1], appended[3], "TA-04: one appended Done page projected more rows with more pages loaded")
        XCTAssertEqual(edited[1], edited[3], "TA-04: an archived task's edit re-read more rows with more pages loaded")
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

    /// The Tasks page with Done drawn and `loadedPages` pages of its log loaded.
    private func doneDrawn(loadedPages: Int) throws -> (TasksPageModel, TaskStore, NSView) {
        let store = try makeStore(open: 20, logged: 400)
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        let hosting = page(model, store)
        model.select(tab: .done)
        model.showPagerPage(animated: false)
        settle(hosting)
        model.loadDoneLogIfNeeded()
        while model.doneLogTasks.count < loadedPages * TasksPageModel.doneLogPageSize, model.doneLogHasMore {
            model.loadMoreDoneLog()
        }
        settle(hosting)
        settle(hosting)
        XCTAssertEqual(model.tab, .done)
        XCTAssertGreaterThanOrEqual(model.doneLogTasks.count, loadedPages * TasksPageModel.doneLogPageSize)
        return (model, store, hosting)
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
