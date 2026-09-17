import XCTest
import SwiftData
@testable import Attic

final class DailyCleanupServiceTests: XCTestCase {
    @MainActor
    func testCleanupDeletesOnlyDoneTasksFromEarlierDays() throws {
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
        let deleted = service.performCleanup()
        XCTAssertNil(store.lastErrorMessage, store.lastErrorMessage ?? "")
        XCTAssertEqual(deleted, 1)

        XCTAssertFalse(store.tasks.contains { $0.id == oldDone.id })
        XCTAssertTrue(store.tasks.contains { $0.id == todayDone.id })
        XCTAssertTrue(store.tasks.contains { $0.id == pending.id })
        XCTAssertTrue(store.tasks.contains { $0.id == progressing.id })
    }

    @MainActor
    func testTaskCompletedJustBeforeMidnightExpiresAfterDayChange() throws {
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
        let deleted = service.performCleanup()
        XCTAssertNil(store.lastErrorMessage, store.lastErrorMessage ?? "")
        XCTAssertEqual(deleted, 1)
        XCTAssertTrue(store.tasks.isEmpty)
    }

    @MainActor
    func testCleanupPurgesOnlyCompletionStrictlyBeforeCutoff() throws {
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
        let deleted = store.purgeCompleted(before: cutoff)
        XCTAssertNil(store.lastErrorMessage, store.lastErrorMessage ?? "")
        XCTAssertEqual(deleted, 1)

        let expectedRemainingIDs: Set<UUID> = [
            missingCompletion.id,
            atCutoff.id,
            afterCutoff.id,
        ]
        XCTAssertEqual(Set(store.tasks.map(\.id)), expectedRemainingIDs)
        let persisted = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(Set(persisted.map(\.id)), expectedRemainingIDs)
        XCTAssertFalse(persisted.contains { $0.id == beforeCutoff.id })
    }

    @MainActor
    func testCleanupPreservesDivergentDuplicateButDeletesOldDoneAfterRecentEdit() throws {
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

        let deleted = service.performCleanup()
        XCTAssertNil(store.lastErrorMessage, store.lastErrorMessage ?? "")
        XCTAssertEqual(deleted, 1)
        let verificationContext = ModelContext(container)
        let remaining = try verificationContext.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(remaining.count, 2)
        XCTAssertTrue(remaining.allSatisfy { $0.id == sharedID })
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
    }
    // TEMPORARY hosted-runtime diagnostic for the macOS 26 cleanup failure.
    // The candidate query must not order-compare the optional completedAt
    // date on that runtime; these probes print the row count each predicate
    // form returns, including the UUID-membership and optional-parent forms
    // the purge also uses, so the hosted log records exactly which forms are
    // safe. Remove once the hosted run confirms the fixed candidate query.
    @MainActor
    func testHostedPredicateFormProbe() throws {
        let cutoff = Date(timeIntervalSince1970: 500_000)
        let createdAt = cutoff.addingTimeInterval(-100)
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let beforeCutoff = TaskItem(
            title: "Completed before cutoff",
            status: .done,
            createdAt: createdAt,
            completedAt: cutoff.addingTimeInterval(-1)
        )
        let doneParent = TaskItem(
            title: "Done parent",
            status: .done,
            createdAt: createdAt,
            completedAt: cutoff.addingTimeInterval(-1)
        )
        let openChild = TaskItem(
            title: "Open child",
            status: .todo,
            createdAt: createdAt,
            parentID: doneParent.id
        )
        let fixtures = [
            beforeCutoff,
            doneParent,
            openChild,
            TaskItem(title: "Missing completion date", status: .done, createdAt: createdAt, completedAt: nil),
            TaskItem(title: "Completed at cutoff", status: .done, createdAt: createdAt, completedAt: cutoff),
            TaskItem(title: "Completed after cutoff", status: .done, createdAt: createdAt, completedAt: cutoff.addingTimeInterval(1)),
        ]
        fixtures.forEach(context.insert)
        try context.save()

        let fresh = ModelContext(container)
        let doneRaw = TaskStatus.done.rawValue
        let farFuture = Date.distantFuture
        let candidateIDs = [beforeCutoff.id, doneParent.id]

        func probe(_ label: String, _ make: () throws -> [TaskItem]) {
            do {
                let rows = try make()
                print("PROBE", label, "count:", rows.count, "titles:", rows.map(\.title).sorted())
            } catch {
                print("PROBE", label, "THREW:", String(describing: error))
            }
        }

        probe("A status-only") {
            try fresh.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.statusRaw == doneRaw }
            ))
        }
        probe("B candidate-nonnil-force") {
            try fresh.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.statusRaw == doneRaw && $0.completedAt != nil && $0.completedAt! < cutoff }
            ))
        }
        probe("C candidate-coalesce") {
            try fresh.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.statusRaw == doneRaw && ($0.completedAt ?? farFuture) < cutoff }
            ))
        }
        probe("D completedAt-nonnil-only") {
            try fresh.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.completedAt != nil }
            ))
        }
        probe("E completedAt-force-compare-only") {
            try fresh.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.completedAt! < cutoff }
            ))
        }
        probe("F completedAt-coalesce-only") {
            try fresh.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { ($0.completedAt ?? farFuture) < cutoff }
            ))
        }
        probe("G createdAt-compare") {
            try fresh.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.createdAt < cutoff }
            ))
        }
        probe("I id-membership") {
            try fresh.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { candidateIDs.contains($0.id) }
            ))
        }
        probe("J parent-force-unwrap-membership") {
            try fresh.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.parentID != nil && candidateIDs.contains($0.parentID!) }
            ))
        }
        // The replacement candidate shape: status-only fetch plus an
        // in-memory completion-date filter.
        probe("L status-only-plus-memory-cutoff") {
            try fresh.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.statusRaw == doneRaw }
            )).filter { $0.completedAt.map { $0 < cutoff } == true }
        }
        // The replacement child shape: a non-nil check on the optional
        // parent link, matched against the candidates in memory.
        probe("M parent-nonnil-only") {
            try fresh.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.parentID != nil }
            ))
        }
        probe("N parent-nonnil-plus-memory-membership") {
            try fresh.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.parentID != nil }
            )).filter { task in
                guard let parentID = task.parentID else { return false }
                return candidateIDs.contains(parentID)
            }
        }

        let candidatePredicate = #Predicate<TaskItem> {
            $0.statusRaw == doneRaw && $0.completedAt != nil && $0.completedAt! < cutoff
        }
        do {
            let all = try fresh.fetch(FetchDescriptor<TaskItem>())
            let manual = try all.filter { try candidatePredicate.evaluate($0) }
            print("PROBE manual-eval count:", manual.count, "titles:", manual.map(\.title).sorted())
        } catch {
            print("PROBE manual-eval THREW:", String(describing: error))
        }

        let store = TaskStore(container: container)
        let deleted = store.purgeCompleted(before: cutoff)
        print("PROBE store-purge deleted:", deleted, "lastError:", store.lastErrorMessage ?? "nil")
    }
}
