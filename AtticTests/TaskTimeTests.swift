import SwiftData
import XCTest
@testable import Attic

@MainActor
final class TaskTimeTests: XCTestCase {
    private let calendar = CalendarMonthMath.calendar(timeZone: TimeZone(identifier: "Europe/London")!)
    private var today: DueDay { DueDay(year: 2026, month: 10, day: 30)! }
    private var noon: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12))! }

    func testTasksTitleLoneClockKeepsExistingDateAndFillsOnlyAnEmptyDate() throws {
        for date in [DueDay(year: 2026, month: 11, day: 2), nil] {
            let store = try makeTestStore()
            let library = AtticLibrary(tasks: store)
            let task = try XCTUnwrap(store.commit([TaskDraft(title: "Call Bob", dueDay: date)])?.first)
            let model = TasksPageModel(library: library, services: TasksPageServices(
                now: { self.noon }, calendar: { self.calendar }, locale: Locale(identifier: "en_GB")))
            model.beginEditingTitle(task.id)
            model.editingTitle = "Call Bob 4pm"
            XCTAssertTrue(model.commitTitle())
            XCTAssertEqual(task.title, "Call Bob")
            XCTAssertEqual(task.dueDay, date ?? today)
            XCTAssertEqual(task.dueTimeMinutes, 960)
            XCTAssertTrue(library.undo(in: .tasks).isApplied)
            XCTAssertEqual(task.dueDay, date)
            XCTAssertNil(task.dueTimeMinutes)
            XCTAssertTrue(library.redo(in: .tasks).isApplied)
            XCTAssertEqual(task.dueDay, date ?? today)
            XCTAssertEqual(task.dueTimeMinutes, 960)
        }
    }

    func testTaskPageTitleLoneClockKeepsExistingDateAndFillsOnlyAnEmptyDate() throws {
        for date in [DueDay(year: 2026, month: 11, day: 2), nil] {
            let store = try makeTestStore()
            let library = AtticLibrary(tasks: store)
            let task = try XCTUnwrap(store.commit([TaskDraft(title: "Call Bob", dueDay: date)])?.first)
            let parser = TaskTextParser(calendar: calendar, now: { self.noon })
            let page = TaskNotePageModel(taskID: task.id, store: store, library: library,
                history: WorkspaceHistory(route: library.undo, historyID: .tasks),
                defaults: nil, parser: parser, calendar: calendar)
            page.beginEditingTitle()
            page.titleEdit.text = "Call Bob 4pm"
            XCTAssertTrue(page.commitTitle())
            XCTAssertEqual(task.title, "Call Bob")
            XCTAssertEqual(task.dueDay, date ?? today)
            XCTAssertEqual(task.dueTimeMinutes, 960)
            XCTAssertTrue(library.undo(in: .tasks).isApplied)
            XCTAssertEqual(task.dueDay, date)
            XCTAssertNil(task.dueTimeMinutes)
            XCTAssertTrue(library.redo(in: .tasks).isApplied)
            XCTAssertEqual(task.dueDay, date ?? today)
            XCTAssertEqual(task.dueTimeMinutes, 960)
        }
    }

    func testSetChangeAndClearTimeUndoRedoAndReopen() throws {
        let store = try makeTestStore()
        let library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.commit([TaskDraft(title: "Call", dueDay: today)])?.first)
        for (before, after) in [(nil, 960), (960, 990), (990, nil)] as [(Int?, Int?)] {
            XCTAssertTrue(library.updateTask(task.id, dueTimeMinutes: .some(after)).isApplied)
            XCTAssertEqual(task.dueTimeMinutes, after)
            XCTAssertTrue(library.undo(in: .tasks).isApplied)
            XCTAssertEqual(task.dueTimeMinutes, before)
            XCTAssertTrue(library.redo(in: .tasks).isApplied)
            XCTAssertEqual(task.dueTimeMinutes, after)
        }
        XCTAssertTrue(library.updateListedTasks([task.id], dueTimeMinutes: .some(0)).isApplied)
        let reopened = try XCTUnwrap(ModelContext(store.container).fetch(FetchDescriptor<TaskItem>()).first)
        XCTAssertEqual(reopened.dueTimeMinutes, 0)
        XCTAssertEqual(reopened.dueDay, today)
    }

    func testClearingDateAndMovingToLaterClearTimeAndUndoRestoresBoth() throws {
        let store = try makeTestStore()
        let library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.commit([TaskDraft(title: "Call", dueDay: today, dueTimeMinutes: 990)])?.first)
        XCTAssertTrue(library.updateTaskFields([task.id], dueDay: .some(nil)).isApplied)
        XCTAssertNil(task.dueDay); XCTAssertNil(task.dueTimeMinutes)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(task.dueDay, today); XCTAssertEqual(task.dueTimeMinutes, 990)
        XCTAssertTrue(library.updateTask(task.id, status: .backlog).isApplied)
        XCTAssertNil(task.dueDay); XCTAssertNil(task.dueTimeMinutes)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(task.dueDay, today); XCTAssertEqual(task.dueTimeMinutes, 990)
        task.dueDay = nil
        XCTAssertNil(task.dueTimeMinutes)
        task.dueTimeMinutes = 60
        XCTAssertNil(task.dueTimeMinutes, "a time cannot exist without a date")
    }

    func testDatingLaterMovesToNowAndMovingBackClearsTheWholeScheduleWithUndo() throws {
        let store = try makeTestStore()
        let library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.create(title: "Later call", status: .backlog))
        XCTAssertTrue(library.updateTask(task.id, dueDay: .some(today), dueTimeMinutes: .some(990)).isApplied)
        XCTAssertEqual(task.status, .todo)
        XCTAssertEqual(task.dueDay, today)
        XCTAssertEqual(task.dueTimeMinutes, 990)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(task.status, .backlog)
        XCTAssertNil(task.dueDay)
        XCTAssertNil(task.dueTimeMinutesRaw)
        XCTAssertTrue(library.redo(in: .tasks).isApplied)
        XCTAssertTrue(library.updateTask(task.id, status: .backlog).isApplied)
        XCTAssertEqual(task.status, .backlog)
        XCTAssertNil(task.dueDay)
        XCTAssertNil(task.dueTimeMinutesRaw)
        let reopened = try XCTUnwrap(ModelContext(store.container).fetch(FetchDescriptor<TaskItem>()).first)
        XCTAssertEqual(reopened.status, .backlog)
        XCTAssertNil(reopened.dueDay)
        XCTAssertNil(reopened.dueTimeMinutesRaw)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(task.status, .todo)
        XCTAssertEqual(task.dueDay, today)
        XCTAssertEqual(task.dueTimeMinutes, 990)
    }

    /// Physical copies deliberately disagree, including an orphan raw clock
    /// from an import. Later must clear the entire schedule on all of them.
    func testMovingToLaterClearsEveryReplicaScheduleWhateverTheShownCopyHolds() throws {
        for shownDated in [false, true] {
            for initialStatus in [TaskStatus.todo, .backlog] {
                let store = try makeTestStore()
                let id = try insertScheduleCopies(in: store, shownDated: shownDated, status: initialStatus)
                let library = AtticLibrary(tasks: store)
                XCTAssertEqual(store.task(withID: id)?.dueDay != nil, shownDated)
                XCTAssertTrue(library.updateTask(id, status: .backlog).isApplied)
                let copies = try scheduleCopies(id, in: store)
                XCTAssertEqual(copies.count, 3)
                XCTAssertTrue(copies.allSatisfy { $0.status == .backlog && $0.dueDayRaw == nil && $0.dueTimeMinutesRaw == nil })
            }
        }
    }

    func testDatingATimedImportedLaterTaskKeepsTimeAndUndoRestoresBoth() throws {
        let store = try makeTestStore()
        let id = try insertScheduleCopies(in: store, shownDated: true, status: .backlog, count: 1)
        let library = AtticLibrary(tasks: store)
        let tomorrow = DueDay(year: 2026, month: 10, day: 31)!
        XCTAssertTrue(library.updateTask(id, dueDay: .some(tomorrow)).isApplied)
        let task = try XCTUnwrap(store.task(withID: id))
        XCTAssertEqual(task.status, .todo)
        XCTAssertEqual(task.dueDay, tomorrow)
        XCTAssertEqual(task.dueTimeMinutes, 990)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(task.status, .backlog)
        XCTAssertEqual(task.dueDay, today)
        XCTAssertEqual(task.dueTimeMinutes, 990)
        XCTAssertFalse(library.undo(in: .tasks).isApplied, "one edit, one Undo step")
        XCTAssertTrue(library.redo(in: .tasks).isApplied)
        XCTAssertEqual(task.dueDay, tomorrow)
        XCTAssertEqual(task.dueTimeMinutes, 990)
    }

    func testEditingATimedImportedLaterTaskStoresItInNowWithoutChangingItsScheduleOrOrder() throws {
        let store = try makeTestStore()
        let id = try insertScheduleCopies(in: store, shownDated: true, status: .backlog, count: 1)
        let task = try XCTUnwrap(store.task(withID: id))
        let order = task.manualOrder
        XCTAssertTrue(AtticLibrary(tasks: store).updateTask(id, title: "Renamed").isApplied)
        XCTAssertEqual(task.status, .todo)
        XCTAssertEqual(task.dueDay, today)
        XCTAssertEqual(task.dueTimeMinutes, 990)
        XCTAssertEqual(task.manualOrder, order)
    }

    func testStandaloneIntoLaterClearsEveryReplicaDateAndTimeAndUndoRestoresParent() throws {
        let store = try makeTestStore()
        let parent = try XCTUnwrap(store.create(title: "Later parent", status: .backlog))
        let id = try insertScheduleCopies(in: store, shownDated: false, status: .todo, parentID: parent.id)
        let library = AtticLibrary(tasks: store)
        XCTAssertTrue(library.moveSubtask(id, toTask: nil).isApplied)
        let copies = try scheduleCopies(id, in: store)
        XCTAssertEqual(copies.count, 3)
        XCTAssertTrue(copies.allSatisfy {
            $0.parentID == nil && $0.status == .backlog && $0.dueDayRaw == nil && $0.dueTimeMinutesRaw == nil
        })
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertTrue(try scheduleCopies(id, in: store).allSatisfy { $0.parentID == parent.id && $0.status == .todo })
        XCTAssertFalse(library.undo(in: .tasks).isApplied, "promotion is one Undo step")
        XCTAssertTrue(library.redo(in: .tasks).isApplied)
        XCTAssertTrue(try scheduleCopies(id, in: store).allSatisfy {
            $0.parentID == nil && $0.status == .backlog && $0.dueDayRaw == nil && $0.dueTimeMinutesRaw == nil
        })
    }

    func testLaterMoveUndoRestoresDateAndTimeOnEveryAgreeingReplica() throws {
        let store = try makeTestStore()
        let id = try insertScheduleCopies(in: store, shownDated: true, status: .todo, count: 1)
        let context = ModelContext(store.container)
        let copy = TaskItem(id: id, title: "Scheduled", createdAt: noon, updatedAt: noon.addingTimeInterval(-60))
        copy.dueDay = today; copy.dueTimeMinutes = 990
        copy.manualOrder = 123; copy.listOrderVersion = TaskItem.currentListOrderVersion
        context.insert(copy); try context.save(); store.refresh()
        let library = AtticLibrary(tasks: store)
        XCTAssertTrue(library.updateTask(id, status: .backlog).isApplied)
        XCTAssertTrue(try scheduleCopies(id, in: store).allSatisfy { $0.dueDayRaw == nil && $0.dueTimeMinutesRaw == nil })
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertTrue(try scheduleCopies(id, in: store).allSatisfy { $0.status == .todo && $0.dueDay == today && $0.dueTimeMinutes == 990 })
        XCTAssertFalse(library.undo(in: .tasks).isApplied, "date, time and status restore together")
    }

    func testFailedLaterScheduleChangesRollBackEveryReplicaAndRegisterNoUndo() throws {
        for standalone in [false, true] {
            var fails = false
            let store = try makeTestStore(persist: { context in
                if fails { throw CocoaError(.fileWriteUnknown) }
                try context.save()
            })
            let parent = try XCTUnwrap(store.create(title: "Later parent", status: .backlog))
            let id = try insertScheduleCopies(in: store, shownDated: false, status: .todo,
                                              parentID: standalone ? parent.id : nil)
            let before = try scheduleCopies(id, in: store).map(TaskEditableState.init)
            let shown = try XCTUnwrap(store.task(withID: id))
            let shownBefore = try WorkspaceModelFields.read(shown)
            let library = AtticLibrary(tasks: store)
            fails = true
            let outcome = standalone ? library.moveSubtask(id, toTask: nil) : library.updateTask(id, status: .backlog)
            XCTAssertFalse(outcome.isApplied)
            XCTAssertEqual(try WorkspaceModelFields.read(shown), shownBefore)
            fails = false
            XCTAssertEqual(try scheduleCopies(id, in: store).map(TaskEditableState.init), before)
            XCTAssertFalse(library.undo(in: .tasks).isApplied)
        }
    }

    private func insertScheduleCopies(in store: TaskStore, shownDated: Bool, status: TaskStatus,
                                      parentID: UUID? = nil, count: Int = 3) throws -> UUID {
        let id = UUID()
        let context = ModelContext(store.container)
        for index in 0..<count {
            let copy = TaskItem(id: id, title: "Scheduled", status: status, createdAt: noon,
                                updatedAt: noon.addingTimeInterval(Double(-60 * index)))
            copy.parentID = parentID
            copy.manualOrder = 123; copy.listOrderVersion = TaskItem.currentListOrderVersion
            if index == 2 {
                copy.dueTimeMinutesRaw = 60 // inconsistent import: no date
            } else if (index == 0) == shownDated {
                copy.dueDay = today; copy.dueTimeMinutes = 990
            }
            context.insert(copy)
        }
        try context.save(); store.refresh()
        return id
    }

    private func scheduleCopies(_ id: UUID, in store: TaskStore) throws -> [TaskItem] {
        try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
            .sorted { String(describing: $0.persistentModelID) < String(describing: $1.persistentModelID) }
    }

    func testTimeOnlyDraftInfersTodayAndPersistsThroughBothComposerBuilders() throws {
        let parser = TaskTextParser(calendar: calendar, now: { self.noon })
        let built = try XCTUnwrap(TaskDraftBuilder(parser: parser).draft(fromLine: "Call 4:30 pm"))
        let composed = try XCTUnwrap(TaskAddBarText(text: "Call 16:30").draft(parser: parser, status: .todo))
        XCTAssertEqual(built, composed)
        XCTAssertEqual(built.dueDay, today); XCTAssertEqual(built.dueTimeMinutes, 990)
        let store = try makeTestStore()
        let task = try XCTUnwrap(store.commit([built])?.first)
        XCTAssertEqual(task.dueTimeMinutes, 990)
    }

    func testTitleShorthandCommitsTimeThroughTasksAndTaskPageUndo() throws {
        let store = try makeTestStore()
        let library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.create(title: "Call"))
        let parser = TaskTextParser(calendar: calendar, now: { self.noon })
        let model = TasksPageModel(library: library, services: TasksPageServices(
            now: { self.noon }, calendar: { self.calendar }, locale: Locale(identifier: "en_GB")))
        model.beginEditingTitle(task.id)
        model.editingTitle = "Call tomorrow 4pm"
        XCTAssertTrue(model.commitTitle())
        XCTAssertEqual(task.title, "Call"); XCTAssertEqual(task.dueTimeMinutes, 960)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertNil(task.dueDay); XCTAssertNil(task.dueTimeMinutes)
        let history = WorkspaceHistory(route: library.undo, historyID: .tasks)
        let page = TaskNotePageModel(taskID: task.id, store: store, library: library, history: history,
                                    defaults: nil, parser: parser, calendar: calendar)
        page.beginEditingTitle()
        page.titleEdit.text = "Call tomorrow 4:30 pm"
        XCTAssertTrue(page.commitTitle())
        XCTAssertEqual(task.title, "Call"); XCTAssertEqual(task.dueTimeMinutes, 990)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertNil(task.dueDay); XCTAssertNil(task.dueTimeMinutes)
    }

    func testTasksWithinDaySortTimedFirstAndKeepUntimedAndEqualTimeOrder() throws {
        let store = try makeTestStore()
        let tasks = try XCTUnwrap(store.commit([
            TaskDraft(title: "Untimed A", dueDay: today),
            TaskDraft(title: "Late", dueDay: today, dueTimeMinutes: 990),
            TaskDraft(title: "Early A", dueDay: today, dueTimeMinutes: 60),
            TaskDraft(title: "Untimed B", dueDay: today),
            TaskDraft(title: "Early B", dueDay: today, dueTimeMinutes: 60),
        ]))
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices(
            now: { self.noon }, calendar: { self.calendar }, locale: Locale(identifier: "en_GB")))
        XCTAssertEqual(model.rows(for: .now).map(\.id),
                       [tasks[2].id, tasks[4].id, tasks[1].id, tasks[0].id, tasks[3].id])
    }

    func testInvalidAndUndatedTimeWritesAreRefusedAndMovingDateKeepsTime() throws {
        let store = try makeTestStore()
        let task = try XCTUnwrap(store.create(title: "Undated"))
        XCTAssertFalse(store.update(task, dueTimeMinutes: .some(60)))
        XCTAssertNil(task.dueDay); XCTAssertNil(task.dueTimeMinutes)
        XCTAssertTrue(store.update(task, dueDay: .some(today), dueTimeMinutes: .some(60)))
        for value in [-1, 1440] {
            XCTAssertFalse(store.update(task, dueTimeMinutes: .some(value)))
            XCTAssertEqual(task.dueTimeMinutes, 60)
        }
        let next = DueDay(year: 2026, month: 10, day: 31)!
        XCTAssertTrue(store.update(task, dueDay: .some(next)))
        XCTAssertEqual(task.dueDay, next); XCTAssertEqual(task.dueTimeMinutes, 60)
        let copy = try XCTUnwrap(store.duplicate(taskIDs: [task.id])?.first)
        XCTAssertEqual(copy.dueDay, next); XCTAssertEqual(copy.dueTimeMinutes, 60)
    }

    func testFailedTimeSaveRollsBackAndDoesNotRegisterUndo() throws {
        var fails = false
        let store = try makeTestStore(persist: { context in
            if fails { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        })
        let library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.commit([TaskDraft(title: "Call", dueDay: today, dueTimeMinutes: 60)])?.first)
        fails = true
        XCTAssertFalse(library.updateTask(task.id, dueTimeMinutes: .some(120)).isApplied)
        XCTAssertEqual(task.dueTimeMinutes, 60)
        XCTAssertFalse(library.undo(in: .tasks).isApplied)
    }

    func testFailedScheduleSavesRestoreRetainedReplicasAndAllowNextWrite() throws {
        let tomorrow = DueDay(year: 2026, month: 10, day: 31)!
        for edit in ["time", "dateAndTime", "clearDate", "later"] {
            var fails = false
            var attemptedRows: [TaskItem] = []
            let store = try makeTestStore(persist: { context in
                if fails {
                    attemptedRows = context.changedModelsArray.compactMap { $0 as? TaskItem }
                    throw CocoaError(.fileWriteUnknown)
                }
                try context.save()
            })
            let created = try XCTUnwrap(store.commit([TaskDraft(title: "Call", dueDay: today, dueTimeMinutes: 60)])?.first)
            let seed = ModelContext(store.container)
            let copy = TaskItem(id: created.id, title: "Other copy", status: .backlog,
                                createdAt: created.createdAt, updatedAt: created.updatedAt.addingTimeInterval(-60))
            copy.dueDay = tomorrow; copy.dueTimeMinutes = 90
            copy.listOrderVersion = TaskItem.currentListOrderVersion
            seed.insert(copy); try seed.save(); store.refresh()
            let shown = try XCTUnwrap(store.task(withID: created.id))
            let before = try persistedTaskFields(in: store)
            let shownBefore = try WorkspaceModelFields.read(shown)
            let library = AtticLibrary(tasks: store)
            fails = true
            let outcome: CommandOutcome
            switch edit {
            case "dateAndTime": outcome = library.updateTask(shown.id, dueDay: .some(tomorrow), dueTimeMinutes: .some(120))
            case "clearDate": outcome = library.updateTask(shown.id, dueDay: .some(nil))
            case "later": outcome = library.updateTask(shown.id, status: .backlog)
            default: outcome = library.updateTask(shown.id, dueTimeMinutes: .some(120))
            }
            XCTAssertFalse(outcome.isApplied, edit)
            XCTAssertEqual(attemptedRows.count, 2, edit)
            XCTAssertEqual(try WorkspaceModelFields.read(shown), shownBefore, "retained displayed object: \(edit)")
            for row in attemptedRows {
                XCTAssertEqual(try WorkspaceModelFields.read(row), before[row.persistentModelID], "retained replica: \(edit)")
            }
            XCTAssertEqual(try persistedTaskFields(in: store), before, edit)
            XCTAssertEqual(try WorkspaceModelFields.read(XCTUnwrap(store.task(withID: shown.id))), shownBefore, edit)
            XCTAssertFalse(library.undo(in: .tasks).isApplied, edit)

            fails = false
            XCTAssertTrue(library.updateTask(shown.id, dueDay: .some(tomorrow), dueTimeMinutes: .some(180)).isApplied, edit)
            XCTAssertTrue(try scheduleCopies(shown.id, in: store).allSatisfy { $0.dueDay == tomorrow && $0.dueTimeMinutes == 180 }, edit)
            XCTAssertTrue(library.undo(in: .tasks).isApplied, edit)
            XCTAssertEqual(store.task(withID: shown.id)?.dueTimeMinutes, 60, edit)
            XCTAssertFalse(library.undo(in: .tasks).isApplied, edit)
        }
    }

    func testFailedBatchScheduleSaveRestoresEveryDisplayedTaskAndReplicaBeforeRetry() throws {
        let tomorrow = DueDay(year: 2026, month: 10, day: 31)!
        for changesDate in [false, true] {
            var fails = false
            var attemptedRows: [TaskItem] = []
            let store = try makeTestStore(persist: { context in
                if fails {
                    attemptedRows = context.changedModelsArray.compactMap { $0 as? TaskItem }
                    throw CocoaError(.fileWriteUnknown)
                }
                try context.save()
            })
            let created = try XCTUnwrap(store.commit([
                TaskDraft(title: "First", dueDay: today, dueTimeMinutes: 60),
                TaskDraft(title: "Second", dueDay: today, dueTimeMinutes: 90)
            ]))
            let seed = ModelContext(store.container)
            for task in created {
                let copy = TaskItem(id: task.id, title: "Other copy", createdAt: task.createdAt,
                                    updatedAt: task.updatedAt.addingTimeInterval(-60))
                copy.dueDay = today; copy.dueTimeMinutes = 30
                copy.listOrderVersion = TaskItem.currentListOrderVersion
                seed.insert(copy)
            }
            try seed.save(); store.refresh()
            let shown = created.compactMap { store.task(withID: $0.id) }
            let before = try persistedTaskFields(in: store)
            let library = AtticLibrary(tasks: store)
            fails = true
            XCTAssertFalse(library.updateTaskFields(shown.map(\.id), dueDay: changesDate ? .some(tomorrow) : nil,
                                                    dueTimeMinutes: .some(120), addingTag: "Changed").isApplied)
            XCTAssertEqual(attemptedRows.count, 4)
            for row in shown + attemptedRows {
                XCTAssertEqual(try WorkspaceModelFields.read(row), before[row.persistentModelID])
            }
            XCTAssertEqual(try persistedTaskFields(in: store), before)
            XCTAssertFalse(library.undo(in: .tasks).isApplied)
            fails = false
            XCTAssertTrue(library.updateTaskFields(shown.map(\.id), dueDay: .some(tomorrow), dueTimeMinutes: .some(180)).isApplied)
            for task in shown {
                XCTAssertTrue(try scheduleCopies(task.id, in: store).allSatisfy { $0.dueDay == tomorrow && $0.dueTimeMinutes == 180 })
            }
            XCTAssertTrue(library.undo(in: .tasks).isApplied)
            XCTAssertFalse(library.undo(in: .tasks).isApplied)
        }
    }

    func testBatchTimeRefusalRestoresEarlierStagedTaskAndAllowsDatedRetry() throws {
        for listed in [false, true] {
            let store = try makeTestStore()
            let timed = try XCTUnwrap(store.commit([TaskDraft(title: "Timed", dueDay: today, dueTimeMinutes: 60)])?.first)
            let undated = try XCTUnwrap(store.create(title: "Undated"))
            let shown = [timed, undated]
            let before = try persistedTaskFields(in: store)
            let library = AtticLibrary(tasks: store)
            let refused = listed
                ? library.updateListedTasks(shown.map(\.id), dueTimeMinutes: .some(120), addingTag: "Changed")
                : library.updateTaskFields(shown.map(\.id), dueTimeMinutes: .some(120), addingTag: "Changed")
            XCTAssertFalse(refused.isApplied)
            for row in shown {
                XCTAssertEqual(try WorkspaceModelFields.read(row), before[row.persistentModelID])
            }
            XCTAssertEqual(try persistedTaskFields(in: store), before)
            XCTAssertFalse(library.undo(in: .tasks).isApplied)
            XCTAssertTrue(library.updateTaskFields(shown.map(\.id), dueDay: .some(today), dueTimeMinutes: .some(180)).isApplied)
            XCTAssertTrue(library.undo(in: .tasks).isApplied)
            XCTAssertFalse(library.undo(in: .tasks).isApplied)
        }
    }

    func testFailedTimeSaveWithFailedReloadCannotContaminateTheNextWrite() throws {
        var fails = false
        let store = try makeTestStore(persist: { context in
            if fails { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        })
        let task = try XCTUnwrap(store.commit([TaskDraft(title: "Call", dueDay: today, dueTimeMinutes: 60)])?.first)
        let before = try WorkspaceModelFields.read(task)
        let library = AtticLibrary(tasks: store)
        fails = true; store.listRefreshFailures = 1
        XCTAssertFalse(library.updateTask(task.id, dueTimeMinutes: .some(120)).isApplied)
        XCTAssertEqual(try WorkspaceModelFields.read(task), before)
        XCTAssertFalse(library.undo(in: .tasks).isApplied)
        fails = false
        XCTAssertTrue(library.updateTask(task.id, title: "Renamed").isApplied)
        XCTAssertEqual(store.task(withID: task.id)?.dueTimeMinutes, 60)
        XCTAssertTrue(try scheduleCopies(task.id, in: store).allSatisfy { $0.title == "Renamed" && $0.dueTimeMinutes == 60 })
    }

    func testFailedLaterMoveRestoresScheduleAndRespacedDestinationOrders() throws {
        var fails = false
        var attemptedRows: [TaskItem] = []
        let store = try makeTestStore(persist: { context in
            if fails {
                attemptedRows = context.changedModelsArray.compactMap { $0 as? TaskItem }
                throw CocoaError(.fileWriteUnknown)
            }
            try context.save()
        })
        let timed = try XCTUnwrap(store.commit([TaskDraft(title: "Call", dueDay: today, dueTimeMinutes: 60)])?.first)
        let later = try XCTUnwrap(store.create(title: "Later", status: .backlog))
        let seed = ModelContext(store.container)
        let destination = try XCTUnwrap(seed.fetch(FetchDescriptor<TaskItem>()).first { $0.id == later.id })
        destination.manualOrder = .max
        try seed.save(); store.refresh()
        let shown = [timed.id, later.id].compactMap { store.task(withID: $0) }
        let before = try persistedTaskFields(in: store)
        let library = AtticLibrary(tasks: store)
        fails = true
        XCTAssertFalse(library.updateTask(timed.id, status: .backlog).isApplied)
        XCTAssertEqual(attemptedRows.count, 2, "moving to Later re-spaces its overflowing destination group")
        for row in shown + attemptedRows {
            XCTAssertEqual(try WorkspaceModelFields.read(row), before[row.persistentModelID])
        }
        XCTAssertEqual(try persistedTaskFields(in: store), before)
        XCTAssertFalse(library.undo(in: .tasks).isApplied)
    }

    func testFailedTimeUndoAndRedoRestoreDisplayedValuesAndRemainRetryable() throws {
        var fails = false
        let store = try makeTestStore(persist: { context in
            if fails { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        })
        let task = try XCTUnwrap(store.commit([TaskDraft(title: "Call", dueDay: today, dueTimeMinutes: 60)])?.first)
        let library = AtticLibrary(tasks: store)
        XCTAssertTrue(library.updateTask(task.id, dueTimeMinutes: .some(120)).isApplied)
        for undoing in [true, false] {
            let shown = try XCTUnwrap(store.task(withID: task.id))
            let before = try WorkspaceModelFields.read(shown)
            fails = true
            XCTAssertFalse((undoing ? library.undo(in: .tasks) : library.redo(in: .tasks)).isApplied)
            XCTAssertEqual(try WorkspaceModelFields.read(shown), before)
            fails = false
            XCTAssertTrue((undoing ? library.undo(in: .tasks) : library.redo(in: .tasks)).isApplied)
            XCTAssertEqual(store.task(withID: task.id)?.dueTimeMinutes, undoing ? 60 : 120)
        }
    }

    private func persistedTaskFields(in store: TaskStore) throws -> [PersistentIdentifier: [String: Data]] {
        let rows = try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>())
        return try Dictionary(uniqueKeysWithValues: rows.map { ($0.persistentModelID, try WorkspaceModelFields.read($0)) })
    }

    func testTimeMutationUpdatesReplicasAndUndoPreservesANewerSchedule() throws {
        let store = try makeTestStore()
        let task = try XCTUnwrap(store.commit([TaskDraft(title: "Call", dueDay: today, dueTimeMinutes: 60)])?.first)
        let context = ModelContext(store.container)
        let duplicate = TaskItem(id: task.id, title: task.title, createdAt: task.createdAt,
                                 updatedAt: task.updatedAt.addingTimeInterval(-60))
        duplicate.dueDay = today
        duplicate.dueTimeMinutes = 90
        context.insert(duplicate); try context.save(); store.refresh()
        let library = AtticLibrary(tasks: store)
        XCTAssertTrue(library.updateTask(task.id, dueTimeMinutes: .some(120)).isApplied)
        let copies = try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(copies.map(\.dueTimeMinutes), [120, 120])
        // A later date edit owns its paired time. Undo must preserve that schedule.
        XCTAssertTrue(store.update(try XCTUnwrap(store.task(withID: task.id)), dueDay: .some(DueDay(year: 2026, month: 11, day: 1)!)))
        XCTAssertFalse(library.undo(in: .tasks).isApplied)
        XCTAssertTrue(copies.allSatisfy { $0.dueTimeMinutes == 120 })
    }

    func testAgendaOrdersFloatingClocksAcrossTheSpringDSTGap() {
        let day = DueDay(year: 2026, month: 3, day: 29)!
        let start = day.startDate(in: calendar)!
        let afterGap = calendar.date(bySettingHour: 2, minute: 0, second: 0, of: start)!
        let event = CalendarEvent(id: "after-gap", title: "Event", start: afterGap,
            end: afterGap.addingTimeInterval(1800), isAllDay: false, calendarTitle: "Test",
            colour: .init(red: 0.2, green: 0.5, blue: 0.9))
        let task = CalendarTaskEntry(id: UUID(), title: "Floating clock", due: day, isOpen: true, dueTimeMinutes: 90)
        let group = CalendarAgenda.groups(selected: day, clock: .init(today: today, now: noon),
            events: [event], tasks: [task], calendar: calendar)[0]
        XCTAssertEqual(group.items.map(\.id), ["task-" + task.id.uuidString, "event-after-gap"])
    }

    func testExplicitTimeWritesReconcileNoOpReplicasAndRefuseUndatedCopies() throws {
        let store = try makeTestStore()
        let task = try XCTUnwrap(store.commit([TaskDraft(title: "Call", dueDay: today, dueTimeMinutes: 60)])?.first)
        let context = ModelContext(store.container)
        let copy = TaskItem(id: task.id, title: task.title, createdAt: task.createdAt,
                            updatedAt: task.updatedAt.addingTimeInterval(-60))
        copy.dueDay = today; copy.dueTimeMinutes = 90
        context.insert(copy); try context.save(); store.refresh()
        XCTAssertTrue(store.update(try XCTUnwrap(store.task(withID: task.id)), dueTimeMinutes: .some(60)))
        let changed = ModelContext(store.container)
        let copies = try changed.fetch(FetchDescriptor<TaskItem>())
        XCTAssertTrue(copies.allSatisfy { $0.dueTimeMinutes == 60 })
        let replica = try XCTUnwrap(copies.first { $0.persistentModelID == copy.persistentModelID })
        replica.dueDay = nil; try changed.save(); store.refresh()
        XCTAssertFalse(store.update(try XCTUnwrap(store.task(withID: task.id)), dueTimeMinutes: .some(120)))
        let refused = try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(refused.filter { $0.dueDay == today }.map(\.dueTimeMinutes), [60])
        XCTAssertTrue(store.update(try XCTUnwrap(store.task(withID: task.id)), dueDay: .some(today), dueTimeMinutes: .some(120)))
        XCTAssertTrue(try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>()).allSatisfy {
            $0.dueDay == today && $0.dueTimeMinutes == 120
        })
    }

    func testMakingADatedChildOfLaterStandaloneKeepsItsScheduleInNowAndUndoRestoresItsParent() throws {
        let store = try makeTestStore()
        let library = AtticLibrary(tasks: store)
        let parent = try XCTUnwrap(store.create(title: "Parent", status: .backlog))
        let child = try XCTUnwrap(store.commit([TaskDraft(title: "Child", dueDay: today, dueTimeMinutes: 60,
                                                         parentID: parent.id)])?.first)
        XCTAssertTrue(library.moveSubtask(child.id, toTask: nil).isApplied)
        XCTAssertEqual(child.status, .todo); XCTAssertNil(child.parentID)
        XCTAssertEqual(child.dueDay, today); XCTAssertEqual(child.dueTimeMinutes, 60)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        let restored = try XCTUnwrap(store.task(withID: child.id))
        XCTAssertEqual(restored.parentID, parent.id); XCTAssertEqual(restored.status, .todo)
        XCTAssertEqual(restored.dueDay, today); XCTAssertEqual(restored.dueTimeMinutes, 60)
    }

    func testDateClearRemovesAnOrphanRawClockAndUndoRestoresExactImportedRawValues() throws {
        let store = try makeTestStore()
        let task = try XCTUnwrap(store.create(title: "Imported"))
        let context = ModelContext(store.container)
        let imported = try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>()).first)
        imported.dueTimeMinutesRaw = 90 // simulate an inconsistent import, never a normal app write
        try context.save(); store.refresh()
        XCTAssertTrue(store.update(try XCTUnwrap(store.task(withID: task.id)), dueDay: .some(nil)))
        XCTAssertNil(try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>()).first?.dueTimeMinutesRaw)

        let next = ModelContext(store.container)
        let invalid = try XCTUnwrap(next.fetch(FetchDescriptor<TaskItem>()).first)
        invalid.dueDayRaw = "legacy-invalid-day"; invalid.dueTimeMinutesRaw = 90
        try next.save(); store.refresh()
        let library = AtticLibrary(tasks: store)
        XCTAssertTrue(library.updateTaskFields([task.id], dueDay: .some(nil)).isApplied)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        let restored = try XCTUnwrap(store.task(withID: task.id))
        XCTAssertEqual(restored.dueDayRaw, "legacy-invalid-day")
        XCTAssertEqual(restored.dueTimeMinutesRaw, 90)
        XCTAssertNil(restored.dueTimeMinutes, "invalid imported dates never expose a usable clock")
    }

    func testWorkspaceSnapshotsIncludeAndRoundTripTheTimeField() throws {
        let task = TaskItem(title: "Clock")
        task.dueDay = today; task.dueTimeMinutes = 90
        let snapshot = try WorkspaceModelFields.read(task)
        XCTAssertNotNil(snapshot["dueTimeMinutesRaw"])
        let copy = TaskItem(title: "Copy")
        try WorkspaceModelFields.apply(snapshot, to: copy)
        XCTAssertEqual(copy.dueDay, today); XCTAssertEqual(copy.dueTimeMinutes, 90)
        XCTAssertEqual(try WorkspaceModelFields.fingerprint(task), try WorkspaceModelFields.fingerprint(copy))
    }

    func testAgendaKeepsEventAndNowChronologyDuringTheRepeatedAutumnHour() {
        let day = DueDay(year: 2026, month: 10, day: 25)!
        let utc = ISO8601DateFormatter()
        func event(_ id: String, _ instant: String) -> CalendarEvent {
            let start = utc.date(from: instant)!
            return CalendarEvent(id: id, title: id, start: start, end: start.addingTimeInterval(1800),
                isAllDay: false, calendarTitle: "Test", colour: .init(red: 0.2, green: 0.5, blue: 0.9))
        }
        let first = event("first", "2026-10-25T00:45:00Z") // 01:45 BST
        let second = event("second", "2026-10-25T01:15:00Z") // 01:15 GMT
        let task = CalendarTaskEntry(id: UUID(), title: "First 01:30", due: day, isOpen: true, dueTimeMinutes: 90)
        let groups = CalendarAgenda.groups(selected: day,
            clock: .init(today: day, now: utc.date(from: "2026-10-25T01:00:00Z")!),
            events: [second, first], tasks: [task], calendar: calendar)
        XCTAssertEqual(groups[0].items.map(\.id), ["task-" + task.id.uuidString, "event-first", "now", "event-second"])
    }

    func testAgendaInterleavesTimedTasksAndEventsUsingFakeSource() throws {
        let store = try makeTestStore()
        let tasks = try XCTUnwrap(store.commit([
            TaskDraft(title: "Match untimed", dueDay: today),
            TaskDraft(title: "Match timed", dueDay: today, dueTimeMinutes: 630),
        ]))
        func event(_ id: String, hour: Int, allDay: Bool = false) -> CalendarEvent {
            let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: noon)!
            return CalendarEvent(id: id, title: "Match event", start: start,
                end: start.addingTimeInterval(allDay ? 86400 : 3600), isAllDay: allDay,
                calendarTitle: "Test", colour: .init(red: 0.2, green: 0.5, blue: 0.9))
        }
        let source = CalendarEventSourceStub(events: [event("late", hour: 13), event("early", hour: 9), event("all", hour: 0, allDay: true)])
        let model = CalendarPageModel(store: store, source: source, calendar: calendar, now: { self.noon })
        let expected = ["event-all", "task-" + tasks[0].id.uuidString, "event-early", "task-" + tasks[1].id.uuidString, "now", "event-late"]
        XCTAssertEqual(model.snapshot.groups.first?.items.map(\.id), expected)
        model.setQuery("Match"); model.commitSearch()
        XCTAssertEqual(model.snapshot.groups.first?.items.map(\.id), expected.filter { $0 != "now" })
    }
}
