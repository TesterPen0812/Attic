import AppKit
import Foundation
import SwiftData

/// Workspace ordering and retention use UndoRoute's existing cursor and limits.
/// NoteUndoHistory is an attributed-payload adapter while attached here.
@MainActor
final class WorkspaceHistory {
    @MainActor
    final class TextGroup {
        var adapter: NoteUndoHistory
        var payloads: [NoteUndoHistory.Op]
        init(adapter: NoteUndoHistory, payload: NoteUndoHistory.Op) {
            self.adapter = adapter; payloads = [payload]
        }
        var attachmentIDs: Set<UUID> { adapter.attachmentIDs(in: payloads) }
        func replay(redo: Bool) -> UndoOutcome {
            guard adapter.workspace?.currentAdapter === adapter else { return .failed }
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
        let completion: () async -> Void
        init(envelope: WorkspaceOperationEnvelope,
             text: (NoteUndoHistory, NoteUndoHistory.PreparedReplay)? = nil,
             textDocument: (noteID: UUID, content: Data)? = nil,
             stage: @escaping (ModelContext) throws -> Void,
             publication: WorkspaceOperationCoordinator.Publication = .init(), completion: @escaping () async -> Void = {}) {
            self.envelope = envelope; self.text = text; self.textDocument = textDocument
            self.stage = stage; self.publication = publication
            self.completion = completion
        }
    }

    let id = UUID()
    unowned let route: UndoRoute
    private(set) var historyID: UndoHistoryID
    private(set) var pendingReplayID: UUID?
    private(set) var pendingCommandID: UUID?
    private var inputReserved = false
    var isInputReserved: Bool { inputReserved }
    var hasPendingPublication: Bool { pendingReplayID != nil || pendingCommandID != nil }
    private(set) var permitsUnsavedDraft = false
    var hasNewerPublicationDraft: Bool { !deferredText.isEmpty }
    var deferredAttachmentIDs: Set<UUID> {
        deferredText.reduce(into: []) { $0.formUnion($1.0.attachmentIDs(in: [$1.1])) }
    }
    private var deferredText: [(NoteUndoHistory, NoteUndoHistory.Op)] = []
    private var resolvingDeferredInput = false
    private weak var pendingCoordinator: WorkspaceOperationCoordinator?
    private var retryTask: Task<Void, Never>?
    private var retryInFlight = false
    private var publicationInstalled = false
    private var fallbackBranchesStoredResult = false
    private var pendingCompletion: (() async -> Void)?
    private var completingPublication = false
    private final class WeakHistory {
        weak var value: WorkspaceHistory?
        init(_ value: WorkspaceHistory) { self.value = value }
    }
    private var recoveryPeers: [WeakHistory] = []
    private weak var recoveryLeader: WorkspaceHistory?
    private var queuedInput: [() -> Void] = []
    enum TypedInput { case text(String), newline }
    private var queuedTyping: [TypedInput] = []
    var hasQueuedTyping: Bool { !queuedTyping.isEmpty }
    private var announcedInputRefusal = false
    private final class WeakAdapter {
        weak var value: NoteUndoHistory?
        init(_ value: NoteUndoHistory) { self.value = value }
    }
    private var adapters: [WeakAdapter] = []
    private(set) var rebindSourceReadCount = 0
    private(set) weak var currentAdapter: NoteUndoHistory?

    init(route: UndoRoute, historyID: UndoHistoryID) {
        self.route = route; self.historyID = historyID
    }
    deinit { retryTask?.cancel() }
    var canUndo: Bool { !completingPublication && pendingReplayID == nil && pendingCommandID == nil && !inputReserved && route.canUndo(in: historyID) }
    var canRedo: Bool { !completingPublication && pendingReplayID == nil && pendingCommandID == nil && !inputReserved && route.canRedo(in: historyID) }
    var undoName: String { route.undoName(in: historyID) ?? "" }
    var redoName: String { route.redoName(in: historyID) ?? "" }

    func attach(_ adapter: NoteUndoHistory) {
        guard adapter.workspace !== self else { return }
        precondition(adapter.workspace == nil, "One workspace owns an editor adapter")
        let existing = adapter.undoOps
        precondition(adapter.redoOps.isEmpty, "Attach before editing or replay")
        adapter.reset()
        adapter.workspace = self
        // Preserve text entries through an editor/projection replacement.
        // Groups outside the shared suffix stay dormant until their form
        // returns (e.g. the ordinary title before Make Task from Note).
        let target = Array(adapter.storage.string.utf16)
        var sources: [ObjectIdentifier: (minimum: Int, delta: Int, matches: Bool)] = [:]
        for step in route.steps(in: historyID, redo: false) + route.steps(in: historyID, redo: true) {
            guard let group = step.workspacePayload, group.adapter !== adapter, group.adapter.noteID == adapter.noteID else { continue }
            let key = ObjectIdentifier(group.adapter)
            let source: (minimum: Int, delta: Int, matches: Bool)
            if let cached = sources[key] { source = cached }
            else {
                rebindSourceReadCount += 1
                let text = Array(group.adapter.storage.string.utf16)
                var shared = 0
                while shared < min(text.count, target.count), text[text.count - shared - 1] == target[target.count - shared - 1] { shared += 1 }
                source = (text.count - shared, target.count - text.count, shared > 0 || text == target)
                sources[key] = source
            }
            guard source.matches else { continue }
            if NoteUndoHistory.transfer(group.payloads, from: source.minimum, by: source.delta) { group.adapter = adapter }
        }
        currentAdapter = adapter
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
    /// A failed publication owns the old cursor until it resolves. New
    /// writing is kept in the draft without invalidating that cursor.
    func recordInput(_ op: NoteUndoHistory.Op, from adapter: NoteUndoHistory) {
        if (permitsUnsavedDraft && hasPendingPublication) || resolvingDeferredInput {
            deferredText.append((adapter, op))
            route.onOwnershipChanged?()
        } else { capture(op, from: adapter) }
    }
    func payloads(for adapter: NoteUndoHistory, redo: Bool) -> [NoteUndoHistory.Op] {
        let steps = route.steps(in: historyID, redo: redo)
        let ordered = redo ? steps.reversed().map { $0 } : steps
        return ordered.compactMap(\.workspacePayload).filter { $0.adapter === adapter }.flatMap(\.payloads)
            + (redo ? [] : deferredText.filter { $0.0 === adapter }.map(\.1))
    }
    func checkpoint() -> UndoRoute.Checkpoint { closeGroup(); return route.checkpoint(in: historyID) }
    func rewind(to checkpoint: UndoRoute.Checkpoint) { route.rewind(to: checkpoint); closeGroup() }
    func clear() { route.clear(historyID); closeGroup() }

    /// Reserve before capturing a command candidate. Input arriving while
    /// journal IO runs is delivered exactly once after installation or abort.
    func reserveInput() -> Bool {
        guard !completingPublication, !inputReserved, pendingReplayID == nil, pendingCommandID == nil,
              currentAdapter?.canPrepareWorkspaceCommand != false else { return false }
        closeGroup(); announcedInputRefusal = false; publicationInstalled = false
        fallbackBranchesStoredResult = false; inputReserved = true; return true
    }
    /// Values, never an old selection or a retained native view. The new
    /// editor receives these at the selection installed by the operation.
    func queueTyping(_ input: TypedInput) -> Bool {
        guard isInputReserved else { return false }
        queuedTyping.append(input)
        requestPublicationRetry()
        return true
    }
    func shouldAnnounceInputRefusal() -> Bool {
        requestPublicationRetry()
        guard !announcedInputRefusal else { return false }
        announcedInputRefusal = true
        return true
    }
    func inputClientDidAttach() {
        guard !isInputReserved, !queuedTyping.isEmpty,
              let adapter = currentAdapter, let view = adapter.textView as? NoteEditorTextView,
              view.engine?.isReadOnly == false, !view.isSuspended else { return }
        let input = queuedTyping; queuedTyping.removeAll()
        let range = view.selectedRange(), length = adapter.storage.length
        if range.location == NSNotFound || NSMaxRange(range) > length {
            view.setSelectedRange(NSRange(location: length, length: 0))
        }
        adapter.beginGroup()
        defer { adapter.endTypingGroup() }
        for event in input {
            switch event {
            case let .text(text): view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            case .newline: view.insertNewline(nil)
            }
        }
    }
    func submitInput(_ edit: @escaping () -> Void) {
        if isInputReserved { queuedInput.append(edit); requestPublicationRetry() }
        else { edit() }
    }
    func releaseInput() {
        guard pendingReplayID == nil, pendingCommandID == nil else { return }
        inputReserved = false
        let input = queuedInput; queuedInput.removeAll()
        for edit in input { edit() }
        inputClientDidAttach()
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
            let preparedText = plan.text
            let noPresentation = plan.publication.steps.isEmpty
            let install: @MainActor (UUID) throws -> Void = { [weak self] _ in
                guard let self else { return }
                if !self.hasNewerPublicationDraft, let (adapter, text) = preparedText,
                   !adapter.installReplay(text) { throw WorkspaceFoundationError.conflict }
                if !self.hasNewerPublicationDraft, preparedText != nil || noPresentation { self.didPublishExternalForm() }
            }
            let publication = WorkspaceOperationCoordinator.Publication(steps: [{ _ in try commitCursor() }, install] + self.trackedPublicationSteps(plan.publication.steps))
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
            case .committed:
                await self.finishPresentation(plan.completion)
                return .applied
            case .publicationPending, .unknown:
                self.pendingReplayID = plan.envelope.id
                self.pendingCompletion = plan.completion
                self.beginPublicationRecovery(using: coordinator)
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
        let completion: () async -> Void
        init(entryID: UUID, envelope: WorkspaceOperationEnvelope, sessionValid: @escaping () -> Bool = { true },
             stage: @escaping (ModelContext) throws -> Void, record: @escaping (UUID, UUID) -> Void,
             publication: WorkspaceOperationCoordinator.Publication = .init(), completion: @escaping () async -> Void = {}) {
            self.entryID = entryID; self.envelope = envelope; self.sessionValid = sessionValid
            self.stage = stage; self.record = record; self.publication = publication
            self.completion = completion
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
        let record = plan.record, entry = plan.entryID, noPresentation = plan.publication.steps.isEmpty
        let publication = WorkspaceOperationCoordinator.Publication(steps: [{ [weak self] operation in
            record(operation, entry)
            if noPresentation { self?.didPublishExternalForm() }
        }] + trackedPublicationSteps(plan.publication.steps))
        let outcome = await coordinator.execute(plan.envelope, sessionValid: plan.sessionValid,
            stage: plan.stage, publication: publication)
        if outcome == .publicationPending || outcome == .unknown {
            pendingCommandID = plan.envelope.id
            pendingCompletion = plan.completion
            beginPublicationRecovery(using: coordinator)
        } else if outcome == .committed {
            await finishPresentation(plan.completion)
        }
        return outcome
    }

    func retryPublication(using coordinator: WorkspaceOperationCoordinator) async -> Bool {
        guard !retryInFlight, let operation = pendingReplayID ?? pendingCommandID else { return false }
        // The sleeping timer is weak; an in-flight retry keeps its cursor's
        // owner alive until post-await publication and draft history finish.
        let routeOwner = route
        defer { withExtendedLifetime(routeOwner) {} }
        retryInFlight = true
        defer { retryInFlight = false }
        var outcome = await coordinator.retryPublication(operation)
        if outcome == .conflict { outcome = coordinator.settledPublication(operation) }
        guard outcome == .committed || outcome == .notCommitted else { return false }
        let peers = recoveryPeers.compactMap(\.value); recoveryPeers.removeAll()
        for peer in peers { await peer.completeRecovery(outcome) }
        await completeRecovery(outcome)
        return true
    }
    private func completeRecovery(_ outcome: WorkspaceOperationCoordinator.Outcome) async {
        resolvingDeferredInput = true
        let branched = hasNewerPublicationDraft
        let conflict = branched && fallbackBranchesStoredResult && outcome == .committed
        pendingReplayID = nil; pendingCommandID = nil
        retryTask?.cancel(); retryTask = nil; pendingCoordinator = nil
        recoveryLeader = nil
        permitsUnsavedDraft = false; inputReserved = false
        let completion = pendingCompletion; pendingCompletion = nil
        if outcome == .committed, let completion { await finishPresentation(completion) }
        if conflict { recordExternalBarrier(origin: "the saved workspace operation") }
        let text = deferredText
        for (adapter, op) in text { capture(op, from: adapter) }
        deferredText.removeAll()
        resolvingDeferredInput = false
        route.onOwnershipChanged?()
        currentAdapter?.onWorkspaceRecoveryChanged?(false, false, conflict)
        releaseInput()
    }
    /// A family purge has one coordinator operation and one retry owner,
    /// even when several open note workspaces share its reservation.
    func trackExternalOperation(_ operation: UUID, using coordinator: WorkspaceOperationCoordinator,
                                peers: [WorkspaceHistory], installed: Bool,
                                completion: @escaping () async -> Void) {
        pendingCommandID = operation; pendingCompletion = completion
        publicationInstalled = installed
        recoveryPeers = peers.filter { $0 !== self }.map(WeakHistory.init)
        for peer in recoveryPeers.compactMap(\.value) {
            peer.pendingCommandID = operation; peer.pendingCoordinator = coordinator
            peer.publicationInstalled = installed; peer.recoveryLeader = self
            peer.currentAdapter?.onWorkspaceRecoveryChanged?(true, false, false)
        }
        beginPublicationRecovery(using: coordinator)
    }
    func didPublishExternalForm() {
        publicationInstalled = true
        if !hasNewerPublicationDraft { fallbackBranchesStoredResult = false }
    }
    private func finishPresentation(_ completion: () async -> Void) async {
        completingPublication = true
        defer { completingPublication = false }
        releaseInput()
        await completion()
    }
    private func trackedPublicationSteps(_ steps: [@MainActor (UUID) throws -> Void]) -> [@MainActor (UUID) throws -> Void] {
        let last = steps.count - 1
        return steps.enumerated().map { index, step in
            { [weak self] operation in
                try step(operation)
                if index == last { self?.didPublishExternalForm() }
            }
        }
    }
    private func beginPublicationRecovery(using coordinator: WorkspaceOperationCoordinator) {
        pendingCoordinator = coordinator
        currentAdapter?.onWorkspaceRecoveryChanged?(true, false, false)
        schedulePublicationRetry(after: .milliseconds(250))
    }
    func requestPublicationRetry() {
        if let recoveryLeader { recoveryLeader.requestPublicationRetry(); return }
        guard hasPendingPublication, !retryInFlight else { return }
        retryTask?.cancel(); retryTask = nil
        schedulePublicationRetry(after: .zero)
    }
    private func schedulePublicationRetry(after delay: Duration) {
        guard retryTask == nil, hasPendingPublication else { return }
        retryTask = Task { [weak self, weak pendingCoordinator] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, let pendingCoordinator, !Task.isCancelled else { return }
            self.retryTask = nil
            if await self.retryPublication(using: pendingCoordinator) { return }
            guard self.hasPendingPublication else { return }
            // Keep the operation envelope and owner holds, but stop blocking
            // the person's draft when storage cannot finish publication.
            self.permitUnsavedDraft()
            self.recoveryPeers.compactMap(\.value).forEach { $0.permitUnsavedDraft() }
            self.schedulePublicationRetry(after: .seconds(1))
        }
    }
    private func permitUnsavedDraft() {
        guard !permitsUnsavedDraft else { return }
        permitsUnsavedDraft = true
        fallbackBranchesStoredResult = !publicationInstalled
        inputReserved = false
        currentAdapter?.onWorkspaceRecoveryChanged?(true, true, false)
        let input = queuedInput; queuedInput.removeAll()
        for edit in input { edit() }
        inputClientDidAttach()
    }
    /// Applied changes from another surface have one originating history.
    /// This history names that origin and stops without running an inverse.
    func recordExternalBarrier(origin: String) {
        closeGroup()
        route.record(UndoStep(name: "Edited by \(origin): can't undo past this",
            undoOutcome: { .failed }, redoOutcome: { .failed }), in: historyID)
    }
    /// Toasts retain a concrete entry identity; a later entry removes their
    /// authority. Native responder/menu binding belongs to slice 0b.
    func undoLatest(stepID: UUID) async -> UndoOutcome? {
        guard route.undoStepID(in: historyID) == stepID else { return nil }
        return await replay(redo: false)
    }
    @discardableResult func undo() -> Bool { closeGroup(); return canUndo && route.undo(in: historyID) }
    @discardableResult func redo() -> Bool { closeGroup(); return canRedo && route.redo(in: historyID) }
    func replay(redo: Bool) async -> UndoOutcome? {
        guard redo ? canRedo : canUndo else { return nil }
        closeGroup()
        return await route.replay(in: historyID, redo: redo)
    }
}
