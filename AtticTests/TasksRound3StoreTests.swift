import SwiftData
import XCTest
@testable import Attic

/// Phase 1 fix round 3, stream S: store reliability (Astra 4, 6, 18, 19,
/// 20, 23), with failures injected where the finding is about failures.
@MainActor
final class TasksRound3StoreTests: XCTestCase {
    /// Mon 21 Sep 2026, 14:13 UTC.
    private let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000))
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private var gate: PersistenceGate!
    private var store: TaskStore!
    private var library: AtticLibrary!
    private var model: TasksPageModel!

    override func setUp() async throws {
        gate = PersistenceGate()
        store = try makeTestStore(now: { [clock] in clock.value }, persist: gate.save)
        library = AtticLibrary(tasks: store, now: { [clock] in clock.value }, persist: gate.save)
        model = makeModel(library)
    }

    override func tearDown() {
        model = nil
        library = nil
        store = nil
        gate = nil
    }

    private func makeModel(_ library: AtticLibrary) -> TasksPageModel {
        let calendar = self.calendar
        let model = TasksPageModel(library: library, services: TasksPageServices(
            now: { [clock] in clock.value },
            calendar: { calendar },
            locale: Locale(identifier: "en_GB"),
            doneHold: .seconds(3_600)
        ))
        model.toasts.holdDuration = 3_600
        return model
    }

    private func rows(_ id: UUID) throws -> [TaskItem] {
        try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
    }

    /// A physical duplicate of `task` (as a sync import can leave), older so
    /// the original stays the one shown.
    @discardableResult
    private func duplicate(_ task: TaskItem, _ edit: (TaskItem) -> Void = { _ in }) throws -> TaskItem {
        let context = ModelContext(store.container)
        let copy = TaskItem(id: task.id, title: task.title, status: task.status, priority: task.priority,
                            createdAt: task.createdAt, updatedAt: task.updatedAt.addingTimeInterval(-60),
                            completedAt: task.completedAt, manualOrder: task.manualOrder, parentID: task.parentID)
        copy.doneLoggedAt = task.doneLoggedAt
        copy.listOrderVersion = task.listOrderVersion
        copy.completedFromRaw = task.completedFromRaw
        copy.completedFromOrder = task.completedFromOrder
        edit(copy)
        context.insert(copy)
        try context.save()
        store.refresh()
        return copy
    }

    /// Finishes `id` on Monday and logs it on Wednesday (the daily cleanup).
    private func finishAndLog(_ ids: UUID...) {
        for id in ids { XCTAssertTrue(library.completeTask(id).isApplied) }
        clock.value = clock.value.addingTimeInterval(2 * 86_400)
        XCTAssertEqual(store.moveCompletedToDoneLog(before: calendar.startOfDay(for: clock.value)), ids.count
                       + ids.reduce(0) { $0 + store.doneLogSubtasks(of: $1).count })
    }

    // MARK: - Astra 4: Restore to Now's undo is one transaction

    func testUndoingARestoreFromTheDoneLogIsOneSaveAndAFailureChangesNothing() throws {
        let parent = try XCTUnwrap(store.create(title: "Invoice"))
        let child = try XCTUnwrap(store.create(title: "Send", parentID: parent.id))
        try duplicate(parent)
        finishAndLog(parent.id)
        XCTAssertNil(store.task(withID: parent.id))
        XCTAssertTrue(library.restoreToNow(parent.id).isApplied)
        XCTAssertEqual(store.task(withID: parent.id)?.status, .todo)
        XCTAssertNotNil(store.task(withID: child.id), "the family came back")

        // The undo fails to save: nothing changes and the step stays.
        gate.shouldFail = true
        let saves = gate.saveCount
        let outcome = library.undo(in: .tasks)
        XCTAssertEqual(outcome.failure?.canRetry, true)
        XCTAssertEqual(gate.saveCount, saves)
        XCTAssertEqual(library.undo.undoName(in: .tasks), "Restore Task", "the step is still there to retry")
        XCTAssertEqual(store.task(withID: parent.id)?.status, .todo, "the task is entirely as before the undo")
        XCTAssertTrue(try rows(parent.id).allSatisfy { $0.status == .todo && $0.doneLoggedAt == nil })
        XCTAssertTrue(try rows(child.id).allSatisfy { $0.doneLoggedAt == nil })

        // Retry: state and log placement come back together, in one save.
        gate.shouldFail = false
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(gate.saveCount, saves + 1, "one save for the state and the log")
        XCTAssertNil(store.task(withID: parent.id), "back in the Done log")
        XCTAssertTrue(try rows(parent.id).allSatisfy { $0.status == .done && $0.doneLoggedAt != nil }, "every replica")
        XCTAssertTrue(try rows(child.id).allSatisfy { $0.doneLoggedAt != nil }, "with its family")
        XCTAssertEqual(store.listedTask(withID: parent.id)?.status, .done)
    }

    func testUndoingARestoreOfTodaysDoneTaskKeepsItInCompletedToday() throws {
        let task = try XCTUnwrap(store.create(title: "Today"))
        XCTAssertTrue(library.completeTask(task.id).isApplied)
        XCTAssertTrue(library.restoreToNow(task.id).isApplied)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(store.task(withID: task.id)?.status, .done)
        XCTAssertNil(store.task(withID: task.id)?.doneLoggedAt, "it was never in the log: it stays in today's list")
    }

    // MARK: - Astra 6: outcomes for the surface that asked

    func testMutationsReturnOutcomesWithTheStoresReasonWhateverFamilyOwnsIt() throws {
        let parent = try XCTUnwrap(store.create(title: "Trip"))
        let sub = try XCTUnwrap(store.create(title: "Pack", parentID: parent.id))
        XCTAssertEqual(model.toggleSubtask(sub.id), .applied)

        // A failed save of a subtask: the store files it under the family
        // (the old family panel), the outcome still carries it.
        gate.shouldFail = true
        let failed = model.toggleSubtask(sub.id)
        XCTAssertEqual(store.lastErrorOwnerID, parent.id, "the store's notice belongs to the family")
        XCTAssertEqual(failed.failure?.message, store.lastErrorMessage, "the quick look gets the reason itself")
        XCTAssertEqual(failed.failure?.canRetry, true)
        XCTAssertEqual(store.task(withID: sub.id)?.status, .done, "nothing changed")

        // Delete: nothing moves before the save.
        model.selectOnly(parent.id)
        XCTAssertFalse(model.delete([parent.id]).isApplied)
        XCTAssertEqual(model.selection, [parent.id], "selection is kept")
        XCTAssertNil(model.toasts.current, "no toast for a delete that did not happen")
        XCTAssertNotNil(store.task(withID: parent.id))

        // Reorder and bulk edits.
        gate.shouldFail = false
        let other = try XCTUnwrap(store.create(title: "Other"))
        gate.shouldFail = true
        XCTAssertFalse(model.move(other.id, toGroupIndex: 1).isApplied)
        XCTAssertFalse(library.updateTasks([parent.id, other.id], priority: .high).isApplied)
        gate.shouldFail = false

        // A refusal can't succeed by retrying.
        XCTAssertTrue(library.updateTask(sub.id, status: .todo).isApplied, "a subtask of an open task reopens")
        XCTAssertTrue(library.updateTask(sub.id, status: .todo).isApplied, "nothing to change is applied")
        let blocked = library.updateTask(parent.id, status: .done)
        XCTAssertEqual(blocked.failure?.message, "Finish the subtasks before completing this task.")
        XCTAssertEqual(blocked.failure?.canRetry, false)

        // A task that is gone: not retryable.
        XCTAssertTrue(model.delete([other.id]).isApplied)
        XCTAssertEqual(library.updateTask(other.id, title: "x"), .failed(.taskGone))
        XCTAssertEqual(library.lastFailure, .taskGone)
    }

    // MARK: - Astra 20: "back to what it was" is durable

    func testReopeningRestoresTheRecordedStateAcrossRelaunchesAndHistory() throws {
        let later = try XCTUnwrap(store.create(title: "Idea", status: .backlog))
        let working = try XCTUnwrap(store.create(title: "Draft", status: .inProgress))
        XCTAssertEqual(model.toggleDone(later.id), .applied)
        XCTAssertEqual(model.toggleDone(working.id), .applied)
        XCTAssertEqual(store.task(withID: later.id)?.completedFromRaw, "backlog", "recorded in the save that finished it")
        XCTAssertTrue(try rows(working.id).allSatisfy { $0.completedFromRaw == TaskStatus.inProgress.rawValue })
        // Unrelated steps, then a relaunch: nothing in memory survives.
        library.undo.clear(.tasks)
        let relaunched = TaskStore(container: store.container, now: { [clock] in clock.value }, persist: gate.save)
        let relaunchedModel = makeModel(AtticLibrary(tasks: relaunched, now: { [clock] in clock.value }, persist: gate.save))
        XCTAssertTrue(relaunchedModel.toggleDone(later.id).isApplied)
        XCTAssertTrue(relaunchedModel.toggleDone(working.id).isApplied)
        XCTAssertEqual(relaunched.task(withID: later.id)?.status, .backlog)
        XCTAssertEqual(relaunched.task(withID: working.id)?.status, .inProgress)
        XCTAssertNil(relaunched.task(withID: working.id)?.completedFromRaw, "cleared in the save that reopened it")
    }

    func testAFailedReopenKeepsTheOriginUntilAReopenSucceeds() throws {
        let task = try XCTUnwrap(store.create(title: "Draft", status: .inProgress))
        XCTAssertTrue(model.toggleDone(task.id).isApplied)
        gate.shouldFail = true
        XCTAssertFalse(model.toggleDone(task.id).isApplied)
        XCTAssertEqual(store.task(withID: task.id)?.status, .done)
        XCTAssertEqual(store.task(withID: task.id)?.completedFromRaw, TaskStatus.inProgress.rawValue, "still known")
        gate.shouldFail = false
        XCTAssertTrue(model.toggleDone(task.id).isApplied)
        XCTAssertEqual(store.task(withID: task.id)?.status, .inProgress)
    }

    func testReopeningAMainTaskReopensOnlyTheSubtasksFinishedWithIt() throws {
        let parent = try XCTUnwrap(store.create(title: "Trip"))
        let packed = try XCTUnwrap(store.create(title: "Pack", parentID: parent.id))
        let booked = try XCTUnwrap(store.create(title: "Book", status: .inProgress, parentID: parent.id))
        let tickets = try XCTUnwrap(store.create(title: "Tickets", parentID: parent.id))
        XCTAssertTrue(library.updateTask(packed.id, status: .done).isApplied)   // finished before, on its own
        clock.value = clock.value.addingTimeInterval(60)
        XCTAssertTrue(model.toggleDone(parent.id).isApplied)                     // finishes Book and Tickets with it
        XCTAssertEqual(store.task(withID: booked.id)?.completedAt, store.task(withID: parent.id)?.completedAt,
                       "one completion time for the family")
        // Tickets changed since (finished again elsewhere, a later sync).
        let context = ModelContext(store.container)
        let ticketsID = tickets.id
        for row in try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == ticketsID })) {
            row.completedAt = clock.value.addingTimeInterval(30)
            row.completedFromRaw = nil
            row.updatedAt = clock.value.addingTimeInterval(30)
        }
        try context.save()
        store.refresh()

        XCTAssertTrue(model.toggleDone(parent.id).isApplied)
        XCTAssertEqual(store.task(withID: parent.id)?.status, .todo, "back to what it was")
        XCTAssertEqual(store.task(withID: booked.id)?.status, .inProgress, "finished with it: back as it was")
        XCTAssertEqual(store.task(withID: packed.id)?.status, .done, "finished before: stays finished")
        XCTAssertEqual(store.task(withID: tickets.id)?.status, .done, "changed since: keeps its state")
    }

    func testReopeningWithTheCircleRightAfterFinishingRestoresSubtasksAndPlace() throws {
        let other = try XCTUnwrap(store.create(title: "Other"))
        let parent = try XCTUnwrap(store.create(title: "Trip"))
        let booked = try XCTUnwrap(store.create(title: "Book", status: .inProgress, parentID: parent.id))
        let order = store.orderedTasks(for: .todo).map(\.id)
        XCTAssertTrue(model.toggleDone(parent.id).isApplied)
        XCTAssertEqual(store.task(withID: booked.id)?.status, .done)
        library.undo.clear(.tasks)   // not the latest step any more: the same result
        XCTAssertTrue(model.toggleDone(parent.id).isApplied)
        XCTAssertEqual(store.task(withID: booked.id)?.status, .inProgress, "its subtask comes back as it was")
        XCTAssertEqual(store.orderedTasks(for: .todo).map(\.id), order, "and the task keeps its place")
        _ = other
    }

    func testReopeningADoneLogTaskBringsItsFamilyBackAndUndoLogsItAgainInOneSave() throws {
        let parent = try XCTUnwrap(store.create(title: "Report", status: .inProgress))
        let child = try XCTUnwrap(store.create(title: "Charts", parentID: parent.id))
        finishAndLog(parent.id)
        XCTAssertTrue(model.toggleDone(parent.id).isApplied)
        XCTAssertEqual(store.task(withID: parent.id)?.status, .inProgress, "back to what it was, not just to Now")
        XCTAssertEqual(store.task(withID: child.id)?.status, .todo)
        let saves = gate.saveCount
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(gate.saveCount, saves + 1)
        XCTAssertNil(store.task(withID: parent.id), "back in the Done log")
        XCTAssertTrue(try rows(child.id).allSatisfy { $0.status == .done && $0.doneLoggedAt != nil })
    }

    func testReopeningSeveralTasksIsOneStepAndOneSave() throws {
        let a = try XCTUnwrap(store.create(title: "A", status: .inProgress))
        let b = try XCTUnwrap(store.create(title: "B", status: .backlog))
        XCTAssertTrue(model.toggleDone([a.id, b.id]).isApplied)
        let steps = library.undo.undoCount(in: .tasks)
        let saves = gate.saveCount
        XCTAssertTrue(model.toggleDone([a.id, b.id]).isApplied)
        XCTAssertEqual(gate.saveCount, saves + 1)
        XCTAssertEqual(library.undo.undoCount(in: .tasks), steps + 1)
        XCTAssertEqual(store.task(withID: a.id)?.status, .inProgress)
        XCTAssertEqual(store.task(withID: b.id)?.status, .backlog)
    }

    // MARK: - Astra 18: Done search is decided by the replica shown

    func testDoneSearchValidatesTheCanonicalWinnerAndOrdersByItsCompletion() throws {
        let renamed = try XCTUnwrap(store.create(title: "Invoice March"))
        let other = try XCTUnwrap(store.create(title: "Invoice April"))
        let moved = try XCTUnwrap(store.create(title: "Invoice parts"))
        let host = try XCTUnwrap(store.create(title: "Host"))
        finishAndLog(renamed.id, other.id, moved.id, host.id)
        // An older copy still has the old matching title; the shown copy
        // was renamed. Another older copy claims to be a main task while the
        // shown one became a subtask. A stale copy carries a newer
        // completion time than the shown one.
        let context = ModelContext(store.container)
        /// Changes the shown (newest) copy and keeps it the newest.
        func editShown(_ id: UUID, _ change: (TaskItem) -> Void) throws {
            let rows = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
            let shown = try XCTUnwrap(rows.max { $0.updatedAt < $1.updatedAt })
            change(shown)
            shown.updatedAt = clock.value
        }
        try duplicate(try XCTUnwrap(store.listedTask(withID: renamed.id)))
        try duplicate(try XCTUnwrap(store.listedTask(withID: moved.id)))
        try duplicate(try XCTUnwrap(store.listedTask(withID: other.id))) { $0.completedAt = self.clock.value.addingTimeInterval(3_600) }
        let hostID = host.id
        try editShown(renamed.id) { $0.title = "Receipt" }
        try editShown(moved.id) { $0.parentID = hostID }
        try editShown(other.id) { $0.completedAt = self.clock.value.addingTimeInterval(-10 * 86_400) }
        try context.save()
        store.refresh()

        let page = store.doneLogPage(limit: 10, matching: "invoice")
        XCTAssertEqual(page.tasks.map(\.id), [other.id], "neither the renamed task nor the one now a subtask")
        XCTAssertNil(page.failure)
        XCTAssertEqual(store.doneLogPage(limit: 10, matching: "receipt").tasks.map(\.id), [renamed.id])
        // Ordered by the shown copy's completion: April (early) comes last.
        let all = store.doneLogPage(limit: 10).tasks
        XCTAssertEqual(all.last?.id, other.id)
        XCTAssertEqual(all.map(\.completedAt), all.map(\.completedAt).sorted { ($0 ?? .distantPast) > ($1 ?? .distantPast) })
    }

    func testAFailedDoneLogReadKeepsWhatLoadedAndOffersRetry() throws {
        var ids: [UUID] = []
        for index in 0..<(TasksPageModel.doneLogPageSize + 5) {
            ids.append(try XCTUnwrap(store.create(title: "Finished \(index)")).id)
        }
        XCTAssertTrue(library.updateTasks(ids, status: .done).isApplied)
        clock.value = clock.value.addingTimeInterval(2 * 86_400)
        XCTAssertEqual(store.moveCompletedToDoneLog(before: calendar.startOfDay(for: clock.value)), ids.count)
        model.select(tab: .done)
        model.loadDoneLogIfNeeded()
        XCTAssertEqual(model.doneLogTasks.count, TasksPageModel.doneLogPageSize)
        XCTAssertTrue(model.doneLogHasMore)

        store.doneLogReadFailures = 1
        model.loadMoreDoneLog()
        XCTAssertEqual(model.doneLogTasks.count, TasksPageModel.doneLogPageSize, "what loaded stays")
        XCTAssertNotNil(model.doneLogFailure, "\"Couldn't load more\", not \"no more\"")
        XCTAssertTrue(model.doneLogHasMore)
        model.loadMoreDoneLog()
        XCTAssertEqual(model.doneLogTasks.count, TasksPageModel.doneLogPageSize, "no retry loop while it shows the failure")

        model.retryDoneLog()
        XCTAssertNil(model.doneLogFailure)
        XCTAssertEqual(model.doneLogTasks.count, ids.count)
        XCTAssertFalse(model.doneLogHasMore)

        // A failed first page for a new search: not remembered as loaded.
        store.doneLogReadFailures = 1
        model.doneSearch = "Finished 1"
        model.loadDoneLogIfNeeded()
        XCTAssertNotNil(model.doneLogFailure)
        model.retryDoneLog()
        XCTAssertNil(model.doneLogFailure)
        XCTAssertTrue(model.doneLogTasks.allSatisfy { $0.title.hasPrefix("Finished 1") })
        XCTAssertFalse(model.doneLogTasks.isEmpty)
    }

    // MARK: - Astra 19: archived rows show their archived family

    func testADoneLogRowShowsItsChecklistFromItsArchivedFamily() throws {
        let parent = try XCTUnwrap(store.create(title: "Trip"))
        _ = try XCTUnwrap(store.create(title: "Pack", parentID: parent.id))
        let booked = try XCTUnwrap(store.create(title: "Book", parentID: parent.id))
        XCTAssertTrue(library.updateTask(booked.id, status: .done).isApplied)
        XCTAssertEqual(model.rowModel(for: try XCTUnwrap(store.task(withID: parent.id))).model.subtasks?.total, 2)
        finishAndLog(parent.id)
        model.select(tab: .done)
        model.loadDoneLogIfNeeded()
        let row = try XCTUnwrap(model.doneDays().flatMap(\.rows).first { $0.id == parent.id })
        XCTAssertEqual(row.model.subtasks?.total, 2, "the checklist stays with the task in the log")
        XCTAssertEqual(row.model.subtasks?.done, 2)
        XCTAssertEqual(store.doneLogSubtasks(ofParents: [parent.id])[parent.id]?.count, 2, "read with the page")
    }

    // MARK: - Astra 23: the toast reports what its action did

    func testTheToastStaysWithARetryableReasonWhenItsUndoFails() throws {
        let task = try XCTUnwrap(store.create(title: "Milk"))
        XCTAssertTrue(model.delete([task.id]).isApplied)
        let toasts = model.toasts
        XCTAssertNotNil(toasts.current)
        gate.shouldFail = true
        XCTAssertFalse(toasts.performAction().isApplied)
        XCTAssertEqual(toasts.current?.isFailure, true, "the toast stays, saying what went wrong")
        XCTAssertEqual(toasts.current?.actionTitle, "Retry")
        XCTAssertFalse(toasts.hasPendingDismissalForTesting, "a problem does not time out")
        XCTAssertNil(store.errorNotice, "said once, where Undo was pressed")
        gate.shouldFail = false
        XCTAssertTrue(toasts.performAction().isApplied)
        XCTAssertNil(toasts.current, "gone once the undo applied")
        XCTAssertNotNil(store.task(withID: task.id))
    }

    func testKeyboardAndVoiceOverHoldTheToastOpen() {
        let toasts = PanelToastCenter()
        toasts.holdDuration = 3_600
        toasts.show("Task deleted") {}
        XCTAssertTrue(toasts.hasPendingDismissalForTesting)
        toasts.hold(.keyboard, true)
        XCTAssertFalse(toasts.hasPendingDismissalForTesting, "keyboard focus on its button holds it")
        toasts.hold(.accessibility, true)
        toasts.hold(.keyboard, false)
        XCTAssertFalse(toasts.hasPendingDismissalForTesting, "VoiceOver still on it")
        toasts.hold(.accessibility, false)
        XCTAssertTrue(toasts.hasPendingDismissalForTesting, "expires once nothing holds it")
    }

    func testModelUndoDismissesTheToastOnlyWhenItApplied() throws {
        let task = try XCTUnwrap(store.create(title: "Milk"))
        XCTAssertTrue(model.delete([task.id]).isApplied)
        gate.shouldFail = true
        XCTAssertFalse(model.undo().isApplied)
        XCTAssertNotNil(model.toasts.current, "⌘Z failed: the toast (and its step) stay")
        gate.shouldFail = false
        XCTAssertTrue(model.undo().isApplied)
        XCTAssertNil(model.toasts.current)
    }
}

/// Astra 7: reveal and reset follow the panel controller's explicit show
/// and hide, never window occlusion.
@MainActor
final class PanelLifecycleTests: XCTestCase {
    func testRevealAndHideAreTheControllersNotTheWindowsOcclusion() throws {
        let suite = "PanelLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let state = PanelUIState()
        let controller = AtticPanelController(
            store: store, noteStore: notes,
            canvasSession: CanvasSession(store: CanvasStore(container: container)),
            noteDraft: NoteDraftController(noteStore: notes),
            settings: AppSettings(defaults: defaults), uiState: state
        )
        let screen = try XCTUnwrap(NSScreen.main)
        XCTAssertTrue(controller.show(on: screen, corner: .topRight))
        XCTAssertEqual(state.revealCount, 1, "a reveal from hidden")
        XCTAssertTrue(controller.show(on: screen, corner: .topRight))
        XCTAssertEqual(state.revealCount, 1, "showing an open panel again is not a reveal")

        // Covered by another window, uncovered, a Space change: the window's
        // occlusion changes, the panel stays open.
        for window in NSApp.windows where window.isVisible {
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(state.revealCount, 1)
        XCTAssertEqual(state.hideCount, 0)

        var hidden = false
        _ = controller.requestHide { hidden = $0 == .hidden }
        let deadline = Date().addingTimeInterval(3)
        while !hidden, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(hidden)
        XCTAssertEqual(state.hideCount, 1, "a real close")
        XCTAssertTrue(controller.show(on: screen, corner: .topRight))
        XCTAssertEqual(state.revealCount, 2, "and a real reopen")
        _ = controller.requestHide { _ in }
    }

    /// What the page does with those events: a reveal opens on Now; an
    /// open panel that was only covered keeps its tab and selection.
    func testTheTasksPageResetsOnRevealOnly() throws {
        let store = try makeTestStore()
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        let id = try XCTUnwrap(store.create(title: "Idea", status: .backlog)).id
        model.select(tab: .backlog)
        model.selectOnly(id)
        // Covering and uncovering sends nothing to the page any more.
        XCTAssertEqual(model.tab, .backlog)
        XCTAssertEqual(model.selection, [id])
        model.pageDidHide()
        model.resetForReveal()
        XCTAssertEqual(model.tab, .now, "a real reopen starts on Now")
        XCTAssertEqual(model.selection, [])
    }
}

/// Astra 23: ⌘Z that nothing in the panel used reaches the page's history
/// through the window (the toast no longer owns the shortcut); a text view
/// keeps its own.
@MainActor
final class PanelUndoKeyTests: XCTestCase {
    func testUnhandledCommandZReachesTheHistoryButNeverPastATextView() throws {
        let panel = AtticPanel(contentRect: CGRect(x: 0, y: 0, width: 320, height: 520), styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: true)
        var calls: [Bool] = []
        panel.onUnhandledUndo = { calls.append($0) }
        func key(_ modifiers: NSEvent.ModifierFlags, _ characters: String = "z") -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: panel.windowNumber,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 6)!
        }
        panel.keyDown(with: key(.command))
        panel.keyDown(with: key([.command, .shift], "Z"))
        panel.keyDown(with: key([.command, .option]))
        XCTAssertEqual(calls, [false, true], "⌘Z undoes, ⇧⌘Z redoes, nothing else")
        let field = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        panel.contentView?.addSubview(field)
        panel.makeFirstResponder(field)
        if panel.firstResponder === field {
            panel.keyDown(with: key(.command))
            XCTAssertEqual(calls.count, 2, "a text view's own undo comes first")
        }
    }

    /// The ⌘Z crash (CU review, 2026-09-27): a field torn down with typing
    /// registrations left in the window's undo manager. Before any ⌘Z is
    /// dispatched, the panel removes the registrations of text views that
    /// have left it; a field still in the panel keeps its own.
    func testUndoRegistrationsOfATextViewThatLeftThePanelAreRemovedBeforeCommandZ() throws {
        let panel = AtticPanel(contentRect: CGRect(x: 0, y: 0, width: 320, height: 520), styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: true)
        let manager = try XCTUnwrap(panel.undoManager)
        let staying = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        let leaving = NSTextView(frame: CGRect(x: 0, y: 30, width: 100, height: 20))
        panel.contentView?.addSubview(staying)
        panel.contentView?.addSubview(leaving)
        var undone: [String] = []
        XCTAssertTrue(panel.makeFirstResponder(staying))
        manager.registerUndo(withTarget: staying) { _ in undone.append("staying") }
        XCTAssertTrue(panel.makeFirstResponder(leaving))
        manager.registerUndo(withTarget: leaving) { _ in undone.append("leaving") }
        let storage = try XCTUnwrap(leaving.textStorage)
        manager.registerUndo(withTarget: storage) { _ in undone.append("leaving storage") }
        XCTAssertTrue(panel.makeFirstResponder(nil))
        leaving.removeFromSuperview()

        let commandZ = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                      windowNumber: panel.windowNumber, context: nil, characters: "z",
                                                      charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        _ = panel.performKeyEquivalent(with: commandZ)
        XCTAssertTrue(manager.canUndo, "the field still in the panel keeps its registration")
        manager.undo()
        XCTAssertEqual(undone, ["staying"], "nothing registered by the field that left is ever invoked")
        XCTAssertFalse(manager.canUndo)
    }
}
