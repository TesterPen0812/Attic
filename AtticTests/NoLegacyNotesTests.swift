import AppKit
import Combine
import SwiftData
import XCTest
@testable import Attic

@MainActor
final class NoLegacyNotesTests: XCTestCase {
    private func rawContainer() throws -> ModelContainer {
        try ModelContainer(for: Schema(PersistenceController.appModelTypes),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }
    private func old(_ id: UUID = UUID()) -> NoteItem {
        let note = NoteItem(id: id, title: "Old", body: "discard")
        note.contentFormat = 0; note.content = nil
        return note
    }
    func testModelInitializerWritesDocumentFormat() throws {
        let note = NoteItem(title: "Title", body: "one\ntwo")
        XCTAssertEqual(note.contentFormat, 1)
        XCTAssertEqual(try XCTUnwrap(NoteContentCodec.decode(try XCTUnwrap(note.content)).document).blocks.map(\.text), ["Title", "one", "two"])
    }
    func testTextCreationWritesDocumentFormat() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let note = try XCTUnwrap(store.create(title: "Title", body: "body"))
        XCTAssertEqual(note.contentFormat, 1)
        XCTAssertTrue(try XCTUnwrap(store.loadDocument(noteID: note.id)).content.isEditable)
    }
    func testAgentCreationAlwaysUsesDocumentFormat() throws {
        let notes = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let tasks = TaskStore(container: notes.container)
        let tools = AgentTaskTools(store: tasks, noteStore: notes, library: AtticLibrary(tasks: tasks, notes: notes), parser: TaskTextParser())
        _ = try tools.call(name: "create_note", arguments: ["title": "Agent", "body": "text"])
        XCTAssertEqual(try XCTUnwrap(notes.notes.first).contentFormat, 1)
    }
    func testMixedStorePurgesOnlyExplicitOldUUIDFamilies() throws {
        let container = try rawContainer(), context = ModelContext(container)
        let oldID = UUID(), newID = UUID()
        context.insert(old(oldID)); context.insert(old(oldID))
        context.insert(NoteItem(id: oldID, title: "Different-format physical replica"))
        let current = NoteItem(id: newID, title: "Keep")
        current.contentFormat = 1; current.content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Keep")]))
        current.tags = ["shared"]
        context.insert(current)
        let task = TaskItem(title: "Keep task"); task.tags = ["shared"]; context.insert(task)
        let canvas = CanvasBoardItem(name: "Keep canvas"); context.insert(canvas)
        for id in [oldID, newID] {
            context.insert(NoteAttachment(noteID: id, originalFilename: "file", byteCount: 1, sortIndex: 0, contentDigest: "digest", payload: Data([1])))
            context.insert(NoteVersion(noteID: id, createdAt: Date(), reason: .pause, content: current.content,
                contentFormat: 1, title: "Version", body: "", attachmentIDs: [], sourceRevisionID: nil))
            context.insert(NotePendingEdit(noteID: id, baseRevisionToken: "initial", proposedContent: try XCTUnwrap(current.content), agentName: "agent", createdAt: Date()))
        }
        // Missing bytes are not evidence of old format.
        let damaged = NoteItem(title: "Damaged current"); damaged.contentFormat = 1; damaged.content = nil; context.insert(damaged)
        try context.save()
        let counts = try OldNotesPurge.run(in: container)
        XCTAssertEqual(counts.notes, 3); XCTAssertEqual(counts.attachments, 1)
        XCTAssertEqual(counts.versions, 1); XCTAssertEqual(counts.proposals, 1)
        let fresh = ModelContext(container)
        XCTAssertEqual(Set(try fresh.fetch(FetchDescriptor<NoteItem>()).map(\.id)), [newID, damaged.id])
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<NoteAttachment>()).map(\.noteID), [newID])
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<NoteVersion>()).map(\.noteID), [newID])
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<NotePendingEdit>()).map(\.noteID), [newID])
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<TaskItem>()).map(\.id), [task.id])
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<CanvasBoardItem>()).map(\.id), [canvas.id])
        XCTAssertEqual(try XCTUnwrap(fresh.fetch(FetchDescriptor<NoteItem>()).first { $0.id == newID }).tags, ["shared"])
    }
    func testSecondOpenNeverPurgesEvenIfAnOldWriterReturns() throws {
        let container = try rawContainer()
        _ = try OldNotesPurge.run(in: container)
        let context = ModelContext(container), note = old(); context.insert(note); try context.save()
        XCTAssertEqual(try OldNotesPurge.run(in: container).notes, 0)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<NoteItem>()).map(\.id), [note.id])
    }
    func testPurgeSaveFailureRollsBackAndCanRetry() throws {
        let container = try rawContainer(), context = ModelContext(container), note = old()
        context.insert(note); try context.save()
        struct Failure: Error {}
        XCTAssertThrowsError(try OldNotesPurge.run(in: container, persist: { _ in throw Failure() }))
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<NoteItem>()).map(\.id), [note.id])
        XCTAssertEqual(try OldNotesPurge.run(in: container).notes, 1)
    }
    func testEmptyAndNewOnlyStoresAreUntouched() throws {
        for newOnly in [false, true] {
            let container = try rawContainer(), context = ModelContext(container)
            if newOnly {
                let note = NoteItem(title: "Keep"); note.contentFormat = 1
                note.content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Keep")]))
                context.insert(note); try context.save()
            }
            XCTAssertEqual(try OldNotesPurge.run(in: container), OldNotesPurge.Counts())
            XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<NoteItem>()).count, newOnly ? 1 : 0)
        }
    }

    private func cleanupFixture() throws -> (ModelContainer, UUID, UUID, UUID, URL, URL) {
        let container = try rawContainer(), context = ModelContext(container)
        let oldID = UUID(), newID = UUID(), attachmentID = UUID()
        context.insert(old(oldID)); context.insert(NoteItem(id: newID, title: "Keep"))
        context.insert(NoteAttachment(id: attachmentID, noteID: oldID, originalFilename: "saved.bin",
            byteCount: 1, sortIndex: 0, contentDigest: NotePayloadDigest.sha256(Data([1])), payload: Data([1])))
        try context.save()
        let root = ownedTemporaryDirectory(prefix: "OldNotesCleanup").resolvingSymlinksInPath()
        let recovery = root.appendingPathComponent("draft-recovery.json"), attachments = root.appendingPathComponent("Attachments")
        let materialized = attachments.appendingPathComponent(attachmentID.uuidString).appendingPathComponent("bytes")
        try FileManager.default.createDirectory(at: materialized.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: materialized)
        return (container, oldID, newID, attachmentID, recovery, attachments)
    }
    private func checkpoint(_ entry: NoteDraftJournalEntry, recovery: URL) throws {
        let directory = recovery.deletingLastPathComponent().appendingPathComponent("NoteDrafts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entry).write(to: directory.appendingPathComponent(entry.noteID.uuidString + ".json"))
    }
    func testSurvivingRecoveryDocumentKeepsItsOnlyMaterializedAttachment() throws {
        let (container, _, newID, attachmentID, recovery, attachments) = try cleanupFixture()
        let content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("New draft"), .image(attachmentID: attachmentID)]))
        try checkpoint(NoteDraftJournalEntry(noteID: newID, isPersisted: true, baseRevisionID: nil, content: content,
            selectionLocation: 0, selectionLength: 0, staged: [], savedAt: Date()), recovery: recovery)
        _ = try OldNotesPurge.run(in: container)
        try OldNotesPurge.cleanup(in: container, recoveryURL: recovery, attachmentRoot: attachments)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachments.appendingPathComponent(attachmentID.uuidString).path),
            "A surviving recovery document still owns these bytes")
    }
    func testDamagedSurvivingRecoveryKeepsSharedStaging() throws {
        let (container, oldID, newID, attachmentID, recovery, attachments) = try cleanupFixture()
        let staged = NoteDraftJournalEntry.StagedFile(id: attachmentID, filename: "saved.bin",
            contentTypeIdentifier: "public.data", byteCount: 1, digest: NotePayloadDigest.sha256(Data([1])))
        let blank = try NoteContentCodec.encode(.blank)
        try checkpoint(NoteDraftJournalEntry(noteID: oldID, isPersisted: true, baseRevisionID: nil, content: blank,
            selectionLocation: 0, selectionLength: 0, staged: [staged], savedAt: Date()), recovery: recovery)
        try checkpoint(NoteDraftJournalEntry(noteID: newID, isPersisted: true, baseRevisionID: nil, content: Data("bad document".utf8),
            selectionLocation: 0, selectionLength: 0, staged: [], savedAt: Date()), recovery: recovery)
        let stagedURL = recovery.deletingLastPathComponent().appendingPathComponent("NoteDrafts/staged/" + attachmentID.uuidString)
        try FileManager.default.createDirectory(at: stagedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: stagedURL)
        _ = try OldNotesPurge.run(in: container)
        try OldNotesPurge.cleanup(in: container, recoveryURL: recovery, attachmentRoot: attachments)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachments.appendingPathComponent(attachmentID.uuidString).path))
    }
    func testFacadePublishesActiveDocumentSessionChanges() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let facade = NoteDraftController(noteStore: store)
        await facade.pages.startAndWait()
        var notifications = 0
        let observation = facade.objectWillChange.sink { notifications += 1 }
        let session = try XCTUnwrap(facade.pages.active)
        XCTAssertTrue(session.engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Typing"), name: "Type"))
        XCTAssertTrue(facade.isDirty)
        XCTAssertGreaterThan(notifications, 0, "Shell hover locks must observe the document session")
        withExtendedLifetime(observation) {}
    }
    func testAgentRevealReturnsToRequestedNoteAfterLibraryNavigation() async throws {
        let notes = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let tasks = TaskStore(container: notes.container), state = PanelUIState(), draft = NoteDraftController(noteStore: notes)
        let first = try XCTUnwrap(notes.create(title: "A")), second = try XCTUnwrap(notes.create(title: "B"))
        let presenter = PanelAgentPresenter(uiState: state, store: tasks, noteStore: notes,
            canvasSession: CanvasSession(store: CanvasStore(container: notes.container)), noteDraft: draft,
            reveal: { section in state.selectSection(section); return .shown })
        _ = presenter.presentForAgent(.item(AtticItemRef(.note, first.id)))
        XCTAssertTrue(draft.pages.open(noteID: second.id))
        _ = presenter.presentForAgent(.item(AtticItemRef(.note, first.id)))
        XCTAssertEqual(draft.pages.active?.noteID, first.id)
    }

    func testPurgeCompletionIsDurableAcrossStoreReopen() throws {
        let root = ownedTemporaryDirectory(prefix: "PurgeStoreReopen")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = PersistenceController.makeConfiguration(cloudSyncEnabled: false, storeDirectory: root)
        do {
            let seed = try ModelContainer(for: Schema(PersistenceController.appModelTypes), configurations: configuration)
            let context = ModelContext(seed); context.insert(old()); try context.save()
        }
        do {
            let opened = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
            XCTAssertTrue(try ModelContext(opened).fetch(FetchDescriptor<NoteItem>()).isEmpty)
            let context = ModelContext(opened); context.insert(old()); try context.save()
        }
        let reopened = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        XCTAssertEqual(try ModelContext(reopened).fetchCount(FetchDescriptor<NoteItem>()), 1,
            "A later format-zero bug must never rearm destructive maintenance")
        XCTAssertEqual(try ModelContext(reopened).fetchCount(FetchDescriptor<StoreMaintenance>()), 1)
    }
    func testCommittedPurgeCleansOnlyOwnedRecoveryAndFilesAndCanResume() throws {
        let (container, oldID, newID, attachmentID, recovery, attachments) = try cleanupFixture()
        let blank = try NoteContentCodec.encode(.blank)
        for id in [oldID, newID] {
            try checkpoint(NoteDraftJournalEntry(noteID: id, isPersisted: true, baseRevisionID: nil, content: blank,
                selectionLocation: 0, selectionLength: 0, staged: [], savedAt: Date()), recovery: recovery)
        }
        try JSONSerialization.data(withJSONObject: ["noteID": oldID.uuidString]).write(to: recovery)
        let journal = recovery.deletingLastPathComponent().appendingPathComponent("NoteDrafts")
        let quarantine = journal.appendingPathComponent("quarantine").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        try Data("old archive".utf8).write(to: quarantine.appendingPathComponent(oldID.uuidString + ".json"))
        let oldCheckpoint = journal.appendingPathComponent(oldID.uuidString + ".json")
        let newCheckpoint = journal.appendingPathComponent(newID.uuidString + ".json")
        _ = try OldNotesPurge.run(in: container)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldCheckpoint.path), "Database commit never mutates files before success")
        let marker = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<StoreMaintenance>()).first)
        XCTAssertFalse(marker.filesCleaned, "A crash here leaves durable pending cleanup")
        try OldNotesPurge.cleanup(in: container, recoveryURL: recovery, attachmentRoot: attachments)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldCheckpoint.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachments.appendingPathComponent(attachmentID.uuidString).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newCheckpoint.path))
        try OldNotesPurge.cleanup(in: container, recoveryURL: recovery, attachmentRoot: attachments)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newCheckpoint.path))
    }
    func testFailedPurgeLeavesDiskCopiesAndAllDependentRowsUntouched() throws {
        let (container, oldID, _, _, recovery, attachments) = try cleanupFixture()
        try JSONSerialization.data(withJSONObject: ["reservedNoteID": oldID.uuidString]).write(to: recovery)
        let before = try Data(contentsOf: recovery)
        struct Failure: Error {}
        XCTAssertThrowsError(try OldNotesPurge.run(in: container, persist: { _ in throw Failure() }))
        try OldNotesPurge.cleanup(in: container, recoveryURL: recovery, attachmentRoot: attachments)
        XCTAssertEqual(try Data(contentsOf: recovery), before)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteAttachment>()), 1)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteItem>()), 2)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<StoreMaintenance>()), 0)
    }
    func testCleanupRejectsSymlinkAndRetriesWithoutRepeatingDatabasePurge() throws {
        let (container, oldID, _, _, recovery, attachments) = try cleanupFixture()
        let root = recovery.deletingLastPathComponent(), outside = ownedTemporaryDirectory(prefix: "PurgeOutside").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent(oldID.uuidString + ".json")
        try Data("preserve".utf8).write(to: sentinel)
        let journal = root.appendingPathComponent("NoteDrafts")
        try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: outside)
        _ = try OldNotesPurge.run(in: container)
        XCTAssertThrowsError(try OldNotesPurge.cleanup(in: container, recoveryURL: recovery, attachmentRoot: attachments))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve".utf8))
        XCTAssertEqual(try OldNotesPurge.run(in: container).notes, 0)
        try FileManager.default.removeItem(at: journal)
        try OldNotesPurge.cleanup(in: container, recoveryURL: recovery, attachmentRoot: attachments)
        XCTAssertTrue(try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<StoreMaintenance>()).first).filesCleaned)
    }
    func testMixedQuarantineKeepsNewCheckpointAndUnrelatedStagedBytes() throws {
        let (container, oldID, newID, attachmentID, recovery, attachments) = try cleanupFixture()
        let archive = recovery.deletingLastPathComponent().appendingPathComponent("NoteDrafts/quarantine/mixed")
        let staged = archive.appendingPathComponent("staged").appendingPathComponent(attachmentID.uuidString)
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldFile = archive.appendingPathComponent(oldID.uuidString + ".json")
        let newFile = archive.appendingPathComponent(newID.uuidString + ".json")
        try Data("old damaged checkpoint".utf8).write(to: oldFile)
        try Data("new damaged checkpoint".utf8).write(to: newFile)
        try Data([1]).write(to: staged)
        _ = try OldNotesPurge.run(in: container)
        try OldNotesPurge.cleanup(in: container, recoveryURL: recovery, attachmentRoot: attachments)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertEqual(try? Data(contentsOf: newFile), Data("new damaged checkpoint".utf8))
        XCTAssertEqual(try? Data(contentsOf: staged), Data([1]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachments.appendingPathComponent(attachmentID.uuidString).path))
    }
    func testSurvivingQuarantineKeepsItsOnlyReferencedMaterialization() throws {
        let (container, _, newID, attachmentID, recovery, attachments) = try cleanupFixture()
        let archive = recovery.deletingLastPathComponent().appendingPathComponent("NoteDrafts/quarantine/new")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Archived"), .image(attachmentID: attachmentID)]))
        try content.write(to: archive.appendingPathComponent("readable-note.json"))
        try Data(newID.uuidString.utf8).write(to: archive.appendingPathComponent(newID.uuidString + ".json"))
        _ = try OldNotesPurge.run(in: container)
        try OldNotesPurge.cleanup(in: container, recoveryURL: recovery, attachmentRoot: attachments)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachments.appendingPathComponent(attachmentID.uuidString).path))
    }
    func testConflictingSingletonIdentityKeepsRecoveryAndUnknownOwnershipKeepsBytes() throws {
        for conflicting in [true, false] {
            let (container, oldID, newID, attachmentID, recovery, attachments) = try cleanupFixture()
            let data = conflicting
                ? try JSONSerialization.data(withJSONObject: ["noteID": newID.uuidString, "reservedNoteID": oldID.uuidString])
                : Data("unreadable ownership".utf8)
            try data.write(to: recovery)
            _ = try OldNotesPurge.run(in: container)
            try OldNotesPurge.cleanup(in: container, recoveryURL: recovery, attachmentRoot: attachments)
            XCTAssertEqual(try? Data(contentsOf: recovery), data)
            XCTAssertTrue(FileManager.default.fileExists(atPath: attachments.appendingPathComponent(attachmentID.uuidString).path))
        }
    }

    func testPurgeRemovesFilesOwnedOnlyByOldHistoryAndRecoveryDocuments() throws {
        let (container, oldID, _, _, recovery, attachments) = try cleanupFixture()
        let versionFile = UUID(), draftFile = UUID()
        let context = ModelContext(container)
        context.insert(NoteVersion(noteID: oldID, createdAt: Date(), reason: .pause,
            content: try NoteContentCodec.encode(.blank), contentFormat: 1, title: "Old history", body: "",
            attachmentIDs: [versionFile], sourceRevisionID: nil))
        try context.save()
        let content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Old draft"), .image(attachmentID: draftFile)]))
        try checkpoint(NoteDraftJournalEntry(noteID: oldID, isPersisted: true, baseRevisionID: nil, content: content,
            selectionLocation: 0, selectionLength: 0, staged: [], savedAt: Date()), recovery: recovery)
        for id in [versionFile, draftFile] {
            let file = attachments.appendingPathComponent(id.uuidString).appendingPathComponent("bytes")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file)
        }
        _ = try OldNotesPurge.run(in: container)
        try OldNotesPurge.cleanup(in: container, recoveryURL: recovery, attachmentRoot: attachments)
        for id in [versionFile, draftFile] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: attachments.appendingPathComponent(id.uuidString).path))
        }
    }

    func testResolvedOldQuarantineCopyIsRemovedAndInterruptedCleanupKeepsItsIdentity() throws {
        for interrupt in [false, true] {
            let (container, oldID, _, _, recovery, attachments) = try cleanupFixture()
            let archive = recovery.deletingLastPathComponent().appendingPathComponent("NoteDrafts/quarantine/old")
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            let checkpoint = archive.appendingPathComponent(oldID.uuidString + ".json")
            let raw = archive.appendingPathComponent("resolved-checkpoint.raw")
            let readable = archive.appendingPathComponent("readable-note.md")
            let data = Data("old owned checkpoint".utf8)
            try data.write(to: checkpoint); try data.write(to: raw)
            let outside = ownedTemporaryDirectory(prefix: "PurgeCopyOutside").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let sentinel = outside.appendingPathComponent("sentinel")
            try Data("keep".utf8).write(to: sentinel)
            if interrupt { try FileManager.default.createSymbolicLink(at: readable, withDestinationURL: sentinel) }
            else { try data.write(to: readable) }
            _ = try OldNotesPurge.run(in: container)
            if interrupt {
                XCTAssertThrowsError(try OldNotesPurge.cleanup(in: container, recoveryURL: recovery, attachmentRoot: attachments))
                XCTAssertEqual(try? Data(contentsOf: checkpoint), data, "Failed copy cleanup must leave its identifying checkpoint for retry")
                try FileManager.default.removeItem(at: readable); try data.write(to: readable)
            }
            try OldNotesPurge.cleanup(in: container, recoveryURL: recovery, attachmentRoot: attachments)
            XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: readable.path))
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        }
    }

    func testH4_01RetiredImportStateHasNoDeclaration() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Attic/Models/NoteAttachment.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("enum AttachmentImportState"))
        let store = try String(contentsOf: root.appendingPathComponent("Attic/Services/NoteStore.swift"), encoding: .utf8)
        XCTAssertFalse(store.contains("private func visibleAttachments("))
        XCTAssertFalse(store.contains("private func totalAttachmentBytes("))
    }

    func testH4_02PurgeRemovesLinksAtomicallyAndProtectsOtherFamilies() throws {
        let container = try rawContainer(), context = ModelContext(container)
        let id = UUID(), keptID = UUID(), taskID = UUID()
        context.insert(old(id)); context.insert(NoteItem(id: keptID, title: "Keep"))
        context.insert(TaskItem(id: id, title: "Task with same UUID"))
        let doomed = ItemLink(source: AtticItemRef(.note, id), target: AtticItemRef(.task, taskID), kind: .card)
        context.insert(doomed)
        context.insert(ItemLink(id: doomed.id, source: AtticItemRef(.note, id), target: AtticItemRef(.task, taskID), kind: .card))
        let inbound = ItemLink(source: AtticItemRef(.note, keptID), target: AtticItemRef(.note, id), kind: .reference)
        context.insert(inbound)
        let kept = ItemLink(source: AtticItemRef(.task, id), target: AtticItemRef(.task, taskID), kind: .reference)
        context.insert(kept)
        let divergentID = UUID()
        context.insert(ItemLink(id: divergentID, source: AtticItemRef(.note, id), target: AtticItemRef(.task, taskID), kind: .card))
        context.insert(ItemLink(id: divergentID, source: AtticItemRef(.note, keptID), target: AtticItemRef(.task, taskID), kind: .card))
        try context.save()
        struct Failure: Error {}
        XCTAssertThrowsError(try OldNotesPurge.run(in: container, persist: { _ in throw Failure() }))
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<ItemLink>()), 6)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<StoreMaintenance>()), 0)
        _ = try OldNotesPurge.run(in: container)
        let remaining = try ModelContext(container).fetch(FetchDescriptor<ItemLink>())
        XCTAssertEqual(Set(remaining.map(\.id)), [kept.id, divergentID])
        XCTAssertEqual(remaining.count, 3, "Every unambiguous physical replica must be removed")
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>()), 1)
        // Marker remains one-time: later writers cannot reactivate the purge.
        let fresh = ModelContext(container)
        fresh.insert(NoteItem(id: id, title: "Reused UUID")); try fresh.save()
        XCTAssertEqual(try OldNotesPurge.run(in: container).notes, 0)
        XCTAssertFalse(try ModelContext(container).fetch(FetchDescriptor<ItemLink>()).contains { $0.id == doomed.id || $0.id == inbound.id })
    }

}
