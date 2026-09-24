import SwiftData
import XCTest
@testable import Attic

/// Task restores are complete or refused, and a subtask returns only to a live
/// main task (data review findings 5 and 6).
@MainActor
final class TaskRestoreSafetyTests: XCTestCase {
    private let day: TimeInterval = 24 * 3_600


    func testTaskRestoreIsRefusedWhenPartOfTheDeleteIsMissing() throws {
        let store = try makeTestStore()
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let child = try XCTUnwrap(store.create(title: "Child", parentID: parent.id))
        XCTAssertTrue(store.delete(parent))
        // The child's rows vanished (a partial purge elsewhere).
        let context = ModelContext(store.container)
        let childID = child.id
        try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == childID })).forEach(context.delete)
        try context.save()
        store.refresh()

        XCTAssertFalse(store.restoreDeleted(taskID: parent.id))
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertTrue(try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>()).allSatisfy { $0.deletedAt != nil })
    }

    func testTaskRestoreIsRefusedWhenAReplicaBelongsToAnotherDelete() throws {
        let store = try makeTestStore()
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let child = try XCTUnwrap(store.create(title: "Child", parentID: parent.id))
        XCTAssertTrue(store.delete(parent))
        let stray = TaskItem(id: child.id, title: "Child", parentID: parent.id)
        stray.deletedAt = Date(timeIntervalSince1970: 1)
        stray.deletionRootID = child.id
        stray.deletionMembersRaw = child.id.uuidString
        let context = ModelContext(store.container)
        context.insert(stray)
        try context.save()

        XCTAssertFalse(store.restoreDeleted(taskID: parent.id))
        XCTAssertTrue(store.tasks.isEmpty)
    }

    func testTaskRestoreInspectsLiveDuplicatesAndBringsEveryDeletedReplicaBack() throws {
        let store = try makeTestStore()
        let task = try XCTUnwrap(store.create(title: "Task"))
        XCTAssertTrue(store.delete(task))
        let context = ModelContext(store.container)
        context.insert(TaskItem(id: task.id, title: "Task", updatedAt: Date(timeIntervalSince1970: 0)))
        try context.save()

        XCTAssertTrue(store.restoreDeleted(taskID: task.id))
        let rows = try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.deletedAt == nil && $0.deletionRootID == nil && $0.deletionMembersRaw.isEmpty })
    }


    // MARK: - Subtasks


    func testASubtaskIsRestoredOnlyOnceItsMainTaskIsBack() throws {
        let store = try makeTestStore()
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let child = try XCTUnwrap(store.create(title: "Child", parentID: parent.id))
        XCTAssertTrue(store.delete(child))
        XCTAssertTrue(store.delete(parent))

        XCTAssertFalse(store.restoreDeleted(taskID: child.id))
        XCTAssertEqual(store.lastErrorMessage, "Restore its main task first; this subtask returns to it.")
        XCTAssertTrue(store.tasks.isEmpty, "never a stray top-level row")

        XCTAssertTrue(store.restoreDeleted(taskID: parent.id))
        XCTAssertTrue(store.restoreDeleted(taskID: child.id))
        XCTAssertEqual(store.subtasks(of: parent.id).map(\.id), [child.id])
    }
}
