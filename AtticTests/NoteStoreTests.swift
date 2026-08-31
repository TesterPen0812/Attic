import SwiftData
import XCTest
@testable import Attic

final class NoteStoreTests: XCTestCase {
    @MainActor
    func testEmptyStoreReconciliationLeavesSeparateDefaultLikeRootUntouched() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtticNoteStoreSentinel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let defaultLikeRoot = parent
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Attic", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        try FileManager.default.createDirectory(
            at: defaultLikeRoot,
            withIntermediateDirectories: true
        )
        let sentinelURL = defaultLikeRoot.appendingPathComponent("must-survive.txt")
        let sentinelData = Data("separate app attachment root".utf8)
        try sentinelData.write(to: sentinelURL)

        let testRoot = parent
            .appendingPathComponent("XCTest", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        let fileStore = makeTestAttachmentFileStore(rootURL: testRoot)
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = NoteStore(container: container, attachmentFileStore: fileStore)

        XCTAssertTrue(store.notes.isEmpty)
        let preparationDeadline = ContinuousClock.now + .seconds(2)
        let testStagingRoot = testRoot.appendingPathComponent(".staging", isDirectory: true)
        while !FileManager.default.fileExists(atPath: testStagingRoot.path),
              ContinuousClock.now < preparationDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: testStagingRoot.path),
            "The injected test root must be the root reconciled during NoteStore creation"
        )
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinelData)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: defaultLikeRoot.appendingPathComponent(".staging").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: defaultLikeRoot.appendingPathComponent("Thumbnails").path
        ))
    }

    @MainActor
    func testCreateNormalizesTitleWithoutChangingMeaningfulBodyWhitespace() throws {
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )

        XCTAssertNil(store.create(title: "   ", body: "   \n  "))
        let note = try XCTUnwrap(store.create(title: "  Meeting   notes ", body: "  Discuss\nrelease  "))

        XCTAssertEqual(note.title, "Meeting notes")
        XCTAssertEqual(note.body, "  Discuss\nrelease  ")
        XCTAssertEqual(store.notes.count, 1)
    }

    @MainActor
    func testUpdatePreservesMeaningfulBodyWhitespace() throws {
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let note = try XCTUnwrap(store.create(body: "Original"))

        XCTAssertTrue(store.update(note, body: "  Indented\ntext  "))
        XCTAssertEqual(try XCTUnwrap(store.notes.first).body, "  Indented\ntext  ")
    }

    @MainActor
    func testCreateAcceptsBodyWithoutTitle() throws {
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let note = try XCTUnwrap(store.create(body: "Quick jot"))

        XCTAssertEqual(note.title, "")
        XCTAssertEqual(note.body, "Quick jot")
    }

    @MainActor
    func testCreateReportsPersistenceFailureAndRollsBack() throws {
        let gate = PersistenceGate()
        gate.shouldFail = true
        let store = try makeTestNoteStore(
            persist: gate.save,
            attachmentFileStore: makeTestAttachmentFileStore()
        )

        XCTAssertNil(store.create(body: "Must not disappear"))
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertNotNil(store.lastErrorMessage)
    }

    @MainActor
    func testUpdateRejectsEmptyTitleAndBody() throws {
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let note = try XCTUnwrap(store.create(title: "Keep", body: "me"))

        XCTAssertFalse(store.update(note, title: "   ", body: "   "))
        XCTAssertEqual(try XCTUnwrap(store.notes.first).title, "Keep")
        XCTAssertEqual(try XCTUnwrap(store.notes.first).body, "me")
    }

    @MainActor
    func testFailedSaveRestoresNote() throws {
        let gate = PersistenceGate()
        let store = try makeTestNoteStore(
            persist: gate.save,
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let note = try XCTUnwrap(store.create(body: "Keep me"))
        gate.shouldFail = true

        XCTAssertFalse(store.update(note, body: "Changed"))
        XCTAssertEqual(try XCTUnwrap(store.notes.first).body, "Keep me")

        XCTAssertFalse(store.delete(note))
        XCTAssertEqual(store.notes.map(\.body), ["Keep me"])
    }

    @MainActor
    func testDeleteRemovesNote() throws {
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let note = try XCTUnwrap(store.create(body: "Temporary"))

        store.delete(note)
        XCTAssertTrue(store.notes.isEmpty)
    }

    @MainActor
    func testOrderedNotesNewestFirst() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000))
        let store = try makeTestNoteStore(
            now: { clock.value },
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let older = try XCTUnwrap(store.create(body: "Older"))
        clock.value = Date(timeIntervalSince1970: 2_000)
        let newer = try XCTUnwrap(store.create(body: "Newer"))

        XCTAssertEqual(store.orderedNotes().map(\.id), [newer.id, older.id])
    }

    @MainActor
    func testRefreshSeesChangesSavedByAnotherModelContext() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = NoteStore(
            container: container,
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let externalContext = ModelContext(container)
        let externalNote = NoteItem(title: "Created elsewhere", body: "hi")

        externalContext.insert(externalNote)
        try externalContext.save()
        store.refresh()

        let imported = try XCTUnwrap(store.notes.first)
        XCTAssertEqual(imported.id, externalNote.id)
        XCTAssertEqual(imported.title, "Created elsewhere")

        externalNote.body = "Updated elsewhere"
        externalNote.updatedAt = Date(timeIntervalSince1970: 2_000)
        try externalContext.save()
        store.refresh()

        XCTAssertEqual(try XCTUnwrap(store.notes.first).body, "Updated elsewhere")
    }

    @MainActor
    func testRefreshHidesDuplicateApplicationIDsWithoutDeletingEitherRow() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let sharedID = UUID()
        let older = NoteItem(id: sharedID, title: "Older", body: "a", updatedAt: Date(timeIntervalSince1970: 1_000))
        let newer = NoteItem(id: sharedID, title: "Newer", body: "b", updatedAt: Date(timeIntervalSince1970: 2_000))
        context.insert(older)
        context.insert(newer)
        try context.save()

        let store = NoteStore(
            container: container,
            attachmentFileStore: makeTestAttachmentFileStore()
        )

        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.title, "Newer")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<NoteItem>()), 2)
    }

    @MainActor
    func testMutationsAndDeleteApplyToEveryPhysicalDuplicate() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seedContext = ModelContext(container)
        let sharedID = UUID()
        seedContext.insert(NoteItem(id: sharedID, title: "Older", body: "a"))
        seedContext.insert(NoteItem(
            id: sharedID,
            title: "Visible",
            body: "b",
            updatedAt: Date().addingTimeInterval(1)
        ))
        try seedContext.save()
        let store = NoteStore(
            container: container,
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let visible = try XCTUnwrap(store.notes.first)

        XCTAssertTrue(store.update(visible, title: "Unified", body: "z"))
        var verificationContext = ModelContext(container)
        var replicas = try verificationContext.fetch(FetchDescriptor<NoteItem>())
        XCTAssertEqual(replicas.count, 2)
        XCTAssertTrue(replicas.allSatisfy { $0.title == "Unified" && $0.body == "z" })

        XCTAssertTrue(store.delete(try XCTUnwrap(store.notes.first)))
        verificationContext = ModelContext(container)
        replicas = try verificationContext.fetch(FetchDescriptor<NoteItem>())
        XCTAssertTrue(replicas.isEmpty)
    }

    @MainActor
    func testSuccessfulCloudImportRefreshesChangesSavedOutsideStoreContext() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seedContext = ModelContext(container)
        seedContext.insert(NoteItem(title: "Before iPhone update", body: "v1"))
        try seedContext.save()

        let store = NoteStore(
            container: container,
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        XCTAssertEqual(store.notes.map(\.body), ["v1"])

        let externalContext = ModelContext(container)
        let importedNote = try XCTUnwrap(
            externalContext.fetch(FetchDescriptor<NoteItem>()).first
        )
        importedNote.body = "Updated from iPhone"
        importedNote.updatedAt = Date()
        try externalContext.save()
        XCTAssertEqual(store.notes.map(\.body), ["v1"])

        store.handleCloudSyncEvent(CloudSyncEventUpdate(
            id: UUID(),
            kind: .importData,
            endedAt: Date(),
            succeeded: true,
            errorMessage: nil
        ))
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(store.notes.map(\.body), ["Updated from iPhone"])
    }

    @MainActor
    func testRemoteDeletionMakesCapturedNoteReferencesNoOps() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = NoteStore(
            container: container,
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let capturedNote = try XCTUnwrap(store.create(body: "Deleted elsewhere"))
        let externalContext = ModelContext(container)
        let externalNote = try XCTUnwrap(
            externalContext.fetch(FetchDescriptor<NoteItem>()).first
        )
        externalContext.delete(externalNote)
        try externalContext.save()
        store.refresh()

        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertFalse(store.update(capturedNote, body: "Resurrected"))
        XCTAssertFalse(store.delete(capturedNote))
    }
}
