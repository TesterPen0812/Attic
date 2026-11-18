import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Red-first count guards for Done's loaded set (18 Nov 2026,
/// `reports/perf-audit/tasks-actions.opus.md` F4 and `tasks-actions.astra.md`
/// TA-04): an edit elsewhere, one more page and an archived task's edit must
/// not re-read or re-project every loaded Done log row. Each runs the same
/// action with more pages loaded and fails when the count grows with them.
/// Each prints a `GUARD_` line with its counts.
///
/// The page is the real `TasksPage`, hosted in a borderless window that is
/// never shown. A step is settled by letting the main queue drain (an
/// expectation, not a fixed wait) and then laying out and drawing, as a
/// frame would.
@MainActor
final class DoneLoadedSetCountGuardTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
        try await super.tearDown()
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

    /// The fix's own check (the oracle): every in-place update of the loaded
    /// pages is read again in full and compared, rows, families and order,
    /// and every reused Done row is projected again and compared. Run through
    /// edits elsewhere, archived edits (a parent's and, where the page lists
    /// it, a subtask's), a search, a failed read and Retry, and the changes
    /// that must still read the pages in full: an archived delete and its
    /// Undo, Restore to Now, and a delete that gives the store a new context.
    func testDoneLogInPlaceUpdatesMatchAFullRead() throws {
        TasksPageModel.checksDoneLogInPlace = true
        defer { TasksPageModel.checksDoneLogInPlace = false }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        let now = Date()
        var order: Int64 = 10_000_000
        var parents: [UUID] = [], children: [UUID] = []
        for index in 0..<12 {
            order -= 1_024
            let open = TaskItem(title: "Open task \(index)", status: .todo, createdAt: now, manualOrder: order)
            open.listOrderVersion = TaskItem.currentListOrderVersion
            context.insert(open)
        }
        for index in 0..<100 {
            order -= 1_024
            let completed = now.addingTimeInterval(-86_400 - Double(index + 1) * 3_600)
            let parent = TaskItem(title: "Finished task \(index)", status: .done, createdAt: now, completedAt: completed, manualOrder: order)
            parent.listOrderVersion = TaskItem.currentListOrderVersion
            parent.doneLoggedAt = completed
            context.insert(parent)
            parents.append(parent.id)
            if index % 4 == 0 {
                for step in 0..<2 {
                    let child = TaskItem(title: "Step \(step) of \(index)", status: .done, createdAt: now,
                                         completedAt: completed.addingTimeInterval(-Double(step + 1) * 60), parentID: parent.id)
                    child.doneLoggedAt = completed
                    context.insert(child)
                    children.append(child.id)
                }
            }
        }
        try context.save()
        let store = TaskStore(container: container)
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        let hosting = page(model, store)
        model.select(tab: .done)
        model.showPagerPage(animated: false)
        settle(hosting)
        model.loadDoneLogIfNeeded()
        model.loadMoreDoneLog()
        settle(hosting)
        XCTAssertEqual(model.doneLogTasks.count, 2 * TasksPageModel.doneLogPageSize)
        var inPlace = model.doneLogInPlaceRefreshCount
        func step(_ name: String, inPlace expected: Bool, _ body: () -> Void) {
            body()
            settle(hosting)
            settle(hosting)
            _ = model.doneDays()
            let ran = model.doneLogInPlaceRefreshCount > inPlace
            print("DONE_IN_PLACE step=\"\(name)\" in_place=\(ran) loaded=\(model.doneLogTasks.count) "
                  + "failure=\(model.doneLogFailure != nil) mismatches=\(model.doneLogInPlaceMismatches.count)")
            XCTAssertEqual(ran, expected, "\(name): updated in place")
            XCTAssertEqual(model.doneLogInPlaceMismatches, [], "\(name)")
            inPlace = model.doneLogInPlaceRefreshCount
        }
        let nowIDs = store.tasks.filter { $0.status == .todo }.map(\.id)
        step("edit on Now", inPlace: true) { XCTAssertTrue(model.setPriority(.high, for: [nowIDs[0]]).isApplied) }
        step("archived priority", inPlace: true) { XCTAssertTrue(model.setPriority(.high, for: [parents[4]]).isApplied) }
        step("archived tag on a family", inPlace: true) { XCTAssertTrue(model.toggleTag("kept", for: [parents[8]]).isApplied) }
        if model.listedTask(children[0]) != nil {
            step("archived subtask's tag", inPlace: true) { XCTAssertTrue(model.toggleTag("step", for: [children[0]]).isApplied) }
        } else {
            print("DONE_IN_PLACE step=\"archived subtask's tag\" skipped: the page does not list an archived subtask")
        }
        step("two edits, then the page reads", inPlace: true) {
            XCTAssertTrue(model.setPriority(.medium, for: [nowIDs[1]]).isApplied)
            XCTAssertTrue(model.setPriority(.low, for: [parents[12]]).isApplied)
        }
        store.doneLogReadFailures = 1
        step("archived edit whose read fails", inPlace: false) {
            XCTAssertTrue(model.setPriority(.medium, for: [parents[16]]).isApplied)
        }
        XCTAssertNotNil(model.doneLogFailure, "a failed read shows Retry")
        XCTAssertEqual(model.doneLogTasks.count, 2 * TasksPageModel.doneLogPageSize, "a failed read keeps what loaded")
        step("Retry", inPlace: true) { model.retryDoneLog() }
        XCTAssertNil(model.doneLogFailure)
        step("archived delete reads in full", inPlace: false) { XCTAssertTrue(model.delete([parents[20]]).isApplied) }
        step("its Undo reads in full", inPlace: false) { XCTAssertTrue(model.undo().isApplied) }
        step("edit after Undo", inPlace: true) { XCTAssertTrue(model.setPriority(.high, for: [parents[20]]).isApplied) }
        step("Restore to Now reads in full", inPlace: false) { XCTAssertTrue(model.restoreToNow([parents[24]]).isApplied) }
        step("a delete on Now gives the store a new context", inPlace: false) {
            XCTAssertTrue(model.delete([nowIDs[2]]).isApplied)
        }
        step("edit after the new context", inPlace: true) { XCTAssertTrue(model.setPriority(.high, for: [nowIDs[3]]).isApplied) }
        model.doneSearch = "Finished task 3"
        model.flushDoneSearchInput()
        settle(hosting)
        step("search: edit on Now", inPlace: true) { XCTAssertTrue(model.setPriority(.low, for: [nowIDs[4]]).isApplied) }
        step("search: archived edit", inPlace: true) { XCTAssertTrue(model.setPriority(.low, for: [parents[32]]).isApplied) }
    }

    /// Review R-1 of PR 31. A Done log shorter than one page is loaded whole.
    /// When a save logs a task below its loaded rows (the daily cleanup
    /// logging a task finished long ago), the next update shows that row at
    /// once, as a full read did: no loading rows, and nothing left to read.
    /// Run with an empty log too (the first task logged).
    func testShortDoneLogShowsARowLoggedBelowItWithoutLoadingRows() throws {
        for logged in [10, 0] {
            let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
            let context = ModelContext(container)
            let now = Date()
            var order: Int64 = 10_000_000
            for index in 0..<logged {
                order -= 1_024
                let completed = now.addingTimeInterval(-86_400 - Double(index + 1) * 3_600)
                let task = TaskItem(title: "Finished task \(index)", status: .done, createdAt: now, completedAt: completed, manualOrder: order)
                task.listOrderVersion = TaskItem.currentListOrderVersion
                task.doneLoggedAt = completed
                context.insert(task)
            }
            // Finished a month ago and still in the list: logging it puts it
            // below every loaded row.
            order -= 1_024
            let late = TaskItem(title: "Finished long ago", status: .done, createdAt: now.addingTimeInterval(-40 * 86_400),
                                completedAt: now.addingTimeInterval(-30 * 86_400), manualOrder: order)
            late.listOrderVersion = TaskItem.currentListOrderVersion
            context.insert(late)
            try context.save()
            let lateID = late.id
            let store = TaskStore(container: container)
            let model = TasksPageModel(library: AtticLibrary(tasks: store))
            model.select(tab: .done)
            model.loadDoneLogIfNeeded()
            XCTAssertEqual(model.doneLogTasks.count, logged, "logged=\(logged)")
            XCTAssertFalse(model.doneLogHasMore, "logged=\(logged): the short log is loaded whole")

            let reads = store.donePageReadCount
            XCTAssertEqual(store.moveCompletedToDoneLog(before: Calendar.current.startOfDay(for: now)), 1, "logged=\(logged)")
            // The save named the task, so the loaded page may be updated in place.
            XCTAssertEqual(store.revisionChangedTaskIDs?.contains(lateID), true, "logged=\(logged)")
            model.loadDoneLogIfNeeded()
            XCTAssertEqual(model.doneLogTasks.map(\.id).last, lateID,
                           "R-1 logged=\(logged): the row logged below the short log is shown at once")
            XCTAssertEqual(model.doneLogTasks.count, logged + 1, "R-1 logged=\(logged)")
            XCTAssertFalse(model.doneLogHasMore, "R-1 logged=\(logged): the short log shows loading rows")
            let afterUpdate = store.donePageReadCount
            // What the loading row does when it is drawn.
            model.loadMoreDoneLog()
            XCTAssertEqual(store.donePageReadCount, afterUpdate,
                           "R-1 logged=\(logged): the short log read again for a row a full read shows at once")
            XCTAssertEqual(model.doneLogTasks.count, logged + 1, "R-1 logged=\(logged)")
            XCTAssertEqual(store.donePageReadCount - reads, 1, "logged=\(logged): one read in all, as a full read")
            print("GUARD_DONE_SHORT_LOG logged=\(logged) loaded=\(model.doneLogTasks.count) "
                  + "has_more=\(model.doneLogHasMore) done_page_reads=\(store.donePageReadCount - reads)")
        }
    }

    /// Review R-2 of PR 31. A full read that fails puts the cursor back at
    /// the log's start. When Retry then brings the loaded page up to date in
    /// place, the next page must still start after the loaded rows: no row
    /// twice, and the rows the index has next.
    func testDoneLogNextPageAfterAnInPlaceRetryRepeatsNoRow() throws {
        let store = try makeStore(open: 5, logged: 100)
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        model.select(tab: .done)
        model.loadDoneLogIfNeeded()
        let pageSize = TasksPageModel.doneLogPageSize
        XCTAssertEqual(model.doneLogTasks.count, pageSize)
        XCTAssertTrue(model.doneLogHasMore)

        // An edit to a loaded Done task asks for the pages again (a save that
        // failed publishes no revision, so this is a full read), and that
        // read fails: Retry is shown and what loaded is kept.
        store.doneLogReadFailures = 1
        model.reloadDoneLogAfterEdit()
        XCTAssertNotNil(model.doneLogFailure, "the full read failed")
        XCTAssertEqual(model.doneLogTasks.count, pageSize, "a failed read keeps what loaded")

        // A save elsewhere names its task; Retry brings the page up to date in place.
        let open = try XCTUnwrap(store.tasks.first { $0.status == .todo }?.id)
        XCTAssertTrue(model.setPriority(.high, for: [open]).isApplied)
        let inPlace = model.doneLogInPlaceRefreshCount
        model.retryDoneLog()
        XCTAssertNil(model.doneLogFailure)
        XCTAssertEqual(model.doneLogInPlaceRefreshCount, inPlace + 1, "Retry updated the loaded page in place")
        XCTAssertEqual(model.doneLogTasks.count, pageSize)

        model.loadMoreDoneLog()
        let ids = model.doneLogTasks.map(\.id)
        let index = store.indexedDoneLogIDs(limit: 3 * pageSize).ids
        print("GUARD_DONE_CURSOR loaded=\(ids.count) unique=\(Set(ids).count)")
        XCTAssertEqual(Set(ids).count, ids.count, "R-2: the next page after an in-place Retry repeated loaded rows")
        XCTAssertEqual(ids.count, 2 * pageSize, "R-2: one more page")
        XCTAssertEqual(Array(ids.dropFirst(pageSize)), Array(index[pageSize..<min(2 * pageSize, index.count)]),
                       "R-2: the next page is not the rows after the loaded ones")
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
