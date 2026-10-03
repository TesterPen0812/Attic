import SwiftData
import XCTest
@testable import Attic

/// Soft delete and Recently Deleted across tasks, notes and canvases.
@MainActor
final class RecentlyDeletedTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        return calendar
    }()

    private func allTasks(_ container: ModelContainer) throws -> [TaskItem] {
        try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
    }

    // MARK: - Tasks

    func testDeletingATaskHidesItsFamilyEverywhereButKeepsEveryRowAndFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticSoftDelete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("brief.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("brief".utf8).write(to: source)
        let files = TaskImageFiles(rootURL: root.appendingPathComponent("storage"))
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = TaskStore(container: container, taskImageFiles: files)
        let parent = try XCTUnwrap(store.create(title: "Launch"))
        let child = try XCTUnwrap(store.create(title: "Write copy", parentID: parent.id))
        let other = try XCTUnwrap(store.create(title: "Unrelated"))
        let attached = await store.attachFiles([source], to: parent.id)
        XCTAssertTrue(attached)
        let file = try XCTUnwrap(store.task(withID: parent.id)?.attachments.first)

        XCTAssertTrue(store.delete(parent))

        XCTAssertEqual(store.tasks.map(\.id), [other.id])
        XCTAssertNil(store.task(withID: child.id))
        XCTAssertEqual(store.snapshot(for: .tasks).visibleCount, 1)
        let rows = try allTasks(container)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(Set(rows.filter { $0.deletedAt != nil }.map(\.id)), [parent.id, child.id])
        XCTAssertTrue(rows.filter { $0.deletedAt != nil }.allSatisfy { $0.deletionRootID == parent.id })
        try await Task.sleep(for: .milliseconds(200))
        let fileURL = try await files.verifiedURL(for: file)
        XCTAssertNotNil(fileURL, "files stay while the task is in Recently Deleted")
        // A fresh store (a relaunch) still hides it.
        XCTAssertEqual(TaskStore(container: container).tasks.map(\.id), [other.id])
        // The sweep of unreferenced files keeps a deleted task's files.
        let removed = await store.sweepUnreferencedAttachmentStorage(minimumAge: 0)
        XCTAssertEqual(removed, 0)
    }

    func testRestoreBringsTheFamilyBackWhereItWasOnEveryReplica() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let parent = TaskItem(title: "Parent", manualOrder: 5_000)
        parent.tags = ["home"]
        let child = TaskItem(title: "Child", parentID: parent.id)
        let childReplica = TaskItem(id: child.id, title: "Child", parentID: parent.id)
        [parent, child, childReplica].forEach(seed.insert)
        try seed.save()
        let store = TaskStore(container: container)
        let order = try XCTUnwrap(store.task(withID: parent.id)?.manualOrder)

        XCTAssertTrue(store.delete(store.task(withID: parent.id)!))
        XCTAssertEqual(store.recentlyDeletedTasks().map(\.ref), [AtticItemRef(.task, parent.id)])
        XCTAssertEqual(store.recentlyDeletedTasks().first?.includedCount, 1)

        XCTAssertTrue(store.restoreDeleted(taskID: parent.id))
        XCTAssertEqual(store.subtasks(of: parent.id).map(\.id), [child.id])
        XCTAssertEqual(store.task(withID: parent.id)?.manualOrder, order)
        XCTAssertEqual(store.task(withID: parent.id)?.tags, ["home"])
        XCTAssertTrue(try allTasks(container).allSatisfy { $0.deletedAt == nil && $0.deletionRootID == nil })
        XCTAssertTrue(store.recentlyDeletedTasks().isEmpty)
    }

    func testASubtaskDeletedOnItsOwnKeepsItsOwnEntryWhenTheParentGoesToo() throws {
        let store = try makeTestStore()
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let first = try XCTUnwrap(store.create(title: "First", parentID: parent.id))
        let second = try XCTUnwrap(store.create(title: "Second", parentID: parent.id))
        XCTAssertTrue(store.delete(first))
        XCTAssertTrue(store.delete(parent))
        XCTAssertEqual(Set(store.recentlyDeletedTasks().map(\.ref.id)), [parent.id, first.id])

        XCTAssertTrue(store.restoreDeleted(taskID: parent.id))
        XCTAssertEqual(store.subtasks(of: parent.id).map(\.id), [second.id], "the earlier delete stays deleted")
        XCTAssertTrue(store.restoreDeleted(taskID: first.id))
        XCTAssertEqual(Set(store.subtasks(of: parent.id).map(\.id)), [first.id, second.id])
    }

    func testRestoreIsAllOrNothingWhenTheSaveFails() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let gate = PersistenceGate()
        let store = TaskStore(container: container, persist: gate.save)
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        _ = try XCTUnwrap(store.create(title: "Child", parentID: parent.id))
        XCTAssertTrue(store.delete(parent))

        gate.shouldFail = true
        XCTAssertFalse(store.restoreDeleted(taskID: parent.id))
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertTrue(try allTasks(container).allSatisfy { $0.deletedAt != nil }, "no row came back on its own")

        gate.shouldFail = false
        XCTAssertTrue(store.restoreDeleted(taskID: parent.id))
        XCTAssertEqual(store.tasks.count, 2)
    }

    func testFailedDeleteLeavesTheTaskVisibleAndUnmarked() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let gate = PersistenceGate()
        let store = TaskStore(container: container, persist: gate.save)
        let task = try XCTUnwrap(store.create(title: "Keep me"))
        gate.shouldFail = true
        XCTAssertFalse(store.delete(task))
        XCTAssertEqual(store.tasks.map(\.id), [task.id])
        XCTAssertTrue(try allTasks(container).allSatisfy { $0.deletedAt == nil })
    }

    func testRestoringSomethingNotDeletedIsRefused() throws {
        let store = try makeTestStore()
        let task = try XCTUnwrap(store.create(title: "Live"))
        XCTAssertFalse(store.restoreDeleted(taskID: task.id))
        XCTAssertFalse(store.restoreDeleted(taskID: UUID()))
        XCTAssertEqual(store.tasks.count, 1)
    }

    func testDeletedSubtasksNoLongerBlockCompletingTheParent() throws {
        let store = try makeTestStore()
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let child = try XCTUnwrap(store.create(title: "Unfinished", parentID: parent.id))
        XCTAssertFalse(store.markDone(parent))
        XCTAssertTrue(store.delete(child))
        XCTAssertTrue(store.markDone(parent), "a deleted subtask is gone from the family, as before")
    }

    func testCreatingASubtaskUnderADeletedParentIsRefused() throws {
        let store = try makeTestStore()
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        XCTAssertTrue(store.delete(parent))
        XCTAssertNil(store.create(title: "Child", parentID: parent.id))
        XCTAssertNotNil(store.lastErrorMessage)
    }

    // MARK: - Purge

    func testPurgeRemovesOnlyDeletesOlderThanTheCutoffWithTheirFamiliesAndFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticPurge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("brief.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("brief".utf8).write(to: source)
        let files = TaskImageFiles(rootURL: root.appendingPathComponent("storage"))
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000_000))
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = TaskStore(container: container, now: { clock.value }, taskImageFiles: files)
        let old = try XCTUnwrap(store.create(title: "Old"))
        _ = try XCTUnwrap(store.create(title: "Old child", parentID: old.id))
        let attached = await store.attachFiles([source], to: old.id)
        XCTAssertTrue(attached)
        let file = try XCTUnwrap(store.task(withID: old.id)?.attachments.first)
        let recent = try XCTUnwrap(store.create(title: "Recent"))
        XCTAssertTrue(store.delete(old))
        clock.value = clock.value.addingTimeInterval(10 * 24 * 3_600)
        XCTAssertTrue(store.delete(recent))

        let cutoff = clock.value.addingTimeInterval(-5 * 24 * 3_600)
        let purged = store.purgeDeleted(before: cutoff)
        XCTAssertEqual(purged.count, 2, "the old task and its subtask")
        XCTAssertTrue(purged.contains(old.id))
        XCTAssertEqual(try allTasks(container).map(\.id), [recent.id])
        XCTAssertEqual(store.recentlyDeletedTasks().map(\.ref.id), [recent.id])
        try await Task.sleep(for: .milliseconds(300))
        let fileURL = try await files.verifiedURL(for: file)
        XCTAssertNil(fileURL, "the purge released the file")
        XCTAssertTrue(store.purgeDeleted(before: cutoff).isEmpty, "purging again changes nothing")
    }

    func testDivergentReplicasBlockThePurge() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let deletedAt = Date(timeIntervalSince1970: 1_000)
        let id = UUID()
        let first = TaskItem(id: id, title: "Copy one")
        first.deletedAt = deletedAt
        first.deletionRootID = id
        let second = TaskItem(id: id, title: "Copy two")
        second.deletedAt = deletedAt
        second.deletionRootID = id
        let liveCopy = UUID()
        let hidden = TaskItem(id: liveCopy, title: "Deleted here")
        hidden.deletedAt = deletedAt
        hidden.deletionRootID = liveCopy
        let live = TaskItem(id: liveCopy, title: "Deleted here", updatedAt: Date(timeIntervalSince1970: 0))
        [first, second, hidden, live].forEach(seed.insert)
        try seed.save()
        let store = TaskStore(container: container)

        XCTAssertTrue(store.purgeDeleted(before: .distantFuture).isEmpty)
        XCTAssertEqual(try allTasks(container).count, 4)
    }

    func testDailyCleanupPurgesAfterThirtyDaysAndNeverBefore() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try makeTestStore(now: { clock.value })
        let library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.create(title: "Soon gone"))
        XCTAssertTrue(library.delete(AtticItemRef(.task, task.id)))
        let service = DailyCleanupService(
            store: store,
            now: { clock.value },
            calendar: { self.calendar },
            purgeRecentlyDeleted: { now, calendar in library.purgeExpired(now: now, calendar: calendar) }
        )

        clock.value = try XCTUnwrap(calendar.date(byAdding: .day, value: 29, to: clock.value))
        service.performCleanup()
        XCTAssertEqual(library.recentlyDeleted().map(\.ref.id), [task.id])

        clock.value = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: clock.value))
        service.performCleanup()
        XCTAssertTrue(library.recentlyDeleted().isEmpty)
        XCTAssertEqual(try ModelContext(store.container).fetchCount(FetchDescriptor<TaskItem>()), 0)
    }

    // MARK: - Notes

    func testDeletingANoteKeepsItsAttachmentsAndRestoreBringsThemBack() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let note = NoteItem(title: "Plan", body: "Body", updatedAt: Date(timeIntervalSince1970: 50))
        let newer = NoteItem(title: "Newer", body: "Other", updatedAt: Date(timeIntervalSince1970: 100))
        seed.insert(note)
        seed.insert(newer)
        seed.insert(NoteAttachment(noteID: note.id, originalFilename: "a.txt", byteCount: 1, sortIndex: 0,
                                   contentDigest: String(repeating: "a", count: 64), payload: Data([1])))
        try seed.save()
        let store = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        XCTAssertEqual(store.orderedNotes().map(\.id), [newer.id, note.id])

        XCTAssertTrue(store.delete(store.note(withID: note.id)!))
        XCTAssertEqual(store.notes.map(\.id), [newer.id])
        XCTAssertTrue(store.attachments(for: note.id).isEmpty)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteAttachment>()), 1)
        XCTAssertEqual(store.recentlyDeletedNotes().map(\.ref.id), [note.id])
        XCTAssertEqual(store.recentlyDeletedNotes().first?.includedCount, 1)
        XCTAssertFalse(store.update(note, body: "edit"), "a deleted note cannot be edited")

        XCTAssertTrue(store.restoreDeleted(noteID: note.id))
        XCTAssertEqual(store.orderedNotes().map(\.id), [newer.id, note.id], "it returns to its place")
        XCTAssertEqual(store.attachments(for: note.id).count, 1)
    }

    func testANoteIDInRecentlyDeletedIsNeverReusedForANewNote() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let note = try XCTUnwrap(store.create(title: "Original"))
        XCTAssertTrue(store.delete(note))
        let recreated = try XCTUnwrap(store.create(id: note.id, title: "Draft"))
        XCTAssertNotEqual(recreated.id, note.id)
        XCTAssertTrue(store.restoreDeleted(noteID: note.id))
        XCTAssertEqual(Set(store.notes.map(\.id)), [note.id, recreated.id])
    }

    func testNoteRestoreFailureLeavesItDeleted() throws {
        let gate = PersistenceGate()
        let store = try makeTestNoteStore(persist: gate.save, attachmentFileStore: makeTestAttachmentFileStore())
        let note = try XCTUnwrap(store.create(title: "Note"))
        XCTAssertTrue(store.delete(note))
        gate.shouldFail = true
        XCTAssertFalse(store.restoreDeleted(noteID: note.id))
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertEqual(store.recentlyDeletedNotes().count, 1)
    }

    func testNotePurgeIsBlockedByADivergentReplica() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let id = UUID()
        let deleted = NoteItem(id: id, title: "A")
        deleted.deletedAt = Date(timeIntervalSince1970: 10)
        let other = NoteItem(id: id, title: "B")
        other.deletedAt = Date(timeIntervalSince1970: 10)
        seed.insert(deleted)
        seed.insert(other)
        try seed.save()
        let store = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        XCTAssertTrue(store.purgeDeleted(before: .distantFuture).isEmpty)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteItem>()), 2)
    }

    // MARK: - Canvases

    func testDeletingACanvasListsItAndRestoreBringsBackOnlyWhatTheDeleteHid() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 10_000))
        let store = try makeTestCanvasStore(now: { clock.value })
        XCTAssertNotNil(store.createCanvas(name: "Keep"), "the last canvas cannot be deleted")
        let board = try XCTUnwrap(store.createCanvas(name: "Ideas"))
        XCTAssertTrue(store.selectCanvas(board.id))
        let kept = try XCTUnwrap(store.addStroke(color: .ink, width: 3, points: [.zero, CanvasPoint(x: 1, y: 1)]))
        let erased = try XCTUnwrap(store.addStroke(color: .ink, width: 3, points: [.zero, CanvasPoint(x: 2, y: 2)]))
        clock.value = clock.value.addingTimeInterval(10)
        XCTAssertTrue(store.setDeleted(true, strokeIDs: [erased.id]))
        clock.value = clock.value.addingTimeInterval(10)

        XCTAssertTrue(store.deleteCanvas(board.id))
        XCTAssertFalse(store.canvases.contains { $0.id == board.id })
        let listed = store.recentlyDeletedCanvases()
        XCTAssertEqual(listed.map(\.ref), [AtticItemRef(.canvas, board.id)])
        XCTAssertEqual(listed.first?.title, "Ideas")
        XCTAssertEqual(listed.first?.retentionStart, clock.value)

        XCTAssertTrue(store.restoreCanvas(board.id))
        XCTAssertTrue(store.canvases.contains { $0.id == board.id })
        XCTAssertTrue(store.selectCanvas(board.id))
        XCTAssertEqual(store.strokes.map(\.id), [kept.id], "the stroke erased earlier stays erased")
        XCTAssertTrue(store.recentlyDeletedCanvases().isEmpty)
    }

    func testCanvasPurgeRemovesContentKeepsANamelessTombstoneAndStampsLegacyDeletes() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 10_000))
        let store = try makeTestCanvasStore(now: { clock.value })
        XCTAssertNotNil(store.createCanvas(name: "Keep"), "the last canvas cannot be deleted")
        let board = try XCTUnwrap(store.createCanvas(name: "Scratch"))
        XCTAssertTrue(store.selectCanvas(board.id))
        XCTAssertNotNil(store.addStroke(color: .ink, width: 3, points: [.zero, CanvasPoint(x: 1, y: 1)]))
        XCTAssertTrue(store.deleteCanvas(board.id))
        // A canvas deleted by an earlier version has no retention start.
        let legacyID = UUID()
        let seed = ModelContext(store.container)
        seed.insert(CanvasBoardItem(id: legacyID, name: "Legacy", sortIndex: 9, tombstoned: true,
                                    deletedAt: Date(timeIntervalSince1970: 1)))
        try seed.save()

        clock.value = clock.value.addingTimeInterval(100)
        XCTAssertEqual(store.purgeDeletedCanvases(before: clock.value), [board.id])
        let context = ModelContext(store.container)
        let canvasID = board.id
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CanvasStrokeItem>(predicate: #Predicate { $0.canvasID == canvasID })), 0)
        let tombstones = try context.fetch(FetchDescriptor<CanvasBoardItem>(predicate: #Predicate { $0.id == canvasID }))
        XCTAssertFalse(tombstones.isEmpty)
        XCTAssertTrue(tombstones.allSatisfy { $0.tombstoned && $0.name.isEmpty && $0.purgedAt != nil })
        XCTAssertFalse(store.restoreCanvas(board.id), "a purged canvas cannot come back")

        // The legacy canvas got its 30 days from the first cleanup that saw it.
        let legacy = try XCTUnwrap(store.recentlyDeletedCanvases().first)
        XCTAssertEqual(legacy.ref.id, legacyID)
        XCTAssertEqual(legacy.retentionStart, clock.value)
        XCTAssertTrue(store.purgeDeletedCanvases(before: clock.value).isEmpty, "not before its 30 days")
        XCTAssertEqual(store.purgeDeletedCanvases(before: clock.value.addingTimeInterval(1)), [legacyID])
    }

    // MARK: - Library

    func testLibraryListsEveryKindNewestFirstAndRestoresByReference() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 100))
        let container = try PersistenceController.makeContainer(inMemory: true)
        let tasks = TaskStore(container: container, now: { clock.value })
        let notes = NoteStore(container: container, now: { clock.value }, attachmentFileStore: makeTestAttachmentFileStore())
        let canvases = CanvasStore(container: container, now: { clock.value })
        let library = AtticLibrary(tasks: tasks, notes: notes, canvases: canvases)
        let task = try XCTUnwrap(tasks.create(title: "Task"))
        let note = try XCTUnwrap(notes.create(title: "Note"))
        XCTAssertNotNil(canvases.createCanvas(name: "Keep"))
        let board = try XCTUnwrap(canvases.createCanvas(name: "Board"))

        XCTAssertTrue(library.delete(AtticItemRef(.task, task.id)))
        clock.value += 1
        XCTAssertTrue(library.delete(AtticItemRef(.note, note.id)))
        clock.value += 1
        XCTAssertTrue(library.delete(AtticItemRef(.canvas, board.id)))
        XCTAssertEqual(library.recentlyDeleted().map(\.ref.kind), [.canvas, .note, .task])
        XCTAssertEqual(library.state(of: AtticItemRef(.note, note.id)), .deleted)

        for ref in library.recentlyDeleted().map(\.ref) { XCTAssertTrue(library.restore(ref)) }
        XCTAssertTrue(library.recentlyDeleted().isEmpty)
        XCTAssertNotNil(tasks.task(withID: task.id))
        XCTAssertNotNil(notes.note(withID: note.id))
        XCTAssertTrue(canvases.canvases.contains { $0.id == board.id })
        XCTAssertFalse(library.delete(AtticItemRef(.task, UUID())))
    }
}
