import AppKit
import Foundation
import SwiftData

/// Workspace ordering and retention use UndoRoute's existing cursor and limits.
/// NoteUndoHistory is an attributed-payload adapter while attached here.
@MainActor
final class WorkspaceHistory {
    @MainActor
    final class TextGroup {
        let adapter: NoteUndoHistory
        var payloads: [NoteUndoHistory.Op]
        init(adapter: NoteUndoHistory, payload: NoteUndoHistory.Op) {
            self.adapter = adapter; payloads = [payload]
        }
        var attachmentIDs: Set<UUID> { adapter.attachmentIDs(in: payloads) }
        func replay(redo: Bool) -> UndoOutcome {
            let order = redo ? payloads : payloads.reversed().map { $0 }
            guard let prepared = adapter.prepareReplay(order), adapter.installReplay(prepared) else { return .failed }
            return .applied
        }
    }
    struct CursorEffect: Codable, Equatable {
        let workspaceID: UUID
        let entryID: UUID
        let redo: Bool
    }
    struct ReplayPlan {
        let envelope: WorkspaceOperationEnvelope
        let text: (NoteUndoHistory, NoteUndoHistory.PreparedReplay)?
        let textDocument: (noteID: UUID, content: Data)?
        let stage: (ModelContext) throws -> Void
        let publication: WorkspaceOperationCoordinator.Publication
        init(envelope: WorkspaceOperationEnvelope,
             text: (NoteUndoHistory, NoteUndoHistory.PreparedReplay)? = nil,
             textDocument: (noteID: UUID, content: Data)? = nil,
             stage: @escaping (ModelContext) throws -> Void,
             publication: WorkspaceOperationCoordinator.Publication = .init()) {
            self.envelope = envelope; self.text = text; self.textDocument = textDocument
            self.stage = stage; self.publication = publication
        }
    }

    let id = UUID()
    unowned let route: UndoRoute
    private(set) var historyID: UndoHistoryID
    private(set) var pendingReplayID: UUID?
    private(set) var pendingCommandID: UUID?
    private var inputReserved = false
    private var queuedInput: [() -> Void] = []
    private final class WeakAdapter {
        weak var value: NoteUndoHistory?
        init(_ value: NoteUndoHistory) { self.value = value }
    }
    private var adapters: [WeakAdapter] = []

    init(route: UndoRoute, historyID: UndoHistoryID) {
        self.route = route; self.historyID = historyID
    }
    var canUndo: Bool { pendingReplayID == nil && pendingCommandID == nil && !inputReserved && route.canUndo(in: historyID) }
    var canRedo: Bool { pendingReplayID == nil && pendingCommandID == nil && !inputReserved && route.canRedo(in: historyID) }
    var undoName: String { route.undoName(in: historyID) ?? "" }
    var redoName: String { route.redoName(in: historyID) ?? "" }

    func attach(_ adapter: NoteUndoHistory) {
        guard adapter.workspace !== self else { return }
        precondition(adapter.workspace == nil, "One workspace owns an editor adapter")
        let existing = adapter.undoOps
        precondition(adapter.redoOps.isEmpty, "Attach before editing or replay")
        adapter.reset()
        adapter.workspace = self
        adapters.removeAll { $0.value == nil }
        adapters.append(WeakAdapter(adapter))
        for op in existing { capture(op, from: adapter) }
    }
    func bind(noteID: UUID) -> Bool { route.alias(.note(noteID), to: historyID) }
    func materialize(noteID: UUID) -> Bool { route.rekey(self, to: .note(noteID)) }
    func didRekey(to key: UndoHistoryID) { historyID = key }
    func closeGroup() { adapters.compactMap(\.value).forEach { $0.breakCoalescing() } }

    func capture(_ op: NoteUndoHistory.Op, from adapter: NoteUndoHistory) {
        // Commands reserve input before asynchronous preparation. Callers deliver
        // native edits through submitInput, never mutate storage then enqueue it.
        precondition(!inputReserved && pendingReplayID == nil, "Reserved workspace input must be queued")
        if let last = route.steps(in: historyID, redo: false).last?.workspacePayload,
           last.adapter === adapter, last.payloads.last?.captureGroup == op.captureGroup {
            last.payloads.append(op)
            return
        }
        let group = TextGroup(adapter: adapter, payload: op)
        var step = UndoStep(name: op.name, undoOutcome: { group.replay(redo: false) }, redoOutcome: { group.replay(redo: true) })
        step.workspacePayload = group
        route.record(step, in: historyID)
    }
    func payloads(for adapter: NoteUndoHistory, redo: Bool) -> [NoteUndoHistory.Op] {
        let steps = route.steps(in: historyID, redo: redo)
        let ordered = redo ? steps.reversed().map { $0 } : steps
        return ordered.compactMap(\.workspacePayload).filter { $0.adapter === adapter }.flatMap(\.payloads)
    }
    func checkpoint() -> UndoRoute.Checkpoint { closeGroup(); return route.checkpoint(in: historyID) }
    func rewind(to checkpoint: UndoRoute.Checkpoint) { route.rewind(to: checkpoint); closeGroup() }
    func clear() { route.clear(historyID); closeGroup() }

    /// Reserve before capturing a command candidate. Input arriving while
    /// journal IO runs is delivered exactly once after installation or abort.
    func reserveInput() -> Bool {
        guard !inputReserved, pendingReplayID == nil, pendingCommandID == nil,
              adapters.compactMap(\.value).allSatisfy(\.canPrepareWorkspaceCommand) else { return false }
        closeGroup(); inputReserved = true; return true
    }
    func submitInput(_ edit: @escaping () -> Void) {
        if inputReserved || pendingReplayID != nil { queuedInput.append(edit) }
        else { edit() }
    }
    func releaseInput() {
        guard pendingReplayID == nil, pendingCommandID == nil else { return }
        inputReserved = false
        let input = queuedInput; queuedInput.removeAll()
        for edit in input { edit() }
    }

    /// Called after the forward operation has been proven committed. Replay
    /// plans use real coordinator staging and carry their cursor effect in the
    /// same receipt as the inverse rows. No editor mutation precedes that save.
    func recordOperation(id operationID: UUID, entryID: UUID = UUID(), name: String, coordinator: WorkspaceOperationCoordinator,
                         attachmentIDs: Set<UUID> = [], textGroup: TextGroup? = nil,
                         prepare: @escaping (Bool, CursorEffect) throws -> ReplayPlan) {
        closeGroup()
        coordinator.registerHistory(route)
        guard !route.steps(in: historyID, redo: false).contains(where: { $0.operationID == operationID }),
              !route.steps(in: historyID, redo: true).contains(where: { $0.operationID == operationID }) else { return }
        var step = UndoStep(id: entryID, name: name, undoOutcome: { .failed }, redoOutcome: { .failed })
        step.operationID = operationID; step.attachmentIDs = attachmentIDs; step.workspacePayload = textGroup
        step.replay = { [weak self, weak coordinator] redo, commitCursor in
            guard let self, let coordinator, self.reserveInput() else { return .failed }
            defer { self.releaseInput() }
            let plan: ReplayPlan
            do {
                let effect = CursorEffect(workspaceID: self.id, entryID: entryID, redo: redo)
                plan = try prepare(redo, effect)
                guard plan.envelope.replayOf == operationID,
                      plan.envelope.historyEffect == (try WorkspaceModelFields.encode(effect)) else { return .failed }
                if plan.text != nil {
                    guard let document = plan.textDocument,
                          plan.envelope.afterDocuments[document.noteID] == document.content,
                          plan.envelope.writes.contains(.init(entity: .note, id: document.noteID)) else { return .failed }
                    if let draft = plan.text?.1.document {
                        guard NoteContentCodec.decode(document.content).document == draft else { return .failed }
                    }
                }
            } catch { return .failed }
            let install: @MainActor (UUID) throws -> Void = { _ in
                if let (adapter, text) = plan.text, !adapter.installReplay(text) { throw WorkspaceFoundationError.conflict }
            }
            let publication = WorkspaceOperationCoordinator.Publication(steps: [{ _ in try commitCursor() }, install] + plan.publication.steps)
            let outcome = await coordinator.execute(plan.envelope, sessionValid: {
                plan.text.map { $0.0.canInstallReplay($0.1) } ?? true
            }, stage: { context in
                try plan.stage(context)
                // A mixed inverse cannot commit only its task half. Verify the
                // complete prepared document on every physical note before save.
                if let document = plan.textDocument {
                    let id = document.noteID
                    let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
                    guard !rows.isEmpty, rows.allSatisfy({ $0.content == document.content }) else {
                        throw WorkspaceFoundationError.conflict
                    }
                    if let metadata = plan.text?.1.metadata {
                        guard rows.allSatisfy({ $0.tags == metadata.tags }) else { throw WorkspaceFoundationError.conflict }
                    }
                }
            }, publication: publication)
            switch outcome {
            case .committed: return .applied
            case .publicationPending, .unknown:
                self.pendingReplayID = plan.envelope.id
                return .failed
            case .notCommitted, .conflict: return .failed
            }
        }
        route.record(step, in: historyID)
    }
    struct ForwardEffect: Codable, Equatable { let workspaceID: UUID; let entryID: UUID }
    struct CommandPlan {
        let entryID: UUID
        let envelope: WorkspaceOperationEnvelope
        let sessionValid: () -> Bool
        let stage: (ModelContext) throws -> Void
        let record: (UUID, UUID) -> Void
        let publication: WorkspaceOperationCoordinator.Publication
        init(entryID: UUID, envelope: WorkspaceOperationEnvelope, sessionValid: @escaping () -> Bool = { true },
             stage: @escaping (ModelContext) throws -> Void, record: @escaping (UUID, UUID) -> Void,
             publication: WorkspaceOperationCoordinator.Publication = .init()) {
            self.entryID = entryID; self.envelope = envelope; self.sessionValid = sessionValid
            self.stage = stage; self.record = record; self.publication = publication
        }
    }

    /// Reserve the input sequence before the caller captures its draft. The
    /// typed forward entry is recorded at receipt publication, before the
    /// prepared editor/presentation handlers. Cancellation keeps the old draft.
    func performCommand(using coordinator: WorkspaceOperationCoordinator,
                        prepare: () async throws -> CommandPlan) async -> WorkspaceOperationCoordinator.Outcome {
        guard !Task.isCancelled, reserveInput() else { return .conflict }
        defer { releaseInput() }
        let plan: CommandPlan
        do {
            plan = try await prepare()
            guard plan.envelope.historyEffect == (try WorkspaceModelFields.encode(ForwardEffect(workspaceID: id, entryID: plan.entryID))) else { return .conflict }
        } catch { return .notCommitted }
        guard !Task.isCancelled else { return .notCommitted }
        let publication = WorkspaceOperationCoordinator.Publication(steps: [{ operation in
            plan.record(operation, plan.entryID)
        }] + plan.publication.steps)
        let outcome = await coordinator.execute(plan.envelope, sessionValid: plan.sessionValid,
            stage: plan.stage, publication: publication)
        if outcome == .publicationPending || outcome == .unknown { pendingCommandID = plan.envelope.id }
        return outcome
    }

    func retryPublication(using coordinator: WorkspaceOperationCoordinator) async -> Bool {
        guard let operation = pendingReplayID ?? pendingCommandID else { return false }
        guard await coordinator.retryPublication(operation) == .committed else { return false }
        pendingReplayID = nil; pendingCommandID = nil; releaseInput(); return true
    }
    @discardableResult func undo() -> Bool { closeGroup(); return canUndo && route.undo(in: historyID) }
    @discardableResult func redo() -> Bool { closeGroup(); return canRedo && route.redo(in: historyID) }
    func replay(redo: Bool) async -> UndoOutcome? {
        guard redo ? canRedo : canUndo else { return nil }
        closeGroup()
        return await route.replay(in: historyID, redo: redo)
    }
}
