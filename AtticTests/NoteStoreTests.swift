import SwiftData
import XCTest
@testable import Attic

final class NoteStoreTests: XCTestCase {
    @MainActor
    func testCreateNormalizesTitleWithoutChangingMeaningfulBodyWhitespace() throws {
        let store = try makeTestNoteStore()

        XCTAssertNil(store.create(title: "   ", body: "   \n  "))
        let note = try XCTUnwrap(store.create(title: "  Meeting   notes ", body: "  Discuss\nrelease  "))

        XCTAssertEqual(note.title, "Meeting notes")
        XCTAssertEqual(note.body, "  Discuss\nrelease  ")
        XCTAssertEqual(store.notes.count, 1)
    }

    @MainActor
    func testUpdatePreservesMeaningfulBodyWhitespace() throws {
        let store = try makeTestNoteStore()
        let note = try XCTUnwrap(store.create(body: "Original"))

        XCTAssertTrue(store.update(note, body: "  Indented\ntext  "))
        XCTAssertEqual(try XCTUnwrap(store.notes.first).body, "  Indented\ntext  ")
    }

    @MainActor
    func testCreateAcceptsBodyWithoutTitle() throws {
        let store = try makeTestNoteStore()
        let note = try XCTUnwrap(store.create(body: "Quick jot"))

        XCTAssertEqual(note.title, "")
        XCTAssertEqual(note.body, "Quick jot")
    }

    @MainActor
    func testCreateReportsPersistenceFailureAndRollsBack() throws {
        let gate = PersistenceGate()
        gate.shouldFail = true
        let store = try makeTestNoteStore(persist: gate.save)

        XCTAssertNil(store.create(body: "Must not disappear"))
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertNotNil(store.lastErrorMessage)
    }

    @MainActor
    func testUpdateRejectsEmptyTitleAndBody() throws {
        let store = try makeTestNoteStore()
        let note = try XCTUnwrap(store.create(title: "Keep", body: "me"))

        XCTAssertFalse(store.update(note, title: "   ", body: "   "))
        XCTAssertEqual(try XCTUnwrap(store.notes.first).title, "Keep")
        XCTAssertEqual(try XCTUnwrap(store.notes.first).body, "me")
    }

    @MainActor
    func testFailedSaveRestoresNote() throws {
        let gate = PersistenceGate()
        let store = try makeTestNoteStore(persist: gate.save)
        let note = try XCTUnwrap(store.create(body: "Keep me"))
        gate.shouldFail = true

        XCTAssertFalse(store.update(note, body: "Changed"))
        XCTAssertEqual(try XCTUnwrap(store.notes.first).body, "Keep me")

        XCTAssertFalse(store.delete(note))
        XCTAssertEqual(store.notes.map(\.body), ["Keep me"])
    }

    @MainActor
    func testDeleteRemovesNote() throws {
        let store = try makeTestNoteStore()
        let note = try XCTUnwrap(store.create(body: "Temporary"))

        store.delete(note)
        XCTAssertTrue(store.notes.isEmpty)
    }

    @MainActor
    func testOrderedNotesNewestFirst() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000))
        let store = try makeTestNoteStore(now: { clock.value })
        let older = try XCTUnwrap(store.create(body: "Older"))
        clock.value = Date(timeIntervalSince1970: 2_000)
        let newer = try XCTUnwrap(store.create(body: "Newer"))

        XCTAssertEqual(store.orderedNotes().map(\.id), [newer.id, older.id])
    }

    @MainActor
    func testRefreshSeesChangesSavedByAnotherModelContext() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = NoteStore(container: container)
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

        let store = NoteStore(container: container)

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
        let store = NoteStore(container: container)
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

        let store = NoteStore(container: container)
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
        let store = NoteStore(container: container)
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

    @MainActor
    func testExternalRecordsRefreshFreshContextAndOrderDeterministically() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000))
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = NoteStore(container: container, now: { clock.value })
        let older = try XCTUnwrap(store.create(title: "Older", body: "one"))
        clock.value = Date(timeIntervalSince1970: 2_000)
        let newer = try XCTUnwrap(store.create(title: "Newer", body: "two"))

        let externalContext = ModelContext(container)
        let externalOlder = try XCTUnwrap(
            externalContext.fetch(FetchDescriptor<NoteItem>()).first { $0.id == older.id }
        )
        externalOlder.body = "changed outside the store"
        externalOlder.updatedAt = Date(timeIntervalSince1970: 3_000)
        try externalContext.save()

        let records = try store.recordsForExternalAccess()

        XCTAssertEqual(records.map(\.id), [older.id, newer.id])
        XCTAssertEqual(records.first?.body, "changed outside the store")
        XCTAssertTrue(records.allSatisfy { $0.revision.hasPrefix("v1:") })
    }

    @MainActor
    func testExternalUpdateChecksRevisionAndMutatesEveryPhysicalReplica() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seedContext = ModelContext(container)
        let sharedID = UUID()
        seedContext.insert(NoteItem(
            id: sharedID,
            title: "Older",
            body: "one",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        seedContext.insert(NoteItem(
            id: sharedID,
            title: "Visible",
            body: "two",
            createdAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 2_000)
        ))
        try seedContext.save()
        let clock = MutableNow(Date(timeIntervalSince1970: 3_000))
        let store = NoteStore(container: container, now: { clock.value })
        let before = try store.recordForExternalAccess(id: sharedID)

        let updated = try store.updateForExternalAccess(
            id: sharedID,
            expectedRevision: before.revision,
            title: nil,
            body: "unified"
        )

        XCTAssertEqual(updated.title, "Visible")
        XCTAssertEqual(updated.body, "unified")
        XCTAssertEqual(updated.createdAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(updated.updatedAt, clock.value)
        XCTAssertNotEqual(updated.revision, before.revision)
        let verificationContext = ModelContext(container)
        let replicas = try verificationContext.fetch(FetchDescriptor<NoteItem>())
        XCTAssertEqual(replicas.count, 2)
        XCTAssertTrue(replicas.allSatisfy {
            $0.title == "Visible"
                && $0.body == "unified"
                && $0.createdAt == Date(timeIntervalSince1970: 200)
                && $0.updatedAt == clock.value
        })
    }

    @MainActor
    func testExternalStaleRevisionConflictsWithoutChangingReplicas() throws {
        let store = try makeTestNoteStore()
        let created = try store.createForExternalAccess(title: "Title", body: "v1")
        let updated = try store.updateForExternalAccess(
            id: created.id,
            expectedRevision: created.revision,
            title: nil,
            body: "v2"
        )

        XCTAssertThrowsError(try store.updateForExternalAccess(
            id: created.id,
            expectedRevision: created.revision,
            title: nil,
            body: "stale"
        )) { error in
            guard let accessError = error as? NoteExternalAccessError,
                  case let .conflict(currentRevision) = accessError else {
                return XCTFail("Expected a revision conflict, got \(error)")
            }
            XCTAssertEqual(currentRevision, updated.revision)
        }
        XCTAssertEqual(store.notes.first?.body, "v2")
    }

    @MainActor
    func testExternalAppendPreservesExactPlainTextAndEnforcesResultLimit() throws {
        let store = try makeTestNoteStore()
        let prefix = String(repeating: "a", count: NoteExternalAccessLimits.maximumBodyUTF8Bytes - 4)
        let created = try store.createForExternalAccess(title: "", body: prefix)

        let full = try store.appendForExternalAccess(
            id: created.id,
            expectedRevision: created.revision,
            content: "👋"
        )
        XCTAssertEqual(full.body, prefix + "👋")
        XCTAssertEqual(full.body.utf8.count, NoteExternalAccessLimits.maximumBodyUTF8Bytes)

        XCTAssertThrowsError(try store.appendForExternalAccess(
            id: full.id,
            expectedRevision: full.revision,
            content: "x"
        )) { error in
            XCTAssertEqual(error as? NoteExternalAccessError, .invalidContent)
        }
        XCTAssertEqual(store.notes.first?.body, prefix + "👋")
    }

    @MainActor
    func testExternalDeleteRequiresCurrentRevisionAndDeletesAllReplicas() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let sharedID = UUID()
        context.insert(NoteItem(id: sharedID, body: "a"))
        context.insert(NoteItem(id: sharedID, body: "b", updatedAt: Date().addingTimeInterval(1)))
        try context.save()
        let store = NoteStore(container: container)
        let record = try store.recordForExternalAccess(id: sharedID)

        XCTAssertThrowsError(try store.deleteForExternalAccess(
            id: sharedID,
            expectedRevision: "v1:stale"
        )) { error in
            guard let accessError = error as? NoteExternalAccessError,
                  case .conflict = accessError else {
                return XCTFail("Expected a revision conflict, got \(error)")
            }
        }
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteItem>()), 2)

        try store.deleteForExternalAccess(id: sharedID, expectedRevision: record.revision)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteItem>()), 0)
        XCTAssertTrue(store.notes.isEmpty)
    }

    @MainActor
    func testExternalRevisionIsStableAcrossOnDiskStoreRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("development.store")

        var firstContainer: ModelContainer? = try makeOnDiskTestContainer(at: storeURL)
        var firstStore: NoteStore? = NoteStore(container: try XCTUnwrap(firstContainer))
        let created = try XCTUnwrap(firstStore).createForExternalAccess(
            title: "Persistent",
            body: "survives relaunch"
        )
        firstStore = nil
        firstContainer = nil

        let secondContainer = try makeOnDiskTestContainer(at: storeURL)
        let secondStore = NoteStore(container: secondContainer)
        let relaunched = try secondStore.recordForExternalAccess(id: created.id)

        XCTAssertEqual(relaunched.title, "Persistent")
        XCTAssertEqual(relaunched.body, "survives relaunch")
        XCTAssertEqual(relaunched.revision, created.revision)
    }

    private func makeOnDiskTestContainer(at url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "development-test",
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: TaskItem.self,
            NoteItem.self,
            configurations: configuration
        )
    }
}
