import AppKit
import Foundation
import SwiftData
import XCTest
@testable import Attic

@MainActor
final class WorkspaceCommitTests: XCTestCase {
    private var root: URL!
    private var container: ModelContainer!
    private var coordinator: WorkspaceOperationCoordinator!
    private var taskID: UUID!
    private var noteID: UUID!
    private var original: NoteDocument!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticWorkspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        coordinator = try WorkspaceOperationCoordinator(container: container,
            journal: NoteDraftJournal(directory: root.appendingPathComponent("NoteDrafts")))
        taskID = UUID(); noteID = UUID()
        original = try NoteDocument(blocks: [.text("Parent"), .text("Make this a child"), .text("Keep this")]).taskSnapshot(title: "Parent")
        let context = coordinator.freshContext()
        context.insert(TaskItem(id: taskID, title: "Parent"))
        let note = NoteItem(id: noteID)
        NoteStore.stageDocumentContent(try PreparedNoteDocument(original), format: 1, on: [note],
            timestamp: Date(timeIntervalSince1970: 123), revision: 0, revisionID: UUID())
        note.taskID = taskID
        context.insert(note)
        try context.save()
    }
    override func tearDown() async throws {
        coordinator = nil; container = nil
        try FileManager.default.removeItem(at: root)
    }
    private var baseOwners: Set<WorkspaceOwner> {
        [WorkspaceOwner(entity: .task, id: taskID), WorkspaceOwner(entity: .note, id: noteID)]
    }

    func testCombinedSubtaskMoveUsesPlainGateAndUpdatesMembership() throws {
        let tasks = TaskStore(container: container)
        let destination = try XCTUnwrap(tasks.create(title: "Destination"))
        let child = try XCTUnwrap(tasks.create(title: "Child", parentID: taskID))
        coordinator.validationCounters = .init()
        XCTAssertTrue(tasks.reparentSubtask(child.id, to: destination.id))
        XCTAssertEqual(coordinator.validationCounters, .init(fastValidations: 1, slowValidations: 0, freshContexts: 0))
        XCTAssertEqual(tasks.subtasks(of: destination.id).map(\.id), [child.id])
        XCTAssertTrue(tasks.subtasks(of: taskID).isEmpty)
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<OperationReceipt>()), 0)
    }

    func testCombinedSubtaskMoveRefusesForeignEditWithoutOverwritingIt() throws {
        let tasks = TaskStore(container: container)
        let destination = try XCTUnwrap(tasks.create(title: "Destination"))
        let child = try XCTUnwrap(tasks.create(title: "Child", parentID: taskID))
        let foreign = ModelContext(container), id = child.id
        let changed = try XCTUnwrap(foreign.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first)
        changed.title = "Foreign title"
        try foreign.save()
        XCTAssertFalse(tasks.reparentSubtask(id, to: destination.id))
        XCTAssertEqual(tasks.task(withID: id)?.title, "Foreign title")
        XCTAssertEqual(tasks.task(withID: id)?.parentID, taskID)
        XCTAssertFalse(try XCTUnwrap(tasks.task(withID: id)?.modelContext).hasChanges)
    }

    func testCombinedTagRenameUsesJournaledMixedGateAndPublishesInventory() throws {
        let tasks = TaskStore(container: container)
        let notes = NoteStore(container: container,
            attachmentFileStore: AttachmentFileStore(rootURL: root.appendingPathComponent("TagFiles")))
        let library = AtticLibrary(tasks: tasks, notes: notes)
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: taskID)), tags: ["before"]))
        XCTAssertTrue(notes.setTags(["before"], for: try XCTUnwrap(notes.note(withID: noteID))))
        XCTAssertEqual(library.tags.countsByName["before"], 2)
        let receiptCount = try coordinator.freshContext().fetchCount(FetchDescriptor<OperationReceipt>())
        XCTAssertNotNil(library.tags.rename("before", to: "after"))
        XCTAssertEqual(library.tags.countsByName["after"], 2)
        XCTAssertNil(library.tags.countsByName["before"])
        XCTAssertEqual(tasks.task(withID: taskID)?.tags, ["after"])
        XCTAssertEqual(notes.note(withID: noteID)?.tags, ["after"])
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<OperationReceipt>()), receiptCount + 1)
    }
    private func conversion(failAfter: Int? = nil,
                            preDraft: NoteDraftJournalEntry? = nil, checkpointClaim: NoteRecoveryClaim? = nil,
                            publication: WorkspaceOperationCoordinator.Publication = .init()) async throws -> (WorkspaceOperationCoordinator.Outcome, UUID) {
        let context = coordinator.freshContext()
        let id = noteID!
        let note = try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })).first)
        let versionID = UUID(), childID = UUID(), associationID = UUID(), attachmentID = UUID()
        let payload = Data("original imported bytes".utf8)
        let staged = StagedNoteAttachment(id: attachmentID, filename: "fixture.txt",
            contentTypeIdentifier: "public.plain-text", byteCount: Int64(payload.count),
            digest: NotePayloadDigest.sha256(payload), data: payload)
        var candidate = original!
        candidate.blocks.remove(at: 1)
        candidate.blocks.append(.file(attachmentID: attachmentID, filename: "fixture.txt",
            contentTypeIdentifier: "public.plain-text", byteCount: Int64(payload.count)))
        candidate.refreshRequiredCapabilities()
        let projection = try PreparedNoteDocument(candidate)
        let owners = baseOwners.union([
            WorkspaceOwner(entity: .task, id: childID), .init(entity: .version, id: versionID),
            .init(entity: .association, id: associationID), .init(entity: .attachment, id: attachmentID)
        ])
        let envelope = try coordinator.newEnvelope(intent: "Make Subtask", reads: try coordinator.capture(owners),
            writes: owners, preDraft: preDraft, afterDocuments: [id: projection.content], checkpointClaim: checkpointClaim, staged: [staged])
        let versionIDs = [note.persistentModelID: versionID]
        let result = await coordinator.execute(envelope, stage: { commit in
            _ = try TaskStore.stageCreation(in: commit,
                drafts: [TaskDraft(title: "Make this a child", parentID: self.taskID)],
                ids: [childID], timestamp: Date(timeIntervalSince1970: 124))
            if failAfter == 1 { throw WorkspaceFoundationError.preparationFailed }
            try NoteStore.stageDocument(in: commit, noteID: id, document: candidate, prepared: projection,
                revisionID: UUID(), versionIDs: versionIDs, staged: [staged], timestamp: Date(timeIntervalSince1970: 124))
            if failAfter == 2 { throw WorkspaceFoundationError.preparationFailed }
            let association = TaskNoteAssociation(id: associationID, taskID: self.taskID, noteID: id)
            commit.insert(association)
            let rootID = self.taskID!
            for row in try commit.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == rootID })) {
                row.associationGeneration += 1; association.taskGeneration = row.associationGeneration
            }
            for row in try commit.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })) {
                row.associationGeneration += 1; association.noteGeneration = row.associationGeneration
            }
            if failAfter == 3 { throw WorkspaceFoundationError.preparationFailed }
        }, publication: publication)
        return (result, envelope.id)
    }

    func testC1ConversionRefusalsAndSaveFailureLeaveEveryPhysicalFamilyUnchanged() async throws {
        let before = try coordinator.capture(baseOwners)
        for point in [1, 2, 3, 4] {
            if point == 4 { coordinator.save = { _ in throw WorkspaceFoundationError.preparationFailed } }
            let (outcome, _) = try await conversion(failAfter: point)
            XCTAssertEqual(outcome, .notCommitted)
            XCTAssertEqual(try coordinator.capture(baseOwners), before)
            let context = coordinator.freshContext()
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskItem>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<NoteVersion>()), 0)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskNoteAssociation>()), 0)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<NoteAttachment>()), 0)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<OperationReceipt>()), 0)
        }
    }
    func testC1MetadataOnlyWritePreservesDifferentPhysicalDocumentFormats() throws {
        let context = coordinator.freshContext(), legacy = NoteItem(id: noteID, title: "Legacy", body: "Unchanged legacy body")
        context.insert(legacy); try context.save()
        let owner = WorkspaceOwner(entity: .note, id: noteID), before = try coordinator.capture([owner])
        let store = NoteStore(container: container)
        XCTAssertTrue(store.setPinned(true, noteID: noteID), store.lastErrorMessage ?? "pin refused")
        let after = try coordinator.capture([owner])
        XCTAssertEqual(after.first?.replicas.count, 2)
        for original in try XCTUnwrap(before.first).replicas {
            let current = try XCTUnwrap(after.first?.replicas.first { $0.physicalID == original.physicalID })
            XCTAssertEqual(current.fields["content"], original.fields["content"])
            XCTAssertEqual(current.fields["contentFormat"], original.fields["contentFormat"])
            XCTAssertEqual(current.fields["title"], original.fields["title"])
            XCTAssertEqual(current.fields["body"], original.fields["body"])
        }
        let id = noteID!
        XCTAssertTrue(try coordinator.freshContext().fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })).allSatisfy(\.isPinned))
    }

    func testC1DeclaredAfterDocumentCannotCommitOnlyTheModelHalf() async throws {
        let before = try coordinator.capture(baseOwners)
        var candidate = original!
        candidate.blocks.remove(at: 1)
        let prepared = try PreparedNoteDocument(candidate)
        let envelope = try coordinator.newEnvelope(intent: "Incomplete forward conversion", reads: before, writes: baseOwners,
            afterDocuments: [noteID: prepared.content])
        let outcome = await coordinator.execute(envelope, stage: { context in
            try TaskStore.stageUpdate(in: context, taskID: self.taskID, title: "Must roll back", timestamp: Date())
        })
        XCTAssertEqual(outcome, .notCommitted)
        XCTAssertEqual(try coordinator.capture(baseOwners), before)
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<OperationReceipt>()), 0)
    }

    func testC5FailedIdenticalPlainSaveDoesNotAcknowledgeCommitOrHoldRetry() throws {
        let owner = WorkspaceOwner(entity: .task, id: taskID)
        let before = try coordinator.capture([owner])
        var attempts = 0
        coordinator.save = { _ in attempts += 1; throw PersistenceGate.Failure() }
        XCTAssertEqual(coordinator.plainSave(tokens: before, writes: [owner], stage: { _ in }), .notCommitted)
        XCTAssertEqual(attempts, 1, "An explicit idempotent repair still crosses the save gate")
        XCTAssertEqual(try coordinator.capture([owner]), before)
        coordinator.save = { try $0.save() }
        XCTAssertEqual(coordinator.plainSave(tokens: before, writes: [owner], stage: { _ in }), .committed,
                       "A failed identical save does not leave an ambiguous-owner hold")
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<OperationReceipt>()), 0)
    }

    func testC5TasksBatchHasOnePlainDomainSaveAndNoBookkeeping() throws {
        let gate = PersistenceGate()
        let store = TaskStore(container: container, persist: gate.save)
        let before = gate.saveCount, beforeBookkeeping = gate.bookkeepingSaveCount
        let created = try XCTUnwrap(store.commit([TaskDraft(title: "One"), TaskDraft(title: "Two")]))
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(gate.saveCount, before + 1, "Tasks commands have one gated domain transaction")
        XCTAssertEqual(gate.bookkeepingSaveCount, beforeBookkeeping)
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<OperationReceipt>()), 0)
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<TaskItem>()), 3)
    }

    func testC2NoteFingerprintTracksPreparedBytesAndPreservesLegacySnapshots() throws {
        let note = NoteItem(), prepared = try PreparedNoteDocument(NoteDocument(blocks: [.text("Prepared bytes")]))
        note.installPreparedContent(prepared)
        XCTAssertEqual(note.contentFingerprint, WorkspaceModelFields.digest(note.content))
        let before = try WorkspaceModelFields.fingerprint(note)
        note.content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Direct write")]))
        XCTAssertNotEqual(try WorkspaceModelFields.fingerprint(note)["content"], before["content"])
        XCTAssertEqual(note.contentFingerprint, WorkspaceModelFields.digest(note.content))
        // A migrated row may have no optional digest yet. Its guard must use
        // the real bytes, and explicit snapshots must round-trip the nil.
        note.contentFingerprint = nil
        let snapshot = try WorkspaceModelFields.read(note), copy = NoteItem()
        try WorkspaceModelFields.apply(snapshot, to: copy)
        XCTAssertEqual(copy.content, note.content)
        XCTAssertNil(copy.contentFingerprint)
        XCTAssertEqual(try WorkspaceModelFields.fingerprint(copy), try WorkspaceModelFields.fingerprint(note))
    }

    func testC2PrimitiveGuardsRemainCompatibleWithPreviouslyEncodedTokens() throws {
        let id = UUID(), source = coordinator.freshContext()
        let child = TaskItem(id: id, title: "Compatible", parentID: taskID)
        source.insert(child); try source.save()
        let owner = WorkspaceOwner(entity: .task, id: id)
        for order in [Int64.min, 0, Int64.max] {
            let context = coordinator.freshContext()
            let row = try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first)
            row.manualOrder = order; try context.save()
            let current = try WorkspaceModelToken.read(owner, in: coordinator.freshContext())
            let snapshot = try WorkspaceModelFields.read(row)
            var legacyFields = current.replicas[0].fields
            for key in ["id", "parentID", "manualOrder", "listOrderVersion", "associationGeneration"] {
                legacyFields[key] = snapshot[key]
            }
            let legacy = WorkspaceModelToken(owner: owner, replicas: [.init(physicalID: row.persistentModelID, fields: legacyFields)])
            let reopened = try JSONDecoder().decode(WorkspaceModelToken.self, from: WorkspaceModelFields.encode(legacy))
            XCTAssertEqual(coordinator.plainSave(tokens: [reopened], writes: [owner], stage: { commit in
                (commit.model(for: row.persistentModelID) as? TaskItem)?.title = "Accepted \(order)"
            }), .committed, "existing JSON scalar guards remain valid after the encoding optimization")
        }
    }

    func testC2CanonicalUnicodeMetadataChangeStillRefusesAStaleWrite() throws {
        let owner = WorkspaceOwner(entity: .note, id: noteID), id = noteID!
        let source = coordinator.freshContext()
        let row = try XCTUnwrap(source.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })).first)
        row.tagsRaw = "[\"Cafe\u{301}\"]"
        try source.save()
        let before = try WorkspaceModelToken.read(owner, in: coordinator.freshContext())
        let external = coordinator.freshContext()
        let changed = try XCTUnwrap(external.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })).first)
        changed.tagsRaw = "[\"Caf\u{e9}\"]"
        try external.save()
        var staged = false
        XCTAssertEqual(coordinator.plainSave(tokens: [before], writes: [owner], stage: { _ in staged = true }), .conflict)
        XCTAssertFalse(staged, "canonically equal text must not hide different persisted UTF-8 metadata")
    }

    func testC2CanonicalUnicodeLongBodyChangeStillRefusesAStaleWrite() throws {
        let owner = WorkspaceOwner(entity: .note, id: noteID), id = noteID!
        let source = coordinator.freshContext()
        let row = try XCTUnwrap(source.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })).first)
        row.body = String(repeating: "Cafe\u{301}", count: 300)
        try source.save()
        let before = try WorkspaceModelToken.read(owner, in: coordinator.freshContext())
        let external = coordinator.freshContext()
        let changed = try XCTUnwrap(external.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })).first)
        changed.body = String(repeating: "Caf\u{e9}", count: 300)
        try external.save()
        var staged = false
        XCTAssertEqual(coordinator.plainSave(tokens: [before], writes: [owner], stage: { _ in staged = true }), .conflict)
        XCTAssertFalse(staged, "a memoized long body must still guard its exact persisted UTF-8 bytes")
    }

    func testC2LegacyMissingPayloadFingerprintsPreserveExplicitSnapshotRoundTrips() throws {
        let bytes = Data("legacy bytes".utf8)
        let attachment = NoteAttachment(noteID: noteID, originalFilename: "legacy.txt", byteCount: Int64(bytes.count),
            sortIndex: 0, contentDigest: NotePayloadDigest.sha256(bytes), payload: bytes)
        let version = NoteVersion(noteID: noteID, createdAt: Date(), reason: .leave, content: bytes,
            contentFormat: 1, title: "Legacy", body: "", attachmentIDs: [], sourceRevisionID: nil)
        let proposal = NotePendingEdit(noteID: noteID, baseRevisionToken: "old", proposedContent: bytes,
            agentName: "Legacy", createdAt: Date())
        // Optional digest columns are absent on rows from the previous schema.
        attachment.payloadFingerprint = nil; version.contentFingerprint = nil; proposal.proposalFingerprint = nil
        let copies: [any PersistentModel] = [
            NoteAttachment(noteID: noteID, originalFilename: "", byteCount: 0, sortIndex: 0, contentDigest: ""),
            NoteVersion(noteID: noteID, createdAt: Date(), reason: .leave, content: nil,
                contentFormat: 0, title: "", body: "", attachmentIDs: [], sourceRevisionID: nil),
            NotePendingEdit(noteID: noteID, baseRevisionToken: "", proposedContent: Data(), agentName: "", createdAt: Date())
        ]
        for (original, copy) in zip([attachment, version, proposal] as [any PersistentModel], copies) {
            let snapshot = try WorkspaceModelFields.read(original)
            try WorkspaceModelFields.apply(snapshot, to: copy)
            XCTAssertEqual(try WorkspaceModelFields.read(copy), snapshot)
            XCTAssertEqual(try WorkspaceModelFields.fingerprint(copy), try WorkspaceModelFields.fingerprint(original))
            try WorkspaceModelFields.copy(Set(snapshot.keys), from: original, to: copy)
            XCTAssertEqual(try WorkspaceModelFields.read(copy), snapshot, "typed ingestion retains legacy missing digests too")
        }
    }

    func testC1PlainAutosaveCanThenEditAnUnrelatedRetainedNoteWithoutDuplicates() throws {
        let store = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let second = NoteDocument(blocks: [.text("Second")])
        let (secondID, secondBase) = try store.createDocumentNote(id: UUID(), document: second).get()
        let firstBase = try XCTUnwrap(store.note(withID: noteID)).revisionID
        var firstChange = original!
        firstChange.blocks.append(.text("First changed"))
        _ = try store.saveDocument(noteID: noteID, document: firstChange, baseRevisionID: firstBase,
                                  prepared: PreparedNoteDocument(firstChange)).get()
        var secondChange = second
        secondChange.blocks.append(.text("Second changed"))
        _ = try store.saveDocument(noteID: secondID, document: secondChange, baseRevisionID: secondBase,
                                  prepared: PreparedNoteDocument(secondChange)).get()
        let saved = try coordinator.freshContext().fetch(FetchDescriptor<NoteItem>())
        XCTAssertEqual(saved.count, 2)
        for (id, document) in [(noteID!, firstChange), (secondID, secondChange)] {
            let row = try XCTUnwrap(saved.first { $0.id == id })
            XCTAssertEqual(NoteContentCodec.decode(try XCTUnwrap(row.content)).document, document)
        }
    }

    func testC5ProductionTaskCRUDHasNoEnvelopeOrReceipt() async throws {
        let gate = PersistenceGate()
        let tasks = TaskStore(container: container, persist: gate.save)
        let library = AtticLibrary(tasks: tasks)
        let initial = gate.bookkeepingSaveCount
        XCTAssertEqual(library.updateTask(taskID, status: .done), .applied)
        XCTAssertEqual(library.updateTask(taskID, title: "Renamed"), .applied)
        let added = try XCTUnwrap(library.createTasks([TaskDraft(title: "Added"), TaskDraft(title: "Peer")]))
        XCTAssertEqual(library.moveTask(added[0].id, toIndex: 1), .applied)
        XCTAssertEqual(library.deleteTasks([added[0].id]), .applied)
        XCTAssertEqual(gate.bookkeepingSaveCount, initial)
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<OperationReceipt>()), 0)
        let envelopes = try await coordinator.journal.operationEnvelopes()
        XCTAssertTrue(envelopes.isEmpty)
    }

    func testPF4ProductionHotPathsReadNoStoredPayloads() async throws {
        let fixture = coordinator.freshContext()
        let bytes = Data(repeating: 42, count: 2 * 1_024 * 1_024)
        fixture.insert(NoteAttachment(noteID: noteID, originalFilename: "unreferenced.bin", byteCount: Int64(bytes.count),
            sortIndex: 0, contentDigest: NotePayloadDigest.sha256(bytes), payload: bytes))
        fixture.insert(NoteVersion(noteID: noteID, createdAt: Date(), reason: .leave, content: bytes, contentFormat: 1,
            title: "Stored version", body: "", attachmentIDs: [], sourceRevisionID: UUID()))
        fixture.insert(NotePendingEdit(noteID: noteID, baseRevisionToken: "old", proposedContent: bytes,
            agentName: "PF4", createdAt: Date()))
        try fixture.save()
        let tasks = TaskStore(container: container), notes = NoteStore(container: container,
            attachmentFileStore: makeTestAttachmentFileStore())
        let library = AtticLibrary(tasks: tasks, notes: notes)
        await notes.waitForAttachmentReconciliation()
        let current = try XCTUnwrap(notes.note(withID: noteID))
        var candidate = original!; candidate.blocks[2] = .text("Hot path")
        let prepared = try PreparedNoteDocument(candidate)
        WorkspacePayloadAccess.counts = [:]
        let revision = try notes.saveDocument(noteID: noteID, document: candidate,
            baseRevisionID: current.revisionID, prepared: prepared).get()
        XCTAssertNotNil(revision)
        XCTAssertEqual(library.updateTask(taskID, status: .done), .applied)
        let link = try XCTUnwrap(library.links.link(.init(.task, taskID), to: .init(.note, noteID), kind: .reference))
        XCTAssertTrue(library.links.unlink(link.id))
        let metadata = WorkspaceLegacyBridge.context(for: container)
        let storedVersion = try XCTUnwrap(metadata.fetch(FetchDescriptor<NoteVersion>()).first)
        let storedProposal = try XCTUnwrap(metadata.fetch(FetchDescriptor<NotePendingEdit>()).first)
        WorkspaceLegacyBridge.captureBeforeMutation(storedVersion, in: metadata)
        WorkspaceLegacyBridge.captureBeforeMutation(storedProposal, in: metadata)
        storedVersion.createdAt = Date()
        storedProposal.needsReview = true
        try WorkspaceLegacyBridge.persist(metadata, using: { try $0.save() }, sourceName: "stored metadata")
        XCTAssertEqual(WorkspacePayloadAccess.counts.values.reduce(0, +), 0, "PF4 faults: \(WorkspacePayloadAccess.counts)")
        let envelopes = try await coordinator.journal.operationEnvelopes()
        XCTAssertTrue(envelopes.isEmpty, "Metadata and production hot paths carry no journal obligation")
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<OperationReceipt>()), 0)
        // Prove the seam detects real getters; a silently inert counter cannot pass.
        let positive = coordinator.freshContext()
        _ = try positive.fetch(FetchDescriptor<NoteAttachment>()).first?.payload
        _ = try positive.fetch(FetchDescriptor<NoteVersion>()).first?.content
        _ = try positive.fetch(FetchDescriptor<NotePendingEdit>()).first?.proposedContent
        XCTAssertEqual(WorkspacePayloadAccess.counts, ["attachment": 1, "version": 1, "proposal": 1])
    }

    func testC2IndexedMembershipMatchesFreshQueriesAndKeepsDivergentReplicasComplete() throws {
        let childID = UUID(), otherParent = UUID()
        let context = coordinator.freshContext()
        context.insert(TaskItem(id: childID, title: "First", parentID: taskID))
        context.insert(TaskItem(id: childID, title: "Divergent", parentID: otherParent))
        try context.save()
        let inventory = try WorkspaceLegacyBridge.inventory(in: context, includeCanvas: false)
        let index = try WorkspaceScopeIndex(inventory)
        let missing = WorkspaceOwner(entity: .task, id: UUID())
        let owners = Set(inventory.keys).union([missing])
        let batched = try WorkspaceModelToken.read(owners: owners, in: context)
        XCTAssertEqual(batched[missing]?.replicas, [])
        for owner in owners { XCTAssertEqual(batched[owner], try WorkspaceModelToken.read(owner, in: context)) }
        let scopes: Set<WorkspaceScope> = [.children(taskID), .children(otherParent), .children(UUID()),
            .taskAssociations(taskID), .noteAssociations(noteID), .attachments(noteID), .versions(noteID), .proposals(noteID)]
        let memberships = try WorkspaceScopeToken.read(scopes: scopes, in: context)
        for scope in scopes { XCTAssertEqual(memberships[scope], try WorkspaceScopeToken.read(scope, in: context)) }
        for parent in [taskID!, otherParent] {
            let scope = WorkspaceScope.children(parent)
            XCTAssertEqual(index.token(scope), try WorkspaceScopeToken.read(scope, in: context))
            XCTAssertEqual(index.token(scope).members.first?.replicas.count, 2)
        }
        let replacementParent = UUID()
        for row in try context.fetch(FetchDescriptor<TaskItem>()) where row.id == childID { row.parentID = replacementParent }
        try context.save()
        let updated = try WorkspaceModelToken.read(.init(entity: .task, id: childID), in: context)
        let replaced = try index.replacing([updated.owner: updated])
        for parent in [taskID!, otherParent, replacementParent] {
            let scope = WorkspaceScope.children(parent)
            XCTAssertEqual(replaced.token(scope), try WorkspaceScopeToken.read(scope, in: context))
        }
        let unknown: [WorkspaceOwner: WorkspaceModelToken] = [.init(entity: .task, id: childID): .init(owner: .init(entity: .task, id: childID), replicas: [.init(physicalID: try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>()).first).persistentModelID, fields: [:])])]
        XCTAssertThrowsError(try WorkspaceScopeIndex(unknown), "missing fields are unknown, never empty membership")
    }
    func testC2ConfirmedPresentationBaselineStillRejectsAnExternallyInsertedPhysicalReplica() throws {
        let store = TaskStore(container: container)
        let row = try XCTUnwrap(store.create(title: "Original"))
        XCTAssertTrue(store.rename(row, to: "Confirmed"))
        let external = coordinator.freshContext()
        external.insert(TaskItem(id: row.id, title: "External"))
        try external.save()
        XCTAssertFalse(store.rename(row, to: "Must refuse"), "cached presentation baseline is never commit authority")
        let id = row.id
        let rows = try coordinator.freshContext().fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
        XCTAssertEqual(Set(rows.map(\.title)), ["Confirmed", "External"])
        XCTAssertEqual(rows.count, 2)
    }
    func testC2SuccessfulDirectFixtureSaveRefreshesTheGuardBaselineWithPermanentIDs() throws {
        let store = NoteStore(container: container)
        let row = try XCTUnwrap(store.create(title: "Original"))
        let source = store.modelContext
        source.insert(NoteItem(id: row.id, title: "Duplicate"))
        try source.save()
        let owner = WorkspaceOwner(entity: .note, id: row.id)
        XCTAssertEqual(try WorkspaceLegacyBridge.capturedToken(owner, in: source),
                       try WorkspaceModelToken.read(owner, in: coordinator.freshContext()),
                       "successful fixture save must refresh permanent identities and every replica field")
        XCTAssertTrue(store.update(row, title: "Renamed"), store.lastErrorMessage ?? "No failure reason")
        XCTAssertEqual(Set(try coordinator.freshContext().fetch(FetchDescriptor<NoteItem>()).filter { $0.id == row.id }.map(\.title)), ["Renamed"])
    }
    func testC5IsolatedTaskSaveRefreshesOnlyItsFamilyAndRebindsUnchangedRowsForLaterStaging() throws {
        let store = TaskStore(container: container)
        let edited = try XCTUnwrap(store.create(title: "Edited"))
        let other = try XCTUnwrap(store.create(title: "Other"))
        let unchanged = try XCTUnwrap(store.tasks.first { $0.id == other.id })
        XCTAssertTrue(store.rename(edited, to: "Renamed"))
        XCTAssertTrue(store.tasks.first { $0.id == other.id } === unchanged,
                      "isolated plain saves must not refetch unrelated presentation rows")
        let rebound = try XCTUnwrap(store.task(withID: other.id))
        XCTAssertTrue(store.tasks.contains { $0 === rebound }, "the unrelated row is still presented and usable for the next staging")
        rebound.tagsRaw = "fixture"
        XCTAssertTrue(store.rename(rebound, to: "Other renamed"), store.lastErrorMessage ?? "No failure reason")
        let fresh = coordinator.freshContext()
        let rows = try fresh.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(rows.first { $0.id == other.id }?.tagsRaw, "fixture")
        XCTAssertEqual(rows.first { $0.id == edited.id }?.title, "Renamed")
        XCTAssertEqual(rows.filter { $0.id == other.id }.count, 1)
    }
    func testC1RealConversionCommitsTextChildVersionAttachmentAssociationAndReceiptTogether() async throws {
        let (outcome, id) = try await conversion()
        XCTAssertEqual(outcome, .committed)
        let context = coordinator.freshContext()
        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks.first { $0.parentID == taskID }?.title, "Make this a child")
        let note = try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>()).first)
        let document = try XCTUnwrap(note.content.flatMap { NoteContentCodec.decode($0).document })
        XCTAssertFalse(document.blocks.contains { $0.text == "Make this a child" })
        XCTAssertEqual(document.blocks[1].text, "Keep this")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<NoteVersion>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskNoteAssociation>()), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<NoteAttachment>()).first?.payload, Data("original imported bytes".utf8))
        let receipts = try context.fetch(FetchDescriptor<OperationReceipt>())
        XCTAssertEqual(receipts.map(\.id), [id]); XCTAssertTrue(receipts[0].publicationComplete)
    }
    func testC2WarmPresentationCannotOverwriteAFreshGatedRename() async throws {
        let tokens = try coordinator.capture(baseOwners)
        let warm = try coordinator.freshContext().fetch(FetchDescriptor<TaskItem>()).first!
        let renameEnvelope = try coordinator.newEnvelope(intent: "workspace rename", reads: tokens, writes: [.init(entity: .task, id: taskID)])
        let rename = await coordinator.execute(renameEnvelope, stage: { context in
            try TaskStore.stageUpdate(in: context, taskID: self.taskID, title: "Fresh", timestamp: Date())
        })
        XCTAssertEqual(rename, .committed)
        let stale = try coordinator.newEnvelope(intent: "stale rename", reads: tokens,
            writes: [.init(entity: .task, id: taskID)])
        let outcome = await coordinator.execute(stale, stage: { context in
            try TaskStore.stageUpdate(in: context, taskID: self.taskID, title: warm.title + " stale", timestamp: Date())
        })
        XCTAssertEqual(outcome, .conflict)
        XCTAssertEqual(try coordinator.freshContext().fetch(FetchDescriptor<TaskItem>()).first?.title, "Fresh")
    }
    func testC2AsyncPreparationCannotCommitAcrossRenameAutosaveOrNewAssociation() async throws {
        let baseline = try coordinator.capture(baseOwners)
        let ready = expectation(description: "conversion prepared immutable values")
        var continuation: CheckedContinuation<Void, Never>?
        coordinator.afterPreparation = {
            if continuation == nil {
                await withCheckedContinuation { continuation = $0; ready.fulfill() }
            }
        }
        let conversion = Task { try await self.conversion() }
        await fulfillment(of: [ready], timeout: 10)
        coordinator.afterPreparation = nil
        let renameEnvelope = try coordinator.newEnvelope(intent: "racing workspace rename", reads: baseline, writes: [.init(entity: .task, id: taskID)])
        let rename = await coordinator.execute(renameEnvelope, stage: {
            try TaskStore.stageUpdate(in: $0, taskID: self.taskID, title: "Raced title", timestamp: Date())
        })
        XCTAssertEqual(rename, .committed)
        let autosave = coordinator.plainSave(tokens: baseline, writes: [.init(entity: .note, id: noteID)], stage: { _ in
            XCTFail("stale autosave must refuse before staging")
        })
        XCTAssertEqual(autosave, .conflict)
        let associationID = UUID()
        let association = try coordinator.newEnvelope(intent: "racing association", reads: baseline + coordinator.capture([.init(entity: .association, id: associationID)]),
            writes: [.init(entity: .association, id: associationID)])
        let associationOutcome = await coordinator.execute(association, stage: { _ in
            XCTFail("stale association must refuse before staging")
        })
        XCTAssertEqual(associationOutcome, .conflict)
        continuation?.resume()
        let conversionResult = try await conversion.value
        XCTAssertEqual(conversionResult.0, .conflict)
        let fresh = coordinator.freshContext()
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<TaskItem>()), 1)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<TaskNoteAssociation>()), 0)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<NoteItem>()).first?.content, try PreparedNoteDocument(original).content)
    }

    func testC2NewAssociationDuringPreparationStalesMembershipEvenWithoutEndpointChanges() async throws {
        let ready = expectation(description: "operation prepared")
        var continuation: CheckedContinuation<Void, Never>?
        coordinator.afterPreparation = {
            await withCheckedContinuation { continuation = $0; ready.fulfill() }
        }
        let operation = Task { try await self.conversion() }
        await fulfillment(of: [ready], timeout: 10)
        coordinator.afterPreparation = nil
        // Simulate an imported row whose endpoint generation has not changed.
        // Membership itself must still invalidate the prepared read set.
        let imported = coordinator.freshContext()
        imported.insert(TaskNoteAssociation(taskID: taskID, noteID: noteID))
        try imported.save()
        continuation?.resume()
        let outcome = try await operation.value
        XCTAssertEqual(outcome.0, .conflict)
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<TaskItem>()), 1)
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<TaskNoteAssociation>()), 1)
    }

    func testC3EachPublicationBoundaryRetainsCommitAndNeverReexecutesMutation() async throws {
        for refusedStep in 0..<5 {
            var effects = [Int](repeating: 0, count: 5)
            var refuse = true
            let owners: Set<WorkspaceOwner> = [.init(entity: .task, id: taskID)]
            let envelope = try coordinator.newEnvelope(intent: "publication boundary", reads: coordinator.capture(owners), writes: owners,
                historyEffect: Data("one history transition".utf8))
            let title = "Boundary \(refusedStep)"
            let publication = WorkspaceOperationCoordinator.Publication(steps: (0..<5).map { index in
                { _ in
                    if index == refusedStep && refuse { throw WorkspaceFoundationError.preparationFailed }
                    effects[index] += 1
                }
            })
            let outcome = await coordinator.execute(envelope, stage: {
                try TaskStore.stageUpdate(in: $0, taskID: self.taskID, title: title, timestamp: Date())
            }, publication: publication)
            XCTAssertEqual(outcome, .publicationPending)
            XCTAssertEqual(try coordinator.freshContext().fetch(FetchDescriptor<TaskItem>()).first?.title, title)
            refuse = false
            let retried = await coordinator.retryPublication(envelope.id)
            XCTAssertEqual(retried, .committed)
            XCTAssertEqual(effects, [1, 1, 1, 1, 1])
            let repeated = await coordinator.execute(envelope, stage: { _ in XCTFail("mutation replayed") })
            XCTAssertEqual(repeated, .conflict)
        }
    }

    func testC5ReceiptPruningIsBoundedOwnershipCheckedAndRejectsRetiredIntent() async throws {
        let owners: Set<WorkspaceOwner> = [.init(entity: .task, id: taskID)]
        var envelopes: [WorkspaceOperationEnvelope] = []
        for index in 0..<12 {
            let envelope = try coordinator.newEnvelope(intent: "retained model entry", reads: coordinator.capture(owners), writes: owners,
                historyEffect: Data("history \(index)".utf8))
            envelopes.append(envelope)
            let result = await coordinator.execute(envelope, stage: {
                try TaskStore.stageUpdate(in: $0, taskID: self.taskID, title: "Operation \(index)", timestamp: Date())
            })
            XCTAssertEqual(result, .committed)
        }
        let retained = envelopes[0].id
        coordinator = try WorkspaceOperationCoordinator(container: container,
            journal: NoteDraftJournal(directory: root.appendingPathComponent("NoteDrafts")))
        coordinator.historyReferences = { [retained] }
        try await coordinator.reconcileStartup()
        XCTAssertEqual(try coordinator.prunePublishedReceipts(limit: 4), 4)
        XCTAssertEqual(try coordinator.prunePublishedReceipts(limit: 4), 4)
        XCTAssertEqual(try coordinator.prunePublishedReceipts(limit: 4), 3)
        XCTAssertEqual(try coordinator.freshContext().fetch(FetchDescriptor<OperationReceipt>()).map(\.id), [retained])
        coordinator.historyReferences = { [] }
        XCTAssertEqual(try coordinator.prunePublishedReceipts(), 1)
        XCTAssertEqual(try coordinator.prunePublishedReceipts(), 0)
        let retry = await coordinator.execute(envelopes[0], stage: { _ in XCTFail("retired operation recreated") })
        XCTAssertEqual(retry, .conflict)
    }

    private func recoveryDraft(_ title: String) throws -> NoteDraftJournalEntry {
        var document = original!; document.blocks[0] = .text(title)
        return NoteDraftJournalEntry(noteID: noteID, isPersisted: true, baseRevisionID: nil,
            content: try PreparedNoteDocument(document).content, selectionLocation: 0, selectionLength: 0,
            staged: [], savedAt: Date())
    }
    func testC4ForeignCheckpointCoexistsWithoutRetiringOrOfferingCommittedOperationPreCopy() async throws {
        let foreign = try recoveryDraft("Foreign unsaved copy")
        let foreignClaim = try await coordinator.journal.writeDurably(foreign, staged: [])
        let (outcome, _) = try await conversion(preDraft: recoveryDraft("Local pre-operation draft"))
        XCTAssertEqual(outcome, .committed)
        coordinator = try WorkspaceOperationCoordinator(container: container,
            journal: NoteDraftJournal(directory: root.appendingPathComponent("NoteDrafts")))
        try await coordinator.reconcileStartup()
        let recovery = try await coordinator.journal.readRecoveryEntries()
        guard case let .valid(entry, _, claim) = recovery.first else { return XCTFail("foreign owner was lost") }
        XCTAssertEqual(entry.content, foreign.content); XCTAssertEqual(claim, foreignClaim)
        XCTAssertEqual(recovery.count, 1)
        XCTAssertTrue(coordinator.preOperationRecoveryCopies.isEmpty)
    }
    func testC4CorruptSavedPayloadCannotProveHandoffAndRetainsCheckpointAndOperationBytes() async throws {
        let pre = try recoveryDraft("Parent")
        let claim = try await coordinator.journal.writeDurably(pre, staged: [])
        var refuse = true
        let (outcome, id) = try await conversion(preDraft: pre, checkpointClaim: claim,
            publication: .init(steps: [{ _ in if refuse { throw WorkspaceFoundationError.unknown } }]))
        XCTAssertEqual(outcome, .publicationPending)
        let corrupt = coordinator.freshContext()
        let rows = try corrupt.fetch(FetchDescriptor<NoteAttachment>())
        rows.forEach { $0.payload = nil }
        try corrupt.save() // Deliberate fixture corruption, outside the operation under test.
        refuse = false
        let retried = await coordinator.retryPublication(id)
        XCTAssertEqual(retried, .publicationPending)
        let envelopes = try await coordinator.journal.operationEnvelopes()
        XCTAssertEqual(envelopes.map { $0.0.id }, [id])
        XCTAssertEqual(envelopes[0].0.payloads.first?.bytes, Data("original imported bytes".utf8))
        let inventory = try await coordinator.journal.inventoryCheckpoints()
        guard case let .valid(entry, _, retainedClaim) = inventory.first else { return XCTFail("lost checkpoint") }
        XCTAssertEqual(entry.content, pre.content); XCTAssertEqual(retainedClaim, claim)
        do { _ = try await coordinator.journal.readRecoveryEntries(); XCTFail("operation pre-copy offered as unsaved") }
        catch { }
    }
    func testC4DamagedForeignCheckpointSurvivesAndDoesNotBlockUnrelatedPlainSave() async throws {
        let damagedURL = coordinator.journal.directory.appendingPathComponent("\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at: coordinator.journal.directory, withIntermediateDirectories: true)
        let raw = Data("damaged raw recovery inventory".utf8)
        try raw.write(to: damagedURL)
        let unrelatedID = UUID()
        let fixture = coordinator.freshContext()
        fixture.insert(TaskItem(id: unrelatedID, title: "Unrelated")); try fixture.save()
        try await coordinator.reconcileStartup()
        XCTAssertFalse(coordinator.damagedCheckpointNotes.isEmpty)
        XCTAssertNil(coordinator.ownership.tryAcquire([UUID()], kind: .collection), "unbounded damaged bytes retain collection")
        let owners: Set<WorkspaceOwner> = [.init(entity: .task, id: unrelatedID)]
        let result = coordinator.plainSave(tokens: try coordinator.capture(owners), writes: owners, stage: {
            try TaskStore.stageUpdate(in: $0, taskID: unrelatedID, title: "Still editable", timestamp: Date())
        })
        XCTAssertEqual(result, .committed)
        XCTAssertEqual(try Data(contentsOf: damagedURL), raw)
        XCTAssertTrue(coordinator.startupReconciled)
    }

    func testC5MixedReplicaSaveOutcomeIsUnknownAndPreservesEachUntouchedMetadataValue() throws {
        let fixture = coordinator.freshContext()
        try fixture.fetch(FetchDescriptor<NoteItem>()).forEach { $0.taskID = nil }
        let first = try XCTUnwrap(fixture.fetch(FetchDescriptor<TaskItem>()).first)
        first.tagsRaw = "first"
        let second = TaskItem(id: taskID, title: first.title); second.tagsRaw = "second"
        fixture.insert(second); try fixture.save()
        let owners: Set<WorkspaceOwner> = [.init(entity: .task, id: taskID)]
        let expectedDate = Date(timeIntervalSince1970: 500)
        coordinator.save = { _ in
            let partial = self.coordinator.freshContext()
            let row = try partial.fetch(FetchDescriptor<TaskItem>()).first!
            row.title = "After"; row.updatedAt = expectedDate
            try partial.save(); throw WorkspaceFoundationError.unknown
        }
        let result = coordinator.plainSave(tokens: try coordinator.capture(owners), writes: owners, stage: { context in
            for row in try context.fetch(FetchDescriptor<TaskItem>()) { row.title = "After"; row.updatedAt = expectedDate }
        })
        XCTAssertEqual(result, .unknown)
        coordinator.beforeReconciliationRead = { throw WorkspaceFoundationError.unknown }
        XCTAssertEqual(coordinator.reconcilePlain(), .unknown)
        let resolved = coordinator.freshContext()
        for row in try resolved.fetch(FetchDescriptor<TaskItem>()) { row.title = "After"; row.updatedAt = expectedDate }
        try resolved.save()
        coordinator.beforeReconciliationRead = nil
        XCTAssertEqual(coordinator.reconcilePlain(), .committed)
        XCTAssertEqual(Set(try coordinator.freshContext().fetch(FetchDescriptor<TaskItem>()).map(\.tagsRaw)), ["first", "second"])
    }
    func testC5OrdinaryTextAutosaveIncludesItsDisplacedVersionWithoutJournalOrReceipt() throws {
        let versionID = UUID()
        let owners: Set<WorkspaceOwner> = [.init(entity: .note, id: noteID), .init(entity: .version, id: versionID)]
        let context = coordinator.freshContext()
        let note = try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>()).first)
        let physicalID = note.persistentModelID
        var candidate = original!; candidate.blocks[2] = .text("New ordinary typing")
        let prepared = try PreparedNoteDocument(candidate)
        coordinator.save = { commit in try commit.save(); throw WorkspaceFoundationError.unknown }
        let result = coordinator.plainSave(tokens: try coordinator.capture(owners), writes: owners, stage: { commit in
            try NoteStore.stageDocument(in: commit, noteID: self.noteID, document: candidate, prepared: prepared,
                revisionID: UUID(), versionIDs: [physicalID: versionID], staged: [], timestamp: Date())
        })
        XCTAssertEqual(result, .committed)
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<NoteVersion>()), 1)
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<OperationReceipt>()), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.journal.directory.path))
    }
    func testC3PublicationFailureKeepsOneCommittedResultAndRetriesOnlyRemainingPublication() async throws {
        var effects = [0, 0, 0, 0, 0]
        var refuse = true
        let publication = WorkspaceOperationCoordinator.Publication(steps: (0..<5).map { index in
            { _ in
                if index == 2 && refuse { throw WorkspaceFoundationError.preparationFailed }
                effects[index] += 1
            }
        })
        let (outcome, id) = try await conversion(publication: publication)
        XCTAssertEqual(outcome, .publicationPending)
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<TaskItem>()), 2)
        XCTAssertEqual(effects, [1, 1, 0, 0, 0])
        refuse = false
        let retried = await coordinator.retryPublication(id)
        XCTAssertEqual(retried, .committed); XCTAssertEqual(effects, [1, 1, 1, 1, 1])
        let refused = await coordinator.retryPublication(id)
        XCTAssertEqual(refused, .conflict)
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<TaskItem>()), 2)
    }
    func testC5PlainSaveReconcilesBeforeAfterAndUnreadableOutcomesWithoutReceipts() throws {
        // The plain task class is deliberately outside a task-note workspace.
        let fixture = coordinator.freshContext()
        try fixture.fetch(FetchDescriptor<NoteItem>()).forEach { $0.taskID = nil }
        try fixture.save()
        let owners: Set<WorkspaceOwner> = [.init(entity: .task, id: taskID)]
        coordinator.save = { _ in throw WorkspaceFoundationError.preparationFailed }
        var tokens = try coordinator.capture(owners)
        XCTAssertEqual(coordinator.plainSave(tokens: tokens, writes: owners, stage: { context in
            try TaskStore.stageUpdate(in: context, taskID: self.taskID, title: "Before", timestamp: Date())
        }), .notCommitted)
        coordinator.save = { context in try context.save(); throw WorkspaceFoundationError.unknown }
        XCTAssertEqual(coordinator.plainSave(tokens: tokens, writes: owners, stage: { context in
            try TaskStore.stageUpdate(in: context, taskID: self.taskID, title: "After", timestamp: Date())
        }), .committed)
        tokens = try coordinator.capture(owners)
        coordinator.beforeReconciliationRead = { throw WorkspaceFoundationError.unknown }
        XCTAssertEqual(coordinator.plainSave(tokens: tokens, writes: owners, stage: { context in
            try TaskStore.stageUpdate(in: context, taskID: self.taskID, title: "Unknown", timestamp: Date())
        }), .unknown)
        coordinator.beforeReconciliationRead = nil
        XCTAssertEqual(coordinator.reconcilePlain(), .committed)
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<OperationReceipt>()), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("NoteDrafts/operations").path))
    }
    private func commitLedgerEdit(_ context: ModelContext, before: [WorkspaceModelToken],
                                  scopes: [WorkspaceScopeToken], through gate: WorkspaceOperationCoordinator? = nil) throws -> WorkspaceOperationCoordinator.Outcome {
        let gate = gate ?? coordinator!
        let owners = Set(before.map(\.owner))
        let after = try WorkspaceModelToken.capture(owners: owners,
            models: WorkspaceModelToken.stagedModels(owners: owners,
                before: Dictionary(uniqueKeysWithValues: before.map { ($0.owner, $0) }), in: context))
        return gate.commitInPlace(context, before: before, requiredScopes: Set(scopes.map(\.scope)),
            scopes: { scopes }, after: Array(after.values), capturedOwners: owners,
            using: { try $0.save() }, confirmed: { _ in })
    }

    func testL1OtherGatedWriterInvalidatesTheOwnerAndRefusesStaleValues() throws {
        let owner = WorkspaceOwner(entity: .task, id: taskID), a = coordinator.freshContext()
        let before = try WorkspaceModelToken.read(owner, in: a)
        let id = taskID!
        XCTAssertEqual(coordinator.plainSave(tokens: [before], writes: [owner]) { b in
            try b.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first!.title = "B"
        }, .committed)
        try a.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first!.title = "A"
        coordinator.validationCounters = .init()
        XCTAssertEqual(try commitLedgerEdit(a, before: [before], scopes: []), .conflict)
        XCTAssertEqual(coordinator.validationCounters.slowValidations, 1)
        XCTAssertEqual(coordinator.validationCounters.freshContexts, 1)
        a.rollback()
        XCTAssertEqual(try coordinator.freshContext().fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first?.title, "B")
    }

    func testL1ColdPresentationStillRefusesAChangedOwnerFromAnotherGatedContext() throws {
        let tasks = TaskStore(container: container)
        let presented = try XCTUnwrap(tasks.task(withID: taskID))
        let owner = WorkspaceOwner(entity: .task, id: taskID), id = taskID!
        XCTAssertEqual(coordinator.plainSave(tokens: try coordinator.capture([owner]), writes: [owner]) { b in
            try b.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first!.title = "B"
        }, .committed)
        coordinator.validationCounters = .init()
        XCTAssertFalse(tasks.update(presented, title: "Stale A"))
        XCTAssertEqual(coordinator.validationCounters.slowValidations, 1)
        XCTAssertEqual(coordinator.validationCounters.freshContexts, 1)
        XCTAssertEqual(tasks.task(withID: id)?.title, "B")
    }

    func testL2GatedSiblingInsertInvalidatesChildrenScope() throws {
        let owner = WorkspaceOwner(entity: .task, id: taskID), a = coordinator.freshContext()
        let before = try WorkspaceModelToken.read(owner, in: a)
        let scope = try WorkspaceScopeToken.read(.children(taskID), in: a)
        let sibling = WorkspaceOwner(entity: .task, id: UUID())
        XCTAssertEqual(coordinator.plainSave(tokens: [.init(owner: sibling, replicas: [])], writes: [sibling]) { b in
            b.insert(TaskItem(id: sibling.id, title: "Sibling", parentID: self.taskID))
        }, .committed)
        (a.model(for: before.replicas[0].physicalID) as! TaskItem).title = "A"
        coordinator.validationCounters = .init()
        XCTAssertEqual(try commitLedgerEdit(a, before: [before], scopes: [scope]), .conflict)
        XCTAssertEqual(coordinator.validationCounters.slowValidations, 1)
        XCTAssertEqual(coordinator.validationCounters.freshContexts, 1)
        a.rollback()
    }

    func testL3ForeignCanvasSaveLeavesTasksAndNotesFast() throws {
        let seed = coordinator.freshContext(), ordinary = NoteItem(title: "Independent note")
        seed.insert(ordinary); try seed.save()
        let tasks = TaskStore(container: container), notes = NoteStore(container: container,
            attachmentFileStore: AttachmentFileStore(rootURL: root.appendingPathComponent("Files")))
        let foreign = ModelContext(container)
        foreign.insert(CanvasBoardItem(name: "Unrelated")); try foreign.save()
        coordinator.validationCounters = .init()
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: taskID)), title: "Task fast"))
        XCTAssertTrue(notes.setPinned(true, noteID: ordinary.id))
        XCTAssertEqual(coordinator.validationCounters.fastValidations, 2)
        XCTAssertEqual(coordinator.validationCounters.slowValidations, 0)
        XCTAssertEqual(coordinator.validationCounters.freshContexts, 0)
    }

    func testL4LedgerEvictionForcesExactValidationBelowTheFloor() throws {
        let a = coordinator.freshContext(), owner = WorkspaceOwner(entity: .task, id: taskID)
        let before = try WorkspaceModelToken.read(owner, in: a)
        coordinator.ledger.capacity = 1
        let inserted = Set((0..<3).map { _ in WorkspaceOwner(entity: .task, id: UUID()) })
        XCTAssertEqual(coordinator.plainSave(tokens: inserted.map { .init(owner: $0, replicas: []) }, writes: inserted) { b in
            for owner in inserted { b.insert(TaskItem(id: owner.id, title: "Eviction")) }
        }, .committed)
        XCTAssertFalse(coordinator.ledger.canValidate(a, owners: [owner], scopes: []))
        (a.model(for: before.replicas[0].physicalID) as! TaskItem).title = "Exact unchanged owner"
        coordinator.validationCounters = .init()
        XCTAssertEqual(try commitLedgerEdit(a, before: [before], scopes: []), .committed)
        XCTAssertEqual(coordinator.validationCounters.slowValidations, 1)
        XCTAssertEqual(coordinator.validationCounters.freshContexts, 1)
    }

    func testL4LaunchMigrationFloorRetainsExactGuardsForOlderContexts() throws {
        let a = coordinator.freshContext(), owner = WorkspaceOwner(entity: .task, id: taskID)
        let before = try WorkspaceModelToken.read(owner, in: a)
        let tasks = TaskStore(container: container)
        XCTAssertFalse(coordinator.ledger.canValidate(a, owners: [owner], scopes: []))
        XCTAssertTrue(coordinator.ledger.owners.isEmpty, "launch recording retains the floor instead of a whole-table map")
        (a.model(for: before.replicas[0].physicalID) as! TaskItem).title = "Stale before migration"
        coordinator.validationCounters = .init()
        XCTAssertEqual(try commitLedgerEdit(a, before: [before], scopes: []), .conflict)
        XCTAssertEqual(coordinator.validationCounters.slowValidations, 1)
        a.rollback()
        coordinator.validationCounters = .init()
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: taskID)), title: "Current presentation"))
        XCTAssertEqual(coordinator.validationCounters.fastValidations, 1)
        XCTAssertEqual(coordinator.validationCounters.slowValidations, 0)
        XCTAssertEqual(coordinator.validationCounters.freshContexts, 0)
    }

    func testL5RecreatedCoordinatorCannotReuseAContextsLedgerProof() throws {
        let a = coordinator.freshContext(), owner = WorkspaceOwner(entity: .task, id: taskID)
        let before = try WorkspaceModelToken.read(owner, in: a)
        let originalIdentity = coordinator.ledger.identity
        let replacement = try WorkspaceOperationCoordinator(container: container, journal: coordinator.journal)
        replacement.ledger.register(a)
        XCTAssertNotEqual(replacement.ledger.identity, originalIdentity)
        XCTAssertEqual(replacement.ledger.stamp(a)?.ledgerID, originalIdentity)
        (a.model(for: before.replicas[0].physicalID) as! TaskItem).title = "Recreated"
        replacement.validationCounters = .init()
        XCTAssertEqual(try commitLedgerEdit(a, before: [before], scopes: [], through: replacement), .committed)
        XCTAssertEqual(replacement.validationCounters.slowValidations, 1)
        XCTAssertEqual(replacement.validationCounters.freshContexts, 1)
    }

    func testL6PurgeUpdatesCachedTombstonesAndForeignPreservationInvalidatesThem() async throws {
        let owner = WorkspaceOwner(entity: .task, id: taskID)
        XCTAssertEqual(coordinator.plainSave(tokens: try coordinator.capture([owner]), writes: [owner]) { _ in }, .committed)
        XCTAssertEqual(coordinator.tombstoneLoads, 1)
        let context = coordinator.freshContext(), id = taskID!
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first)
        row.deletedAt = Date(timeIntervalSince1970: 100); row.deletionRootID = id; row.deletionMembersRaw = id.uuidString
        try context.save()
        // Reload the cache after this foreign fixture write.
        XCTAssertEqual(coordinator.plainSave(tokens: try coordinator.capture([owner]), writes: [owner]) { _ in }, .committed)
        let loads = coordinator.tombstoneLoads
        let result = await WorkspacePurge.purge(rootID: id, before: .distantFuture, coordinator: coordinator,
            files: TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles")), inventory: { .init(generation: 0) })
        XCTAssertEqual(result.outcome, .committed)
        XCTAssertEqual(coordinator.tombstoneLoads, loads)
        XCTAssertEqual(coordinator.plainSave(tokens: [.init(owner: owner, replicas: [])], writes: [owner]) {
            $0.insert(TaskItem(id: id, title: "Cannot resurrect"))
        }, .notCommitted)
        XCTAssertEqual(coordinator.tombstoneLoads, loads, "gated purge updates the resident set")
        let otherID = UUID(), other = WorkspaceOwner(entity: .task, id: otherID)
        let snapshot = WorkspacePurge.Preservation(rootID: otherID, title: "Foreign tombstone",
            members: [.init(id: otherID, fields: ["title": try JSONEncoder().encode("Foreign tombstone")])], originals: [])
        let foreign = ModelContext(container)
        let record = TaskDeletionPreservation(rootID: otherID, deletedAt: .distantPast, capturedAt: Date(),
            provenance: "fixture", snapshot: try JSONEncoder().encode(snapshot))
        record.purgedAt = Date(); foreign.insert(record); try foreign.save()
        XCTAssertEqual(coordinator.plainSave(tokens: [.init(owner: other, replicas: [])], writes: [other]) {
            $0.insert(TaskItem(id: otherID, title: "Also cannot resurrect"))
        }, .notCommitted)
        XCTAssertEqual(coordinator.tombstoneLoads, loads + 1)
    }

    func testR2FollowupPendingPublicationOffersOnlyForeignClaimAndClearsSuppressionOnRelease() async throws {
        let pre = try recoveryDraft("operation pre-copy")
        let claim = try await coordinator.journal.writeDurably(pre, staged: [])
        let (outcome, id) = try await conversion(preDraft: pre, checkpointClaim: claim,
            publication: .init(steps: [{ _ in throw WorkspaceFoundationError.unknown }]))
        XCTAssertEqual(outcome, .publicationPending)
        try await coordinator.finishLaunch()
        let initial = try await coordinator.journal.readRecoveryEntries()
        XCTAssertTrue(initial.isEmpty, "exact pending operation checkpoint is suppressed")
        let checkpointURL = coordinator.journal.directory.appendingPathComponent(pre.noteID.uuidString + ".json")
        let exactCheckpointBytes = try Data(contentsOf: checkpointURL)
        var foreign = pre
        foreign.content = try PreparedNoteDocument(NoteDocument(blocks: [.text("foreign unsaved copy")])).content
        _ = try await coordinator.journal.writeDurably(foreign, staged: [], replacing: claim)
        let offered = try await coordinator.journal.readRecoveryEntries()
        XCTAssertEqual(offered.compactMap { if case let .valid(entry, _, _) = $0 { return entry.content }; return nil }, [foreign.content])
        // Recreate the exact claim, then simulate proven receipt absence.
        // Releasing pending ownership must offer this copy in this session.
        try exactCheckpointBytes.write(to: checkpointURL, options: .atomic)
        let suppressedAgain = try await coordinator.journal.readRecoveryEntries()
        XCTAssertTrue(suppressedAgain.isEmpty)
        let context = coordinator.freshContext()
        try context.fetch(FetchDescriptor<OperationReceipt>()).forEach(context.delete)
        try context.save() // Isolated fixture models proven absence, never production cleanup.
        let resolved = await coordinator.retryPublication(id)
        XCTAssertEqual(resolved, .notCommitted)
        let afterRelease = try await coordinator.journal.readRecoveryEntries()
        XCTAssertEqual(afterRelease.count, 1, "release must refresh the suppression set in this session")
    }

    func testR2FollowupEveryRuntimeLaunchCompletesWithoutOpeningNotes() async throws {
        for environment in [["ATTIC_UI_TESTING": "1"], ["ATTIC_TESTING": "1"],
                            ["ATTIC_UI_TESTING": "1", "ATTIC_PERF_SEED_ONLY": "1"]] {
            let isolated = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
            let gate = try WorkspaceLegacyBridge.coordinator(for: isolated)
            gate.beginLaunchRegistration()
            let runtime = AppRuntimeEnvironment(environment: environment, applicationSupportURL: root)
            let stores = runtime.makeItemStores(container: isolated, performanceRoot: root.appendingPathComponent(UUID().uuidString))
            // No AppCoordinator/window/Notes page is created. Store construction
            // is the common production path, even if start() returns early.
            for _ in 0..<200 where !gate.startupReconciled {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(gate.startupReconciled, "launch path \(environment)")
            let lease = gate.ownership.tryAcquire([UUID()], kind: .collection)
            XCTAssertNotNil(lease, "launch hold must finish without a Notes visit")
            lease?.release()
            await stores.notes.waitForAttachmentReconciliation()
        }
    }

    func testR2FollowupPersistentCompatibilityFailureAllowsDisjointFastSaveAndRollsBackRefusedEdit() throws {
        let tasks = TaskStore(container: container)
        let disjoint = try XCTUnwrap(tasks.create(title: "disjoint"))
        try coordinator.commitCompatibility(tokens: coordinator.capture(baseOwners), scopes: [], writes: baseOwners,
            intent: "persistently held compatibility", plain: false, writer: { context in
                if context.changedModelsArray.compactMap({ $0 as? OperationReceipt }).contains(where: \.envelopeReleased) {
                    throw WorkspaceFoundationError.unknown
                }
                try context.save()
            }, stage: { context in
                try TaskStore.stageUpdate(in: context, taskID: self.taskID, title: "committed once", timestamp: Date())
                try context.fetch(FetchDescriptor<NoteItem>()).forEach { $0.tagsRaw = "compatibility" }
            })
        // Persistent bookkeeping failure, not an unreadable disjoint task.
        coordinator.save = { _ in throw WorkspaceFoundationError.unknown }
        tasks.refresh()
        coordinator.validationCounters = .init()
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: disjoint.id)), title: "saved independently"))
        XCTAssertEqual(coordinator.validationCounters.fastValidations, 1)
        XCTAssertEqual(coordinator.validationCounters.slowValidations, 0)
        let held = try XCTUnwrap(tasks.task(withID: taskID))
        XCTAssertFalse(tasks.update(held, title: "never attempted"))
        XCTAssertEqual(tasks.task(withID: taskID)?.title, "committed once")
        XCTAssertFalse(try XCTUnwrap(tasks.task(withID: taskID)?.modelContext).hasChanges)
        let fresh = coordinator.freshContext()
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<TaskItem>()).first { $0.id == disjoint.id }?.title, "saved independently")
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<TaskItem>()).first { $0.id == taskID }?.title, "committed once")
    }

    func testR2TasksOnlyLaunchRegistersThenPrunesInBatchesBeforeCheckpointOffers() async throws {
        let context = coordinator.freshContext()
        for _ in 0..<130 {
            let receipt = OperationReceipt(id: UUID(), envelopeDigest: "released", affectedIDs: Data(), resultingTokens: Data())
            receipt.publicationComplete = true; receipt.handoffProof = Data(); receipt.envelopeReleased = true
            context.insert(receipt)
        }
        try context.save()
        coordinator.beginLaunchRegistration()
        XCTAssertNil(coordinator.ownership.tryAcquire([UUID()], kind: .collection))
        let tasks = TaskStore(container: container), library = AtticLibrary(tasks: tasks)
        XCTAssertNotNil(tasks.task(withID: taskID), "presentation exists before maintenance")
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<OperationReceipt>()), 130)
        async let first: Void = coordinator.finishLaunch()
        async let second: Void = coordinator.finishLaunch()
        try await first; try await second
        XCTAssertEqual(coordinator.launchPruneBatches, [64, 64, 2])
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<OperationReceipt>()), 0)
        let lease = try XCTUnwrap(coordinator.ownership.tryAcquire([UUID()], kind: .collection)); lease.release()
        XCTAssertNotNil(library.tasks.task(withID: taskID))
        try await coordinator.finishLaunch()
        XCTAssertEqual(coordinator.launchPruneBatches, [64, 64, 2])
    }

    func testR2DamagedCheckpointHoldsOnlyItsPublicationAndIndependentOffersContinue() async throws {
        let pre = try recoveryDraft("pre-copy")
        let claim = try await coordinator.journal.writeDurably(pre, staged: [])
        let (outcome, operation) = try await conversion(preDraft: pre, checkpointClaim: claim,
            publication: .init(steps: [{ _ in throw WorkspaceFoundationError.unknown }]))
        XCTAssertEqual(outcome, .publicationPending)
        let damaged = coordinator.journal.directory.appendingPathComponent("\(noteID!.uuidString).json")
        let raw = Data("broken checkpoint".utf8); try raw.write(to: damaged)
        let independentID = UUID(), content = try PreparedNoteDocument(NoteDocument(blocks: [.text("independent")])).content
        let independent = NoteDraftJournalEntry(noteID: independentID, isPersisted: false, baseRevisionID: nil,
            content: content, selectionLocation: 0, selectionLength: 0, staged: [], savedAt: Date())
        _ = try await coordinator.journal.writeDurably(independent, staged: [])
        coordinator = try WorkspaceOperationCoordinator(container: container, journal: coordinator.journal)
        try await coordinator.finishLaunch()
        XCTAssertEqual(coordinator.damagedCheckpointNotes, [noteID])
        let entries = try await coordinator.journal.readRecoveryEntries()
        XCTAssertEqual(entries.compactMap { if case let .valid(entry, _, _) = $0 { return entry.noteID }; return nil }, [independentID])
        XCTAssertEqual(try Data(contentsOf: damaged), raw)
        XCTAssertEqual(try coordinator.journal.operationEnvelopesSynchronously().map { $0.0.id }, [operation])
        XCTAssertNil(coordinator.ownership.tryAcquire([UUID()], kind: .collection))
        let owner = WorkspaceOwner(entity: .task, id: taskID)
        // The affected task remains held; a disjoint note is still writable.
        let other = WorkspaceOwner(entity: .task, id: independentID)
        XCTAssertEqual(coordinator.plainSave(tokens: [.init(owner: other, replicas: [])], writes: [other]) {
            $0.insert(TaskItem(id: independentID, title: "editable"))
        }, .committed)
        XCTAssertEqual(coordinator.plainSave(tokens: try coordinator.capture([owner]), writes: [owner]) { _ in }, .unknown)
    }

    func testR2PendingCheckpointOffersCannotReleaseItsRawRowAndByteOwners() async throws {
        let byteID = UUID()
        var document = original!
        document.blocks.append(.file(attachmentID: byteID, filename: "existing.txt",
            contentTypeIdentifier: "public.plain-text", byteCount: 1))
        var pre = try recoveryDraft("pending pre-copy")
        pre.content = try PreparedNoteDocument(document).content
        let claim = try await coordinator.journal.writeDurably(pre, staged: [])
        let (outcome, _) = try await conversion(preDraft: pre, checkpointClaim: claim,
            publication: .init(steps: [{ _ in throw WorkspaceFoundationError.unknown }]))
        XCTAssertEqual(outcome, .publicationPending)
        try await coordinator.finishLaunch()
        XCTAssertTrue(coordinator.retainedRecoveryBytes.contains(byteID))
        let offered = try await coordinator.journal.readRecoveryEntries()
        XCTAssertTrue(offered.isEmpty, "pending checkpoint must not be offered as unsaved work")
        XCTAssertTrue(coordinator.retainedRecoveryBytes.contains(byteID), "filtered offers are not a complete ownership inventory")
        XCTAssertNil(coordinator.ownership.tryAcquire([byteID], kind: .collection))
        XCTAssertNil(coordinator.ownership.tryAcquire([noteID], kind: .collection))
        let unrelated = try XCTUnwrap(coordinator.ownership.tryAcquire([UUID()], kind: .collection))
        unrelated.release()
    }

    func testR2ProductionPlainUnknownRetriesOnDemandAndReturnsToFastValidation() throws {
        var fail = true
        let tasks = TaskStore(container: container, persist: { context in
            try context.save()
            if fail { throw WorkspaceFoundationError.unknown }
        })
        coordinator.beforeReconciliationRead = { throw WorkspaceFoundationError.unknown }
        XCTAssertFalse(tasks.update(try XCTUnwrap(tasks.task(withID: taskID)), title: "saved but unknown"))
        fail = false; coordinator.beforeReconciliationRead = nil
        coordinator.validationCounters = .init()
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: taskID)), title: "resolved retry"))
        XCTAssertLessThanOrEqual(coordinator.validationCounters.slowValidations, 1)
        coordinator.validationCounters = .init()
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: taskID)), title: "steady again"))
        XCTAssertEqual(coordinator.validationCounters, .init(fastValidations: 1, slowValidations: 0, freshContexts: 0))
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<OperationReceipt>()), 0)
    }

    func testR2CompatibilityRetriesReleasedEnvelopeBookkeepingWithoutReexecutingMutation() throws {
        var domainSaves = 0
        let reads = try coordinator.capture(baseOwners)
        try coordinator.commitCompatibility(tokens: reads, scopes: [], writes: baseOwners, intent: "mixed compatibility", plain: false,
            writer: { context in
                let receipts = (context.insertedModelsArray + context.changedModelsArray).compactMap { $0 as? OperationReceipt }
                if receipts.contains(where: \.envelopeReleased) { throw WorkspaceFoundationError.unknown }
                if context.changedModelsArray.contains(where: { $0 is TaskItem }) { domainSaves += 1 }
                try context.save()
            }, stage: { context in
                try TaskStore.stageUpdate(in: context, taskID: self.taskID, title: "committed once", timestamp: Date())
                try context.fetch(FetchDescriptor<NoteItem>()).forEach { $0.tagsRaw = "compatibility" }
            })
        XCTAssertEqual(domainSaves, 1)
        XCTAssertTrue(try coordinator.journal.operationEnvelopesSynchronously().isEmpty, "release preceded failed receipt save")
        XCTAssertTrue(coordinator.retryHeldWrites())
        let receipt = try XCTUnwrap(coordinator.freshContext().fetch(FetchDescriptor<OperationReceipt>()).first)
        XCTAssertTrue(receipt.envelopeReleased); XCTAssertTrue(receipt.publicationComplete)
        XCTAssertTrue(coordinator.retryHeldWrites()); XCTAssertEqual(domainSaves, 1)
        let tasks = TaskStore(container: container)
        coordinator.validationCounters = .init()
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: taskID)), title: "ordinary next command"))
        XCTAssertEqual(coordinator.validationCounters, .init(fastValidations: 1, slowValidations: 0, freshContexts: 0))
    }

    func testR2PreservationSnapshotAndPurgedTombstoneCannotBeDeletedRewrittenOrCleared() async throws {
        let context = coordinator.freshContext(), rootID = taskID!
        let task = try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>()).first)
        task.deletedAt = .distantPast; task.deletionRootID = rootID; task.deletionMembersRaw = rootID.uuidString
        try context.save()
        let result = await WorkspacePurge.purge(rootID: rootID, before: .distantFuture, coordinator: coordinator,
            files: TaskImageFiles(rootURL: root.appendingPathComponent("LifetimeFiles")), inventory: { .init(generation: 0) })
        XCTAssertEqual(result.outcome, .committed)
        let record = try XCTUnwrap(coordinator.freshContext().fetch(FetchDescriptor<TaskDeletionPreservation>()).first)
        let owner = WorkspaceOwner(entity: .preservation, id: record.id), original = try coordinator.capture([owner])
        for edit in 0..<3 {
            XCTAssertEqual(coordinator.plainSave(tokens: original, writes: [owner]) { commit in
                let row = try XCTUnwrap(commit.fetch(FetchDescriptor<TaskDeletionPreservation>()).first)
                switch edit { case 0: commit.delete(row); case 1: row.snapshot = Data(); default: row.purgedAt = nil }
            }, .notCommitted)
            XCTAssertEqual(try coordinator.capture([owner]), original)
        }
    }

    func testR2FailedPurgeCannotPublishTentativeTombstonesIntoTheCache() async throws {
        let context = coordinator.freshContext(), id = taskID!
        let task = try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>()).first)
        task.deletedAt = .distantPast; task.deletionRootID = id; task.deletionMembersRaw = id.uuidString
        try context.save()
        coordinator.save = { _ in throw WorkspaceFoundationError.unknown }
        let result = await WorkspacePurge.purge(rootID: id, before: .distantFuture, coordinator: coordinator,
            files: TaskImageFiles(rootURL: root.appendingPathComponent("FailedTombstoneFiles")), inventory: { .init(generation: 0) })
        XCTAssertEqual(result.outcome, .notCommitted)
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<TaskDeletionPreservation>()), 0)
        coordinator.save = { try $0.save() }
        let owner = WorkspaceOwner(entity: .task, id: id)
        XCTAssertEqual(coordinator.plainSave(tokens: try coordinator.capture([owner]), writes: [owner]) {
            let row = try XCTUnwrap($0.fetch(FetchDescriptor<TaskItem>()).first)
            row.title = "retained after refusal"
        }, .committed)
    }

    func testR2ForeignPreservationRemovalCannotForgetACachedRetiredUUID() async throws {
        let context = coordinator.freshContext(), id = taskID!
        let task = try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>()).first)
        task.deletedAt = .distantPast; task.deletionRootID = id; task.deletionMembersRaw = id.uuidString
        try context.save()
        let result = await WorkspacePurge.purge(rootID: id, before: .distantFuture, coordinator: coordinator,
            files: TaskImageFiles(rootURL: root.appendingPathComponent("ForeignTombstoneFiles")), inventory: { .init(generation: 0) })
        XCTAssertEqual(result.outcome, .committed)
        let foreign = ModelContext(container)
        for row in try foreign.fetch(FetchDescriptor<TaskDeletionPreservation>()) { foreign.delete(row) }
        try foreign.save()
        let owner = WorkspaceOwner(entity: .task, id: id), loads = coordinator.tombstoneLoads
        XCTAssertEqual(coordinator.plainSave(tokens: [.init(owner: owner, replicas: [])], writes: [owner]) {
            $0.insert(TaskItem(id: id, title: "retired UUID"))
        }, .notCommitted)
        XCTAssertEqual(coordinator.tombstoneLoads, loads + 1)
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<TaskItem>()), 0)
    }

    func testR2CapacityPlusOneDistinctGatedWritesKeepPresentationToggleLinkAndAutosaveFast() async throws {
        let tasks = TaskStore(container: container), notes = NoteStore(container: container,
            attachmentFileStore: AttachmentFileStore(rootURL: root.appendingPathComponent("EvictionFiles")))
        let library = AtticLibrary(tasks: tasks, notes: notes)
        let headID = try XCTUnwrap(tasks.create(title: "Eviction head")).id
        let ordinary = UUID(), document = NoteDocument(blocks: [.text("ordinary")])
        _ = try notes.createDocumentNote(id: ordinary, document: document, staged: []).get()
        await notes.waitForAttachmentReconciliation()
        _ = try notes.noteMutationPreflight(ordinary, format: .document)
        let link = try XCTUnwrap(library.links.link(.init(.task, headID), to: .init(.note, ordinary), kind: .reference))
        var linkIsLive = true
        // A journaled writer advances the entity independently; normal refresh
        // must re-register presentation before the capacity+1 plain writes.
        let taskOwner = WorkspaceOwner(entity: .task, id: headID)
        let envelope = try coordinator.newEnvelope(intent: "foreign journaled task write",
            reads: coordinator.capture([taskOwner]), writes: [taskOwner])
        let journaled = await coordinator.execute(envelope, stage: {
            try TaskStore.stageUpdate(in: $0, taskID: headID, title: "journaled then refreshed", timestamp: Date())
        })
        XCTAssertEqual(journaled, .committed)
        tasks.refresh()
        // Touch distinct rows through the same registered presentation context.
        // A small capacity deterministically exercises several eviction batches;
        // repeat at the shipping capacity to catch hidden size-dependent work.
        for capacity in [32, 8_192] {
            coordinator.ledger.capacity = capacity
            let source = try XCTUnwrap(tasks.task(withID: headID)?.modelContext)
            var first: [Double] = [], last: [Double] = []
            let clock = ContinuousClock()
            coordinator.validationCounters = .init()
            for i in 0...capacity {
                let row = TaskItem(title: "distinct \(capacity)-\(i)")
                source.insert(row)
                let owner = WorkspaceOwner(entity: .task, id: row.id), before = WorkspaceModelToken(owner: owner, replicas: [])
                let start = clock.now
                XCTAssertEqual(try commitLedgerEdit(source, before: [before], scopes: []), .committed)
                let elapsed = start.duration(to: clock.now)
                let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
                if i < 24 { first.append(ms) }
                if i > capacity - 24 { last.append(ms) }
            }
            XCTAssertEqual(coordinator.validationCounters, .init(fastValidations: capacity + 1, slowValidations: 0, freshContexts: 0))
            print("R2_EVICTION capacity=\(capacity) first_median_ms=\(first.sorted()[first.count/2]) last_median_ms=\(last.sorted()[last.count/2]) trim_passes=\(coordinator.ledger.trimPasses)")
            // Per-save proofs stay constant: zero exact reads/fresh contexts.
            // Hosted timing remains subject to the unchanged paired PF gate.
            for i in 0..<3 {
                coordinator.validationCounters = .init()
                XCTAssertEqual(library.updateTask(headID, status: tasks.task(withID: headID)?.status == .done ? .todo : .done), .applied)
                XCTAssertEqual(coordinator.validationCounters, .init(fastValidations: 1, slowValidations: 0, freshContexts: 0))
                coordinator.validationCounters = .init()
                XCTAssertTrue(linkIsLive ? library.links.unlink(link.id) : library.links.restoreLink(link.id))
                XCTAssertEqual(coordinator.validationCounters, .init(fastValidations: 1, slowValidations: 0, freshContexts: 0))
                linkIsLive.toggle()
                var next = document; next.blocks[0] = .text("ordinary \(capacity)-\(i)")
                let prepared = try PreparedNoteDocument(next), revision = try XCTUnwrap(notes.loadDocument(noteID: ordinary)?.revisionID)
                coordinator.validationCounters = .init()
                _ = try notes.saveDocument(noteID: ordinary, document: next, baseRevisionID: revision, staged: [], prepared: prepared).get()
                XCTAssertEqual(coordinator.validationCounters, .init(fastValidations: 1, slowValidations: 0, freshContexts: 0))
            }
        }
    }

    func testR2FailedCompatibilityDraftReleasesOnlyAfterExactClaimedCheckpointHandoff() async throws {
        let id = UUID(), owner = WorkspaceOwner(entity: .note, id: id)
        let prepared = try PreparedNoteDocument(NoteDocument(blocks: [.text("Only pre-copy")]))
        let pre = NoteDraftJournalEntry(noteID: id, isPersisted: false, baseRevisionID: nil,
            content: prepared.content, selectionLocation: 0, selectionLength: 0, staged: [], savedAt: Date())
        XCTAssertThrowsError(try coordinator.commitCompatibility(tokens: [.init(owner: owner, replicas: [])], scopes: [],
            writes: [owner], intent: "Failed first creation", plain: false, writer: { _ in throw WorkspaceFoundationError.unknown },
            afterDocuments: [id: prepared.content], preDraft: pre, stage: { context in
                let note = NoteItem(id: id)
                NoteStore.stageDocumentContent(prepared, format: 1, on: [note], timestamp: Date(), revision: 0, revisionID: UUID())
                context.insert(note)
            }))
        XCTAssertEqual(try coordinator.journal.operationEnvelopesSynchronously().count, 1)
        var different = pre
        different.content = try PreparedNoteDocument(NoteDocument(blocks: [.text("Different foreign copy")])).content
        let claim = try await coordinator.journal.writeDurably(different, staged: [])
        XCTAssertEqual(try coordinator.journal.operationEnvelopesSynchronously().count, 1, "a different checkpoint owns no pre-copy")
        _ = try await coordinator.journal.writeDurably(pre, staged: [], replacing: claim)
        XCTAssertTrue(try coordinator.journal.operationEnvelopesSynchronously().isEmpty)
        let restart = NoteDraftJournal(directory: coordinator.journal.directory)
        let entries = try await restart.readRecoveryEntries()
        XCTAssertEqual(entries.count, 1)
        guard case let .valid(entry, _, _) = entries[0] else { return XCTFail("handoff lost the checkpoint") }
        XCTAssertEqual(entry.content, pre.content)
    }

    func testR2PruningFailureRetainsReceiptButAllowsIndependentCheckpointOffersAndSweepRetry() async throws {
        let context = coordinator.freshContext()
        let receipt = OperationReceipt(id: UUID(), envelopeDigest: "released", affectedIDs: Data(), resultingTokens: Data())
        receipt.publicationComplete = true; receipt.handoffProof = Data(); receipt.envelopeReleased = true
        context.insert(receipt); try context.save()
        let independent = NoteDraftJournalEntry(noteID: UUID(), isPersisted: false, baseRevisionID: nil,
            content: try PreparedNoteDocument(NoteDocument(blocks: [.text("offer after reconciliation")])).content,
            selectionLocation: 0, selectionLength: 0, staged: [], savedAt: Date())
        _ = try await coordinator.journal.writeDurably(independent, staged: [])
        coordinator.save = { _ in throw WorkspaceFoundationError.unknown }
        try await coordinator.finishLaunch()
        XCTAssertNotNil(coordinator.launchPruningError)
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<OperationReceipt>()), 1)
        let offered = try await coordinator.journal.readRecoveryEntries()
        XCTAssertEqual(offered.compactMap { if case let .valid(entry, _, _) = $0 { return entry.noteID }; return nil }, [independent.noteID])
        coordinator.save = { try $0.save() }
        try await coordinator.finishLaunch()
        XCTAssertNil(coordinator.launchPruningError)
        XCTAssertEqual(try coordinator.freshContext().fetchCount(FetchDescriptor<OperationReceipt>()), 0)
    }

    func testR2LaunchCheckpointOwnersRetainRowsAndBytesWithoutNotesPageAndReleaseAfterRetirement() async throws {
        let byteID = UUID(), note = UUID()
        let payload = Data("checkpoint only".utf8)
        let staged = StagedNoteAttachment(id: byteID, filename: "only.txt", contentTypeIdentifier: "public.plain-text",
            byteCount: Int64(payload.count), digest: NotePayloadDigest.sha256(payload), data: payload)
        let document = NoteDocument(blocks: [.text("checkpoint"), .file(attachmentID: byteID, filename: "only.txt",
            contentTypeIdentifier: "public.plain-text", byteCount: Int64(payload.count))])
        let entry = NoteDraftJournalEntry(noteID: note, isPersisted: false, baseRevisionID: nil,
            content: try PreparedNoteDocument(document).content, selectionLocation: 0, selectionLength: 0,
            staged: [.init(id: byteID, filename: staged.filename, contentTypeIdentifier: staged.contentTypeIdentifier,
                byteCount: staged.byteCount, digest: staged.digest)], savedAt: Date())
        let claim = try await coordinator.journal.writeDurably(entry, staged: [staged])
        try await coordinator.finishLaunch()
        XCTAssertTrue(coordinator.retainedRecoveryBytes.contains(byteID))
        XCTAssertNil(coordinator.ownership.tryAcquire([byteID], kind: .collection))
        XCTAssertNil(coordinator.ownership.tryAcquire([note], kind: .collection))
        let unrelated = try XCTUnwrap(coordinator.ownership.tryAcquire([UUID()], kind: .collection)); unrelated.release()
        try await coordinator.journal.retireDurably(noteID: note, claim: claim,
            saved: .init(document: document, tags: [], attachments: [byteID: staged]))
        XCTAssertFalse(coordinator.retainedRecoveryBytes.contains(byteID))
        let freed = try XCTUnwrap(coordinator.ownership.tryAcquire([byteID, note], kind: .collection)); freed.release()
    }

    func testR2HistoryRegistrationRetainsLiveReceiptAndReleasesItWhenHistoryEnds() async throws {
        let owner = WorkspaceOwner(entity: .task, id: taskID)
        let envelope = try coordinator.newEnvelope(intent: "history retention", reads: coordinator.capture([owner]), writes: [owner])
        let outcome = await coordinator.execute(envelope, stage: {
            try TaskStore.stageUpdate(in: $0, taskID: self.taskID, title: "history owner", timestamp: Date())
        })
        XCTAssertEqual(outcome, .committed)
        var route: UndoRoute? = UndoRoute()
        var step = UndoStep(name: "retained", undoOutcome: { .failed }, redoOutcome: { .failed })
        step.operationID = envelope.id
        route!.record(step, in: .tasks); coordinator.registerHistory(route!)
        for _ in 0..<64 { coordinator.registerHistory(UndoRoute()) }
        coordinator.registerHistory(route!)
        // Include the pre-Round-2 closure registries so this same assertion
        // exercises their unbounded entries when backported to the old code.
        let registries = Mirror(reflecting: coordinator!).children.filter {
            ["histories", "historyOwners", "historyBytes"].contains($0.label ?? "")
        }
        XCTAssertFalse(registries.isEmpty)
        for registry in registries {
            XCTAssertEqual(Mirror(reflecting: registry.value).children.count, 1,
                           "registration must drop dead entries before pruning: \(registry.label ?? "")")
        }
        try await coordinator.reconcileStartup()
        XCTAssertEqual(try coordinator.prunePublishedReceipts(), 0)
        route = nil
        XCTAssertEqual(try coordinator.prunePublishedReceipts(), 1)
    }

    func testR2GateRegistrySharesLiveDomainsAndReleasesDeadDomains() throws {
        let key = "round2-registry-\(UUID())"
        var gate: WorkspaceOwnershipGate? = .shared(for: key)
        weak var old = gate
        XCTAssertTrue(gate === WorkspaceOwnershipGate.shared(for: key))
        let lease = try XCTUnwrap(gate?.tryAcquire([UUID()], kind: .admission))
        gate = nil
        XCTAssertNotNil(old, "a live lease owns its domain")
        lease.release()
        // The lexical lease still owns its gate; after its scope ends the weak
        // registry must permit the domain to deallocate.
        func abandonedDomain() -> () -> Bool {
            let other = WorkspaceOwnershipGate.shared(for: key + "-abandoned")
            weak var weakOther = other
            return { weakOther == nil }
        }
        XCTAssertTrue(abandonedDomain()())
    }

    func testPF6ProductionPlainSavesUseLedgerWithExactPositiveControls() async throws {
        let tasks = TaskStore(container: container), notes = NoteStore(container: container,
            attachmentFileStore: AttachmentFileStore(rootURL: root.appendingPathComponent("Files")))
        let headID = try XCTUnwrap(tasks.create(title: "Unassociated head")).id
        let library = AtticLibrary(tasks: tasks, notes: notes)
        await notes.waitForAttachmentReconciliation()
        // An ordinary document note does not carry taskNote semantics.
        let ordinaryID = UUID(), document = NoteDocument(blocks: [.text("Ordinary")])
        _ = try notes.createDocumentNote(id: ordinaryID, document: document, staged: []).get()
        _ = try notes.noteMutationPreflight(ordinaryID, format: .document)
        let link = try XCTUnwrap(library.links.link(.init(.task, headID), to: .init(.note, ordinaryID), kind: .reference))
        func check(_ name: String, _ operation: () throws -> Void) rethrows {
            coordinator.validationCounters = .init(); try operation()
            let counters = coordinator.validationCounters
            print("PF6 \(name): fast=\(counters.fastValidations) slow=\(counters.slowValidations) fresh=\(counters.freshContexts)")
            XCTAssertGreaterThan(counters.fastValidations, 0, name)
            XCTAssertEqual(counters.slowValidations, 0, name)
            XCTAssertEqual(counters.freshContexts, 0, name)
        }
        // Warm each production path once before the steady-state samples.
        XCTAssertEqual(library.updateTask(headID, title: "Warm"), .applied)
        for i in 0..<3 {
            check("toggle \(i)") { XCTAssertEqual(library.updateTask(headID, status: i.isMultiple(of: 2) ? .done : .todo), .applied) }
            check("rename \(i)") { XCTAssertEqual(library.updateTask(headID, title: "Steady \(i)"), .applied) }
            check("link \(i)") { XCTAssertTrue(i.isMultiple(of: 2) ? library.links.unlink(link.id) : library.links.restoreLink(link.id)) }
            var next = document; next.blocks[0] = .text("Ordinary \(i)")
            let prepared = try PreparedNoteDocument(next), revision = try XCTUnwrap(notes.loadDocument(noteID: ordinaryID)?.revisionID)
            try check("autosave \(i)") { _ = try notes.saveDocument(noteID: ordinaryID, document: next,
                baseRevisionID: revision, staged: [], prepared: prepared).get() }
        }
        let id = headID, foreign = ModelContext(container)
        try foreign.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first!.title = "Foreign"
        try foreign.save()
        coordinator.validationCounters = .init()
        XCTAssertNotEqual(library.updateTask(id, title: "Stale"), .applied)
        XCTAssertEqual(coordinator.validationCounters.slowValidations, 1)
        XCTAssertEqual(coordinator.validationCounters.freshContexts, 1)
        XCTAssertEqual(library.updateTask(id, title: "Confirmed after refresh"), .applied)
        let owner = WorkspaceOwner(entity: .task, id: id)
        XCTAssertEqual(coordinator.plainSave(tokens: try coordinator.capture([owner]), writes: [owner]) { b in
            try b.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first!.title = "Gated other"
        }, .committed)
        coordinator.validationCounters = .init()
        XCTAssertNotEqual(library.updateTask(id, title: "Stale again"), .applied)
        XCTAssertEqual(coordinator.validationCounters.slowValidations, 1)
        XCTAssertEqual(coordinator.validationCounters.freshContexts, 1)
    }

}

/// The nonmutating text half of H2. This is not the complete H gate.
@MainActor
final class WorkspaceTextReplayTests: XCTestCase {
    private func groupedAdapter() -> NoteUndoHistory {
        let storage = NSTextStorage(string: "abcdef")
        let adapter = NoteUndoHistory(storage: storage)
        adapter.beginGroup()
        for (location, value) in [(0, "A"), (3, "D")] {
            let range = NSRange(location: location, length: 1)
            adapter.willChange(ranges: [range], strings: [value])
            storage.replaceCharacters(in: range, with: value)
            adapter.didChange()
        }
        adapter.endGroup()
        return adapter
    }

    func testH2PreparationAndNativeRefusalDoNotMutateStoragePayloadsOrCursor() throws {
        let adapter = groupedAdapter()
        let payloads = Array(adapter.undoOps.reversed())
        let restores = payloads.map(\.restores)
        let storage = NSAttributedString(attributedString: adapter.storage)
        let cursor = adapter.undoOps.map(ObjectIdentifier.init)
        let prepared = try XCTUnwrap(adapter.prepareReplay(payloads))
        XCTAssertEqual(prepared.candidate.string, "abcdef")
        XCTAssertTrue(adapter.storage.isEqual(to: storage))
        XCTAssertEqual(payloads.map(\.restores), restores)
        XCTAssertEqual(adapter.undoOps.map(ObjectIdentifier.init), cursor)
        XCTAssertNil(adapter.prepareReplay(payloads, preflight: { _ in false }))
        XCTAssertTrue(adapter.storage.isEqual(to: storage))
        XCTAssertEqual(payloads.map(\.restores), restores)
        XCTAssertEqual(adapter.undoOps.map(ObjectIdentifier.init), cursor)
    }

    func testH2InstallationSwapsTheWholeGroupOnceAndDoesNotOwnACursorTransition() throws {
        let adapter = groupedAdapter()
        let payloads = Array(adapter.undoOps.reversed())
        let cursor = adapter.undoOps.map(ObjectIdentifier.init)
        var publications = 0
        adapter.onReplay = { _ in publications += 1 }
        let prepared = try XCTUnwrap(adapter.prepareReplay(payloads))
        XCTAssertTrue(adapter.installReplay(prepared))
        XCTAssertEqual(adapter.storage.string, "abcdef")
        XCTAssertEqual(adapter.undoOps.map(ObjectIdentifier.init), cursor)
        XCTAssertEqual(publications, 1)
        XCTAssertFalse(adapter.installReplay(prepared), "a second inverse is refused")
        XCTAssertEqual(adapter.storage.string, "abcdef")
        XCTAssertEqual(publications, 1)
        let redo = try XCTUnwrap(adapter.prepareReplay(Array(payloads.reversed())))
        XCTAssertTrue(adapter.installReplay(redo))
        XCTAssertEqual(adapter.storage.string, "AbcDef")
    }

    func testH2MetadataDryRunIncludesTagsParagraphAndTypingMarksAndInstallsOnlyOnce() throws {
        let adapter = NoteUndoHistory(storage: NSTextStorage(string: "Title\n"))
        var metadata = NoteUndoHistory.ReplayMetadata(tags: ["after", "unrelated"],
            paragraphs: [6: .init(style: .bullet, indent: 1)], typingMarks: [.bold])
        var publications = 0
        adapter.readReplayMetadata = { metadata }
        adapter.installReplayMetadata = { metadata = $0; publications += 1 }
        adapter.beginGroup()
        adapter.recordTagChange(before: ["before", "unrelated"], after: ["after", "unrelated"])
        adapter.recordParagraphStyleChange(location: 6, before: .init(style: .body, indent: 0), after: .init(style: .bullet, indent: 1))
        adapter.recordTypingMarkChange(.bold, before: false, after: true)
        adapter.endGroup()
        let payloads = Array(adapter.undoOps.reversed()), initial = metadata
        let prepared = try XCTUnwrap(adapter.prepareReplay(payloads))
        XCTAssertEqual(metadata, initial); XCTAssertEqual(publications, 0)
        XCTAssertEqual(prepared.metadata?.tags, ["before", "unrelated"])
        XCTAssertEqual(prepared.metadata?.paragraphs, [:]); XCTAssertEqual(prepared.metadata?.typingMarks, [])
        XCTAssertNil(adapter.prepareReplay(payloads, preflight: { _ in false }))
        XCTAssertEqual(metadata, initial); XCTAssertEqual(publications, 0)
        XCTAssertTrue(adapter.installReplay(prepared)); XCTAssertEqual(metadata, try XCTUnwrap(prepared.metadata)); XCTAssertEqual(publications, 1)
        XCTAssertFalse(adapter.installReplay(prepared)); XCTAssertEqual(publications, 1)
        let redo = try XCTUnwrap(adapter.prepareReplay(payloads.reversed().map { $0 }))
        XCTAssertTrue(adapter.installReplay(redo)); XCTAssertEqual(metadata, initial); XCTAssertEqual(publications, 2)
    }
    func testH2ChangedOrUnknownMetadataRefusesWithoutChangingPayloadsOrDraft() throws {
        let adapter = NoteUndoHistory(storage: NSTextStorage(string: "Title"))
        adapter.recordTagChange(before: ["old"], after: ["new"])
        let payloads = adapter.undoOps, identity = payloads.map(ObjectIdentifier.init)
        XCTAssertNil(adapter.prepareReplay(payloads), "unregistered metadata cannot be guessed")
        var metadata = NoteUndoHistory.ReplayMetadata(tags: ["new"])
        adapter.readReplayMetadata = { metadata }; adapter.installReplayMetadata = { metadata = $0 }
        let prepared = try XCTUnwrap(adapter.prepareReplay(payloads))
        metadata.tags = ["external"]
        XCTAssertFalse(adapter.canInstallReplay(prepared)); XCTAssertFalse(adapter.installReplay(prepared))
        XCTAssertNil(adapter.prepareReplay(payloads)); XCTAssertEqual(metadata.tags, ["external"])
        XCTAssertEqual(adapter.undoOps.map(ObjectIdentifier.init), identity); XCTAssertEqual(adapter.storage.string, "Title")
    }
    func testH2EngineMetadataPreparationProjectsCandidateDocumentWithoutLiveChanges() throws {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("Body")]), tags: ["before"])
        engine.setTagsFromPicker(["after"])
        let before = engine.document(), adapter = engine.history
        let prepared = try XCTUnwrap(adapter.prepareReplay(adapter.undoOps))
        XCTAssertEqual(prepared.metadata?.tags, ["before"]); XCTAssertEqual(prepared.document, before)
        XCTAssertEqual(engine.tags, ["after"]); XCTAssertEqual(engine.document(), before)
        XCTAssertTrue(adapter.installReplay(prepared)); XCTAssertEqual(engine.tags, ["before"])
    }

    func testCombinedPreparedReplayPreservesTrailingParagraphMetadata() throws {
        var empty = NoteBlock.text("")
        empty.style = "bullet"; empty.indent = 2
        empty.extras = ["future": .string("kept")]
        var original = NoteDocument(blocks: [.text("T"), empty])
        original.refreshRequiredCapabilities()
        let engine = NoteEditorEngine(noteID: UUID(), document: original)
        let (_, view) = engine.makeView()
        view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        view.insertText("A", replacementRange: view.selectedRange())
        let typed = engine.document(), adapter = engine.history
        let undo = try XCTUnwrap(adapter.prepareReplay(adapter.undoOps.reversed().map { $0 }))
        XCTAssertEqual(undo.document, original)
        XCTAssertEqual(engine.document(), typed, "Preparation leaves the live editor untouched")
        XCTAssertTrue(adapter.installReplay(undo))
        XCTAssertEqual(engine.document(), original)
        let redo = try XCTUnwrap(adapter.prepareReplay(adapter.undoOps))
        XCTAssertEqual(redo.document, typed)
        XCTAssertTrue(adapter.installReplay(redo))
        XCTAssertEqual(engine.document(), typed)
    }

    func testH2AStalePayloadOrProtectedActivityRefusesTheWholePreparation() {
        let adapter = groupedAdapter()
        let payloads = Array(adapter.undoOps.reversed())
        adapter.canReplay = { false }
        XCTAssertNil(adapter.prepareReplay(payloads))
        adapter.canReplay = { true }
        adapter.rebase(editAt: NSRange(location: 3, length: 1), newLength: 1)
        XCTAssertNil(adapter.prepareReplay(payloads), "overlap cannot become an inert half-inverse")
        XCTAssertEqual(adapter.storage.string, "AbcDef")
        XCTAssertEqual(adapter.undoOps.count, 2)
    }

}
