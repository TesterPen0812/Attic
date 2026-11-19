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
    /// it, a subtask's), a search, and the changes that must still read the
    /// pages in full: an archived delete and its Undo, Restore to Now, and a
    /// delete that gives the store a new context. Failed reads have their own
    /// tests, one per read the in-place update makes.
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
            let (store, lateID, now) = try makeDoneLog(logged: logged)
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

    /// The in-place update asks where a named task that is neither loaded
    /// nor listed belongs (`savedParentIDs`). That read goes through the
    /// Done log's reads, so an injected failure reaches it: the update falls
    /// back to a full read, nothing is shown as failed, and the rows are the
    /// log's, page after page.
    func testDoneLogInPlaceParentReadFailureFallsBackToAFullRead() throws {
        let (store, lateID, now) = try makeDoneLog(logged: 100)
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        model.select(tab: .done)
        model.loadDoneLogIfNeeded()
        let pageSize = TasksPageModel.doneLogPageSize
        XCTAssertEqual(model.doneLogTasks.count, pageSize)

        // The daily cleanup logs a task below the loaded page; it is not
        // listed, so the update reads where it belongs, and that read fails.
        XCTAssertEqual(store.moveCompletedToDoneLog(before: Calendar.current.startOfDay(for: now)), 1)
        XCTAssertEqual(store.revisionChangedTaskIDs?.contains(lateID), true, "the save named the task")
        store.doneLogReadFailures = 1
        let inPlace = model.doneLogInPlaceRefreshCount
        model.loadDoneLogIfNeeded()
        print("GUARD_DONE_PARENT_READ_FAILURE pending_failures=\(store.doneLogReadFailures) "
              + "in_place=\(model.doneLogInPlaceRefreshCount - inPlace) loaded=\(model.doneLogTasks.count)")
        XCTAssertEqual(store.doneLogReadFailures, 0, "the injected failure reached the parent read")
        XCTAssertEqual(model.doneLogInPlaceRefreshCount, inPlace, "a failed parent read falls back to a full read")
        XCTAssertNil(model.doneLogFailure, "the full read succeeded: nothing is shown as failed")
        XCTAssertEqual(model.doneLogTasks.map(\.id), store.indexedDoneLogIDs(limit: pageSize).ids)
        XCTAssertTrue(model.doneLogHasMore)
        XCTAssertEqual(model.doneLogState(), fullReadState(store, rows: model.doneLogTasks.count), "the state is a full read's")

        while model.doneLogHasMore, model.doneLogFailure == nil { model.loadMoreDoneLog() }
        let ids = model.doneLogTasks.map(\.id)
        XCTAssertNil(model.doneLogFailure)
        XCTAssertEqual(ids, store.indexedDoneLogIDs(limit: 200).ids, "every row of the log, in its order")
        XCTAssertEqual(ids.count, 101)
        XCTAssertEqual(ids.last, lateID)
    }

    // MARK: - Rig

    private static let size = CGSize(width: 344, height: 520)

    /// The lead's rule (19 Nov), per read the in-place update makes: one
    /// injected failure there changes nothing in place, and the pages are
    /// read in full in the same load, so the whole state (rows, families,
    /// query, revision, cursor, failure and Retry, the drawn days) is a full
    /// read's in the same build. The lookup is
    /// `testDoneLogInPlaceParentReadFailureFallsBackToAFullRead`; this is the
    /// touched parents' read.
    func testInPlaceParentReadFailureLeavesAFullReadsState() throws {
        let (store, parents) = try makeFamilyLog(logged: 60, families: [2])
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        model.select(tab: .done)
        model.loadDoneLogIfNeeded()
        XCTAssertEqual(model.doneLogTasks.count, TasksPageModel.doneLogPageSize)
        let inPlace = model.doneLogInPlaceRefreshCount
        store.doneLogReadFailures = 1
        XCTAssertTrue(model.setPriority(.high, for: [parents[5]]).isApplied)
        assertFullReadsState("parent_read", store, model, injectedUsed: store.doneLogReadFailures == 0, inPlace: inPlace)
        XCTAssertEqual(model.doneLogTasks.first { $0.id == parents[5] }?.priority, .high, "the list shows the edit")
    }

    /// The same for the touched families' read.
    func testInPlaceFamilyReadFailureLeavesAFullReadsState() throws {
        let (store, parents) = try makeFamilyLog(logged: 60, families: [2])
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        model.select(tab: .done)
        model.loadDoneLogIfNeeded()
        XCTAssertEqual(drawnSubtaskTotal(model, parents[2]), 2, "before: the row shows its two subtasks")
        let inPlace = model.doneLogInPlaceRefreshCount
        store.doneFamilyBatchReadFailures = 1
        XCTAssertTrue(model.setPriority(.high, for: [parents[2]]).isApplied)
        assertFullReadsState("family_read", store, model, injectedUsed: store.doneFamilyBatchReadFailures == 0, inPlace: inPlace)
        XCTAssertEqual(drawnSubtaskTotal(model, parents[2]), 2, "the row shows its two subtasks")
    }

    /// After one injected failure at an in-place read: it was used, nothing
    /// was applied in place, nothing shows as failed, and the state is a
    /// full read's. Prints `GUARD_DONE_IN_PLACE_SITE`.
    private func assertFullReadsState(_ site: String, _ store: TaskStore, _ model: TasksPageModel, injectedUsed: Bool, inPlace: Int,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let state = model.doneLogState()
        let oracle = fullReadState(store, rows: model.doneLogTasks.count)
        print("GUARD_DONE_IN_PLACE_SITE site=\(site) injected_used=\(injectedUsed) in_place=\(model.doneLogInPlaceRefreshCount - inPlace) "
              + "loaded=\(state.rows.count) failure=\(state.failure != nil) in_place_allowed=\(state.inPlaceAllowed) "
              + "matches_full_read=\(state == oracle)")
        XCTAssertTrue(injectedUsed, "\(site): the injected failure reached the in-place read", file: file, line: line)
        XCTAssertEqual(model.doneLogInPlaceRefreshCount, inPlace, "\(site): nothing was applied in place", file: file, line: line)
        XCTAssertNil(state.failure, "\(site): the full read succeeded: nothing shows as failed", file: file, line: line)
        XCTAssertEqual(state, oracle, "\(site): the state is a full read's", file: file, line: line)
    }

    /// The kept line, full read: a full read whose family read failed shows
    /// the row with no checklist and no Retry, as on the trunk, and refuses
    /// the in-place update until a full read succeeds. Later saves do not
    /// allow it again, nor does a full read that fails; the next full read
    /// that succeeds reads the family again and its state is a full read's.
    func testFullReadFamilyFailureRefusesInPlaceUntilAFullReadSucceeds() throws {
        let (store, parents) = try makeFamilyLog(logged: 60, families: [2])
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        model.select(tab: .done)
        store.doneFamilyBatchReadFailures = 1
        model.loadDoneLogIfNeeded()
        XCTAssertEqual(model.doneLogTasks.count, TasksPageModel.doneLogPageSize)
        try assertRefusedUntilAFullReadSucceeds("full_read", store, model, family: parents[2])
    }

    /// The kept line, one more page: the same when the page's family read
    /// failed.
    func testPageLoadFamilyFailureRefusesInPlaceUntilAFullReadSucceeds() throws {
        let (store, parents) = try makeFamilyLog(logged: 100, families: [50])
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        model.select(tab: .done)
        model.loadDoneLogIfNeeded()
        XCTAssertTrue(model.doneLogState().inPlaceAllowed, "before: the first page read in full")
        store.doneFamilyBatchReadFailures = 1
        model.loadMoreDoneLog()
        XCTAssertEqual(model.doneLogTasks.count, 2 * TasksPageModel.doneLogPageSize)
        try assertRefusedUntilAFullReadSucceeds("page_load", store, model, family: parents[50])
    }

    /// After a family read failed in a full read or a page load: the row
    /// shows no checklist and nothing shows as failed (the trunk's result);
    /// two saves on Now and a failed full read leave the in-place update
    /// refused; a third save and Retry (a full read that succeeds) read the
    /// family again, nothing was updated in place on the way, and the state
    /// is a full read's. Prints `GUARD_DONE_REFUSED`.
    private func assertRefusedUntilAFullReadSucceeds(_ path: String, _ store: TaskStore, _ model: TasksPageModel, family: UUID,
                                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let used = store.doneFamilyBatchReadFailures == 0
        let failed = model.doneLogState()
        let during = drawnSubtaskTotal(model, family)
        let nowIDs = store.tasks.filter { $0.status == .todo }.map(\.id)
        let inPlace = model.doneLogInPlaceRefreshCount
        XCTAssertTrue(model.setPriority(.low, for: [nowIDs[0]]).isApplied, file: file, line: line)
        XCTAssertTrue(model.setPriority(.medium, for: [nowIDs[1]]).isApplied, file: file, line: line)
        let afterSaves = model.doneLogState()
        store.doneLogReadFailures = 1
        model.loadDoneLogIfNeeded()
        let afterFailedRead = model.doneLogState()
        let fullReadFailureUsed = store.doneLogReadFailures == 0
        XCTAssertTrue(model.setPriority(.high, for: [nowIDs[2]]).isApplied, file: file, line: line)
        model.retryDoneLog()
        let recovered = model.doneLogState()
        let shown = drawnSubtaskTotal(model, family)
        let oracle = fullReadState(store, rows: model.doneLogTasks.count)
        print("GUARD_DONE_REFUSED path=\(path) injected_used=\(used) during=\(during.map(String.init) ?? "not_loaded") "
              + "allowed_after_failure=\(failed.inPlaceAllowed) allowed_after_saves=\(afterSaves.inPlaceAllowed) "
              + "full_read_failed=\(afterFailedRead.failure != nil) allowed_after_failed_read=\(afterFailedRead.inPlaceAllowed) "
              + "in_place=\(model.doneLogInPlaceRefreshCount - inPlace) recovered=\(shown.map(String.init) ?? "not_loaded") "
              + "allowed_after_recovery=\(recovered.inPlaceAllowed) matches_full_read=\(recovered == oracle)")
        XCTAssertTrue(used, "\(path): the injected failure reached the family read", file: file, line: line)
        XCTAssertEqual(during, 0, "\(path): the row shows no checklist, as on the trunk", file: file, line: line)
        XCTAssertNil(failed.failure, "\(path): no Retry, as on the trunk", file: file, line: line)
        XCTAssertFalse(failed.inPlaceAllowed, "\(path): the in-place update is refused", file: file, line: line)
        XCTAssertEqual(afterSaves.revision, failed.revision, "\(path): the saves on Now loaded nothing", file: file, line: line)
        XCTAssertFalse(afterSaves.inPlaceAllowed, "\(path): later saves do not allow it again", file: file, line: line)
        XCTAssertTrue(fullReadFailureUsed, "\(path): the next load was a full read, and it failed", file: file, line: line)
        XCTAssertNotNil(afterFailedRead.failure, "\(path): the failed full read shows Retry", file: file, line: line)
        XCTAssertFalse(afterFailedRead.inPlaceAllowed, "\(path): a failed full read does not allow it either", file: file, line: line)
        XCTAssertEqual(model.doneLogInPlaceRefreshCount, inPlace, "\(path): nothing was updated in place before a full read succeeded",
                       file: file, line: line)
        XCTAssertEqual(shown, 2, "\(path): the full read read the family again", file: file, line: line)
        XCTAssertTrue(recovered.inPlaceAllowed, "\(path): a full read that succeeded allows it again", file: file, line: line)
        XCTAssertEqual(recovered, oracle, "\(path): the state is a full read's", file: file, line: line)
    }

    /// The oracle: what a full read shows now, in the same build. A new model
    /// on the same store reads the first page, then pages on to `count` rows.
    private func fullReadState(_ store: TaskStore, rows count: Int) -> TasksPageModel.DoneLogState {
        let oracle = TasksPageModel(library: AtticLibrary(tasks: store))
        oracle.select(tab: .done)
        oracle.loadDoneLogIfNeeded()
        while oracle.doneLogTasks.count < count, oracle.doneLogHasMore, oracle.doneLogFailure == nil { oracle.loadMoreDoneLog() }
        return oracle.doneLogState()
    }

    /// The subtask total a drawn Done row shows (0 when it shows none); nil
    /// when the row is not loaded.
    private func drawnSubtaskTotal(_ model: TasksPageModel, _ id: UUID) -> Int? {
        guard let row = model.doneDays().flatMap(\.rows).first(where: { $0.id == id }) else { return nil }
        return row.model.subtasks?.total ?? 0
    }

    /// Astra r5 R2 of PR 31. The daily cleanup logs `archived` older tasks
    /// below a loaded page. Bringing the page up to date reads no more Done
    /// log rows than the loaded page, however many were archived (a full read
    /// reads the page). Prints `GUARD_DONE_PARENT_LOOKUP`.
    func testGuardUpdateAfterCleanupReadsNoMoreThanTheLoadedPage() throws {
        let pageSize = TasksPageModel.doneLogPageSize
        for archived in [100, 1_000] {
            let (store, now) = try makeCleanupLog(logged: pageSize, late: archived)
            let model = TasksPageModel(library: AtticLibrary(tasks: store))
            model.select(tab: .done)
            model.loadDoneLogIfNeeded()
            XCTAssertEqual(model.doneLogTasks.count, pageSize, "archived=\(archived)")
            XCTAssertEqual(store.moveCompletedToDoneLog(before: Calendar.current.startOfDay(for: now)), archived, "archived=\(archived)")
            XCTAssertNotNil(store.revisionChangedTaskIDs, "archived=\(archived): the cleanup named its tasks")
            let rows = store.doneLogRowsReadCount
            let inPlace = model.doneLogInPlaceRefreshCount
            model.loadDoneLogIfNeeded()
            let read = store.doneLogRowsReadCount - rows
            print("GUARD_DONE_PARENT_LOOKUP archived=\(archived) loaded=\(model.doneLogTasks.count) done_log_rows_read=\(read) "
                  + "in_place=\(model.doneLogInPlaceRefreshCount - inPlace) has_more=\(model.doneLogHasMore)")
            XCTAssertLessThanOrEqual(read, pageSize, "archived=\(archived): the update read more Done log rows than the loaded page")
            XCTAssertEqual(model.doneLogTasks.map(\.id), store.indexedDoneLogIDs(limit: pageSize).ids, "archived=\(archived)")
            XCTAssertTrue(model.doneLogHasMore, "archived=\(archived): the archived tasks are below the page")
            XCTAssertNil(model.doneLogFailure, "archived=\(archived)")
            XCTAssertEqual(model.doneLogInPlaceRefreshCount, inPlace, "archived=\(archived): over the bound, nothing in place")
            XCTAssertEqual(model.doneLogState(), fullReadState(store, rows: model.doneLogTasks.count),
                           "archived=\(archived): the state is a full read's")
        }
    }

    /// Five open tasks on Now and `logged` tasks in the Done log, finished
    /// before today; each task at an index in `families` has two logged
    /// subtasks. Returns the logged tasks' IDs in the log's order.
    private func makeFamilyLog(logged: Int, families: Set<Int>) throws -> (TaskStore, [UUID]) {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        let now = Date()
        var order: Int64 = 10_000_000
        for index in 0..<5 {
            order -= 1_024
            let open = TaskItem(title: "Open task \(index)", status: .todo, createdAt: now, manualOrder: order)
            open.listOrderVersion = TaskItem.currentListOrderVersion
            context.insert(open)
        }
        var parents: [UUID] = []
        for index in 0..<logged {
            order -= 1_024
            let completed = now.addingTimeInterval(-86_400 - Double(index + 1) * 3_600)
            let parent = TaskItem(title: "Finished task \(index)", status: .done, createdAt: now, completedAt: completed, manualOrder: order)
            parent.listOrderVersion = TaskItem.currentListOrderVersion
            parent.doneLoggedAt = completed
            context.insert(parent)
            parents.append(parent.id)
            guard families.contains(index) else { continue }
            for step in 0..<2 {
                let child = TaskItem(title: "Step \(step) of \(index)", status: .done, createdAt: now,
                                     completedAt: completed.addingTimeInterval(-Double(step + 1) * 60), parentID: parent.id)
                child.doneLoggedAt = completed
                context.insert(child)
            }
        }
        try context.save()
        return (TaskStore(container: container), parents)
    }

    /// `logged` tasks in the Done log, finished before today, and `late`
    /// tasks finished a month ago and still in the list: the daily cleanup
    /// logs them below every logged row. Returns the time the rows count from.
    private func makeCleanupLog(logged: Int, late: Int) throws -> (TaskStore, Date) {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        let now = Date()
        var order: Int64 = 10_000_000
        for index in 0..<(logged + late) {
            order -= 1_024
            let isLate = index >= logged
            let completed = isLate
                ? now.addingTimeInterval(-30 * 86_400 - Double(index) * 60)
                : now.addingTimeInterval(-86_400 - Double(index + 1) * 3_600)
            let task = TaskItem(title: isLate ? "Finished long ago \(index)" : "Finished task \(index)", status: .done,
                                createdAt: now.addingTimeInterval(-40 * 86_400), completedAt: completed, manualOrder: order)
            task.listOrderVersion = TaskItem.currentListOrderVersion
            if !isLate { task.doneLoggedAt = completed }
            context.insert(task)
        }
        try context.save()
        return (TaskStore(container: container), now)
    }

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

    /// `logged` tasks in the Done log, finished before today, and one task
    /// finished a month ago and still in the list: the daily cleanup logs it
    /// below every logged row. Returns its ID and the time the rows count from.
    private func makeDoneLog(logged: Int) throws -> (TaskStore, UUID, Date) {
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
        order -= 1_024
        let late = TaskItem(title: "Finished long ago", status: .done, createdAt: now.addingTimeInterval(-40 * 86_400),
                            completedAt: now.addingTimeInterval(-30 * 86_400), manualOrder: order)
        late.listOrderVersion = TaskItem.currentListOrderVersion
        context.insert(late)
        try context.save()
        return (TaskStore(container: container), late.id, now)
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
