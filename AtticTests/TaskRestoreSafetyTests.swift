import SwiftData
import XCTest
@testable import Attic

/// Task restores are complete or refused, a subtask returns only to a live
/// main task, and a purge removes only a delete that is whole and agreed
/// (data review findings 5 and 6, re-review items 2 and 6).
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

    func testTaskRestoreIsRefusedWhileALiveDuplicateDivergesAndProceedsOnceItAgrees() throws {
        let store = try makeTestStore()
        let task = try XCTUnwrap(store.create(title: "Task"))
        XCTAssertTrue(store.setTags(["home"], for: task))
        XCTAssertTrue(store.delete(task))
        let context = ModelContext(store.container)
        let taskID = task.id
        let deleted = try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first)
        // A late copy from another device that the delete never reached, and
        // that was renamed there: identical to the deleted row but for its
        // title.
        let live = TaskItem(id: task.id, title: "Task, renamed elsewhere", status: deleted.status,
                            priority: deleted.priority, createdAt: deleted.createdAt,
                            updatedAt: Date(timeIntervalSince1970: 0), completedAt: deleted.completedAt,
                            manualOrder: deleted.manualOrder, parentID: deleted.parentID)
        live.tagsRaw = deleted.tagsRaw
        live.dueDayRaw = deleted.dueDayRaw
        live.imageReferencesData = deleted.imageReferencesData
        live.removedAttachmentsData = deleted.removedAttachmentsData
        live.doneLoggedAt = deleted.doneLoggedAt
        context.insert(live)
        try context.save()

        XCTAssertFalse(store.restoreDeleted(taskID: task.id))
        XCTAssertEqual(store.lastErrorMessage,
                       "Another copy of this task changed after it was deleted, so it can’t be restored safely. Refresh and try again.")
        var rows = try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.filter { $0.deletedAt != nil }.map(\.title), ["Task"], "the deleted copy is untouched")
        XCTAssertEqual(rows.filter { $0.deletedAt == nil }.map(\.title), ["Task, renamed elsewhere"],
                       "the live copy is untouched")
        XCTAssertTrue(rows.first { $0.deletedAt != nil }?.deletionRootID == task.id)

        // Once the copies hold the same task, the restore brings every
        // deleted replica back.
        live.title = "Task"
        try context.save()
        XCTAssertTrue(store.restoreDeleted(taskID: task.id))
        rows = try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.deletedAt == nil && $0.deletionRootID == nil && $0.deletionMembersRaw.isEmpty })
        XCTAssertEqual(store.tasks.map(\.title), ["Task"])
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
