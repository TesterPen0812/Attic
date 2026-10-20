import SwiftData
import XCTest
@testable import Attic

/// Single attachments go to Recently Deleted, and purges never remove a file
/// another note still needs (data review findings 3 and 4).
@MainActor
final class AttachmentRecentlyDeletedTests: XCTestCase {

    func testR1_03AttachmentPurgeKeepsByteDivergentTaskTitles() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container), id = UUID()
        let date = Date(timeIntervalSince1970: 1000)
        let reference = TaskImageReference(id: UUID(), filename: "plan.txt", digest: String(repeating: "a", count: 64),
            contentTypeIdentifier: "public.plain-text", byteCount: 4)
        let data = try JSONEncoder().encode([RemovedTaskAttachment(reference: reference, removedAt: date)])
        for title in ["Café", "Cafe\u{301}"] {
            let row = TaskItem(id: id, title: title, createdAt: date, updatedAt: date)
            row.removedAttachmentsData = data
            context.insert(row)
        }
        try context.save()
        XCTAssertEqual(TaskStore(container: container).purgeRemovedAttachments(before: .distantFuture), 0)
        let rows = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.removedAttachmentsData == data })
    }

    private let day: TimeInterval = 24 * 3_600


    func testRemovingATaskAttachmentKeepsItRestorableUntilThePurge() async throws {
        let root = ownedTemporaryDirectory(prefix: "AtticAttachmentBin")

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

    func testRemovingADocumentAttachmentRetainsPayloadOwnedByHistory() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 100_000))
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let note = NoteItem(title: "Note")
        let attachment = NoteAttachment(noteID: note.id, originalFilename: "a.txt", byteCount: 1, sortIndex: 0,
                                        contentDigest: NotePayloadDigest.sha256(Data([7])), payload: Data([7]))
        let document = NoteDocument(blocks: [.text("Note"), .file(attachmentID: attachment.id,
            filename: attachment.originalFilename, contentTypeIdentifier: attachment.contentTypeIdentifier, byteCount: 1)])
        note.content = try NoteContentCodec.encode(document)
        note.plainText = NoteTextExport.plainText(document)
        seed.insert(note)
        seed.insert(attachment)
        try seed.save()
        let notes = trackAttachmentReconciliation(of: NoteStore(container: container, now: { clock.value }, attachmentFileStore: makeTestAttachmentFileStore()))
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
        notes.thinVersions(noteID: note.id)
        XCTAssertEqual(library.purgeExpired(now: clock.value, calendar: Calendar(identifier: .gregorian)).attachmentCount, 0, "Rich document history keeps its only recoverable attachment")
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteAttachment>()), 1)
        XCTAssertTrue(notes.versions(noteID: note.id).contains { $0.attachmentIDs.contains(attachment.id) })
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
        let store = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()))

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
        let store = trackAttachmentReconciliation(of: NoteStore(container: container, now: { clock.value }, attachmentFileStore: makeTestAttachmentFileStore()))
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
        let store = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()))

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
        let store = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()))

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
        let store = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()))

        XCTAssertTrue(store.purgeDeleted(before: .distantFuture).isEmpty)
        let rows = try ModelContext(container).fetch(FetchDescriptor<NoteAttachment>())
        XCTAssertEqual(Set(rows.compactMap(\.payload)), [Data([1]), Data([9])], "both copies are kept")
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteItem>()), 1)
    }

    func testRemovedAttachmentPurgeWaitsWhileReplicasHoldDifferentBytesUnderOneDigest() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let note = NoteItem(title: "Note")
        seed.insert(note)
        let attachmentID = UUID()
        let removedAt = Date(timeIntervalSince1970: 1_000)
        for bytes in [Data([1]), Data([9])] {
            let row = NoteAttachment(id: attachmentID, noteID: note.id, originalFilename: "a.txt", byteCount: 1,
                                     sortIndex: 0, contentDigest: String(repeating: "e", count: 64),
                                     createdAt: Date(timeIntervalSince1970: 500), updatedAt: removedAt, payload: bytes)
            row.deletedAt = removedAt
            seed.insert(row)
        }
        try seed.save()
        let store = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()))

        XCTAssertEqual(store.purgeRemovedAttachments(before: .distantFuture), 0)
        let rows = try ModelContext(container).fetch(FetchDescriptor<NoteAttachment>())
        XCTAssertEqual(Set(rows.compactMap(\.payload)), [Data([1]), Data([9])], "both copies are kept")
    }

    /// An attachment removed before its note was deleted reaches its own 30
    /// days first. It stays with the deleted note, and both go together when
    /// the note's 30 days end.
    func testAnAttachmentRemovedBeforeItsNoteWasDeletedIsPurgedWithTheNote() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let note = NoteItem(title: "Note")
        let removed = NoteAttachment(noteID: note.id, originalFilename: "removed.txt", byteCount: 1, sortIndex: 0,
                                     contentDigest: String(repeating: "a", count: 64),
                                     createdAt: Date(timeIntervalSince1970: 500), payload: Data([1]))
        let shown = NoteAttachment(noteID: note.id, originalFilename: "shown.txt", byteCount: 1, sortIndex: 1,
                                   contentDigest: String(repeating: "b", count: 64),
                                   createdAt: Date(timeIntervalSince1970: 500), payload: Data([2]))
        seed.insert(note)
        seed.insert(removed)
        seed.insert(shown)
        try seed.save()
        let start = Date(timeIntervalSince1970: 100_000)
        let clock = MutableNow(start)
        let store = trackAttachmentReconciliation(of: NoteStore(container: container, now: { clock.value }, attachmentFileStore: makeTestAttachmentFileStore()))
        let library = AtticLibrary(tasks: TaskStore(container: container), notes: store)
        let calendar = Calendar(identifier: .gregorian)

        XCTAssertTrue(store.removeAttachment(try XCTUnwrap(store.attachments(for: note.id).first { $0.id == removed.id })))
        clock.value = start + 10 * day
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: note.id))))

        // The attachment's 30 days are over, the note's are not.
        clock.value = start + 35 * day
        XCTAssertEqual(library.purgeExpired(now: clock.value, calendar: calendar).attachmentCount, 0)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteAttachment>()), 2, "nothing goes early")
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteItem>()), 1)

        // The note's 30 days are over: it goes with its whole family.
        clock.value = start + 45 * day
        _ = library.purgeExpired(now: clock.value, calendar: calendar)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteItem>()), 0)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteAttachment>()), 0)
    }
}

@MainActor
final class RoundPRADataSafetyTests: XCTestCase {
    private struct RawAttachments: Equatable {
        let shown: Data?, removed: Data?, updatedAt: Date
        init(_ row: TaskItem) {
            shown = row.imageReferencesData; removed = row.removedAttachmentsData; updatedAt = row.updatedAt
        }
    }
    func testFailedImportDoesNotLeaveAnyReplicaPointingAtRemovedFiles() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let root = ownedTemporaryDirectory(prefix: "PRAFailedTaskImport")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = root.appendingPathComponent("storage")
        let source = root.appendingPathComponent("plan.txt")
        try Data("private bytes".utf8).write(to: source)
        let files = TaskImageFiles(rootURL: storage)
        var savedContext: ModelContext?
        let store = TaskStore(container: container, persist: { context in
            savedContext = context; try context.save()
        }, taskImageFiles: files)
        let task = try XCTUnwrap(store.create(title: "Owner"))
        let other = try XCTUnwrap(store.create(title: "Other"))
        let context = try XCTUnwrap(savedContext)
        let replica = TaskItem(id: task.id, title: task.title, createdAt: task.createdAt, updatedAt: task.updatedAt)
        replica.listOrderVersion = task.listOrderVersion
        context.insert(replica); try context.save()
        let ids = [task.id]
        let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { ids.contains($0.id) })
        let ordered = try context.fetch(descriptor)
        XCTAssertEqual(ordered.count, 2)
        // Match the exact unsorted fetch used by storedTaskGroups: the healthy
        // row is visited before the malformed row, regardless of SQLite order.
        ordered[1].removedAttachmentsData = Data("malformed removal JSON".utf8)
        try context.save()
        XCTAssertEqual(try context.fetch(descriptor).map(\.persistentModelID), ordered.map(\.persistentModelID))
        let before = ordered.map(RawAttachments.init), times = ordered.map(\.updatedAt)
        let attached = await store.attachFiles([source], to: task.id)
        XCTAssertFalse(attached)
        XCTAssertEqual(ordered.map(RawAttachments.init), before, "failure must not leave unsaved references")
        XCTAssertEqual(ordered.map(\.updatedAt), times)
        XCTAssertNotNil(store.errorNotice)
        XCTAssertTrue(store.update(other, title: "Unrelated save"))
        let fresh = ModelContext(container)
        let after = try fresh.fetch(descriptor)
        let beforeByID = Dictionary(uniqueKeysWithValues: zip(ordered.map(\.persistentModelID), before))
        for row in after { XCTAssertEqual(RawAttachments(row), beforeByID[row.persistentModelID]) }
        let remaining = FileManager.default.enumerator(at: storage, includingPropertiesForKeys: [.isRegularFileKey])
        let filesLeft = (remaining?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        XCTAssertEqual(filesLeft, [], "all unbound private copies are removed")
        XCTAssertEqual(try Data(contentsOf: source), Data("private bytes".utf8))
    }
}

@MainActor
extension RoundPRADataSafetyTests {
    func testDoneLogOwnerKeepsAttachmentRecoveryAndCompletionState() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let root = ownedTemporaryDirectory(prefix: "PRADoneAttachment")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("plan.txt"), bytes = Data("done task attachment".utf8)
        try bytes.write(to: source)
        let files = TaskImageFiles(rootURL: root.appendingPathComponent("storage"))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000))
        let store = TaskStore(container: container, now: { clock.value }, taskImageFiles: files)
        let task = try XCTUnwrap(store.create(title: "Finished work"))
        let attached = await store.attachFiles([source], to: task.id)
        XCTAssertTrue(attached)
        let reference = try XCTUnwrap(store.task(withID: task.id)?.attachments.first)
        XCTAssertTrue(store.removeAttachment(reference.id, from: task.id))
        let summary = try XCTUnwrap(store.recentlyDeletedAttachments().first)
        XCTAssertTrue(store.setStatus(.done, for: try XCTUnwrap(store.task(withID: task.id))))
        let completedAt = store.task(withID: task.id)?.completedAt
        clock.value = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: clock.value))
        XCTAssertEqual(store.moveCompletedToDoneLog(before: calendar.startOfDay(for: clock.value)), 1)
        XCTAssertNil(store.task(withID: task.id))
        let logged = try XCTUnwrap(store.doneLog().first)
        let loggedAt = try XCTUnwrap(logged.doneLoggedAt)
        // A duplicate in the Done log must be restored too, without leaving Done.
        let seed = ModelContext(container)
        let sibling = TaskItem(id: task.id, title: logged.title, status: .done, createdAt: logged.createdAt, updatedAt: logged.updatedAt)
        sibling.completedAt = completedAt; sibling.doneLoggedAt = loggedAt
        sibling.removedAttachmentsData = logged.removedAttachmentsData; sibling.listOrderVersion = logged.listOrderVersion
        seed.insert(sibling); try seed.save(); store.refresh()
        let file = try await files.verifiedURL(for: reference)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(file)), bytes)
        let summaries = store.recentlyDeletedAttachments()
        XCTAssertEqual(summaries.map(\.attachmentID), [summary.attachmentID])
        XCTAssertEqual(summaries.first?.owner, summary.owner)
        XCTAssertEqual(summaries.first?.deletedAt, summary.deletedAt)
        XCTAssertTrue(store.restoreAttachment(reference.id))
        XCTAssertTrue(store.recentlyDeletedAttachments().isEmpty)
        XCTAssertNil(store.task(withID: task.id))
        let fresh = ModelContext(container), id = task.id
        let rows = try fresh.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertEqual(row.attachments, [reference]); XCTAssertTrue(row.removedAttachments.isEmpty)
            XCTAssertEqual(row.status, .done); XCTAssertEqual(row.completedAt, completedAt); XCTAssertEqual(row.doneLoggedAt, loggedAt)
        }
        let restoredFile = try await files.verifiedURL(for: reference)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restoredFile)), bytes)
    }
}

@MainActor
extension RoundPRADataSafetyTests {
    func testDuplicateUnopenedNoteVerifiesOnlyItsColdAttachmentAndHasOneUndoStep() async throws {
        let root = ownedTemporaryDirectory(prefix: "PRAColdDuplicate")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let schema = Schema(PersistenceController.appModelTypes), url = root.appendingPathComponent("notes.store")
        func open() throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
        }
        let fileStore = AttachmentFileStore(rootURL: root.appendingPathComponent("files"))
        let first = trackAttachmentReconciliation(of: NoteStore(container: try open(), attachmentFileStore: fileStore))
        let bytes = Data("intact saved file".utf8)
        let item = StagedNoteAttachment(id: UUID(), filename: "plan.txt", contentTypeIdentifier: "public.plain-text",
            byteCount: Int64(bytes.count), digest: NotePayloadDigest.sha256(bytes), data: bytes)
        let sourceID = UUID(), unrelatedID = UUID(), otherID = UUID()
        let original = NoteDocument(blocks: [.text("Source"), .checklist("Keep task"), .file(attachmentID: item.id,
            filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)])
        let otherFile = item.copying(id: UUID())
        guard case .success = first.createDocumentNote(id: sourceID, document: original, staged: [item], tags: ["project"]),
              case .success = first.createDocumentNote(id: unrelatedID, document: NoteDocument(blocks: [.text("Unrelated")])),
              case .success = first.createDocumentNote(id: otherID, document: NoteDocument(blocks: [.text("Other file"),
                .file(attachmentID: otherFile.id, filename: otherFile.filename, contentTypeIdentifier: otherFile.contentTypeIdentifier,
                      byteCount: otherFile.byteCount)]), staged: [otherFile]) else { return XCTFail("seed") }
        let originalBytes = try XCTUnwrap(first.note(withID: sourceID)?.content)
        let originalDocument = try XCTUnwrap(first.loadDocument(noteID: sourceID)?.content.document)
        await first.waitForAttachmentReconciliation()
        let second = trackAttachmentReconciliation(of: NoteStore(container: try open(), attachmentFileStore: fileStore))
        let controller = NotesPageController(store: second, journal: nil, saveDelay: .seconds(600))
        let opened = await controller.openDurably(noteID: unrelatedID)
        XCTAssertTrue(opened)
        XCTAssertEqual(second.attachmentFamily(item.id).first?.payload, bytes)
        XCTAssertNil(second.cachedVerifiedAttachmentBytes(item.id))
        XCTAssertNil(second.cachedVerifiedAttachmentBytes(otherFile.id))
        let duplicated = await controller.duplicateNote(noteID: sourceID)
        XCTAssertTrue(duplicated)
        guard duplicated else { return }
        let copy = try XCTUnwrap(controller.active), copyID = copy.noteID
        XCTAssertNotEqual(copyID, sourceID); XCTAssertNotEqual(copyID, unrelatedID)
        XCTAssertEqual(second.notes.count, 4)
        let document = try XCTUnwrap(second.loadDocument(noteID: copyID)?.content.document)
        XCTAssertEqual(document.blocks.map(\.text), ["Source copy", "Keep task", ""])
        XCTAssertNotEqual(document.blocks[1].id, originalDocument.blocks[1].id)
        XCTAssertEqual(document.attachmentIDs.count, 1)
        XCTAssertNotEqual(document.attachmentIDs.first, item.id)
        XCTAssertEqual(try second.attachmentRows(forNoteID: copyID).first?.payload, bytes)
        XCTAssertEqual(second.note(withID: copyID)?.tags, ["project"])
        XCTAssertNil(second.cachedVerifiedAttachmentBytes(otherFile.id), "Duplicate must not read the library's other attachment bytes")
        XCTAssertEqual(second.note(withID: sourceID)?.content, originalBytes)
        XCTAssertEqual(second.note(withID: sourceID)?.tags, ["project"])
        XCTAssertTrue(controller.undoLibrary()); XCTAssertNil(second.note(withID: copyID))
        XCTAssertFalse(controller.undoLibrary(), "exactly one library Undo step")
        XCTAssertTrue(controller.redoLibrary())
        XCTAssertEqual(second.loadDocument(noteID: copyID)?.content.document, document)
        let fresh = ModelContext(second.container)
        let rows = try fresh.fetch(FetchDescriptor<NoteItem>())
        XCTAssertEqual(rows.first { $0.id == sourceID }?.content, originalBytes)
        XCTAssertEqual(rows.first { $0.id == copyID }?.tags, ["project"])
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<NoteAttachment>()).first { $0.noteID == copyID }?.payload, bytes)
    }
}

@MainActor
extension RoundPRADataSafetyTests {
    private func coldDuplicateFixture() async throws -> (NoteStore, NotesPageController, UUID, UUID, UUID) {
        let files = makeTestAttachmentFileStore()
        let first = try makeTestNoteStore(attachmentFileStore: files)
        let bytes = Data("saved attachment".utf8)
        let item = StagedNoteAttachment(id: UUID(), filename: "plan.txt", contentTypeIdentifier: "public.plain-text",
            byteCount: Int64(bytes.count), digest: NotePayloadDigest.sha256(bytes), data: bytes)
        let source = UUID(), other = UUID(), third = UUID()
        guard case .success = first.createDocumentNote(id: source, document: NoteDocument(blocks: [.text("Source"),
            .file(attachmentID: item.id, filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)]), staged: [item]),
              case .success = first.createDocumentNote(id: other, document: NoteDocument(blocks: [.text("Other")])),
              case .success = first.createDocumentNote(id: third, document: NoteDocument(blocks: [.text("Third")])) else {
            throw CocoaError(.fileWriteUnknown)
        }
        await first.waitForAttachmentReconciliation()
        let store = trackAttachmentReconciliation(of: NoteStore(container: first.container, attachmentFileStore: files))
        let controller = NotesPageController(store: store, journal: nil, saveDelay: .seconds(600))
        let opened = await controller.openDurably(noteID: other)
        XCTAssertTrue(opened); XCTAssertNil(store.cachedVerifiedAttachmentBytes(item.id))
        return (store, controller, source, third, item.id)
    }

    func testDuplicateRevalidatesSourceAndPresentationAfterVerificationSuspends() async throws {
        for mutation in ["revision", "tags", "source session", "active session", "navigation", "delete", "refresh"] {
            let (store, controller, source, third, attachment) = try await coldDuplicateFixture()
            let active = try XCTUnwrap(controller.active)
            var sourceSession: NoteSession?
            if mutation == "source session" {
                XCTAssertTrue(controller.open(noteID: source)); sourceSession = controller.active
                XCTAssertTrue(controller.open(noteID: active.noteID))
            }
            let ids = Set(store.notes.map(\.id))
            controller.duplicateAttachmentWillVerify = { id in
                XCTAssertEqual(id, attachment)
                switch mutation {
                case "revision":
                    let load = try! XCTUnwrap(store.loadDocument(noteID: source))
                    var document = load.content.document!; document.blocks[0].text = "Changed while verifying"
                    guard case .success = store.saveDocument(noteID: source, document: document, baseRevisionID: load.revisionID) else { return XCTFail("save") }
                case "tags": XCTAssertTrue(store.setTags(["changed"], for: store.note(withID: source)!))
                case "source session":
                    let engine = sourceSession!.engine
                    XCTAssertTrue(engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Changed "), name: "Type"))
                case "active session":
                    XCTAssertTrue(active.engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Changed "), name: "Type"))
                case "navigation": XCTAssertTrue(controller.open(noteID: third))
                case "delete": XCTAssertTrue(store.delete(store.note(withID: source)!))
                default: store.refresh()
                }
            }
            let duplicated = await controller.duplicateNote(noteID: source)
            XCTAssertFalse(duplicated, mutation)
            XCTAssertEqual(Set(store.notes.map(\.id)), mutation == "delete" ? ids.subtracting([source]) : ids, mutation)
            XCTAssertFalse(controller.canUndoLibrary, mutation)
            if mutation == "active session" { XCTAssertEqual(active.engine.document().title, "Changed Other") }
            if mutation == "source session" { XCTAssertEqual(sourceSession?.engine.document().title, "Changed Source") }
            if mutation == "navigation" { XCTAssertEqual(controller.active?.noteID, third) }
        }
    }

    func testRepeatedDuplicateDuringVerificationCreatesOnlyOneCopy() async throws {
        let (store, controller, source, _, _) = try await coldDuplicateFixture()
        controller.duplicateAttachmentWillVerify = { _ in
            let repeated = await controller.duplicateNote(noteID: source)
            XCTAssertFalse(repeated)
        }
        let duplicated = await controller.duplicateNote(noteID: source)
        XCTAssertTrue(duplicated)
        XCTAssertEqual(store.notes.count, 4)
        XCTAssertTrue(controller.undoLibrary()); XCTAssertEqual(store.notes.count, 3)
        XCTAssertFalse(controller.undoLibrary())
        XCTAssertTrue(controller.redoLibrary()); XCTAssertEqual(store.notes.count, 4)
    }
}
