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

    func testMakingAChildStandalonePreservesScheduleAndUndoRestoresItsParent() throws {
        let store = try makeTestStore()
        let library = AtticLibrary(tasks: store)
        let parent = try XCTUnwrap(store.create(title: "Parent"))
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
