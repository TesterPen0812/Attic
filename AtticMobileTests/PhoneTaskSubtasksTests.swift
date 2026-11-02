import Foundation
import SwiftData
import XCTest
@testable import AtticMobile

@MainActor
final class PhoneTaskSubtasksTests: XCTestCase {
    private func database() throws -> ModelContainer {
        try PersistenceController.makeContainer(inMemory: true)
    }

    private func seed(_ tasks: [TaskItem], in database: ModelContainer) throws {
        let context = ModelContext(database)
        tasks.forEach(context.insert)
        try context.save()
    }

    func testAddingAndEditingStepsPersistsCanonicalOrderingAcrossFreshReaders() throws {
        let database = try database()
        let root = try PhoneLibrary(container: database).createTask(title: "  Launch   app ")
        let actions = PhoneTaskSubtasks(container: database)
        XCTAssertEqual(try actions.subtasks(of: root.id), [])

        let first = try actions.addSubtask(to: root.id, title: "  Design   screen ")
        let second = try actions.addSubtask(to: root.id, title: "Build screen")
        let third = try actions.addSubtask(to: root.id, title: "Test screen")
        XCTAssertEqual(first.title, "Design screen")
        XCTAssertEqual(try actions.subtasks(of: root.id).map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(try PhoneTaskSubtasks(container: database).subtasks(of: root.id).count, 3)

        let edited = try actions.editSubtask(id: second.id, title: "  Build   screens ")
        XCTAssertEqual(edited.title, "Build screens")
        let read = ModelContext(database)
        let rows = try read.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(rows.first(where: { $0.id == second.id })?.title, "Build screens")
        XCTAssertEqual(rows.first(where: { $0.id == first.id })?.parentID, root.id)
        XCTAssertTrue(rows.filter { $0.parentID == root.id }.allSatisfy { $0.listOrderVersion == TaskItem.currentListOrderVersion })
    }

    func testToggleReordersByCompletionAndRestoresOriginalActiveStatus() throws {
        let database = try database()
        let root = try PhoneLibrary(container: database).createTask(title: "Trip")
        let actions = PhoneTaskSubtasks(container: database)
        let first = try actions.addSubtask(to: root.id, title: "Train")
        let second = try actions.addSubtask(to: root.id, title: "Hotel")
        let third = try actions.addSubtask(to: root.id, title: "Tickets")
        let seedContext = ModelContext(database)
        let original = try XCTUnwrap(seedContext.fetch(FetchDescriptor<TaskItem>()).first { $0.id == second.id })
        original.status = .inProgress
        try seedContext.save()

        let done = try actions.toggleSubtask(id: second.id)
        XCTAssertTrue(done.isDone)
        XCTAssertNotNil(done.completedAt)
        XCTAssertEqual(try actions.subtasks(of: root.id).map(\.id), [first.id, third.id, second.id])
        XCTAssertEqual(try actions.toggleSubtask(id: first.id).status, .done)
        XCTAssertEqual(try actions.subtasks(of: root.id).map(\.id), [third.id, first.id, second.id])

        let reopened = try actions.toggleSubtask(id: second.id)
        XCTAssertEqual(reopened.status, .inProgress)
        XCTAssertNil(reopened.completedAt)
        XCTAssertEqual(try actions.subtasks(of: root.id).map(\.id), [second.id, third.id, first.id])
        let persistence = ModelContext(database)
        let stored = try XCTUnwrap(persistence.fetch(FetchDescriptor<TaskItem>()).first { $0.id == second.id })
        XCTAssertNil(stored.completedFromRaw)
        XCTAssertNil(stored.completedFromOrder)
    }

    func testReorderOnlyWithinCompletionGroupAndRejectStalePositions() throws {
        let database = try database()
        let root = try PhoneLibrary(container: database).createTask(title: "Group")
        let actions = PhoneTaskSubtasks(container: database)
        let a = try actions.addSubtask(to: root.id, title: "A")
        let b = try actions.addSubtask(to: root.id, title: "B")
        let c = try actions.addSubtask(to: root.id, title: "C")
        XCTAssertEqual(try actions.reorderSubtask(id: c.id, toIndex: 0).map(\.id), [c.id, a.id, b.id])
        XCTAssertEqual(try PhoneTaskSubtasks(container: database).subtasks(of: root.id).map(\.id), [c.id, a.id, b.id])
        XCTAssertThrowsError(try actions.reorderSubtask(id: a.id, toIndex: 3)) {
            XCTAssertEqual($0 as? PhoneTaskSubtasks.Failure, .invalidOrder)
        }
        _ = try actions.toggleSubtask(id: a.id)
        _ = try actions.toggleSubtask(id: b.id)
        XCTAssertEqual(try actions.reorderSubtask(id: b.id, toIndex: 0).map(\.id), [c.id, b.id, a.id])
        XCTAssertThrowsError(try actions.reorderSubtask(id: b.id, toIndex: 2)) {
            XCTAssertEqual($0 as? PhoneTaskSubtasks.Failure, .invalidOrder)
        }
        XCTAssertEqual(try actions.subtasks(of: root.id).map(\.id), [c.id, b.id, a.id])
    }

    func testRejectsMissingNestedCompletedAndInactiveParentsWithoutCreatingAnything() throws {
        let database = try database()
        let actions = PhoneTaskSubtasks(container: database)
        let library = PhoneLibrary(container: database)
        let parent = try library.createTask(title: "Root")
        let child = try actions.addSubtask(to: parent.id, title: "Child")
        let completed = try library.createTask(title: "Done", status: .done)
        let staged = TaskItem(title: "Deleted")
        staged.deletedAt = Date()
        try seed([staged], in: database)

        XCTAssertThrowsError(try actions.addSubtask(to: UUID(), title: "Missing"))
        XCTAssertThrowsError(try actions.addSubtask(to: child.id, title: "Nested")) {
            XCTAssertEqual($0 as? PhoneTaskSubtasks.Failure, .notMainTask)
        }
        XCTAssertThrowsError(try actions.addSubtask(to: completed.id, title: "Late")) {
            XCTAssertEqual($0 as? PhoneTaskSubtasks.Failure, .parentCompleted)
        }
        XCTAssertThrowsError(try actions.addSubtask(to: staged.id, title: "Restored?")) {
            XCTAssertEqual($0 as? PhoneTaskSubtasks.Failure, .inactiveTask)
        }
        XCTAssertThrowsError(try actions.addSubtask(to: parent.id, title: " \t ")) {
            XCTAssertEqual($0 as? PhoneTaskSubtasks.Failure, .emptyTitle)
        }
        XCTAssertThrowsError(try actions.editSubtask(id: parent.id, title: "Root is not a step"))
        XCTAssertEqual(try actions.subtasks(of: parent.id).map(\.id), [child.id])
    }

    func testDoneParentBlocksChildReopeningButAllowsFinishingItsLastOpenChild() throws {
        let database = try database()
        let library = PhoneLibrary(container: database)
        let root = try library.createTask(title: "Parent")
        let actions = PhoneTaskSubtasks(container: database)
        let child = try actions.addSubtask(to: root.id, title: "Step")
        _ = try actions.toggleSubtask(id: child.id)
        try library.updateTask(id: root.id, patch: .init(title: nil, priority: nil, status: .done))
        XCTAssertThrowsError(try actions.toggleSubtask(id: child.id)) {
            XCTAssertEqual($0 as? PhoneTaskSubtasks.Failure, .parentCompleted)
        }
        XCTAssertEqual(try actions.subtasks(of: root.id).first?.status, .done)
    }

    func testReplicaMutationsUpdateEveryCopyAndConflictingParentOrTombstoneFailsClosed() throws {
        let database = try database()
        let parent = try PhoneLibrary(container: database).createTask(title: "Parent")
        let actions = PhoneTaskSubtasks(container: database)
        let child = try actions.addSubtask(to: parent.id, title: "First")
        let read = ModelContext(database)
        let copy = TaskItem(id: child.id, title: "First", createdAt: child.createdAt,
                            updatedAt: child.updatedAt, manualOrder: child.manualOrder, parentID: parent.id)
        read.insert(copy)
        try read.save()
        _ = try actions.editSubtask(id: child.id, title: "Second")
        let check = ModelContext(database)
        XCTAssertEqual(try check.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == child.id }.map(\.title), ["Second", "Second"])

        let changed = try XCTUnwrap(check.fetch(FetchDescriptor<TaskItem>()).first { $0.id == child.id })
        changed.deletedAt = Date()
        try check.save()
        XCTAssertThrowsError(try actions.toggleSubtask(id: child.id)) {
            XCTAssertEqual($0 as? PhoneTaskSubtasks.Failure, .conflictingReplicas)
        }
        XCTAssertThrowsError(try actions.deleteSubtask(id: child.id))
        let verification = ModelContext(database)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == child.id && $0.status == .todo }.count, 2)
    }

    func testDeletionSoftHidesOnlyChildAndPreservesAllItsCopies() throws {
        let database = try database()
        let root = try PhoneLibrary(container: database).createTask(title: "Parent")
        let actions = PhoneTaskSubtasks(container: database)
        let child = try actions.addSubtask(to: root.id, title: "Step")
        try actions.deleteSubtask(id: child.id)
        XCTAssertEqual(try actions.subtasks(of: root.id), [])
        XCTAssertThrowsError(try actions.editSubtask(id: child.id, title: "Resurrect")) {
            XCTAssertEqual($0 as? PhoneTaskSubtasks.Failure, .inactiveTask)
        }
        let reader = ModelContext(database)
        let tasks = try reader.fetch(FetchDescriptor<TaskItem>())
        let tombstone = try XCTUnwrap(tasks.first(where: { $0.id == child.id }))
        XCTAssertNotNil(tombstone.deletedAt)
        XCTAssertEqual(tombstone.deletionRootID, child.id)
        XCTAssertEqual(tombstone.deletionMembers, [child.id])
        XCTAssertNil(tasks.first { $0.id == root.id }?.deletedAt)
    }

    func testInjectedSaveFailureRollsBackReorderAndKeepsUnrelatedContext() throws {
        enum Injected: Error { case failure }
        let database = try database()
        let parent = try PhoneLibrary(container: database).createTask(title: "Parent")
        let basic = PhoneTaskSubtasks(container: database)
        let first = try basic.addSubtask(to: parent.id, title: "One")
        let second = try basic.addSubtask(to: parent.id, title: "Two")
        let unrelated = ModelContext(database)
        unrelated.autosaveEnabled = false
        unrelated.insert(TaskItem(title: "Unsaved"))
        var staged: ModelContext?
        var fail = true
        var saves = 0
        let throwing = PhoneTaskSubtasks(container: database, save: { context in
            saves += 1
            staged = context
            if fail { throw Injected.failure }
            try context.save()
        })
        XCTAssertThrowsError(try throwing.reorderSubtask(id: second.id, toIndex: 0)) {
            XCTAssertTrue($0 is Injected)
        }
        XCTAssertEqual(staged?.hasChanges, false)
        XCTAssertTrue(unrelated.hasChanges)
        XCTAssertEqual(try basic.subtasks(of: parent.id).map(\.id), [first.id, second.id])
        fail = false
        XCTAssertEqual(try throwing.reorderSubtask(id: second.id, toIndex: 0).map(\.id), [second.id, first.id])
        XCTAssertEqual(saves, 2)
    }

    func testTaskNoteIsLazyAndCreationIsAtomicIdempotentAndReadable() throws {
        let database = try database()
        let root = try PhoneLibrary(container: database).createTask(title: "A task")
        var saveCount = 0
        let actions = PhoneTaskSubtasks(container: database, save: { context in
            saveCount += 1
            try context.save()
        })
        XCTAssertNil(try actions.loadTaskNote(taskID: root.id))
        XCTAssertEqual(saveCount, 0)
        let created = try actions.createTaskNoteIfNeeded(taskID: root.id, initialWriting: "Hello\nworld")
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(created.taskID, root.id)
        XCTAssertEqual(created.title, root.title)
        XCTAssertEqual(created.body, "Hello\nworld")
        XCTAssertEqual(created.revision, 1)
        let bytes = try XCTUnwrap(created.content)
        guard case let .editable(document) = NoteContentCodec.decode(bytes) else {
            return XCTFail("Task note did not encode as a native document")
        }
        XCTAssertEqual(document.requires, ["taskNote"])
        XCTAssertEqual(document.blocks.map(\.text), ["A task", "Hello", "world"])
        XCTAssertEqual(try actions.createTaskNoteIfNeeded(taskID: root.id).content, bytes)
        XCTAssertThrowsError(try actions.createTaskNoteIfNeeded(taskID: root.id, initialWriting: "Different draft")) {
            XCTAssertEqual($0 as? PhoneTaskSubtasks.Failure, .existingWriting)
        }
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(try PhoneTaskSubtasks(container: database).loadTaskNote(taskID: root.id)?.content, bytes)
        let reader = ModelContext(database)
        let links = try reader.fetch(FetchDescriptor<TaskNoteAssociation>())
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].taskID, root.id)
        XCTAssertEqual(links[0].noteID, created.id)
        XCTAssertEqual(try PhoneLibrary(container: database).notes().map(\.id), [created.id])
    }

    func testOpaqueNoteBytesSurviveTaskDeletionAndAreNeverDecodedAndRewritten() throws {
        let database = try database()
        let root = try PhoneLibrary(container: database).createTask(title: "Parent")
        let actions = PhoneTaskSubtasks(container: database)
        let original = try actions.createTaskNoteIfNeeded(taskID: root.id)
        let customBytes = Data(#"{ "format": 99, "requires": ["future-feature"], "blocks": [{ "kind": "unknown", "payload": "⛵" }] }"#.utf8)
        let writer = ModelContext(database)
        let note = try XCTUnwrap(writer.fetch(FetchDescriptor<NoteItem>()).first { $0.id == original.id })
        note.content = customBytes
        note.contentFormat = 99
        note.contentFingerprint = nil
        note.revision = 42
        try writer.save()
        XCTAssertEqual(try actions.loadTaskNote(taskID: root.id)?.content, customBytes)
        XCTAssertEqual(try actions.createTaskNoteIfNeeded(taskID: root.id).content, customBytes)

        // A task lifecycle writer soft-deletes the task: the note must remain byte-identical.
        let lifecycle = ModelContext(database)
        let task = try XCTUnwrap(lifecycle.fetch(FetchDescriptor<TaskItem>()).first { $0.id == root.id })
        task.deletedAt = Date(timeIntervalSince1970: 9_876)
        try lifecycle.save()
        XCTAssertThrowsError(try actions.createTaskNoteIfNeeded(taskID: root.id)) {
            XCTAssertEqual($0 as? PhoneTaskSubtasks.Failure, .inactiveTask)
        }
        let reopened = ModelContext(database)
        let preserved = try XCTUnwrap(reopened.fetch(FetchDescriptor<NoteItem>()).first { $0.id == original.id })
        XCTAssertEqual(preserved.content, customBytes)
        XCTAssertEqual(preserved.contentFormat, 99)
        XCTAssertNil(preserved.contentFingerprint)
        XCTAssertEqual(preserved.revision, 42)
        XCTAssertEqual(preserved.taskID, root.id)
        XCTAssertNil(preserved.deletedAt)
    }

    func testFailedTaskNoteCreationRollsBackBothRowsAndRetryCreatesOnePair() throws {
        enum Injected: Error { case unavailable }
        let database = try database()
        let root = try PhoneLibrary(container: database).createTask(title: "Draft")
        var attempts = 0
        var shouldFail = true
        var staged: ModelContext?
        let actions = PhoneTaskSubtasks(container: database, save: { context in
            attempts += 1
            staged = context
            if shouldFail {
                XCTAssertEqual(try context.fetch(FetchDescriptor<NoteItem>()).count, 1)
                XCTAssertEqual(try context.fetch(FetchDescriptor<TaskNoteAssociation>()).count, 1)
                throw Injected.unavailable
            }
            try context.save()
        })
        XCTAssertThrowsError(try actions.createTaskNoteIfNeeded(taskID: root.id, initialWriting: "Draft writing")) {
            XCTAssertTrue($0 is Injected)
        }
        XCTAssertFalse(try XCTUnwrap(staged).hasChanges)
        let firstRead = ModelContext(database)
        XCTAssertTrue(try firstRead.fetch(FetchDescriptor<NoteItem>()).isEmpty)
        XCTAssertTrue(try firstRead.fetch(FetchDescriptor<TaskNoteAssociation>()).isEmpty)
        shouldFail = false
        let created = try actions.createTaskNoteIfNeeded(taskID: root.id, initialWriting: "Draft writing")
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(created.body, "Draft writing")
        XCTAssertEqual(try ModelContext(database).fetch(FetchDescriptor<TaskNoteAssociation>()).count, 1)
    }

    func testDeletingSubtaskNeverCascadesToItsOwnNote() throws {
        let database = try database()
        let root = try PhoneLibrary(container: database).createTask(title: "Root")
        let actions = PhoneTaskSubtasks(container: database)
        let child = try actions.addSubtask(to: root.id, title: "Child")
        let note = try actions.createTaskNoteIfNeeded(taskID: child.id, initialWriting: "Keep these bytes")
        try actions.deleteSubtask(id: child.id)
        XCTAssertEqual(try actions.subtasks(of: root.id), [])
        let reader = ModelContext(database)
        let saved = try XCTUnwrap(reader.fetch(FetchDescriptor<NoteItem>()).first { $0.id == note.id })
        XCTAssertNil(saved.deletedAt)
        XCTAssertEqual(saved.content, note.content)
        XCTAssertEqual(saved.revisionID, note.revisionID)
        XCTAssertEqual(saved.taskID, child.id)
        XCTAssertEqual(try reader.fetch(FetchDescriptor<TaskNoteAssociation>()).count, 1)
    }

    func testStaleTaskNoteLinkGenerationIsRejectedWithoutWriting() throws {
        let database = try database()
        let root = try PhoneLibrary(container: database).createTask(title: "Root")
        let actions = PhoneTaskSubtasks(container: database)
        let note = try actions.createTaskNoteIfNeeded(taskID: root.id, initialWriting: "Keep")
        let writer = ModelContext(database)
        let link = try XCTUnwrap(writer.fetch(FetchDescriptor<TaskNoteAssociation>()).first)
        link.taskGeneration += 1
        try writer.save()
        XCTAssertThrowsError(try actions.loadTaskNote(taskID: root.id)) {
            XCTAssertEqual($0 as? PhoneTaskSubtasks.Failure, .conflictingNote)
        }
        XCTAssertThrowsError(try actions.createTaskNoteIfNeeded(taskID: root.id))
        let check = ModelContext(database)
        XCTAssertEqual(try check.fetch(FetchDescriptor<NoteItem>()).count, 1)
        XCTAssertEqual(try XCTUnwrap(check.fetch(FetchDescriptor<NoteItem>()).first).content, note.content)
    }

    func testTaskNoteConflictsDoNotCreateASecondNoteOrChangeExistingBytes() throws {
        let database = try database()
        let root = try PhoneLibrary(container: database).createTask(title: "Parent")
        let actions = PhoneTaskSubtasks(container: database)
        let original = try actions.createTaskNoteIfNeeded(taskID: root.id, initialWriting: "Protected")
        let writer = ModelContext(database)
        let second = NoteItem(title: "Conflicting")
        second.taskID = root.id
        writer.insert(second)
        try writer.save()
        XCTAssertThrowsError(try actions.loadTaskNote(taskID: root.id)) {
            XCTAssertEqual($0 as? PhoneTaskSubtasks.Failure, .conflictingNote)
        }
        XCTAssertThrowsError(try actions.createTaskNoteIfNeeded(taskID: root.id))
        let verify = ModelContext(database)
        XCTAssertEqual(try verify.fetch(FetchDescriptor<NoteItem>()).count, 2)
        XCTAssertEqual(try XCTUnwrap(verify.fetch(FetchDescriptor<NoteItem>()).first { $0.id == original.id }).content, original.content)
    }

    func testDiskReopenPreservesSubtasksAndNativeNoteExactly() throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        let reference = try autoreleasepool { () throws -> (UUID, UUID, UUID, Data?) in
            let database = try PersistenceController.makeContainer(storeDirectory: location)
            let task = try PhoneLibrary(container: database).createTask(title: "On disk")
            let store = PhoneTaskSubtasks(container: database)
            let child = try store.addSubtask(to: task.id, title: "Step")
            let note = try store.createTaskNoteIfNeeded(taskID: task.id, initialWriting: "A line")
            return (task.id, child.id, note.id, note.content)
        }
        let reloaded = PhoneTaskSubtasks(container: try PersistenceController.makeContainer(storeDirectory: location))
        XCTAssertEqual(try reloaded.subtasks(of: reference.0).map(\.id), [reference.1])
        XCTAssertEqual(try reloaded.loadTaskNote(taskID: reference.0)?.id, reference.2)
        XCTAssertEqual(try reloaded.loadTaskNote(taskID: reference.0)?.content, reference.3)
    }
}
