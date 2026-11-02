import Foundation
import SwiftData
import XCTest
@testable import AtticMobile

@MainActor
final class TaskStoreMobileTests: XCTestCase {
    func testMobileUsesSharedTaskSemanticsWithoutCloudKitInTests() throws {
        XCTAssertNil(PersistenceController.makeConfiguration(inMemory: true).cloudKitContainerIdentifier)
        let store = PhoneLibrary(container: try PersistenceController.makeContainer(inMemory: true))
        let task = try store.createTask(title: "  From   iPhone ", priority: .high, status: .backlog)
        XCTAssertEqual(task.title, "From iPhone")
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.status, .backlog)
        try store.updateTask(id: task.id, patch: .init(title: nil, priority: nil, status: .todo))
        XCTAssertEqual(try store.tasks().first?.status, .todo)
        XCTAssertThrowsError(try store.createTask(title: " \n "))
        XCTAssertThrowsError(try store.updateTask(id: task.id, patch: .init(title: " \t", priority: nil, status: nil)))
        XCTAssertEqual(try store.tasks().map(\.title), ["From iPhone"])
    }

    func testEditorPatchIncludesOnlyFieldsChangedByTheUser() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = PhoneLibrary(container: container)
        let task = try store.createTask(title: "Original", priority: .low)
        let baseline = MobileTaskEditBaseline(title: task.title, priority: task.priority, status: task.status)
        let patch = baseline.patch(title: "Renamed", priority: .low, status: .todo)
        XCTAssertEqual(patch.title, "Renamed")
        XCTAssertNil(patch.priority)
        XCTAssertNil(patch.status)

        let other = ModelContext(container)
        let changed = try XCTUnwrap(other.fetch(FetchDescriptor<TaskItem>()).first)
        changed.priority = .high
        changed.status = .inProgress
        let older = TaskItem(id: task.id, title: "Replica", status: .backlog, priority: .medium,
                             createdAt: task.createdAt.addingTimeInterval(-10))
        older.tags = ["Older"]
        other.insert(older)
        try other.save()

        let result = try store.updateTask(id: task.id, patch: patch)
        XCTAssertEqual(result.priority, .high)
        XCTAssertEqual(result.status, .inProgress)
        XCTAssertEqual(try store.tasks().map(\.id), [task.id])
        let verificationContext = ModelContext(container)
        let rows = try verificationContext.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(rows.map(\.title), ["Renamed", "Renamed"])
        XCTAssertEqual(Set(rows.map(\.priority)), [.high, .medium])
        XCTAssertEqual(Set(rows.map(\.status)), [.inProgress, .backlog])
        XCTAssertEqual(rows.first { $0.status == .backlog }?.tags, ["older"])
    }

    func testIsolatedDiskStoreReopensWithoutSavingOrRollingBackAnotherContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ids = try autoreleasepool { () throws -> [UUID] in
            let container = try PersistenceController.makeContainer(storeDirectory: root)
            let unrelated = ModelContext(container)
            unrelated.autosaveEnabled = false
            unrelated.insert(TaskItem(title: "Uncommitted draft"))
            let store = PhoneLibrary(container: container)
            let task = try store.createTask(title: "Kept")
            let note = try store.createNote(title: "Stored", body: "Line 1\nLine 2")
            XCTAssertTrue(unrelated.hasChanges)
            return [task.id, note.id]
        }
        let reopened = PhoneLibrary(container: try PersistenceController.makeContainer(storeDirectory: root))
        XCTAssertEqual(try reopened.tasks().map(\.id), [ids[0]])
        XCTAssertEqual(try reopened.notes().map(\.id), [ids[1]])
        XCTAssertEqual(try reopened.openNote(id: ids[1]).note.body, "Line 1\nLine 2")
    }

    func testFailedSaveRollsBackAllReplicasAndDoesNotPoisonNextWrite() throws {
        enum Injected: Error { case save }
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let id = UUID()
        for title in ["One", "Two"] { seed.insert(TaskItem(id: id, title: title)) }
        try seed.save()
        let unrelated = ModelContext(container)
        unrelated.autosaveEnabled = false
        unrelated.insert(TaskItem(title: "Other draft"))
        var failedContext: ModelContext?
        var fail = true
        let store = PhoneLibrary(container: container, save: { context in
            if fail {
                failedContext = context
                XCTAssertEqual(try context.fetch(FetchDescriptor<TaskItem>()).map(\.title), ["Changed", "Changed"])
                throw Injected.save
            }
            try context.save()
        })
        let patch = MobileTaskEditPatch(title: "Changed", priority: .high, status: nil)
        XCTAssertThrowsError(try store.updateTask(id: id, patch: patch)) { XCTAssertTrue($0 is Injected) }
        XCTAssertEqual(failedContext?.hasChanges, false)
        XCTAssertTrue(unrelated.hasChanges)
        let verificationContext = ModelContext(container)
        let untouched = try verificationContext.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(Set(untouched.map(\.title)), ["One", "Two"])
        XCTAssertTrue(untouched.allSatisfy { $0.priority == .none })
        fail = false
        try store.updateTask(id: id, patch: patch)
        XCTAssertEqual(try store.tasks().map(\.title), ["Changed"])
    }

    func testDatedLaterMovesToNowAndReturningToLaterClearsEveryLocalClock() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = PhoneLibrary(container: container)
        let day = try XCTUnwrap(DueDay(rawValue: "2028-02-29"))
        let task = try store.createTask(title: "Leap day", status: .backlog)
        XCTAssertThrowsError(try store.updateTask(id: task.id, dueTimeMinutes: .some(60)))
        try store.updateTask(id: task.id, dueDay: .some(day), dueTimeMinutes: .some(1439))
        XCTAssertThrowsError(try store.updateTask(id: task.id, dueTimeMinutes: .some(1440)))
        XCTAssertEqual(try store.tasks(status: .todo).first?.dueTimeMinutes, 1439)
        let seed = ModelContext(container)
        let old = TaskItem(id: task.id, title: "Older", status: .backlog, createdAt: .distantPast)
        old.dueDay = day
        old.dueTimeMinutes = 0
        seed.insert(old)
        try seed.save()
        try store.updateTask(id: task.id, patch: .init(title: nil, priority: nil, status: .backlog))
        let verificationContext = ModelContext(container)
        let rows = try verificationContext.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.status == .backlog && $0.dueDayRaw == nil && $0.dueTimeMinutesRaw == nil })
        XCTAssertTrue(try store.tasks(status: .todo).isEmpty)
        XCTAssertEqual(try store.tasks(status: .backlog).map(\.id), [task.id])
    }

    func testLegacyDatedLaterListsInNowWithoutReadSideEffects() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let legacy = TaskItem(title: "Legacy", status: .backlog)
        legacy.dueDayRaw = "2028-02-29"
        seed.insert(legacy)
        try seed.save()
        let store = PhoneLibrary(container: container)
        XCTAssertEqual(try store.tasks(status: .todo).map(\.id), [legacy.id])
        let beforeEditContext = ModelContext(container)
        XCTAssertEqual(try beforeEditContext.fetch(FetchDescriptor<TaskItem>()).first?.status, .backlog)
        try store.updateTask(id: legacy.id, tags: ["#DAY"])
        let verificationContext = ModelContext(container)
        let saved = try XCTUnwrap(verificationContext.fetch(FetchDescriptor<TaskItem>()).first)
        XCTAssertEqual(saved.status, .todo)
        XCTAssertEqual(saved.dueDayRaw, "2028-02-29")
        XCTAssertEqual(saved.tags, ["day"])
    }

    func testDeletedWinnerCannotBeExposedOrResurrectedThroughOlderReplica() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let id = UUID()
        let old = TaskItem(id: id, title: "Older visible", createdAt: .distantPast)
        let deleted = TaskItem(id: id, title: "Hidden")
        deleted.deletedAt = deleted.updatedAt
        seed.insert(old); seed.insert(deleted)
        try seed.save()
        let store = PhoneLibrary(container: container)
        XCTAssertTrue(try store.tasks().isEmpty)
        XCTAssertThrowsError(try store.updateTask(id: id, tags: ["edit"])) {
            XCTAssertEqual($0 as? PhoneLibrary.Failure, .inactiveReplica)
        }
        let reader = ModelContext(container)
        let rows = try reader.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.filter { $0.deletedAt != nil }.count, 1)
        XCTAssertTrue(rows.allSatisfy { $0.tagsRaw.isEmpty })
    }
}
