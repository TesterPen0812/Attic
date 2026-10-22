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

    func testP3S2R2UnchangedLaunchReadsNoAttachmentPayloads() async throws {
        for family in 0..<8 {
            let references = try await legacyFiles(["\(family)-one.txt", "\(family)-two.txt", "\(family)-three.txt"])
            let id = try insertTask(shown: references)
            guard case .migrated = await migrate(id) else { return XCTFail("seed migration") }
        }
        try reopen()
        try await coordinator.finishLaunch()
        WorkspacePayloadAccess.allThreads.reset()
        let report = await TaskAttachmentMigration.runAll(coordinator: coordinator, files: files)
        XCTAssertTrue(report.migrated.isEmpty)
        XCTAssertEqual(WorkspacePayloadAccess.allThreads.count("attachment"), 0, "unchanged launch must not fault or hash stored payload bytes")
    }

    func testP3S2R2PresenceQueryRepairsMissingReplicaWithoutFaultingPresentLegacyPayload() async throws {
        let refs = try await legacyFiles(["repair.txt"])
        let rootID = try insertTask(shown: refs)
        guard case .migrated = await migrate(rootID) else { return XCTFail("seed migration") }
        let context = coordinator.freshContext(), id = refs[0].id
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<NoteAttachment>()).first)
        row.payloadFingerprint = nil // A present legacy payload has no scalar proof.
        let replica = NoteAttachment(id: id, noteID: row.noteID, originalFilename: row.originalFilename,
            contentTypeIdentifier: row.contentTypeIdentifier, byteCount: row.byteCount, sortIndex: row.sortIndex,
            contentDigest: row.contentDigest, payload: nil)
        context.insert(replica); try context.save()
        WorkspacePayloadAccess.allThreads.reset()
        XCTAssertEqual(try NoteAttachment.missingPayloadIDs(among: [id], in: coordinator.freshContext()), [id])
        XCTAssertEqual(WorkspacePayloadAccess.allThreads.count("attachment"), 0)
        let repaired = await migrate(rootID)
        XCTAssertEqual(repaired, .reconciled, "an already migrated family's missing replica is repaired by reconciliation")
        let rows = try all(NoteAttachment.self)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.payload.map(NotePayloadDigest.sha256) == refs[0].digest })
        WorkspacePayloadAccess.allThreads.reset()
        let unchanged = await migrate(rootID)
        XCTAssertEqual(unchanged, .unchanged)
        XCTAssertEqual(WorkspacePayloadAccess.allThreads.count("attachment"), 0)
    }

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
                                  sortIndex: 0, contentDigest: refs[1].digest, payload: try Data(contentsOf: await files.files.materializedURL(for: refs[1].fileReference))))
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

@MainActor
extension TaskFileMigrationTests {
    func testP3S2F1MigrationKeepsInventoryTokens() async throws {
        let refs = try await legacyFiles(["race.txt"])
        let id = try insertTask(shown: refs)
        let noteID = try insertOwnNote(for: id)
        var fired = false
        TaskAttachmentMigration.interruption = { [self] point in
            guard point == "M2-bytes", !fired else { return }
            fired = true
            let edit = ModelContext(container)
            var changed = try document(noteID)
            changed.blocks.append(.text("Saved while migration read bytes"))
            let prepared = try PreparedNoteDocument(changed)
            for row in try edit.fetch(FetchDescriptor<NoteItem>()) where row.id == noteID {
                NoteStore.stageDocumentContent(prepared, format: 1, on: [row], timestamp: Date(), revision: 1, revisionID: UUID())
            }
            try edit.save()
        }
        let result = await migrate(id)
        XCTAssertTrue(fired)
        XCTAssertEqual(result, .deferred)
        XCTAssertTrue(try document(noteID).blocks.contains { $0.text == "Saved while migration read bytes" })
    }

    func testP3S2F5OlderWriterKeepsEditedPlacement() async throws {
        let refs = try await legacyFiles(["shot.png"])
        let id = try insertTask(shown: refs)
        guard case let .migrated(noteID, _) = await migrate(id) else { return XCTFail() }
        let edit = ModelContext(container)
        var changed = try document(noteID)
        let index = try XCTUnwrap(changed.blocks.firstIndex { $0.attachmentID == refs[0].id })
        changed.blocks[index].widthFraction = 0.5
        let prepared = try PreparedNoteDocument(changed)
        for row in try edit.fetch(FetchDescriptor<NoteItem>()) where row.id == noteID {
            NoteStore.stageDocumentContent(prepared, format: 1, on: [row], timestamp: Date(), revision: 1, revisionID: UUID())
        }
        for row in try edit.fetch(FetchDescriptor<TaskItem>()) where row.id == id {
            row.imageReferencesData = nil
            row.removedAttachmentsData = try JSONEncoder().encode([RemovedTaskAttachment(reference: refs[0], removedAt: Date())])
        }
        try edit.save()
        let result = await migrate(id)
        XCTAssertEqual(result, .refused(.changedSinceMoving("shot.png")))
        XCTAssertTrue(try document(noteID).attachmentIDs.contains(refs[0].id))
    }

    func testP3S2F2OriginalCoverageIsCumulative() async throws {
        let refs = try await legacyFiles(["retained.txt", "still.txt"])
        let id = try insertTask(shown: refs)
        guard case .migrated = await migrate(id) else { return XCTFail() }
        let edit = ModelContext(container)
        for row in try edit.fetch(FetchDescriptor<TaskItem>()) where row.id == id {
            row.imageReferencesData = try JSONEncoder().encode([refs[1]])
            row.removedAttachmentsData = nil
        }
        try edit.save()
        // First reconcile the ordinary older-writer removal, then its
        // later purge of the legacy Recently Deleted entry.
        let removal = ModelContext(container)
        for row in try removal.fetch(FetchDescriptor<TaskItem>()) where row.id == id {
            row.removedAttachmentsData = try JSONEncoder().encode([RemovedTaskAttachment(reference: refs[0], removedAt: Date())])
        }
        try removal.save()
        let firstRemoval = await migrate(id)
        XCTAssertEqual(firstRemoval, .reconciled)
        let expiry = ModelContext(container)
        for row in try expiry.fetch(FetchDescriptor<TaskItem>()) where row.id == id { row.removedAttachmentsData = nil }
        try expiry.save()
        let result = await migrate(id)
        XCTAssertEqual(result, .reconciled)
        XCTAssertTrue(try TaskAttachmentMigration.coveredAttachmentIDs(in: coordinator.freshContext()).contains(refs[0].id))
        let tasks = TaskStore(container: container, taskImageFiles: files)
        files.files.finishCandidates(Set(refs.map(\.id)))
        _ = await tasks.sweepUnreferencedAttachmentStorage(minimumAge: 0)
        let exists = await originalExists(refs[0])
        XCTAssertTrue(exists, "original covered by the first migration must survive reconciliation and sweep")
    }

    func testP3S2F8EarlierFilesUnionsPhysicalReplicas() async throws {
        let refs = try await legacyFiles(["A.txt", "B.txt"])
        let id = try insertTask(shown: [refs[0]])
        try insertTask(id, shown: [refs[1]])
        let result = await migrate(id)
        XCTAssertEqual(result, .refused(.divergentReplicas))
        let status = TaskAttachmentMigration.status(rootID: id, coordinator: coordinator)
        XCTAssertEqual(Set(status.earlier.map(\.id)), Set(refs.map(\.id)))
    }

    func testP3S2F4ExistingRowsNeedVerifiedPayloads() async throws {
        let refs = try await legacyFiles(["good.txt"])
        let id = try insertTask(shown: refs)
        let noteID = try insertOwnNote(for: id)
        let edit = ModelContext(container)
        edit.insert(NoteAttachment(id: refs[0].id, noteID: noteID, originalFilename: refs[0].filename,
            contentTypeIdentifier: refs[0].contentTypeIdentifier, byteCount: refs[0].byteCount, sortIndex: 0,
            contentDigest: refs[0].digest, payload: nil))
        try edit.save()
        let result = await migrate(id)
        let row = try XCTUnwrap(all(NoteAttachment.self).first { $0.id == refs[0].id })
        XCTAssertEqual(row.payload.map(NotePayloadDigest.sha256), refs[0].digest)
        let status = TaskAttachmentMigration.status(rootID: id, coordinator: coordinator)
        XCTAssertTrue(row.payload != nil || status.earlier.contains { $0.id == refs[0].id }, "either the note has verified bytes or the original remains accessible")
    }
}

@MainActor
extension TaskFileMigrationTests {
    func testP3S2F9ReversalRefusesRecoveryDependency() async throws {
        let refs = try await legacyFiles(["draft.txt"])
        let id = try insertTask(shown: refs)
        guard case let .migrated(noteID, _) = await migrate(id) else { return XCTFail() }
        var draft = try document(noteID)
        draft.blocks.append(.text("Unsaved writing using migrated files"))
        let row = try XCTUnwrap(all(NoteItem.self).first { $0.id == noteID })
        let entry = NoteDraftJournalEntry(noteID: noteID, isPersisted: true, baseRevisionID: row.revisionID,
            content: try NoteContentCodec.encode(draft), selectionLocation: 0, selectionLength: 0, staged: [], savedAt: Date())
        _ = try await coordinator.journal.writeDurably(entry, staged: [])
        XCTAssertTrue(coordinator.retainedRecoveryBytes.contains(refs[0].id))
        let result = await TaskAttachmentMigration.reverse(rootID: id, coordinator: coordinator)
        guard case .refused = result else { return XCTFail("a recovery draft still depends on the migrated files") }
    }
}

@MainActor
extension TaskFileMigrationTests {
    func testP3S2F6LastLegacyRemovalReconciles() async throws {
        let refs = try await legacyFiles(["last.txt"])
        let id = try insertTask(shown: refs)
        guard case let .migrated(noteID, _) = await migrate(id) else { return XCTFail() }
        let edit = ModelContext(container)
        for row in try edit.fetch(FetchDescriptor<TaskItem>()) where row.id == id { row.imageReferencesData = nil; row.removedAttachmentsData = nil }
        try edit.save()
        let report = await TaskAttachmentMigration.runAll(coordinator: coordinator, files: files)
        XCTAssertTrue(report.reconciled.contains(id))
        XCTAssertFalse(try document(noteID).attachmentIDs.contains(refs[0].id))
        let direct = await migrate(id)
        XCTAssertEqual(direct, .unchanged, "launch already reconciled the removal; direct retry is idempotent")
    }

    func testP3S2F7ConflictingOriginalStaysVisible() async throws {
        let refs = try await legacyFiles(["old.txt", "replacement.txt"])
        let id = try insertTask(shown: [refs[0]])
        guard case .migrated = await migrate(id) else { return XCTFail() }
        let source = try await files.files.materializedURL(for: refs[1].fileReference)
        let replacement = TaskImageReference(id: refs[0].id, filename: refs[1].filename, digest: refs[1].digest,
            contentTypeIdentifier: refs[1].contentTypeIdentifier, byteCount: refs[1].byteCount)
        let target = try await files.files.materializedURL(for: replacement.fileReference)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        let edit = ModelContext(container)
        for row in try edit.fetch(FetchDescriptor<TaskItem>()) where row.id == id { row.imageReferencesData = try JSONEncoder().encode([replacement]) }
        try edit.save()
        let result = await migrate(id)
        guard case let .refused(reason) = result else { return XCTFail("\(result)") }
        let status = TaskAttachmentMigration.status(rootID: id, coordinator: coordinator, refusal: reason)
        XCTAssertTrue(status.earlier.contains(replacement), "a changed, refused original still exists and must be reachable")
        XCTAssertNotNil(status.refusal)
    }
}

@MainActor
extension TaskFileMigrationTests {
    func testP3S2QuarantineReleaseRequiresIndependentOriginalsAndUnchangedSource() async throws {
        for unsafe in [false, true] {
            let references = try await legacyFiles(["interrupted.txt", "second.txt"])
            let rootID = try insertTask(shown: references)
            let noteID = UUID()
            let writes: Set<WorkspaceOwner> = [.init(entity: .note, id: noteID), .init(entity: .migration, id: rootID)]
            let reads = writes.union([.init(entity: .task, id: rootID)])
            let staged = try await references.asyncMapForMigrationTest { reference in
                let url = try await self.files.files.materializedURL(for: reference.fileReference)
                return StagedNoteAttachment(id: reference.id, filename: reference.filename, contentTypeIdentifier: reference.contentTypeIdentifier,
                    byteCount: reference.byteCount, digest: reference.digest, data: try Data(contentsOf: url))
            }
            let envelope = try coordinator.newEnvelope(intent: "Move Files into Note", reads: coordinator.capture(reads), writes: writes, staged: staged)
            _ = try await coordinator.journal.prepareOperation(envelope)
            let inventory = try await coordinator.journal.operationInventory()
            let item = try XCTUnwrap(inventory.first { $0.envelope?.id == envelope.id })
            try Data([0]).write(to: item.directory.appendingPathComponent(references[1].id.uuidString))
            try await coordinator.reconcileStartup()
            if unsafe {
                let edit = coordinator.freshContext()
                for row in try edit.fetch(FetchDescriptor<TaskItem>()) where row.id == rootID { row.title += " changed" }
                try edit.save()
            }
            let result = await migrate(rootID)
            if unsafe {
                XCTAssertEqual(result, .deferred, "a changed source stays held for Review")
            } else {
                guard case .migrated = result else { XCTFail("independent bytes and unchanged intent permit a fresh retry: \(result)"); continue }
                let artifacts = try await coordinator.journal.operationInventory().filter { $0.envelope?.id == envelope.id }
                XCTAssertEqual(artifacts.count, 1, "keep the quarantine artifact")
                XCTAssertTrue(artifacts[0].quarantined)
                XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts[0].directory.appendingPathComponent("verified-abort.json").path))
                try await coordinator.reconcileStartup()
                let retry = await migrate(rootID)
                XCTAssertEqual(retry, .unchanged)
            }
        }
    }
}

private extension Array where Element: Sendable {
    func asyncMapForMigrationTest<T: Sendable>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}

@MainActor
extension TaskFileMigrationTests {
    func testP3S2ReversalRefusesTextOnlyRecoveryForTheNote() async throws {
        let refs = try await legacyFiles(["recovery.txt"])
        let id = try insertTask(shown: refs)
        guard case let .migrated(noteID, _) = await migrate(id) else { return XCTFail() }
        let row = try XCTUnwrap(all(NoteItem.self).first { $0.id == noteID })
        let draft = NoteDocument(blocks: [.text("Task"), .text("New writing after removing the files")])
        let entry = NoteDraftJournalEntry(noteID: noteID, isPersisted: true, baseRevisionID: row.revisionID,
            content: try NoteContentCodec.encode(draft), selectionLocation: 0, selectionLength: 0, staged: [], savedAt: Date())
        _ = try await coordinator.journal.writeDurably(entry, staged: [])
        let outcome = await TaskAttachmentMigration.reverse(rootID: id, coordinator: coordinator)
        guard case .refused = outcome else { return XCTFail("a note recovery dependency matters even when it references no file bytes") }
    }

    func testP3S2UnreadableIntentKeepsBytesAndReviewWithoutFreezingWrites() async throws {
        let refs = try await legacyFiles(["unknown.txt"])
        let rootID = try insertTask(shown: refs)
        let owner = WorkspaceOwner(entity: .migration, id: rootID)
        let envelope = try coordinator.newEnvelope(intent: "Move Files into Note", reads: coordinator.capture([owner]), writes: [owner])
        _ = try await coordinator.journal.prepareOperation(envelope)
        let inventory = try await coordinator.journal.operationInventory()
        let item = try XCTUnwrap(inventory.first { $0.envelope?.id == envelope.id })
        try Data([0]).write(to: item.directory.appendingPathComponent("intent.json"))
        try Data([0]).write(to: item.directory.appendingPathComponent("envelope.json"))
        try await coordinator.reconcileStartup()
        let outcome = await migrate(rootID)
        guard case .migrated = outcome else { return XCTFail("no readable owner evidence may freeze this write") }
        XCTAssertNil(coordinator.ownership.tryAcquire([UUID()], kind: .collection), "unclassified byte damage still retains collection")
        XCTAssertFalse(coordinator.operationRecoveryIssues.isEmpty)
    }
}

@MainActor
extension TaskFileMigrationTests {
    private func interruptedCopy(_ document: NoteDocument, noteID: UUID, name: String? = nil) throws -> URL {
        let pre = NoteDraftJournalEntry(noteID: noteID, isPersisted: true, baseRevisionID: nil,
            content: try NoteContentCodec.encode(document), selectionLocation: 0, selectionLength: 0,
            staged: [], savedAt: Date(), tags: ["recovered"], tagsChanged: false)
        let folder = coordinator.journal.directory.appendingPathComponent("operations")
            .appendingPathComponent(name ?? "preparing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try WorkspaceModelFields.encode(pre).write(to: folder.appendingPathComponent("pre-draft.json"))
        return folder
    }

    private func recoveryPages() async -> NotesPageController {
        let store = NoteStore(container: container, attachmentFileStore: AttachmentFileStore(rootURL: root.appendingPathComponent("NoteFiles")))
        await store.waitForAttachmentReconciliation()
        let pages = NotesPageController(store: store, journal: coordinator.journal, defaults: nil)
        await pages.recoverAtLaunchAndWait()
        return pages
    }

    func testP3S2R3EmptyAndUnreadablePreIntentFoldersLeaveReviewForQuarantineTrash() async throws {
        for name in ["preparing-\(UUID().uuidString)", UUID().uuidString] {
            let folder = coordinator.journal.directory.appendingPathComponent("operations").appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if UUID(uuidString: name) != nil { try Data("damaged pre-copy".utf8).write(to: folder.appendingPathComponent("pre-draft.json")) }
            try Data("keep artifact bytes".utf8).write(to: folder.appendingPathComponent("sentinel"))
        }
        for _ in 0..<2 {
            try reopen(); try await coordinator.finishLaunch()
            XCTAssertTrue(coordinator.operationRecoveryIssues.isEmpty, "nothing readable to review")
            let trash = coordinator.journal.directory.appendingPathComponent("quarantine-trash")
            let archived = (try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? []
            XCTAssertEqual(archived.count, 2)
            for folder in archived { XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("sentinel")), Data("keep artifact bytes".utf8)) }
            XCTAssertTrue(coordinator.retryHeldWrites())
        }
    }

    func testP3S2R3DiscardReleasesOnlyItsCopyAndAllowsMoveFilesBack() async throws {
        let refs = try await legacyFiles(["discard.txt"]), id = try insertTask(shown: refs)
        guard case let .migrated(noteID, _) = await migrate(id) else { return XCTFail("seed migration") }
        var draft = try document(noteID); draft.blocks.append(.text("Interrupted writing"))
        _ = try interruptedCopy(draft, noteID: noteID)
        _ = try interruptedCopy(draft, noteID: noteID)
        try reopen(); try await coordinator.finishLaunch()
        let pages = await recoveryPages()
        XCTAssertEqual(pages.workspaceRecoveryIssues.count, 2)
        guard case .refused = await TaskAttachmentMigration.reverse(rootID: id, coordinator: coordinator) else { return XCTFail("recovery must hold reversal") }
        let first = try XCTUnwrap(pages.workspaceRecoveryIssues.first)
        XCTAssertTrue(first.previewText?.contains("Interrupted writing") == true)
        try await pages.discardWorkspaceRecovery(first)
        XCTAssertEqual(pages.workspaceRecoveryIssues.count, 1)
        XCTAssertTrue(coordinator.retainedRecoveryBytes.contains(refs[0].id), "the other operation still owns these bytes")
        try await pages.discardWorkspaceRecovery(XCTUnwrap(pages.workspaceRecoveryIssues.first))
        XCTAssertTrue(pages.workspaceRecoveryIssues.isEmpty)
        XCTAssertFalse(coordinator.retainedRecoveryBytes.contains(refs[0].id))
        let reversed = await TaskAttachmentMigration.reverse(rootID: id, coordinator: coordinator)
        XCTAssertEqual(reversed, .reversed)
        let originalKept = await originalExists(refs[0])
        XCTAssertTrue(originalKept)
        XCTAssertFalse(try all(NoteAttachment.self).filter { $0.id == refs[0].id }.isEmpty)
        try reopen(); try await coordinator.finishLaunch()
        XCTAssertTrue(coordinator.operationRecoveryIssues.isEmpty)
    }

    func testP3S2R3RestoreAsNewNoteCopiesFilesAndReleasesTheOldRecoveryOwner() async throws {
        let refs = try await legacyFiles(["restore.txt"]), id = try insertTask(shown: refs)
        guard case let .migrated(noteID, _) = await migrate(id) else { return XCTFail("seed migration") }
        let saved = try document(noteID)
        var draft = saved; draft.blocks.append(.text("Interrupted writing restored"))
        _ = try interruptedCopy(draft, noteID: noteID)
        try reopen(); try await coordinator.finishLaunch()
        let pages = await recoveryPages()
        let newID = try await pages.restoreWorkspaceRecoveryAsNewNote(XCTUnwrap(pages.workspaceRecoveryIssues.first))
        XCTAssertNotEqual(newID, noteID)
        let row = try XCTUnwrap(all(NoteItem.self).first { $0.id == newID })
        XCTAssertNil(row.taskID)
        XCTAssertEqual(row.tags, ["recovered"])
        let restored = try document(newID)
        XCTAssertFalse(restored.requires.contains("taskNote"))
        XCTAssertTrue(NoteTextExport.plainText(restored).contains("Interrupted writing restored"))
        XCTAssertEqual(try document(noteID), saved)
        let newFile = try XCTUnwrap(restored.attachmentIDs.first)
        XCTAssertNotEqual(newFile, refs[0].id, "restored files have independent owners")
        let attachment = try XCTUnwrap(all(NoteAttachment.self).first { $0.id == newFile })
        XCTAssertEqual(attachment.contentDigest, refs[0].digest)
        XCTAssertEqual(attachment.payload?.count, Int(refs[0].byteCount))
        XCTAssertTrue(pages.workspaceRecoveryIssues.isEmpty)
        let reversed = await TaskAttachmentMigration.reverse(rootID: id, coordinator: coordinator)
        XCTAssertEqual(reversed, .reversed)
        let originalKept = await originalExists(refs[0])
        XCTAssertTrue(originalKept)
        try reopen(); try await coordinator.finishLaunch()
        XCTAssertTrue(coordinator.operationRecoveryIssues.isEmpty)
        XCTAssertEqual(try document(newID), restored)
    }

    func testP3S2R3EqualStoredPreDraftAutoReleasesItsRetention() async throws {
        let refs = try await legacyFiles(["equal.txt"]), id = try insertTask(shown: refs)
        guard case let .migrated(noteID, _) = await migrate(id) else { return XCTFail("seed migration") }
        _ = try interruptedCopy(document(noteID), noteID: noteID)
        try reopen(); try await coordinator.finishLaunch()
        XCTAssertTrue(coordinator.operationRecoveryIssues.isEmpty)
        XCTAssertFalse(coordinator.retainedRecoveryBytes.contains(refs[0].id))
        let reversed = await TaskAttachmentMigration.reverse(rootID: id, coordinator: coordinator)
        XCTAssertEqual(reversed, .reversed)
        let originalKept = await originalExists(refs[0])
        XCTAssertTrue(originalKept)
    }
}

@MainActor
extension TaskFileMigrationTests {
    func testP3S2R3RestoreIgnoresAnUnusedPayloadThatNeverReachedDisk() async throws {
        let folder = try interruptedCopy(NoteDocument(blocks: [.text("Readable before writing")]), noteID: UUID())
        let file = folder.appendingPathComponent("pre-draft.json")
        var pre = try JSONDecoder().decode(NoteDraftJournalEntry.self, from: Data(contentsOf: file))
        pre.staged = [.init(id: UUID(), filename: "not-in-the-before-document.txt", contentTypeIdentifier: "public.plain-text", byteCount: 4, digest: "unwritten")]
        try WorkspaceModelFields.encode(pre).write(to: file)
        try reopen(); try await coordinator.finishLaunch()
        let pages = await recoveryPages()
        let restored = try await pages.restoreWorkspaceRecoveryAsNewNote(XCTUnwrap(pages.workspaceRecoveryIssues.first))
        XCTAssertEqual(try document(restored).title, "Readable before writing")
        XCTAssertTrue(try document(restored).attachmentIDs.isEmpty)
        XCTAssertTrue(pages.workspaceRecoveryIssues.isEmpty)
    }

    func testP3S2R3ConcurrentResolutionCannotReinstallAnArchivedRecoveryHold() async throws {
        let refs = try await legacyFiles(["concurrent.txt"]), id = try insertTask(shown: refs)
        guard case let .migrated(noteID, _) = await migrate(id) else { return XCTFail("seed migration") }
        var draft = try document(noteID); draft.blocks.append(.text("Different interrupted writing"))
        _ = try interruptedCopy(draft, noteID: noteID)
        _ = try interruptedCopy(draft, noteID: noteID)
        try reopen(); try await coordinator.finishLaunch()
        let pages = await recoveryPages(), issues = pages.workspaceRecoveryIssues
        XCTAssertEqual(issues.count, 2)
        let entered = expectation(description: "first resolution comparing remaining copy")
        var resume: CheckedContinuation<Void, Never>?
        var paused = false
        coordinator.beforeRecoveryComparison = {
            guard !paused else { return }; paused = true
            entered.fulfill()
            await withCheckedContinuation { resume = $0 }
        }
        let first = Task { try await pages.discardWorkspaceRecovery(issues[0]) }
        await fulfillment(of: [entered], timeout: 2)
        var reconciliationRefused = false
        do { try await coordinator.reconcileStartup() } catch { reconciliationRefused = true }
        var secondRefused = false
        do { try await pages.discardWorkspaceRecovery(issues[1]) } catch { secondRefused = true }
        resume?.resume(); resume = nil
        try await first.value
        coordinator.beforeRecoveryComparison = nil
        XCTAssertTrue(reconciliationRefused, "runtime reconciliation shares the same transaction guard")
        XCTAssertTrue(secondRefused, "resolution transactions must serialize")
        XCTAssertEqual(pages.workspaceRecoveryIssues.count, 1)
        XCTAssertTrue(coordinator.retainedRecoveryBytes.contains(refs[0].id))
        try await pages.discardWorkspaceRecovery(issues[1])
        XCTAssertTrue(pages.workspaceRecoveryIssues.isEmpty)
        XCTAssertFalse(coordinator.retainedRecoveryBytes.contains(refs[0].id))
        let reversed = await TaskAttachmentMigration.reverse(rootID: id, coordinator: coordinator)
        XCTAssertEqual(reversed, .reversed)
    }
}

@MainActor
extension TaskFileMigrationTests {
    func testP3S2R3RestorePlacesPendingTaskTextInTheBodyOfTheOrdinaryCopy() async throws {
        let source = try NoteDocument(blocks: [.text("Heading"), .text("Existing body")]).taskSnapshot(title: "Heading")
        let folder = try interruptedCopy(source, noteID: UUID())
        let file = folder.appendingPathComponent("pre-draft.json")
        var pre = try JSONDecoder().decode(NoteDraftJournalEntry.self, from: Data(contentsOf: file))
        pre.pendingImport = .init(anchor: 0, acceptedText: "Pasted before body\n", items: [], remainingNames: [])
        try WorkspaceModelFields.encode(pre).write(to: file)
        try reopen(); try await coordinator.finishLaunch()
        let pages = await recoveryPages()
        XCTAssertTrue(pages.workspaceRecoveryIssues.first?.previewText?.contains("Pasted before body") == true)
        let restored = try await pages.restoreWorkspaceRecoveryAsNewNote(XCTUnwrap(pages.workspaceRecoveryIssues.first))
        let copy = try document(restored)
        XCTAssertEqual(copy.title, "Heading")
        XCTAssertTrue(NoteTextExport.plainBody(copy).hasPrefix("Pasted before body"))
        XCTAssertTrue(NoteTextExport.plainBody(copy).contains("Existing body"))
        XCTAssertFalse(copy.requires.contains("taskNote"))
    }
}

@MainActor
extension TaskFileMigrationTests {
    func testP3S2R3RestorePreservesPendingPasteIntoAnOrdinaryTitle() async throws {
        let source = try NoteDocument(blocks: [.text("Heading"), .text("Existing body")])
        let folder = try interruptedCopy(source, noteID: UUID())
        let file = folder.appendingPathComponent("pre-draft.json")
        var pre = try JSONDecoder().decode(NoteDraftJournalEntry.self, from: Data(contentsOf: file))
        pre.pendingImport = .init(anchor: 0, acceptedText: "Pasted ", items: [], remainingNames: [])
        try WorkspaceModelFields.encode(pre).write(to: file)
        try reopen(); try await coordinator.finishLaunch()
        let pages = await recoveryPages()
        let restored = try await pages.restoreWorkspaceRecoveryAsNewNote(XCTUnwrap(pages.workspaceRecoveryIssues.first))
        XCTAssertEqual(try document(restored).title, "Pasted Heading")
        XCTAssertTrue(NoteTextExport.plainBody(try document(restored)).contains("Existing body"))
    }

    func testP3S2R3DiscardCanRetryAfterTheArchiveRenameButBeforeSync() async throws {
        let refs = try await legacyFiles(["retry.txt"]), id = try insertTask(shown: refs)
        guard case let .migrated(noteID, _) = await migrate(id) else { return XCTFail("seed migration") }
        var draft = try document(noteID); draft.blocks.append(.text("Interrupted writing"))
        _ = try interruptedCopy(draft, noteID: noteID)
        try reopen(); try await coordinator.finishLaunch()
        let pages = await recoveryPages(), issue = try XCTUnwrap(pages.workspaceRecoveryIssues.first)
        await coordinator.journal.failNextRecoveryArchiveAfterRename()
        do { try await pages.discardWorkspaceRecovery(issue); XCTFail("injected sync failure") }
        catch { XCTAssertEqual(error as? WorkspaceFoundationError, .preparationFailed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: issue.directory.path), "failure occurred after the rename")
        XCTAssertTrue(coordinator.retainedRecoveryBytes.contains(refs[0].id), "unacknowledged archival keeps retention")
        var retried = false
        do { try await pages.discardWorkspaceRecovery(issue); retried = true } catch {}
        XCTAssertTrue(retried, "the same confirmation must finish its durable rename on retry")
        XCTAssertTrue(pages.workspaceRecoveryIssues.isEmpty)
        XCTAssertFalse(coordinator.retainedRecoveryBytes.contains(refs[0].id))
        let reversed = await TaskAttachmentMigration.reverse(rootID: id, coordinator: coordinator)
        XCTAssertEqual(reversed, .reversed)
    }

    func testP3S2R3DiscardChecksBothReceiptIdentitiesOfADamagedFolder() async throws {
        let owner = WorkspaceOwner(entity: .note, id: UUID()), receiptOwner = WorkspaceOwner(entity: .task, id: UUID())
        let envelope = try coordinator.newEnvelope(intent: "Damaged identity", reads: coordinator.capture([owner]), writes: [owner])
        let rootID = UUID()
        let folder = try interruptedCopy(NoteDocument(blocks: [.text("Recovery writing")]), noteID: owner.id, name: rootID.uuidString)
        try WorkspaceModelFields.encode(envelope).write(to: folder.appendingPathComponent("intent.json"))
        let context = coordinator.freshContext()
        context.insert(OperationReceipt(id: rootID, envelopeDigest: "uncertain", affectedIDs: try WorkspaceModelFields.encode([receiptOwner]), resultingTokens: Data()))
        try context.save()
        do { try await coordinator.finishLaunch() } catch {}
        let issue = try XCTUnwrap(coordinator.operationRecoveryIssues.first)
        var refused = false
        do { try await coordinator.discardOperationRecovery(issue) } catch { refused = true }
        XCTAssertTrue(refused, "a receipt at either identity still owns recovery")
        XCTAssertFalse(coordinator.retryHeldWrites(affecting: [receiptOwner]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: issue.directory.path))
    }
}
