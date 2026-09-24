import SwiftData
import XCTest
@testable import Attic

/// Single attachments go to Recently Deleted, and purges never remove a file
/// another note still needs (data review findings 3 and 4).
@MainActor
final class AttachmentRecentlyDeletedTests: XCTestCase {
    private let day: TimeInterval = 24 * 3_600


    func testRemovingATaskAttachmentKeepsItRestorableUntilThePurge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticAttachmentBin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("plan.txt")
        try Data("plan".utf8).write(to: source)
        let files = TaskImageFiles(rootURL: root.appendingPathComponent("storage"))
        let clock = MutableNow(Date(timeIntervalSince1970: 100_000))
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = TaskStore(container: container, now: { clock.value }, taskImageFiles: files)
        let library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.create(title: "Task"))
        let attached = await store.attachFiles([source], to: task.id)
        XCTAssertTrue(attached)
        let reference = try XCTUnwrap(store.task(withID: task.id)?.attachments.first)

        XCTAssertTrue(store.removeAttachment(reference.id, from: task.id))
        XCTAssertTrue(store.task(withID: task.id)?.attachments.isEmpty == true)
        try await Task.sleep(for: .milliseconds(200))
        let kept = try await files.verifiedURL(for: reference)
        XCTAssertNotNil(kept, "the file stays while the removal is restorable")
        let swept = await store.sweepUnreferencedAttachmentStorage(minimumAge: 0)
        XCTAssertEqual(swept, 0, "the launch sweep keeps it too")
        let listed = library.recentlyDeletedAttachments()
        XCTAssertEqual(listed.map(\.attachmentID), [reference.id])
        XCTAssertEqual(listed.first?.owner, AtticItemRef(.task, task.id))

        XCTAssertTrue(library.restoreAttachment(try XCTUnwrap(listed.first)))
        XCTAssertEqual(store.task(withID: task.id)?.attachments, [reference])
        XCTAssertTrue(library.recentlyDeletedAttachments().isEmpty)

        XCTAssertTrue(store.removeAttachment(reference.id, from: task.id))
        XCTAssertEqual(store.purgeRemovedAttachments(before: clock.value), 0, "not before its 30 days")
        clock.value += 31 * day
        let report = library.purgeExpired(now: clock.value, calendar: Calendar(identifier: .gregorian))
        XCTAssertEqual(report.attachmentCount, 1)
        try await Task.sleep(for: .milliseconds(300))
        let gone = try await files.verifiedURL(for: reference)
        XCTAssertNil(gone)
        XCTAssertTrue(store.task(withID: task.id)?.removedAttachments.isEmpty == true)
    }

    func testRemovingANoteAttachmentKeepsItRestorableUntilThePurge() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 100_000))
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let note = NoteItem(title: "Note")
        let attachment = NoteAttachment(noteID: note.id, originalFilename: "a.txt", byteCount: 1, sortIndex: 0,
                                        contentDigest: String(repeating: "a", count: 64), payload: Data([7]))
        seed.insert(note)
        seed.insert(attachment)
        try seed.save()
        let notes = NoteStore(container: container, now: { clock.value }, attachmentFileStore: makeTestAttachmentFileStore())
        let library = AtticLibrary(tasks: TaskStore(container: container), notes: notes)
        let visible = try XCTUnwrap(notes.attachments(for: note.id).first)

        XCTAssertTrue(notes.removeAttachment(visible))
        XCTAssertTrue(notes.attachments(for: note.id).isEmpty)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<NoteAttachment>()).first?.payload, Data([7]))
        let listed = library.recentlyDeletedAttachments()
        XCTAssertEqual(listed.map(\.owner), [AtticItemRef(.note, note.id)])
        XCTAssertTrue(library.restoreAttachment(try XCTUnwrap(listed.first)))
        XCTAssertEqual(notes.attachments(for: note.id).map(\.id), [attachment.id])

        XCTAssertTrue(notes.removeAttachment(try XCTUnwrap(notes.attachments(for: note.id).first)))
        XCTAssertEqual(notes.purgeRemovedAttachments(before: clock.value), 0, "not before its 30 days")
        clock.value += 31 * day
        XCTAssertEqual(library.purgeExpired(now: clock.value, calendar: Calendar(identifier: .gregorian)).attachmentCount, 1)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteAttachment>()), 0)
    }


    // MARK: - Shared files


    func testNotePurgeWaitsWhileAnotherNoteHoldsTheSameAttachment() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let doomed = NoteItem(title: "Doomed")
        doomed.deletedAt = Date(timeIntervalSince1970: 10)
        let survivor = NoteItem(title: "Survivor")
        let sharedID = UUID()
        let digest = String(repeating: "b", count: 64)
        seed.insert(doomed)
        seed.insert(survivor)
        seed.insert(NoteAttachment(id: sharedID, noteID: doomed.id, originalFilename: "s.txt", byteCount: 1,
                                   sortIndex: 0, contentDigest: digest, payload: Data([1])))
        seed.insert(NoteAttachment(id: sharedID, noteID: survivor.id, originalFilename: "s.txt", byteCount: 1,
                                   sortIndex: 0, contentDigest: digest, payload: Data([1])))
        try seed.save()
        let store = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())

        XCTAssertTrue(store.purgeDeleted(before: .distantFuture).isEmpty, "an ambiguous purge is refused")
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteAttachment>()), 2)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteItem>()), 2)
        XCTAssertEqual(store.attachments(for: survivor.id).map(\.id), [sharedID])
    }
}

extension AttachmentRecentlyDeletedTests {
    /// A note deleted at 1 000, with one attachment added before that.
    private func deletedNote(_ container: ModelContainer) throws -> (NoteItem, NoteAttachment) {
        let seed = ModelContext(container)
        let note = NoteItem(title: "Doomed")
        note.updatedAt = Date(timeIntervalSince1970: 400)
        note.deletedAt = Date(timeIntervalSince1970: 1_000)
        let attachment = NoteAttachment(noteID: note.id, originalFilename: "a.txt", byteCount: 1, sortIndex: 0,
                                        contentDigest: String(repeating: "c", count: 64),
                                        createdAt: Date(timeIntervalSince1970: 500), payload: Data([1]))
        note.deletedAttachmentIDsRaw = attachment.id.uuidString
        seed.insert(note)
        seed.insert(attachment)
        try seed.save()
        return (note, attachment)
    }

    func testNotePurgeWaitsForALateAttachmentWithANewIDAndEarlierTimestamps() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let note = NoteItem(title: "Doomed")
        let kept = NoteAttachment(noteID: note.id, originalFilename: "a.txt", byteCount: 1, sortIndex: 0,
                                  contentDigest: String(repeating: "c", count: 64),
                                  createdAt: Date(timeIntervalSince1970: 500), payload: Data([1]))
        seed.insert(note)
        seed.insert(kept)
        try seed.save()
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000))
        let store = NoteStore(container: container, now: { clock.value }, attachmentFileStore: makeTestAttachmentFileStore())
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: note.id))))
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<NoteItem>()).first?.deletedAttachmentIDsRaw,
                       kept.id.uuidString, "the delete records its attachment family")

        // A row from another device that arrived after the delete, with a
        // new id and timestamps from before it: nothing but the record
        // shows it was never part of the delete.
        let context = ModelContext(container)
        let late = NoteAttachment(noteID: note.id, originalFilename: "late.txt", byteCount: 1, sortIndex: 1,
                                  contentDigest: String(repeating: "d", count: 64),
                                  createdAt: Date(timeIntervalSince1970: 600), payload: Data([2]))
        context.insert(late)
        try context.save()

        XCTAssertTrue(store.purgeDeleted(before: .distantFuture).isEmpty)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteItem>()), 1)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteAttachment>()), 2)

        // The family the delete recorded, and nothing more, is purged.
        context.delete(late)
        try context.save()
        XCTAssertEqual(store.purgeDeleted(before: .distantFuture), [note.id])
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteAttachment>()), 0)
    }

    func testNoteDeletedWithoutARecordedAttachmentFamilyIsKept() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let (note, _) = try deletedNote(container)
        let context = ModelContext(container)
        try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>()).first).deletedAttachmentIDsRaw = nil
        try context.save()
        let store = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())

        XCTAssertTrue(store.purgeDeleted(before: .distantFuture).isEmpty)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteAttachment>()), 1)

        // Restoring it and deleting it again records the family.
        XCTAssertTrue(store.restoreDeleted(noteID: note.id))
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: note.id))))
        XCTAssertEqual(store.purgeDeleted(before: .distantFuture), [note.id])
    }

    func testNotePurgeWaitsForAnAttachmentThatArrivedAfterTheDelete() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let (note, _) = try deletedNote(container)
        let context = ModelContext(container)
        // A late row from another device, added after the note was deleted.
        let late = NoteAttachment(noteID: note.id, originalFilename: "late.txt", byteCount: 1, sortIndex: 1,
                                  contentDigest: String(repeating: "d", count: 64),
                                  createdAt: Date(timeIntervalSince1970: 2_000), payload: Data([2]))
        context.insert(late)
        try context.save()
        let store = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())

        XCTAssertTrue(store.purgeDeleted(before: .distantFuture).isEmpty)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteItem>()), 1)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteAttachment>()), 2)

        // Without the late row, the delete is whole and the purge goes ahead.
        context.delete(late)
        try context.save()
        XCTAssertEqual(store.purgeDeleted(before: .distantFuture), [note.id])
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteAttachment>()), 0)
    }

    func testNotePurgeWaitsWhileReplicasOfOneAttachmentDiffer() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let (note, attachment) = try deletedNote(container)
        let context = ModelContext(container)
        // Same identity, same note, same claimed digest, different bytes.
        context.insert(NoteAttachment(id: attachment.id, noteID: note.id, originalFilename: "a.txt", byteCount: 1,
                                      sortIndex: 0, contentDigest: attachment.contentDigest,
                                      createdAt: attachment.createdAt, payload: Data([9])))
        try context.save()
        let store = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())

        XCTAssertTrue(store.purgeDeleted(before: .distantFuture).isEmpty)
        let rows = try ModelContext(container).fetch(FetchDescriptor<NoteAttachment>())
        XCTAssertEqual(Set(rows.compactMap(\.payload)), [Data([1]), Data([9])], "both copies are kept")
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteItem>()), 1)
    }
}
