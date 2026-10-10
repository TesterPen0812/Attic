import SwiftData
import XCTest
@testable import Attic

@MainActor
final class PhaseXHunt1TaskInvariantTests: XCTestCase {
    func testStableReorderStaysInCompletionGroupAndSubtasksFollowParent() throws {
        let store = try makeTestStore()
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let siblings = try (0..<5).map { try XCTUnwrap(store.create(title: "Child \($0)", parentID: parent.id)) }
        XCTAssertTrue(store.markDone(siblings[3])); XCTAssertTrue(store.markDone(siblings[4]))
        XCTAssertTrue(store.reorder(taskID: siblings[0].id, relativeTo: siblings[2].id))
        XCTAssertEqual(store.subtasks(of: parent.id).map(\.id), [siblings[1].id, siblings[2].id, siblings[0].id, siblings[3].id, siblings[4].id])
        XCTAssertFalse(store.reorder(taskID: siblings[0].id, relativeTo: siblings[3].id))
        XCTAssertTrue(store.setStatus(.inProgress, for: parent))
        // Children remain linked to the moved root; their completion state is
        // independent (open children are stored as todo by design).
        XCTAssertTrue(store.subtasks(of: parent.id).allSatisfy { $0.parentID == parent.id })
        XCTAssertEqual(store.parent(of: siblings[0])?.status, .inProgress)
        XCTAssertEqual(store.snapshot(for: .tasks).sections.first { $0.status == .inProgress }?.tasks.map(\.id), [parent.id])
        XCTAssertEqual(store.subtasks(of: parent.id).filter { $0.status == .done }.map(\.id), [siblings[3].id, siblings[4].id])
    }

    func testCleanupUsesLocalMidnightAcrossDSTAndProtectsDivergentDuplicates() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12))!
        let midnight = calendar.startOfDay(for: now)
        let store = try makeTestStore(now: { now })
        let context = ModelContext(store.container)
        let old = TaskItem(title: "Old done", status: .done, createdAt: midnight.addingTimeInterval(-90_000),
                           updatedAt: now, completedAt: midnight.addingTimeInterval(-1))
        let boundary = TaskItem(title: "At midnight", status: .done, completedAt: midnight)
        let shared = UUID()
        let copies = [TaskItem(id: shared, title: "A", status: .done, completedAt: midnight.addingTimeInterval(-2)),
                      TaskItem(id: shared, title: "B", status: .done, completedAt: midnight.addingTimeInterval(-2))]
        ([old, boundary] + copies).forEach(context.insert); try context.save(); store.refresh()
        let cleanup = DailyCleanupService(store: store, now: { now }, calendar: { calendar })
        XCTAssertEqual(cleanup.performCleanup(), 1); XCTAssertEqual(cleanup.performCleanup(), 0)
        let rows = try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertNotNil(rows.first { $0.id == old.id }?.doneLoggedAt)
        XCTAssertNil(rows.first { $0.id == boundary.id }?.doneLoggedAt)
        XCTAssertTrue(rows.filter { $0.id == shared }.allSatisfy { $0.doneLoggedAt == nil && $0.deletedAt == nil })
    }

    func testTaskFieldMutationsAndDeletionTouchEveryPhysicalReplica() throws {
        let store = try makeTestStore()
        let row = try XCTUnwrap(store.create(title: "First"))
        let context = ModelContext(store.container)
        context.insert(TaskItem(id: row.id, title: "Divergent")); try context.save(); store.refresh()
        let canonical = try XCTUnwrap(store.task(withID: row.id))
        XCTAssertTrue(store.rename(canonical, to: "Both"))
        XCTAssertTrue(store.setPriority(.high, for: canonical))
        XCTAssertTrue(store.setTags(["uni"], for: canonical))
        var rows = try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.title == "Both" && $0.priority == .high && $0.tags == ["uni"] })
        XCTAssertTrue(store.delete(try XCTUnwrap(store.task(withID: row.id))))
        rows = try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(rows.count, 2); XCTAssertTrue(rows.allSatisfy { $0.deletedAt != nil })
    }

    func testDestructivePurgeProtectsDivergentPhysicalTaskFamily() throws {
        let deletedAt = Date(timeIntervalSince1970: 1_000)
        let store = try makeTestStore(now: { deletedAt })
        let row = try XCTUnwrap(store.create(title: "Keep"))
        XCTAssertTrue(store.delete(row))
        let deleted = try XCTUnwrap(ModelContext(store.container).fetch(FetchDescriptor<TaskItem>()).first)
        let copy = TaskItem(id: row.id, title: "Different", status: deleted.status,
                            createdAt: deleted.createdAt, updatedAt: deleted.updatedAt)
        copy.deletedAt = deleted.deletedAt
        copy.deletionRootID = deleted.deletionRootID
        copy.deletionMembersRaw = deleted.deletionMembersRaw
        let context = ModelContext(store.container); context.insert(copy); try context.save(); store.refresh()
        XCTAssertTrue(store.purgeDeleted(before: deletedAt.addingTimeInterval(1)).isEmpty)
        let remaining = try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(Set(remaining.map(\.title)), ["Keep", "Different"])
    }
    func testH5_03LocalOnlyConfigurationsCannotOptIntoCloudKit() {
        #if ATTIC_LOCAL_ONLY
        for environment in [AtticCloudKitEnvironment.development, .production] {
            let configuration = PersistenceController.makeConfiguration(cloudSyncEnabled: true, environment: environment)
            XCTExpectFailure("H5-03") {
                XCTAssertNil(configuration.cloudKitContainerIdentifier,
                    "A compiled local-only build must ignore CloudKit opt-in")
            }
        }
        #endif
    }

}
