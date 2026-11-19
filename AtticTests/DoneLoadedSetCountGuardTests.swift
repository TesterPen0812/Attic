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
    /// it, a subtask's), a search, failed reads on the drawn page (one, which
    /// the page's own second load recovers, and two, which show Retry) and
    /// Retry, and the changes
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
        let loadedCount = 2 * TasksPageModel.doneLogPageSize
        func row(_ id: UUID) -> TaskItem? { model.doneLogTasks.first { $0.id == id } }
        func describe(_ task: TaskItem) -> String { "\(task.id) \(task.title) \(task.priority) \(task.tags)" }
        // The list shows what a full read shows: the same rows, in order, with
        // the same content.
        func assertMatchesAFullRead(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
            let full = store.indexedDoneLogPage(limit: model.doneLogTasks.count).tasks.sorted(by: TaskStore.doneLogOrder)
            XCTAssertEqual(model.doneLogTasks.map(describe), full.map(describe), "\(label): the list is a full read's", file: file, line: line)
        }
        // On a drawn page every save is loaded twice: the model's own reload
        // after the edit, then the Done page's revision watcher. A failed
        // read is not marked as read, so the watcher's load reads the pages
        // in full (the in-place path is refused while a failure is set).
        //
        // One failed read: the model's in-place read fails and sets the
        // failure; the watcher's full read then shows the edit. No Retry.
        store.doneLogReadFailures = 1
        step("drawn page: archived edit, one failed read", inPlace: false) {
            XCTAssertTrue(model.setPriority(.medium, for: [parents[17]]).isApplied)
            XCTAssertNotNil(model.doneLogFailure, "before the page draws: the model's read failed")
        }
        XCTAssertEqual(store.doneLogReadFailures, 0, "the injected failure was used")
        XCTAssertNil(model.doneLogFailure, "the watcher's full read succeeded: no Retry")
        XCTAssertEqual(model.doneLogTasks.count, loadedCount)
        XCTAssertEqual(row(parents[17])?.priority, .medium, "the list shows the edit")
        assertMatchesAFullRead("one failed read")
        // Condition 2 (lead, 19 Nov), one named step: both reads fail (the
        // model's in-place read, then the watcher's full read). No loaded row
        // is dropped and the order holds. The row the save named shows its
        // saved value, as on the trunk: a loaded row is the task the save
        // edited, in the store's one context, so it needs no read to show it.
        // Every other row is unchanged, and Retry shows. Retry then brings
        // the list up to date in place.
        let named = parents[16]
        XCTAssertEqual(row(named)?.priority, TaskPriority.none, "the named row is loaded, with no priority yet")
        let before = model.doneLogTasks.map { (id: $0.id, text: describe($0)) }
        // The row the page draws (doneDays), not only the task it holds.
        func drawn(_ id: UUID) -> TasksListRow? { model.doneDays().flatMap(\.rows).first { $0.id == id } }
        let drawnBefore = drawn(named)?.model.priority
        store.doneLogReadFailures = 2
        step("drawn page: archived edit, both reads fail", inPlace: false) {
            XCTAssertTrue(model.setPriority(.medium, for: [named]).isApplied)
            XCTAssertNotNil(model.doneLogFailure, "before the page draws: the model's read failed")
        }
        let failed = model.doneLogTasks.map { (id: $0.id, text: describe($0)) }
        let injectedUsed = store.doneLogReadFailures == 0
        let noneDropped = Set(failed.map(\.id)).isSuperset(of: before.map(\.id))
        let sameOrder = failed.map(\.id) == before.map(\.id)
        let namedShowsSaved = row(named)?.priority == .medium
        let othersUnchanged = sameOrder && zip(before, failed).allSatisfy { old, new in old.id == named || old.text == new.text }
        let retryShows = model.doneLogFailure != nil
        let drawnAfter = drawn(named)?.model.priority
        let drawnShowsSaved = drawnAfter != nil && drawnAfter != drawnBefore
            && drawnAfter == row(named).map { model.rowModel(for: $0).model.priority }
        let countedBeforeRetry = model.doneLogInPlaceRefreshCount
        step("Retry after both reads failed", inPlace: true) { model.retryDoneLog() }
        let retryInPlace = model.doneLogInPlaceRefreshCount > countedBeforeRetry
        let fullRead = store.indexedDoneLogPage(limit: model.doneLogTasks.count).tasks.sorted(by: TaskStore.doneLogOrder)
        let retryUpdates = model.doneLogFailure == nil && retryInPlace && model.doneLogTasks.map(describe) == fullRead.map(describe)
        print("DONE_CONDITION_2 step=\"both reads fail, then Retry\" injected_used=\(injectedUsed) "
              + "loaded=\(before.count)->\(failed.count) none_dropped=\(noneDropped) same_order=\(sameOrder) "
              + "named_shows_saved=\(namedShowsSaved) drawn_shows_saved=\(drawnShowsSaved) others_unchanged=\(othersUnchanged) retry_shows=\(retryShows) "
              + "retry_in_place=\(retryInPlace) retry_updates=\(retryUpdates)")
        XCTAssertTrue(injectedUsed, "condition 2: both injected failures were used")
        XCTAssertTrue(noneDropped, "condition 2: no loaded row is dropped")
        XCTAssertTrue(sameOrder, "condition 2: the loaded rows keep their order")
        XCTAssertTrue(namedShowsSaved, "condition 2: the row the save named shows its saved value")
        XCTAssertTrue(drawnShowsSaved, "condition 2: the drawn row shows its saved value, as a fresh projection does")
        XCTAssertTrue(othersUnchanged, "condition 2: every other loaded row is unchanged")
        XCTAssertTrue(retryShows, "condition 2: both reads failed, so Retry shows")
        XCTAssertTrue(retryUpdates, "condition 2: Retry clears the failure and brings the list up to date in place")
        assertMatchesAFullRead("Retry")
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

    /// The model alone, with no page drawn and so no revision watcher to load
    /// again: a failed in-place update keeps the loaded rows and sets the
    /// failure (Retry). The row the save named shows its saved value (it is
    /// the task the save edited); the others are unchanged. Retry then brings
    /// the loaded page up to date in place.
    func testFailedInPlaceUpdateKeepsWhatLoadedAndSetsTheFailure() throws {
        let store = try makeStore(open: 5, logged: 100)
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        model.select(tab: .done)
        model.loadDoneLogIfNeeded()
        let pageSize = TasksPageModel.doneLogPageSize
        XCTAssertEqual(model.doneLogTasks.count, pageSize)
        func describe(_ task: TaskItem) -> String { "\(task.id) \(task.title) \(task.priority) \(task.tags)" }
        let edited = model.doneLogTasks[3].id
        XCTAssertEqual(model.doneLogTasks[3].priority, TaskPriority.none, "the named row has no priority yet")
        let before = model.doneLogTasks.map { (id: $0.id, text: describe($0)) }
        let inPlace = model.doneLogInPlaceRefreshCount

        store.doneLogReadFailures = 1
        XCTAssertTrue(model.setPriority(.high, for: [edited]).isApplied)
        print("GUARD_DONE_FAILED_IN_PLACE pending_failures=\(store.doneLogReadFailures) failure=\(model.doneLogFailure != nil) "
              + "in_place=\(model.doneLogInPlaceRefreshCount - inPlace) loaded=\(model.doneLogTasks.count)")
        XCTAssertEqual(store.doneLogReadFailures, 0, "the injected failure was used")
        XCTAssertNotNil(model.doneLogFailure, "a failed in-place update sets the failure (Retry)")
        let failed = model.doneLogTasks.map { (id: $0.id, text: describe($0)) }
        XCTAssertEqual(failed.map(\.id), before.map(\.id), "a failed in-place update drops no loaded row and keeps the order")
        XCTAssertEqual(model.doneLogTasks.first { $0.id == edited }?.priority, .high,
                       "the row the save named shows its saved value")
        for (old, new) in zip(before, failed) where old.id != edited {
            XCTAssertEqual(new.text, old.text, "a failed in-place update leaves every other loaded row unchanged")
        }
        XCTAssertEqual(model.doneLogInPlaceRefreshCount, inPlace, "a failed update is not counted as done")

        model.retryDoneLog()
        XCTAssertNil(model.doneLogFailure)
        XCTAssertEqual(model.doneLogInPlaceRefreshCount, inPlace + 1, "Retry updated the loaded page in place")
        XCTAssertEqual(model.doneLogTasks.first { $0.id == edited }?.priority, .high, "Retry shows the edit")
        XCTAssertEqual(model.doneLogTasks.map(\.id), store.indexedDoneLogIDs(limit: pageSize).ids)
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

        while model.doneLogHasMore, model.doneLogFailure == nil { model.loadMoreDoneLog() }
        let ids = model.doneLogTasks.map(\.id)
        XCTAssertNil(model.doneLogFailure)
        XCTAssertEqual(ids, store.indexedDoneLogIDs(limit: 200).ids, "every row of the log, in its order")
        XCTAssertEqual(ids.count, 101)
        XCTAssertEqual(ids.last, lateID)
    }

    // MARK: - Rig

    private static let size = CGSize(width: 344, height: 520)

    /// Open tasks on Now, tasks in Later, finished tasks in the Done log
    /// (finished before today) and unrelated notes.
    /// Astra r5 R1 of PR 31. A family read that fails is a failed read, on
    /// every path that loads Done log rows: what loaded is kept (no row is
    /// marked as read with a checklist it could not read), Retry shows, and
    /// once reads recover the row shows its subtasks as a full read does. On
    /// the trunk each save reads the loaded families again (source-traced in
    /// `loadDoneLogIfNeeded`, not run); the in-place update must not keep a
    /// family it failed to read across later saves.
    func testFailedFamilyReadInAnInPlaceUpdateIsAFailedRead() throws {
        let (store, parents) = try makeFamilyLog(logged: 60, families: [2])
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        model.select(tab: .done)
        model.loadDoneLogIfNeeded()
        let family = parents[2]
        XCTAssertEqual(model.doneLogTasks.count, TasksPageModel.doneLogPageSize)
        XCTAssertEqual(drawnSubtaskTotal(model, family), 2, "before: the row shows its two subtasks")
        let familyParents = store.doneFamilyParentReadCount
        store.doneFamilyBatchReadFailures = 1
        XCTAssertTrue(model.setPriority(.high, for: [family]).isApplied)
        assertFamilyReadFailure("in_place", store, model, family, familyParentsRead: store.doneFamilyParentReadCount - familyParents,
                                expectedFamilyParents: 1)
    }

    /// R1, the full read: the first page's family read fails.
    func testFailedFamilyReadInAFullReadIsAFailedRead() throws {
        let (store, parents) = try makeFamilyLog(logged: 60, families: [2])
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        model.select(tab: .done)
        let familyParents = store.doneFamilyParentReadCount
        store.doneFamilyBatchReadFailures = 1
        model.loadDoneLogIfNeeded()
        XCTAssertEqual(model.doneLogTasks.count, TasksPageModel.doneLogPageSize, "the page's rows show")
        assertFamilyReadFailure("full_read", store, model, parents[2], familyParentsRead: store.doneFamilyParentReadCount - familyParents,
                                expectedFamilyParents: TasksPageModel.doneLogPageSize)
    }

    /// R1, one more page: the next page's family read fails.
    func testFailedFamilyReadOnTheNextPageIsAFailedRead() throws {
        let (store, parents) = try makeFamilyLog(logged: 100, families: [50])
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        model.select(tab: .done)
        model.loadDoneLogIfNeeded()
        XCTAssertEqual(model.doneLogTasks.count, TasksPageModel.doneLogPageSize)
        let familyParents = store.doneFamilyParentReadCount
        store.doneFamilyBatchReadFailures = 1
        model.loadMoreDoneLog()
        assertFamilyReadFailure("next_page", store, model, parents[50], familyParentsRead: store.doneFamilyParentReadCount - familyParents,
                                expectedFamilyParents: TasksPageModel.doneLogPageSize)
    }

    /// After the injected family read failure: the failure is shown (Retry);
    /// then reads recover, an unrelated save on Now is loaded, and the row is
    /// scrolled to if it is not loaded. Its subtask total must be a full read's.
    private func assertFamilyReadFailure(_ path: String, _ store: TaskStore, _ model: TasksPageModel, _ family: UUID,
                                         familyParentsRead: Int, expectedFamilyParents: Int,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let used = store.doneFamilyBatchReadFailures == 0
        let failureShown = model.doneLogFailure != nil
        let during = drawnSubtaskTotal(model, family)
        guard let nowID = store.tasks.first(where: { $0.status == .todo })?.id else {
            return XCTFail("\(path): a task on Now", file: file, line: line)
        }
        XCTAssertTrue(model.setPriority(.low, for: [nowID]).isApplied, file: file, line: line)
        model.loadDoneLogIfNeeded()
        var pages = 0
        while !model.doneLogTasks.contains(where: { $0.id == family }), model.doneLogHasMore, pages < 3 {
            model.loadMoreDoneLog()
            pages += 1
        }
        let shown = drawnSubtaskTotal(model, family)
        let full = store.doneLogSubtasks(ofParents: [family])[family]?.count ?? 0
        print("GUARD_DONE_FAMILY_READ_FAILURE path=\(path) injected_used=\(used) family_parents_read=\(familyParentsRead) "
              + "failure_shown=\(failureShown) during=\(during.map(String.init) ?? "not_loaded") pages_after=\(pages) "
              + "after_unrelated_save=\(shown.map(String.init) ?? "not_loaded") full_read=\(full) "
              + "failure_after=\(model.doneLogFailure != nil)")
        XCTAssertTrue(used, "\(path): the injected failure reached a batch family read", file: file, line: line)
        XCTAssertEqual(familyParentsRead, expectedFamilyParents, "\(path): it was this path's family read", file: file, line: line)
        XCTAssertTrue(failureShown, "\(path): a failed family read is a failed read: Retry shows", file: file, line: line)
        XCTAssertEqual(full, 2, "\(path): a full read finds the two subtasks", file: file, line: line)
        XCTAssertEqual(shown, full, "\(path): once reads recover the row shows its subtasks, as a full read does",
                       file: file, line: line)
        XCTAssertNil(model.doneLogFailure, "\(path): the reads recovered", file: file, line: line)
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
