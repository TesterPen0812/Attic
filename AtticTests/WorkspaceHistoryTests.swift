import AppKit
import SwiftData
import XCTest
@testable import Attic

@MainActor
final class WorkspaceHistoryTests: XCTestCase {
    private var root: URL!
    private var coordinator: WorkspaceOperationCoordinator!
    private var route: UndoRoute!
    private var workspace: WorkspaceHistory!
    private var adapter: NoteUndoHistory!
    private var taskID: UUID!
    private var noteID: UUID!
    private var omitReplayDocumentStage = false

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticHistory-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        coordinator = try WorkspaceOperationCoordinator(container: container, journal: NoteDraftJournal(directory: root.appendingPathComponent("Journal")))
        taskID = UUID(); noteID = UUID()
        let context = coordinator.freshContext()
        context.insert(TaskItem(id: taskID, title: "Before"))
        let note = NoteItem(id: noteID)
        let document = NoteDocument(blocks: [.text("Workspace"), .text("")])
        NoteStore.stageDocumentContent(try PreparedNoteDocument(document), format: 1, on: [note], timestamp: Date(), revision: 0, revisionID: UUID())
        context.insert(note); try context.save()
        route = UndoRoute(); workspace = route.workspace(for: .taskWorkspace(taskID))
        adapter = NoteUndoHistory(storage: NSTextStorage(string: "")); workspace.attach(adapter)
    }
    override func tearDown() async throws {
        adapter = nil; workspace = nil; route = nil; coordinator = nil
        try FileManager.default.removeItem(at: root)
    }
    private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }
    private func expectTrue(_ actual: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(actual, file: file, line: line) }
    private func expectNil<T>(_ actual: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNil(actual, file: file, line: line) }
    private func type(_ text: String) {
        let range = NSRange(location: adapter.storage.length, length: 0)
        adapter.willChange(ranges: [range], strings: [text]); adapter.storage.replaceCharacters(in: range, with: text); adapter.didChange()
    }
    private func title() throws -> String { try XCTUnwrap(coordinator.freshContext().fetch(FetchDescriptor<TaskItem>()).first).title }
    private func savedDocument() throws -> NoteDocument {
        let id = noteID!
        let note = try XCTUnwrap(coordinator.freshContext().fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })).first)
        return try XCTUnwrap(note.content.flatMap { NoteContentCodec.decode($0).document })
    }
    private func recordRename(from: String, to: String, mixed: Bool = false,
                              publish: WorkspaceOperationCoordinator.Publication = .init()) async throws {
        workspace.closeGroup()
        let owner = WorkspaceOwner(entity: .task, id: taskID)
        let before = NSAttributedString(attributedString: adapter.storage)
        let after = NSAttributedString(string: before.string + " transformed")
        var forwardDocument = try savedDocument()
        forwardDocument.blocks[1].text = after.string
        let forwardPrepared = try PreparedNoteDocument(forwardDocument)
        let context = coordinator.freshContext(), note = noteID!
        let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == note }))
        let versions = mixed ? Dictionary(uniqueKeysWithValues: rows.map { ($0.persistentModelID, UUID()) }) : [:]
        let writes = mixed ? Set<WorkspaceOwner>([owner, .init(entity: .note, id: note)])
            .union(versions.values.map { .init(entity: .version, id: $0) }) : [owner]
        let envelope = try coordinator.newEnvelope(intent: "Rename", reads: coordinator.capture(writes), writes: writes,
            afterDocuments: mixed ? [note: forwardPrepared.content] : [:])
        expectEqual(await coordinator.execute(envelope, stage: { context in
            try TaskStore.stageUpdate(in: context, taskID: self.taskID, title: to, timestamp: Date())
            if mixed {
                try NoteStore.stageDocument(in: context, noteID: note, document: forwardDocument, prepared: forwardPrepared,
                    revisionID: UUID(), versionIDs: versions, timestamp: Date())
            }
        }), .committed)
        let group: WorkspaceHistory.TextGroup?
        if mixed {
            adapter.performUnrecorded { adapter.storage.setAttributedString(after) }
            let op = adapter.commandPayload(before: before, name: "Rename with text patch")
            XCTAssertNotNil(adapter.prepareReplay([op]), "payload captures NSTextStorage’s installed attributes")
            group = WorkspaceHistory.TextGroup(adapter: adapter, payload: op)
        } else { group = nil }
        workspace.recordOperation(id: envelope.id, name: mixed ? "Rename with text patch" : "Rename", coordinator: coordinator, textGroup: group) { [self] redo, effect in
            let current = redo ? from : to, next = redo ? to : from
            let context = coordinator.freshContext()
            let replicas = try context.fetch(FetchDescriptor<TaskItem>())
            guard !replicas.isEmpty, replicas.allSatisfy({ $0.title == current }) else { throw WorkspaceFoundationError.conflict }
            let prepared = try group.map { group -> (NoteUndoHistory, NoteUndoHistory.PreparedReplay) in
                let text = try XCTUnwrap(adapter.prepareReplay(redo ? group.payloads : group.payloads.reversed().map { $0 }))
                return (adapter, text)
            }
            var document = try savedDocument()
            if let prepared { document.blocks[1].text = prepared.1.candidate.string }
            let projection = try PreparedNoteDocument(document)
            let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == note }))
            let versions = mixed ? Dictionary(uniqueKeysWithValues: rows.map { ($0.persistentModelID, UUID()) }) : [:]
            let writes = mixed ? Set<WorkspaceOwner>([owner, .init(entity: .note, id: note)])
                .union(versions.values.map { .init(entity: .version, id: $0) }) : [owner]
            let replay = try coordinator.newEnvelope(intent: "Replay Rename", reads: coordinator.capture(writes), writes: writes,
                afterDocuments: mixed ? [note: projection.content] : [:],
                historyEffect: WorkspaceModelFields.encode(effect), replayOf: envelope.id)
            return .init(envelope: replay, text: prepared,
                textDocument: mixed ? (note, projection.content) : nil, stage: { context in
                try TaskStore.stageUpdate(in: context, taskID: self.taskID, title: next, timestamp: Date())
                if mixed && !omitReplayDocumentStage {
                    try NoteStore.stageDocument(in: context, noteID: note, document: document, prepared: projection,
                        revisionID: UUID(), versionIDs: versions, timestamp: Date())
                }
            }, publication: publish)
        }
    }
    func testH1TypingAndRealModelCommandsShareOneChronologicalCursorWithoutAutosave() async throws {
        type("first"); try await recordRename(from: "Before", to: "Tick"); type(" second")
        try await recordRename(from: "Tick", to: "Child", mixed: true)
        expectEqual(route.undoCount(in: workspace.historyID), 4)
        expectEqual(await workspace.replay(redo: false), .applied)
        expectEqual(adapter.storage.string, "first second"); expectEqual(try title(), "Tick")
        expectEqual(try savedDocument().blocks[1].text, "first second")
        XCTAssertTrue(adapter.undo()); expectEqual(adapter.storage.string, "first")
        expectEqual(await workspace.replay(redo: false), .applied); expectEqual(try title(), "Before")
        XCTAssertTrue(adapter.undo()); expectEqual(adapter.storage.string, "")
        XCTAssertTrue(adapter.redo()); expectEqual(await workspace.replay(redo: true), .applied)
        XCTAssertTrue(adapter.redo()); expectEqual(await workspace.replay(redo: true), .applied)
        expectEqual(adapter.storage.string, "first second transformed"); expectEqual(try title(), "Child")
        expectEqual(try savedDocument().blocks[1].text, "first second transformed")
    }
    func testH1LazyBindingKeepsSequenceAndReflectionsCannotReplayTwice() throws {
        type("hello"); let noteID = UUID()
        XCTAssertTrue(workspace.bind(noteID: noteID)); XCTAssertTrue(route.workspace(for: .note(noteID)) === workspace)
        let step = route.undoStepID(in: .note(noteID))
        expectEqual(step, route.undoStepID(in: .taskWorkspace(taskID)))
        XCTAssertTrue(route.undo(in: .note(noteID))); XCTAssertFalse(adapter.undo())
        expectEqual(adapter.storage.string, ""); XCTAssertTrue(adapter.redo())
        expectEqual(adapter.storage.string, "hello")
    }
    func testH2FailedMixedSaveLeavesTextPayloadSelectionAndCursorUnchanged() async throws {
        type("draft"); try await recordRename(from: "Before", to: "After", mixed: true)
        let before = NSAttributedString(attributedString: adapter.storage)
        let count = route.undoCount(in: workspace.historyID), step = route.undoStepID(in: workspace.historyID)
        let restored = adapter.undoOps.map(\.restores)
        let stored = try savedDocument()
        coordinator.save = { _ in throw WorkspaceFoundationError.preparationFailed }
        expectEqual(await workspace.replay(redo: false), .failed)
        XCTAssertTrue(before.isEqual(to: adapter.storage)); expectEqual(try title(), "After")
        expectEqual(try savedDocument(), stored)
        expectEqual(adapter.undoOps.map(\.restores), restored)
        expectEqual(route.undoCount(in: workspace.historyID), count); expectEqual(route.undoStepID(in: workspace.historyID), step)
    }
    func testH1MaterializationRekeysTheSameHistoryWithoutResettingRedoOrReplayIdentity() throws {
        type("first"); workspace.closeGroup(); type(" second")
        let identity = workspace.id, checkpoint = adapter.checkpoint()
        XCTAssertTrue(adapter.undo()); let step = route.steps(in: workspace.historyID, redo: true).last?.id
        XCTAssertTrue(workspace.bind(noteID: noteID)); XCTAssertTrue(workspace.materialize(noteID: noteID))
        expectEqual(workspace.historyID, .note(noteID)); expectEqual(workspace.id, identity)
        XCTAssertTrue(route.workspace(for: .taskWorkspace(taskID)) === workspace)
        XCTAssertTrue(route.workspace(for: .note(noteID)) === workspace)
        expectEqual(route.steps(in: .taskWorkspace(taskID), redo: true).last?.id, step)
        XCTAssertTrue(adapter.redo()); expectEqual(adapter.storage.string, "first second")
        adapter.rewind(to: checkpoint)
        expectEqual(route.undoCount(in: .note(noteID)), 2)
        expectEqual(route.undoCount(in: .taskWorkspace(taskID)), 2)
    }
    func testH2FamilyGuardRefusesWholeMixedReplay() async throws {
        type("draft"); try await recordRename(from: "Before", to: "After", mixed: true)
        let context = coordinator.freshContext(); context.insert(TaskItem(id: taskID, title: "Divergent")); try context.save()
        let text = adapter.storage.string, cursor = route.undoStepID(in: workspace.historyID)
        expectEqual(await workspace.replay(redo: false), .failed)
        expectEqual(adapter.storage.string, text); expectEqual(route.undoStepID(in: workspace.historyID), cursor)
    }
    func testH2MixedReplayCannotSaveOnlyTaskHalfWhenDocumentStagingIsMissing() async throws {
        type("unsaved draft"); try await recordRename(from: "Before", to: "After", mixed: true)
        let text = NSAttributedString(attributedString: adapter.storage), stored = try savedDocument()
        let cursor = route.undoStepID(in: workspace.historyID)
        omitReplayDocumentStage = true
        expectEqual(await workspace.replay(redo: false), .failed)
        expectEqual(try title(), "After"); expectEqual(try savedDocument(), stored)
        XCTAssertTrue(text.isEqual(to: adapter.storage)); expectEqual(route.undoStepID(in: workspace.historyID), cursor)
        XCTAssertTrue(try coordinator.freshContext().fetch(FetchDescriptor<OperationReceipt>()).allSatisfy { $0.replayOf == nil })
    }
    func testH2CommittedCursorMovesOnceWhilePublicationWaitsAndRetryDoesNotSaveInverseAgain() async throws {
        var fail = true, publications = 0, saves = 0
        let publish = WorkspaceOperationCoordinator.Publication(steps: [{ _ in
            publications += 1; if fail { throw WorkspaceFoundationError.preparationFailed }
        }])
        type("draft"); try await recordRename(from: "Before", to: "After", mixed: true, publish: publish)
        coordinator.save = { context in saves += 1; try context.save() }
        expectEqual(await workspace.replay(redo: false), .applied)
        XCTAssertNotNil(workspace.pendingReplayID); expectEqual(try title(), "Before")
        expectEqual(try savedDocument().blocks[1].text, "draft")
        let count = route.undoCount(in: workspace.historyID), saved = saves
        expectNil(await workspace.replay(redo: false)); XCTAssertFalse(adapter.undo())
        fail = false; expectTrue(await workspace.retryPublication(using: coordinator))
        expectEqual(route.undoCount(in: workspace.historyID), count)
        expectEqual(saves, saved + 3, "retry saves publication, handoff and release bookkeeping only")
        let receiptID = try XCTUnwrap(coordinator.freshContext().fetch(FetchDescriptor<OperationReceipt>()).first(where: { $0.replayOf != nil }))
        XCTAssertTrue(receiptID.publicationComplete); XCTAssertTrue(receiptID.envelopeReleased); XCTAssertNotNil(receiptID.handoffProof)
        expectEqual(publications, 2)
    }
    func testH1ReservedInputIsDeliveredExactlyOnceAfterCommitAndAfterAbort() async throws {
        type("draft"); try await recordRename(from: "Before", to: "After", mixed: true)
        var delivered = 0
        coordinator.afterPreparation = { [self] in
            workspace.submitInput { [self] in delivered += 1; type(" queued") }
        }
        expectEqual(await workspace.replay(redo: false), .applied)
        expectEqual(delivered, 1); expectEqual(adapter.storage.string, "draft queued")
        XCTAssertTrue(adapter.undo())
        coordinator.afterPreparation = nil
        try await recordRename(from: "Before", to: "Abort", mixed: true)
        coordinator.afterPreparation = { [self] in
            workspace.submitInput { [self] in delivered += 1; type(" queued") }
        }
        coordinator.save = { _ in throw WorkspaceFoundationError.preparationFailed }
        expectEqual(await workspace.replay(redo: false), .failed)
        expectEqual(delivered, 2)
        expectEqual(adapter.storage.string, "draft transformed queued")
        expectEqual(try title(), "Abort")
    }
    func testH3AcceptedTypingClearsRedoButRefusedPreparationDoesNot() async throws {
        type("first"); workspace.closeGroup(); type(" second")
        XCTAssertTrue(adapter.undo()); XCTAssertTrue(adapter.canRedo)
        adapter.canReplay = { false }; XCTAssertFalse(adapter.redo()); XCTAssertTrue(route.canRedo(in: workspace.historyID))
        adapter.canReplay = { true }; type(" replacement")
        XCTAssertFalse(adapter.canRedo); expectEqual(adapter.storage.string, "first replacement")
    }
    func testH4WritingToolsCheckpointRestoresWorkspaceAndMutableAdapterTogether() async throws {
        type("before"); try await recordRename(from: "Before", to: "After")
        let text = NSAttributedString(attributedString: adapter.storage), checkpoint = adapter.checkpoint()
        type(" temporary"); expectEqual(route.undoCount(in: workspace.historyID), 3)
        adapter.performUnrecorded { adapter.storage.setAttributedString(text) }; adapter.rewind(to: checkpoint)
        expectEqual(route.undoCount(in: workspace.historyID), 2)
        expectEqual(await workspace.replay(redo: false), .applied); expectEqual(try title(), "Before")
        XCTAssertTrue(adapter.undo()); expectEqual(adapter.storage.string, "")
    }
}
