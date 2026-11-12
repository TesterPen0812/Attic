import XCTest
import SwiftData
@testable import Attic

final class DailyCleanupServiceTests: XCTestCase {

    @MainActor
    func testDatesHuntClockCorrectionCleansOldDoneWithoutWaitingForTheOldMidnightTimer() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 12,
                                                                     hour: 23, minute: 58)))
        let later = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 14,
                                                                     hour: 9)))
        let clock = MutableNow(start)
        let store = try makeTestStore(now: { clock.value })
        let task = try XCTUnwrap(store.create(title: "Finished before clock correction"))
        XCTAssertTrue(store.markDone(task))
        let service = DailyCleanupService(store: store, now: { clock.value }, calendar: { calendar })
        service.start()
        defer { service.stop() }
        XCTAssertTrue(store.doneLog().isEmpty)

        // Manual/NTP clock jumps do not necessarily emit a calendar-day or
        // time-zone notification. The platform emits a clock-change event.
        clock.value = later
        NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(store.doneLog().map(\.id), [task.id],
                       "a live clock correction should archive yesterday's completed task")
        XCTAssertEqual(try ModelContext(store.container).fetchCount(FetchDescriptor<TaskItem>()), 1,
                       "cleanup must preserve the task's stored record")
    }

    @MainActor
    func testDatesHuntSeededClockAndZoneCleanupNeverLosesOrReplaysDoneTasks() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let datePieces: [(Int, Int, Int, Int, Int)] = [
            (2026, 3, 8, 6, 59), (2026, 3, 8, 7, 1),
            (2026, 3, 8, 9, 59), (2026, 3, 8, 10, 1),
            (2026, 3, 29, 0, 59), (2026, 3, 29, 1, 1),
            (2026, 10, 25, 0, 30), (2026, 10, 25, 1, 30),
            (2026, 11, 1, 5, 30), (2026, 11, 1, 6, 30),
            (2026, 11, 1, 8, 30), (2026, 11, 1, 9, 30),
            (2026, 12, 31, 23, 59), (2027, 1, 1, 0, 1),
            (2028, 2, 28, 23, 59), (2028, 2, 29, 0, 1), (2028, 3, 1, 0, 1)
        ]
        let instants = try datePieces.map { y, m, d, h, minute in
            try XCTUnwrap(utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: minute)))
        }
        let zones = ["Europe/London", "America/New_York", "America/Los_Angeles", "Asia/Tokyo"]
        for seed in [UInt64(0xDA7E_C101), 0xDA7E_C102] {
            var state = seed
            func draw(_ upper: Int) -> Int {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Int((state >> 33) % UInt64(upper))
            }
            let clock = MutableNow(instants[0])
            var calendar = utc
            let store = try makeTestStore(now: { clock.value })
            let service = DailyCleanupService(store: store, now: { clock.value }, calendar: { calendar })
            var created = Set<UUID>()
            var pending: [UUID] = []
            var completed: [UUID: Date] = [:]
            var logged = Set<UUID>()

            for step in 0..<360 {
                switch draw(6) {
                case 0: clock.value = instants[draw(instants.count)]
                case 1: calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zones[draw(zones.count)]))
                case 2 where created.count < 90:
                    let new = try XCTUnwrap(store.create(title: "Seed \(seed) task \(step)"))
                    created.insert(new.id)
                    pending.append(new.id)
                case 3 where !pending.isEmpty:
                    let id = pending.remove(at: draw(pending.count))
                    let task = try XCTUnwrap(store.task(withID: id))
                    XCTAssertTrue(store.markDone(task), "seed=\(seed) step=\(step)")
                    completed[id] = try XCTUnwrap(store.task(withID: id)?.completedAt)
                default: break // timer ticks, returning from sleep, or no-op
                }
                let cutoff = calendar.startOfDay(for: clock.value)
                let newlyEligible = Set(completed.filter { $0.value < cutoff }.map { $0.key })
                    .subtracting(logged)
                logged.formUnion(newlyEligible)
                XCTAssertEqual(service.performCleanup(), newlyEligible.count,
                               "seed=\(seed) step=\(step) cutoff=\(cutoff)")
                XCTAssertEqual(Set(store.doneLog().map(\.id)), logged, "seed=\(seed) step=\(step)")
                XCTAssertEqual(Set(store.tasks.map(\.id)), created.subtracting(logged),
                               "seed=\(seed) step=\(step) neither live nor logged tasks may disappear")
                if step.isMultiple(of: 30) {
                    let rows = try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>())
                    XCTAssertEqual(Set(rows.map(\.id)), created, "seed=\(seed) step=\(step) physical records stay durable")
                }
            }
            print("DATES_HUNT_CLEANUP seed=\(seed) steps=360")
        }
    }

    @MainActor
    func testV10NotificationsOnSeparateMainQueueTurnsShareOneCleanup() async throws {
        let store = try makeTestStore()
        var passes = 0
        let service = DailyCleanupService(store: store, purgeRecentlyDeleted: { _, _ in passes += 1 })
        service.start()
        defer { service.stop() }
        XCTAssertEqual(passes, 1)

        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        try await Task.sleep(for: .milliseconds(30))
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        let queued = try XCTUnwrap(service.queuedCleanupTask)
        await queued.value
        XCTAssertEqual(passes, 2, "wake and activation arriving on separate main turns should share one pass")

        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        let later = try XCTUnwrap(service.queuedCleanupTask)
        await later.value
        XCTAssertEqual(passes, 3, "a later event must still catch overdue cleanup")
    }

    @MainActor
    func testNotificationBurstCoalescesCleanupAndAllowsLaterWake() async throws {
        let store = try makeTestStore()
        var passes = 0
        let service = DailyCleanupService(store: store, purgeRecentlyDeleted: { _, _ in passes += 1 })
        service.start()
        XCTAssertEqual(passes, 1)

        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
                     NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.post(name: name, object: nil)
        }
        let queued = try XCTUnwrap(service.queuedCleanupTask)
        await queued.value
        XCTAssertEqual(passes, 2, "One notification burst must run only one cleanup pass")

        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        let later = try XCTUnwrap(service.queuedCleanupTask)
        await later.value
        XCTAssertEqual(passes, 3, "A later notification must still run overdue cleanup")
        service.stop()
    }

    @MainActor
    func testR1_03CleanupKeepsCanonicallyEqualButByteDivergentTitles() throws {
        let now = Date(timeIntervalSince1970: 500_000)
        let old = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container), id = UUID()
        for title in ["Café", "Cafe\u{301}"] {
            context.insert(TaskItem(id: id, title: title, status: .done, createdAt: old, updatedAt: old, completedAt: old))
        }
        try context.save()
        let store = TaskStore(container: container)
        XCTAssertEqual(DailyCleanupService(store: store, now: { now }).performCleanup(), 0)
        let rows = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.doneLoggedAt == nil })
        XCTAssertEqual(Set(rows.map { Array($0.title.utf16) }).count, 2)
    }

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
