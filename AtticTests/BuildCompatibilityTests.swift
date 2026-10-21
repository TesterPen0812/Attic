import AppKit
import CryptoKit
import SwiftData
import XCTest
@testable import Attic

/// Golden stores were written by the named historical commits, never by this reader.
/// All mutations run on temporary copies, including external SwiftData payloads.
@MainActor
final class BuildCompatibilityTests: XCTestCase {
    func testInt13OpensOctober10StoreWithoutChangingUntouchedBytes() async throws {
        try await checkFixture("4b25a1fa")
    }

    func testInt13OpensInt12StoreWithoutChangingUntouchedBytes() async throws {
        try await checkFixture("81c124d6")
    }

    func testFixtureProvenanceDoesNotPublishPrivateHomeDirectoryPaths() throws {
        let readme = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Compatibility/README.md")
        let text = try String(contentsOf: readme, encoding: .utf8)
        XCTAssertFalse(text.contains("/Users/"), "public provenance must not point to a developer's home directory")
        XCTAssertFalse(text.contains("/home/"), "public provenance must not point to a developer's home directory")
    }

    private func checkFixture(_ commit: String) async throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Compatibility/\(commit)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attic-compat-\(UUID())")
        try FileManager.default.copyItem(at: source, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try Compat.open(root)
        let golden = try Data(contentsOf: root.appendingPathComponent("snapshot.json"))
        XCTAssertEqual(try Compat.snapshot(container), golden, "Every physical row and persisted field")
        try await Compat.exercise(container, root: root)
        let reopened = try Compat.open(root)
        XCTAssertEqual(try Compat.snapshot(reopened), try Compat.snapshot(container), "Durable reopen")
    }
}

@MainActor
enum Compat {
    final class SaveGate { var fail = false }
    static let clock = Date(timeIntervalSince1970: 1_792_152_000)
    static let noteID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    static let plainID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    static let taskID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    static func dir(_ root: URL, _ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
    static func open(_ root: URL) throws -> ModelContainer {
        // Same schema/configuration as PersistenceController, with explicit filesystem roots.
        let configuration = PersistenceController.makeConfiguration(inMemory: false,
            cloudSyncEnabled: false, storeDirectory: root)
        return try ModelContainer(for: Schema(PersistenceController.appModelTypes), configurations: configuration)
    }
    static func notes(_ container: ModelContainer, _ root: URL) -> NoteStore {
        NoteStore(container: container, now: { clock },
            attachmentFileStore: AttachmentFileStore(rootURL: dir(root, "NoteFiles")))
    }
    static func tasks(_ container: ModelContainer, _ root: URL) -> TaskStore {
        TaskStore(container: container, now: { clock }, taskImageFiles: TaskImageFiles(rootURL: dir(root, "TaskFiles")))
    }
    static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    }
    static func snapshot(_ container: ModelContainer) throws -> Data {
        let c = ModelContext(container); c.autosaveEnabled = false
        func v(_ x: Any?) -> Any {
            guard let x else { return NSNull() }
            if let d = x as? Data { return d.base64EncodedString() }
            if let d = x as? Date { return d.timeIntervalSince1970 }
            if let id = x as? UUID { return id.uuidString }
            return x
        }
        func sorted(_ rows: [[String: Any]]) -> [[String: Any]] {
            rows.sorted { (try! json($0)).lexicographicallyPrecedes(try! json($1)) }
        }
        let n = try c.fetch(FetchDescriptor<NoteItem>()).map { r in
            ["id": v(r.id), "title": v(r.title), "body": v(r.body), "createdAt": v(r.createdAt),
             "updatedAt": v(r.updatedAt), "deletedAt": v(r.deletedAt), "deletedAttachmentIDsRaw": v(r.deletedAttachmentIDsRaw),
             "tagsRaw": v(r.tagsRaw), "pinnedAt": v(r.pinnedAt), "externalEditorName": v(r.externalEditorName),
             "externalEditedAt": v(r.externalEditedAt), "content": v(r.content), "contentFormat": v(r.contentFormat),
             "plainText": v(r.plainText), "imageCount": v(r.imageCount), "fileCount": v(r.fileCount),
             "firstFileName": v(r.firstFileName), "taskID": v(r.taskID), "revision": v(r.revision),
             "revisionID": v(r.revisionID)]
        }
        let t = try c.fetch(FetchDescriptor<TaskItem>()).map { r in
            ["id": v(r.id), "title": v(r.title), "statusRaw": v(r.statusRaw), "priorityRaw": v(r.priorityRaw),
             "createdAt": v(r.createdAt), "updatedAt": v(r.updatedAt), "completedAt": v(r.completedAt),
             "manualOrder": v(r.manualOrder), "parentID": v(r.parentID), "imageReferencesData": v(r.imageReferencesData),
             "deletedAt": v(r.deletedAt), "deletionRootID": v(r.deletionRootID), "deletionMembersRaw": v(r.deletionMembersRaw),
             "removedAttachmentsData": v(r.removedAttachmentsData), "doneLoggedAt": v(r.doneLoggedAt),
             "tagsRaw": v(r.tagsRaw), "dueDayRaw": v(r.dueDayRaw), "listOrderVersion": v(r.listOrderVersion),
             "completedFromRaw": v(r.completedFromRaw), "completedFromOrder": v(r.completedFromOrder)]
        }
        let h = try c.fetch(FetchDescriptor<NoteVersion>()).map { r in
            ["id": v(r.id), "noteID": v(r.noteID), "createdAt": v(r.createdAt), "reasonRaw": v(r.reasonRaw),
             "content": v(r.content), "contentFormat": v(r.contentFormat), "title": v(r.title), "body": v(r.body),
             "attachmentIDsRaw": v(r.attachmentIDsRaw), "sourceRevisionID": v(r.sourceRevisionID)]
        }
        let p = try c.fetch(FetchDescriptor<NotePendingEdit>()).map { r in
            ["id": v(r.id), "noteID": v(r.noteID), "baseRevisionToken": v(r.baseRevisionToken),
             "proposedContent": v(r.proposedContent), "baseVersionID": v(r.baseVersionID), "agentName": v(r.agentName),
             "createdAt": v(r.createdAt), "needsReview": v(r.needsReview), "isDeletion": v(r.isDeletion)]
        }
        let a = try c.fetch(FetchDescriptor<NoteAttachment>()).map { r in
            ["id": v(r.id), "noteID": v(r.noteID), "filename": v(r.originalFilename), "contentTypeIdentifier": v(r.contentTypeIdentifier),
             "byteCount": v(r.byteCount), "sha256": v(r.contentDigest), "data": v(r.payload), "deletedAt": v(r.deletedAt),
             "createdAt": v(r.createdAt), "updatedAt": v(r.updatedAt), "sortIndex": v(r.sortIndex),
             "inlineOffset": v(r.inlineOffset), "displayWidth": v(r.displayWidth), "displayHeight": v(r.displayHeight)]
        }
        let l = try c.fetch(FetchDescriptor<ItemLink>()).map { r in
            ["id": v(r.id), "sourceKindRaw": v(r.sourceKindRaw), "sourceID": v(r.sourceID),
             "targetKindRaw": v(r.targetKindRaw), "targetID": v(r.targetID), "kindRaw": v(r.kindRaw),
             "createdAt": v(r.createdAt), "updatedAt": v(r.updatedAt), "deletedAt": v(r.deletedAt)]
        }
        let m = try c.fetch(FetchDescriptor<StoreMaintenance>()).map { r in
            ["key": v(r.key), "noteIDsRaw": v(r.noteIDsRaw), "attachmentIDsRaw": v(r.attachmentIDsRaw),
             "stagedIDsRaw": v(r.stagedIDsRaw), "filesCleaned": v(r.filesCleaned)]
        }
        let colours = try c.fetch(FetchDescriptor<TagColour>()).map { r in
            ["id": v(r.id), "name": v(r.name), "colourKey": v(r.colourKey),
             "createdAt": v(r.createdAt), "modifiedAt": v(r.modifiedAt)]
        }
        return try json(["notes": sorted(n), "tasks": sorted(t), "versions": sorted(h), "pending": sorted(p),
                         "attachments": sorted(a), "links": sorted(l), "maintenance": sorted(m), "tagColours": sorted(colours)])
    }

    static func exercise(_ container: ModelContainer, root: URL) async throws {
        let store = notes(container, root), taskStore = tasks(container, root)
        await store.waitForAttachmentReconciliation()
        let c = ModelContext(container); c.autosaveEnabled = false
        let initialSnapshot = try JSONSerialization.jsonObject(with: snapshot(container)) as! [String: [[String: Any]]]
        let taskSnapshot = initialSnapshot["tasks"]!
        let original = try c.fetch(FetchDescriptor<NoteItem>())
        let bytes = Dictionary(grouping: original, by: \.id).mapValues { $0.map(\.content) }
        let versions = try c.fetch(FetchDescriptor<NoteVersion>()).map { ($0.id, $0.content) }
        let proposals = try c.fetch(FetchDescriptor<NotePendingEdit>()).map { ($0.id, $0.proposedContent) }
        let attachments = try c.fetch(FetchDescriptor<NoteAttachment>()).map { ($0.id, $0.payload) }
        func unchanged(_ stage: String) throws {
            let fresh = ModelContext(container)
            let rows = try fresh.fetch(FetchDescriptor<NoteItem>())
            XCTAssertEqual(rows.count, original.count, stage)
            let current = Dictionary(grouping: rows, by: \.id).mapValues { $0.map { $0.content?.base64EncodedString() ?? "nil" }.sorted() }
            let expected = bytes.mapValues { $0.map { $0?.base64EncodedString() ?? "nil" }.sorted() }
            XCTAssertEqual(current, expected, stage)
            for (id, data) in versions {
                XCTAssertEqual(try fresh.fetch(FetchDescriptor<NoteVersion>()).first { $0.id == id }?.content, data, stage)
            }
            for (id, data) in proposals {
                XCTAssertEqual(try fresh.fetch(FetchDescriptor<NotePendingEdit>()).first { $0.id == id }?.proposedContent, data, stage)
            }
            for (id, data) in attachments {
                XCTAssertEqual(try fresh.fetch(FetchDescriptor<NoteAttachment>()).first { $0.id == id }?.payload, data, stage)
            }
        }
        for id in Set(original.filter { $0.deletedAt == nil }.map(\.id)) {
            let loaded = try XCTUnwrap(store.loadDocument(noteID: id))
            let doc = try XCTUnwrap(loaded.content.document)
            XCTAssertTrue(doc.isWritableByThisBuild)
            let roundTrip = NoteTextKitRoundTrip.document(afterRoundTrip: doc)
            XCTAssertEqual(try NoteContentCodec.encode(roundTrip), bytes[id]?.first ?? nil, "TextKit layout: \(id)")
            let engine = NoteEditorEngine(noteID: id, document: doc)
            XCTAssertEqual(try NoteContentCodec.encode(engine.checkpointDocument()), bytes[id]?.first ?? nil, "Checkpoint: \(id)")
            let row = try XCTUnwrap(store.note(withID: id))
            _ = try store.saveDocument(noteID: id, document: roundTrip, baseRevisionID: row.revisionID).get()
            try unchanged("unchanged document save")
            XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
            XCTAssertTrue(store.recordVersion(noteID: id, reason: .leave))
            store.thinVersions(noteID: id)
            try unchanged("checkpoint/version retention")
            XCTAssertTrue(store.setTags(["compat", "changed"], for: try XCTUnwrap(store.note(withID: id))))
            XCTAssertTrue(store.setPinned(true, noteID: id))
            XCTAssertTrue(store.acknowledgeExternalEdit(noteID: id))
            try unchanged("tags, pin, attribution")
        }
        // Use the session's actual scheduled-save and departure paths. The plain
        // fixture has no queued proposal that leaving would intentionally apply.
        let controller = NotesPageController(store: store,
            journal: NoteDraftJournal(directory: dir(root, "SessionDrafts")),
            saveDelay: .seconds(600), pauseVersionDelay: .seconds(600), now: { clock })
        let opened = await controller.openDurably(noteID: plainID)
        XCTAssertTrue(opened)
        let session = try XCTUnwrap(controller.active)
        session.engine.setTags(["compat", "session"])
        await controller.runDueSave(session)
        try unchanged("session scheduled save")
        let preserved = await controller.preserveDurably(session)
        XCTAssertTrue(preserved)
        for reason in [NotesPageController.LeaveReason.pageSwitch, .hide, .quit, .library, .openNote, .newNote] {
            let didOpen = await controller.openDurably(noteID: plainID)
            XCTAssertTrue(didOpen)
            let left = await controller.prepareToLeaveDurably(reason)
            XCTAssertTrue(left)
            try unchanged("session departure: \(reason)")
        }
        let gate = SaveGate()
        let failedStore = NoteStore(container: container, now: { clock }, persist: { context in
            if gate.fail { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        }, attachmentFileStore: AttachmentFileStore(rootURL: dir(root, "NoteFiles")))
        let failureJournal = NoteDraftJournal(directory: dir(root, "FailedSaveDrafts"))
        let failedController = NotesPageController(store: failedStore, journal: failureJournal,
            saveDelay: .seconds(600), now: { clock })
        let openedForFailure = await failedController.openDurably(noteID: plainID)
        XCTAssertTrue(openedForFailure)
        let failedSession = try XCTUnwrap(failedController.active)
        failedSession.engine.setTags(["compat", "checkpoint"])
        gate.fail = true
        let checkpointed = await failedController.preserveDurably(failedSession)
        XCTAssertTrue(checkpointed)
        let checkpoints = try await failureJournal.entriesDurably()
        XCTAssertEqual(checkpoints.count, 1)
        XCTAssertEqual(checkpoints.first?.0.content, bytes[plainID]?.first ?? nil, "Real failed-save checkpoint bytes")
        try unchanged("failed save rolls back and checkpoints")
        gate.fail = false
        let retried = await failedController.preserveDurably(failedSession)
        XCTAssertTrue(retried)
        try unchanged("checkpoint retry")
        await failedStore.waitForAttachmentReconciliation()
        let links = LinkStore(container: container, now: { clock })
        let link = try XCTUnwrap(links.links(from: AtticItemRef(.note, noteID)).first)
        XCTAssertTrue(links.unlink(link.id)); XCTAssertTrue(links.restoreLink(link.id))
        try unchanged("link updates")
        let journal = NoteDraftJournal(directory: dir(root, "NoteDrafts"))
        let recovered = try await journal.entriesDurably()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.0.noteID, noteID)
        XCTAssertEqual(recovered.first?.1.count, 1)
        let recoveryFile = dir(root, "NoteDrafts").appendingPathComponent("\(noteID).json")
        let recoveryBytes = try Data(contentsOf: recoveryFile)
        let markerBefore = try c.fetch(FetchDescriptor<StoreMaintenance>()).map(\.key)
        XCTAssertEqual(try OldNotesPurge.run(in: container), OldNotesPurge.Counts())
        try OldNotesPurge.cleanup(in: container, recoveryURL: root.appendingPathComponent("Recovery.json"),
                                 attachmentRoot: dir(root, "NoteFiles"))
        XCTAssertEqual(try Data(contentsOf: recoveryFile), recoveryBytes)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<StoreMaintenance>()).map(\.key), markerBefore)
        let retainedEntries = try await journal.entriesDurably()
        XCTAssertEqual(retainedEntries.count, 1)
        try unchanged("launch maintenance")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let cutoff = calendar.startOfDay(for: clock)
        XCTAssertEqual(taskStore.moveCompletedToDoneLog(before: cutoff), 3)
        XCTAssertEqual(taskStore.moveCompletedToDoneLog(before: cutoff), 0)
        let afterTasks = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        for task in afterTasks {
            let expected = ["Yesterday", "Done parent", "Done child", "Existing history"].contains(task.title)
            XCTAssertEqual(task.doneLoggedAt != nil, expected, task.title)
        }
        let parent = try XCTUnwrap(taskStore.task(withID: taskID))
        let taskBytes = parent.imageReferencesData
        XCTAssertEqual(parent.attachments.count, 1)
        XCTAssertTrue(taskStore.rename(parent, to: "Edited task café 👩🏽‍💻"))
        XCTAssertEqual(taskStore.task(withID: taskID)?.imageReferencesData, taskBytes)
        let taskFiles = TaskImageFiles(rootURL: dir(root, "TaskFiles"))
        for reference in parent.attachments {
            let url = try await taskFiles.verifiedURL(for: reference)
            XCTAssertNotNil(url)
        }
        XCTAssertEqual(taskStore.task(withID: taskID)?.dueDayRaw, "2026-10-31")
        XCTAssertEqual(taskStore.task(withID: taskID)?.tagsRaw, "compat task")
        let newTaskSnapshot = (try JSONSerialization.jsonObject(with: snapshot(container)) as! [String: Any])["tasks"] as! [[String: Any]]
        func taskInvariant(_ rows: [[String: Any]]) throws -> [Data] {
            try rows.map { original in
                var row = original
                if row["id"] as? String == taskID.uuidString { row.removeValue(forKey: "title"); row.removeValue(forKey: "updatedAt") }
                if ["Yesterday", "Done parent", "Done child"].contains(row["title"] as? String ?? "") { row.removeValue(forKey: "doneLoggedAt") }
                return try json(row)
            }.sorted { $0.lexicographicallyPrecedes($1) }
        }
        XCTAssertEqual(try taskInvariant(newTaskSnapshot), try taskInvariant(taskSnapshot), "All other task fields, replicas and history")
        let finalSnapshot = try JSONSerialization.jsonObject(with: snapshot(container)) as! [String: [[String: Any]]]
        for kind in ["versions", "pending", "attachments", "links", "tagColours"] {
            let finalRows = try finalSnapshot[kind]!.map { try json($0) }
            for originalRow in initialSnapshot[kind]! {
                XCTAssertTrue(finalRows.contains(try json(originalRow)), "Complete original \(kind) row survives every save")
            }
        }
        try unchanged("task edits and daily cleanup")
    }
}
