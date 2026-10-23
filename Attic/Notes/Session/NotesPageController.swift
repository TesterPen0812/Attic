import AppKit
import Combine
import CryptoKit
import SwiftData
import UniformTypeIdentifiers

enum NoteStatusItem: Equatable {
    case couldntFinishSaving
    case onlyInMemory(String), notSaved(String), changedElsewhere, deletedElsewhere
    case proposal(String), deletionProposal(String), editedBy(String, Date), importing, notice(NoteNotice), readOnly(String)

    var label: String {
        switch self {
        case .couldntFinishSaving: String(localized: "Couldn't finish saving")
        case .onlyInMemory: String(localized: "Only in memory")
        case .notSaved: String(localized: "Not saved")
        case .changedElsewhere: String(localized: "Changed elsewhere")
        case .deletedElsewhere: String(localized: "Deleted elsewhere")
        case let .proposal(agent): "\(agent) has changes"
        case let .deletionProposal(agent): "Deleted by \(agent)"
        case let .editedBy(agent, date): "\(agent) edited \(date.formatted(date: .omitted, time: .shortened))"
        case .importing: String(localized: "Adding files")
        case let .notice(message): message.kind.headline
        case .readOnly: String(localized: "Read only")
        }
    }

    var explanation: String? {
        switch self {
        case .couldntFinishSaving: String(localized: "Your writing is kept here. Retry to finish saving the workspace change; you can keep writing in the unsaved draft.")
        case let .onlyInMemory(reason), let .notSaved(reason), let .readOnly(reason): reason
        case let .notice(notice): notice.detail
        case .changedElsewhere: String(localized: "This note changed outside this editor. Your text is kept in recovery.")
        case .deletedElsewhere: String(localized: "This note was deleted elsewhere. Your text is kept in recovery. Keep as new note to save it under a new ID.")
        case .proposal: String(localized: "An agent suggested changes to this note.")
        case .deletionProposal: String(localized: "Deletion is waiting for your review. Your text is still here; Restore keeps this note, or Save as New Note keeps a separate copy.")
        case .editedBy: String(localized: "This outside edit is saved. Undo stops at the outside edit; the previous text is kept in Version History.")
        case .importing: String(localized: "Files are still being added to this note.")
        }
    }
}

/// Immutable comparison ticket: acceptance checks store bytes and the live draft again.
struct NoteProposalReview: Identifiable, Equatable {
    let id: UUID
    let sessionID: UUID
    let noteID: UUID
    let agent: String
    let createdAt: Date
    let isDeletion: Bool
    let current: NoteDocument
    let currentTags: [String]
    let proposed: NoteDocument
    let proposedPreview: NoteDocument
    let revision: String
    let savedContent: Data?
    let signature: NoteProposalSignature

    var workspaceIntent: AgentWorkspaceIntent? = nil
    var workspaceReadSet: AgentWorkspaceReadSet? = nil

    var summary: String {
        if let workspaceIntent { return workspaceIntent.summary }
        if isDeletion { return "The whole note would move to Recently Deleted." }
        let changed = zip(current.blocks, proposed.blocks).filter { $0 != $1 }.count
        let removed = max(0, current.blocks.count - proposed.blocks.count)
        return "\(changed) blocks changed · \(removed) removed"
    }
}

private struct DamagedNoteRecovery: Error {}

struct NoteImportProgress: Equatable {
    let batchID: UUID
    let noteID: UUID
    let completed: Int
    let total: Int
    let copiedBytes: Int64
    let names: [String]
}

fileprivate struct NoteImportBatch {
    let id: UUID
    let urls: [URL]
    let acceptedText: String
    var completed = 0
    var loaded: [NoteImportedObject]? = nil
}

/// One open note: its engine (text, undo, staged images) and where it
/// stands against the store. Lives outside any view.
@MainActor
final class NoteSession: ObservableObject, Identifiable {
    enum ConflictKind: Equatable { case changed, deleted }
    enum State: Equatable {
        case untouched, clean, dirty, notSaved(String), onlyInMemory(String)
        case conflict(ConflictKind), readOnly
    }
    nonisolated let id = UUID()
    /// The note's id (a new note's reserved id until its first save).
    @Published private(set) var noteID: UUID
    @Published fileprivate(set) var isPersisted: Bool
    fileprivate(set) var baseRevisionID: UUID?
    /// Saved bytes also identify same-token changes imported by a fresh context.
    fileprivate var baseContent: Data?
    /// The tags the store holds for this note (as loaded or last saved). A
    /// save writes the engine's tags only when they differ.
    fileprivate(set) var baseTags: [String] = []
    @Published private(set) var engine: NoteEditorEngine
    @Published fileprivate(set) var workspacePublicationPending = false
    var isItemDeleted = false
    fileprivate(set) var readOnlyReason: NoteReadOnlyReason?
    /// A readable checkpoint with unavailable placements. Its display ID is
    /// separate from the original owner; it can never replace that saved note.
    let recoverySourceNoteID: UUID?
    @Published fileprivate(set) var state: State {
        didSet {
            if case .conflict = state, state != oldValue { invalidateCallbacks() }
            engine.setWritingToolsAvailable(NoteSessionPolicy.writingToolsAvailable(state,
                activity: engine.activity, refusedSinceLastStoreSave: refusedWritingToolsSinceSave,
                hasMarkedText: engine.textView?.hasMarkedText() == true))
        }
    }
    struct CallbackStamp {
        let noteID: UUID
        let engineID: ObjectIdentifier
        let binding: UInt64
        let draft: UInt64
        let revision: UUID?
    }
    private var bindingGeneration: UInt64 = 0
    var usesWorkspaceBinding = false
    weak var workspacePage: WorkspacePageSession?
    /// Closed native task-note regions share this session's cache lifetime.
    /// No lease, controller, timer or second draft is retained here.
    var taskNotePresentation: TaskNoteWarmPresentation?
    var callbackStamp: CallbackStamp {
        .init(noteID: noteID, engineID: ObjectIdentifier(engine), binding: bindingGeneration,
              draft: editGeneration, revision: baseRevisionID)
    }
    func hasSameBinding(_ stamp: CallbackStamp) -> Bool {
        stamp.noteID == noteID && stamp.engineID == ObjectIdentifier(engine) && stamp.binding == bindingGeneration
    }
    func accepts(_ stamp: CallbackStamp, retainingNewerDraft: Bool = false) -> Bool {
        hasSameBinding(stamp) && stamp.revision == baseRevisionID
            && (retainingNewerDraft || stamp.draft == editGeneration)
    }
    func invalidateCallbacks() { bindingGeneration &+= 1 }
    fileprivate var editGeneration: UInt64 = 0
    /// Information for the slot (lowest priority), such as a refused change.
    @Published private(set) var noticeValue: NoteNotice?
    // Compatibility for clearing notices and full-detail recovery comparisons.
    // New producers supply their meaning through showNotice.
    var notice: String? {
        get { noticeValue?.detail }
        set { noticeValue = newValue.map { NoteNotice(kind: .notice, detail: $0) } }
    }
    func showNotice(_ notice: NoteNotice) { noticeValue = notice }
    fileprivate(set) var lastEditAt: Date?
    fileprivate(set) var selection = NSRange(location: 0, length: 0)
    fileprivate(set) var scrollOffset: CGFloat = 0
    @Published fileprivate var importBatch: NoteImportBatch?
    fileprivate var importTask: Task<Void, Never>?
    fileprivate var cancellingImport = false
    fileprivate var refusedWritingToolsSinceSave = false
    fileprivate var saveTask: Task<Void, Never>?
    fileprivate var durabilityTask: Task<Void, Never>?
    fileprivate var pauseTask: Task<Void, Never>?
    /// The recovery checkpoint this session wrote or adopted. Only its
    /// holder may replace or retire a checkpoint holding unsaved work.
    fileprivate var recoveryClaim: NoteRecoveryClaim?
    /// Verified bytes for this live document, separate from unsaved staging.
    /// Bounded by the document's admission limit and the session-cache limit.
    fileprivate var verifiedDocumentAttachments: [UUID: StagedNoteAttachment] = [:]

    fileprivate init(noteID: UUID, isPersisted: Bool, baseRevisionID: UUID?, engine: NoteEditorEngine,
                     readOnlyReason: NoteReadOnlyReason?, recoverySourceNoteID: UUID? = nil) {
        self.recoverySourceNoteID = recoverySourceNoteID
        self.noteID = noteID
        self.isPersisted = isPersisted
        self.baseRevisionID = baseRevisionID
        self.engine = engine
        self.readOnlyReason = readOnlyReason
        self.state = readOnlyReason != nil ? .readOnly : (isPersisted ? .clean : .untouched)
    }

    fileprivate func adopt(noteID: UUID) {
        invalidateCallbacks()
        self.noteID = noteID
        engine.noteID = noteID
    }

    fileprivate func replaceEngine(_ replacement: NoteEditorEngine) {
        invalidateCallbacks()
        engine.detachView()
        verifiedDocumentAttachments.removeAll()
        engine = replacement
    }

    var isReadOnly: Bool { readOnlyReason != nil || recoverySourceNoteID != nil }
    var isConflict: Bool { if case .conflict = state { true } else { false } }
    var isImporting: Bool { importBatch != nil }
    var importProgress: NoteImportProgress? {
        guard let batch = importBatch else { return nil }
        return NoteImportProgress(batchID: batch.id, noteID: noteID, completed: batch.completed,
            total: batch.urls.count,
            copiedBytes: (batch.loaded ?? []).compactMap(\.staged).reduce(0) { $0 + $1.byteCount },
            names: batch.urls.map(\.lastPathComponent))
    }

    /// Untouched: never saved, no text, no objects, no tags.
    var isUntouchedDraft: Bool {
        !isPersisted && importBatch == nil && engine.tags.isEmpty && Self.hasNoWriting(engine.document(), taskDraft: pendingTaskID != nil)
            && engine.objectIDs().isEmpty
    }

    /// Phase 3 lazy creation (UX plan § 2.1): a task's page with no note
    /// writes into this never-saved draft. Its first save creates the note,
    /// owned by this task, and the association in one gated transaction.
    var pendingTaskID: UUID?

    /// A task draft's first block is the title snapshot (§ 2.12), not
    /// writing: only the blocks after it count.
    static func hasNoWriting(_ document: NoteDocument, taskDraft: Bool) -> Bool {
        guard taskDraft else { return document.isEmpty }
        return document.blocks.dropFirst().allSatisfy { block in
            block.kind == .text && block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The tags to write with the next save: only a change the person made.
    var pendingTags: [String]? { engine.tags == baseTags ? nil : engine.tags }
}

/// The new Notes page's sessions (Phase 2): opening, creating, saving and
/// preserving notes, independent of views.
///
/// Contracts (critique finding 1; spec § Reliability):
/// - text is saved within `saveDelay` (300 ms) of the last edit; continuous
///   typing gets an independent five-second durability deadline using the
///   same prepared save path (or an owned checkpoint when writes are gated);
/// - hide, quit, page switch and navigation save or checkpoint pending work;
/// - before any navigation the draft is saved or checkpointed; if both fail
///   the session stays, marked "Only in memory", and navigation is refused;
/// - recovered drafts reopen before the normal opening rule;
/// - a never-saved draft with no content is discarded, nothing else is.
@MainActor
final class NotesPageController: ObservableObject {
    isolated deinit {
        for session in cache.values {
            session.saveTask?.cancel()
            session.durabilityTask?.cancel()
            session.pauseTask?.cancel()
        }
        versionHistoryCommandTask?.cancel()
        // Serialized recovery writes keep their owners until they finish.
        // Teardown must not abandon a checkpoint or an admitted import.
    }

    enum LeaveReason { case openNote, newNote, library, pageSwitch, hide, quit }
    @Published private(set) var active: NoteSession?
    @Published private(set) var historyBrowser: NoteHistoryBrowser?
    private struct VersionRestoreUndo {
        let id: UUID
        let noteID: UUID
        let versionID: UUID
        var restoredRevisionID: UUID
        let document: NoteDocument?
        let tags: [String]
        let historyPosition: [ObjectIdentifier]
        let session: NoteSession?
        let isUndo: Bool
    }
    private var versionRestoreUndo: VersionRestoreUndo?
    var versionRestoreUndoID: UUID? { versionRestoreUndo?.isUndo == true ? versionRestoreUndo?.id : nil }
    private(set) var versionHistoryCommandTask: Task<Void, Never>?
    private var isVersionRestoreReplaying = false
    /// The task page belongs to navigation, not its disposable SwiftUI
    /// container. Keep its single lease while Notes is behind another section.
    var taskNotePresenter: TaskNotePresenter?
    @Published var isLibraryPresented = false
    @Published private(set) var design: AtticDesignContext = .default
    @Published private(set) var recoveryWarnings: [String] = []
    @Published private(set) var workspaceRecoveryIssues: [WorkspaceOperationCoordinator.RecoveryIssue] = []
    private var damagedRecoveryWarnings = Set<String>()
    /// Moves on each `present()`: the page puts the keyboard back in the
    /// note (Notes reopens where you left it, caret included).
    @Published private(set) var presentationCount = 0
    /// Follows the undo route's revision, so menus that read the library's
    /// undo names redraw when a step is recorded, undone or dropped.
    @Published private(set) var undoRevision: UInt64 = 0

    let store: NoteStore
    let librarySummaries = NotesLibrarySummaryCache()
    /// Where All notes' actions are recorded (the app's route once
    /// `attachUndoRoute` runs; a private one until then, so tests and
    /// previews work alone).
    private(set) var undoRoute = UndoRoute()
    private var undoRevisionSubscription: AnyCancellable?
    private var purgeSubscription: AnyCancellable?
    let journal: NoteDraftJournaling?
    private let defaults: UserDefaults?
    private let saveDelay: Duration
    private let durabilityDelay: Duration
    private let pauseVersionDelay: Duration
    private let now: () -> Date
    let imageLoader: @Sendable (URL) async -> (StagedNoteAttachment, CGSize?)?
    private let decodeRecoveryDocument: @Sendable (Data) async -> NoteDocument?
    private var openRequestGeneration: UInt64 = 0
    private var isDuplicatingNote = false
    #if DEBUG
    /// Deterministic suspension boundary for source/navigation revalidation tests.
    var duplicateAttachmentWillVerify: ((UUID) async -> Void)?
    #endif
    private let decodeOpenDocument: @Sendable (Data) async -> (content: NoteContent, onMainThread: Bool)
    private(set) var coldDecodeCount = 0
    private(set) var coldDecodeOnMainCount = 0
    private let prepareDocument: @Sendable (NoteDocument) async -> PreparedNoteDocument?
    private var cache: [UUID: NoteSession] = [:]
    private var recency: [UUID] = []
    private struct ProposalStatus {
        let revision: UInt64
        let agent: String?
        let deletionAgent: String?
        let editID: UUID?
        let deletionID: UUID?
    }
    private var proposalStatusCache: [UUID: ProposalStatus] = [:]
    @Published var proposalReview: NoteProposalReview?
    @Published var proposalReviewNotice: String?
    private var verifiedAvailability: [UUID: (revision: UInt64, digest: String, available: Bool)] = [:]
    private var verifyingAvailability = Set<UUID>()
    private var resolvedAttachmentRows: [UUID: (revision: UInt64, row: NoteAttachment?)] = [:]
    private let cacheLimit = 8
    private var didStart = false
    private var startRequested = false
    private var didRecoverAtLaunch = false
    private var recoveryWork: Task<Void, Never>?
    private var stagingCollectionWork: Task<Void, Never>?
    private var stagingCollectionToken: UUID?
    private var recoveryLoading = false
    private var recoveryFailureCount = 0
    /// A verified retirement stays valid only until this note writes or adopts
    /// another checkpoint. Unrelated damaged entries do not invalidate it.
    private var retiredNoteIDs = Set<UUID>()
    private var checkpointKeys: [UUID: NoteDraftJournalEntry] = [:]
    private var verifiedCheckpointKeys: [UUID: NoteDraftJournalEntry] = [:]
    private var verifiedCheckpointOwners: [UUID: (generation: UInt64, claim: NoteRecoveryClaim)] = [:]

    /// Waits for durable recovery work; useful for headless callers and tests.
    /// Session replacement waits for this work; hide/page switch retain sessions.
    func waitForRecoveryWork() async {
        while let work = recoveryWork ?? stagingCollectionWork {
            await work.value
        }
    }

    func waitForImportWork() async {
        for session in cache.values { await session.importTask?.value }
        await waitForRecoveryWork()
    }
    func startAndWait() async { start(); await waitForRecoveryWork() }
    func preserveDurably(_ session: NoteSession) async -> Bool {
        // A task page can receive queued input while its close checkpoint is
        // in flight. Preserve the newest draft before releasing its lease.
        if session.usesWorkspaceBinding {
            let deadline = ContinuousClock.now + recoveryResponseTimeout
            let binding = session.callbackStamp
            repeat {
                guard await awaitRecoveryForUser() else { return false }
                let failures = recoveryFailureCount
                let result = preserve(session)
                let queued = recoveryWork != nil
                guard await awaitRecoveryForUser(), recoveryFailureCount == failures,
                      session.hasSameBinding(binding) else { return false }
                checkpointKeys[session.id] = nil
                if hasDurableCheckpoint(session)
                    || (result && !session.isImporting && !NoteSessionPolicy.hasPendingWork(session.state)) { return true }
                guard queued else { return false }
            } while ContinuousClock.now < deadline
            reportRecoveryRetentionWarning("Recovery data is still being saved. Try again when saving finishes.")
            return false
        }
        guard await awaitRecoveryForUser() else { return false }
        let failures = recoveryFailureCount
        let engine = session.engine, generation = session.editGeneration
        let result = preserve(session)
        guard await awaitRecoveryForUser() else { return false }
        let durable = recoveryFailureCount == failures && session.engine === engine
            && session.editGeneration == generation && (result || hasDurableCheckpoint(session))
        checkpointKeys[session.id] = nil
        return durable
    }
    func preserveAllDurably() async -> Bool {
        guard !undoRoute.hasQueuedWorkspaceTyping else { return false }
        if let active { captureViewState(active) }
        var ok = true
        for session in cache.values where NoteSessionPolicy.hasPendingWork(session.state) || session.isImporting {
            let saved = await preserveDurably(session); ok = saved && ok
        }
        return ok
    }
    private func hasDurableCheckpoint(_ session: NoteSession) -> Bool {
        if let source = session.recoverySourceNoteID, let claim = session.recoveryClaim {
            // A read-only recovery row has a separate display ID. Its original
            // claimed checkpoint, not a new copy under that ID, owns the draft.
            return (try? journal?.recoveryEntries().contains { item in
                guard case let .valid(entry, _, current) = item else { return false }
                return entry.noteID == source && current == claim
                    && NoteContentCodec.decode(entry.content).document == session.engine.document()
            }) == true
        }
        guard let owner = verifiedCheckpointOwners[session.id],
              session.recoveryClaim == owner.claim, session.editGeneration == owner.generation,
              var key = try? journalEntry(for: session,
            document: checkpointDocument(for: session)) else { return false }
        key.savedAt = .distantPast
        return verifiedCheckpointKeys[session.id] == key
    }
    private func hasDurableImportCheckpoint(_ session: NoteSession) -> Bool {
        guard session.recoveryClaim != nil, let saved = verifiedCheckpointKeys[session.id],
              let current = try? journalEntry(for: session, document: checkpointDocument(for: session)) else { return false }
        return saved.content == current.content && saved.tags == current.tags
            && saved.staged == current.staged && saved.pendingImport == current.pendingImport
            && saved.baseRevisionID == current.baseRevisionID
    }

    func prepareToLeaveDurably(_ reason: LeaveReason) async -> Bool {
        // Quit must prove all cached drafts durable before the shell releases them.
        if reason == .quit {
            guard await preserveAllDurably() else { return false }
        }
        let wasVisible = isPageVisible
        let result = await performAfterRecovery(requireDrainedRecovery: reason == .quit,
            finishAfterWrite: { self.prepareToLeave(reason, verifiedCheckpointsOnly: true) }) { prepareToLeave(reason) }
        // A successful earlier pass cannot authorize leaving newer work behind.
        let durable = result && (reason != .quit || journal?.requiresAsyncIO != true || cache.values.allSatisfy {
            $0.recoverySourceNoteID != nil || (!NoteSessionPolicy.hasPendingWork($0.state) && !$0.isImporting)
                || hasDurableCheckpoint($0)
        })
        // Queued hide/switch preservation may optimistically mark the page
        // hidden. A durable refusal must keep its original agent disposition.
        if !durable { isPageVisible = wasVisible }
        return durable
    }
    func newNoteDurably() async -> Bool {
        await performAfterRecovery(finishAfterWrite: { self.newNote(verifiedCheckpointsOnly: true) }) { newNote() }
    }
    var launchRecoveryCompleted: Bool { didRecoverAtLaunch }
    func recoverAtLaunchAndWait() async { recoverAtLaunch(); await waitForRecoveryWork() }

    func discardWorkspaceRecovery(_ issue: WorkspaceOperationCoordinator.RecoveryIssue) async throws {
        let coordinator = try WorkspaceLegacyBridge.coordinator(for: store.container)
        try await coordinator.discardOperationRecovery(issue)
        workspaceRecoveryIssues = coordinator.operationRecoveryIssues
    }

    func restoreWorkspaceRecoveryAsNewNote(_ issue: WorkspaceOperationCoordinator.RecoveryIssue) async throws -> UUID {
        guard let pre = issue.draft, let source = NoteContentCodec.decode(pre.content).document,
              source.isWritableByThisBuild else { throw WorkspaceFoundationError.damagedEnvelope }
        let coordinator = try WorkspaceLegacyBridge.coordinator(for: store.container)
        var bytes = try await coordinator.journal.operationRecoveryPayloads(issue)
        let wanted = Set(source.attachmentIDs).union(pre.pendingImport?.items.compactMap(\.stagedID) ?? [])
        let admission = try await coordinator.ownership.admit(wanted.union(pre.staged.map(\.id)))
        defer { admission.release() }
        for id in wanted where !bytes.contains(where: { $0.id == id }) {
            guard let payload = await store.verifiedAttachmentBytes(id) else { throw WorkspaceFoundationError.preparationFailed }
            bytes.append(payload)
        }
        var document = source
        if let pending = pre.pendingImport {
            let engine = makeEngine(noteID: UUID(), document: document, readOnly: false, staged: bytes,
                bodyOnly: source.requires.contains("taskNote"))
            engine.restoreImageImport(anchor: pending.anchor, replacementLength: pending.replacementLength ?? 0,
                isBoundary: pending.isBoundary ?? false)
            var items = pending.items.map { item -> NoteImportedObject in
                if let id = item.stagedID, let payload = bytes.first(where: { $0.id == id }) {
                    let size = item.pixelWidth.flatMap { width in item.pixelHeight.map { CGSize(width: width, height: $0) } }
                    return NoteImportedObject(staged: payload, pixelSize: size)
                }
                return NoteImportedObject(filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier,
                    byteCount: item.byteCount, failure: item.failure ?? String(localized: "Import interrupted. Retry this file."))
            }
            items += pending.remainingNames.map { NoteImportedObject(filename: $0, contentTypeIdentifier: UTType.data.identifier,
                byteCount: 0, failure: String(localized: "Import interrupted. Retry this file.")) }
            guard engine.insertImportedObjects(items, acceptedText: pending.acceptedText) else {
                throw WorkspaceFoundationError.preparationFailed
            }
            document = engine.document()
        }
        document = try document.ordinarySnapshot(title: document.title)
        guard let (copy, payloads) = replacementForDeletedNote(document, oldID: pre.noteID, staged: bytes) else {
            throw WorkspaceFoundationError.preparationFailed
        }
        let needed = Set(copy.attachmentIDs)
        let result = try store.createDocumentNote(id: UUID(), document: copy,
            staged: payloads.filter { needed.contains($0.id) }, tags: pre.tags).get()
        do { try await discardWorkspaceRecovery(issue) }
        catch { recoveryWarnings.append("The new note was saved, but its interrupted recovery copy is still kept for Review.") }
        return result.noteID
    }
    /// Library navigation prepares only document bytes. Full byte ownership
    /// hydration remains part of the existing explicit durable-open API.
    func openFromLibrary(noteID: UUID) async -> Bool {
        await openDecoded(noteID: noteID)
    }

    private func openDecoded(noteID: UUID) async -> Bool {
        if !didRecoverAtLaunch && journal?.requiresAsyncIO == true { recoverAtLaunch() }
        guard await awaitRecoveryForUser() else { return false }
        openRequestGeneration &+= 1
        let generation = openRequestGeneration
        var preparedLoad: NoteDocumentLoad?
        var preparedBytes: Data?
        if cache[noteID] == nil, let note = store.note(withID: noteID), note.usesDocumentFormat, let bytes = note.content {
            let revision = note.revisionID
            let decoded = await decodeOpenDocument(bytes)
            coldDecodeCount += 1
            if decoded.onMainThread { coldDecodeOnMainCount += 1 }
            guard !Task.isCancelled, generation == openRequestGeneration,
                  let current = store.note(withID: noteID), current.revisionID == revision,
                  current.content == bytes else { return false }
            preparedLoad = NoteDocumentLoad(noteID: noteID, content: decoded.content, revisionID: revision)
            preparedBytes = bytes
        }
        func stillCurrent() -> Bool {
            guard !Task.isCancelled, generation == openRequestGeneration else { return false }
            guard let preparedLoad else { return true }
            guard let current = store.note(withID: noteID) else { return false }
            return current.revisionID == preparedLoad.revisionID && current.content == preparedBytes
        }
        guard await performAfterRecovery(finishAfterWrite: {
            guard stillCurrent() else { return false }
            return self.open(noteID: noteID, verifiedCheckpointsOnly: true, preparedLoad: preparedLoad)
        }, {
            guard stillCurrent() else { return false }
            return open(noteID: noteID, preparedLoad: preparedLoad)
        }) else { return false }
        return true
    }

    func openDurably(noteID: UUID) async -> Bool {
        guard await openDecoded(noteID: noteID) else { return false }
        if let session = active {
            let engine = session.engine
            // Text-only sessions have no bytes to hydrate. Inspect the
            // attachment attribute instead of extracting all paragraphs.
            // A refused Writing Tools rewrite still uses its safety snapshot.
            if engine.activity == .idle,
               !engine.rangeContainsObject(NSRange(location: 0, length: engine.textStorage.length)) {
                session.verifiedDocumentAttachments.removeAll()
                return true
            }
            // Live sessions own the bytes used by synchronous copy/paste and
            // Undo; store-cache eviction cannot turn objects into plain text.
            let document = engine.checkpointDocument()
            let bytes = await performBoundedUserIO(completedAction: true) { [self] in
                var verified: [UUID: StagedNoteAttachment] = [:]
                for id in document.attachmentIDs {
                    if let item = await store.verifiedAttachmentBytes(id) { verified[id] = item }
                }
                return verified
            }
            if let bytes, session.engine === engine {
                let liveIDs = Set(engine.checkpointDocument().attachmentIDs)
                session.verifiedDocumentAttachments = bytes.filter { liveIDs.contains($0.key) }
            }
        }
        return true
    }
    func keepAsNewNoteDurably() async -> Bool {
        guard await awaitRecoveryForUser() else { return false }
        guard let session = active else { return false }
        let document = checkpointDocument(for: session)
        guard let stored = await performBoundedUserIO({ [self] in
            Array(await durableAttachmentsAsync(in: document).values)
        }), active === session, checkpointDocument(for: session) == document else { return false }
        return await performAfterRecovery { keepAsNewNote(stored: stored) }
    }
    func deleteNoteDurably(noteID: UUID) async -> Bool {
        // removeNote proves this note's retirement and store save itself.
        // A different session's failed checkpoint cannot change that outcome.
        await performAfterRecovery(reportCompletedAction: true) { deleteNote(noteID: noteID) }
    }

    private func performAfterRecovery(requireDrainedRecovery: Bool = false, reportCompletedAction: Bool = false,
                                      finishAfterWrite: (() -> Bool)? = nil, _ operation: () -> Bool) async -> Bool {
        guard await awaitRecoveryForUser() else { return false }
        let failures = recoveryFailureCount
        let first = operation()
        let pending = recoveryWork != nil
        let firstWait = await awaitRecoveryForUser(completedAction: first && !requireDrainedRecovery)
        guard firstWait else { return first && !requireDrainedRecovery }
        guard reportCompletedAction || recoveryFailureCount == failures else { return false }
        guard !first, pending else { return first }
        let second = operation()
        let secondWait = await awaitRecoveryForUser(completedAction: second && !requireDrainedRecovery)
        guard secondWait else { return second && !requireDrainedRecovery }
        guard reportCompletedAction || recoveryFailureCount == failures else { return false }
        // The final write may have succeeded after the operation queued it.
        // Prove current durability without consuming a ticket or queuing again.
        return second || (finishAfterWrite?() ?? false)
    }

    /// Waiting never cancels the serialized write or releases its live owners.
    /// A slow disk returns control with guidance; the same action can be retried.
    var recoveryResponseTimeout: Duration = .seconds(2)
    /// The functional ordering test can pause this read; production uses the real clock.
    var recoveryClockNow: () -> ContinuousClock.Instant = { .now }
    var recoveryWaitDidStart: (() -> Void)?
    /// Deterministic ordering seams; unset in the app.
    var recoveryWaitDidDrain: (() async -> Void)?
    var importCheckpointWillResume: (() async -> Void)?
    private func awaitRecoveryForUser(completedAction: Bool = false) async -> Bool {
        let deadline = recoveryClockNow() + recoveryResponseTimeout
        let hadPendingWork = recoveryWork != nil
        if hadPendingWork { recoveryWaitDidStart?() }
        while recoveryWork != nil {
            guard recoveryClockNow() < deadline, !Task.isCancelled else {
                reportRecoveryRetentionWarning(completedAction
                    ? "Recovery data is still being saved."
                    : "Recovery data is still being saved. Try again when saving finishes.",
                    kind: .stillSaving, severity: completedAction ? .progress : .information)
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if hadPendingWork { await recoveryWaitDidDrain?() }
        clearPendingRecoveryWarnings()
        return true
    }

    private func clearPendingRecoveryWarnings() {
        let messages: Set<String> = ["Recovery data is still being saved.",
            "Recovery data is still being saved. Try again when saving finishes."]
        recoveryWarnings.removeAll { messages.contains($0) }
        for session in cache.values where session.notice.map(messages.contains) == true { session.notice = nil }
    }

    /// Attachment reads are cancellable, unlike an in-flight checkpoint write.
    /// A bounded response must also cover hydration and Keep as New's copy.
    private func performBoundedUserIO<T: Sendable>(completedAction: Bool = false, _ action: @escaping @MainActor () async -> T) async -> T? {
        var result: T?
        var finished = false
        let message = completedAction ? "Attachment data is still being read."
            : "Attachment data is still being read. Try again when loading finishes."
        func clearWarning() {
            recoveryWarnings.removeAll { $0 == message }
            for session in cache.values where session.notice == message { session.notice = nil }
        }
        let task = Task { @MainActor in
            result = await action()
            finished = true
            clearWarning()
        }
        let deadline = ContinuousClock.now + recoveryResponseTimeout
        while !finished {
            guard ContinuousClock.now < deadline, !Task.isCancelled else {
                task.cancel()
                reportRecoveryRetentionWarning(message, kind: .stillReading, severity: completedAction ? .progress : .information)
                return nil
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        clearWarning()
        return result
    }

    private func queueRecoveryWork(_ action: @escaping @MainActor () async -> Void) {
        let prior = recoveryWork
        let token = UUID()
        recoveryWorkToken = token
        recoveryWork = Task { @MainActor [weak self] in
            await prior?.value
            await action()
            if self?.recoveryWorkToken == token {
                self?.recoveryWork = nil
                self?.clearPendingRecoveryWarnings()
            }
        }
    }
    private var recoveryWorkToken: UUID?

    private var newestRecovered: NoteSession?
    private var isPageVisible = false
    /// New Note from the menu bar before the page first appeared: honoured
    /// by `start()` (after a recovered draft, which always opens first).
    private var pendingNewNote = false
    private static let lastViewedKey = "notes.lastViewedNote.v2"

    private static func viewStateKey(_ id: UUID) -> String { "notes.viewState.\(id.uuidString)" }

    init(store: NoteStore, journal: NoteDraftJournaling?, defaults: UserDefaults? = nil,
         saveDelay: Duration = .milliseconds(300), durabilityDelay: Duration = .seconds(5), pauseVersionDelay: Duration = .seconds(120),
         now: @escaping () -> Date = Date.init,
         imageLoader: @escaping @Sendable (URL) async -> (StagedNoteAttachment, CGSize?)? = { url in
             await NotesPageController.loadImageFile(url)
         },
         prepareDocument: @escaping @Sendable (NoteDocument) async -> PreparedNoteDocument? = { document in
             await Task.detached { try? PreparedNoteDocument(document) }.value
         },
         decodeOpenDocument: @escaping @Sendable (Data) async -> (content: NoteContent, onMainThread: Bool) = { bytes in
             await Task.detached(priority: .userInitiated) { (NoteContentCodec.decode(bytes), Thread.isMainThread) }.value
         },
         decodeRecoveryDocument: @escaping @Sendable (Data) async -> NoteDocument? = { bytes in
             await Task.detached(priority: .userInitiated) { NoteContentCodec.decode(bytes).document }.value
         }) {
        self.store = store
        self.journal = journal
        self.defaults = defaults
        self.saveDelay = saveDelay
        self.durabilityDelay = durabilityDelay
        self.pauseVersionDelay = pauseVersionDelay
        self.now = now
        self.imageLoader = imageLoader
        self.prepareDocument = prepareDocument
        self.decodeRecoveryDocument = decodeRecoveryDocument
        self.decodeOpenDocument = decodeOpenDocument
        if let diskJournal = journal?.workspaceJournal {
            diskJournal.liveReferencedIDs = { [weak self] in
                Set(self?.cache.values.flatMap { Array($0.engine.staged.keys) + (self?.liveAttachmentIDs(in: $0) ?? []) } ?? [])
            }
        }
        attachUndoRoute(undoRoute)
        (try? WorkspaceLegacyBridge.coordinator(for: store.container))?.lifecycleNotes = self
        purgeSubscription = store.purgedNoteIDs.sink { [weak self] ids in self?.forgetPurgedSnapshots(ids) }
        store.agentWriteDisposition = { [weak self] id in
            self?.agentDisposition(for: id) ?? .direct
        }
        store.recoveryReferencedAttachmentIDs = { [weak self, journal] in
            // One live-byte rule for purge: every checkpoint, open draft,
            // pending payload and both sides of editor history own bytes.
            var ids = Set(self?.cache.values.flatMap { self?.liveAttachmentIDs(in: $0) ?? [] } ?? [])
            guard let journal else { return ids }
            let entries: [NoteDraftRecoveryEntry]
            do { entries = try journal.recoveryEntries() }
            catch {
                self?.reportRecoveryRetentionWarning("Recovery copies could not be checked. Removed images are being kept until they can be checked.")
                throw error
            }
            do { ids.formUnion(try Self.recoveryAttachmentIDs(in: entries)) }
            catch {
                self?.reportRecoveryRetentionWarning("A damaged recovery copy is keeping removed images safe until it is repaired.")
                throw error
            }
            return ids
        }
        store.recoveryReferencedAttachmentIDsDurably = { [weak self, journal] in
            // A live controller also owns unsaved session attachments. Its
            // existing synchronous authority includes those without disk IO.
            if let self { return try self.store.recoveryReferencedAttachmentIDs() }
            guard let journal else { return [] }
            return try Self.recoveryAttachmentIDs(in: try await journal.readRetentionEntries())
        }
        store.recoveryProtectedRevisionIDs = { [weak self] in
            guard let journal = self?.journal else { return [] }
            let entries = try journal.recoveryEntries()
            var bases = Set<UUID>()
            for item in entries {
                guard case let .valid(entry, _, _) = item else { throw DamagedNoteRecovery() }
                if let base = entry.baseRevisionID { bases.insert(base) }
            }
            return bases
        }
        // Retention is used by Settings before the Notes page is presented.
        // Warm recovery ownership once at startup without activating a page.
        if journal?.requiresAsyncIO == true { recoverAtLaunch() }
    }

    private static func recoveryAttachmentIDs(in entries: [NoteDraftRecoveryEntry]) throws -> Set<UUID> {
        var ids = Set<UUID>()
        for item in entries {
            guard case let .valid(entry, _, _) = item,
                  let document = NoteContentCodec.decode(entry.content).document else { throw DamagedNoteRecovery() }
            ids.formUnion(document.attachmentIDs)
            ids.formUnion(entry.staged.map(\.id))
            ids.formUnion(entry.pendingImport?.items.compactMap(\.stagedID) ?? [])
        }
        return ids
    }

    func refreshRecoveryWarningsAfterResolution() async {
        guard let journal else { return }
        do {
            if let diskJournal = journal.workspaceJournal,
               let coordinator = try? WorkspaceLegacyBridge.coordinator(for: store.container), coordinator.journal === diskJournal {
                try await coordinator.reconcileStartup()
            }
            let remaining = try await journal.listDamagedDurably()
            recoveryWarnings.removeAll { damagedRecoveryWarnings.contains($0) }
            damagedRecoveryWarnings = Set(remaining.map { "Recovery data is damaged: \($0.confirmation.checkpointFilename)." })
            recoveryWarnings += damagedRecoveryWarnings.sorted()
        } catch { reportRecoveryRetentionWarning(error.localizedDescription) }
    }

    private func reportRecoveryRetentionWarning(_ warning: String, kind: NoteNotice.Kind = .copyKept,
                                                severity: NoteNotice.Severity? = nil) {
        if !recoveryWarnings.contains(warning) { recoveryWarnings.append(warning) }
        active?.showNotice(NoteNotice(kind: kind, severity: severity, detail: warning))
    }

    private struct LiveByteInventory {
        let staged: [StagedNoteAttachment]
        let references: Set<UUID>
        let pendingImport: NoteDraftJournalEntry.PendingImport?
    }

    /// Shared ownership rule for checkpoints, exported recovery, purge and
    /// the Recently Deleted row lifecycle. A byte is live while a current
    /// document, pending source, staged draft or Undo/Redo side can reach it.
    private func liveByteInventory(in session: NoteSession, document: NoteDocument) -> LiveByteInventory {
        var byID = Dictionary(session.engine.stagedAttachments(for: document).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let loaded = session.importBatch?.loaded ?? []
        for item in loaded { if let staged = item.staged { byID[staged.id] = staged } }
        var references = Set(document.attachmentIDs)
        references.formUnion(session.engine.history.referencedAttachmentIDs)
        references.formUnion(session.engine.staged.keys)
        references.formUnion(byID.keys)
        let pending: NoteDraftJournalEntry.PendingImport?
        if let batch = session.importBatch, let target = session.engine.currentImportTarget {
            pending = .init(anchor: target.anchor, replacementLength: target.replacementLength,
                isBoundary: target.isBoundary, acceptedText: batch.acceptedText,
                items: loaded.map { item in
                    .init(filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier,
                          byteCount: item.byteCount, stagedID: item.staged?.id,
                          pixelWidth: item.pixelSize.map { Double($0.width) },
                          pixelHeight: item.pixelSize.map { Double($0.height) }, failure: item.failure)
                }, remainingNames: Array(batch.urls.dropFirst(batch.completed)).map(\.lastPathComponent))
        } else { pending = nil }
        return LiveByteInventory(staged: byID.values.sorted { $0.id.uuidString < $1.id.uuidString },
            references: references, pendingImport: pending)
    }

    private func liveAttachmentIDs(in session: NoteSession) -> Set<UUID> {
        liveByteInventory(in: session, document: checkpointDocument(for: session)).references
    }

    var lastViewedNoteID: UUID? {
        defaults?.string(forKey: Self.lastViewedKey).flatMap(UUID.init(uuidString:))
    }

    /// Failed sessions are listed even when no note row was ever committed.
    var failedDrafts: [NoteSession] {
        recency.reversed().compactMap { cache[$0] }.filter { NoteSessionPolicy.needsAttention($0.state) }
    }

    weak var workspaceTaskStore: TaskStore?
    private var operationReviewSession: NoteSession?

    /// Presence is read without flushing a draft. The producing call may own
    /// one engine-only session; every other live editor keeps proposal authority.
    func hasAgentWorkspaceEditor(taskID: UUID?, noteID: UUID?, allowing presenter: TaskNotePresenter?, session allowed: NoteSession?, reviewed: Bool = false) -> Bool {
        if let taskID, let open = TaskNotePresenter.open(for: taskID), open !== presenter || (!reviewed && open.isMounted) { return true }
        for session in cache.values {
            let matches = session.noteID == noteID || (taskID != nil && (session.pendingTaskID == taskID || store.note(withID: session.noteID)?.taskID == taskID))
            guard matches else { continue }
            let visible = isPageVisible && !isLibraryPresented && active === session
            if session === allowed || session === presenter?.session {
                if !reviewed && visible { return true }
                continue
            }
            if session.workspacePage?.activeLease != nil || (isPageVisible && !isLibraryPresented && active === session) { return true }
            if NoteSessionPolicy.hasPendingWork(session.state) || session.isImporting { return true }
        }
        return false
    }

    var workspaceProposals: [NotePendingEdit] {
        let rows = (try? store.modelContext.fetch(FetchDescriptor<NotePendingEdit>(predicate: #Predicate { $0.workspaceOperationData != nil }))) ?? []
        var seen = Set<UUID>()
        return rows.sorted { $0.createdAt < $1.createdAt }.filter { seen.insert($0.id).inserted }
    }

    private func pendingWorkspaceEdits(_ session: NoteSession) -> [NotePendingEdit] {
        store.pendingEdits(noteID: session.noteID, taskID: session.pendingTaskID ?? store.note(withID: session.noteID)?.taskID)
    }

    private func beginWorkspaceProposalReview(_ id: UUID) async -> Bool {
        guard let family = try? store.pendingEditRows(id), let edit = family.first,
              NotePhysicalFamilyRetention.proposalEligible(family, noteIDs: [edit.noteID]),
              let data = edit.workspaceOperationData, let intent = try? JSONDecoder().decode(AgentWorkspaceIntent.self, from: data) else { return false }
        let session = intent.taskID.flatMap { TaskNotePresenter.open(for: $0)?.session }
            ?? cache[edit.noteID]
        if let session, session !== operationReviewSession {
            guard canLeaveComposition(in: session), await preserveDurably(session) else { return false }
        }
        let current = session?.engine.document() ?? (try? store.replicasIncludingDeleted(of: edit.noteID))?.first?.content.flatMap { NoteContentCodec.decode($0).document } ?? .blank
        let preview = (try? NoteDocument(blocks: [.text("Proposed workspace change"), .text(intent.summary)])) ?? .blank
        let ticketSession = session ?? NoteSession(noteID: edit.noteID, isPersisted: false, baseRevisionID: nil,
            engine: makeEngine(noteID: edit.noteID, document: current, readOnly: true), readOnlyReason: nil)
        operationReviewSession = ticketSession
        guard let readSet = try? AgentWorkspaceReadSet.capture(taskID: intent.taskID, noteID: intent.noteID, in: ModelContext(store.container)) else { return false }
        proposalReview = NoteProposalReview(id: edit.id, sessionID: ticketSession.id, noteID: ticketSession.noteID,
            agent: edit.agentName, createdAt: edit.createdAt, isDeletion: false, current: current, currentTags: ticketSession.engine.tags,
            proposed: preview, proposedPreview: preview, revision: "workspace", savedContent: nil, signature: NoteProposalSignature(edit),
            workspaceIntent: intent, workspaceReadSet: readSet)
        isLibraryPresented = false
        return true
    }

    private func acceptWorkspaceProposal(_ review: NoteProposalReview) async -> Bool {
        guard let intent = review.workspaceIntent, let readSet = review.workspaceReadSet,
              let session = operationReviewSession, session.id == review.sessionID,
              let family = try? store.pendingEditRows(review.id), let edit = family.first,
              NotePhysicalFamilyRetention.proposalEligible(family, noteIDs: [edit.noteID]),
              NoteProposalSignature(edit) == review.signature,
              let tasks = workspaceTaskStore else { return false }
        guard session.engine.document() == review.current, session.engine.tags == review.currentTags,
              !session.isImporting, canLeaveComposition(in: session),
              (try? readSet.isCurrent(in: ModelContext(store.container))) == true else {
            _ = await beginWorkspaceProposalReview(review.id)
            proposalReviewNotice = "The workspace changed. Review the refreshed operation before applying."
            return false
        }
        let tools = AgentTaskTools(store: tasks, noteStore: store)
        tools.notesController = { [weak self] in self }
        let call = AgentWorkspaceCall(readSet: readSet, intent: intent, notes: self, resolving: review.signature)
        call.presenter = intent.taskID.flatMap { TaskNotePresenter.open(for: $0) }
        call.session = session
        do {
            _ = try await AgentWorkspaceCall.$current.withValue(call) { try await tools.executeWorkspaceIntent(intent, notes: self) }
            endProposalReview()
            store.refresh()
            return true
        } catch {
            if call.conflicted { _ = await beginWorkspaceProposalReview(review.id) }
            proposalReviewNotice = "The operation couldn't be applied: \(error.localizedDescription)"
            return false
        }
    }

    func proposalComparison(for session: NoteSession) -> (agent: String, current: String, proposed: String)? {
        guard session.isPersisted,
              let edit = store.pendingEdits(noteID: session.noteID).first,
              let bytes = edit.proposedContent,
              case let .editable(document) = NoteContentCodec.decode(bytes) else { return nil }
        return (edit.agentName.isEmpty ? String(localized: "Agent") : edit.agentName,
                NoteTextExport.plainText(session.engine.document()), NoteTextExport.plainText(document))
    }

    /// A store revision can change this answer; typing alone cannot.
    func proposalAgent(for session: NoteSession) -> String? {
        if let cached = proposalStatusCache[session.noteID], cached.revision == store.revision { return cached.agent }
        let edits: [NotePendingEdit]
        do {
            edits = try store.readPendingEdits(noteID: session.noteID,
                taskID: session.pendingTaskID ?? store.note(withID: session.noteID)?.taskID)
        } catch {
            store.reportProposalReadFailure(error)
            return proposalStatusCache[session.noteID]?.agent
        }
        // Task-anchored operations also belong to an absent-note draft. Cache
        // both positive and negative answers by store revision before typing
        // can ask again; typing never changes proposal membership.
        let primary = edits.first(where: { $0.workspaceOperationData != nil }) ?? edits.first(where: { !$0.isDeletion })
        let agent = primary.map { $0.agentName.isEmpty ? String(localized: "Agent") : $0.agentName }
        proposalStatusCache[session.noteID] = ProposalStatus(revision: store.revision, agent: agent,
            deletionAgent: edits.first(where: \.isDeletion).map { $0.agentName.isEmpty ? "Agent" : $0.agentName },
            editID: primary?.id, deletionID: edits.first(where: \.isDeletion)?.id)
        return agent
    }

    /// A status action belongs to the proposal displayed when the action was built.
    /// If it disappears before the click, the action must not resolve its sibling.
    func proposalID(for session: NoteSession, deletion: Bool) -> UUID? {
        _ = proposalAgent(for: session)
        return deletion ? proposalStatusCache[session.noteID]?.deletionID : proposalStatusCache[session.noteID]?.editID
    }

    func statusItems(for session: NoteSession) -> [NoteStatusItem] {
        var items: [NoteStatusItem] = []
        if session.workspacePublicationPending { items.append(.couldntFinishSaving) }
        switch session.state {
        case let .onlyInMemory(reason): items.append(.onlyInMemory(reason))
        case let .notSaved(reason): items.append(.notSaved(reason))
        case .conflict(.changed): items.append(.changedElsewhere)
        case .conflict(.deleted): items.append(.deletedElsewhere)
        default: break
        }
        let agent = proposalAgent(for: session)
        if let deletion = proposalStatusCache[session.noteID]?.deletionAgent { items.append(.deletionProposal(deletion)) }
        if let agent { items.append(.proposal(agent)) }
        if session.isImporting { items.append(.importing) }
        if let notice = session.noticeValue { items.append(.notice(notice)) }
        if let reason = session.readOnlyReason { items.append(.readOnly(reason.message)) }
        if let note = store.note(withID: session.noteID), let editor = note.externalEditorName, let time = note.externalEditedAt {
            items.append(.editedBy(editor, time))
        }
        return items
    }

    private func reviewSession(proposalID: UUID? = nil) -> NoteSession? {
        if let proposalID, let noteID = (try? store.pendingEditRows(proposalID))?.first?.noteID,
           let session = cache[noteID], isReviewSessionCurrent(session) { return session }
        return taskNotePresenter?.session ?? active
    }
    private func isReviewSessionCurrent(_ session: NoteSession) -> Bool {
        active === session || session.workspacePage?.activeLease != nil
    }

    var reviewProposals: [NotePendingEdit] {
        guard let noteID = proposalReview?.noteID else { return [] }
        return store.pendingEdits(noteID: noteID)
    }

    @discardableResult
    func beginProposalReview(id: UUID? = nil) async -> Bool {
        if let id, (try? store.pendingEditRows(id))?.first?.workspaceOperationData != nil {
            guard await awaitRecoveryForUser() else { return false }
            return await beginWorkspaceProposalReview(id)
        }
        guard await awaitRecoveryForUser(), let session = reviewSession(proposalID: id), !session.isImporting,
              canLeaveComposition(in: session) else { return false }
        return await performAfterRecovery {
            guard self.isReviewSessionCurrent(session), !session.isImporting, self.canLeaveComposition(in: session),
                  self.preserve(session),
                  let edit = self.store.pendingEdits(noteID: session.noteID).first(where: { id == nil || $0.id == id }),
                  let family = try? self.store.pendingEditRows(edit.id),
                  NotePhysicalFamilyRetention.proposalEligible(family, noteIDs: [session.noteID]) else { return false }
            WorkspaceLegacyBridge.prepareMutations(family, in: self.store.modelContext)
            family.forEach { $0.needsReview = true }
            guard self.store.commitStagedChanges() else { return false }
            self.captureViewState(session)
            self.proposalReviewNotice = nil
            return self.refreshProposalReview(id: edit.id, session: session)
        }
    }

    private func refreshProposalReview(id: UUID, session: NoteSession) -> Bool {
        guard let note = store.note(withID: session.noteID),
              let edit = store.pendingEdits(noteID: session.noteID).first(where: { $0.id == id }),
              let data = edit.proposedContent, let document = NoteContentCodec.decode(data).document else { return false }
        // A clean editor can follow a fresh outside save; dirty/conflicted text stays owned by its draft.
        if session.state == .clean, session.baseRevisionID != note.revisionID || session.baseContent != note.content,
           let saved = note.content.flatMap({ NoteContentCodec.decode($0).document }) {
            session.replaceEngine(makeEngine(noteID: note.id, document: saved, readOnly: false, tags: note.tags))
            session.baseRevisionID = note.revisionID
            session.baseContent = note.content
            session.baseTags = note.tags
            wire(session)
        }
        var preview = document
        if !edit.isDeletion {
            let missing = session.engine.document().blocks.filter { !document.blocks.contains($0) }
            if !missing.isEmpty {
                preview.blocks.append(.text("Not in proposal", style: "heading"))
                preview.blocks += missing.map { block in
                    var copy = block
                    if copy.id != nil { copy.id = UUID() }
                    return copy
                }
            }
        }
        proposalReview = NoteProposalReview(id: edit.id, sessionID: session.id, noteID: session.noteID,
            agent: edit.agentName.isEmpty ? "Agent" : edit.agentName, createdAt: edit.createdAt, isDeletion: edit.isDeletion,
            current: session.engine.document(), currentTags: session.engine.tags,
            proposed: edit.isDeletion ? .blank : document, proposedPreview: preview,
            revision: note.revisionToken, savedContent: note.content, signature: NoteProposalSignature(edit))
        return true
    }

    func endProposalReview() {
        proposalReview = nil
        proposalReviewNotice = nil
        operationReviewSession = nil
    }

    @discardableResult
    func acceptProposal() async -> Bool {
        if let review = proposalReview, review.workspaceIntent != nil { return await acceptWorkspaceProposal(review) }
        guard await awaitRecoveryForUser(), let review = proposalReview, let session = cache[review.noteID], isReviewSessionCurrent(session),
              session.id == review.sessionID, !session.isImporting,
              canLeaveComposition(in: session) else { return false }
        guard !session.isConflict else {
            proposalReviewNotice = "Your draft changed elsewhere. Save as New Note before replacing it."
            return false
        }
        let engine = session.engine, generation = session.editGeneration
        if NoteSessionPolicy.hasPendingWork(session.state) {
            // A document-only comparison misses tags and staged file bytes.
            // Save the whole draft before replacing its engine or retiring
            // recovery, then require review of that saved state.
            _ = await preserveDurably(session)
            guard isReviewSessionCurrent(session), proposalReview == review, session.engine === engine else { return false }
            _ = refreshProposalReview(id: review.id, session: session)
            proposalReviewNotice = "Your draft changed. Review the refreshed comparison before replacing."
            return false
        }
        return await performAfterRecovery {
            guard self.proposalReview == review, self.isReviewSessionCurrent(session), !session.isImporting,
                  self.canLeaveComposition(in: session) else { return false }
            guard let note = self.store.note(withID: review.noteID), note.revisionToken == review.revision,
                  note.content == review.savedContent, session.engine === engine,
                  session.editGeneration == generation, session.state == .clean,
                  session.engine.document() == review.current, session.engine.tags == review.currentTags,
                  session.engine.tags == session.baseTags else {
                _ = self.refreshProposalReview(id: review.id, session: session)
                self.proposalReviewNotice = "The note changed. The comparison has refreshed; review it before replacing."
                return false
            }
            // The journal must retire while the note is still live. Async retirement
            // refuses this attempt and requires a retry after its durable proof completes.
            if review.isDeletion, !self.retireRecoveryCopy(noteID: review.noteID, session: session) {
                self.proposalReviewNotice = "Recovery data is being preserved. Retry deletion when saving finishes."
                return false
            }
            let outcome = self.store.replaceWithProposal(review.id, noteID: review.noteID,
                expectedRevision: review.revision, expectedSavedContent: review.savedContent,
                expectedProposal: review.signature, preserving: review.current)
            switch outcome {
            case let .failure(error):
                self.proposalReviewNotice = error.localizedDescription
                return false
            case let .success(token):
                self.endProposalReview()
                if review.isDeletion {
                    session.saveTask?.cancel(); session.durabilityTask?.cancel(); session.pauseTask?.cancel()
                    self.cache[review.noteID] = nil
                    session.engine.detachView()
                    self.active = nil
                    self.isLibraryPresented = true
                } else {
                    if let page = session.workspacePage {
                        page.externalRefresh(origin: review.agent)
                    } else {
                        session.replaceEngine(self.makeEngine(noteID: review.noteID, document: review.proposed,
                            readOnly: false, tags: session.engine.tags))
                        session.baseRevisionID = UUID(uuidString: token)
                        self.wire(session)
                        self.didSave(session, staged: [])
                    }
                }
                return true
            }
        }
    }

    @discardableResult
    func discardReviewedProposal() -> Bool {
        guard let review = proposalReview, store.discardProposal(review.id, noteID: review.signature.noteID) else {
            proposalReviewNotice = store.lastErrorMessage ?? "The proposal could not be discarded."
            return false
        }
        endProposalReview()
        return true
    }

    @discardableResult
    func saveReviewedProposalAsNew() async -> Bool {
        guard proposalReview?.workspaceIntent == nil else { proposalReviewNotice = "Apply or discard the whole workspace operation."; return false }
        guard await awaitRecoveryForUser(), let review = proposalReview, let session = active,
              session.id == review.sessionID, !session.isImporting,
              canLeaveComposition(in: session) else { return false }
        if review.isDeletion, session.engine.document() != review.current {
            _ = refreshProposalReview(id: review.id, session: session)
            proposalReviewNotice = "Your text changed. Review the refreshed comparison before saving a copy."
            return false
        }
        let document = review.isDeletion ? review.current : review.proposed
        guard let stored = await performBoundedUserIO({ [self] in Array(await durableAttachmentsAsync(in: document).values) }),
              proposalReview == review, active === session else { return false }
        return await performAfterRecovery {
            guard self.proposalReview == review, self.active === session, !session.isImporting,
                  self.canLeaveComposition(in: session),
                  !review.isDeletion || session.engine.document() == review.current,
                  let rows = try? self.store.pendingEditRows(review.id),
                  NotePhysicalFamilyRetention.proposalEligible(rows, noteIDs: [review.noteID]),
                  rows.first.map(NoteProposalSignature.init) == review.signature,
                  let (copy, bytes) = self.replacementForDeletedNote(document, oldID: review.noteID,
                    staged: session.engine.stagedAttachments(for: document) + stored) else {
                self.proposalReviewNotice = "The proposal or its files changed. Review it again."
                return false
            }
            switch self.store.createDocumentNote(id: UUID(), document: copy, staged: bytes,
                tags: session.engine.tags, resolvingProposal: review.id) {
            case let .failure(error): self.proposalReviewNotice = error.localizedDescription; return false
            case .success:
                self.endProposalReview()
                session.showNotice(NoteNotice(kind: .noteSaved, detail: "Saved as a new note."))
                return true
            }
        }
    }

    func conflictComparison(for session: NoteSession) -> (agent: String, current: String, proposed: String)? {
        guard case .conflict = session.state else { return nil }
        let current = store.loadDocument(noteID: session.noteID)?.content.document
        return (session.state == .conflict(.deleted) ? String(localized: "Deleted elsewhere")
                : String(localized: "Changed elsewhere"),
                current.map(NoteTextExport.plainText) ?? "",
                NoteTextExport.plainText(session.engine.document()))
    }

    @discardableResult
    func openFailedDraft(sessionID: UUID) -> Bool {
        guard let draft = cache.values.first(where: { $0.id == sessionID }) else { return false }
        guard draft.workspacePage?.activeLease == nil else { return false }
        if active !== draft { guard prepareToLeave(.openNote) else { return false } }
        activate(draft)
        isLibraryPresented = false
        return true
    }

    // MARK: Opening

    /// Recovery first, then the last note viewed, else a new draft.
    func start() {
        guard !didStart else { return }
        startRequested = true
        if !didRecoverAtLaunch {
            recoverAtLaunch()
            if journal?.requiresAsyncIO == true { return }
        }
        didStart = true
        isPageVisible = true
        pruneObsoleteViewState()
        if let recovered = newestRecovered {
            newestRecovered = nil
            pendingNewNote = false
            if let shown = presentSession(recovered) {
                activate(shown)
                return
            }
        }
        if pendingNewNote {
            pendingNewNote = false
            _ = newNote()
            return
        }
        if let last = lastViewedNoteID, store.note(withID: last) != nil, open(noteID: last) {
            if !recoveryWarnings.isEmpty { active?.showNotice(NoteNotice(kind: .damaged, detail: recoveryWarnings.joined(separator: " "))) }
            return
        }
        _ = newNote()
        if !recoveryWarnings.isEmpty {
            active?.showNotice(NoteNotice(kind: .damaged, detail: recoveryWarnings.joined(separator: " ")))
        }
    }

    /// Opens a stored document in the Notes editor.
    @discardableResult
    func open(noteID: UUID, verifiedCheckpointsOnly: Bool = false, preparedLoad: NoteDocumentLoad? = nil) -> Bool {
        guard cache[noteID]?.workspacePage?.activeLease == nil else { return false }
        if let active, active.noteID == noteID {
            present()
            return true
        }
        guard let note = store.note(withID: noteID) else { return false }
        guard prepareToLeave(.openNote, verifiedCheckpointsOnly: verifiedCheckpointsOnly) else { return false }
        guard let session = session(for: note, preparedLoad: preparedLoad).flatMap({ presentSession($0) }) else { return false }
        activate(session)
        return true
    }

    /// A new draft; the current one is preserved first.
    @discardableResult
    func newNote(verifiedCheckpointsOnly: Bool = false) -> Bool {
        if let active, active.isUntouchedDraft { return true }
        guard prepareToLeave(.newNote, verifiedCheckpointsOnly: verifiedCheckpointsOnly) else { return false }
        let id = UUID()
        let session = NoteSession(noteID: id, isPersisted: false, baseRevisionID: nil,
                                  engine: makeEngine(noteID: id, document: .blank, readOnly: false),
                                  readOnlyReason: nil)
        activate(session)
        return true
    }

    /// Engine-only entry point: does not present a page, create a note, or
    /// attach a native view. Registry callers share the controller's cache.
    func workspaceSession(noteID: UUID) -> NoteSession? {
        // Cache admission can evict a clean incoming note before activate
        // installs it as active. Reuse that live session rather than split it.
        let existing = cache[noteID] ?? (active?.noteID == noteID ? active : nil)
        if let existing, !existing.usesWorkspaceBinding {
            // Reopen checks this UUID's physical rows only. A warm hit must
            // not reload every unrelated note and attachment in the store.
            let context = ModelContext(store.container)
            context.autosaveEnabled = false
            guard let rows = try? store.liveReplicas(of: noteID, in: context) else { return nil }
            let latest = NoteStore.canonicalReplicas(from: rows).first
            if latest == nil || latest?.revisionID != existing.baseRevisionID || latest?.tags != existing.baseTags {
                // An actual external change replaces the stale store context
                // before presentSession rebuilds the clean cached engine.
                store.refresh()
            }
        }
        guard let note = store.note(withID: noteID) else { return nil }
        guard let session = (existing ?? session(for: note)).flatMap({
            $0.usesWorkspaceBinding ? $0 : presentSession($0)
        }) else { return nil }
        if let existing, session !== existing {
            // A closed workspace still has its ordered history. An external
            // replacement must stop Undo before the retired editor's steps.
            existing.engine.history.workspace?.recordExternalBarrier(origin: "another surface")
        }
        if cache[noteID] == nil { wire(session); cache[noteID] = session }
        return session
    }
    /// Phase 3 lazy creation: the engine-only draft a task's page writes
    /// into while the task has no note. Nothing is stored until the first
    /// save that has writing or a file (`save`, `createDocumentNote`).
    func workspaceTaskDraft(taskID: UUID, title: String) -> NoteSession? {
        guard let document = try? NoteDocument.blank.taskSnapshot(title: title) else { return nil }
        let id = UUID()
        let session = NoteSession(noteID: id, isPersisted: false, baseRevisionID: nil,
                                  engine: makeEngine(noteID: id, document: document, readOnly: false, bodyOnly: true),
                                  readOnlyReason: nil)
        session.pendingTaskID = taskID
        wire(session)
        cache[id] = session
        return session
    }

    /// A task draft nobody wrote in leaves nothing behind when its page
    /// closes (§ 2.1: opening creates nothing).
    func discardUntouchedTaskDraft(_ session: NoteSession) {
        guard session.pendingTaskID != nil, session.isUntouchedDraft, !session.usesWorkspaceBinding,
              cache[session.noteID] === session else { return }
        session.saveTask?.cancel(); session.saveTask = nil
        session.durabilityTask?.cancel(); session.durabilityTask = nil
        session.pauseTask?.cancel(); session.pauseTask = nil
        session.engine.detachView()
        cache[session.noteID] = nil
    }

    /// Phase 3: a task note's task state for All notes, and opening a task's
    /// page from the library (the host supplies both; nil in tests).
    var taskStateLookup: ((UUID) -> AtticTaskState?)?
    var openTaskPage: ((UUID) -> Bool)?

    /// The cached session for `noteID`, if any (tests and diagnostics).
    func workspaceSessionIfCached(_ noteID: UUID) -> NoteSession? { cache[noteID] }

    /// Called after a task draft's first save created its note.
    var taskNoteCreated: ((_ taskID: UUID, _ noteID: UUID) -> Void)?
    var taskNoteBecameOrdinary: ((_ taskID: UUID, _ noteID: UUID) -> Void)?
    /// A workspace operation (Make Subtask, Make Note Checkbox, their Undo)
    /// committed this note's document at `revisionID` through the write
    /// gate, and its editor already shows that text: the session takes the
    /// revision as its base, so its next save neither conflicts nor repeats
    /// the write. `created` marks the never-saved task draft whose note the
    /// operation created. Text typed meanwhile stays pending, as after any
    /// save.
    func adoptWorkspaceCommit(_ session: NoteSession, revisionID: UUID, created: Bool = false) {
        store.refresh()
        if created {
            session.isPersisted = true
            if let owner = session.pendingTaskID {
                session.pendingTaskID = nil
                taskNoteCreated?(owner, session.noteID)
            }
            remember(session.noteID)
        }
        session.baseRevisionID = revisionID
        session.baseContent = store.note(withID: session.noteID)?.content
        session.baseTags = store.note(withID: session.noteID)?.tags ?? session.baseTags
        let stored = store.loadDocument(noteID: session.noteID)?.content.document
        if session.engine.matchesContentIgnoringFolds(stored), session.engine.tags == session.baseTags {
            session.state = .clean
            session.durabilityTask?.cancel(); session.durabilityTask = nil
            clearRecoveryCopy(for: session)
        } else {
            session.state = .dirty
            scheduleSave(session)
            scheduleDurabilityDeadline(session)
        }
    }

    /// Makes the session hold exactly what is stored (a workspace operation
    /// starts from a saved note): saves pending writing, creating a task
    /// draft's note when it has writing. True when the note exists and is
    /// clean.
    func settleForWorkspaceOperation(_ session: NoteSession) -> Bool {
        session.engine.refreshCompositionActivity()
        if NoteSessionPolicy.hasPendingWork(session.state) || !session.isPersisted { _ = save(session) }
        return session.isPersisted && session.state == .clean && !session.isImporting
    }

    /// A coordinated purge made a task's own note ordinary (§ 2.7.2); the
    /// host closes that task's page and shows the note (with the patch and
    /// its operation for "Task removed permanently · Undo").
    var taskNoteMaterialized: ((WorkspaceMaterializationPatch, UUID) -> Void)?
    /// Make Task from Note (the ⋯ of an ordinary note); nil hides it.
    var makeTaskFromNote: ((UUID) -> Void)?

    /// All notes' search while a task's page opened from it is shown; the
    /// library takes it back on Back (slice 1).
    var libraryQueryAcrossTaskPage: String?

    func installFileHistoryState(_ session: NoteSession, rootID: UUID, noteID: UUID, history: WorkspaceHistory) throws {
        guard !session.isImporting,
              session.engine.textView?.hasMarkedText() != true else { throw WorkspaceFoundationError.conflict }
        // The stored replay is authoritative, but a fallback draft now owns
        // the editor. Finish publication without replacing it; history's
        // recovery path installs the external barrier and retains that draft.
        if history.hasNewerPublicationDraft { return }
        store.refresh()
        let stored = store.note(withID: noteID)
        guard retireRecoveryCopy(noteID: session.noteID, session: session) else { throw WorkspaceFoundationError.conflict }
        session.saveTask?.cancel(); session.saveTask = nil
        session.durabilityTask?.cancel(); session.durabilityTask = nil
        session.pauseTask?.cancel(); session.pauseTask = nil
        cache[session.noteID] = nil
        session.invalidateCallbacks()
        session.verifiedDocumentAttachments = [:]
        if let stored {
            session.adopt(noteID: noteID)
            session.pendingTaskID = nil
            session.isPersisted = true
            session.baseRevisionID = stored.revisionID
            session.baseContent = stored.content
            session.baseTags = stored.tags
            guard let document = stored.content.flatMap({ NoteContentCodec.decode($0).document }) else { throw WorkspaceFoundationError.conflict }
            session.replaceEngine(makeEngine(noteID: noteID, document: document, readOnly: false, tags: stored.tags, bodyOnly: true))
            session.state = .clean
        } else {
            let id = UUID()
            let task = (try? ModelContext(store.container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == rootID })))?.first
            let blank = try NoteDocument.blank.taskSnapshot(title: task?.title ?? "")
            session.adopt(noteID: id)
            session.pendingTaskID = rootID
            session.isPersisted = false
            session.baseRevisionID = nil; session.baseContent = nil; session.baseTags = []
            session.replaceEngine(makeEngine(noteID: id, document: blank, readOnly: false, bodyOnly: true))
            session.state = .untouched
        }
        session.readOnlyReason = nil
        session.recoveryClaim = nil
        session.selection = NSRange(location: 0, length: 0)
        session.scrollOffset = 0
        guard history.bind(noteID: session.noteID) else { throw WorkspaceFoundationError.conflict }
        history.attach(session.engine.history)
        cache[session.noteID] = session
        wire(session)
        TaskNotePresenter.open(for: rootID)?.refreshDeletedNote(stored == nil ? noteID : nil)
    }

    func refreshWorkspaceSession(_ session: NoteSession) -> NoteSession? {
        store.refresh()
        session.invalidateCallbacks()
        cancelWorkspaceImport(session)
        guard let note = store.note(withID: session.noteID) else {
            session.state = .conflict(.deleted)
            return session
        }
        if NoteSessionPolicy.hasPendingWork(session.state), note.revisionID != session.baseRevisionID {
            session.state = .conflict(.changed)
            return session
        }
        guard let refreshed = presentSession(session, refreshingWorkspace: true) else { return nil }
        if refreshed !== session { wire(refreshed); cache[refreshed.noteID] = refreshed }
        return refreshed
    }
    func resumeWorkspaceDurability(_ session: NoteSession) {
        // Admission happens after the workspace binding protects this owner.
        touch(session.noteID)
        if NoteSessionPolicy.hasPendingWork(session.state) {
            scheduleSave(session); scheduleDurabilityDeadline(session)
        }
    }
    func workspaceIsDurable(_ session: NoteSession) -> Bool {
        guard session.engine.history.workspace?.hasQueuedTyping != true else { return false }
        return hasDurableCheckpoint(session)
            || (!session.isImporting && !NoteSessionPolicy.hasPendingWork(session.state))
    }
    func suspendWorkspace(_ session: NoteSession) {
        guard active !== session else { return }
        cancelWorkspaceImport(session)
        session.saveTask?.cancel(); session.saveTask = nil
        session.durabilityTask?.cancel(); session.durabilityTask = nil
        session.pauseTask?.cancel(); session.pauseTask = nil
        session.importTask?.cancel(); session.importTask = nil
        session.engine.detachView()
    }

    func cancelWorkspaceImport(_ session: NoteSession) {
        guard let batch = session.importBatch else { return }
        dropImport(in: session, batchID: batch.id,
            notice: NoteNotice(kind: .notice, detail: String(localized: "The file batch was cancelled because the page moved or closed.")))
    }

    func releaseWorkspace(_ session: NoteSession) {
        session.usesWorkspaceBinding = false
        session.workspacePage = nil
        // Close revokes the page and its callbacks, not the warm editor.
        // The same eight-slot LRU and protected-draft rules as plain Notes
        // decide when this clean, detached session can be discarded.
        guard cache[session.noteID] === session else { return }
        touch(session.noteID)
    }

    private func session(for note: NoteItem, preparedLoad: NoteDocumentLoad? = nil) -> NoteSession? {
        if let cached = cache[note.id] { return cached }
        let load = preparedLoad ?? store.loadDocument(noteID: note.id)
        let document = load?.content.document ?? .blank
        let readOnlyReason: NoteReadOnlyReason? = if let load {
            if case let .readOnly(_, reason, _) = load.content { reason } else { nil }
        } else {
            .unreadable("missing document bytes")
        }
        let session = NoteSession(noteID: note.id, isPersisted: true, baseRevisionID: load?.revisionID,
                                  engine: makeEngine(noteID: note.id, document: document, readOnly: readOnlyReason != nil,
                                                     tags: note.tags, bodyOnly: note.taskID != nil),
                                  readOnlyReason: readOnlyReason)
        session.baseTags = note.tags
        session.baseContent = note.content
        if let history = undoRoute.existingWorkspace(for: .note(note.id)) { history.attach(session.engine.history) }
        if let state = defaults?.dictionary(forKey: Self.viewStateKey(note.id)) {
            session.selection = NSRange(location: state["location"] as? Int ?? 0,
                                        length: state["length"] as? Int ?? 0)
            session.scrollOffset = CGFloat(state["scroll"] as? Double ?? 0)
        }
        return session
    }

    private func makeEngine(noteID: UUID, document: NoteDocument, readOnly: Bool,
                            staged: [StagedNoteAttachment] = [], tags: [String] = [],
                            bodyOnly: Bool = false) -> NoteEditorEngine {
        // A task's own note (`taskID` set, stored in the `taskNote` form)
        // loads the body-only projection (UX plan § 2.12).
        let engine = NoteEditorEngine(noteID: noteID, document: document, readOnly: readOnly, design: design,
                                      today: NoteDay(date: now()), imageProvider: self, stagedAttachments: staged,
                                      tags: tags, relativeDateNow: now, bodyOnly: bodyOnly)
        if let editor = store.note(withID: noteID)?.externalEditorName {
            engine.history.outsideEditBarrier = editor
            engine.history.onOutsideEditBarrier = { [weak engine] editor in
                engine?.onNotice?(NoteNotice(kind: .notice, detail: "Edited by \(editor): can't undo past this"))
            }
        }
        return engine
    }

    private func activate(_ session: NoteSession) {
        openRequestGeneration &+= 1
        closeHistory()
        wire(session)
        cache[session.noteID] = session
        touch(session.noteID)
        active = session
        if session.isPersisted { remember(session.noteID) }
    }

    /// A clean cached session is rebuilt once, at presentation, if its store
    /// revision moved. A missing clean note is dropped.
    private func presentSession(_ session: NoteSession, refreshingWorkspace: Bool = false) -> NoteSession? {
        if !refreshingWorkspace {
            guard session.workspacePage?.activeLease == nil else { return nil }
            // Bound notes refresh only through the workspace's history barrier.
            if session.usesWorkspaceBinding { return session }
        }
        if case .conflict = session.state {
            session.state = .conflict(store.note(withID: session.noteID) == nil ? .deleted : .changed)
            return session
        }
        guard case .clean = session.state, session.isPersisted else { return session }
        guard let note = store.note(withID: session.noteID) else {
            if session.usesWorkspaceBinding { session.state = .conflict(.deleted); return session }
            cache[session.noteID] = nil
            session.engine.detachView()
            return nil
        }
        guard session.baseRevisionID != note.revisionID || session.baseContent != note.content else {
            // Tags set elsewhere (an agent, another page) move no revision.
            if note.tags != session.baseTags, session.engine.tags == session.baseTags {
                session.baseTags = note.tags
                session.engine.setTags(note.tags)
            }
            return session
        }
        if session.usesWorkspaceBinding {
            guard let load = store.loadDocument(noteID: session.noteID) else { return nil }
            let reason: NoteReadOnlyReason? = if case let .readOnly(_, reason, _) = load.content { reason } else { nil }
            session.replaceEngine(makeEngine(noteID: session.noteID, document: load.content.document ?? .blank,
                readOnly: reason != nil, tags: note.tags, bodyOnly: note.taskID != nil))
            session.readOnlyReason = reason
            session.baseRevisionID = load.revisionID
            session.baseContent = note.content
            session.baseTags = note.tags
            session.state = reason == nil ? .clean : .readOnly
            wire(session)
            return session
        }
        cache[session.noteID] = nil
        session.engine.detachView()
        let rebuilt = self.session(for: note)
        if session.recoveryClaim != nil { retiredNoteIDs.remove(session.noteID) }
        rebuilt?.recoveryClaim = session.recoveryClaim
        return rebuilt
    }

    func present() {
        openRequestGeneration &+= 1
        isPageVisible = true
        presentationCount &+= 1
        if let current = active {
            if let shown = presentSession(current) {
                if shown !== current { activate(shown) }
            } else {
                active = nil
                if didStart { _ = newNote() }
            }
        }
        active?.engine.refreshRelativeDates(today: NoteDay(date: now()))
    }

    private func wire(_ session: NoteSession) {
        let engine = session.engine
        engine.permitsReadOnlyLifecycleReplay = { [weak session] redo in
            guard let session, session.isItemDeleted, let history = session.engine.history.workspace,
                  let step = history.route.steps(in: history.historyID, redo: redo).last,
                  step.name.hasPrefix(redo ? "Restore" : "Delete") else { return false }
            let ref: AtticItemRef
            if let page = session.workspacePage, case let .task(id) = page.key.workspace { ref = .init(.task, id) }
            else { ref = .init(.note, session.noteID) }
            return step.affectedItems().contains(ref)
        }
        engine.history.onWorkspaceRecoveryChanged = { [weak self, weak session] pending, permitsDraft, conflict in
            guard let self, let session else { return }
            session.workspacePublicationPending = pending
            if pending && permitsDraft {
                session.saveTask?.cancel(); session.saveTask = nil
                // Permission to edit is not itself an edit. A checkpoint of
                // the unchanged replay source can outlive its deleted/draft
                // identity and prevent the awaited retirement from finishing.
                if session.engine.history.workspace?.hasNewerPublicationDraft == true
                    || NoteSessionPolicy.hasPendingWork(session.state) || session.isImporting {
                    session.state = .notSaved(String(localized: "Couldn't finish saving the workspace change."))
                    _ = self.checkpoint(session, silent: true, allowQueued: true)
                }
            } else if !pending {
                self.store.refresh()
                if conflict {
                    session.state = .conflict(.changed)
                    _ = self.checkpoint(session, silent: true, allowQueued: true)
                } else if session.engine.matchesContentIgnoringFolds(self.store.loadDocument(noteID: session.noteID)?.content.document),
                          session.engine.tags == session.baseTags,
                          session.baseTags == self.store.note(withID: session.noteID)?.tags,
                          session.baseRevisionID == self.store.note(withID: session.noteID)?.revisionID {
                    session.state = .clean
                } else if NoteSessionPolicy.hasPendingWork(session.state) { self.scheduleSave(session) }
            }
        }
        session.workspacePublicationPending = engine.history.workspace?.hasPendingPublication == true
        engine.canUndoVersionRestore = { [weak self, weak session] in
            guard let self, let session, self.active === session else { return false }
            return self.canReplayVersionRestore(undo: true)
        }
        engine.canRedoVersionRestore = { [weak self, weak session] in
            guard let self, let session, self.active === session else { return false }
            return self.canReplayVersionRestore(undo: false)
        }
        engine.undoVersionRestore = { [weak self] in self?.requestVersionRestoreReplay(undo: true) }
        engine.redoVersionRestore = { [weak self] in self?.requestVersionRestoreReplay(undo: false) }
        engine.imageProvider = self
        engine.onTextChange = { [weak self, weak session] in
            guard let self, let session else { return }
            self.textDidChange(in: session)
        }
        engine.onActivityChanged = { [weak self, weak session] old, new in
            guard let self, let session else { return }
            if old != .idle && new == .idle {
                self.completeImportIfPossible(in: session)
                if NoteSessionPolicy.hasPendingWork(session.state) || session.isImporting {
                    _ = self.preserve(session)
                } else {
                    self.clearRecoveryCopy(for: session)
                }
            }
            self.updateWritingToolsAvailability(for: session)
        }
        engine.onNotice = { [weak session] notice in session?.showNotice(notice) }
        engine.onFileBatchRequest = { [weak self, weak session] urls, text, range in
            guard let self, let session, self.active === session || session.usesWorkspaceBinding else { return }
            self.importFiles(urls, acceptedText: text, at: range, into: session)
        }
        engine.onRawImageBatchRequest = { [weak self, weak session] data, ext, range in
            guard let self, let session, self.active === session || session.usesWorkspaceBinding else { return }
            guard !data.isEmpty, Int64(data.count) <= AttachmentLimits.maxBytesPerAttachment else {
                session.showNotice(NoteNotice(kind: .notAdded, detail: String(localized: "The clipboard image is empty or exceeds the attachment size limit.")))
                return
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("AtticClipboard-\(UUID().uuidString).\(ext)")
            self.importFiles([url], at: range, temporaryURLs: [url], clipboardData: data, into: session)
        }

        engine.onImportAdmission = { [weak self, weak session] payload in
            guard let self, let session else { return String(localized: "The note is no longer open.") }
            return self.importAdmissionFailure(payload, in: session)
        }
        engine.canPasteFragment = { [weak self, weak session] in
            guard let self, let session else { return false }
            return self.active === session && !self.isLibraryPresented && !session.isImporting
                && !session.isReadOnly
                && session.engine.textView?.hasMarkedText() != true
        }
        engine.onFragmentAdmission = { [weak self, weak session] proposed, copied in
            guard let self, let session else { return String(localized: "The note is no longer open.") }
            return self.attachmentAdmissionFailure(proposed: proposed, additions: copied, in: session)
        }
        engine.onTagsChange = { [weak self, weak session] in
            guard let self, let session else { return }
            // A refresh to the stored tags is not an edit.
            if !NoteSessionPolicy.hasPendingWork(session.state), session.engine.tags == session.baseTags { return }
            self.textDidChange(in: session)
        }
        engine.onWritingToolsWillBegin = { [weak self, weak session, weak engine] in
            guard let self, let session, let engine else { return false }
            guard NoteSessionPolicy.writingToolsAvailable(session.state, activity: engine.activity,
                    refusedSinceLastStoreSave: session.refusedWritingToolsSinceSave,
                    hasMarkedText: session.engine.textView?.hasMarkedText() == true) else {
                session.engine.writingToolsRefusalReason = String(localized: "Writing Tools unavailable — couldn't save a safety copy.")
                return false
            }
            let saved = session.isImporting && self.hasDurableImportCheckpoint(session) ? true : self.save(session)
            if !saved { _ = self.preserve(session) }
            guard saved, session.isPersisted,
                  self.store.recordVersion(noteID: session.noteID, reason: .beforeWritingTools) else {
                session.refusedWritingToolsSinceSave = true
                session.engine.writingToolsRefusalReason = String(localized: "Writing Tools unavailable — couldn't save a safety copy.")
                return false
            }
            return true
        }
        engine.onSelectionChange = { [weak session] range in session?.selection = range }
        updateWritingToolsAvailability(for: session)
    }

    private func updateWritingToolsAvailability(for session: NoteSession) {
        session.engine.setWritingToolsAvailable(NoteSessionPolicy.writingToolsAvailable(session.state,
            activity: session.engine.activity, refusedSinceLastStoreSave: session.refusedWritingToolsSinceSave,
            hasMarkedText: session.engine.textView?.hasMarkedText() == true))
    }

    private func remember(_ noteID: UUID) {
        defaults?.set(noteID.uuidString, forKey: Self.lastViewedKey)
    }

    private func touch(_ noteID: UUID) {
        recency.removeAll { $0 == noteID }
        recency.append(noteID)
        // Evict the least recently used clean sessions only.
        while cache.count > cacheLimit, let evict = recency.first(where: { id in
            guard let session = cache[id] else { return true }
            let presence: NoteSessionPolicy.Presence = isPageVisible && !isLibraryPresented && active === session
                ? .onScreen : .background
            // A session still holding a checkpoint claim keeps it reachable.
            return !session.usesWorkspaceBinding && session.recoveryClaim == nil
                && NoteSessionPolicy.canEvict(session.state, activity: session.engine.activity,
                                              hasBatch: session.isImporting, presence: presence)
        }) {
            recency.removeAll { $0 == evict }
            cache[evict]?.saveTask?.cancel()
            cache[evict]?.durabilityTask?.cancel()
            cache[evict]?.pauseTask?.cancel()
            cache[evict]?.engine.detachView()
            cache[evict] = nil
        }
    }

    private func agentDisposition(for noteID: UUID) -> NoteAgentWriteDisposition {
        if journal?.requiresAsyncIO == true && !didRecoverAtLaunch { return .refuse("Recovery is still being checked. Retry after it completes.") }
        guard let session = cache[noteID] else { return .direct }
        let presence: NoteSessionPolicy.Presence = session.workspacePage?.activeLease != nil || (isPageVisible && !isLibraryPresented && active === session)
            ? .onScreen : .background
        switch NoteSessionPolicy.agentDisposition(presence, state: session.state, hasBatch: session.isImporting) {
        case .proposal: return .proposal
        case .direct: return .direct
        case .refuseImport: return .refuse("Images are being added to this note. Try again when they finish.")
        case .flush:
            guard preserve(session), case .clean = session.state else {
                return .refuse("Attic has unsaved text for this note. Try again after it is saved.")
            }
            return .direct
        }
    }

    // MARK: Leaving

    /// The single boundary used by note navigation, the shell, hide and quit.
    @discardableResult
    func prepareToLeave(_ reason: LeaveReason, verifiedCheckpointsOnly: Bool = false) -> Bool {
        if reason != .openNote { openRequestGeneration &+= 1 }
        let visibleSession = (reason == .hide || reason == .pageSwitch || reason == .quit) ? (taskNotePresenter?.session ?? active) : active
        if let active = visibleSession, !canLeaveComposition(in: active) { return false }
        let retainsSession = reason == .hide || reason == .pageSwitch
        if reason == .hide || reason == .quit {
            guard preserveAll(allowQueued: retainsSession, verifiedCheckpointsOnly: verifiedCheckpointsOnly) else { return false }
        } else if let session = visibleSession {
            captureViewState(session)
            guard preserve(session, allowQueued: retainsSession, verifiedCheckpointsOnly: verifiedCheckpointsOnly) else { return false }
        }
        endProposalReview()
        if let session = visibleSession {
            // The session and its history survive navigation (and may keep
            // their native view during a transition). A new visit must start
            // a new typing run even when its caret returns to the same edge.
            session.engine.history.breakCoalescing()
            if session.isPersisted, !NoteSessionPolicy.hasPendingWork(session.state) {
                store.recordVersion(noteID: session.noteID, reason: .leave)
                _ = store.applyPendingEdits(noteID: session.noteID)
            }
            if session.isUntouchedDraft { cache[session.noteID] = nil }
            session.pauseTask?.cancel()
        }
        if reason == .pageSwitch || reason == .hide || reason == .quit {
            taskNotePresenter?.model.setFocusInside(false)
            taskNotePresenter?.model.setPointerInside(false)
            isPageVisible = false
        }
        closeHistory()
        return true
    }

    private func canLeaveComposition(in session: NoteSession) -> Bool {
        session.engine.refreshCompositionActivity()
        if session.engine.writingToolsBeganInView,
           let textView = session.engine.textView,
           textView.isWritingToolsActive,
           let coordinator = textView.writingToolsCoordinator {
            coordinator.stopWritingTools()
            // The coordinator may finish through AppKit's delegate later.
            // Keep the panel visible until the text view reports it inactive.
            if textView.isWritingToolsActive {
                session.showNotice(NoteNotice(kind: .finishFirst, detail: String(localized: "Finish Writing Tools first.")))
                return false
            }
            if session.engine.activity == .writingToolsSafe || session.engine.activity == .writingToolsRefused {
                session.engine.writingToolsDidEnd()
            }
        }
        if session.engine.writingToolsBeganInView,
           session.engine.activity == .writingToolsSafe || session.engine.activity == .writingToolsRefused,
           session.engine.textView?.isWritingToolsActive == false {
            session.engine.writingToolsDidEnd()
        }
        guard NoteSessionPolicy.canLeave(session.engine.activity,
                hasMarkedText: session.engine.textView?.hasMarkedText() == true) else {
            session.showNotice(NoteNotice(kind: .finishFirst, detail:
                session.engine.activity == .writingToolsSafe || session.engine.activity == .writingToolsRefused
                ? String(localized: "Finish Writing Tools first.")
                : String(localized: "Finish composing text before leaving this note.")))
            return false
        }
        return true
    }

    func showLibrary() -> Bool {
        openRequestGeneration &+= 1
        guard prepareToLeave(.library) else { return false }
        isLibraryPresented = true
        return true
    }

    func dismissLibrary() {
        openRequestGeneration &+= 1
        isLibraryPresented = false
        guard active != nil else {
            // The note on screen was deleted: the last note visited, else a new draft.
            if let last = lastViewedNoteID, store.note(withID: last) != nil, open(noteID: last) { return }
            _ = newNote()
            return
        }
        present()
    }

    /// The shell's flush (hide, quit, page switch): every session with
    /// unsaved text is saved or checkpointed. False only when some draft is
    /// in memory alone.
    @discardableResult
    func preserveAll(allowQueued: Bool = false, verifiedCheckpointsOnly: Bool = false) -> Bool {
        guard !undoRoute.hasQueuedWorkspaceTyping else { return false }
        if let active { captureViewState(active) }
        if let session = taskNotePresenter?.session { captureViewState(session) }
        var ok = true
        for session in cache.values where NoteSessionPolicy.hasPendingWork(session.state) || session.isImporting {
            ok = preserve(session, allowQueued: allowQueued, verifiedCheckpointsOnly: verifiedCheckpointsOnly) && ok
        }
        return ok
    }

    /// Save, else checkpoint, else keep in memory and say so.
    @discardableResult
    func preserve(_ session: NoteSession, allowQueued: Bool = false, verifiedCheckpointsOnly: Bool = false) -> Bool {
        guard session.engine.history.workspace?.hasQueuedTyping != true else {
            session.showNotice(NoteNotice(kind: .finishFirst, detail: String(localized: "Your typing is waiting for the editor to finish opening.")))
            return false
        }
        // This session already has a durable checkpoint, owned by its source.
        // Navigation must neither overwrite it nor adopt its missing payloads.
        if session.recoverySourceNoteID != nil { return hasDurableCheckpoint(session) }
        if verifiedCheckpointsOnly {
            guard !session.cancellingImport else { return false }
            return (!NoteSessionPolicy.hasPendingWork(session.state) && !session.isImporting)
                || hasDurableCheckpoint(session)
        }
        session.saveTask?.cancel()
        session.engine.refreshCompositionActivity()
        if session.isImporting { return checkpoint(session, silent: true, allowQueued: allowQueued) }
        if NoteSessionPolicy.dueSaveAction(session.state, activity: session.engine.activity,
                hasMarkedText: session.engine.textView?.hasMarkedText() == true) == .checkpointOnly {
            return checkpoint(session, silent: true, allowQueued: allowQueued)
        }
        guard NoteSessionPolicy.hasPendingWork(session.state) else { return true }
        if save(session) { return true }
        return checkpoint(session, silent: false, allowQueued: allowQueued)
    }

    /// An activity can defer a store write without making the status say it failed.
    private func checkpoint(_ session: NoteSession, silent: Bool, allowQueued: Bool = false) -> Bool {
        // The live batch keeps its byte ownership until cancellation commits,
        // but no callback may checkpoint it back into recoverable pending work.
        guard !session.cancellingImport else { return false }
        guard let journal else {
            session.state = .onlyInMemory(String(localized: "There is no recovery copy for this note."))
            return false
        }
        retiredNoteIDs.remove(session.noteID)
        if journal.requiresAsyncIO {
            do {
                let document = checkpointDocument(for: session)
                let entry = try journalEntry(for: session, document: document)
                var key = entry; key.savedAt = .distantPast
                if checkpointKeys[session.id] == key && session.recoveryClaim != nil {
                    checkpointKeys[session.id] = nil
                    return true
                }
                // Keep the draft and its bytes in memory while the serialized
                // service commits. Retained-session navigation may proceed;
                // replacement and quit wait for the verified checkpoint.
                let bytes = journalStaged(for: session, document: document)
                let noteID = session.noteID, generation = session.editGeneration
                let stamp = session.callbackStamp
                queueRecoveryWork { [weak self, session] in
                    guard let self, session.noteID == noteID else { return }
                    if self.checkpointKeys[session.id] == key && session.recoveryClaim != nil { return }
                    do {
                        self.retiredNoteIDs.remove(noteID)
                        let claim = try await journal.writeDurably(entry, staged: bytes, replacing: session.recoveryClaim)
                        guard session.noteID == noteID else { return }
                        session.recoveryClaim = claim
                        if session.noticeValue?.kind == .saving || session.noticeValue?.kind == .stillSaving { session.notice = nil }
                        if session.accepts(stamp) {
                            self.checkpointKeys[session.id] = key
                            self.verifiedCheckpointKeys[session.id] = key
                            self.verifiedCheckpointOwners[session.id] = (generation, claim)
                        }
                        if session.isConflict { return }
                        if !silent { session.state = .notSaved(self.storeMessage()) }
                    } catch {
                        self.recoveryFailureCount += 1
                        if session.notice == "Saving recovery data…" { session.notice = nil }
                        session.state = .onlyInMemory("Recovery could not be saved: \(error.localizedDescription)")
                    }
                }
                session.showNotice(NoteNotice(kind: .saving, detail: "Saving recovery data…"))
                return allowQueued
            } catch { session.state = .onlyInMemory(error.localizedDescription); return false }
        }
        do {
            let document = checkpointDocument(for: session)
            session.recoveryClaim = try journal.write(journalEntry(for: session, document: document),
                staged: journalStaged(for: session, document: document), replacing: session.recoveryClaim)
            if !silent, !NoteSessionPolicy.needsAttention(session.state) { session.state = .notSaved(storeMessage()) }
            return true
        } catch {
            session.state = .onlyInMemory("The recovery copy failed: \(error.localizedDescription)")
            return false
        }
    }

    private func storeMessage() -> String {
        store.lastErrorMessage ?? String(localized: "The note could not be saved.")
    }

    private func checkpointDocument(for session: NoteSession) -> NoteDocument {
        session.engine.checkpointDocument()
    }

    private func journalEntry(for session: NoteSession, document: NoteDocument) throws -> NoteDraftJournalEntry {
        let inventory = liveByteInventory(in: session, document: document)
        let staged = inventory.staged
        var entry = NoteDraftJournalEntry(
            noteID: session.noteID,
            isPersisted: session.isPersisted,
            baseRevisionID: session.baseRevisionID,
            content: try NoteContentCodec.encode(document),
            selectionLocation: session.selection.location,
            selectionLength: session.selection.length,
            scrollOffset: Double(session.scrollOffset),
            staged: staged.map { .init(id: $0.id, filename: $0.filename, contentTypeIdentifier: $0.contentTypeIdentifier,
                                       byteCount: $0.byteCount, digest: $0.digest) },
            savedAt: now(),
            tags: session.engine.tags,
            tagsChanged: session.isPersisted ? session.pendingTags != nil : !session.engine.tags.isEmpty
        )
        entry.pendingImport = inventory.pendingImport
        entry.taskOwnerID = session.isPersisted ? nil : session.pendingTaskID
        return entry
    }

    private func journalStaged(for session: NoteSession, document: NoteDocument) -> [StagedNoteAttachment] {
        liveByteInventory(in: session, document: document).staged
    }

    // MARK: Saving

    /// All paths that replace a stored document or rekey a draft use this gate.
    private func canCommit(_ session: NoteSession, resolvingConflict: Bool = false) -> Bool {
        guard session.recoverySourceNoteID == nil else { return false }
        return NoteSessionPolicy.canWriteStore(resolvingConflict ? .dirty : session.state,
            activity: session.engine.activity,
            hasMarkedText: session.engine.textView?.hasMarkedText() == true)
    }

    private func textDidChange(in session: NoteSession) {
        guard !session.isReadOnly else { return }
        if let step = versionRestoreUndo, !step.isUndo, step.noteID == session.noteID,
           !session.engine.history.isTraversing {
            store.historyRetainedVersionIDs.remove(step.versionID)
            versionRestoreUndo = nil
        }
        if !NoteSessionPolicy.hasPendingWork(session.state) { session.state = .dirty }
        session.editGeneration &+= 1
        session.lastEditAt = now()
        updateWritingToolsAvailability(for: session)
        scheduleSave(session)
        scheduleDurabilityDeadline(session)
    }

    private func scheduleSave(_ session: NoteSession) {
        session.saveTask?.cancel()
        let delay = saveDelay
        session.saveTask = Task { @MainActor [weak self, weak session] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, let session, !Task.isCancelled else { return }
            await self.runDueSave(session)
        }
    }

    /// Typing may reset the coalescing timer, but never this session's deadline.
    private func scheduleDurabilityDeadline(_ session: NoteSession) {
        guard session.durabilityTask == nil, NoteSessionPolicy.hasPendingWork(session.state) else { return }
        let delay = durabilityDelay
        session.durabilityTask = Task { @MainActor [weak self, weak session] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, let session, !Task.isCancelled else { return }
            let generation = session.editGeneration
            await self.runDurabilityDeadline(session)
            guard !Task.isCancelled else { return }
            session.durabilityTask = nil
            // Pending work can stay pending after a failure or conflict.
            // Only edits made during this attempt justify another deadline.
            if session.editGeneration != generation { self.scheduleDurabilityDeadline(session) }
        }
    }

    func runDurabilityDeadline(_ session: NoteSession) async {
        await runDueSaveWork(session, isDeadline: true)
        await waitForRecoveryWork()
        checkpointKeys[session.id] = nil
    }

    /// The timer body is separate so the lifecycle matrix can fire it without
    /// wall-clock waits; production still waits for the coalescing delay.
    func runDueSave(_ session: NoteSession) async {
        await runDueSaveWork(session)
        await waitForRecoveryWork()
        checkpointKeys[session.id] = nil
    }

    private func runDueSaveWork(_ session: NoteSession, isDeadline: Bool = false) async {
        session.engine.refreshCompositionActivity()
        if session.isImporting { _ = checkpoint(session, silent: true); return }
        if NoteSessionPolicy.dueSaveAction(session.state, activity: session.engine.activity,
                hasMarkedText: session.engine.textView?.hasMarkedText() == true) == .checkpointOnly {
            _ = checkpoint(session, silent: true)
            return
        }
        let generation = session.editGeneration
        let stamp = session.callbackStamp
        let tags = session.engine.tags
        let document = session.engine.document()
        let staged = session.engine.stagedAttachments(for: document)
        let prepared = await prepareDocument(document)
        guard !Task.isCancelled, session.accepts(stamp, retainingNewerDraft: isDeadline) else { return }
        if session.isImporting { _ = checkpoint(session, silent: true); return }
        guard let prepared else { _ = preserve(session); return }
        if !save(session, snapshot: document, stagedSnapshot: staged, prepared: prepared,
                 tagsSnapshot: tags, retainingNewerEdits: generation != session.editGeneration) {
            _ = preserve(session)
        }
    }

    /// Writes the session to the store now. A never-saved draft with no
    /// content is not written (and counts as saved).
    @discardableResult
    func save(_ session: NoteSession, snapshot: NoteDocument? = nil,
              stagedSnapshot: [StagedNoteAttachment]? = nil, prepared: PreparedNoteDocument? = nil,
              tagsSnapshot: [String]? = nil, retainingNewerEdits: Bool = false) -> Bool {
        if session.engine.history.workspace?.hasPendingPublication == true {
            session.state = .notSaved(String(localized: "Couldn't finish saving the workspace change."))
            return false
        }
        guard !session.isImporting else { return checkpoint(session, silent: true) }
        guard canCommit(session) else { return false }
        guard NoteSessionPolicy.hasPendingWork(session.state) else { return true }
        guard !session.isReadOnly else { return true }
        let engine = session.engine
        let generation = session.editGeneration
        let liveDocument = engine.document()
        let document = snapshot ?? liveDocument
        let staged = stagedSnapshot ?? engine.stagedAttachments(for: document)
        let tags = tagsSnapshot ?? session.engine.tags
        // A caller flag is not proof that a captured snapshot covers the live
        // draft. Keep newer text and tags owned even if the caller omits it.
        let retainingNewerEdits = retainingNewerEdits
            || document != liveDocument || tags != engine.tags
        if !session.isPersisted {
            guard !NoteSession.hasNoWriting(document, taskDraft: session.pendingTaskID != nil)
                    || !document.objectIDs.isEmpty || !tags.isEmpty else {
                session.state = retainingNewerEdits ? .dirty : .untouched
                return true
            }
            switch store.createDocumentNote(id: session.noteID, document: document, staged: staged,
                                            prepared: prepared, tags: tags.isEmpty ? nil : tags,
                                            taskOwner: session.pendingTaskID) {
            case let .success((noteID, revisionID)):
                session.isPersisted = true
                if let owner = session.pendingTaskID {
                    session.pendingTaskID = nil
                    taskNoteCreated?(owner, noteID)
                }
                session.baseRevisionID = revisionID
                session.baseTags = tags
                didSave(session, staged: staged, retainingNewerEdits: retainingNewerEdits || generation != session.editGeneration)
                remember(noteID)
                return true
            case .failure(.noteMissing):
                session.state = .conflict(.deleted)
                return false
            case .failure(.staleRevision):
                session.state = .conflict(.changed)
                return false
            case .failure:
                return false
            }
        }
        let pendingTags = tags == session.baseTags ? nil : tags
        switch store.saveDocument(noteID: session.noteID, document: document,
                                  baseRevisionID: session.baseRevisionID, staged: staged, prepared: prepared,
                                  tags: pendingTags) {
        case let .success(revisionID):
            // Only this controller's successful writes advance the replay
            // boundary. An imported/external revision must still refuse Undo.
            if var step = versionRestoreUndo, step.noteID == session.noteID,
               step.restoredRevisionID == session.baseRevisionID {
                step.restoredRevisionID = revisionID
                versionRestoreUndo = step
            }
            session.baseRevisionID = revisionID
            if let pendingTags { session.baseTags = pendingTags }
            didSave(session, staged: staged, retainingNewerEdits: retainingNewerEdits || generation != session.editGeneration)
            return true
        case .failure(.noteMissing):
            session.state = .conflict(.deleted)
            return false
        case .failure(.staleRevision):
            session.state = .conflict(.changed)
            return false
        case .failure:
            return false
        }
    }

    /// The explicit escape from a stale base. The original note is untouched.
    @discardableResult
    func keepAsNewNote() -> Bool { keepAsNewNote(stored: []) }

    private func keepAsNewNote(stored: [StagedNoteAttachment]) -> Bool {
        guard let session = active,
              NoteSessionPolicy.keepAsNewAllowed(session.state, activity: session.engine.activity,
                                                 hasBatch: session.isImporting,
                                                 hasMarkedText: session.engine.textView?.hasMarkedText() == true),
              preserve(session) else { return false }
        let document = checkpointDocument(for: session)
        let notice = session.state == .conflict(.deleted)
            ? String(localized: "Your text was kept as a new note. The deleted note remains in Recently Deleted.")
            : String(localized: "Your text was kept as a new note. The changed note is still available.")
        return saveAsNewNote(session, document: document,
            staged: session.engine.stagedAttachments(for: document) + stored,
            successNotice: notice)
    }

    private func saveAsNewNote(_ session: NoteSession, document: NoteDocument,
                               staged: [StagedNoteAttachment], successNotice: String) -> Bool {
        guard canCommit(session, resolvingConflict: true) else { return false }
        let oldID = session.noteID
        guard let (replacement, images) = replacementForDeletedNote(document, oldID: oldID, staged: staged) else {
            session.showNotice(NoteNotice(kind: .imageGone, detail: String(localized: "An image is unavailable, so this draft remains in recovery until it can be restored.")))
            return false
        }
        let tags = session.engine.tags
        guard case let .success((newID, revisionID)) = store.createDocumentNote(id: UUID(), document: replacement,
                                                                                  staged: images,
                                                                                  tags: tags.isEmpty ? nil : tags) else {
            session.showNotice(NoteNotice(kind: .notSaved, detail: String(localized: "Couldn’t save a new note; your text is still in recovery.")))
            return false
        }
        cache[oldID] = nil
        // The old checkpoint belongs to the old ID; the new note has none.
        let oldClaim = session.recoveryClaim
        session.recoveryClaim = nil
        retiredNoteIDs.remove(newID)
        session.adopt(noteID: newID)
        session.replaceEngine(makeEngine(noteID: newID, document: replacement, readOnly: false, tags: tags))
        session.baseTags = tags
        wire(session)
        if active === session { active = session }
        cache[newID] = session
        touch(newID)
        session.baseRevisionID = revisionID
        session.showNotice(NoteNotice(kind: .noteSaved, detail: successNotice))
        didSave(session, staged: images)
        if let journal {
            do {
                if let oldClaim {
                    if journal.requiresAsyncIO {
                        queueRecoveryWork {
                            do { try await journal.discardOwnedDurably(noteID: oldID, claim: oldClaim) }
                            catch { session.showNotice(NoteNotice(kind: .copyKept, detail: "Your text was saved, but its old recovery copy is being kept until it can be checked.")) }
                        }
                    } else { try journal.discardOwned(noteID: oldID, claim: oldClaim) }
                }
            } catch {
                session.showNotice(NoteNotice(kind: .copyKept, detail: String(localized: "Your text was saved, but its old recovery copy is being kept until it can be checked.")))
            }
        }
        remember(newID)
        return true
    }

    private func didSave(_ session: NoteSession, staged: [StagedNoteAttachment], retainingNewerEdits: Bool = false) {
        captureViewState(session)
        session.baseContent = store.note(withID: session.noteID)?.content
        session.state = retainingNewerEdits ? .dirty : .clean
        if retainingNewerEdits { scheduleSave(session) }
        if !retainingNewerEdits {
            session.durabilityTask?.cancel()
            session.durabilityTask = nil
        }
        session.refusedWritingToolsSinceSave = false
        updateWritingToolsAvailability(for: session)
        for item in staged { session.verifiedDocumentAttachments[item.id] = item }
        if !session.verifiedDocumentAttachments.isEmpty {
            let liveIDs = Set(session.engine.checkpointDocument().attachmentIDs)
            session.verifiedDocumentAttachments = session.verifiedDocumentAttachments.filter { liveIDs.contains($0.key) }
        }
        session.engine.forgetStaged(Set(staged.map(\.id)))
        if !retainingNewerEdits { clearRecoveryCopy(for: session) }
        schedulePauseVersion(session)
    }

    private func clearRecoveryCopy(for session: NoteSession) {
        if !retireRecoveryCopy(noteID: session.noteID, session: session), journal?.requiresAsyncIO != true {
            active?.showNotice(NoteNotice(kind: .copyKept, detail: String(localized: "Saved, but an old recovery copy could not be cleared.")))
        }
    }

    /// Retires a note's recovery copy through the journal's ownership rule:
    /// the session's own checkpoint, or one the saved note proves redundant.
    /// A live file batch keeps its checkpoint. Unknown ownership remains on
    /// disk with its staged bytes.
    fileprivate func retireRecoveryCopy(noteID: UUID, session: NoteSession?) -> Bool {
        guard let journal else { return true }
        guard session?.isImporting != true else { return false }
        if journal.requiresAsyncIO {
            if recoveryWork == nil, retiredNoteIDs.contains(noteID) { return true }
            if recoveryWork == nil, let entries = try? journal.recoveryEntries(),
               !entries.contains(where: { entry in
                   switch entry {
                   case let .valid(checkpoint, _, _): return checkpoint.noteID == noteID
                   case .damaged: return true // Unknown ownership must not be guessed absent.
                   }
               }) { return true }
            queueRecoveryWork { [weak self, weak session] in
                guard let self else { return }
                do {
                    let note = self.store.note(withID: noteID)
                    let bytes = note?.content
                    let format = note?.contentFormat
                    let revisionID = note?.revisionID
                    let tags = note?.tags ?? []
                    let claim = session?.recoveryClaim
                    let document: NoteDocument?
                    if note?.usesDocumentFormat == true {
                        guard let bytes, let decoded = await self.decodeRecoveryDocument(bytes) else {
                            throw DamagedNoteRecovery()
                        }
                        document = decoded
                    } else { document = nil }
                    let attachments = await self.durableAttachmentsAsync(in: document ?? .blank)
                    // Decoding and byte verification suspend. Never release recovery
                    // using a proof of a store or ownership state that has since changed.
                    let current = self.store.note(withID: noteID)
                    guard current?.contentFormat == format, current?.revisionID == revisionID,
                          current?.content == bytes, (current?.tags ?? []) == tags,
                          session?.recoveryClaim == claim, session?.isImporting != true else {
                        throw DamagedNoteRecovery()
                    }
                    let saved = document.map { NoteRecoverySavedState(document: $0, tags: tags, attachments: attachments) }
                    try await journal.retireDurably(noteID: noteID, claim: claim, saved: saved)
                    self.retiredNoteIDs.insert(noteID)
                    session?.recoveryClaim = nil
                    if session?.noticeValue?.kind == .copyKept { session?.notice = nil }
                    if let session {
                        self.checkpointKeys[session.id] = nil
                        self.verifiedCheckpointKeys[session.id] = nil
                        self.verifiedCheckpointOwners[session.id] = nil
                    }
                } catch {
                    self.recoveryFailureCount += 1
                    let message = "Saved recovery is being kept because its bytes could not be handed off safely."
                    if let session { session.showNotice(NoteNotice(kind: .notSaved, detail: message)) } else { self.active?.showNotice(NoteNotice(kind: .copyKept, detail: message)) }
                }
            }
            return false
        }
        do {
            try journal.retire(noteID: noteID, claim: session?.recoveryClaim, saved: { [store] in
                store.loadDocument(noteID: noteID)?.content.document.map {
                    NoteRecoverySavedState(document: $0, tags: store.note(withID: noteID)?.tags ?? [],
                        attachments: self.durableAttachments(in: $0))
                }
            })
            session?.recoveryClaim = nil
            return true
        } catch {
            return false
        }
    }

    /// A version after 2 minutes without edits.
    private func schedulePauseVersion(_ session: NoteSession) {
        session.pauseTask?.cancel()
        let delay = pauseVersionDelay
        session.pauseTask = Task { @MainActor [weak self, weak session] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, let session, !Task.isCancelled, session.isPersisted, !session.isImporting,
                  !NoteSessionPolicy.hasPendingWork(session.state) else { return }
            self.store.recordVersion(noteID: session.noteID, reason: .pause)
        }
    }

    /// Retry from the slot.
    func retry() {
        guard let active else { return }
        retry(active)
    }
    func retry(_ session: NoteSession) {
        if let history = session.engine.history.workspace, history.hasPendingPublication {
            history.requestPublicationRetry()
            if history.permitsUnsavedDraft { _ = preserve(session) }
            return
        }
        if case .conflict = session.state { return }
        _ = preserve(session)
    }

    /// Copy Text from the slot: the draft as plain text.
    func copyActiveText() { copyActiveText(to: .general) }

    func copyActiveText(to pasteboard: NSPasteboard) {
        guard let active else { return }
        pasteboard.clearContents()
        pasteboard.setString(active.engine.plainText, forType: .string)
    }

    // MARK: Recovery copy (Phase 2 audit, item 17)

    /// Asks where to save a recovery copy; nil when the person cancels.
    /// Replaced in tests, which have no panel to click.
    var recoveryCopyDestination: @MainActor (_ suggestedName: String) -> URL? = { NotesPageController.askForRecoveryCopyLocation($0) }

    /// A recovery copy is offered while the note's text is held only here:
    /// "Only in memory" and "Not saved".
    func canSaveRecoveryCopy(_ session: NoteSession?) -> Bool {
        guard let session else { return false }
        switch session.state {
        case .onlyInMemory, .notSaved: return true
        default: return false
        }
    }

    /// Save Recovery Copy…: the note as it is now, with its structure and
    /// the images that can be read, into a folder the person chooses
    /// (`NoteRecoveryCopy` says what is in it). It changes nothing about the
    /// note, its state or its recovery journal; the result is said in the
    /// status slot, success or failure. False when nothing was written,
    /// including when the person cancels the panel.
    @discardableResult
    func saveRecoveryCopy(of session: NoteSession? = nil) async -> Bool {
        guard let session = session ?? active, canSaveRecoveryCopy(session) else { return false }
        session.engine.refreshCompositionActivity()
        do {
            let snapshot = try await recoverySnapshot(of: session)
            guard let destination = recoveryCopyDestination(NoteRecoveryCopy.suggestedName(title: snapshot.title)) else { return false }
            try await Task.detached(priority: .userInitiated) {
                try NoteRecoveryCopy.write(snapshot, to: destination)
            }.value
            var message = String(localized: "Recovery copy saved to “\(destination.lastPathComponent)”.")
            if !snapshot.unavailableAttachmentIDs.isEmpty {
                message += " " + String(localized: "\(snapshot.unavailableAttachmentIDs.count) image(s) couldn’t be read and are listed in its README.")
            }
            session.showNotice(NoteNotice(kind: .copySaved, severity: snapshot.unavailableAttachmentIDs.isEmpty ? .information : .caution, detail: message))
            return true
        } catch {
            session.showNotice(NoteNotice(kind: .copyFailed, detail: String(localized: "The recovery copy couldn’t be saved: \(error.localizedDescription)")))
            return false
        }
    }

    private func recoverySnapshot(of session: NoteSession) async throws -> NoteRecoverySnapshot {
        // The checkpoint document, as the journal writes it: during a refused
        // Writing Tools session that is the starting note, never the
        // in-place rewrite that got past the text guards. The files come
        // from that same document.
        let document = checkpointDocument(for: session)
        let inventory = liveByteInventory(in: session, document: document)
        let pending = inventory.pendingImport
        var attachments = inventory.staged
        var unavailable: [UUID] = []
        var seen = Set(attachments.map(\.id))
        for id in document.attachmentIDs where !seen.contains(id) {
            seen.insert(id)
            if let stored = await verifiedBytes(forAttachment: id) {
                attachments.append(stored)
            } else { unavailable.append(id) }
        }
        let names = Dictionary(attachments.map { ($0.id, $0.filename) }, uniquingKeysWith: { first, _ in first })
        let reason: String = switch session.state {
        case let .onlyInMemory(reason), let .notSaved(reason): reason
        default: ""
        }
        // The stored format, as the store would have written it. A note that
        // cannot be encoded is not "copied" without its structure: this
        // throws and the failure is said.
        let content = try NoteContentCodec.encode(document)
        return NoteRecoverySnapshot(
            noteID: session.recoverySourceNoteID ?? session.noteID, title: NoteStore.normalizedTitle(document.title), content: content,
            markdown: NoteMarkdownExport.markdown(document) { names[$0] },
            tags: session.engine.tags, reason: reason, savedAt: now(),
            attachments: attachments, unavailableAttachmentIDs: unavailable, pendingImport: pending)
    }

    @MainActor
    static func askForRecoveryCopyLocation(_ suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "Save Recovery Copy")
        panel.message = String(localized: "Saves a folder with this note’s text, structure and images. The note itself is not changed.")
        panel.prompt = String(localized: "Save")
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    // MARK: Recovery

    /// Materializes recovery drafts before agent access starts. Safe to call
    /// again from `start()` in tests that do not create an AppCoordinator.
    func recoveryStartupFailed(_ error: Error) {
        reportRecoveryRetentionWarning("Recovery could not be checked: \(error.localizedDescription)")
    }
    func recoverAtLaunch() {
        guard !didRecoverAtLaunch else { return }
        if let journal, journal.requiresAsyncIO {
            guard !recoveryLoading else { return }
            recoveryLoading = true
            queueRecoveryWork { [weak self] in
                guard let self else { return }
                do {
                    if let diskJournal = journal.workspaceJournal {
                        let coordinator = try WorkspaceLegacyBridge.coordinator(for: self.store.container)
                        if coordinator.journal !== diskJournal { try coordinator.adoptJournal(diskJournal) }
                        try await coordinator.finishLaunch()
                        self.workspaceRecoveryIssues = coordinator.operationRecoveryIssues
                    }
                    _ = try await journal.readRecoveryEntries()
                    // A faster guarded save can now reach missing-row repair
                    // while the store's existing cache collection still owns
                    // its bytes. Finish that work before this synchronous save.
                    await self.store.waitForAttachmentReconciliation()
                    // Prepare stored-byte proofs off-main before comparing
                    // matching checkpoint documents at startup.
                    var savedProofs: [UUID: [UUID: StagedNoteAttachment]] = [:]
                    for item in try journal.recoveryEntries() {
                        if case let .valid(entry, _, _) = item,
                           let doc = NoteContentCodec.decode(entry.content).document {
                            savedProofs[entry.noteID] = await self.durableAttachmentsAsync(in: doc)
                        }
                    }
                    self.recoverFromCachedJournal(savedProofs: savedProofs)
                } catch { self.recoveryWarnings.append("Recovery could not be checked: \(error.localizedDescription)") }
                self.recoveryLoading = false
                // A transient read/admission failure remains explicitly
                // retryable. Do not recursively retry a persistent failure.
                if self.startRequested && self.didRecoverAtLaunch { self.start() }
            }
            return
        }
        recoverFromCachedJournal()
    }

    private func recoverFromCachedJournal(savedProofs: [UUID: [UUID: StagedNoteAttachment]] = [:]) {
        guard let journal else { didRecoverAtLaunch = true; return }
        let entries: [NoteDraftRecoveryEntry]
        do { entries = try journal.recoveryEntries() }
        catch {
            recoveryWarnings.append("Recovery copies could not be listed: \(error.localizedDescription)")
            return
        }
        didRecoverAtLaunch = true
        for item in entries {
            guard case let .valid(entry, staged, claim) = item else {
                if case let .damaged(message) = item { recoveryWarnings.append(message); damagedRecoveryWarnings.insert(message) }
                continue
            }
            guard case let .editable(document) = NoteContentCodec.decode(entry.content) else {
                recoveryWarnings.append("Recovery copy for \(entry.noteID.uuidString) contains unreadable note content.")
                continue
            }
            let replicas: [NoteItem]
            do { replicas = try store.replicasIncludingDeleted(of: entry.noteID) }
            catch {
                recoveryWarnings.append("Recovery copy for \(entry.noteID.uuidString) could not be compared with the note store.")
                continue
            }
            let stored = store.loadDocument(noteID: entry.noteID)
            // A copy that matches the note as it was deleted (a delete made
            // here whose recovery copy could not be removed) holds nothing the
            // deleted note doesn't: it is retired, never a conflict.
            // Its tags must match too: a tag-only change is unsaved work.
            if stored == nil, let base = entry.baseRevisionID,
               replicas.contains(where: { replica in
                   replica.deletedAt != nil && replica.revisionID == base
                       && replica.content.flatMap { NoteContentCodec.decode($0).document } == document
                       && (entry.changedTags == nil || entry.changedTags == replica.tags)
               }) {
                let saved = NoteRecoverySavedState(document: document, tags: entry.changedTags ?? [],
                    attachments: savedProofs[entry.noteID] ?? durableAttachments(in: document))
                if staged.allSatisfy({ saved.attachments[$0.id] == $0 }) {
                    if journal.requiresAsyncIO {
                        queueRecoveryWork { try? await journal.retireDurably(noteID: entry.noteID, claim: claim, saved: saved) }
                        continue
                    } else if (try? journal.retire(noteID: entry.noteID, claim: claim, saved: { saved })) != nil { continue }
                }
            }
            let storedTags = store.note(withID: entry.noteID)?.tags ?? []
            if entry.pendingImport == nil, stored?.content.document == document,
               entry.changedTags == nil || entry.changedTags == storedTags {
                let saved = NoteRecoverySavedState(document: document, tags: entry.changedTags ?? [],
                    attachments: savedProofs[entry.noteID] ?? durableAttachments(in: document))
                if staged.allSatisfy({ saved.attachments[$0.id] == $0 }) {
                    if journal.requiresAsyncIO {
                        queueRecoveryWork { try? await journal.retireDurably(noteID: entry.noteID, claim: claim, saved: saved) }
                        continue
                    } else if (try? journal.retire(noteID: entry.noteID, claim: claim, saved: { saved })) != nil { continue }
                }
            }
            let available = Set(staged.map(\.id))
                .union(((try? store.attachmentRows(forNoteID: entry.noteID)) ?? []).map(\.id))
            guard Set(document.attachmentIDs).isSubset(of: available) else {
                let message = "Some attachments are unavailable. Copy Text or Save Recovery Copy to recover this draft; the original checkpoint and saved note are kept unchanged."
                recoveryWarnings.append(message)
                let displayID = UUID()
                let recovery = NoteSession(noteID: displayID, isPersisted: false, baseRevisionID: nil,
                    engine: makeEngine(noteID: displayID, document: document, readOnly: true, staged: staged,
                                       tags: entry.tags ?? storedTags), readOnlyReason: nil,
                    recoverySourceNoteID: entry.noteID)
                recovery.recoveryClaim = claim
                recovery.baseTags = entry.tags ?? storedTags
                recovery.state = .notSaved(message)
                recovery.selection = NSRange(location: entry.selectionLocation, length: entry.selectionLength)
                recovery.scrollOffset = CGFloat(entry.scrollOffset ?? 0)
                wire(recovery)
                cache[displayID] = recovery
                touch(displayID)
                newestRecovered = recovery
                continue
            }
            if let pending = entry.pendingImport,
               !Set(pending.items.compactMap(\.stagedID)).isSubset(of: Set(staged.map(\.id))) {
                recoveryWarnings.append("A pending file batch for \(entry.noteID.uuidString) has missing staged bytes.")
                continue
            }
            let session = NoteSession(noteID: entry.noteID,
                isPersisted: stored != nil || entry.baseRevisionID != nil || !replicas.isEmpty,
                baseRevisionID: entry.baseRevisionID,
                engine: makeEngine(noteID: entry.noteID, document: document, readOnly: false, staged: staged,
                                   tags: entry.tags ?? storedTags,
                                   bodyOnly: store.note(withID: entry.noteID)?.taskID != nil),
                readOnlyReason: nil)
            // Unchanged tags stay the stored ones' business (nothing is written
            // over them), yet the draft keeps them, even if its note is gone.
            session.baseTags = entry.changedTags == nil ? (entry.tags ?? storedTags) : storedTags
            // A never-saved task draft keeps its owner: its first save still
            // creates the task's note (the store refuses a second one).
            if !session.isPersisted { session.pendingTaskID = entry.taskOwnerID }
            retiredNoteIDs.remove(entry.noteID)
            session.recoveryClaim = claim
            wire(session)
            session.selection = NSRange(location: entry.selectionLocation, length: entry.selectionLength)
            session.scrollOffset = CGFloat(entry.scrollOffset ?? 0)
            let deleted = stored == nil && (entry.baseRevisionID != nil || replicas.contains { $0.deletedAt != nil })
            if let pending = entry.pendingImport, !deleted {
                let byID = Dictionary(staged.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                var items = pending.items.map { item -> NoteImportedObject in
                    if let id = item.stagedID, let payload = byID[id] {
                        let size: CGSize? = if let width = item.pixelWidth, let height = item.pixelHeight {
                            CGSize(width: width, height: height)
                        } else { nil }
                        return NoteImportedObject(staged: payload, pixelSize: size)
                    }
                    return NoteImportedObject(filename: item.filename,
                        contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount,
                        failure: item.failure ?? String(localized: "Import interrupted. Retry this file."))
                }
                items += pending.remainingNames.map { name in
                    NoteImportedObject(filename: name,
                        contentTypeIdentifier: (UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension) ?? .data).identifier,
                        byteCount: 0, failure: String(localized: "Import interrupted. Retry this file."))
                }
                session.engine.restoreImageImport(anchor: pending.anchor,
                    replacementLength: pending.replacementLength ?? 0, isBoundary: pending.isBoundary ?? false)
                session.importBatch = NoteImportBatch(id: UUID(),
                    urls: (pending.items.map(\.filename) + pending.remainingNames).map { URL(fileURLWithPath: $0) },
                    acceptedText: pending.acceptedText, completed: items.count, loaded: items)
            }
            if deleted {
                session.state = .conflict(.deleted)
            } else if (entry.baseRevisionID == nil && !replicas.isEmpty)
                        || (entry.baseRevisionID != nil && stored?.revisionID != entry.baseRevisionID) {
                session.state = .conflict(.changed)
            } else {
                session.state = .dirty
                if session.isImporting {
                    completeImportIfPossible(in: session)
                } else if !save(session), !session.isConflict {
                    session.state = .notSaved(storeMessage())
                }
            }
            session.showNotice(NoteNotice(kind: .textRestored, detail: String(localized: "Restored unsaved text.")))
            cache[session.noteID] = session
            touch(session.noteID)
            newestRecovered = session
        }
        if !recoveryWarnings.isEmpty { newestRecovered?.showNotice(NoteNotice(kind: .damaged, detail: recoveryWarnings.joined(separator: " "))) }
    }

    private func captureViewState(_ session: NoteSession) {
        guard session.isPersisted else { return }
        if let scroll = session.engine.scrollView {
            session.scrollOffset = max(0, scroll.contentView.bounds.origin.y)
        }
        defaults?.set(["location": session.selection.location,
                       "length": session.selection.length,
                       "scroll": Double(session.scrollOffset)],
                      forKey: Self.viewStateKey(session.noteID))
    }

    private func pruneObsoleteViewState() {
        guard let defaults else { return }
        let recovery: [NoteDraftRecoveryEntry]
        do { recovery = try journal?.recoveryEntries() ?? [] }
        catch { return }
        // A damaged journal may still own a draft whose ID cannot be decoded.
        guard recovery.allSatisfy({ if case .valid = $0 { return true }; return false }) else { return }
        let retained = Set(store.notes.map(\.id)).union(recovery.compactMap { item -> UUID? in
            if case let .valid(entry, _, _) = item { return entry.noteID }
            return nil
        })
        let prefix = "notes.viewState."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            guard let id = UUID(uuidString: String(key.dropFirst(prefix.count))), !retained.contains(id) else { continue }
            defaults.removeObject(forKey: key)
        }
    }

    private func replacementForDeletedNote(_ original: NoteDocument, oldID: UUID,
                                           staged: [StagedNoteAttachment])
        -> (NoteDocument, [StagedNoteAttachment])? {
        var replacement = original
        var copied = staged
        var mapping: [UUID: UUID] = [:]
        for index in replacement.blocks.indices where replacement.blocks[index].kind == .image
            || replacement.blocks[index].kind == .file {
            guard let oldAttachmentID = replacement.blocks[index].attachmentID else {
                replacement.blocks[index].id = UUID()
                continue
            }
            let newID: UUID
            if let existing = mapping[oldAttachmentID] {
                newID = existing
            } else {
                guard let source = staged.first(where: { $0.id == oldAttachmentID })
                    ?? attachmentBytes(forAttachment: oldAttachmentID) else { return nil }
                guard source.byteCount > 0, source.byteCount <= AttachmentLimits.maxBytesPerAttachment,
                      source.byteCount == Int64(source.data.count) else { return nil }
                newID = UUID()
                mapping[oldAttachmentID] = newID
                copied.append(source.copying(id: newID))
            }
            replacement.blocks[index].attachmentID = newID
            replacement.blocks[index].id = UUID()
        }
        return (replacement, copied)
    }

    private func validImagePayload(_ item: StagedNoteAttachment) -> Bool {
        item.byteCount > 0 && item.byteCount <= AttachmentLimits.maxBytesPerAttachment
            && item.byteCount == Int64(item.data.count)
            && item.payloadIsVerified
            && UTType(item.contentTypeIdentifier)?.conforms(to: .image) == true
            && NoteImageDecoder.pixelSize(of: item.data) != nil
    }

    // MARK: Look and images

    /// Counts the proposed document's logical IDs, including retained rows
    /// and unsaved draft objects. A batch passes its earlier accepted sources.
    func importAdmissionFailure(_ payload: StagedNoteAttachment, in session: NoteSession,
                                        earlier: [NoteImportedObject] = []) -> String? {
        let accepted = earlier.compactMap(\.staged)
        var proposed = session.engine.documentAfterRemovingImportTarget()
        proposed.blocks += (accepted + [payload]).map { item in
            .file(attachmentID: item.id, filename: item.filename,
                  contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)
        }
        return attachmentAdmissionFailure(proposed: proposed, additions: accepted + [payload], in: session)
    }

    /// The store's complete admission rule is also the pre-edit rule. New
    /// placements of missing originals cannot pass by reusing an old byte ID.
    private func attachmentAdmissionFailure(proposed: NoteDocument, additions: [StagedNoteAttachment],
                                            in session: NoteSession) -> String? {
        guard !session.isPersisted || store.note(withID: session.noteID) != nil else {
            return String(localized: "The note is no longer in the library.")
        }
        let staged = Dictionary((Array(session.engine.staged.values) + additions).map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }).values.map { $0 }
        let metadataOnly = Set(additions.filter { $0.data.isEmpty && $0.digest.isEmpty }.map(\.id))
        return store.attachmentAdmissionFailure(noteID: session.noteID, document: proposed,
            staged: staged, metadataOnlyIDs: metadataOnly)
    }

    func sourceAdmissionFailure(_ url: URL, in session: NoteSession,
                                earlier: [NoteImportedObject] = []) -> (Int64?, String?) {
        let scoped = url.startAccessingSecurityScopedResource()
        var metadataURL = url; metadataURL.removeAllCachedResourceValues()
        let size = (try? metadataURL.resourceValues(forKeys: [.fileSizeKey])).flatMap(\.fileSize).map(Int64.init)
        if scoped { url.stopAccessingSecurityScopedResource() }
        let probe = StagedNoteAttachment(id: UUID(), filename: url.lastPathComponent,
            contentTypeIdentifier: (UTType(filenameExtension: url.pathExtension) ?? .data).identifier,
            byteCount: size ?? 1, digest: "", data: Data())
        return (size, importAdmissionFailure(probe, in: session, earlier: earlier))
    }

    func update(design: AtticDesignContext) {
        guard design != self.design else { return }
        self.design = design
        for session in cache.values { session.engine.update(design: design) }
    }

    /// Paste, drop and Insert use this batch path. Slash uses its captured single-item commit path. Files are read
    /// away from the main actor, then inserted with the accepted text as one
    /// editor-history step. Its anchor belongs to the note, not the caret.
    func importFiles(_ urls: [URL], acceptedText: String = "", at selection: NSRange? = nil,
                     temporaryURLs: [URL] = [], clipboardData: Data? = nil, into target: NoteSession? = nil) {
        // A task's page imports into its workspace session (Phase 3); the
        // Notes page into the active one.
        guard let session = target ?? active, !session.isReadOnly, !urls.isEmpty else {
            temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            return
        }
        guard NoteSessionPolicy.commandAllowed(session.engine.activity,
                hasMarkedText: session.engine.textView?.hasMarkedText() == true) else {
            temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            session.showNotice(NoteNotice(kind: .finishFirst, detail: String(localized: "Finish Writing Tools or composing text before adding files.")))
            return
        }
        guard session.importBatch == nil else {
            temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            session.showNotice(NoteNotice(kind: .importBusy, detail: String(localized: "Finish the current file import before adding more files.")))
            return
        }
        let batchID = UUID()
        session.engine.beginImageImport(at: selection)
        session.importBatch = NoteImportBatch(id: batchID, urls: urls, acceptedText: acceptedText)
        // A crash before the first loader returns must still recover the
        // target, accepted text and every unfinished source.
        let loader = imageLoader
        session.importTask = Task { @MainActor [weak self, session] in
            defer { temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) } }
            guard let self else { return }
            if let clipboardData, let url = urls.first {
                do { try await Self.stageClipboardImage(clipboardData, at: url) }
                catch {
                    session.importBatch = nil
                    session.importTask = nil
                    session.engine.cancelImageImport()
                    session.showNotice(NoteNotice(kind: .notAdded, detail: String(localized: "The clipboard image could not be staged.")))
                    return
                }
                guard !Task.isCancelled, session.importBatch?.id == batchID else { return }
            }
            if self.journal != nil {
                _ = self.checkpoint(session, silent: true)
                await self.waitForRecoveryWork()
                await self.importCheckpointWillResume?()
                self.checkpointKeys[session.id] = nil
            }
            var loaded: [NoteImportedObject] = []
            for url in urls {
                guard !Task.isCancelled, session.importBatch?.id == batchID else { return }
                let stamp = session.callbackStamp
                let type = UTType(filenameExtension: url.pathExtension) ?? .data
                let item: NoteImportedObject
                // Metadata admission happens before either loader opens the
                // payload. A missing metadata value is checked by the loader.
                let (size, admissionFailure) = self.sourceAdmissionFailure(url, in: session, earlier: loaded)
                if let failure = admissionFailure {
                    item = NoteImportedObject(filename: url.lastPathComponent, contentTypeIdentifier: type.identifier,
                        byteCount: size ?? 0, failure: failure)
                } else if type.conforms(to: .image), let (image, size) = await loader(url) {
                    item = NoteImportedObject(staged: image.copying(id: UUID()), pixelSize: size)
                } else {
                    item = await Self.loadFile(url, type: type.identifier)
                }
                guard !Task.isCancelled, session.importBatch?.id == batchID else { return }
                if session.usesWorkspaceBinding, !session.accepts(stamp, retainingNewerDraft: true) {
                    self.cancelWorkspaceImport(session)
                    return
                }
                if let payload = item.staged,
                   let failure = self.importAdmissionFailure(payload, in: session, earlier: loaded) {
                    loaded.append(NoteImportedObject(filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier,
                        byteCount: item.byteCount, failure: failure))
                } else {
                    loaded.append(item)
                }
                guard var progress = session.importBatch, progress.id == batchID else { return }
                progress.completed = loaded.count
                progress.loaded = loaded
                session.importBatch = progress
                if self.journal != nil {
                    _ = self.checkpoint(session, silent: true)
                    await self.waitForRecoveryWork()
                    self.checkpointKeys[session.id] = nil
                }
            }
            guard !Task.isCancelled, var batch = session.importBatch, batch.id == batchID else { return }
            batch.loaded = loaded
            session.importBatch = batch
            session.importTask = nil
            self.completeImportIfPossible(in: session)
        }
    }

    func importImages(_ urls: [URL]) { importFiles(urls) }

    /// Retry picker entry point. Admission happens from file metadata before
    /// reading, then again at commit in case the draft changed meanwhile.
    func retryFailedFile(_ objectID: UUID, with url: URL) async -> Bool {
        guard let session = active, !session.isReadOnly,
              case .importFailed = session.engine.objectState(objectID) else { return false }
        if let failure = sourceAdmissionFailure(url, in: session).1 {
            session.showNotice(NoteNotice(kind: .notAdded, detail: failure))
            return false
        }
        let noteID = session.noteID
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let item: NoteImportedObject
        if type.conforms(to: .image), let (image, size) = await imageLoader(url) {
            item = NoteImportedObject(staged: image, pixelSize: size)
        } else {
            item = await Self.loadFile(url, type: type.identifier)
        }
        guard active === session, session.noteID == noteID,
              !session.isPersisted || store.note(withID: noteID) != nil else { return false }
        return session.engine.replaceFailedFile(objectID, with: item)
    }

    private func completeImportIfPossible(in session: NoteSession) {
        guard let batch = session.importBatch, let loaded = batch.loaded else { return }
        guard batch.completed == batch.urls.count else { return }
        guard session.engine.activity == .idle else { return }
        if session.isPersisted && store.note(withID: session.noteID) == nil {
            let hadUnsavedChanges = NoteSessionPolicy.hasPendingWork(session.state)
            dropImport(in: session, batchID: batch.id,
                notice: NoteNotice(kind: .notAdded, detail: String(localized: "The note was deleted, so its file batch was not added.")))
            if hadUnsavedChanges { session.state = .conflict(.deleted) }
            return
        }
        switch NoteSessionPolicy.importCompletion(session.state, activity: session.engine.activity) {
        case .deferUntilIdle:
            return
        case .drop:
            dropImport(in: session, batchID: batch.id,
                notice: NoteNotice(kind: .notAdded, detail: String(localized: "The note was deleted or is read only, so the files were not added.")))
        case .insert:
            let target = session.engine.currentImportTarget
            guard session.engine.insertImportedObjects(loaded, acceptedText: batch.acceptedText) else {
                if let target {
                    session.engine.restoreImageImport(anchor: target.anchor,
                        replacementLength: target.replacementLength, isBoundary: target.isBoundary)
                    session.importBatch = batch
                    _ = checkpoint(session, silent: true)
                }
                session.showNotice(NoteNotice(kind: .notAdded, detail: String(localized: "The files could not be added to this note.")))
                return
            }
            session.importBatch = nil
            session.importTask = nil
            _ = preserve(session)
        }
    }

    func cancelActiveImport() {
        guard let session = active, let batch = session.importBatch else { return }
        dropImport(in: session, batchID: batch.id,
            notice: NoteNotice(kind: .cancelled, detail: String(localized: "The file batch was cancelled.")))
    }

    private func dropImport(in session: NoteSession, batchID: UUID, notice: NoteNotice) {
        guard let batch = session.importBatch, batch.id == batchID, !session.cancellingImport else { return }
        if let journal, journal.requiresAsyncIO {
            session.cancellingImport = true
            session.importTask?.cancel()
            // Capture the post-cancel checkpoint without releasing live batch
            // ownership while the service is writing it.
            session.importBatch = nil
            let document = checkpointDocument(for: session)
            let generation = session.editGeneration
            let entry = try? journalEntry(for: session, document: document)
            let bytes = journalStaged(for: session, document: document)
            session.importBatch = batch
            queueRecoveryWork { [weak self, session] in
                guard let self, session.importBatch?.id == batchID else { return }
                do {
                    if NoteSessionPolicy.hasPendingWork(session.state), let entry {
                        self.retiredNoteIDs.remove(session.noteID)
                        session.recoveryClaim = try await journal.cancelPendingDurably(entry, staged: bytes, replacing: session.recoveryClaim)
                        self.checkpointKeys[session.id] = nil
                    } else if let claim = session.recoveryClaim {
                        try await journal.discardOwnedDurably(noteID: session.noteID, claim: claim)
                        session.recoveryClaim = nil
                    }
                    session.importBatch = nil
                    session.importTask = nil
                    session.cancellingImport = false
                    session.engine.cancelImageImport()
                    session.showNotice(notice)
                    // Keep edits made while cancellation was committing. Their
                    // checkpoint now has no cancelled batch or pending metadata.
                    if session.editGeneration != generation { _ = self.checkpoint(session, silent: true) }
                } catch {
                    session.cancellingImport = false
                    session.showNotice(NoteNotice(kind: .cantCancel, detail: "The batch could not be cancelled because recovery could not be updated."))
                }
            }
            return
        }
        // Retire pending metadata durably before releasing the live batch.
        // A failed replacement leaves the old checkpoint and the batch live.
        // A session holding no claim has no pending metadata on disk.
        session.importBatch = nil
        let ownsCheckpoint = session.recoveryClaim != nil
        let retired: Bool
        if let journal {
            if NoteSessionPolicy.hasPendingWork(session.state) {
                retired = checkpoint(session, silent: true) || !ownsCheckpoint
            } else if ownsCheckpoint {
                do {
                    if let claim = session.recoveryClaim { try journal.discardOwned(noteID: session.noteID, claim: claim) }
                    session.recoveryClaim = nil
                    retired = true
                } catch {
                    retired = false
                }
            } else {
                retired = true
            }
        } else { retired = true }
        if !retired {
            session.importBatch = batch
            session.showNotice(NoteNotice(kind: .cantCancel, detail: String(localized: "The batch could not be cancelled because its recovery copy could not be updated.")))
            return
        }
        session.importTask?.cancel()
        session.importTask = nil
        session.engine.cancelImageImport()
        session.showNotice(notice)
    }

    nonisolated static func stageClipboardImage(_ data: Data, at url: URL,
        write: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) async throws {
        guard !data.isEmpty, Int64(data.count) <= AttachmentLimits.maxBytesPerAttachment else {
            throw AttachmentFileStoreError.attachmentTooLarge(url, Int64(data.count))
        }
        try await Task.detached(priority: .userInitiated) { try write(data, url) }.value
    }

    nonisolated static func readImportedBytes(_ url: URL,
        maximumBytes: Int = Int(AttachmentLimits.maxBytesPerAttachment)) throws -> Data {
        guard maximumBytes >= 0 else { throw AttachmentFileStoreError.changedDuringRead(url) }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var data = Data()
        while true {
            try Task.checkCancellation()
            // At the bound read one sentinel byte, never an unbounded tail.
            let remaining = maximumBytes - data.count
            let request = remaining >= 1024 * 1024 ? 1024 * 1024 : remaining + 1
            let chunk = try input.read(upToCount: request) ?? Data()
            if chunk.isEmpty { return data }
            guard chunk.count <= remaining else {
                throw AttachmentFileStoreError.attachmentTooLarge(url, Int64(maximumBytes) + 1)
            }
            data.append(chunk)
        }
    }

    nonisolated private static func loadImageFile(_ url: URL) async -> (StagedNoteAttachment, CGSize?)? {
        await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var metadataURL = url
            metadataURL.removeAllCachedResourceValues()
            let values = try? metadataURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true,
                  let size = values?.fileSize, size > 0,
                  Int64(size) <= AttachmentLimits.maxBytesPerAttachment,
                  url.lastPathComponent.utf8.count <= AttachmentLimits.maxFilenameUTF8Bytes,
                  let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                  let data = try? readImportedBytes(url), data.count == size,
                  let pixelSize = NoteImageDecoder.pixelSize(of: data) else { return nil }
            let digest = NotePayloadDigest.sha256(data)
            return (StagedNoteAttachment(id: UUID(), filename: url.lastPathComponent,
                                         contentTypeIdentifier: type.identifier, byteCount: Int64(data.count),
                                         digest: digest, data: data), pixelSize)
        }.value
    }

    nonisolated static func loadFile(_ url: URL, type: String) async -> NoteImportedObject {
        await Task.detached(priority: .userInitiated) {
            let name = url.lastPathComponent
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var metadataURL = url
            metadataURL.removeAllCachedResourceValues()
            let values = try? metadataURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            let size = Int64(values?.fileSize ?? 0)
            guard values?.isRegularFile == true else {
                return NoteImportedObject(filename: name, contentTypeIdentifier: type, byteCount: size,
                    failure: AttachmentFileStoreError.notAFile(url).localizedDescription)
            }
            guard name.utf8.count <= AttachmentLimits.maxFilenameUTF8Bytes else {
                return NoteImportedObject(filename: name, contentTypeIdentifier: type, byteCount: size,
                    failure: AttachmentFileStoreError.invalidFilename(name).localizedDescription)
            }
            guard size <= AttachmentLimits.maxBytesPerAttachment else {
                return NoteImportedObject(filename: name, contentTypeIdentifier: type, byteCount: size,
                    failure: AttachmentFileStoreError.attachmentTooLarge(url, size).localizedDescription)
            }
            guard let data = try? readImportedBytes(url), !data.isEmpty else {
                return NoteImportedObject(filename: name, contentTypeIdentifier: type, byteCount: size,
                    failure: String(localized: "The file could not be read."))
            }
            guard Int64(data.count) == size else {
                return NoteImportedObject(filename: name, contentTypeIdentifier: type, byteCount: size,
                    failure: AttachmentFileStoreError.changedDuringRead(url).localizedDescription)
            }
            let digest = NotePayloadDigest.sha256(data)
            let staged = StagedNoteAttachment(id: UUID(), filename: name, contentTypeIdentifier: type,
                byteCount: size, digest: digest, data: data)
            return NoteImportedObject(staged: staged, pixelSize: nil)
        }.value
    }
}

extension NotesPageController: NoteImageProviding {
    func fileURL(forAttachment id: UUID) async -> URL? {
        guard let row = attachmentRow(id) else { return nil }
        return await store.materializedURL(for: row, allowRetained: true)
    }

    func filename(forAttachment id: UUID) -> String? {
        attachmentRow(id)?.originalFilename
    }

    func imageBytes(forAttachment id: UUID) -> StagedNoteAttachment? {
        // A failed source save leaves its image in the live draft, not in a
        // store row. Copy from that draft while it is retained in recovery.
        if let staged = cache.values.lazy.compactMap({ $0.engine.staged[id] }).first {
            return validImagePayload(staged) ? staged : nil
        }
        let live = cache.values.lazy.compactMap { $0.verifiedDocumentAttachments[id] }.first
        guard let item = live ?? store.cachedVerifiedAttachmentBytes(id) else { return nil }
        return validImagePayload(item) ? item : nil
    }

    func attachmentBytes(forAttachment id: UUID) -> StagedNoteAttachment? {
        if let staged = cache.values.lazy.compactMap({ $0.engine.staged[id] }).first {
            return staged.payloadIsVerified ? staged : nil
        }
        return cache.values.lazy.compactMap { $0.verifiedDocumentAttachments[id] }.first
            ?? store.cachedVerifiedAttachmentBytes(id)
    }

    func verifiedBytes(forAttachment id: UUID) async -> StagedNoteAttachment? {
        if let live = attachmentBytes(forAttachment: id) { return live.payloadIsVerified ? live : nil }
        return await store.verifiedAttachmentBytes(id)
    }

    private func durableAttachments(in document: NoteDocument) -> [UUID: StagedNoteAttachment] {
        Dictionary(document.attachmentIDs.compactMap { id in store.cachedVerifiedAttachmentBytes(id).map { (id, $0) } },
            uniquingKeysWith: { first, _ in first })
    }

    private func durableAttachmentsAsync(in document: NoteDocument) async -> [UUID: StagedNoteAttachment] {
        var result: [UUID: StagedNoteAttachment] = [:]
        for id in Set(document.attachmentIDs) {
            if let item = await store.verifiedAttachmentBytes(id, allowMaterialized: false) { result[id] = item }
        }
        return result
    }

    func hasAttachmentBytes(_ id: UUID) -> Bool {
        if let staged = cache.values.lazy.compactMap({ $0.engine.staged[id] }).first {
            return staged.byteCount == Int64(staged.data.count)
        }
        guard let row = attachmentRow(id) else { return false }
        let revision = store.revision
        if let cached = verifiedAvailability[id], cached.revision == revision,
           cached.digest == row.contentDigest { return cached.available }
        if verifyingAvailability.insert(id).inserted {
            let payloads = store.attachmentFamily(id).compactMap(\.payload)
            let digest = row.contentDigest
            let size = row.byteCount
            Task { @MainActor [weak self] in
                guard let self else { return }
                let available: Bool
                if !payloads.isEmpty {
                    available = await Task.detached(priority: .utility) {
                        payloads.allSatisfy { payload in
                            Int64(payload.count) == size && NotePayloadDigest.sha256(payload) == digest
                        }
                    }.value
                } else {
                    available = await self.store.materializedURL(for: row, allowRetained: true) != nil
                }
                self.verifyingAvailability.remove(id)
                if self.store.revision == revision,
                   self.attachmentRow(id)?.contentDigest == digest {
                    self.verifiedAvailability[id] = (revision, digest, available)
                    self.objectWillChange.send()
                    for session in self.cache.values { session.engine.invalidateAttachmentPresentation(id) }
                }
            }
        }
        // Metadata is enough for responsive validation; the background
        // verifier changes this to missing if the stored bytes are corrupt.
        return row.payload.map { Int64($0.count) == row.byteCount } ?? true
    }

    func locateAttachment(_ id: UUID, at url: URL) async -> Bool {
        guard let row = attachmentRow(id) else { return false }
        return await store.locateAttachment(row, at: url)
    }

    func locatePlacement(_ block: NoteBlock, noteID: UUID, at url: URL) async -> Bool {
        guard let session = cache[noteID], session.engine.checkpointDocument().blocks.contains(block) else { return false }
        return await store.locatePlacement(block, noteID: noteID, at: url) { [weak session] in
            session?.noteID == noteID && session?.engine.checkpointDocument().blocks.contains(block) == true
        }
    }

    private func attachmentRow(_ id: UUID) -> NoteAttachment? {
        if let cached = resolvedAttachmentRows[id], cached.revision == store.revision { return cached.row }
        let family = store.attachmentFamily(id)
        let resolved: NoteAttachment?
        if let first = family.first,
              family.allSatisfy({ $0.noteID == first.noteID && $0.contentDigest == first.contentDigest
                  && $0.byteCount == first.byteCount && $0.contentTypeIdentifier == first.contentTypeIdentifier }) {
            resolved = first
        } else {
            resolved = nil
        }
        resolvedAttachmentRows[id] = (store.revision, resolved)
        return resolved
    }
}

/// The decisions shared by autosave, navigation, imports and agent writes.
/// Inputs are values so the policy can be tested without a store or a view.
enum NoteSessionPolicy {
    enum DueSaveAction: Equatable { case preserve, checkpointOnly }
    enum Presence: Equatable { case onScreen, background, released }
    enum AgentDisposition: Equatable { case proposal, direct, flush, refuseImport }
    enum ImportCompletion: Equatable { case insert, deferUntilIdle, drop }

    static func hasPendingWork(_ state: NoteSession.State) -> Bool {
        switch state {
        case .dirty, .notSaved, .onlyInMemory, .conflict: true
        default: false
        }
    }

    static func needsAttention(_ state: NoteSession.State) -> Bool {
        switch state {
        case .notSaved, .onlyInMemory, .conflict: true
        default: false
        }
    }

    static func canWriteStore(_ state: NoteSession.State, activity: NoteEditorEngine.Activity,
                              hasMarkedText: Bool = false) -> Bool {
        guard activity == .idle, !hasMarkedText else { return false }
        switch state {
        case .conflict, .readOnly: return false
        default: return true
        }
    }

    static func dueSaveAction(_ state: NoteSession.State, activity: NoteEditorEngine.Activity,
                              hasMarkedText: Bool = false) -> DueSaveAction {
        guard activity == .idle, !hasMarkedText else { return .checkpointOnly }
        if case .conflict = state { return .checkpointOnly }
        return .preserve
    }

    static func canLeave(_ activity: NoteEditorEngine.Activity, hasMarkedText: Bool = false) -> Bool {
        activity == .idle && !hasMarkedText
    }
    static func commandAllowed(_ activity: NoteEditorEngine.Activity, hasMarkedText: Bool = false) -> Bool {
        activity == .idle && !hasMarkedText
    }

    static func canEvict(_ state: NoteSession.State, activity: NoteEditorEngine.Activity,
                         hasBatch: Bool, presence: Presence) -> Bool {
        guard activity == .idle, !hasBatch, presence != .onScreen else { return false }
        switch state {
        case .untouched, .clean, .readOnly: return true
        default: return false
        }
    }

    static func writingToolsAvailable(_ state: NoteSession.State, activity: NoteEditorEngine.Activity,
                                      refusedSinceLastStoreSave: Bool, hasMarkedText: Bool = false) -> Bool {
        guard activity == .idle, !refusedSinceLastStoreSave, !hasMarkedText else { return false }
        switch state {
        case .clean, .dirty: return true
        default: return false
        }
    }

    static func agentDisposition(_ presence: Presence, state: NoteSession.State?, hasBatch: Bool) -> AgentDisposition {
        if presence == .onScreen { return .proposal }
        if hasBatch { return .refuseImport }
        guard let state else { return .direct }
        if case .clean = state { return .direct }
        if case .readOnly = state { return .direct }
        return .flush
    }

    static func importCompletion(_ state: NoteSession.State, activity: NoteEditorEngine.Activity) -> ImportCompletion {
        if activity != .idle { return .deferUntilIdle }
        switch state {
        case .conflict(.deleted), .readOnly: return .drop
        default: return .insert
        }
    }

    /// Delete Note: never during an activity or while images load, and
    /// never from a conflict (its text lives only in its draft until Keep).
    static func deleteAllowed(_ state: NoteSession.State, activity: NoteEditorEngine.Activity,
                              hasBatch: Bool, hasMarkedText: Bool = false) -> Bool {
        guard activity == .idle, !hasBatch, !hasMarkedText else { return false }
        if case .conflict = state { return false }
        return true
    }

    /// Duplicate: like Delete, never during an activity or while images
    /// load; never from a conflict or a note this build can only read.
    static func duplicateAllowed(_ state: NoteSession.State, activity: NoteEditorEngine.Activity,
                                 hasBatch: Bool, hasMarkedText: Bool = false) -> Bool {
        guard deleteAllowed(state, activity: activity, hasBatch: hasBatch, hasMarkedText: hasMarkedText) else { return false }
        if case .readOnly = state { return false }
        return true
    }

    static func keepAsNewAllowed(_ state: NoteSession.State, activity: NoteEditorEngine.Activity,
                                 hasBatch: Bool, hasMarkedText: Bool = false) -> Bool {
        guard activity == .idle, !hasBatch, !hasMarkedText else { return false }
        if case .conflict = state { return true }
        return false
    }
}

// MARK: - Version history (Phase 2, slice 7)

extension NotesPageController {
    /// `workspace`: a task's page opens its note's history (Phase 3); nil
    /// is the Notes page's note.
    func openHistoryDurably(workspace: NoteSession? = nil) async -> Bool {
        guard historyBrowser == nil, let session = workspace ?? active, session.isPersisted,
              workspace == nil || session.usesWorkspaceBinding,
              !session.isReadOnly, !session.isImporting, !session.isConflict,
              canLeaveComposition(in: session) else { return false }
        captureViewState(session)
        guard await preserveDurably(session), workspace != nil || active === session, session.state == .clean,
              store.note(withID: session.noteID)?.revisionID == session.baseRevisionID else {
            session.showNotice(NoteNotice(kind: .saveFirst, detail: "The current note must be saved before opening version history. Your text is kept."))
            return false
        }
        session.pauseTask?.cancel()
        let entries: [NoteHistoryEntry]
        do { entries = try store.readVersions(noteID: session.noteID).map(NoteHistoryEntry.init) }
        catch {
            session.showNotice(NoteNotice(kind: .historyError, detail: "Version history could not be read. Try again. Your note is kept."))
            return false
        }
        let browser = NoteHistoryBrowser(noteID: session.noteID, current: session.engine.document(),
            currentRevision: session.baseRevisionID, entries: entries)
        if let scroll = session.engine.scrollView {
            browser.scrollOffset = scroll.contentView.bounds.origin.y + scroll.contentInsets.top
        }
        store.historyRetainedVersionIDs.formUnion(entries.map(\.id))
        historyBrowser = browser
        refreshHistoryPreview()
        return true
    }

    func refreshHistoryPreview() {
        guard let browser = historyBrowser else { return }
        if let scroll = browser.preview?.engine.scrollView {
            browser.scrollOffset = scroll.contentView.bounds.origin.y + scroll.contentInsets.top
        }
        browser.preview?.engine.detachView()
        browser.updateComparison()
        let comparison = browser.comparison
        // A task's note previews its body only (§ 2.12): block 0 is the
        // title snapshot, never shown.
        let bodyOnly = comparison.document.requires.contains("taskNote")
        let engine = makeEngine(noteID: browser.noteID, document: comparison.document, readOnly: true, bodyOnly: bodyOnly)
        var offset = 0
        let text = engine.textStorage.string as NSString
        for (index, block) in comparison.document.blocks.enumerated() where !(bodyOnly && engine.isBodyOnly && index == 0) {
            let length = block.kind == .text ? block.text.utf16.count
                : (block.kind == .checklist ? block.text.utf16.count + 1 : 1)
            if comparison.changedBlocks.contains(index) {
                var start = offset
                repeat {
                    guard start < text.length else { break }
                    let range = text.paragraphRange(for: NSRange(location: start, length: 0))
                    engine.historyDifferenceOffsets.insert(range.location)
                    start = NSMaxRange(range)
                } while start < offset + length
            }
            offset += length + 1
        }
        let preview = NoteSession(noteID: browser.noteID, isPersisted: true,
            baseRevisionID: browser.currentRevision, engine: engine, readOnlyReason: .unsupportedContent)
        preview.scrollOffset = browser.scrollOffset
        browser.preview = preview
    }

    func selectHistoryVersion(_ index: Int) {
        guard let browser = historyBrowser, !browser.isRestoring, browser.entries.indices.contains(index) else { return }
        browser.selectedIndex = index
        browser.showsCurrent = false
        browser.failure = nil
        refreshHistoryPreview()
    }

    func closeHistory() {
        guard let browser = historyBrowser else { return }
        browser.preview?.engine.detachView()
        store.historyRetainedVersionIDs.subtract(browser.entries.map(\.id))
        if let undo = versionRestoreUndo { store.historyRetainedVersionIDs.insert(undo.versionID) }
        historyBrowser = nil
    }

    func copyHistoryVersion() {
        guard let browser = historyBrowser, let selected = browser.selected else { return }
        let engine = makeEngine(noteID: browser.noteID, document: selected.document, readOnly: true)
        _ = engine.writeSelection(NSRange(location: 0, length: engine.textStorage.length), to: .general,
                                  types: [.string, .rtf, NoteEditorEngine.fragmentType])
    }

    func restoreHistoryVersionDurably() async -> Bool {
        guard let browser = historyBrowser, let selected = browser.selected, selected.canRestore,
              !browser.isRestoring, !browser.showsCurrent else { return false }
        // A task's page restores its note's version through its own session
        // (Phase 3): the note only; the task, its subtasks and the
        // association are never rewound (§ 2.10, S4).
        let workspace = cache[browser.noteID].flatMap { $0.usesWorkspaceBinding ? $0 : nil }
        guard let session = workspace ?? active,
              session.noteID == browser.noteID, session.state == .clean, !session.isImporting,
              canLeaveComposition(in: session) else { return false }
        let engine = session.engine, generation = session.editGeneration
        browser.isRestoring = true
        defer { browser.isRestoring = false }
        guard await awaitRecoveryForUser(), historyBrowser === browser, workspace != nil || active === session,
              session.engine === engine, canLeaveComposition(in: session),
              session.editGeneration == generation, session.state == .clean, !session.isImporting,
              browser.selected?.id == selected.id, browser.selected?.canRestore == true,
              !browser.showsCurrent else { return false }
        if let workspace, let owner = store.note(withID: browser.noteID)?.taskID,
           let presenter = TaskNotePresenter.open(for: owner),
           let coordinator = try? WorkspaceLegacyBridge.coordinator(for: store.container) {
            let normalized: NoteDocument
            do { normalized = try WorkspaceRestoreNormalization.document(selected.document, noteID: browser.noteID, in: coordinator.freshContext()) }
            catch { return false }
            workspace.engine.setCompatibilityTitle(normalized.title)
            let candidate = workspace.engine.bodyText(for: Array(normalized.blocks.dropFirst()))
            let selection = workspace.engine.textView?.selectedRange() ?? NSRange(location: 0, length: 0)
            let edit = TaskNoteTextEdit(engine: workspace.engine, session: workspace, notes: self, tasks: presenter.model.store,
                coordinator: coordinator, history: presenter.page.history, noteID: workspace.noteID,
                parentID: owner, selectionBefore: selection, caretAfter: selection.location)
            let outcome = await edit.perform(name: String(localized: "Restore Version"), candidate: candidate, entryID: UUID(),
                forwardWrites: [], forward: { _ in }, inverse: { _ in
                    .init(writes: [], check: { _ in }, preservations: [:], stage: { _, _ in })
                })
            guard outcome == .committed || outcome == .publicationPending else { return false }
            closeHistory()
            return true
        }
        let preservationID = UUID()
        switch store.restoreVersion(selected.id, noteID: browser.noteID,
                                    expectedRevisionID: browser.currentRevision, preservationID: preservationID) {
        case let .failure(error):
            browser.failure = error.localizedDescription
            return false
        case let .success(token):
            guard let revision = UUID(uuidString: token), let note = store.note(withID: browser.noteID) else { return false }
            if let workspace {
                // The page reloads its editor from the store; its history
                // stops at this external change. The replaced text is a
                // version of its own, restorable from Version History.
                closeHistory()
                store.historyRetainedVersionIDs.insert(preservationID)
                workspace.workspacePage?.externalRefresh(origin: String(localized: "Version History"))
                return true
            }
            if let previous = versionRestoreUndo { store.historyRetainedVersionIDs.remove(previous.versionID) }
            versionRestoreUndo = VersionRestoreUndo(id: UUID(), noteID: browser.noteID, versionID: preservationID,
                restoredRevisionID: revision, document: store.loadDocument(noteID: browser.noteID)?.content.document,
                tags: note.tags, historyPosition: [], session: session, isUndo: true)
            store.historyRetainedVersionIDs.insert(preservationID)
            closeHistory()
            session.engine.detachView()
            cache[browser.noteID] = nil
            if let restored = self.session(for: note) { activate(restored) }
            return true
        }
    }

    func undoVersionRestoreDurably(expectedID: UUID?) async -> Bool {
        await replayVersionRestoreDurably(undo: true, expectedID: expectedID)
    }

    func redoVersionRestoreDurably() async -> Bool {
        await replayVersionRestoreDurably(undo: false, expectedID: versionRestoreUndo?.id)
    }

    private func canReplayVersionRestore(undo: Bool) -> Bool {
        guard versionHistoryCommandTask == nil, !isVersionRestoreReplaying,
              let step = versionRestoreUndo, step.isUndo == undo,
              historyBrowser == nil, let current = active, current.noteID == step.noteID,
              !current.isImporting, !current.isConflict, !current.isReadOnly,
              current.engine.activity == .idle,
              store.note(withID: step.noteID)?.revisionID == step.restoredRevisionID else { return false }
        return current.engine.matchesContentIgnoringFolds(step.document)
            && current.engine.history.undoOps.map(ObjectIdentifier.init) == step.historyPosition
            && current.engine.tags == step.tags
    }

    private func requestVersionRestoreReplay(undo: Bool) {
        guard versionHistoryCommandTask == nil else { return }
        let ticket = versionRestoreUndo?.id
        versionHistoryCommandTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.versionHistoryCommandTask = nil }
            _ = await self.replayVersionRestoreDurably(undo: undo, expectedID: ticket)
        }
    }

    private func replayVersionRestoreDurably(undo isUndo: Bool, expectedID: UUID?) async -> Bool {
        guard !isVersionRestoreReplaying else { return false }
        isVersionRestoreReplaying = true
        defer { isVersionRestoreReplaying = false }
        guard let initial = versionRestoreUndo, initial.id == expectedID, initial.isUndo == isUndo,
              await awaitRecoveryForUser(), let undo = versionRestoreUndo,
              undo.id == expectedID, undo.isUndo == isUndo else { return false }
        let current = active
        var expectedRevision = undo.restoredRevisionID
        if let current {
            guard current.noteID == undo.noteID, !current.isImporting, !current.isConflict, !current.isReadOnly,
                  historyBrowser == nil, canLeaveComposition(in: current),
                  current.engine.matchesContentIgnoringFolds(undo.document),
                  current.engine.history.undoOps.map(ObjectIdentifier.init) == undo.historyPosition,
                  store.note(withID: undo.noteID)?.revisionID == expectedRevision else { return false }
            let generation = current.editGeneration
            let tags = current.engine.tags
            if current.state != .clean {
                // Typing followed by Undo may have returned exactly to the
                // restored state while its coalesced save is still pending.
                guard current.engine.tags == undo.tags,
                      await preserveDurably(current), current.state == .clean,
                      let revision = current.baseRevisionID else { return false }
                expectedRevision = revision
            }
            // A durability await permits typing, imports and navigation.
            // Never interpret their newer save as permission to replace them.
            guard active === current, historyBrowser == nil, generation == current.editGeneration,
                  !current.isImporting, !current.isConflict, !current.isReadOnly,
                  canLeaveComposition(in: current), current.engine.matchesContentIgnoringFolds(undo.document),
                  current.engine.history.undoOps.map(ObjectIdentifier.init) == undo.historyPosition,
                  current.engine.tags == tags, let latest = versionRestoreUndo,
                  latest.id == expectedID, latest.isUndo == isUndo,
                  latest.restoredRevisionID == expectedRevision,
                  store.note(withID: undo.noteID)?.revisionID == expectedRevision else { return false }
        } else { return false }
        let inverseID = UUID()
        switch store.restoreVersion(undo.versionID, noteID: undo.noteID, expectedRevisionID: expectedRevision,
                                    preservationID: inverseID) {
        case let .failure(error): current?.showNotice(NoteNotice(kind: .didntWork, detail: error.localizedDescription)); return false
        case let .success(token):
            closeHistory()
            current?.engine.detachView()
            guard let revision = UUID(uuidString: token), let note = store.note(withID: undo.noteID) else { return false }
            if let returned = undo.session {
                        returned.baseRevisionID = revision
                returned.baseContent = note.content
                returned.baseTags = note.tags
                // The displaced session can receive late callbacks while retained
                // for Undo. Its text and tags remain owned until actually saved.
                returned.state = returned.engine.matchesContentIgnoringFolds(store.loadDocument(noteID: undo.noteID)?.content.document)
                    && returned.engine.tags == note.tags ? .clean : .dirty
                activate(returned)
                if returned.state == .dirty {
                    scheduleSave(returned)
                    scheduleDurabilityDeadline(returned)
                }
            } else if let restored = self.session(for: note) { activate(restored) }
            store.historyRetainedVersionIDs.remove(undo.versionID)
            store.historyRetainedVersionIDs.insert(inverseID)
            versionRestoreUndo = VersionRestoreUndo(id: undo.id, noteID: undo.noteID, versionID: inverseID,
                restoredRevisionID: revision, document: active?.engine.document(),
                tags: active?.engine.tags ?? note.tags,
                historyPosition: active?.engine.history.undoOps.map(ObjectIdentifier.init) ?? [],
                session: current, isUndo: !isUndo)
            return true
        }
    }
}

// MARK: - Note actions (Phase 2, slice 2)

/// The ⋯ menu's and All notes' note actions. Each goes through the session
/// rules: a note's pending text is preserved before anything that could
/// lose it, and nothing here saves document text by another path.
extension NotesPageController {
    /// New Note from the menu bar or ⌘N: always a fresh draft (a recovered
    /// draft still opens first when the page has not started yet).
    @discardableResult
    func requestNewNote() -> Bool {
        guard didStart else {
            pendingNewNote = true
            return true
        }
        guard newNote() else { return false }
        isLibraryPresented = false
        present()
        return true
    }

    /// All notes' "New note “kyoto”" (in #launch), after a search found
    /// nothing: a fresh draft whose title is the search and whose tags are
    /// the filter's, pending like typed text (saved, journalled and kept on
    /// leave by the usual rules). The current note is preserved first.
    @discardableResult
    func requestNewNote(title: String, tags: [String]) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard didStart, !title.isEmpty, !title.contains(where: \.isNewline) else { return false }
        guard prepareToLeave(.newNote) else { return false }
        let id = UUID()
        let document = NoteDocument(blocks: [.text(title)])
        let session = NoteSession(noteID: id, isPersisted: false, baseRevisionID: nil,
                                  engine: makeEngine(noteID: id, document: document, readOnly: false, tags: tags),
                                  readOnlyReason: nil)
        // The caret waits at the end of the title, as if it had been typed.
        session.selection = NSRange(location: (title as NSString).length, length: 0)
        // Pending before it joins the cache: an untouched session can be
        // evicted there as an empty draft (review S4-R1).
        session.state = .dirty
        activate(session)
        // The text was not typed into the view: mark it as the edit it is.
        textDidChange(in: session)
        isLibraryPresented = false
        present()
        return true
    }

    /// Delete Note (⋯, or right-click and ⌘⌫ in All notes): an intentional
    /// leave, never "Deleted elsewhere". Pending text is saved first, so
    /// Restore brings back the latest; the session and its recovery copy go;
    /// then the note moves to Recently Deleted. A refused step changes
    /// nothing and says why in the slot. Deleting the note on screen shows
    /// All notes.
    @discardableResult
    func deleteNote(noteID: UUID) -> Bool {
        let reopen = active?.noteID == noteID && !isLibraryPresented
        let context = ModelContext(store.container)
        let taskID = try? WorkspaceItemLifecycle.taskOwner(noteID: noteID, in: context)
        guard removeNote(noteID: noteID) else { return false }
        if let taskID, let library = store.commandLibrary ?? workspaceTaskStore?.commandLibrary
            ?? (try? WorkspaceLegacyBridge.coordinator(for: store.container))?.lifecycleLibrary {
            library.recordCommittedDeletion(.init(.task, taskID), in: .notesLibrary)
        } else { undoRoute.record(deleteStep(noteID: noteID, reopen: reopen), in: .notesLibrary) }
        return true
    }

    /// The delete itself, as a history step also runs it (Redo, and Undo of
    /// a duplicate).
    private func removeNote(noteID: UUID, restoredLegacy: Bool = false) -> Bool {
        let session = cache[noteID]
        if let session {
            session.engine.refreshCompositionActivity()
            guard NoteSessionPolicy.deleteAllowed(session.state, activity: session.engine.activity,
                    hasBatch: session.isImporting, hasMarkedText: session.engine.textView?.hasMarkedText() == true) else {
                let detail = switch session.state {
                case .conflict: String(localized: "Keep this text as a new note before deleting it.")
                default: session.isImporting
                    ? String(localized: "Images are still being added. Delete the note when they finish.")
                    : String(localized: "Finish Writing Tools or composing text before deleting this note.")
                }
                session.showNotice(NoteNotice(kind: session.isConflict ? .notDeleted : (session.isImporting ? .stillAdding : .finishFirst), detail: detail))
                return false
            }
            if NoteSessionPolicy.hasPendingWork(session.state) || !session.isPersisted {
                guard preserve(session), session.isPersisted, !NoteSessionPolicy.hasPendingWork(session.state) else {
                    session.showNotice(NoteNotice(kind: .notDeleted, detail: String(localized: "The latest text couldn’t be saved, so the note was not deleted.")))
                    return false
                }
            }
        }
        guard let note = store.note(withID: noteID) else { return false }
        // Retire the recovery copy while the note is live, so a copy that
        // can't be removed is replaced by a retired marker; if neither
        // works, nothing is deleted (the copy would come back as a conflict).
        guard retireRecoveryCopy(noteID: noteID, session: session) else {
            if journal?.requiresAsyncIO == true && recoveryWork != nil { return false }
            let message = String(localized: "An old recovery copy of this note couldn’t be cleared, so the note was not deleted. Try again.")
            if let session { session.showNotice(NoteNotice(kind: .notSaved, detail: message)) } else { active?.showNotice(NoteNotice(kind: .notDeleted, detail: message)) }
            return false
        }
        if let session {
            session.saveTask?.cancel()
            session.durabilityTask?.cancel()
            session.pauseTask?.cancel()
        }
        guard (restoredLegacy ? store.deleteRestoredLegacyNote(noteID: noteID) : store.delete(note)) else {
            if let session {
                cache[noteID] = session
                touch(noteID)
                session.showNotice(NoteNotice(kind: .notSaved, detail: storeMessage()))
            }
            return false
        }
        let keepWorkspace = session?.workspacePage?.activeLease != nil && session?.isItemDeleted == true
        if !keepWorkspace { cache[noteID] = nil }
        recency.removeAll { $0 == noteID }
        if lastViewedNoteID == noteID { defaults?.removeObject(forKey: Self.lastViewedKey) }
        if let session, active === session {
            active = nil
            isLibraryPresented = true
        }
        if !keepWorkspace { session?.engine.detachView() }
        collectReleasedStaging()
        return true
    }

    private func forgetPurgedSnapshots(_ ids: Set<UUID>) {
        if let restore = versionRestoreUndo, ids.contains(restore.noteID) {
            restore.session?.engine.history.reset()
            store.historyRetainedVersionIDs.remove(restore.versionID)
            versionRestoreUndo = nil
            versionHistoryCommandTask?.cancel()
            versionHistoryCommandTask = nil
        }
        if let browser = historyBrowser, ids.contains(browser.noteID) { closeHistory() }
        if let review = proposalReview, ids.contains(review.noteID) { proposalReview = nil }
        for id in ids {
            proposalStatusCache[id] = nil
            // A pending local draft may still own the only unsaved bytes.
            // Purge invalidates saved snapshots without discarding that draft.
            if let session = cache[id], !NoteSessionPolicy.hasPendingWork(session.state), !session.isImporting {
                session.saveTask?.cancel(); session.durabilityTask?.cancel(); session.pauseTask?.cancel()
                session.engine.history.reset()
                session.engine.detachView()
                cache[id] = nil
                recency.removeAll { $0 == id }
                if active === session { active = nil; isLibraryPresented = true }
            }
        }
        undoRoute.invalidate(Set(ids.map { AtticItemRef(.note, $0) }))
        collectReleasedStaging()
    }

    private func collectReleasedStaging() {
        guard let journal else { return }
        // Collection is serialized by the journal IO actor, but it is not
        // a pending checkpoint. It must not make synchronous Undo/Redo wait
        // for an unrelated housekeeping pass.
        let prior = stagingCollectionWork
        let token = UUID()
        stagingCollectionToken = token
        stagingCollectionWork = Task { @MainActor [weak self] in
            await prior?.value
            do { try await journal.collectUnreferencedStaging() }
            catch { self?.reportRecoveryRetentionWarning("Unused recovery files could not be checked. They are being kept for a later cleanup.") }
            if self?.stagingCollectionToken == token { self?.stagingCollectionWork = nil }
        }
    }

    /// The Undo toast after Delete Note: the note comes back from Recently
    /// Deleted with its text, tags and images; `reopen` shows it again.
    @discardableResult
    func restoreDeletedNote(noteID: UUID, reopen: Bool) -> Bool {
        guard store.restoreDeleted(noteID: noteID) else { return false }
        if reopen, open(noteID: noteID) { isLibraryPresented = false }
        return true
    }

    /// Restore Note on a task's page (§ 2.7.2) as its own Undo step: Undo
    /// sends the note back to Recently Deleted, Redo restores it again.
    /// Returns nil when the store refused; else whether it came back as a
    /// separate, ordinary note (the task had a newer own note) and the
    /// step's id (the toast's Undo targets exactly that step).
    func restoreTaskNote(noteID: UUID, staging: ((ModelContext) throws -> Void)? = nil) -> (separate: Bool, stepID: UUID?)? {
        let before = (try? store.replicasIncludingDeleted(of: noteID)) ?? []
        let owner = before.first?.taskID
        let independent = before.allSatisfy { $0.deletionGroupID == nil }
        let historyID: UndoHistoryID = owner.map { .taskWorkspace($0) } ?? .note(noteID)
        let owned = noteHistoryOwnership(noteID, deleted: true)
        guard store.restoreDeleted(noteID: noteID, staging: staging) else { return nil }
        let separate = store.lastRestoreWasSeparate
        undoRoute.record(UndoStep(
            name: String(localized: "Restore Note"),
            items: { owned.itemRefs.union([.init(.note, noteID)]) },
            undoOutcome: { [weak self] in
                self?.deleteHistoryNote(noteID, owned: owned, legacyOwner: separate ? nil : owner,
                    restoredLegacy: independent) ?? .obsolete
            },
            redoOutcome: { [weak self] in self?.restoreHistoryNote(noteID, owned: owned, reopen: false) ?? .obsolete }
        ), in: historyID)
        return (separate, undoRoute.undoStepID(in: historyID))
    }

    /// Duplicate (⌘D): a new note with this note's current text, copies of
    /// its images and its tags, titled "… copy", and opened.
    @discardableResult
    func duplicateNote(noteID: UUID) async -> Bool {
        guard !isDuplicatingNote else {
            active?.showNotice(NoteNotice(kind: .notice, detail: String(localized: "This note is already being duplicated.")))
            return false
        }
        isDuplicatingNote = true
        defer { isDuplicatingNote = false }
        guard let newID = await makeDuplicate(noteID: noteID) else { return false }
        undoRoute.record(duplicateStep(newID: newID), in: .notesLibrary)
        return true
    }

    private func makeDuplicate(noteID: UUID) async -> UUID? {
        // 1. The gates, before anything is read or written: the source's
        //    activity (composition, Writing Tools), a loading batch, and
        //    leaving the note on screen. A refusal creates nothing.
        if let session = cache[noteID] {
            session.engine.refreshCompositionActivity()
            guard NoteSessionPolicy.duplicateAllowed(session.state, activity: session.engine.activity,
                    hasBatch: session.isImporting, hasMarkedText: session.engine.textView?.hasMarkedText() == true) else {
                let detail = switch session.state {
                case .conflict: String(localized: "Keep this text as a new note before duplicating it.")
                case .readOnly: String(localized: "This note can’t be duplicated here.")
                default: session.isImporting
                    ? String(localized: "Images are still being added. Duplicate the note when they finish.")
                    : String(localized: "Finish Writing Tools or composing text before duplicating this note.")
                }
                session.showNotice(NoteNotice(kind: session.isConflict || session.isReadOnly ? .noDuplicate : (session.isImporting ? .stillAdding : .finishFirst), detail: detail))
                return nil
            }
        }
        let leaving = active, leaveRequest = openRequestGeneration
        guard await prepareToLeaveDurably(.openNote), active === leaving,
              openRequestGeneration == leaveRequest, !Task.isCancelled else { return nil }
        // 2. The source as it is now (its latest text was just preserved).
        let document: NoteDocument
        var staged: [StagedNoteAttachment]
        let tags: [String]
        if let session = cache[noteID] {
            document = session.engine.document()
            staged = session.engine.stagedAttachments(for: document)
            tags = session.engine.tags
        } else if let load = store.loadDocument(noteID: noteID), case let .editable(stored) = load.content {
            document = stored
            staged = []
            tags = store.note(withID: noteID)?.tags ?? []
        } else {
            return nil
        }
        let sourceSession = cache[noteID], sourceEngine = cache[noteID]?.engine
        let sourceGeneration = sourceSession?.editGeneration
        let sourceRow = store.note(withID: noteID)
        let sourceRevision = sourceRow?.revisionID, sourceContent = sourceRow?.content, sourceTags = sourceRow?.tags
        let storeGeneration = store.revision, request = openRequestGeneration
        let leavingEngine = leaving?.engine, leavingGeneration = leaving?.editGeneration
        let sourceStaged = staged
        for id in Set(document.attachmentIDs) where !staged.contains(where: { $0.id == id }) {
            #if DEBUG
            if let hook = duplicateAttachmentWillVerify { await hook(id) }
            #endif
            guard let bytes = await store.verifiedAttachmentBytes(id) else {
                active?.showNotice(NoteNotice(kind: .imageGone, detail: String(localized: "An attachment is unavailable, so the note was not duplicated.")))
                return nil
            }
            staged.append(bytes)
        }
        // Byte verification yields. Navigation, edits, tags, deletion, imports
        // or a replaced store context cannot authorize copying the old snapshot.
        sourceEngine?.refreshCompositionActivity()
        leavingEngine?.refreshCompositionActivity()
        guard !Task.isCancelled, request == openRequestGeneration, active === leaving,
              leaving?.engine === leavingEngine, leaving?.editGeneration == leavingGeneration,
              cache[noteID] === sourceSession, sourceSession?.engine === sourceEngine,
              sourceSession?.editGeneration == sourceGeneration, store.revision == storeGeneration,
              store.note(withID: noteID)?.revisionID == sourceRevision,
              store.note(withID: noteID)?.content == sourceContent,
              store.note(withID: noteID)?.tags == sourceTags,
              sourceEngine?.stagedAttachments(for: document) ?? [] == sourceStaged,
              sourceSession.map({ NoteSessionPolicy.duplicateAllowed($0.state, activity: $0.engine.activity,
                  hasBatch: $0.isImporting, hasMarkedText: $0.engine.textView?.hasMarkedText() == true) }) ?? true,
              leaving.map({ NoteSessionPolicy.canLeave($0.engine.activity, hasMarkedText: $0.engine.textView?.hasMarkedText() == true)
                  && !$0.isImporting }) ?? true else {
            active?.showNotice(NoteNotice(kind: .noDuplicate, detail: String(localized: "The note changed while it was being duplicated. Try again.")))
            return nil
        }
        guard var (copy, images) = replacementForDeletedNote(document, oldID: noteID, staged: staged) else {
            active?.showNotice(NoteNotice(kind: .imageGone, detail: String(localized: "An attachment is unavailable, so the note was not duplicated.")))
            return nil
        }
        if let first = copy.blocks.first, first.kind == .text, !first.displayText.trimmingCharacters(in: .whitespaces).isEmpty {
            copy.blocks[0].text = first.text.trimmingCharacters(in: .whitespaces) + String(localized: " copy")
        }
        copy.blocks = copy.blocks.map { block in
            var block = block
            if block.kind == .checklist { block.id = UUID() }
            block.inlines = block.inlines.map { inline in
                var inline = inline
                inline.id = UUID()
                return inline
            }
            return block
        }
        images = images.filter { image in copy.attachmentIDs.contains(image.id) }
        // 3. One complete copy, then it opens (the leave already ran).
        guard case let .success((newID, _)) = store.createDocumentNote(id: UUID(), document: copy, staged: images,
                                                                     tags: tags.isEmpty ? nil : tags),
              let note = store.note(withID: newID), let session = session(for: note).flatMap({ presentSession($0) }) else {
            active?.showNotice(NoteNotice(kind: .noDuplicate, detail: String(localized: "The note couldn’t be duplicated: \(storeMessage())")))
            return nil
        }
        activate(session)
        isLibraryPresented = false
        return newID
    }

    /// Pin to Top / Unpin from Top (metadata; a draft is saved first).
    @discardableResult
    func setPinned(_ pinned: Bool, noteID: UUID) -> Bool {
        // The store decides between a mutation and a no-op across every
        // replica of the UUID; history records what it actually did. A pin
        // that changed nothing is not a step.
        switch applyPinned(pinned, noteID: noteID) {
        case .failed:
            return false
        case .unchanged:
            return true
        case .changed:
            undoRoute.record(pinStep(pinned, noteID: noteID), in: .notesLibrary)
            return true
        }
    }

    private func applyPinned(_ pinned: Bool, noteID: UUID) -> NoteStore.PinResult {
        if let session = cache[noteID], !session.isPersisted {
            guard preserve(session), session.isPersisted else { return .failed }
        }
        return store.setPinnedOutcome(pinned, noteID: noteID)
    }

    // MARK: Library history (Phase 2 audit, item 15)

    /// Follows `route` for the library's actions from now on.
    func attachUndoRoute(_ route: UndoRoute) {
        undoRoute = route
        undoRevision = route.revision
        undoRevisionSubscription = route.$revision.sink { [weak self] revision in
            self?.undoRevision = revision
        }
    }

    var canUndoLibrary: Bool { undoRoute.canUndo(in: .notesLibrary) }
    var canRedoLibrary: Bool { undoRoute.canRedo(in: .notesLibrary) }
    /// "Delete Note", "Pin Note", "Duplicate Note": what Undo would reverse.
    var libraryUndoName: String? { undoRoute.undoName(in: .notesLibrary) }
    var libraryRedoName: String? { undoRoute.redoName(in: .notesLibrary) }
    /// The step an Undo would reverse now (the delete toast is tied to it).
    var libraryUndoStepID: UUID? { undoRoute.undoStepID(in: .notesLibrary) }

    @discardableResult
    func undoLibraryDurably(expectedStepID: UUID? = nil) async -> Bool {
        await performAfterRecovery {
            guard expectedStepID == nil || libraryUndoStepID == expectedStepID else { return false }
            return undoLibrary()
        }
    }
    func redoLibraryDurably() async -> Bool { await performAfterRecovery { redoLibrary() } }

    @discardableResult
    func undoLibrary() -> Bool { undoRoute.undo(in: .notesLibrary) }

    @discardableResult
    func redoLibrary() -> Bool { undoRoute.redo(in: .notesLibrary) }

    /// Delete Note: Undo brings the note back from Recently Deleted (and
    /// shows it again when it was the note on screen); Redo deletes it
    /// again. A refused restore of a note still in Recently Deleted keeps
    /// the step; one that can never apply drops it.
    private var lifecycleHistoryLibrary: AtticLibrary? {
        store.commandLibrary ?? workspaceTaskStore?.commandLibrary
            ?? (try? WorkspaceLegacyBridge.coordinator(for: store.container))?.lifecycleLibrary
    }

    private func noteHistoryOwnership(_ noteID: UUID, deleted: Bool) -> AtticLibrary.FamilyOwnership {
        if let library = lifecycleHistoryLibrary {
            let owned = library.itemOwnership(deleted ? library.ownedMembers(of: .init(.note, noteID)) : [], deleted: deleted, noteID: noteID)
            owned.writing = (owned.writing ?? []).union([noteID])
            return owned
        }
        let owned = AtticLibrary.FamilyOwnership([])
        owned.writing = [noteID]
        if deleted, let copies = try? store.replicasIncludingDeleted(of: noteID) {
            owned.groups = Set(copies.compactMap(\.deletionGroupID))
        }
        return owned
    }

    private func restoreHistoryNote(_ noteID: UUID, owned: AtticLibrary.FamilyOwnership, reopen: Bool) -> UndoOutcome {
        let outcome: UndoOutcome
        if let library = lifecycleHistoryLibrary {
            if let stop = library.wholeItemRestoreGuard(owned, refs: [.init(.note, noteID)]) { return stop }
            if store.restoreDeleted(noteID: noteID) { outcome = .applied }
            else { outcome = store.recentlyDeletedNotes().contains { $0.ref.id == noteID } ? .failed : .obsolete }
        } else {
            guard let copies = try? store.replicasIncludingDeleted(of: noteID) else { return .failed }
            let current = Set(copies.compactMap(\.deletionGroupID))
            guard owned.groups.isEmpty || !current.isEmpty && current.isSubset(of: owned.groups) else { return .obsolete }
            if store.restoreDeleted(noteID: noteID) { outcome = .applied }
            else { outcome = store.recentlyDeletedNotes().contains { $0.ref.id == noteID } ? .failed : .obsolete }
        }
        if outcome == .applied, reopen, open(noteID: noteID) { isLibraryPresented = false }
        return outcome
    }

    private func deleteHistoryNote(_ noteID: UUID, owned: AtticLibrary.FamilyOwnership,
                                   legacyOwner: UUID? = nil, restoredLegacy: Bool = false) -> UndoOutcome {
        guard store.note(withID: noteID) != nil else { return .obsolete }
        do {
            let root = try WorkspaceItemLifecycle.taskOwner(noteID: noteID, in: ModelContext(store.container))
            if restoredLegacy {
                guard root == legacyOwner else { return .obsolete }
            } else if let library = lifecycleHistoryLibrary {
                if let stop = library.wholeItemDeleteGuard(owned, roots: root.map { [$0] } ?? []) { return stop }
            } else if root != nil { return .obsolete }
        } catch { return .failed }
        guard removeNote(noteID: noteID, restoredLegacy: restoredLegacy) else { return .failed }
        let updated = noteHistoryOwnership(noteID, deleted: true)
        owned.members = updated.members; owned.writing = updated.writing; owned.groups = updated.groups
        return .applied
    }

    private func deleteStep(noteID: UUID, reopen: Bool) -> UndoStep {
        let owned = noteHistoryOwnership(noteID, deleted: true)
        return UndoStep(
            name: String(localized: "Delete Note"),
            items: { owned.itemRefs.union([.init(.note, noteID)]) },
            undoOutcome: { [weak self] in self?.restoreHistoryNote(noteID, owned: owned, reopen: reopen) ?? .obsolete },
            redoOutcome: { [weak self] in self?.deleteHistoryNote(noteID, owned: owned) ?? .obsolete }
        )
    }

    /// Pin or Unpin: undo and redo set the state the step moved between.
    private func pinStep(_ pinned: Bool, noteID: UUID) -> UndoStep {
        UndoStep(
            name: pinned ? String(localized: "Pin Note") : String(localized: "Unpin Note"),
            items: { [AtticItemRef(.note, noteID)] },
            undoOutcome: { [weak self] in self?.pinOutcome(!pinned, noteID: noteID) ?? .obsolete },
            redoOutcome: { [weak self] in self?.pinOutcome(pinned, noteID: noteID) ?? .obsolete }
        )
    }

    private func pinOutcome(_ pinned: Bool, noteID: UUID) -> UndoOutcome {
        guard store.note(withID: noteID) != nil else { return .obsolete }
        switch applyPinned(pinned, noteID: noteID) {
        case .changed, .unchanged: return .applied
        case .failed: return .failed
        }
    }

    /// Duplicate: Undo deletes the copy (to Recently Deleted, with any text
    /// typed into it since saved first, so nothing is lost); Redo restores
    /// it without opening it.
    private func duplicateStep(newID: UUID) -> UndoStep {
        let owned = noteHistoryOwnership(newID, deleted: false)
        return UndoStep(
            name: String(localized: "Duplicate Note"),
            items: { owned.itemRefs.union([.init(.note, newID)]) },
            undoOutcome: { [weak self] in self?.deleteHistoryNote(newID, owned: owned) ?? .obsolete },
            redoOutcome: { [weak self] in self?.restoreHistoryNote(newID, owned: owned, reopen: false) ?? .obsolete }
        )
    }

    /// The note as Markdown text (Copy as Markdown): the draft on screen as
    /// it is now, or the stored note.
    func markdown(noteID: UUID) -> String? {
        let document: NoteDocument
        let staged: [UUID: String]
        if let session = cache[noteID] {
            // What a recovery checkpoint would keep: never the transient text
            // of a refused Writing Tools rewrite.
            document = checkpointDocument(for: session)
            staged = session.engine.staged.mapValues(\.filename)
        } else if let stored = store.loadDocument(noteID: noteID)?.content.document {
            document = stored
            staged = [:]
        } else {
            return nil
        }
        return NoteMarkdownExport.markdown(document) { id in staged[id] ?? self.filename(forAttachment: id) }
    }

    func copyMarkdown(noteID: UUID) {
        guard let text = markdown(noteID: noteID) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The note the library selects: the one on screen, else (from a new
    /// draft or after a delete) the last note visited.
    var librarySelectionID: UUID? {
        if let active, active.isPersisted { return active.noteID }
        return lastViewedNoteID
    }
}

// MARK: - Phase 3: purging a deleted task whose note is open (§ 2.7.2)

extension NotesPageController {
    /// What the coordinated purge must know about the open editors of the
    /// family's own notes (S5): their drafts (merged into the
    /// materialization, never replaced by stored content), their activity
    /// (composition, imports, conflicts defer the purge) and their bytes.
    func taskNotePurgeInventory(ownNotes: Set<UUID>) -> WorkspacePurge.Inventory {
        var generation: UInt64 = 1
        var drafts: [UUID: NoteDocument] = [:]
        var sessions: [UUID: WorkspacePurge.SessionSnapshot] = [:]
        var claims: [UUID: NoteRecoveryClaim] = [:]
        var staged: [UUID: [StagedNoteAttachment]] = [:]
        var tags: [UUID: [String]] = [:]
        var selections: [UUID: NSRange] = [:]
        var bytes = Set<UUID>()
        var blocked = Set<UUID>()
        for session in cache.values {
            let id = session.noteID
            generation = generation &* 31 &+ UInt64(truncatingIfNeeded: id.hashValue) &+ session.editGeneration
            for item in session.engine.stagedAttachments(for: session.engine.checkpointDocument()) { bytes.insert(item.id) }
            guard ownNotes.contains(id) else { continue }
            session.engine.refreshCompositionActivity()
            var snapshot = session.workspacePage?.activitySnapshot ?? WorkspacePurge.SessionSnapshot()
            snapshot.activity = session.engine.activity
            snapshot.state = session.isItemDeleted ? .clean : session.state
            snapshot.importing = session.isImporting
            snapshot.proposal = proposalReview?.noteID == id
            if session.engine.textView?.hasMarkedText() == true { snapshot.activity = .composing }
            sessions[id] = snapshot
            if session.recoverySourceNoteID != nil { blocked.insert(id) }
            if NoteSessionPolicy.hasPendingWork(session.state) {
                let document = session.engine.checkpointDocument()
                drafts[id] = document
                staged[id] = session.engine.stagedAttachments(for: document)
                if let claim = session.recoveryClaim { claims[id] = claim }
                if let pending = session.pendingTags { tags[id] = pending }
                selections[id] = session.selection
            }
        }
        return WorkspacePurge.Inventory(generation: generation, bytes: bytes, drafts: drafts, blockedNotes: blocked,
                                        sessions: sessions, claims: claims, staged: staged, tags: tags, selections: selections)
    }

    /// Hold every cached writer until the committed materialization has
    /// been adopted. Plain typing queues; other mutations refuse visibly.
    func reserveTaskNoteInput(_ noteIDs: Set<UUID>) -> [WorkspaceHistory]? {
        var reserved: [WorkspaceHistory] = []
        for session in cache.values where noteIDs.contains(session.noteID) {
            let adapter = session.engine.history
            let taskID = store.note(withID: session.noteID)?.taskID
            let history = adapter.workspace
                ?? taskID.flatMap { undoRoute.existingWorkspace(for: .taskWorkspace($0)) }
                ?? undoRoute.workspace(for: .note(session.noteID))
            if let taskID, !undoRoute.alias(.taskWorkspace(taskID), to: history.historyID) {
                reserved.forEach { $0.releaseInput() }; return nil
            }
            guard adapter.workspace != nil || adapter.redoOps.isEmpty else {
                reserved.forEach { $0.releaseInput() }; return nil
            }
            history.attach(adapter)
            guard history.reserveInput() else {
                reserved.forEach { $0.releaseInput() }; return nil
            }
            reserved.append(history)
        }
        return reserved
    }

    /// After a committed purge materialized `noteID` (now an ordinary
    /// note): an editor that was open on it as a task's note took the
    /// stored text as its base (its draft is what the purge saved) and
    /// leaves; the next open builds an ordinary editor. A warm, closed
    /// task-note editor is dropped.
    func retireMaterializedTaskNote(_ noteID: UUID) {
        store.refresh()
        guard let session = cache[noteID] else { return }
        installCommittedTaskNoteForm(session)
    }

    /// Install the committed form synchronously while input is reserved.
    /// A later asynchronous close can never save the old projection over it.
    private func installCommittedTaskNoteForm(_ session: NoteSession) {
        session.saveTask?.cancel(); session.saveTask = nil
        session.durabilityTask?.cancel(); session.durabilityTask = nil
        session.pauseTask?.cancel(); session.pauseTask = nil
        let load = store.loadDocument(noteID: session.noteID)
        let reason: NoteReadOnlyReason? = if let load {
            if case let .readOnly(_, reason, _) = load.content { reason } else { nil }
        } else { .unreadable("missing document bytes") }
        guard let note = store.note(withID: session.noteID) else {
            session.readOnlyReason = reason
            session.replaceEngine(makeEngine(noteID: session.noteID, document: .blank, readOnly: true))
            session.state = .readOnly
            return
        }
        let history = session.engine.history.workspace
        let document = load?.content.document ?? .blank
        session.baseRevisionID = note.revisionID
        session.baseContent = note.content
        session.baseTags = note.tags
        session.readOnlyReason = reason
        session.replaceEngine(makeEngine(noteID: note.id, document: document, readOnly: reason != nil,
                                         tags: note.tags, bodyOnly: note.taskID != nil))
        if let history { history.attach(session.engine.history) }
        wire(session)
        session.state = reason == nil ? .clean : .readOnly
    }

    func installCommittedTaskNote(_ noteID: UUID) {
        store.refresh()
        if let session = cache[noteID] { installCommittedTaskNoteForm(session) }
    }

    /// A change written by another owner (a purge's Undo): a clean editor
    /// on `noteID` reloads from the store; one with pending writing keeps
    /// it and meets the change as a conflict, as with any external edit.
    func reloadAfterExternalChange(_ noteID: UUID) {
        store.refresh()
        guard let session = cache[noteID], !session.usesWorkspaceBinding else { return }
        guard !NoteSessionPolicy.hasPendingWork(session.state), !session.isImporting else {
            session.state = .conflict(.changed)
            return
        }
        let wasActive = active === session
        session.engine.detachView()
        cache[noteID] = nil
        if wasActive { _ = open(noteID: noteID) }
    }

    /// Make Task from Note (or its Undo) rewrote `noteID` in the other
    /// form: the editor built for the old form leaves (an ordinary one
    /// can't show a task's note, nor the reverse); the store is re-read.
    func retireConvertedNote(_ noteID: UUID, installingCommittedForm: Bool = true) async {
        store.refresh()
        guard let session = cache[noteID] else { return }
        let owner: UUID? = if case let .task(id) = session.workspacePage?.key.workspace { id } else { nil }
        if session.usesWorkspaceBinding {
            if installingCommittedForm { installCommittedTaskNoteForm(session) }
            if let owner, let presenter = TaskNotePresenter.open(for: owner) {
                guard await presenter.close() else { return }
            } else if let page = session.workspacePage, let lease = page.activeLease {
                guard await page.close(lease) else { return }
            }
        }
        if NoteSessionPolicy.hasPendingWork(session.state), !(await preserveDurably(session)) { return }
        guard cache[noteID] === session, session.noteID == noteID else { return }
        session.saveTask?.cancel(); session.durabilityTask?.cancel(); session.pauseTask?.cancel()
        let wasActive = active === session
        session.engine.detachView()
        cache[noteID] = nil
        if wasActive { active = nil }
        if store.note(withID: noteID)?.taskID == nil {
            _ = open(noteID: noteID)
            if let owner { taskNoteBecameOrdinary?(owner, noteID) }
        }
    }

    /// Drops the retired task-note editor once its page has left.
    func evictRetiredTaskNote(_ noteID: UUID) {
        guard let session = cache[noteID], session.engine.isBodyOnly, !session.usesWorkspaceBinding else { return }
        session.engine.detachView()
        cache[noteID] = nil
    }
}

extension NotesPageController {
    func wholeItemSessions(noteIDs: Set<UUID>, taskIDs: Set<UUID>) -> [NoteSession] {
        cache.values.filter { noteIDs.contains($0.noteID) || $0.pendingTaskID.map(taskIDs.contains) == true }
    }
    func retireWholeItemRecovery(_ session: NoteSession) -> Bool {
        retireRecoveryCopy(noteID: session.noteID, session: session)
    }
    func publishWholeItemLifecycle() {
        store.refresh()
        let context = ModelContext(store.container)
        guard let rows = try? context.fetch(FetchDescriptor<NoteItem>()),
              let tasks = try? context.fetch(FetchDescriptor<TaskItem>()) else { return }
        for session in cache.values {
            let row = NoteStore.canonicalReplicas(from: rows.filter { $0.id == session.noteID }).first
            let deleted = row?.deletionGroupID != nil && row?.deletedAt != nil
                || (session.pendingTaskID.map { id in tasks.contains { $0.id == id && $0.deletedAt != nil && $0.deletionGroupID != nil } } ?? false)
            if deleted, !session.isItemDeleted {
                let history = session.engine.history.workspace
                let document = row?.content.flatMap { NoteContentCodec.decode($0).document } ?? session.engine.checkpointDocument()
                session.saveTask?.cancel(); session.durabilityTask?.cancel(); session.pauseTask?.cancel()
                session.isItemDeleted = true
                session.readOnlyReason = .unreadable("This item is in Recently Deleted.")
                session.replaceEngine(makeEngine(noteID: session.noteID, document: document, readOnly: true,
                    tags: row?.tags ?? [], bodyOnly: row?.taskID != nil || session.pendingTaskID != nil))
                if let history { history.attach(session.engine.history) }
                session.state = .readOnly
                wire(session)
            } else if !deleted, session.isItemDeleted, row?.deletedAt == nil,
                      row != nil || (!session.isPersisted && session.pendingTaskID.map { id in tasks.contains { $0.id == id && $0.deletedAt == nil } } == true) {
                session.isItemDeleted = false
                if row != nil { installCommittedTaskNoteForm(session) }
                else {
                    let history = session.engine.history.workspace, document = session.engine.checkpointDocument()
                    session.readOnlyReason = nil
                    session.replaceEngine(makeEngine(noteID: session.noteID, document: document, readOnly: false, bodyOnly: true))
                    if let history { history.attach(session.engine.history) }
                    session.state = .untouched; wire(session)
                }
            }
        }
    }
}

extension NotesPageController {
    /// A new-style deleted item opens its preserved writing read-only; only
    /// legacy split states may offer an independent replacement draft.
    func workspaceDeletedItemSession(noteID: UUID) -> NoteSession? {
        let context = ModelContext(store.container)
        guard let rows = try? context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })),
              let row = NoteStore.canonicalReplicas(from: rows).first,
              row.deletedAt != nil, row.deletionGroupID != nil else { return nil }
        if let existing = cache[noteID], existing.isItemDeleted { return existing }
        let document = row.content.flatMap { NoteContentCodec.decode($0).document } ?? .blank
        let session = NoteSession(noteID: noteID, isPersisted: true, baseRevisionID: row.revisionID,
            engine: makeEngine(noteID: noteID, document: document, readOnly: true, tags: row.tags, bodyOnly: row.taskID != nil),
            readOnlyReason: .unreadable("This item is in Recently Deleted."))
        session.isItemDeleted = true; session.baseContent = row.content; session.baseTags = row.tags
        cache[noteID] = session; wire(session)
        return session
    }
}
