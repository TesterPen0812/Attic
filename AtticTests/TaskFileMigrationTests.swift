import SwiftData
import XCTest
@testable import Attic

/// Phase 3 slice 2 (UX plan § 13, S1, S9, S10): existing task attachments
/// move into the task's own note. Every fixture § 13 lists, reversal, an
/// older writer, and an interruption at every migration boundary, on an
/// on-disk store that is reopened the way a relaunch would.
@MainActor
final class TaskFileMigrationTests: XCTestCase {
    private var root: URL!
    private var container: ModelContainer!
    private var coordinator: WorkspaceOperationCoordinator!
    private var files: TaskImageFiles!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticTaskFileMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        files = TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles"))
        try reopen()
    }

    override func tearDown() async throws {
        TaskAttachmentMigration.interruption = nil
        coordinator = nil; container = nil; files = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// A relaunch: drop the coordinator and container, open the same store
    /// and journal again, and run launch recovery.
    private func reopen(recover: Bool = false) throws {
        coordinator = nil; container = nil
        container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        coordinator = try WorkspaceOperationCoordinator(container: container,
            journal: NoteDraftJournal(directory: root.appendingPathComponent("NoteDrafts")))
    }

    // MARK: Fixtures

    private func legacyFiles(_ names: [String]) async throws -> [TaskImageReference] {
        let folder = root.appendingPathComponent("inputs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for name in names {
            let url = folder.appendingPathComponent(name)
            if name.hasSuffix(".png") { try AtticDemoData.demoImage().write(to: url) }
            else { try Data("\(name) original bytes \(UUID())".utf8).write(to: url) }
            urls.append(url)
        }
        return try await files.importAttachments(urls, existing: [])
    }

    @discardableResult
    private func insertTask(_ id: UUID = UUID(), title: String = "Plan the launch", parent: UUID? = nil,
                            shown: [TaskImageReference] = [], removed: [RemovedTaskAttachment] = [],
                            replicas: Int = 1, deleted: Bool = false, rawShown: Data? = nil) throws -> UUID {
        let context = ModelContext(container)
        for _ in 0..<replicas {
            let row = TaskItem(id: id, title: title, parentID: parent)
            row.imageReferencesData = try rawShown ?? (shown.isEmpty ? nil : JSONEncoder().encode(shown))
            row.removedAttachmentsData = removed.isEmpty ? nil : try JSONEncoder().encode(removed)
            if deleted { row.deletedAt = Date(); row.deletionRootID = id; row.deletionMembersRaw = id.uuidString }
            context.insert(row)
        }
        try context.save()
        return id
    }

    /// An existing own note (task-note form) with some writing.
    @discardableResult
    private func insertOwnNote(for taskID: UUID, title: String = "Plan the launch", body: [NoteBlock] = [.text("Research so far")],
                               requires extra: [String] = [], replicas: Int = 1) throws -> UUID {
        let context = ModelContext(container)
        let noteID = UUID()
        var document = try NoteDocument(blocks: [.text(title)] + body).taskSnapshot(title: title)
        document.requires += extra
        let prepared = try PreparedNoteDocument(document)
        for _ in 0..<replicas {
            let note = NoteItem(id: noteID, createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000))
            NoteStore.stageDocumentContent(prepared, format: 1, on: [note], timestamp: Date(timeIntervalSince1970: 1_000), revision: 0, revisionID: UUID())
            note.taskID = taskID
            context.insert(note)
        }
        context.insert(TaskNoteAssociation(taskID: taskID, noteID: noteID))
        try context.save()
        return noteID
    }

    private func all<M: PersistentModel>(_ type: M.Type) throws -> [M] { try coordinator.freshContext().fetch(FetchDescriptor<M>()) }

    private func ownNotes(_ taskID: UUID) throws -> [NoteItem] { try all(NoteItem.self).filter { $0.taskID == taskID } }

    private func document(_ noteID: UUID) throws -> NoteDocument {
        let row = try XCTUnwrap(all(NoteItem.self).first { $0.id == noteID })
        return try XCTUnwrap(row.content.flatMap { NoteContentCodec.decode($0).document })
    }

    private func legacyData(_ id: UUID) throws -> [Data?] {
        try all(TaskItem.self).filter { $0.id == id }.flatMap { [$0.imageReferencesData, $0.removedAttachmentsData] }
    }

    private func migrate(_ id: UUID, force: Bool = false) async -> TaskAttachmentMigration.Outcome {
        await TaskAttachmentMigration.migrate(rootID: id, coordinator: coordinator, files: files, force: force)
    }

    private func originalExists(_ reference: TaskImageReference) async -> Bool {
        (try? await files.verifiedURL(for: reference)) != nil
    }

    // MARK: Removed and child-held files, into a new note

    func testShownRemovedAndChildHeldFilesMoveIntoANewOwnNoteWithDeterministicPlacements() async throws {
        let refs = try await legacyFiles(["shot.png", "Spec.pdf", "gone.txt", "child.txt"])
        let removedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let id = try insertTask(shown: [refs[0], refs[1]], removed: [RemovedTaskAttachment(reference: refs[2], removedAt: removedAt)])
        let child = try insertTask(title: "Child", parent: id, shown: [refs[3]])
        let before = try legacyData(id) + legacyData(child)

        let outcome = await migrate(id)
        guard case let .migrated(noteID, created) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(created)
        let note = try XCTUnwrap(ownNotes(id).first)
        XCTAssertEqual(note.id, noteID)
        XCTAssertEqual(try ownNotes(id).count, 1)
        XCTAssertEqual(try all(TaskNoteAssociation.self).filter { $0.taskID == id && $0.noteID == noteID }.count, 1)
        let doc = try document(noteID)
        XCTAssertTrue(doc.requires.contains("taskNote"))
        XCTAssertEqual(doc.blocks[0].text, "Plan the launch")
        // Shown files at the end, in stored order: the image inline, then
        // the file card, then the child's file. Placements are UUIDv5s.
        let objects = doc.blocks.filter { $0.attachmentID != nil }
        XCTAssertEqual(objects.map(\.attachmentID), [refs[0].id, refs[1].id, refs[3].id])
        XCTAssertEqual(objects.map(\.kind), [.image, .file, .file])
        XCTAssertEqual(objects.map(\.id), [refs[0], refs[1], refs[3]].map { TaskAttachmentMigration.placementID(attachment: $0.id, note: noteID) })
        XCTAssertEqual(TaskAttachmentMigration.placementID(attachment: refs[0].id, note: noteID),
                       TaskAttachmentMigration.placementID(attachment: refs[0].id, note: noteID))
        // Same IDs, names, types, sizes and digests; the removed file keeps
        // its removal date (and so its recovery deadline).
        let rows = try all(NoteAttachment.self)
        XCTAssertEqual(Set(rows.map(\.id)), Set(refs.map(\.id)))
        for ref in refs {
            let row = try XCTUnwrap(rows.first { $0.id == ref.id })
            XCTAssertEqual(row.noteID, noteID)
            XCTAssertEqual(row.originalFilename, ref.filename)
            XCTAssertEqual(row.contentTypeIdentifier, ref.contentTypeIdentifier)
            XCTAssertEqual(row.byteCount, ref.byteCount)
            XCTAssertEqual(row.contentDigest.lowercased(), ref.digest.lowercased())
            XCTAssertEqual(row.payload.map(NotePayloadDigest.sha256), ref.digest.lowercased())
        }
        XCTAssertEqual(rows.first { $0.id == refs[2].id }?.deletedAt, removedAt)
        XCTAssertTrue(rows.filter { $0.id != refs[2].id }.allSatisfy { $0.deletedAt == nil })
        // The record: manifest with holders, before "absent", after.
        let record = try XCTUnwrap(all(TaskAttachmentMigrationRecord.self).first)
        XCTAssertEqual(record.id, id); XCTAssertEqual(record.noteID, noteID); XCTAssertTrue(record.noteCreated)
        XCTAssertEqual(record.stateRaw, "migrated")
        let manifest = try JSONDecoder().decode(TaskAttachmentMigration.Manifest.self, from: record.manifestData)
        XCTAssertEqual(manifest.entries.first { $0.reference.id == refs[3].id }?.holderID, child)
        XCTAssertEqual(manifest.entries.first { $0.reference.id == refs[2].id }?.removedAt, removedAt)
        XCTAssertEqual(try JSONDecoder().decode(TaskAttachmentMigration.NoteState.self, from: record.beforeData).absent, true)
        // The legacy lists and bytes are untouched.
        XCTAssertEqual(try legacyData(id) + legacyData(child), before)
        for ref in refs { let exists = await originalExists(ref); XCTAssertTrue(exists, ref.filename) }
        // Idempotent: a second run changes nothing and duplicates nothing.
        let again = await migrate(id)
        XCTAssertEqual(again, .unchanged)
        XCTAssertEqual(try all(NoteAttachment.self).count, refs.count)
        XCTAssertEqual(try all(TaskAttachmentMigrationRecord.self).count, 1)
        // The resolver finds the placement for an old reference.
        let resolved = TaskAttachmentMigration.resolve(attachmentID: refs[3].id, in: coordinator.freshContext())
        XCTAssertEqual(resolved, .init(ownerID: id, holderID: child, noteID: noteID,
                                       placementID: TaskAttachmentMigration.placementID(attachment: refs[3].id, note: noteID)))
        let status = TaskAttachmentMigration.status(rootID: id, coordinator: coordinator)
        XCTAssertEqual(status.kind, .migrated)
        XCTAssertTrue(status.earlier.isEmpty)
    }

    func testFilesAppendToAnExistingOwnNoteAfterItsWritingWithAVersion() async throws {
        let refs = try await legacyFiles(["a.txt", "b.png"])
        let id = try insertTask(shown: refs)
        let noteID = try insertOwnNote(for: id)
        let outcome = await migrate(id)
        XCTAssertEqual(outcome, .migrated(noteID: noteID, created: false))
        let doc = try document(noteID)
        XCTAssertEqual(doc.blocks.map(\.kind), [.text, .text, .file, .image])
        XCTAssertEqual(doc.blocks[1].text, "Research so far")
        XCTAssertEqual(try all(NoteVersion.self).filter { $0.noteID == noteID }.count, 1)
        let record = try XCTUnwrap(all(TaskAttachmentMigrationRecord.self).first)
        XCTAssertFalse(record.noteCreated)
        XCTAssertFalse(try JSONDecoder().decode(TaskAttachmentMigration.NoteState.self, from: record.beforeData).absent)
    }

    func testDoneLogFamiliesMigrateAndRecentlyDeletedFamiliesWaitUntilRestored() async throws {
        let refs = try await legacyFiles(["done.txt", "deleted.txt"])
        let done = try insertTask(title: "Done", shown: [refs[0]])
        let context = ModelContext(container)
        for row in try context.fetch(FetchDescriptor<TaskItem>()) where row.id == done {
            row.status = .done; row.completedAt = Date(); row.doneLoggedAt = Date()
        }
        try context.save()
        let deleted = try insertTask(title: "Deleted", shown: [refs[1]], deleted: true)
        let report = await TaskAttachmentMigration.runAll(coordinator: coordinator, files: files)
        XCTAssertEqual(report.migrated, [done])
        XCTAssertEqual(report.deferred, [deleted])
        XCTAssertTrue(try ownNotes(deleted).isEmpty)
        // Restored, it migrates.
        let restore = ModelContext(container)
        for row in try restore.fetch(FetchDescriptor<TaskItem>()) where row.id == deleted {
            row.deletedAt = nil; row.deletionRootID = nil; row.deletionMembersRaw = ""
        }
        try restore.save()
        let later = await TaskAttachmentMigration.runAll(coordinator: coordinator, files: files)
        XCTAssertEqual(later.migrated, [deleted])
    }

    // MARK: Refusals: the family stays legacy, with its reason

    private func assertRefusedUntouched(_ id: UUID, _ expected: TaskAttachmentMigration.Refusal, earlier: Int,
                                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = try legacyData(id)
        let notes = try all(NoteItem.self).map(\.content)
        let outcome = await migrate(id)
        XCTAssertEqual(outcome, .refused(expected), file: file, line: line)
        XCTAssertTrue(try all(TaskAttachmentMigrationRecord.self).isEmpty, file: file, line: line)
        XCTAssertEqual(try legacyData(id), before, file: file, line: line)
        XCTAssertEqual(try all(NoteItem.self).map(\.content), notes, file: file, line: line)
        let status = TaskAttachmentMigration.status(rootID: id, coordinator: coordinator, refusal: expected)
        XCTAssertEqual(status.kind, .legacy, file: file, line: line)
        XCTAssertEqual(status.earlier.count, earlier, file: file, line: line)
        XCTAssertEqual(status.refusal, expected, file: file, line: line)
        XCTAssertFalse(expected.reason.isEmpty, file: file, line: line)
    }

    func testDivergentReplicasAreRefusedAndNothingIsInterpretedAsEmpty() async throws {
        let refs = try await legacyFiles(["one.txt", "two.txt"])
        let id = UUID()
        try insertTask(id, shown: [refs[0], refs[1]])
        try insertTask(id, shown: [refs[0]])
        try await assertRefusedUntouched(id, .divergentReplicas, earlier: 2)
    }

    func testAgreeingDuplicateReplicasMigrateOnceAndTheManifestHasEveryReplica() async throws {
        let refs = try await legacyFiles(["one.txt"])
        let id = try insertTask(shown: refs, replicas: 2)
        let outcome = await migrate(id)
        guard case .migrated = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try all(NoteAttachment.self).count, 1)
        let record = try XCTUnwrap(all(TaskAttachmentMigrationRecord.self).first)
        XCTAssertEqual(try JSONDecoder().decode(TaskAttachmentMigration.Manifest.self, from: record.manifestData).replicas.count, 2)
    }

    func testDuplicateNoteReplicasBothReceiveTheFiles() async throws {
        let refs = try await legacyFiles(["one.txt"])
        let id = try insertTask(shown: refs)
        let noteID = try insertOwnNote(for: id, replicas: 2)
        let outcome = await migrate(id)
        XCTAssertEqual(outcome, .migrated(noteID: noteID, created: false))
        let replicas = try all(NoteItem.self).filter { $0.id == noteID }
        XCTAssertEqual(replicas.count, 2)
        XCTAssertEqual(Set(replicas.map(\.content)).count, 1)
        XCTAssertTrue(try document(noteID).attachmentIDs.contains(refs[0].id))
    }

    func testUnreadableListsAreRefused() async throws {
        let id = try insertTask(rawShown: Data("not json".utf8))
        try await assertRefusedUntouched(id, .unreadable, earlier: 0)
    }

    func testCombinedLimitsRefuseTheWholeFamily() async throws {
        // 21 shown files: the note would exceed 20.
        let many = try await legacyFiles((0..<11).map { "f\($0).txt" }) + legacyFiles((11..<21).map { "f\($0).txt" })
        let tooMany = try insertTask(title: "Many", shown: many)
        try await assertRefusedUntouched(tooMany, .tooManyFiles, earlier: 21)
        // 18 in the note already plus 3 legacy: the combined count refuses.
        let three = Array(many.prefix(3))
        let combined = try insertTask(title: "Combined", shown: three)
        let noteID = try insertOwnNote(for: combined, title: "Combined", body: (0..<18).map { _ in .text("") })
        let context = ModelContext(container)
        var doc = try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>()).first { $0.id == noteID }?.content.flatMap { NoteContentCodec.decode($0).document })
        for index in 0..<18 {
            let attachment = NoteAttachment(noteID: noteID, originalFilename: "n\(index).txt", byteCount: 3, sortIndex: Int64(index), contentDigest: "x")
            context.insert(attachment)
            doc.blocks[index + 1] = .file(attachmentID: attachment.id, filename: "n\(index).txt", contentTypeIdentifier: "public.plain-text", byteCount: 3)
        }
        let prepared = try PreparedNoteDocument(doc)
        for row in try context.fetch(FetchDescriptor<NoteItem>()) where row.id == noteID {
            NoteStore.stageDocumentContent(prepared, format: 1, on: [row], timestamp: Date(), revision: 1, revisionID: UUID())
        }
        try context.save()
        try await assertRefusedUntouched(combined, .tooManyFiles, earlier: 3)
        // Removed files never count: the same three as removed migrate.
        let removedOnly = try insertTask(title: "Removed only", removed: many.suffix(3).map { RemovedTaskAttachment(reference: $0, removedAt: Date()) })
        let outcome = await migrate(removedOnly)
        guard case .migrated = outcome else { return XCTFail("\(outcome)") }
    }

    func testOversizedFilesAndAnOversizedNoteAreRefused() async throws {
        let big = TaskImageReference(id: UUID(), filename: "huge.mov", digest: "00", contentTypeIdentifier: "public.movie",
                                     byteCount: AttachmentLimits.maxBytesPerAttachment + 1)
        let id = try insertTask(shown: [big])
        try await assertRefusedUntouched(id, .fileTooLarge("huge.mov"), earlier: 1)
        let parts = (0..<7).map { TaskImageReference(id: UUID(), filename: "part\($0).bin", digest: "00",
                                                    contentTypeIdentifier: "public.data", byteCount: 15 * 1024 * 1024) }
        let heavy = try insertTask(title: "Heavy", shown: parts)
        try await assertRefusedUntouched(heavy, .noteTooLarge, earlier: 7)
    }

    func testAnUnsupportedOrReadOnlyNoteIsRefused() async throws {
        let refs = try await legacyFiles(["a.txt"])
        let id = try insertTask(shown: refs)
        try insertOwnNote(for: id, requires: ["from-a-newer-attic"])
        try await assertRefusedUntouched(id, .noteNotWritable, earlier: 1)
    }

    func testAnIDUsedInAnotherNoteIsRefusedButTheSameFileInTheOwnNoteCountsAsMigrated() async throws {
        let refs = try await legacyFiles(["shared.txt", "mine.txt"])
        let elsewhere = try insertTask(title: "Elsewhere", shown: [refs[0]])
        let context = ModelContext(container)
        let other = NoteItem(id: UUID())
        context.insert(other)
        context.insert(NoteAttachment(id: refs[0].id, noteID: other.id, originalFilename: "shared.txt", byteCount: refs[0].byteCount,
                                      sortIndex: 0, contentDigest: refs[0].digest))
        try context.save()
        try await assertRefusedUntouched(elsewhere, .usedElsewhere("shared.txt"), earlier: 1)

        let mine = try insertTask(title: "Mine", shown: [refs[1]])
        let noteID = try insertOwnNote(for: mine, title: "Mine")
        let add = ModelContext(container)
        add.insert(NoteAttachment(id: refs[1].id, noteID: noteID, originalFilename: "mine.txt", byteCount: refs[1].byteCount,
                                  sortIndex: 0, contentDigest: refs[1].digest, payload: Data()))
        try add.save()
        let outcome = await migrate(mine)
        XCTAssertEqual(outcome, .migrated(noteID: noteID, created: false))
        XCTAssertEqual(try all(NoteAttachment.self).filter { $0.id == refs[1].id }.count, 1)
    }

    func testAMissingOriginalIsRefusedWithItsName() async throws {
        let refs = try await legacyFiles(["here.txt"])
        let ghost = TaskImageReference(id: UUID(), filename: "ghost.pdf", digest: String(repeating: "a", count: 64),
                                       contentTypeIdentifier: "com.adobe.pdf", byteCount: 10)
        let id = try insertTask(shown: [refs[0], ghost])
        try await assertRefusedUntouched(id, .missingOriginal("ghost.pdf"), earlier: 2)
    }

    // MARK: Failure injection: a failed save changes nothing

    func testAFailedSaveLeavesEveryStoreUntouchedAndALaterRunSucceeds() async throws {
        let refs = try await legacyFiles(["a.png", "b.txt"])
        let id = try insertTask(shown: refs)
        let before = try legacyData(id)
        coordinator.save = { _ in throw CocoaError(.fileWriteNoPermission) }
        let outcome = await migrate(id)
        XCTAssertEqual(outcome, .deferred)
        XCTAssertTrue(try all(NoteItem.self).isEmpty)
        XCTAssertTrue(try all(NoteAttachment.self).isEmpty)
        XCTAssertTrue(try all(TaskAttachmentMigrationRecord.self).isEmpty)
        XCTAssertTrue(try all(TaskNoteAssociation.self).isEmpty)
        XCTAssertEqual(try legacyData(id), before)
        coordinator.save = { try $0.save() }
        let retried = await migrate(id)
        guard case .migrated = retried else { return XCTFail("\(retried)") }
    }

    // MARK: Interruption at every boundary

    private enum Shape: String { case created, existing }

    /// Old state: no record, no note rows from the migration, no
    /// attachment rows. New state: the record, the note with exactly the
    /// expected placements, one row per file. Anything else is a mix.
    private func classify(_ id: UUID, refs: [TaskImageReference], shape: Shape, existingNote: UUID?,
                          legacy: [Data?], point: String) throws -> Bool {
        XCTAssertEqual(try legacyData(id), legacy, "legacy lists changed: \(point)")
        let records = try all(TaskAttachmentMigrationRecord.self)
        let rows = try all(NoteAttachment.self)
        let notes = try ownNotes(id)
        if records.isEmpty {
            XCTAssertTrue(rows.isEmpty, "attachment rows without a record: \(point)")
            XCTAssertEqual(notes.count, shape == .created ? 0 : 1, "note rows without a record: \(point)")
            if let existingNote { XCTAssertEqual(try document(existingNote).attachmentIDs, [], point) }
            XCTAssertTrue(try all(NoteVersion.self).isEmpty, point)
            return false
        }
        XCTAssertEqual(records.count, 1, point)
        let noteID = records[0].noteID
        XCTAssertEqual(notes.map(\.id), [noteID], point)
        if let existingNote { XCTAssertEqual(noteID, existingNote, point) }
        let doc = try document(noteID)
        let shown = refs.dropLast()
        XCTAssertEqual(doc.blocks.filter { $0.attachmentID != nil }.map(\.id),
                       shown.map { TaskAttachmentMigration.placementID(attachment: $0.id, note: noteID) }, point)
        XCTAssertEqual(rows.map(\.id).sorted { $0.uuidString < $1.uuidString }, refs.map(\.id).sorted { $0.uuidString < $1.uuidString }, point)
        XCTAssertTrue(rows.allSatisfy { $0.noteID == noteID && $0.payload != nil }, point)
        return true
    }

    func testAnInterruptionAtEveryBoundaryLeavesOldOrNewAndRelaunchFinishes() async throws {
        let points = ["M0-inventory", "M1-validation", "M2-bytes", "M3-note", "M4-record", "M5-publication", "save-throws", "save-then-throw"]
        for shape in [Shape.created, .existing] {
            for point in points {
                try reopen()
                let refs = try await legacyFiles(["shot.png", "Spec.pdf", "old.txt"])
                let id = try insertTask(title: "Family \(shape) \(point)", shown: [refs[0], refs[1]],
                                        removed: [RemovedTaskAttachment(reference: refs[2], removedAt: Date(timeIntervalSince1970: 1_700_000_000))])
                let existing = shape == .existing ? try insertOwnNote(for: id, title: "Family \(shape) \(point)") : nil
                let legacy = try legacyData(id)
                var fired = false
                switch point {
                case "save-throws": coordinator.save = { _ in throw CocoaError(.fileWriteUnknown) }
                case "save-then-throw": coordinator.save = { try $0.save(); throw CocoaError(.fileWriteUnknown) }
                default:
                    TaskAttachmentMigration.interruption = { reached in
                        guard reached == point, !fired else { return }
                        fired = true
                        throw TaskAttachmentMigration.InjectedInterruption.at(reached)
                    }
                }
                _ = await migrate(id)
                TaskAttachmentMigration.interruption = nil
                XCTAssertTrue(fired || point.hasPrefix("save"), "boundary never reached: \(point)")
                // Relaunch twice: recovery is idempotent, and the state is
                // either before or after, never a mix.
                for relaunch in 0..<2 {
                    try reopen()
                    try await coordinator.reconcileStartup()
                    let isNew = try classify(id, refs: refs, shape: shape, existingNote: existing, legacy: legacy, point: "\(shape) \(point) #\(relaunch)")
                    // Before the save: the old state. After it: the new one.
                    XCTAssertEqual(isNew, ["M5-publication", "save-then-throw"].contains(point), "\(shape) \(point) #\(relaunch)")
                }
                // The launch run finishes (or confirms) the migration.
                _ = await TaskAttachmentMigration.runAll(coordinator: coordinator, files: files)
                XCTAssertTrue(try classify(id, refs: refs, shape: shape, existingNote: existing, legacy: legacy, point: "\(shape) \(point) finished"),
                              "launch run did not finish: \(shape) \(point)")
                XCTAssertEqual(try all(NoteVersion.self).count, shape == .existing ? 1 : 0, "\(shape) \(point)")
                let staged = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("NoteDrafts").path)
                _ = staged
                coordinator = nil; container = nil
                try FileManager.default.removeItem(at: root)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                files = TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles"))
            }
        }
    }

    // MARK: Reversal

    func testReversalOfACreatedNoteDeletesItRecoverablyAndKeepsEveryRowAndByte() async throws {
        let refs = try await legacyFiles(["shot.png", "Spec.pdf"])
        let id = try insertTask(shown: refs)
        guard case let .migrated(noteID, _) = await migrate(id) else { return XCTFail() }
        let rowsBefore = try all(NoteAttachment.self).count
        let outcome = await TaskAttachmentMigration.reverse(rootID: id, coordinator: coordinator)
        XCTAssertEqual(outcome, .reversed)
        let note = try XCTUnwrap(all(NoteItem.self).first { $0.id == noteID })
        XCTAssertNotNil(note.deletedAt, "the created note goes to Recently Deleted")
        XCTAssertEqual(try all(NoteAttachment.self).count, rowsBefore, "rows are never physically deleted")
        XCTAssertTrue(try all(NoteAttachment.self).allSatisfy { $0.deletedAt != nil && $0.payload != nil })
        XCTAssertFalse(try document(noteID).attachmentIDs.contains(refs[0].id))
        XCTAssertGreaterThan(try all(NoteVersion.self).filter { $0.noteID == noteID }.count, 0, "the body edit makes a version")
        for ref in refs { let exists = await originalExists(ref); XCTAssertTrue(exists) }
        XCTAssertEqual(try all(TaskAttachmentMigrationRecord.self).first?.stateRaw, "reversed")
        // Never migrated again by itself; Earlier files lists them.
        let report = await TaskAttachmentMigration.runAll(coordinator: coordinator, files: files)
        XCTAssertEqual(report.refused[id], .reversed)
        let status = TaskAttachmentMigration.status(rootID: id, coordinator: coordinator)
        XCTAssertEqual(status.kind, .reversed)
        XCTAssertEqual(status.earlier.map(\.id), refs.map(\.id))
        XCTAssertTrue(status.refusal?.allowsMove == true)
    }

    func testReversalKeepsFilesAddedLaterAndReturnsFilesRemovedInTheNoteAsRemoved() async throws {
        let refs = try await legacyFiles(["keep.txt", "dropped.txt"])
        let id = try insertTask(shown: refs)
        let noteID = try insertOwnNote(for: id)
        guard case .migrated = await migrate(id) else { return XCTFail() }
        // In the note: the person removes "dropped.txt" and adds a file.
        let context = ModelContext(container)
        var doc = try document(noteID)
        doc.blocks.removeAll { $0.attachmentID == refs[1].id }
        let added = NoteAttachment(noteID: noteID, originalFilename: "added.txt", byteCount: 3, sortIndex: 9, contentDigest: "y", payload: Data("new".utf8))
        context.insert(added)
        doc.blocks.append(.file(attachmentID: added.id, filename: "added.txt", contentTypeIdentifier: "public.plain-text", byteCount: 3))
        let removedAt = Date(timeIntervalSince1970: 1_900_000_000)
        for row in try context.fetch(FetchDescriptor<NoteAttachment>()) where row.id == refs[1].id { row.deletedAt = removedAt }
        let prepared = try PreparedNoteDocument(doc)
        for row in try context.fetch(FetchDescriptor<NoteItem>()) where row.id == noteID {
            NoteStore.stageDocumentContent(prepared, format: 1, on: [row], timestamp: Date(), revision: 2, revisionID: UUID())
        }
        try context.save()

        let outcome = await TaskAttachmentMigration.reverse(rootID: id, coordinator: coordinator)
        XCTAssertEqual(outcome, .reversed)
        let after = try document(noteID)
        XCTAssertEqual(after.attachmentIDs, [added.id], "a file added after migration stays")
        XCTAssertNil(try all(NoteItem.self).first { $0.id == noteID }?.deletedAt, "a note holding other content stays")
        let task = try XCTUnwrap(all(TaskItem.self).first { $0.id == id })
        XCTAssertEqual(task.attachments.map(\.id), [refs[0].id])
        XCTAssertEqual(task.removedAttachments, [RemovedTaskAttachment(reference: refs[1], removedAt: removedAt)],
                       "not resurrected: it goes back as removed, with its date")
    }

    func testReversalRefusesAfterAMovedFileChangedAndKeepsTheRecord() async throws {
        let refs = try await legacyFiles(["shot.png"])
        let id = try insertTask(shown: refs)
        guard case let .migrated(noteID, _) = await migrate(id) else { return XCTFail() }
        let context = ModelContext(container)
        var doc = try document(noteID)
        let index = try XCTUnwrap(doc.blocks.firstIndex { $0.attachmentID == refs[0].id })
        doc.blocks[index].widthFraction = 0.5
        let prepared = try PreparedNoteDocument(doc)
        for row in try context.fetch(FetchDescriptor<NoteItem>()) where row.id == noteID {
            NoteStore.stageDocumentContent(prepared, format: 1, on: [row], timestamp: Date(), revision: 2, revisionID: UUID())
        }
        try context.save()
        let contentBefore = try all(NoteItem.self).first { $0.id == noteID }?.content
        let outcome = await TaskAttachmentMigration.reverse(rootID: id, coordinator: coordinator)
        XCTAssertEqual(outcome, .refused("Can't reverse: “shot.png” changed after moving"))
        XCTAssertEqual(try all(NoteItem.self).first { $0.id == noteID }?.content, contentBefore)
        XCTAssertEqual(try all(TaskAttachmentMigrationRecord.self).first?.stateRaw, "migrated")
    }

    func testReversalRefusesWhileAnAgentProposalIsPending() async throws {
        let refs = try await legacyFiles(["a.txt"])
        let id = try insertTask(shown: refs)
        guard case let .migrated(noteID, _) = await migrate(id) else { return XCTFail() }
        let context = ModelContext(container)
        context.insert(NotePendingEdit(noteID: noteID, baseRevisionToken: "", proposedContent: Data(), agentName: "Agent", createdAt: Date()))
        try context.save()
        let outcome = await TaskAttachmentMigration.reverse(rootID: id, coordinator: coordinator)
        guard case .refused = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try all(TaskAttachmentMigrationRecord.self).first?.stateRaw, "migrated")
    }

    func testMoveIntoNoteAfterAReversalMigratesAgainIntoTheLiveNote() async throws {
        let refs = try await legacyFiles(["a.txt"])
        let id = try insertTask(shown: refs)
        let noteID = try insertOwnNote(for: id)
        guard case .migrated = await migrate(id) else { return XCTFail() }
        let reversed = await TaskAttachmentMigration.reverse(rootID: id, coordinator: coordinator)
        XCTAssertEqual(reversed, .reversed)
        let unforced = await migrate(id)
        XCTAssertEqual(unforced, .refused(.reversed))
        let again = await migrate(id, force: true)
        XCTAssertEqual(again, .migrated(noteID: noteID, created: false))
        XCTAssertEqual(try document(noteID).attachmentIDs, [refs[0].id])
        XCTAssertEqual(try all(NoteAttachment.self).filter { $0.id == refs[0].id }.count, 1)
        XCTAssertTrue(try all(NoteAttachment.self).allSatisfy { $0.deletedAt == nil })
    }

    // MARK: An older writer

    /// An older build sees the legacy lists as they were at migration; if it
    /// adds or removes references, the next launch reconciles.
    func testAnOlderWritersAdditionsMigrateAndItsRemovalsLeaveTheNoteWhilePlacementsAreUnchanged() async throws {
        let refs = try await legacyFiles(["first.txt", "second.txt"])
        let id = try insertTask(shown: refs)
        guard case let .migrated(noteID, _) = await migrate(id) else { return XCTFail() }
        let later = try await legacyFiles(["added by old build.png"])
        // The older build removes "second" and adds a screenshot.
        let removedAt = Date(timeIntervalSince1970: 1_850_000_000)
        let context = ModelContext(container)
        for row in try context.fetch(FetchDescriptor<TaskItem>()) where row.id == id {
            row.imageReferencesData = try JSONEncoder().encode([refs[0], later[0]])
            row.removedAttachmentsData = try JSONEncoder().encode([RemovedTaskAttachment(reference: refs[1], removedAt: removedAt)])
        }
        try context.save()
        let report = await TaskAttachmentMigration.runAll(coordinator: coordinator, files: files)
        XCTAssertEqual(report.reconciled, [id])
        let doc = try document(noteID)
        XCTAssertEqual(doc.attachmentIDs, [refs[0].id, later[0].id])
        XCTAssertNotNil(try all(NoteAttachment.self).first { $0.id == refs[1].id }?.deletedAt)
        XCTAssertNil(try all(NoteAttachment.self).first { $0.id == later[0].id }?.deletedAt)
        XCTAssertEqual(try all(NoteAttachment.self).filter { $0.id == later[0].id }.count, 1)
        // Placements never duplicate on a second run.
        let second = await TaskAttachmentMigration.runAll(coordinator: coordinator, files: files)
        XCTAssertEqual(second.reconciled, [])
        XCTAssertEqual(try document(noteID).blocks.filter { $0.attachmentID != nil }.count, 2)
    }

    func testAnOlderWritersRemovalOfAChangedPlacementWaitsForReview() async throws {
        let refs = try await legacyFiles(["shot.png"])
        let id = try insertTask(shown: refs)
        guard case let .migrated(noteID, _) = await migrate(id) else { return XCTFail() }
        let context = ModelContext(container)
        var doc = try document(noteID)
        doc.blocks.removeAll { $0.attachmentID == refs[0].id }
        doc.blocks.insert(.image(attachmentID: refs[0].id, widthFraction: 0.5), at: 1)
        let prepared = try PreparedNoteDocument(doc)
        for row in try context.fetch(FetchDescriptor<NoteItem>()) where row.id == noteID {
            NoteStore.stageDocumentContent(prepared, format: 1, on: [row], timestamp: Date(), revision: 2, revisionID: UUID())
        }
        for row in try context.fetch(FetchDescriptor<TaskItem>()) where row.id == id {
            row.imageReferencesData = nil
            row.removedAttachmentsData = try JSONEncoder().encode([RemovedTaskAttachment(reference: refs[0], removedAt: Date())])
        }
        try context.save()
        let outcome = await migrate(id)
        XCTAssertEqual(outcome, .refused(.changedSinceMoving("shot.png")))
        XCTAssertTrue(try document(noteID).attachmentIDs.contains(refs[0].id))
    }

    // MARK: Collectors keep covered originals

    func testCoveredOriginalsStayWithBothCollectors() async throws {
        let refs = try await legacyFiles(["a.txt"])
        let id = try insertTask(shown: refs)
        guard case .migrated = await migrate(id) else { return XCTFail() }
        XCTAssertEqual(try TaskAttachmentMigration.coveredAttachmentIDs(in: coordinator.freshContext()), [refs[0].id])
        // Even with no task row referencing it any more, the sweep keeps it.
        let context = ModelContext(container)
        for row in try context.fetch(FetchDescriptor<TaskItem>()) { row.imageReferencesData = nil }
        try context.save()
        let store = TaskStore(container: container, taskImageFiles: files)
        _ = await store.sweepUnreferencedAttachmentStorage(minimumAge: 0)
        let exists = await originalExists(refs[0])
        XCTAssertTrue(exists)
    }
}
