import AppKit
import CoreData
import CryptoKit
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import Attic

/// The app persistence stack migrates only a disposable copy. The subsequent
/// read-only format audit bypasses startup reconciliation and never saves notes.
@MainActor
private enum MigrationCopyAudit {
    static func runThroughApplication(storeURL: URL) throws -> Report {
        let directory = storeURL.deletingLastPathComponent()
        let configuration = PersistenceController.makeConfiguration(cloudSyncEnabled: false, storeDirectory: directory)
        guard configuration.url.standardizedFileURL == storeURL.standardizedFileURL else {
            throw NSError(domain: "AtticMigrationAudit.StoreName", code: 1)
        }
        let before = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: storeURL)
        let oldHashes = before[NSStoreModelVersionHashesKey] as? [String: Data]
        // Exactly the local app's constructor: inferred migration is enabled by
        // SwiftData. No alternate Core Data mapping or migration options here.
        try autoreleasepool {
            let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: directory)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            _ = try context.fetch(FetchDescriptor<TaskItem>())
            _ = try context.fetch(FetchDescriptor<CanvasBoardItem>())
            _ = try context.fetch(FetchDescriptor<CanvasStrokeItem>())
            _ = try context.fetch(FetchDescriptor<CanvasImageItem>())
            _ = try context.fetch(FetchDescriptor<CanvasSemanticObjectItem>())
            _ = try context.fetch(FetchDescriptor<NoteItem>())
            _ = try context.fetch(FetchDescriptor<NoteAttachment>())
        }
        let after = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: storeURL)
        let newHashes = after[NSStoreModelVersionHashesKey] as? [String: Data]
        let current = try XCTUnwrap(NSManagedObjectModel.makeManagedObjectModel(for: PersistenceController.appModelTypes))
        guard newHashes == current.entityVersionHashesByName else {
            throw NSError(domain: "AtticMigrationAudit.Schema", code: 1)
        }
        var report = try run(storeURL: storeURL)
        report.mode = "application schema migration; read-only format plan, inverse and TextKit 2; no note commit"
        report.schemaMigrated = oldHashes != newHashes
        return report
    }
    struct Row: Codable {
        let noteID: String
        let state: String
        let reason: String?
        let attachments: Int
        let missingPayloads: Int
        let normalizedLineBreaks: Int
        let snappedAnchors: Int
    }
    struct Report: Codable {
        var mode: String = "read-only; projection, inverse and real TextKit 2 round trip; no commit"
        var schemaMigrated: Bool = false
        var status: String = "opened"
        let noteRows: Int
        let taskRows: Int
        let canvasBoards: Int
        let canvasStrokes: Int
        let canvasImages: Int
        let canvasObjects: Int
        let attachmentRows: Int
        let attachmentsFound: Int
        let attachmentsMissing: Int
        let rows: [Row]
        var notesTotal: Int { rows.count }
        var migratedCleanly: Int { rows.filter { $0.state == "verified-migration-candidate" }.count }
        var refused: Int { rows.filter { $0.state == "refused-legacy-editable" }.count }
        var legacy: Int { rows.filter { $0.state == "verified-migration-candidate" || $0.state == "refused-legacy-editable" }.count }
        var alreadyNew: Int { rows.filter { $0.state == "supported-editable" || $0.state == "unsupported-read-only" }.count }
    }

    // Never include associated strings from errors: they can carry private data.
    private static func reasonClass(_ reason: LegacyMigrationRefusal) -> String {
        switch reason {
        case .duplicateAttachmentIDs: "duplicate-attachment-ids"
        case .titleHasLineBreak: "title-line-break"
        case .bodyContainsObjectCharacter: "object-character"
        case .fileAttachment: "file-metadata"
        case .replicasDisagree: "replicas-disagree"
        case .projectionMismatch: "projection-mismatch"
        case .roundTripMismatch: "textkit-round-trip-mismatch"
        case .changedSincePlanned: "revision-changed"
        case .alreadyMigrated: "already-migrated"
        case .saveFailed: "save-failed"
        }
    }

    static func run(storeURL: URL) throws -> Report {
        let model = try XCTUnwrap(NSManagedObjectModel.makeManagedObjectModel(for: PersistenceController.appModelTypes))
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let persistent = try coordinator.addPersistentStore(type: .sqlite, at: storeURL, options: [
            NSReadOnlyPersistentStoreOption: true,
            NSMigratePersistentStoresAutomaticallyOption: false,
            NSInferMappingModelAutomaticallyOption: false
        ])
        defer { try? coordinator.remove(persistent) }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let notes = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "NoteItem"))
        let attachments = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "NoteAttachment"))
        func payload(_ row: NSManagedObject) -> Data? {
            if let bytes = row.value(forKey: "payload") as? Data { return bytes }
            guard let id = row.value(forKey: "id") as? UUID,
                  let digest = row.value(forKey: "contentDigest") as? String, !digest.isEmpty,
                  digest != ".", digest != "..", !digest.contains("/"), !digest.contains("\\"),
                  let originalFilename = row.value(forKey: "originalFilename") as? String else { return nil }
            let filename = AttachmentFileStore.sanitizedFilename(originalFilename)
            guard
                  !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"),
                  !filename.contains("\\") else { return nil }
            let url = storeURL.deletingLastPathComponent().appendingPathComponent("Attic/Attachments/v1")
                .appendingPathComponent(id.uuidString).appendingPathComponent(digest.lowercased())
                .appendingPathComponent(filename)
            return try? Data(contentsOf: url)
        }
        let found = attachments.filter { payload($0) != nil }.count
        let families = try Dictionary(grouping: notes, by: { try XCTUnwrap($0.value(forKey: "id") as? UUID) })
        var results: [Row] = []
        for id in families.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let family = families[id]!
            let note = family[0]
            // A deleted physical replica prevents migration of the family.
            if family.contains(where: { $0.value(forKey: "deletedAt") != nil }) {
                results.append(Row(noteID: id.uuidString, state: "skipped-deleted-family", reason: nil,
                    attachments: 0, missingPayloads: 0, normalizedLineBreaks: 0, snappedAnchors: 0))
                continue
            }
            func number(_ row: NSManagedObject, _ key: String) -> Int { (row.value(forKey: key) as? NSNumber)?.intValue ?? 0 }
            let formats = family.map { number($0, "contentFormat") }
            if formats.allSatisfy({ $0 >= 1 }) {
                let contents = family.map { $0.value(forKey: "content") as? Data }
                let data = contents[0]
                let editable = contents.allSatisfy { $0 == data } && data.map {
                    if case .editable = NoteContentCodec.decode($0) { return true }; return false
                } == true && formats.allSatisfy { $0 == NoteDocument.currentFormat }
                results.append(Row(noteID: id.uuidString, state: editable ? "supported-editable" : "unsupported-read-only",
                    reason: editable ? nil : "unsupported-or-divergent-document", attachments: 0, missingPayloads: 0,
                    normalizedLineBreaks: 0, snappedAnchors: 0))
                continue
            }
            var refusal: LegacyMigrationRefusal?
            let title = note.value(forKey: "title") as? String ?? ""
            let body = note.value(forKey: "body") as? String ?? ""
            if !formats.allSatisfy({ $0 == 0 }) || !family.allSatisfy({
                NoteTextReplacement.utf16Equal($0.value(forKey: "title") as? String ?? "", title) &&
                NoteTextReplacement.utf16Equal($0.value(forKey: "body") as? String ?? "", body)
            }) { refusal = .replicasDisagree }
            let physical = attachments.filter {
                $0.value(forKey: "noteID") as? UUID == id && $0.value(forKey: "deletedAt") == nil
            }
            var byID: [UUID: LegacyNoteSnapshot.Attachment] = [:]
            var digests: [UUID: String] = [:]
            for row in physical {
                let attachmentID = try XCTUnwrap(row.value(forKey: "id") as? UUID)
                let type = row.value(forKey: "contentTypeIdentifier") as? String ?? "public.data"
                let value = LegacyNoteSnapshot.Attachment(id: attachmentID,
                    inlineOffset: (row.value(forKey: "inlineOffset") as? NSNumber)?.intValue,
                    sortIndex: (row.value(forKey: "sortIndex") as? NSNumber)?.int64Value ?? 0,
                    createdAt: try XCTUnwrap(row.value(forKey: "createdAt") as? Date),
                    isImage: UTType(type)?.conforms(to: .image) == true,
                    filename: row.value(forKey: "originalFilename") as? String ?? "",
                    contentTypeIdentifier: type,
                    byteCount: (row.value(forKey: "byteCount") as? NSNumber)?.int64Value ?? 0,
                    payload: payload(row))
                let digest = row.value(forKey: "contentDigest") as? String ?? ""
                if let old = byID[attachmentID], old != value || digests[attachmentID] != digest { refusal = .replicasDisagree }
                byID[attachmentID] = value
                digests[attachmentID] = digest
            }
            var breaks = 0, snapped = 0
            if refusal == nil {
                let snapshot = LegacyNoteSnapshot(noteID: id, title: title, body: body,
                    attachments: Array(byID.values), revisionToken: "read-only-copy")
                switch LegacyNoteMigration.plan(snapshot) {
                case let .failure(reason): refusal = reason
                case let .success(plan):
                    breaks = plan.normalizedLineBreaks; snapped = plan.snappedAnchors
                    if case let .failure(reason) = LegacyNoteMigration.verify(plan, roundTrip: {
                        NoteTextKitRoundTrip.document(afterRoundTrip: $0)
                    }) { refusal = reason }
                }
            }
            results.append(Row(noteID: id.uuidString, state: refusal == nil ? "verified-migration-candidate" : "refused-legacy-editable",
                reason: refusal.map(reasonClass), attachments: byID.count,
                missingPayloads: byID.values.filter { $0.payload == nil }.count,
                normalizedLineBreaks: breaks, snappedAnchors: snapped))
        }
        func count(_ entity: String) throws -> Int {
            try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entity))
        }
        return try Report(noteRows: notes.count, taskRows: count("TaskItem"),
            canvasBoards: count("CanvasBoardItem"), canvasStrokes: count("CanvasStrokeItem"),
            canvasImages: count("CanvasImageItem"), canvasObjects: count("CanvasSemanticObjectItem"),
            attachmentRows: attachments.count, attachmentsFound: found,
            attachmentsMissing: attachments.count - found, rows: results)
    }
}

@MainActor
final class NotesMigrationAcceptanceTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = ownedTemporaryDirectory(prefix: "AtticS6Fixtures")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func store(in name: String, gate: PersistenceGate? = nil) throws -> NoteStore {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: directory)
        let result = NoteStore(container: container, persist: { context in
            if let gate { try gate.save(context) } else { try context.save() }
        }, attachmentFileStore: makeTestAttachmentFileStore(rootURL: root.appendingPathComponent("files")))
        addTeardownBlock { [weak result] in await result?.waitForAttachmentReconciliation() }
        return result
    }

    private func seed(_ store: NoteStore) throws -> UUID {
        let note = NoteItem(title: "Trip", body: "First\r\nSecond\n")
        store.modelContext.insert(note)
        // Includes missing bytes, equal sort/time ties, nil/end/past-end and mid-paragraph anchors.
        for (index, offset) in [Optional(0), 8, nil, 15, 999].enumerated() {
            let row = NoteAttachment(id: UUID(uuidString: String(format: "60000000-0000-0000-0000-%012d", index + 1))!,
                noteID: note.id, originalFilename: "\(index).png", contentTypeIdentifier: "public.png",
                byteCount: 2, sortIndex: 0, contentDigest: "fixture", createdAt: Date(timeIntervalSince1970: 0),
                payload: index == 2 ? nil : Data([UInt8(index), 0]))
            row.inlineOffset = offset
            store.modelContext.insert(row)
        }
        try store.modelContext.save()
        try store.reloadPresentation()
        return note.id
    }

    func testMigrationAndRecoverySurviveFreshDiskContexts() async throws {
        let gate = PersistenceGate()
        var first: NoteStore? = try store(in: "restart", gate: gate)
        let id = try seed(first!)
        let before = try first!.legacySnapshot(noteID: id).get()
        let plan = try LegacyNoteMigration.plan(before).get()
        XCTAssertEqual(plan.document.blocks.map { $0.kind == .image ? $0.attachmentID!.uuidString.suffix(1).description : $0.text },
                       ["Trip", "1", "First", "2", "Second", "", "3", "4", "5"])
        let verified = try LegacyNoteMigration.verify(plan, roundTrip: { NoteTextKitRoundTrip.document(afterRoundTrip: $0) }).get()
        gate.shouldFail = true
        guard case .failure(.saveFailed) = first!.commitMigration(verified) else { return XCTFail("injected save must refuse") }
        gate.shouldFail = false
        let afterFailure = try store(in: "restart")
        XCTAssertEqual(try afterFailure.legacySnapshot(noteID: id).get(), before)
        XCTAssertTrue(afterFailure.versions(noteID: id).isEmpty)
        _ = try first!.commitMigration(verified).get()
        await first!.waitForAttachmentReconciliation()
        first = nil
        let reopened = try store(in: "restart", gate: gate)
        XCTAssertEqual(reopened.loadDocument(noteID: id)?.content.document, plan.document)
        XCTAssertEqual(reopened.note(withID: id)?.body, before.body)
        XCTAssertTrue(reopened.versions(noteID: id).contains { $0.reason == .beforeMigration && $0.body == before.body })
        let rows = try reopened.attachmentRows(forNoteID: id)
        XCTAssertEqual(rows.count, before.attachments.count)
        for row in rows {
            let source = try XCTUnwrap(before.attachments.first { $0.id == row.id })
            XCTAssertEqual(row.payload, source.payload)
            XCTAssertEqual(row.inlineOffset, source.inlineOffset)
        }
        let journalURL = root.appendingPathComponent("journal")
        let controller = NotesPageController(store: reopened, journal: NoteDraftJournal(directory: journalURL), saveDelay: .seconds(60))
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
            with: NSAttributedString(string: " recovered"), name: "Typing")
        let unsaved = session.engine.document()
        gate.shouldFail = true
        await XCTAssertTrueAsync(await controller.preserveDurably(session))
        gate.shouldFail = false
        let restarted = NotesPageController(store: try store(in: "restart"), journal: NoteDraftJournal(directory: journalURL), saveDelay: .seconds(60))
        await restarted.recoverAtLaunchAndWait()
        await restarted.startAndWait()
        XCTAssertEqual(restarted.active?.noteID, id)
        XCTAssertEqual(restarted.active?.engine.document(), unsaved)
        session.engine.detachView()
    }

    func testRefusedLegacyAndFutureReadOnlyRemainUsableAfterRestart() async throws {
        let initial = try store(in: "states")
        let legacy = NoteItem(title: "Refused\nTitle", body: "Still editable")
        let future = NoteItem(title: "Future")
        future.contentFormat = 8
        let bytes = Data(#"{"format":8,"blocks":[{"kind":"text","text":"Future"},{"kind":"new-widget","data":"kept"}]}"#.utf8)
        future.content = bytes
        initial.modelContext.insert(legacy); initial.modelContext.insert(future)
        try initial.modelContext.save(); try initial.reloadPresentation()
        guard case .failure(.titleHasLineBreak) = LegacyNoteMigration.plan(try initial.legacySnapshot(noteID: legacy.id).get()) else { return XCTFail() }
        let reopened = try store(in: "states")
        let controller = NotesPageController(store: reopened, journal: NoteDraftJournal(directory: root.appendingPathComponent("journal")))
        await XCTAssertTrueAsync(await controller.openDurably(noteID: legacy.id))
        XCTAssertEqual(controller.legacyNoteID, legacy.id)
        XCTAssertTrue(reopened.update(try XCTUnwrap(reopened.note(withID: legacy.id)), body: "Legacy edit saved"))
        await XCTAssertTrueAsync(await controller.openDurably(noteID: future.id))
        XCTAssertTrue(controller.active?.isReadOnly == true)
        XCTAssertTrue(controller.active?.engine.document().blocks.contains { $0.kind == .opaque } == true)
        XCTAssertTrue(reopened.setTags(["kept"], for: try XCTUnwrap(reopened.note(withID: future.id))))
        let third = try store(in: "states")
        XCTAssertEqual(third.note(withID: legacy.id)?.body, "Legacy edit saved")
        XCTAssertEqual(third.note(withID: legacy.id)?.contentFormat, 0)
        XCTAssertEqual(third.note(withID: future.id)?.content, bytes)
    }

    func testReadOnlyAuditUsesSeededCopyAndLeavesEveryByteUnchanged() async throws {
        var seedStore: NoteStore? = try store(in: "audit-seed")
        _ = try seed(seedStore!)
        let refused = NoteItem(title: "Two\nlines", body: "Kept")
        seedStore!.modelContext.insert(refused)
        try seedStore!.modelContext.save()
        await seedStore!.waitForAttachmentReconciliation()
        seedStore = nil
        let copied = root.appendingPathComponent("audit-copy")
        try FileManager.default.copyItem(at: root.appendingPathComponent("audit-seed"), to: copied)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: copied, includingPropertiesForKeys: [.isRegularFileKey]))
            .allObjects.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        for file in files { try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path) }
        defer { for file in files { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) } }
        let before = try fileHashes(copied)
        let storeURL = PersistenceController.makeConfiguration(cloudSyncEnabled: false, storeDirectory: copied).url
        let report = try MigrationCopyAudit.run(storeURL: storeURL)
        XCTAssertEqual(report.rows.map(\.state).sorted(), ["refused-legacy-editable", "verified-migration-candidate"])
        XCTAssertEqual(report.rows.first { $0.state == "verified-migration-candidate" }?.missingPayloads, 1)
        XCTAssertEqual(try fileHashes(copied), before, "read-only audit cannot mutate even the copy")
    }

    private func fileHashes(_ directory: URL) throws -> [String: String] {
        var hashes: [String: String] = [:]
        for case let url as URL in try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])) {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                hashes[url.path.replacingOccurrences(of: directory.path, with: "")] = SHA256.hash(data: try Data(contentsOf: url)).description
            }
        }
        return hashes
    }

    func testDailySchemaDryRunOpensThroughApplicationAndPreservesReplicas() throws {
        let source = root.appendingPathComponent("daily-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let url = PersistenceController.makeConfiguration(cloudSyncEnabled: false, storeDirectory: source).url
        let id = UUID()
        try autoreleasepool {
            let schema = Schema(SchemaMigrationTests.prePhase0Types)
            let container = try ModelContainer(for: schema,
                configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
            let context = ModelContext(container)
            context.autosaveEnabled = false
            context.insert(PrePhase0.NoteItem(id: id, title: "Fixture", body: "One\r\nTwo"))
            context.insert(PrePhase0.NoteItem(id: id, title: "Fixture", body: "One\r\nTwo"))
            context.insert(PrePhase0.NoteItem(title: "Two\nlines", body: "Kept"))
            context.insert(PrePhase0.TaskItem(id: id, title: "Fixture task"))
            context.insert(PrePhase0.TaskItem(id: id, title: "Fixture task replica"))
            context.insert(PrePhase0.CanvasBoardItem())
            context.insert(PrePhase0.CanvasStrokeItem(payload: Data([1, 2, 3])))
            context.insert(PrePhase0.NoteAttachment(noteID: id, originalFilename: "fixture.txt",
                byteCount: 200_000, sortIndex: 0, contentDigest: "fixture", payload: Data(repeating: 4, count: 200_000)))
            context.insert(PrePhase0.NoteAttachment(noteID: id, originalFilename: "missing.txt",
                byteCount: 3, sortIndex: 1, contentDigest: "missing", payload: nil))
            try context.save()
        }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url)
        XCTAssertEqual(metadata[NSStoreModelVersionIdentifiersKey] as? [String], ["1.0.0"])
        XCTAssertEqual((metadata[NSStoreModelVersionHashesKey] as? [String: Data])?.mapValues { $0.base64EncodedString() },
                       SchemaMigrationTests.baseRevisionEntityHashes)
        // Metadata validation may update SQLite's SHM reader bookkeeping;
        // freeze the source baseline only after fixture construction/validation.
        let before = try fileHashes(source)
        let copy = root.appendingPathComponent("daily-copy")
        try FileManager.default.copyItem(at: source, to: copy)
        let report = try MigrationCopyAudit.runThroughApplication(storeURL: copy.appendingPathComponent(url.lastPathComponent))
        XCTAssertEqual(report.rows.map(\.state).sorted(), ["refused-legacy-editable", "verified-migration-candidate"])
        XCTAssertEqual(report.rows.first { $0.noteID == id.uuidString }?.attachments, 2)
        XCTAssertTrue(report.schemaMigrated)
        XCTAssertEqual(report.noteRows, 3)
        XCTAssertEqual(report.notesTotal, 2)
        XCTAssertEqual(report.taskRows, 2)
        XCTAssertEqual(report.canvasBoards, 1)
        XCTAssertEqual(report.canvasStrokes, 1)
        XCTAssertEqual(report.attachmentsFound, 1)
        XCTAssertEqual(report.attachmentsMissing, 1)
        XCTAssertEqual(report.migratedCleanly, 1)
        XCTAssertEqual(report.refused, 1)
        XCTAssertEqual(report.rows.first { $0.state == "refused-legacy-editable" }?.reason, "title-line-break")
        XCTAssertEqual(try fileHashes(source), before)
        let reopened = try MigrationCopyAudit.runThroughApplication(storeURL: copy.appendingPathComponent(url.lastPathComponent))
        XCTAssertFalse(reopened.schemaMigrated)
        XCTAssertEqual(reopened.noteRows, 3)
        XCTAssertEqual(reopened.taskRows, 2)
        XCTAssertEqual(reopened.attachmentsFound, 1)
    }

    func testExportExplicitDryRunFixture() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let request = repo.appendingPathComponent(".build/migration-fixture-request")
        guard FileManager.default.fileExists(atPath: request.path) else { throw XCTSkip("No fixture export requested") }
        var seeded: NoteStore? = try store(in: "export")
        _ = try seed(seeded!)
        await seeded!.waitForAttachmentReconciliation()
        seeded = nil
        let output = repo.appendingPathComponent(".build/migration-script-fixture")
        guard !FileManager.default.fileExists(atPath: output.path) else { return XCTFail("Fixture destination already exists") }
        try FileManager.default.copyItem(at: root.appendingPathComponent("export"), to: output)
    }

    /// Invoke seed and verify in separate xcodebuild test sessions so the
    /// owning test-host process actually exits between migration and reopen.
    func testSeededMigrationAcrossProcessRestart() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let phaseFile = repo.appendingPathComponent(".build/migration-process-phase")
        guard FileManager.default.fileExists(atPath: phaseFile.path) else { throw XCTSkip("No process-restart fixture requested") }
        let phase = try String(contentsOf: phaseFile).trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = repo.appendingPathComponent(".build/migration-process-fixture")
        if phase == "seed" {
            guard !FileManager.default.fileExists(atPath: directory.path) else { return XCTFail("Refusing to overwrite a fixture") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard phase == "seed" || phase == "verify" else { return XCTFail("Unknown process phase") }
        let gate = PersistenceGate()
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: directory)
        let disk = NoteStore(container: container, persist: { try gate.save($0) },
            attachmentFileStore: makeTestAttachmentFileStore(rootURL: directory.appendingPathComponent("files")))
        addTeardownBlock { [weak disk] in await disk?.waitForAttachmentReconciliation() }
        let journal = NoteDraftJournal(directory: directory.appendingPathComponent("journal"))
        let controller = NotesPageController(store: disk, journal: journal, saveDelay: .seconds(60))
        let recordURL = directory.appendingPathComponent("expected.json")
        if phase == "seed" {
            let id = try seed(disk)
            let plan = try LegacyNoteMigration.plan(disk.legacySnapshot(noteID: id).get()).get()
            _ = try disk.commitMigration(LegacyNoteMigration.verify(plan, roundTrip: {
                NoteTextKitRoundTrip.document(afterRoundTrip: $0)
            }).get()).get()
            await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
            let session = try XCTUnwrap(controller.active)
            session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
                with: NSAttributedString(string: " process recovery"), name: "Typing")
            gate.shouldFail = true
            await XCTAssertTrueAsync(await controller.preserveDurably(session))
            let record = ["id": id.uuidString,
                "saved": try NoteContentCodec.encode(plan.document).base64EncodedString(),
                "unsaved": try NoteContentCodec.encode(session.engine.document()).base64EncodedString()]
            try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
        } else {
            let record = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: recordURL))
            let id = try XCTUnwrap(record["id"].flatMap(UUID.init(uuidString:)))
            XCTAssertEqual(disk.note(withID: id)?.content, record["saved"].flatMap { Data(base64Encoded: $0) })
            XCTAssertTrue(disk.versions(noteID: id).contains { $0.reason == .beforeMigration && $0.body == "First\r\nSecond\n" })
            XCTAssertEqual(try disk.attachmentRows(forNoteID: id).count, 5)
            await controller.startAndWait()
            XCTAssertEqual(controller.active?.noteID, id)
            XCTAssertEqual(try controller.active.map { try NoteContentCodec.encode($0.engine.document()) },
                           record["unsaved"].flatMap { Data(base64Encoded: $0) })
        }
    }

    /// Only the opt-in script creates this request. Ordinary CI skips this test.
    func testOwnerApprovedCopiedStoreDryRun() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let requestURL = repo.appendingPathComponent(".build/migration-dry-run-request.json")
        guard FileManager.default.fileExists(atPath: requestURL.path) else { throw XCTSkip("No explicitly approved copy supplied") }
        let request = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: requestURL))
        let copy = URL(fileURLWithPath: try XCTUnwrap(request["copy"]))
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        XCTAssertTrue(copy.resolvingSymlinksInPath().path.hasPrefix(temp), "Only the script's temporary copy is allowed")
        guard copy.resolvingSymlinksInPath().path.hasPrefix(temp) else { return }
        let reportURL = URL(fileURLWithPath: try XCTUnwrap(request["report"]))
        do {
            let report = try MigrationCopyAudit.runThroughApplication(storeURL: copy)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportURL, options: .atomic)
        } catch {
            let failure = error as NSError
            try JSONEncoder().encode(["status": "refused", "reason_domain": failure.domain,
                "reason_code": String(failure.code)]).write(to: reportURL, options: .atomic)
            XCTFail("Disposable store open/audit refused; error domain/code in report")
        }
    }
}
