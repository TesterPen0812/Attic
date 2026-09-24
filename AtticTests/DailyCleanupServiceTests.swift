import XCTest
import SwiftData
@testable import Attic

final class DailyCleanupServiceTests: XCTestCase {
    @MainActor
    // Phase 0: the cleanup keeps today's timing but moves finished tasks to
    // the Done log instead of deleting them. These tests keep their original
    // cases; "deleted" became "moved", and every row must still be stored.
    func testCleanupMovesOnlyDoneTasksFromEarlierDaysToTheDoneLog() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Rome"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 9)))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        let clock = MutableNow(yesterday)
        let store = try makeTestStore(now: { clock.value })

        let oldDone = try XCTUnwrap(store.create(title: "Old done"))
        store.markDone(oldDone)
        let pending = try XCTUnwrap(store.create(title: "Still todo"))
        let progressing = try XCTUnwrap(store.create(title: "Still progressing"))
        store.setStatus(.inProgress, for: progressing)

        clock.value = now
        let todayDone = try XCTUnwrap(store.create(title: "Today done"))
        store.markDone(todayDone)

        let service = DailyCleanupService(store: store, now: { now }, calendar: { calendar })
        let moved = service.performCleanup()
        XCTAssertNil(store.lastErrorMessage, store.lastErrorMessage ?? "")
        XCTAssertEqual(moved, 1)

        XCTAssertFalse(store.tasks.contains { $0.id == oldDone.id })
        XCTAssertEqual(store.doneLog().map(\.id), [oldDone.id])
        XCTAssertEqual(try ModelContext(store.container).fetchCount(FetchDescriptor<TaskItem>()), 4)
        XCTAssertTrue(store.tasks.contains { $0.id == todayDone.id })
        XCTAssertTrue(store.tasks.contains { $0.id == pending.id })
        XCTAssertTrue(store.tasks.contains { $0.id == progressing.id })
    }

    @MainActor
    func testTaskCompletedJustBeforeMidnightMovesAfterDayChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Rome"))
        let beforeMidnight = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 23, minute: 59))
        )
        let afterMidnight = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 9, hour: 0, minute: 1))
        )
        let clock = MutableNow(beforeMidnight)
        let store = try makeTestStore(now: { clock.value })
        let task = try XCTUnwrap(store.create(title: "Late finish"))
        store.markDone(task)

        clock.value = afterMidnight
        let service = DailyCleanupService(store: store, now: { clock.value }, calendar: { calendar })
        let moved = service.performCleanup()
        XCTAssertNil(store.lastErrorMessage, store.lastErrorMessage ?? "")
        XCTAssertEqual(moved, 1)
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertEqual(store.doneLog().map(\.id), [task.id])
    }

    @MainActor
    func testCleanupMovesOnlyCompletionStrictlyBeforeCutoff() throws {
        let cutoff = Date(timeIntervalSince1970: 500_000)
        let createdAt = cutoff.addingTimeInterval(-100)
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let missingCompletion = TaskItem(
            title: "Missing completion date",
            status: .done,
            createdAt: createdAt,
            completedAt: nil
        )
        let atCutoff = TaskItem(
            title: "Completed at cutoff",
            status: .done,
            createdAt: createdAt,
            completedAt: cutoff
        )
        let beforeCutoff = TaskItem(
            title: "Completed before cutoff",
            status: .done,
            createdAt: createdAt,
            completedAt: cutoff.addingTimeInterval(-1)
        )
        let afterCutoff = TaskItem(
            title: "Completed after cutoff",
            status: .done,
            createdAt: createdAt,
            completedAt: cutoff.addingTimeInterval(1)
        )
        [missingCompletion, atCutoff, beforeCutoff, afterCutoff].forEach(context.insert)
        try context.save()

        let store = TaskStore(container: container)
        let moved = store.moveCompletedToDoneLog(before: cutoff)
        XCTAssertNil(store.lastErrorMessage, store.lastErrorMessage ?? "")
        XCTAssertEqual(moved, 1)

        let expectedRemainingIDs: Set<UUID> = [
            missingCompletion.id,
            atCutoff.id,
            afterCutoff.id,
        ]
        XCTAssertEqual(Set(store.tasks.map(\.id)), expectedRemainingIDs)
        let persisted = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(Set(persisted.map(\.id)), expectedRemainingIDs.union([beforeCutoff.id]))
        XCTAssertEqual(Set(persisted.filter { $0.doneLoggedAt != nil }.map(\.id)), [beforeCutoff.id])
    }

    @MainActor
    func testCleanupPreservesDivergentDuplicateButMovesOldDoneAfterRecentEdit() throws {
        let now = Date(timeIntervalSince1970: 500_000)
        let old = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let sharedID = UUID()
        context.insert(TaskItem(
            id: sharedID,
            title: "Done copy",
            status: .done,
            createdAt: old,
            updatedAt: old,
            completedAt: old
        ))
        context.insert(TaskItem(
            id: sharedID,
            title: "Restored copy",
            status: .todo,
            createdAt: old,
            updatedAt: now
        ))
        let recentDone = TaskItem(
            title: "Recently edited",
            status: .done,
            createdAt: old,
            updatedAt: now,
            completedAt: old
        )
        context.insert(recentDone)
        try context.save()

        let store = TaskStore(container: container)
        let service = DailyCleanupService(store: store, now: { now })

        let moved = service.performCleanup()
        XCTAssertNil(store.lastErrorMessage, store.lastErrorMessage ?? "")
        XCTAssertEqual(moved, 1)
        let verificationContext = ModelContext(container)
        let remaining = try verificationContext.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(remaining.count, 3)
        XCTAssertTrue(remaining.filter { $0.id == sharedID }.allSatisfy { $0.doneLoggedAt == nil })
        XCTAssertEqual(remaining.filter { $0.doneLoggedAt != nil }.map(\.id), [recentDone.id])
    }

    @MainActor
    func testCleanupPreservesDoneReplicasWithDivergentFields() throws {
        let now = Date(timeIntervalSince1970: 500_000)
        let old = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let sharedID = UUID()
        context.insert(TaskItem(
            id: sharedID,
            title: "Original title",
            status: .done,
            priority: .low,
            createdAt: old,
            updatedAt: old,
            completedAt: old
        ))
        context.insert(TaskItem(
            id: sharedID,
            title: "Conflicting title",
            status: .done,
            priority: .high,
            createdAt: old,
            updatedAt: old,
            completedAt: old
        ))
        try context.save()

        let store = TaskStore(container: container)
        let service = DailyCleanupService(store: store, now: { now })

        XCTAssertEqual(service.performCleanup(), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskItem>()), 2)
        XCTAssertTrue(try context.fetch(FetchDescriptor<TaskItem>()).allSatisfy { $0.doneLoggedAt == nil })
    }

    // MARK: - Done log (Phase 0)

    private func rome() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Rome"))
        return calendar
    }

    @MainActor
    func testCleanupIsIdempotentAndNeverLogsATaskTwice() throws {
        let calendar = try rome()
        let finished = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 18)))
        let nextMorning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 9, hour: 8)))
        let clock = MutableNow(finished)
        let store = try makeTestStore(now: { clock.value })
        let task = try XCTUnwrap(store.create(title: "Done yesterday"))
        XCTAssertTrue(store.markDone(task))
        clock.value = nextMorning
        let service = DailyCleanupService(store: store, now: { clock.value }, calendar: { calendar })

        XCTAssertEqual(service.performCleanup(), 1)
        let loggedAt = try XCTUnwrap(store.doneLog().first?.doneLoggedAt)
        // Wake, day-change and time-zone notifications can all arrive at once.
        for _ in 0..<3 { XCTAssertEqual(service.performCleanup(), 0) }
        clock.value = nextMorning.addingTimeInterval(3_600)
        XCTAssertEqual(service.performCleanup(), 0)
        XCTAssertEqual(store.doneLog().map(\.id), [task.id])
        XCTAssertEqual(store.doneLog().first?.doneLoggedAt, loggedAt, "the move is recorded once")
    }

    @MainActor
    func testClockMovingBackwardsNeverBringsALoggedTaskBackOrRepeatsTheMove() throws {
        let calendar = try rome()
        let finished = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 18)))
        let clock = MutableNow(finished)
        let store = try makeTestStore(now: { clock.value })
        let task = try XCTUnwrap(store.create(title: "Done"))
        XCTAssertTrue(store.markDone(task))
        let service = DailyCleanupService(store: store, now: { clock.value }, calendar: { calendar })

        clock.value = finished.addingTimeInterval(24 * 3_600)
        XCTAssertEqual(service.performCleanup(), 1)
        clock.value = finished.addingTimeInterval(-3 * 24 * 3_600)
        XCTAssertEqual(service.performCleanup(), 0)
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertEqual(store.doneLog().map(\.id), [task.id])
    }

    @MainActor
    func testTimeZoneChangesNeitherSkipNorRepeatTheCleanup() throws {
        // Finished at 23:30 in Rome on 8 July = 21:30 UTC.
        let rome = try rome()
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let finished = try XCTUnwrap(rome.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 23, minute: 30)))
        let clock = MutableNow(finished)
        let store = try makeTestStore(now: { clock.value })
        let task = try XCTUnwrap(store.create(title: "Late finish"))
        XCTAssertTrue(store.markDone(task))
        var active = rome
        let service = DailyCleanupService(store: store, now: { clock.value }, calendar: { active })

        // 00:30 in Rome is still 8 July in New York: after flying west the
        // task finished "today", so it stays until New York's next day.
        clock.value = finished.addingTimeInterval(3_600)
        active = newYork
        XCTAssertEqual(service.performCleanup(), 0)
        XCTAssertEqual(store.tasks.map(\.id), [task.id])
        // New York's next day: moved, once.
        clock.value = try XCTUnwrap(newYork.date(from: DateComponents(year: 2026, month: 7, day: 9, hour: 0, minute: 5)))
        XCTAssertEqual(service.performCleanup(), 1)
        // Flying back to Rome changes the day boundary again; nothing repeats.
        active = rome
        XCTAssertEqual(service.performCleanup(), 0)
        XCTAssertEqual(store.doneLog().map(\.id), [task.id])
    }

    @MainActor
    func testWakingAfterSeveralDaysCatchesUpEverythingInOnePass() throws {
        let calendar = try rome()
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 10)))
        let clock = MutableNow(start)
        let store = try makeTestStore(now: { clock.value })
        var ids: [UUID] = []
        for day in 0..<4 {
            clock.value = start.addingTimeInterval(Double(day) * 24 * 3_600)
            let task = try XCTUnwrap(store.create(title: "Day \(day)"))
            XCTAssertTrue(store.markDone(task))
            ids.append(task.id)
        }
        // The Mac slept through three midnights.
        clock.value = start.addingTimeInterval(6 * 24 * 3_600)
        let service = DailyCleanupService(store: store, now: { clock.value }, calendar: { calendar })
        XCTAssertEqual(service.performCleanup(), 4)
        XCTAssertEqual(Set(store.doneLog().map(\.id)), Set(ids))
        XCTAssertEqual(try ModelContext(store.container).fetchCount(FetchDescriptor<TaskItem>()), 4)
    }

    @MainActor
    func testLoggedTasksAreHiddenFromEveryListAndAgentsButKeepTheirData() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000))
        let store = try makeTestStore(now: { clock.value })
        let task = try XCTUnwrap(store.create(title: "Finished", priority: .high))
        XCTAssertTrue(store.setTags(["work"], for: task))
        XCTAssertTrue(store.markDone(task))
        clock.value = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(store.moveCompletedToDoneLog(before: clock.value), 1)

        XCTAssertNil(store.task(withID: task.id))
        XCTAssertEqual(store.snapshot(for: .tasks).visibleCount, 0)
        XCTAssertEqual(TaskStore(container: store.container).tasks.count, 0, "hidden after a relaunch too")
        let handler = MCPRequestHandler(tools: AgentTaskTools(store: store), serverVersion: "test")
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "list_tasks", "arguments": [:] as [String: Any]]
        ])
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(handler.handle(body: body).body)) as? [String: Any])
        let text = try XCTUnwrap(((response["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.contains("\"count\":0"))
        let logged = try XCTUnwrap(store.doneLog().first)
        XCTAssertEqual(logged.title, "Finished")
        XCTAssertEqual(logged.priority, .high)
        XCTAssertEqual(logged.tags, ["work"])
        XCTAssertEqual(logged.completedAt, Date(timeIntervalSince1970: 1_000))
    }

    @MainActor
    func testASubtaskInRecentlyDeletedNeitherBlocksNorFollowsItsParentIntoTheDoneLog() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000))
        let store = try makeTestStore(now: { clock.value })
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let deletedChild = try XCTUnwrap(store.create(title: "Abandoned", parentID: parent.id))
        let doneChild = try XCTUnwrap(store.create(title: "Done", parentID: parent.id))
        XCTAssertTrue(store.delete(deletedChild))
        XCTAssertTrue(store.markDone(doneChild))
        XCTAssertTrue(store.markDone(parent))
        clock.value = Date(timeIntervalSince1970: 100_000)

        XCTAssertEqual(store.moveCompletedToDoneLog(before: clock.value), 2)
        XCTAssertEqual(Set(store.doneLog().map(\.id)), [parent.id, doneChild.id])
        XCTAssertEqual(store.recentlyDeletedTasks().map(\.ref.id), [deletedChild.id])
    }

    @MainActor
    func testDoneLogMoveFailureLeavesTasksInTheList() throws {
        let gate = PersistenceGate()
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000))
        let store = try makeTestStore(now: { clock.value }, persist: gate.save)
        let task = try XCTUnwrap(store.create(title: "Done"))
        XCTAssertTrue(store.markDone(task))
        gate.shouldFail = true
        XCTAssertEqual(store.moveCompletedToDoneLog(before: .distantFuture), 0)
        XCTAssertEqual(store.tasks.map(\.id), [task.id])
        XCTAssertTrue(store.doneLog().isEmpty)
        gate.shouldFail = false
        XCTAssertEqual(store.moveCompletedToDoneLog(before: .distantFuture), 1)
    }
}
