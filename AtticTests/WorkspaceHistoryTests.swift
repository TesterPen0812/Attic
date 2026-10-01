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

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticHistory-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        coordinator = try WorkspaceOperationCoordinator(container: container, journal: NoteDraftJournal(directory: root.appendingPathComponent("Journal")))
        taskID = UUID()
        let context = coordinator.freshContext(); context.insert(TaskItem(id: taskID, title: "Before")); try context.save()
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
    private func recordRename(from: String, to: String, mixed: Bool = false,
                              publish: WorkspaceOperationCoordinator.Publication = .init()) async throws {
        workspace.closeGroup()
        let owner = WorkspaceOwner(entity: .task, id: taskID)
        let envelope = try coordinator.newEnvelope(intent: "Rename", reads: coordinator.capture([owner]), writes: [owner])
        expectEqual(await coordinator.execute(envelope, stage: { context in
            try TaskStore.stageUpdate(in: context, taskID: self.taskID, title: to, timestamp: Date())
        }), .committed)
        let group: WorkspaceHistory.TextGroup?
        if mixed {
            let before = NSAttributedString(attributedString: adapter.storage)
            let after = NSAttributedString(string: before.string + " transformed")
            let op = adapter.commandPayload(before: before, after: after, name: "Rename with text patch")
            adapter.performUnrecorded { adapter.storage.setAttributedString(after) }
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
            let replay = try coordinator.newEnvelope(intent: "Replay Rename", reads: coordinator.capture([owner]), writes: [owner],
                historyEffect: WorkspaceModelFields.encode(effect), replayOf: envelope.id)
            return .init(envelope: replay, text: prepared, stage: { context in
                try TaskStore.stageUpdate(in: context, taskID: self.taskID, title: next, timestamp: Date())
            }, publication: publish)
        }
    }
    func testH1TypingAndRealModelCommandsShareOneChronologicalCursorWithoutAutosave() async throws {
        type("first"); try await recordRename(from: "Before", to: "Tick"); type(" second")
        try await recordRename(from: "Tick", to: "Child", mixed: true)
        expectEqual(route.undoCount(in: workspace.historyID), 4)
        expectEqual(await workspace.replay(redo: false), .applied)
        expectEqual(adapter.storage.string, "first second"); expectEqual(try title(), "Tick")
        XCTAssertTrue(adapter.undo()); expectEqual(adapter.storage.string, "first")
        expectEqual(await workspace.replay(redo: false), .applied); expectEqual(try title(), "Before")
        XCTAssertTrue(adapter.undo()); expectEqual(adapter.storage.string, "")
        XCTAssertTrue(adapter.redo()); expectEqual(await workspace.replay(redo: true), .applied)
        XCTAssertTrue(adapter.redo()); expectEqual(await workspace.replay(redo: true), .applied)
        expectEqual(adapter.storage.string, "first second transformed"); expectEqual(try title(), "Child")
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
        coordinator.save = { _ in throw WorkspaceFoundationError.preparationFailed }
        expectEqual(await workspace.replay(redo: false), .failed)
        XCTAssertTrue(before.isEqual(to: adapter.storage)); expectEqual(try title(), "After")
        expectEqual(adapter.undoOps.map(\.restores), restored)
        expectEqual(route.undoCount(in: workspace.historyID), count); expectEqual(route.undoStepID(in: workspace.historyID), step)
    }
    func testH2FamilyGuardRefusesWholeMixedReplay() async throws {
        type("draft"); try await recordRename(from: "Before", to: "After", mixed: true)
        let context = coordinator.freshContext(); context.insert(TaskItem(id: taskID, title: "Divergent")); try context.save()
        let text = adapter.storage.string, cursor = route.undoStepID(in: workspace.historyID)
        expectEqual(await workspace.replay(redo: false), .failed)
        expectEqual(adapter.storage.string, text); expectEqual(route.undoStepID(in: workspace.historyID), cursor)
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
