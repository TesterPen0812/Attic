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
    func testH1ForwardMakeSubtaskReservesTypingAndReplaysRealChildAndFullDraftAtomically() async throws {
        let tasks = TaskStore(container: coordinator.container), library = AtticLibrary(tasks: tasks, undo: route)
        let tickID = try XCTUnwrap(tasks.create(title: "Tick child", parentID: taskID)).id
        type("earlier"); workspace.closeGroup()
        expectEqual(library.updateTask(tickID, status: .done, in: workspace.historyID), .applied)
        type("\nMake child")
        let childID = UUID(), forwardEntry = UUID(), parent = taskID!, noteID = noteID!
        var group: WorkspaceHistory.TextGroup!
        var forwardID: UUID!
        var delivered = 0
        coordinator.afterPreparation = { [self] in
            workspace.submitInput { [self] in delivered += 1; type(" queued") }
        }
        let outcome = await workspace.performCommand(using: coordinator) { [self] in
            let command = try XCTUnwrap(adapter.prepareCommand(NSAttributedString(string: "earlier"), name: "Make Subtask"))
            group = .init(adapter: adapter, payload: command.payload)
            let context = coordinator.freshContext()
            let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
            let versions = Dictionary(uniqueKeysWithValues: rows.map { ($0.persistentModelID, UUID()) })
            let document = NoteDocument(blocks: [.text("Workspace"), .text("earlier")]), prepared = try PreparedNoteDocument(document)
            let writes = Set<WorkspaceOwner>([.init(entity: .task, id: childID), .init(entity: .note, id: noteID)])
                .union(versions.values.map { .init(entity: .version, id: $0) })
            let guards = writes.union([.init(entity: .task, id: parent)])
            let envelope = try coordinator.newEnvelope(intent: "Make Subtask", reads: coordinator.capture(guards), writes: writes,
                afterDocuments: [noteID: prepared.content], historyEffect: WorkspaceModelFields.encode(WorkspaceHistory.ForwardEffect(workspaceID: workspace.id, entryID: forwardEntry)))
            forwardID = envelope.id
            return .init(entryID: forwardEntry, envelope: envelope, sessionValid: { adapter.canInstallCommand(command) }, stage: { commit in
                _ = try TaskStore.stageCreation(in: commit, drafts: [TaskDraft(title: "Make child", parentID: parent)], ids: [childID], timestamp: Date())
                try NoteStore.stageDocument(in: commit, noteID: noteID, document: document, prepared: prepared,
                    revisionID: UUID(), versionIDs: versions, timestamp: Date())
            }, record: { operation, entry in
                workspace.recordOperation(id: operation, entryID: entry, name: "Make Subtask", coordinator: coordinator, textGroup: group) { redo, effect in
                    let context = coordinator.freshContext()
                    let children = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == childID }))
                    guard !children.isEmpty, children.allSatisfy({ $0.title == "Make child" && $0.parentID == parent && (($0.deletedAt != nil) == redo) }) else { throw WorkspaceFoundationError.conflict }
                    let text = try XCTUnwrap(adapter.prepareReplay(redo ? group.payloads : group.payloads.reversed().map { $0 }))
                    let document = NoteDocument(blocks: [.text("Workspace")] + text.candidate.string.components(separatedBy: "\n").map { .text($0) })
                    let prepared = try PreparedNoteDocument(document)
                    let notes = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
                    let versions = Dictionary(uniqueKeysWithValues: notes.map { ($0.persistentModelID, UUID()) }), preservation = UUID()
                    var writes = Set<WorkspaceOwner>([.init(entity: .task, id: childID), .init(entity: .note, id: noteID)])
                        .union(versions.values.map { .init(entity: .version, id: $0) })
                    if !redo { writes.insert(.init(entity: .preservation, id: preservation)) }
                    let envelope = try coordinator.newEnvelope(intent: "Replay Make Subtask", reads: coordinator.capture(writes.union([.init(entity: .task, id: parent)])), writes: writes,
                        afterDocuments: [noteID: prepared.content], historyEffect: WorkspaceModelFields.encode(effect), replayOf: operation)
                    return .init(envelope: envelope, text: (adapter, text), textDocument: (noteID, prepared.content), stage: { commit in
                        if redo { try TaskStore.stageRestoreDeleted(in: commit, taskIDs: [childID], timestamp: Date()) }
                        else { try TaskStore.stageSoftDeletion(in: commit, taskID: childID, preservationID: preservation, timestamp: Date()) }
                        try NoteStore.stageDocument(in: commit, noteID: noteID, document: document, prepared: prepared,
                            revisionID: UUID(), versionIDs: versions, timestamp: Date())
                    }, publication: .init(steps: [{ _ in tasks.refresh() }]))
                }
            }, publication: .init(steps: [{ _ in
                guard adapter.installCommand(command) else { throw WorkspaceFoundationError.conflict }
                tasks.refresh()
            }]))
        }
        expectEqual(outcome, .committed); expectEqual(delivered, 1); expectEqual(adapter.storage.string, "earlier queued")
        expectEqual(route.undoCount(in: workspace.historyID), 5)
        let id = forwardID!
        let receipt = try XCTUnwrap(coordinator.freshContext().fetch(FetchDescriptor<OperationReceipt>(predicate: #Predicate { $0.id == id })).first)
        expectEqual(receipt.historyEffect, try WorkspaceModelFields.encode(WorkspaceHistory.ForwardEffect(workspaceID: workspace.id, entryID: forwardEntry)))
        coordinator.afterPreparation = nil
        expectTrue(adapter.undo()); expectEqual(adapter.storage.string, "earlier")
        expectEqual(await workspace.replay(redo: false), .applied)
        expectEqual(adapter.storage.string, "earlier\nMake child"); expectEqual(try savedDocument().blocks.map(\.text), ["Workspace", "earlier", "Make child"])
        let deleted = try XCTUnwrap(coordinator.freshContext().fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == childID })).first)
        XCTAssertNotNil(deleted.deletedAt)
        expectTrue(adapter.undo()); expectEqual(adapter.storage.string, "earlier")
        expectEqual(await workspace.replay(redo: false), .applied)
        expectEqual(tasks.task(withID: tickID)?.status, .todo)
        expectTrue(adapter.undo()); expectEqual(adapter.storage.string, "")
        expectTrue(adapter.redo()); expectEqual(await workspace.replay(redo: true), .applied)
        expectEqual(tasks.task(withID: tickID)?.status, .done)
        expectTrue(adapter.redo()); expectEqual(adapter.storage.string, "earlier\nMake child")
        expectEqual(await workspace.replay(redo: true), .applied); expectEqual(adapter.storage.string, "earlier")
        XCTAssertNil(try coordinator.freshContext().fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == childID })).first?.deletedAt)
        expectEqual(try savedDocument().blocks.map(\.text), ["Workspace", "earlier"])
    }

    private func forwardRenamePlan(publication: WorkspaceOperationCoordinator.Publication = .init()) throws -> WorkspaceHistory.CommandPlan {
        let entryID = UUID(), owner = WorkspaceOwner(entity: .task, id: taskID)
        let envelope = try coordinator.newEnvelope(intent: "Forward rename", reads: coordinator.capture([owner]), writes: [owner],
            historyEffect: WorkspaceModelFields.encode(WorkspaceHistory.ForwardEffect(workspaceID: workspace.id, entryID: entryID)))
        return .init(entryID: entryID, envelope: envelope, stage: { [self] context in
            try TaskStore.stageUpdate(in: context, taskID: taskID, title: "After", timestamp: Date())
        }, record: { [self] operation, entry in
            workspace.recordOperation(id: operation, entryID: entry, name: "Rename", coordinator: coordinator) { [self] redo, effect in
                let envelope = try coordinator.newEnvelope(intent: "Replay rename", reads: coordinator.capture([owner]), writes: [owner],
                    historyEffect: WorkspaceModelFields.encode(effect), replayOf: operation)
                return .init(envelope: envelope, stage: { [self] context in
                    try TaskStore.stageUpdate(in: context, taskID: taskID, title: redo ? "After" : "Before", timestamp: Date())
                })
            }
        }, publication: publication)
    }
    func testH1ForwardFailureAndCancellationKeepDraftAndHistoryAndDeliverQueuedInputOnce() async throws {
        type("draft"); let cursor = route.undoStepID(in: workspace.historyID)
        var delivered = 0
        coordinator.afterPreparation = { [self] in workspace.submitInput { [self] in delivered += 1; type(" queued") } }
        coordinator.save = { _ in throw WorkspaceFoundationError.preparationFailed }
        expectEqual(await workspace.performCommand(using: coordinator) { [self] in try forwardRenamePlan() }, .notCommitted)
        expectEqual(try title(), "Before"); expectEqual(delivered, 1); expectEqual(adapter.storage.string, "draft queued")
        XCTAssertNil(workspace.pendingCommandID)
        XCTAssertEqual(route.undoCount(in: workspace.historyID), 2)
        XCTAssertEqual(route.steps(in: workspace.historyID, redo: false).first?.id, cursor)
        coordinator.afterPreparation = nil
        let count = route.undoCount(in: workspace.historyID), text = adapter.storage.string
        let cancelled = Task { [self] in
            await workspace.performCommand(using: coordinator) { [self] in
                let plan = try forwardRenamePlan()
                withUnsafeCurrentTask { $0?.cancel() }
                return plan
            }
        }
        expectEqual(await cancelled.value, .notCommitted)
        expectEqual(try title(), "Before"); expectEqual(adapter.storage.string, text)
        expectEqual(route.undoCount(in: workspace.historyID), count)
        XCTAssertTrue(workspace.canUndo)
    }
    func testH1ForwardPendingPublicationRetainsInputAndRecordsOneEntryBeforeRetryInstall() async throws {
        type("draft"); var blocked = true, delivered = 0, installations = 0, saves = 0
        coordinator.save = { context in saves += 1; try context.save() }
        coordinator.afterPreparation = { [self] in workspace.submitInput { [self] in delivered += 1; type(" queued") } }
        let publication = WorkspaceOperationCoordinator.Publication(steps: [{ _ in
            if blocked { throw WorkspaceFoundationError.preparationFailed }
            installations += 1
        }])
        expectEqual(await workspace.performCommand(using: coordinator) { [self] in try forwardRenamePlan(publication: publication) }, .publicationPending)
        expectEqual(try title(), "After"); expectEqual(adapter.storage.string, "draft"); expectEqual(delivered, 0)
        let count = route.undoCount(in: workspace.historyID), saved = saves
        XCTAssertNotNil(workspace.pendingCommandID); XCTAssertFalse(adapter.undo())
        blocked = false
        expectTrue(await workspace.retryPublication(using: coordinator))
        expectEqual(installations, 1); expectEqual(delivered, 1); expectEqual(adapter.storage.string, "draft queued")
        expectEqual(route.undoCount(in: workspace.historyID), count + 1)
        expectEqual(saves, saved + 3)
        let repeated = await workspace.retryPublication(using: coordinator)
        XCTAssertFalse(repeated)
        expectEqual(installations, 1); expectEqual(delivered, 1)
    }

    func testH1TypingAndRealModelCommandsShareOneChronologicalCursorWithoutAutosave() async throws {
        let tasks = TaskStore(container: coordinator.container)
        let library = AtticLibrary(tasks: tasks, undo: route)
        type("first"); workspace.closeGroup()
        expectEqual(library.updateTask(taskID, status: .done, in: workspace.historyID), .applied)
        type(" second")
        try await recordRename(from: "Before", to: "Child", mixed: true,
            publish: .init(steps: [{ _ in tasks.refresh() }]))
        expectEqual(route.undoCount(in: workspace.historyID), 4)
        expectEqual(await workspace.replay(redo: false), .applied)
        expectEqual(adapter.storage.string, "first second"); expectEqual(try title(), "Before")
        expectEqual(try savedDocument().blocks[1].text, "first second")
        XCTAssertTrue(adapter.undo()); expectEqual(adapter.storage.string, "first")
        expectEqual(await workspace.replay(redo: false), .applied); expectEqual(try title(), "Before")
        expectEqual(try coordinator.freshContext().fetch(FetchDescriptor<TaskItem>()).first?.status, .todo)
        XCTAssertTrue(adapter.undo()); expectEqual(adapter.storage.string, "")
        XCTAssertTrue(adapter.redo()); expectEqual(await workspace.replay(redo: true), .applied)
        XCTAssertTrue(adapter.redo()); expectEqual(await workspace.replay(redo: true), .applied)
        expectEqual(adapter.storage.string, "first second transformed"); expectEqual(try title(), "Child")
        expectEqual(try savedDocument().blocks[1].text, "first second transformed")
    }
    func testH1RealReorderOccupiesItsChronologicalPlaceAndReplaysBothWays() async throws {
        let tasks = TaskStore(container: coordinator.container), library = AtticLibrary(tasks: tasks, undo: route)
        let sibling = try XCTUnwrap(tasks.create(title: "Sibling"))
        let before = tasks.orderedTasks(for: .todo).map(\.id)
        type("before order"); workspace.closeGroup()
        expectEqual(library.moveTask(taskID, relativeTo: sibling.id, in: workspace.historyID), .applied)
        let after = tasks.orderedTasks(for: .todo).map(\.id)
        XCTAssertNotEqual(before, after)
        type(" after order")
        expectTrue(adapter.undo()); expectEqual(adapter.storage.string, "before order")
        expectEqual(await workspace.replay(redo: false), .applied)
        expectEqual(tasks.orderedTasks(for: .todo).map(\.id), before)
        expectTrue(adapter.undo()); expectEqual(adapter.storage.string, "")
        expectTrue(adapter.redo()); expectEqual(await workspace.replay(redo: true), .applied)
        expectEqual(tasks.orderedTasks(for: .todo).map(\.id), after)
        expectTrue(adapter.redo()); expectEqual(adapter.storage.string, "before order after order")
    }
    func testH3DirtyTypingPrecedesNamedExternalBarrierAndToastIsLatestOnly() async throws {
        type("local"); workspace.closeGroup()
        let toast = try XCTUnwrap(route.undoStepID(in: workspace.historyID))
        workspace.recordExternalBarrier(origin: "Claude")
        let barrier = route.undoStepID(in: workspace.historyID)
        expectNil(await workspace.undoLatest(stepID: toast))
        type(" dirty")
        expectTrue(adapter.undo()); expectEqual(adapter.storage.string, "local")
        expectEqual(route.undoStepID(in: workspace.historyID), barrier)
        XCTAssertTrue(workspace.undoName.contains("Claude"))
        expectEqual(await workspace.replay(redo: false), .failed)
        expectEqual(adapter.storage.string, "local")
        XCTAssertTrue(workspace.canRedo, "a refused barrier clears nothing")
        workspace.recordExternalBarrier(origin: "Other window")
        XCTAssertFalse(workspace.canRedo, "an applied external change clears redo")
        type(" latest")
        let latest = try XCTUnwrap(route.undoStepID(in: workspace.historyID))
        expectEqual(await workspace.undoLatest(stepID: latest), .applied)
        expectEqual(adapter.storage.string, "local")
        expectNil(await workspace.undoLatest(stepID: latest))
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
