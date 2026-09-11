import XCTest
import SwiftData
@testable import Attic

@MainActor
final class SubtaskTests: XCTestCase {
    private func makeStore() throws -> TaskStore {
        TaskStore(container: try PersistenceController.makeContainer(inMemory: true))
    }

    func testExistingOnDiskTaskMigratesWithoutLosingFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticSubtaskMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.store")
        let id = UUID()
        try seedLegacyStore(at: url, id: id)
        let container = try ModelContainer(for: TaskItem.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let store = TaskStore(container: container)
        let task = try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(task.id, id)
        XCTAssertEqual(task.title, "Existing task")
        XCTAssertEqual(task.status, .inProgress)
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.manualOrder, 1_024)
        XCTAssertEqual(task.createdAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(task.updatedAt, Date(timeIntervalSince1970: 200))
        XCTAssertNil(task.parentID)
        let child = try XCTUnwrap(store.create(title: "New step", parentID: id))
        let reopened = TaskStore(container: container)
        XCTAssertEqual(reopened.subtasks(of: id).map(\.id), [child.id])
    }

    private func seedLegacyStore(at url: URL, id: UUID) throws {
        let container = try ModelContainer(for: BeforeSubtasks.TaskItem.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let context = ModelContext(container)
        let task = BeforeSubtasks.TaskItem()
        task.id = id
        task.title = "Existing task"
        task.statusRaw = TaskStatus.inProgress.rawValue
        task.priorityRaw = TaskPriority.high.rawValue
        task.manualOrder = 1_024
        task.createdAt = Date(timeIntervalSince1970: 100)
        task.updatedAt = Date(timeIntervalSince1970: 200)
        context.insert(task)
        try context.save()
    }

    func testSubtasksPersistAcrossFreshContextsAndCountOnlyTheParent() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = TaskStore(container: container)
        let parent = try XCTUnwrap(store.create(title: "Trip", status: .inProgress))
        let child = try XCTUnwrap(store.create(title: "  Book   hotel ", parentID: parent.id))
        XCTAssertEqual(child.title, "Book hotel")
        let fresh = TaskStore(container: container)
        XCTAssertEqual(fresh.subtasks(of: parent.id).map(\.id), [child.id])
        XCTAssertEqual(fresh.snapshot(for: .tasks).activeCount, 1)
        XCTAssertEqual(fresh.snapshot(for: .tasks).visibleCount, 1)
        XCTAssertEqual(fresh.snapshot(for: .tasks).sections.flatMap(\.tasks).map(\.id), [parent.id])
    }

    func testCompletionIsManualAndCompletedStepsStayUnderParent() throws {
        let store = try makeStore()
        let parent = try XCTUnwrap(store.create(title: "Trip"))
        let child = try XCTUnwrap(store.create(title: "Hotel", parentID: parent.id))
        XCTAssertFalse(store.markDone(parent))
        XCTAssertEqual(parent.status, .todo)
        XCTAssertTrue(store.markDone(child))
        XCTAssertEqual(parent.status, .todo)
        XCTAssertEqual(store.subtasks(of: parent.id).first?.status, .done)
        XCTAssertFalse(store.snapshot(for: .tasks).sections.contains { $0.status == .done })
        XCTAssertTrue(store.markDone(parent))
        XCTAssertFalse(store.setStatus(.todo, for: child))
        XCTAssertTrue(store.setStatus(.todo, for: parent))
        XCTAssertTrue(store.setStatus(.todo, for: child))
    }

    func testRejectsMissingNestedAndCompletedParents() throws {
        let store = try makeStore()
        XCTAssertNil(store.create(title: "Missing", parentID: UUID()))
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let child = try XCTUnwrap(store.create(title: "Child", parentID: parent.id))
        XCTAssertNil(store.create(title: "Grandchild", parentID: child.id))
        XCTAssertTrue(store.markDone(child))
        XCTAssertTrue(store.markDone(parent))
        XCTAssertNil(store.create(title: "New child", parentID: parent.id))
        XCTAssertEqual(store.tasks.count, 2)
    }

    func testMovingParentKeepsFamilyTogetherAcrossScopes() throws {
        let store = try makeStore()
        let parent = try XCTUnwrap(store.create(title: "Idea", status: .backlog))
        let child = try XCTUnwrap(store.create(title: "Explore", parentID: parent.id))
        XCTAssertEqual(store.snapshot(for: .backlog).visibleCount, 1)
        XCTAssertEqual(store.snapshot(for: .tasks).visibleCount, 0)
        XCTAssertTrue(store.setStatus(.todo, for: parent))
        XCTAssertEqual(store.snapshot(for: .tasks).visibleCount, 1)
        XCTAssertEqual(store.subtasks(of: parent.id).map(\.id), [child.id])
    }

    func testDeletingChildPreservesParentAndDeletingParentDeletesFamilyOnly() throws {
        let store = try makeStore()
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let child = try XCTUnwrap(store.create(title: "Child", parentID: parent.id))
        let sibling = try XCTUnwrap(store.create(title: "Sibling", parentID: parent.id))
        let unrelated = try XCTUnwrap(store.create(title: "Unrelated"))
        XCTAssertTrue(store.delete(child))
        XCTAssertEqual(store.subtasks(of: parent.id).map(\.id), [sibling.id])
        XCTAssertTrue(store.delete(parent))
        store.refresh()
        XCTAssertEqual(store.tasks.map(\.id), [unrelated.id])
    }

    func testFailedFamilyDeletionAndChildCreationRollBack() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var fail = false
        let store = TaskStore(container: container, persist: { context in
            if fail { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        })
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let child = try XCTUnwrap(store.create(title: "Child", parentID: parent.id))
        fail = true
        XCTAssertFalse(store.delete(parent))
        XCTAssertEqual(Set(store.tasks.map(\.id)), [parent.id, child.id])
        XCTAssertNil(store.create(title: "Failed child", parentID: parent.id))
        XCTAssertEqual(store.tasks.count, 2)
        XCTAssertEqual(TaskStore(container: container).subtasks(of: parent.id).count, 1)
    }

    func testCleanupRetainsCompletedChildrenUntilEntireFamilyExpires() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var time = Date(timeIntervalSince1970: 1_000)
        let store = TaskStore(container: container, now: { time })
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let child = try XCTUnwrap(store.create(title: "Child", parentID: parent.id))
        XCTAssertTrue(store.markDone(child))
        let cutoff = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(store.purgeCompleted(before: cutoff), 0)
        time = Date(timeIntervalSince1970: 3_000)
        XCTAssertTrue(store.markDone(parent))
        XCTAssertEqual(store.purgeCompleted(before: cutoff), 0)
        XCTAssertEqual(store.purgeCompleted(before: Date(timeIntervalSince1970: 4_000)), 2)
        XCTAssertTrue(store.tasks.isEmpty)
    }

    func testDivergentChildPreventsParentCompletionAndCleanup() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let parent = TaskItem(title: "Parent", status: .done, completedAt: .distantPast)
        let child = TaskItem(title: "Child", status: .done, completedAt: .distantPast, parentID: parent.id)
        let duplicate = TaskItem(id: child.id, title: "Child", status: .todo, parentID: parent.id)
        [parent, child, duplicate].forEach(context.insert)
        try context.save()
        let store = TaskStore(container: container)
        XCTAssertEqual(store.purgeCompleted(before: .now), 0)
        XCTAssertTrue(store.setStatus(.todo, for: parent))
        XCTAssertFalse(store.setStatus(.done, for: parent))
        XCTAssertEqual(store.tasks.count, 2)
    }

    func testAllPhysicalChildReplicasAreUpdatedAndDeleted() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let parent = TaskItem(title: "Parent")
        let child = TaskItem(title: "Child", parentID: parent.id)
        let duplicate = TaskItem(id: child.id, title: "Old child", parentID: parent.id)
        [parent, child, duplicate].forEach(context.insert)
        try context.save()
        let store = TaskStore(container: container)
        XCTAssertTrue(store.rename(child, to: "New title"))
        let stored = try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).filter { $0.id == child.id }
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(stored.allSatisfy { $0.title == "New title" && $0.parentID == parent.id })
        XCTAssertTrue(store.delete(parent))
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).isEmpty)
    }

    func testConflictingParentLinksBlockFamilyDeletion() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let parent = TaskItem(title: "Parent")
        let other = TaskItem(title: "Other")
        let child = TaskItem(title: "Child", parentID: parent.id)
        let duplicate = TaskItem(id: child.id, title: "Child", parentID: other.id)
        [parent, other, child, duplicate].forEach(context.insert)
        try context.save()
        let store = TaskStore(container: container)
        XCTAssertFalse(store.delete(parent))
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).count, 4)
    }

    func testOrphanedAndCyclicImportsRemainVisible() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let orphan = TaskItem(title: "Orphan", parentID: UUID())
        let first = TaskItem(title: "First")
        let second = TaskItem(title: "Second", parentID: first.id)
        first.parentID = second.id
        [orphan, first, second].forEach(context.insert)
        try context.save()
        let store = TaskStore(container: container)
        XCTAssertEqual(store.snapshot(for: .tasks).visibleCount, 3)
        XCTAssertFalse(store.delete(first), "A cycle must not turn one-row deletion into deleting its peer")
    }

    func testCrossFamilyDropsDoNotMoveChildren() throws {
        let store = try makeStore()
        let first = try XCTUnwrap(store.create(title: "First"))
        let second = try XCTUnwrap(store.create(title: "Second", status: .inProgress))
        let child = try XCTUnwrap(store.create(title: "Child", parentID: first.id))
        XCTAssertFalse(store.drop(taskID: child.id, onto: second.id))
        XCTAssertEqual(child.parentID, first.id)
        XCTAssertEqual(child.status, .todo)
        XCTAssertFalse(store.reorder(taskID: child.id, relativeTo: first.id))
    }

    func testSiblingReorderPersistsWithoutReorderingMainTasks() throws {
        let store = try makeStore()
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let other = try XCTUnwrap(store.create(title: "Other"))
        let first = try XCTUnwrap(store.create(title: "First", parentID: parent.id))
        let second = try XCTUnwrap(store.create(title: "Second", parentID: parent.id))
        let third = try XCTUnwrap(store.create(title: "Third", parentID: parent.id))
        let roots = store.snapshot(for: .tasks).sections.flatMap(\.tasks).map(\.id)
        XCTAssertEqual(Set(roots), [parent.id, other.id])
        XCTAssertTrue(store.reorder(taskID: third.id, relativeTo: first.id))
        XCTAssertEqual(store.subtasks(of: parent.id).map(\.id), [third.id, first.id, second.id])
        store.refresh()
        XCTAssertEqual(store.subtasks(of: parent.id).map(\.id), [third.id, first.id, second.id])
        XCTAssertEqual(store.snapshot(for: .tasks).sections.flatMap(\.tasks).map(\.id), roots)
        XCTAssertTrue(store.markDone(second))
        XCTAssertEqual(store.subtasks(of: parent.id).map(\.id), [third.id, first.id, second.id])
    }

    func testMCPCreateListCompleteAndDeleteFamily() throws {
        let store = try makeStore()
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let tools = AgentTaskTools(store: store)
        let result = try tools.call(name: "create_task", arguments: ["title": "Child", "parent_id": parent.id.uuidString])
        XCTAssertTrue(result.contains("parent_id"))
        let child = try XCTUnwrap(store.subtasks(of: parent.id).first)
        let listed = try tools.call(name: "list_tasks", arguments: ["parent_id": parent.id.uuidString])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(listed.utf8)) as? [String: Any])
        XCTAssertEqual(payload["count"] as? Int, 1)
        XCTAssertThrowsError(try tools.call(name: "update_task", arguments: ["id": parent.id.uuidString, "status": "done"]))
        _ = try tools.call(name: "update_task", arguments: ["id": child.id.uuidString, "status": "done"])
        XCTAssertEqual(parent.status, .todo)
        _ = try tools.call(name: "delete_task", arguments: ["id": parent.id.uuidString])
        XCTAssertTrue(store.tasks.isEmpty)
    }

    func testMCPRejectsMalformedParentBeforeCreatingAnything() throws {
        let store = try makeStore()
        let tools = AgentTaskTools(store: store)
        for invalid: Any in ["invalid", 42, UUID().uuidString, NSNull()] {
            XCTAssertThrowsError(try tools.call(name: "create_task", arguments: ["title": "Child", "parent_id": invalid]))
        }
        XCTAssertTrue(store.tasks.isEmpty)
    }

    func testSubtaskDraftSurvivesCollapseAndLocksOnlyTaskSections() throws {
        let state = PanelUIState()
        let id = UUID()
        state.subtaskDrafts[id] = "Unfinished thought"
        state.expandedTaskIDs.insert(id)
        state.expandedTaskIDs.remove(id)
        XCTAssertEqual(state.subtaskDrafts[id], "Unfinished thought")
        XCTAssertTrue(state.interactionLockReasons.contains(.subtaskComposer))
        state.selectSection(.notes)
        XCTAssertFalse(state.interactionLockReasons.contains(.subtaskComposer))
        state.reconcileTaskIDs([])
        XCTAssertTrue(state.subtaskDrafts.isEmpty)
    }

    func testFamilyDeleteConfirmationPreventsAutoHideAndReconcilesRemoval() {
        let state = PanelUIState()
        let id = UUID()
        state.confirmingTaskDeletionID = id
        XCTAssertTrue(state.interactionLockReasons.contains(.taskConfirmation))
        state.reconcileTaskIDs([id])
        XCTAssertTrue(state.isInteractionLocked)
        state.reconcileTaskIDs([])
        XCTAssertFalse(state.isInteractionLocked)
    }
}

/// The shipping task schema before parentID was added. Nested qualification
/// keeps the Swift name distinct while SwiftData's entity remains TaskItem.
private enum BeforeSubtasks {
    @Model final class TaskItem {
        var id: UUID = UUID()
        var title: String = ""
        var statusRaw: String = "todo"
        var priorityRaw: String = "none"
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var completedAt: Date? = nil
        var manualOrder: Int64? = nil
        init() {}
    }
}
