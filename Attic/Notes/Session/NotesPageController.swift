import AppKit
import Combine
import CryptoKit
import UniformTypeIdentifiers

/// Whether the Notes page uses the new editor. Internal: the
/// `AtticUseNewNotesEditor` default, when set, decides (either way);
/// otherwise the new editor is on in every preview identity
/// (`com.taha.Attic.preview.<name>`: "Attic Preview" is
/// `com.taha.Attic.preview.main`) and off elsewhere. A note already in the
/// new format always opens in the new editor, whatever this says.
///
/// The official `com.taha.Attic` identity keeps the legacy editor by
/// default for now: switching it is decided at Phase 2's pull request.
enum NotesEditorSetting {
    static let defaultsKey = "AtticUseNewNotesEditor"
    static let previewBundlePrefix = "com.taha.Attic.preview."

    static func isEnabled(defaults: UserDefaults = .standard, bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Bool {
        if defaults.object(forKey: defaultsKey) != nil { return defaults.bool(forKey: defaultsKey) }
        return isPreviewIdentity(bundleIdentifier)
    }

    /// A strict preview identity: the preview prefix and a name after it.
    static func isPreviewIdentity(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, bundleIdentifier.hasPrefix(previewBundlePrefix) else { return false }
        return bundleIdentifier.count > previewBundlePrefix.count
    }
}

enum NoteStatusItem: Equatable {
    case onlyInMemory(String), notSaved(String), changedElsewhere, deletedElsewhere
    case proposal(String), deletionProposal(String), editedBy(String, Date), importing, notice(String), readOnly(String)

    var label: String {
        switch self {
        case .onlyInMemory: String(localized: "Only in memory")
        case .notSaved: String(localized: "Not saved")
        case .changedElsewhere: String(localized: "Changed elsewhere")
        case .deletedElsewhere: String(localized: "Deleted elsewhere")
        case let .proposal(agent): "\(agent) has changes"
        case let .deletionProposal(agent): "Deleted by \(agent)"
        case let .editedBy(agent, date): "\(agent) edited \(date.formatted(date: .omitted, time: .shortened))"
        case .importing: String(localized: "Adding files")
        case let .notice(message): message
        case .readOnly: String(localized: "Read only")
        }
    }

    var explanation: String? {
        switch self {
        case let .onlyInMemory(reason), let .notSaved(reason), let .notice(reason), let .readOnly(reason): reason
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
    var proposalContent: Data? { signature.content }

    var summary: String {
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
    let readOnlyReason: NoteReadOnlyReason?
    /// A readable checkpoint with unavailable placements. Its display ID is
    /// separate from the original owner; it can never replace that saved note.
    let recoverySourceNoteID: UUID?
    @Published fileprivate(set) var state: State {
        didSet {
            engine.setWritingToolsAvailable(NoteSessionPolicy.writingToolsAvailable(state,
                activity: engine.activity, refusedSinceLastStoreSave: refusedWritingToolsSinceSave,
                hasMarkedText: engine.textView?.hasMarkedText() == true))
        }
    }
    fileprivate var editGeneration: UInt64 = 0
    /// Information for the slot (lowest priority), such as a refused change.
    @Published var notice: String?
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
        self.noteID = noteID
        engine.noteID = noteID
    }

    fileprivate func replaceEngine(_ replacement: NoteEditorEngine) {
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
        !isPersisted && importBatch == nil && engine.tags.isEmpty && engine.document().isEmpty && engine.objectIDs().isEmpty
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
    enum LeaveReason { case openNote, newNote, library, pageSwitch, hide, quit, exitToOldPage }
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
    /// A legacy note the page shows in the old editor.
    @Published private(set) var legacyNoteID: UUID?
    @Published var isLibraryPresented = false
    @Published private(set) var design: AtticDesignContext = .default
    @Published private(set) var recoveryWarnings: [String] = []
    private var damagedRecoveryWarnings = Set<String>()
    /// Moves on each `present()`: the page puts the keyboard back in the
    /// note (Notes reopens where you left it, caret included).
    @Published private(set) var presentationCount = 0
    /// Follows the undo route's revision, so menus that read the library's
    /// undo names redraw when a step is recorded, undone or dropped.
    @Published private(set) var undoRevision: UInt64 = 0

    let store: NoteStore
    /// Where All notes' actions are recorded (the app's route once
    /// `attachUndoRoute` runs; a private one until then, so tests and
    /// previews work alone).
    private(set) var undoRoute = UndoRoute()
    private var undoRevisionSubscription: AnyCancellable?
    let journal: NoteDraftJournaling?
    private let defaults: UserDefaults?
    private let saveDelay: Duration
    private let durabilityDelay: Duration
    private let pauseVersionDelay: Duration
    private let now: () -> Date
    let imageLoader: @Sendable (URL) async -> (StagedNoteAttachment, CGSize?)?
    private let decodeRecoveryDocument: @Sendable (Data) async -> NoteDocument?
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
    private var recoveryLoading = false
    private var recoveryFailureCount = 0
    /// A verified retirement stays valid only until this note writes or adopts
    /// another checkpoint. Unrelated damaged entries do not invalidate it.
    private var retiredNoteIDs = Set<UUID>()
    private var checkpointKeys: [UUID: NoteDraftJournalEntry] = [:]
    private var verifiedCheckpointKeys: [UUID: NoteDraftJournalEntry] = [:]

    /// Waits for durable recovery work; useful for headless callers and tests.
    /// Session replacement waits for this work; hide/page switch retain sessions.
    func waitForRecoveryWork() async {
        while let work = recoveryWork {
            await work.value
            if recoveryWork == nil { break }
        }
    }

    func waitForImportWork() async {
        for session in cache.values { await session.importTask?.value }
        await waitForRecoveryWork()
    }
    func startAndWait() async { start(); await waitForRecoveryWork() }
    func preserveDurably(_ session: NoteSession) async -> Bool {
        guard await awaitRecoveryForUser() else { return false }
        let failures = recoveryFailureCount
        let result = preserve(session)
        guard await awaitRecoveryForUser() else { return false }
        let durable = recoveryFailureCount == failures && (result || hasDurableCheckpoint(session))
        checkpointKeys[session.id] = nil
        return durable
    }
    func preserveAllDurably() async -> Bool {
        if let active { captureViewState(active) }
        var ok = true
        for session in cache.values where NoteSessionPolicy.hasPendingWork(session.state) || session.isImporting {
            let saved = await preserveDurably(session); ok = saved && ok
        }
        return ok
    }
    private func hasDurableCheckpoint(_ session: NoteSession) -> Bool {
        guard session.recoveryClaim != nil, var key = try? journalEntry(for: session,
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
        let result = await performAfterRecovery(requireDrainedRecovery: reason == .quit) { prepareToLeave(reason) }
        // Queued hide/switch preservation may optimistically mark the page
        // hidden. A durable refusal must keep its original agent disposition.
        if !result { isPageVisible = wasVisible }
        return result
    }
    func newNoteDurably() async -> Bool {
        await performAfterRecovery { newNote() }
    }
    func recoverAtLaunchAndWait() async { recoverAtLaunch(); await waitForRecoveryWork() }
    func openDurably(noteID: UUID) async -> Bool {
        if !didRecoverAtLaunch && journal?.requiresAsyncIO == true { recoverAtLaunch() }
        guard await awaitRecoveryForUser() else { return false }
        guard await performAfterRecovery({ open(noteID: noteID) }) else { return false }
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
                                      _ operation: () -> Bool) async -> Bool {
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
        return second && (reportCompletedAction || recoveryFailureCount == failures)
    }

    /// Waiting never cancels the serialized write or releases its live owners.
    /// A slow disk returns control with guidance; the same action can be retried.
    var recoveryResponseTimeout: Duration = .seconds(2)
    private func awaitRecoveryForUser(completedAction: Bool = false) async -> Bool {
        let clock = ContinuousClock(), deadline = ContinuousClock.now + recoveryResponseTimeout
        while recoveryWork != nil {
            guard clock.now < deadline, !Task.isCancelled else {
                reportRecoveryRetentionWarning(completedAction
                    ? "Recovery data is still being saved."
                    : "Recovery data is still being saved. Try again when saving finishes.")
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
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
                reportRecoveryRetentionWarning(message)
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
    /// Saves and closes the old editor's draft before the page moves on
    /// from a legacy note (set by `NoteDraftController`).
    var leaveLegacyNote: (LeaveReason) -> Bool = { _ in true }
    var prepareLegacyVersionReplay: (() -> Bool)?
    var finishLegacyVersionReplay: (() -> Void)?
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
        if let diskJournal = journal as? NoteDraftJournal {
            diskJournal.liveReferencedIDs = { [weak self] in
                Set(self?.cache.values.flatMap { Array($0.engine.staged.keys) + (self?.liveAttachmentIDs(in: $0) ?? []) } ?? [])
            }
        }
        attachUndoRoute(undoRoute)
        store.agentWriteDisposition = { [weak self] id in
            self?.agentDisposition(for: id) ?? .direct
        }
        store.recoveryReferencedAttachmentIDs = { [weak self] in
            guard let self else { return [] }
            // One live-byte rule for purge: every checkpoint, open draft,
            // pending payload and both sides of editor history own bytes.
            var ids = Set(self.cache.values.flatMap { self.liveAttachmentIDs(in: $0) })
            guard let journal = self.journal else { return ids }
            let entries: [NoteDraftRecoveryEntry]
            do { entries = try journal.recoveryEntries() }
            catch {
                self.reportRecoveryRetentionWarning("Recovery copies could not be checked. Removed images are being kept until they can be checked.")
                throw error
            }
            for item in entries {
                guard case let .valid(entry, _, _) = item,
                      let document = NoteContentCodec.decode(entry.content).document else {
                    self.reportRecoveryRetentionWarning("A damaged recovery copy is keeping removed images safe until it is repaired.")
                    throw DamagedNoteRecovery()
                }
                ids.formUnion(document.attachmentIDs)
                ids.formUnion(entry.staged.map(\.id))
                ids.formUnion(entry.pendingImport?.items.compactMap(\.stagedID) ?? [])
            }
            return ids
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

    func refreshRecoveryWarningsAfterResolution() async {
        guard let journal else { return }
        do {
            let remaining = try await journal.listDamagedDurably()
            recoveryWarnings.removeAll { damagedRecoveryWarnings.contains($0) }
            damagedRecoveryWarnings = Set(remaining.map { "Recovery data is damaged: \($0.confirmation.checkpointFilename)." })
            recoveryWarnings += damagedRecoveryWarnings.sorted()
        } catch { reportRecoveryRetentionWarning(error.localizedDescription) }
    }

    private func reportRecoveryRetentionWarning(_ warning: String) {
        if !recoveryWarnings.contains(warning) { recoveryWarnings.append(warning) }
        active?.notice = warning
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
        guard session.isPersisted else { return nil }
        if let cached = proposalStatusCache[session.noteID], cached.revision == store.revision { return cached.agent }
        let edits = store.pendingEdits(noteID: session.noteID)
        let agent = edits.first(where: { !$0.isDeletion }).map {
            $0.agentName.isEmpty ? String(localized: "Agent") : $0.agentName
        }
        proposalStatusCache[session.noteID] = ProposalStatus(revision: store.revision, agent: agent,
            deletionAgent: edits.first(where: \.isDeletion).map { $0.agentName.isEmpty ? "Agent" : $0.agentName },
            editID: edits.first(where: { !$0.isDeletion })?.id, deletionID: edits.first(where: \.isDeletion)?.id)
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
        if let notice = session.notice { items.append(.notice(notice)) }
        if let reason = session.readOnlyReason { items.append(.readOnly(reason.message)) }
        if let note = store.note(withID: session.noteID), let editor = note.externalEditorName, let time = note.externalEditedAt {
            items.append(.editedBy(editor, time))
        }
        return items
    }

    var reviewProposals: [NotePendingEdit] {
        guard let session = active else { return [] }
        return store.pendingEdits(noteID: session.noteID)
    }

    @discardableResult
    func beginProposalReview(id: UUID? = nil) async -> Bool {
        guard await awaitRecoveryForUser(), let session = active, !session.isImporting,
              canLeaveComposition(in: session) else { return false }
        return await performAfterRecovery {
            guard self.active === session, !session.isImporting, self.canLeaveComposition(in: session),
                  self.preserve(session),
                  let edit = self.store.pendingEdits(noteID: session.noteID).first(where: { id == nil || $0.id == id }),
                  let family = try? self.store.pendingEditRows(edit.id),
                  NotePhysicalFamilyRetention.proposalEligible(family, noteIDs: [session.noteID]) else { return false }
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
    }

    @discardableResult
    func acceptProposal() async -> Bool {
        guard await awaitRecoveryForUser(), let review = proposalReview, let session = active,
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
            guard active === session, proposalReview == review, session.engine === engine else { return false }
            _ = refreshProposalReview(id: review.id, session: session)
            proposalReviewNotice = "Your draft changed. Review the refreshed comparison before replacing."
            return false
        }
        return await performAfterRecovery {
            guard self.proposalReview == review, self.active === session, !session.isImporting,
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
                    session.replaceEngine(self.makeEngine(noteID: review.noteID, document: review.proposed,
                        readOnly: false, tags: session.engine.tags))
                    session.baseRevisionID = UUID(uuidString: token)
                    self.wire(session)
                    self.didSave(session, staged: [])
                }
                return true
            }
        }
    }

    @discardableResult
    func discardReviewedProposal() -> Bool {
        guard let review = proposalReview, store.discardProposal(review.id, noteID: review.noteID) else {
            proposalReviewNotice = store.lastErrorMessage ?? "The proposal could not be discarded."
            return false
        }
        endProposalReview()
        return true
    }

    @discardableResult
    func saveReviewedProposalAsNew() async -> Bool {
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
                session.notice = "Saved as a new note."
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
        if active !== draft { guard prepareToLeave(.openNote) else { return false } }
        legacyNoteID = nil
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
            if !recoveryWarnings.isEmpty { active?.notice = recoveryWarnings.joined(separator: " ") }
            return
        }
        _ = newNote()
        if !recoveryWarnings.isEmpty {
            active?.notice = recoveryWarnings.joined(separator: " ")
        }
    }

    /// Opens a note. Legacy notes open in the old editor (`legacyNoteID`).
    @discardableResult
    func open(noteID: UUID) -> Bool {
        if let active, active.noteID == noteID, legacyNoteID == nil {
            present()
            return true
        }
        guard let note = store.note(withID: noteID) else { return false }
        guard prepareToLeave(.openNote) else { return false }
        if !note.usesDocumentFormat {
            active = nil
            legacyNoteID = noteID
            remember(noteID)
            return true
        }
        legacyNoteID = nil
        guard let session = session(for: note).flatMap(presentSession) else { return false }
        activate(session)
        return true
    }

    /// A new draft; the current one is preserved first.
    @discardableResult
    func newNote() -> Bool {
        if let active, active.isUntouchedDraft, legacyNoteID == nil { return true }
        guard prepareToLeave(.newNote) else { return false }
        legacyNoteID = nil
        let id = UUID()
        let session = NoteSession(noteID: id, isPersisted: false, baseRevisionID: nil,
                                  engine: makeEngine(noteID: id, document: .blank, readOnly: false),
                                  readOnlyReason: nil)
        activate(session)
        return true
    }

    private func session(for note: NoteItem) -> NoteSession? {
        if let cached = cache[note.id] { return cached }
        let load = store.loadDocument(noteID: note.id)
        let document = load?.content.document ?? .blank
        let readOnlyReason: NoteReadOnlyReason? = if let load {
            if case let .readOnly(_, reason, _) = load.content { reason } else { nil }
        } else {
            .unreadable("missing document bytes")
        }
        let session = NoteSession(noteID: note.id, isPersisted: true, baseRevisionID: load?.revisionID,
                                  engine: makeEngine(noteID: note.id, document: document, readOnly: readOnlyReason != nil,
                                                     tags: note.tags),
                                  readOnlyReason: readOnlyReason)
        session.baseTags = note.tags
        session.baseContent = note.content
        if let state = defaults?.dictionary(forKey: Self.viewStateKey(note.id)) {
            session.selection = NSRange(location: state["location"] as? Int ?? 0,
                                        length: state["length"] as? Int ?? 0)
            session.scrollOffset = CGFloat(state["scroll"] as? Double ?? 0)
        }
        return session
    }

    private func makeEngine(noteID: UUID, document: NoteDocument, readOnly: Bool,
                            staged: [StagedNoteAttachment] = [], tags: [String] = []) -> NoteEditorEngine {
        let engine = NoteEditorEngine(noteID: noteID, document: document, readOnly: readOnly, design: design,
                                      today: NoteDay(date: now()), imageProvider: self, stagedAttachments: staged,
                                      tags: tags)
        if let editor = store.note(withID: noteID)?.externalEditorName {
            engine.history.outsideEditBarrier = editor
            engine.history.onOutsideEditBarrier = { [weak engine] editor in
                engine?.onNotice?("Edited by \(editor): can't undo past this")
            }
        }
        return engine
    }

    private func activate(_ session: NoteSession) {
        closeHistory()
        wire(session)
        cache[session.noteID] = session
        touch(session.noteID)
        active = session
        if session.isPersisted { remember(session.noteID) }
    }

    /// A clean cached session is rebuilt once, at presentation, if its store
    /// revision or content moved. A missing clean note is dropped.
    private func presentSession(_ session: NoteSession) -> NoteSession? {
        if case .conflict = session.state {
            session.state = .conflict(store.note(withID: session.noteID) == nil ? .deleted : .changed)
            return session
        }
        guard case .clean = session.state, session.isPersisted else { return session }
        guard let note = store.note(withID: session.noteID) else {
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
        cache[session.noteID] = nil
        session.engine.detachView()
        let rebuilt = self.session(for: note)
        if session.recoveryClaim != nil { retiredNoteIDs.remove(session.noteID) }
        rebuilt?.recoveryClaim = session.recoveryClaim
        return rebuilt
    }

    func present() {
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
        engine.onNotice = { [weak session] message in session?.notice = message }
        engine.onFileBatchRequest = { [weak self, weak session] urls, text, range in
            guard let self, let session, self.active === session else { return }
            self.importFiles(urls, acceptedText: text, at: range)
        }
        engine.onRawImageBatchRequest = { [weak self, weak session] data, ext, range in
            guard let self, let session, self.active === session else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("AtticClipboard-\(UUID().uuidString).\(ext)")
            do {
                try data.write(to: url, options: .atomic)
                self.importFiles([url], at: range, temporaryURLs: [url])
            } catch {
                session.notice = String(localized: "The clipboard image could not be staged: \(error.localizedDescription)")
            }
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
        engine.onWritingToolsWillBegin = { [weak self, weak session] in
            guard let self, let session else { return false }
            guard NoteSessionPolicy.writingToolsAvailable(session.state, activity: engine.activity,
                    refusedSinceLastStoreSave: session.refusedWritingToolsSinceSave,
                    hasMarkedText: engine.textView?.hasMarkedText() == true) else {
                engine.writingToolsRefusalReason = String(localized: "Writing Tools unavailable — couldn't save a safety copy.")
                return false
            }
            let saved = session.isImporting && self.hasDurableImportCheckpoint(session) ? true : self.save(session)
            if !saved { _ = self.preserve(session) }
            guard saved, session.isPersisted,
                  self.store.recordVersion(noteID: session.noteID, reason: .beforeWritingTools) else {
                session.refusedWritingToolsSinceSave = true
                engine.writingToolsRefusalReason = String(localized: "Writing Tools unavailable — couldn't save a safety copy.")
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
            return session.recoveryClaim == nil
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
        if legacyNoteID == noteID, isPageVisible, !isLibraryPresented { return .proposal }
        guard let session = cache[noteID] else { return .direct }
        let presence: NoteSessionPolicy.Presence = isPageVisible && !isLibraryPresented && active === session
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
    func prepareToLeave(_ reason: LeaveReason) -> Bool {
        if let active, !canLeaveComposition(in: active) { return false }
        if legacyNoteID != nil, !leaveLegacyNote(reason) { return false }
        let retainsSession = reason == .hide || reason == .pageSwitch
        if reason == .hide || reason == .quit {
            guard preserveAll(allowQueued: retainsSession) else { return false }
        } else if let session = active {
            captureViewState(session)
            guard preserve(session, allowQueued: retainsSession) else { return false }
        }
        endProposalReview()
        if let session = active {
            if session.isPersisted, !NoteSessionPolicy.hasPendingWork(session.state) {
                store.recordVersion(noteID: session.noteID, reason: .leave)
                _ = store.applyPendingEdits(noteID: session.noteID)
            }
            if session.isUntouchedDraft { cache[session.noteID] = nil }
            session.pauseTask?.cancel()
        }
        if reason == .pageSwitch || reason == .hide || reason == .quit || reason == .exitToOldPage {
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
                session.notice = String(localized: "Finish Writing Tools first.")
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
            session.notice = session.engine.activity == .writingToolsSafe || session.engine.activity == .writingToolsRefused
                ? String(localized: "Finish Writing Tools first.")
                : String(localized: "Finish composing text before leaving this note.")
            return false
        }
        return true
    }

    func showLibrary() -> Bool {
        guard prepareToLeave(.library) else { return false }
        isLibraryPresented = true
        return true
    }

    func dismissLibrary() {
        isLibraryPresented = false
        guard active != nil || legacyNoteID != nil else {
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
    func preserveAll(allowQueued: Bool = false) -> Bool {
        if let active { captureViewState(active) }
        var ok = true
        for session in cache.values where NoteSessionPolicy.hasPendingWork(session.state) || session.isImporting {
            ok = preserve(session, allowQueued: allowQueued) && ok
        }
        return ok
    }

    /// Save, else checkpoint, else keep in memory and say so.
    @discardableResult
    func preserve(_ session: NoteSession, allowQueued: Bool = false) -> Bool {
        // This session already has a durable checkpoint, owned by its source.
        // Navigation must neither overwrite it nor adopt its missing payloads.
        if session.recoverySourceNoteID != nil { return true }
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
                let noteID = session.noteID
                queueRecoveryWork { [weak self, session] in
                    guard let self, session.noteID == noteID else { return }
                    if self.checkpointKeys[session.id] == key && session.recoveryClaim != nil { return }
                    do {
                        self.retiredNoteIDs.remove(noteID)
                        let claim = try await journal.writeDurably(entry, staged: bytes, replacing: session.recoveryClaim)
                        guard session.noteID == noteID else { return }
                        session.recoveryClaim = claim
                        self.checkpointKeys[session.id] = key
                        self.verifiedCheckpointKeys[session.id] = key
                        if session.notice == "Saving recovery data…"
                            || session.notice == "Recovery data is still being saved. Try again when saving finishes." { session.notice = nil }
                        if session.isConflict { return }
                        if !silent { session.state = .notSaved(self.storeMessage()) }
                    } catch { self.recoveryFailureCount += 1; session.state = .onlyInMemory("Recovery could not be saved: \(error.localizedDescription)") }
                }
                session.notice = "Saving recovery data…"
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
        let noteID = session.noteID
        let engine = session.engine
        let baseRevisionID = session.baseRevisionID
        let tags = session.engine.tags
        let document = session.engine.document()
        let staged = session.engine.stagedAttachments(for: document)
        let prepared = await prepareDocument(document)
        guard !Task.isCancelled, noteID == session.noteID, engine === session.engine,
              baseRevisionID == session.baseRevisionID,
              isDeadline || generation == session.editGeneration else { return }
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
        guard !session.isImporting else { return checkpoint(session, silent: true) }
        guard canCommit(session) else { return false }
        guard NoteSessionPolicy.hasPendingWork(session.state) else { return true }
        guard !session.isReadOnly else { return true }
        let engine = session.engine
        let document = snapshot ?? engine.document()
        let staged = stagedSnapshot ?? engine.stagedAttachments(for: document)
        let tags = tagsSnapshot ?? session.engine.tags
        if !session.isPersisted {
            guard !document.isEmpty || !document.objectIDs.isEmpty || !tags.isEmpty else {
                session.state = retainingNewerEdits ? .dirty : .untouched
                return true
            }
            switch store.createDocumentNote(id: session.noteID, document: document, staged: staged,
                                            prepared: prepared, tags: tags.isEmpty ? nil : tags) {
            case let .success((noteID, revisionID)):
                session.isPersisted = true
                session.baseRevisionID = revisionID
                session.baseTags = tags
                didSave(session, staged: staged, retainingNewerEdits: retainingNewerEdits)
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
            didSave(session, staged: staged, retainingNewerEdits: retainingNewerEdits)
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
            session.notice = String(localized: "An image is unavailable, so this draft remains in recovery until it can be restored.")
            return false
        }
        let tags = session.engine.tags
        guard case let .success((newID, revisionID)) = store.createDocumentNote(id: UUID(), document: replacement,
                                                                                  staged: images,
                                                                                  tags: tags.isEmpty ? nil : tags) else {
            session.notice = String(localized: "Couldn’t save a new note; your text is still in recovery.")
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
        session.notice = successNotice
        didSave(session, staged: images)
        if let journal {
            do {
                if let oldClaim {
                    if journal.requiresAsyncIO {
                        queueRecoveryWork {
                            do { try await journal.discardOwnedDurably(noteID: oldID, claim: oldClaim) }
                            catch { session.notice = "Your text was saved, but its old recovery copy is being kept until it can be checked." }
                        }
                    } else { try journal.discardOwned(noteID: oldID, claim: oldClaim) }
                }
            } catch {
                session.notice = String(localized: "Your text was saved, but its old recovery copy is being kept until it can be checked.")
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
            active?.notice = String(localized: "Saved, but an old recovery copy could not be cleared.")
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
                    if session?.notice == "Saved, but an old recovery copy could not be cleared." { session?.notice = nil }
                    if let session {
                        self.checkpointKeys[session.id] = nil
                        self.verifiedCheckpointKeys[session.id] = nil
                    }
                } catch {
                    self.recoveryFailureCount += 1
                    let message = "Saved recovery is being kept because its bytes could not be handed off safely."
                    if let session { session.notice = message } else { self.active?.notice = message }
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
        if case .conflict = active.state { return }
        _ = preserve(active)
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
            session.notice = message
            return true
        } catch {
            session.notice = String(localized: "The recovery copy couldn’t be saved: \(error.localizedDescription)")
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
    func recoverAtLaunch() {
        guard !didRecoverAtLaunch else { return }
        if let journal, journal.requiresAsyncIO {
            guard !recoveryLoading else { return }
            recoveryLoading = true
            queueRecoveryWork { [weak self] in
                guard let self else { return }
                do {
                    _ = try await journal.readRecoveryEntries()
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
                self.didRecoverAtLaunch = true
                self.recoveryLoading = false
                if self.startRequested { self.start() }
            }
            return
        }
        recoverFromCachedJournal()
    }

    private func recoverFromCachedJournal(savedProofs: [UUID: [UUID: StagedNoteAttachment]] = [:]) {
        didRecoverAtLaunch = true
        guard let journal else { return }
        let entries: [NoteDraftRecoveryEntry]
        do { entries = try journal.recoveryEntries() }
        catch {
            recoveryWarnings.append("Recovery copies could not be listed: \(error.localizedDescription)")
            return
        }
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
                                   tags: entry.tags ?? storedTags),
                readOnlyReason: nil)
            // Unchanged tags stay the stored ones' business (nothing is written
            // over them), yet the draft keeps them, even if its note is gone.
            session.baseTags = entry.changedTags == nil ? (entry.tags ?? storedTags) : storedTags
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
            session.notice = String(localized: "Restored unsaved text.")
            cache[session.noteID] = session
            touch(session.noteID)
            newestRecovered = session
        }
        if !recoveryWarnings.isEmpty { newestRecovered?.notice = recoveryWarnings.joined(separator: " ") }
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
                     temporaryURLs: [URL] = []) {
        guard let session = active, !session.isReadOnly, !urls.isEmpty else {
            temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            return
        }
        guard NoteSessionPolicy.commandAllowed(session.engine.activity,
                hasMarkedText: session.engine.textView?.hasMarkedText() == true) else {
            temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            session.notice = String(localized: "Finish Writing Tools or composing text before adding files.")
            return
        }
        guard session.importBatch == nil else {
            temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            session.notice = String(localized: "Finish the current file import before adding more files.")
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
            if self.journal != nil {
                _ = self.checkpoint(session, silent: true)
                await self.waitForRecoveryWork()
                self.checkpointKeys[session.id] = nil
            }
            var loaded: [NoteImportedObject] = []
            for url in urls {
                guard !Task.isCancelled, session.importBatch?.id == batchID else { return }
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
            session.notice = failure
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
                notice: String(localized: "The note was deleted, so its file batch was not added."))
            if hadUnsavedChanges { session.state = .conflict(.deleted) }
            return
        }
        switch NoteSessionPolicy.importCompletion(session.state, activity: session.engine.activity) {
        case .deferUntilIdle:
            return
        case .drop:
            dropImport(in: session, batchID: batch.id,
                notice: String(localized: "The note was deleted or is read only, so the files were not added."))
        case .insert:
            let target = session.engine.currentImportTarget
            guard session.engine.insertImportedObjects(loaded, acceptedText: batch.acceptedText) else {
                if let target {
                    session.engine.restoreImageImport(anchor: target.anchor,
                        replacementLength: target.replacementLength, isBoundary: target.isBoundary)
                    session.importBatch = batch
                    _ = checkpoint(session, silent: true)
                }
                session.notice = String(localized: "The files could not be added to this note.")
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
            notice: String(localized: "The file batch was cancelled."))
    }

    private func dropImport(in session: NoteSession, batchID: UUID, notice: String) {
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
                    session.notice = notice
                    // Keep edits made while cancellation was committing. Their
                    // checkpoint now has no cancelled batch or pending metadata.
                    if session.editGeneration != generation { _ = self.checkpoint(session, silent: true) }
                } catch {
                    session.cancellingImport = false
                    session.notice = "The batch could not be cancelled because recovery could not be updated."
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
            session.notice = String(localized: "The batch could not be cancelled because its recovery copy could not be updated.")
            return
        }
        session.importTask?.cancel()
        session.importTask = nil
        session.engine.cancelImageImport()
        session.notice = notice
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
                  let data = try? Data(contentsOf: url), data.count == size,
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
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
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
    func openHistoryDurably() async -> Bool {
        guard historyBrowser == nil, let session = active, session.isPersisted,
              !session.isReadOnly, !session.isImporting, !session.isConflict,
              canLeaveComposition(in: session) else { return false }
        captureViewState(session)
        guard await preserveDurably(session), active === session, session.state == .clean,
              store.note(withID: session.noteID)?.revisionID == session.baseRevisionID else {
            session.notice = "The current note must be saved before opening version history. Your text is kept."
            return false
        }
        session.pauseTask?.cancel()
        let entries = store.versions(noteID: session.noteID).map(NoteHistoryEntry.init)
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
        let engine = makeEngine(noteID: browser.noteID, document: comparison.document, readOnly: true)
        var offset = 0
        let text = engine.textStorage.string as NSString
        for (index, block) in comparison.document.blocks.enumerated() {
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
              !browser.isRestoring, !browser.showsCurrent, let session = active,
              session.noteID == browser.noteID, session.state == .clean, !session.isImporting,
              canLeaveComposition(in: session) else { return false }
        let engine = session.engine, generation = session.editGeneration
        browser.isRestoring = true
        defer { browser.isRestoring = false }
        guard await awaitRecoveryForUser(), historyBrowser === browser, active === session,
              session.engine === engine, session.editGeneration == generation, session.state == .clean,
              !session.isImporting, canLeaveComposition(in: session) else { return false }
        let preservationID = UUID()
        switch store.restoreVersion(selected.id, noteID: browser.noteID,
                                    expectedRevisionID: browser.currentRevision, preservationID: preservationID) {
        case let .failure(error):
            browser.failure = error.localizedDescription
            return false
        case let .success(token):
            guard let revision = UUID(uuidString: token), let note = store.note(withID: browser.noteID) else { return false }
            if let previous = versionRestoreUndo { store.historyRetainedVersionIDs.remove(previous.versionID) }
            versionRestoreUndo = VersionRestoreUndo(id: UUID(), noteID: browser.noteID, versionID: preservationID,
                restoredRevisionID: revision, document: store.loadDocument(noteID: browser.noteID)?.content.document,
                tags: note.tags, historyPosition: [], session: session, isUndo: true)
            store.historyRetainedVersionIDs.insert(preservationID)
            closeHistory()
            session.engine.detachView()
            cache[browser.noteID] = nil
            if note.usesDocumentFormat, let restored = self.session(for: note) {
                activate(restored)
            } else {
                // A pre-migration snapshot keeps its original legacy bytes
                // and uses the existing legacy presentation path.
                active = nil
                legacyNoteID = note.id
            }
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
        return current.engine.document() == step.document
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
                  current.engine.document() == undo.document,
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
                  canLeaveComposition(in: current), current.engine.document() == undo.document,
                  current.engine.history.undoOps.map(ObjectIdentifier.init) == undo.historyPosition,
                  current.engine.tags == tags, let latest = versionRestoreUndo,
                  latest.id == expectedID, latest.isUndo == isUndo,
                  latest.restoredRevisionID == expectedRevision,
                  store.note(withID: undo.noteID)?.revisionID == expectedRevision else { return false }
        } else {
            guard historyBrowser == nil, legacyNoteID == undo.noteID,
                  prepareLegacyVersionReplay?() ?? leaveLegacyNote(.openNote),
                  store.note(withID: undo.noteID)?.revisionID == expectedRevision else { return false }
        }
        let inverseID = UUID()
        switch store.restoreVersion(undo.versionID, noteID: undo.noteID, expectedRevisionID: expectedRevision,
                                    preservationID: inverseID) {
        case let .failure(error): current?.notice = error.localizedDescription; return false
        case let .success(token):
            if current == nil { finishLegacyVersionReplay?() }
            closeHistory()
            current?.engine.detachView()
            guard let revision = UUID(uuidString: token), let note = store.note(withID: undo.noteID) else { return false }
            if let returned = undo.session {
                legacyNoteID = nil
                returned.baseRevisionID = revision
                returned.baseContent = note.content
                returned.baseTags = note.tags
                // The displaced session can receive late callbacks while retained
                // for Undo. Its text and tags remain owned until actually saved.
                returned.state = returned.engine.document() == store.loadDocument(noteID: undo.noteID)?.content.document
                    && returned.engine.tags == note.tags ? .clean : .dirty
                activate(returned)
            } else {
                cache[undo.noteID] = nil
                active = nil
                legacyNoteID = undo.noteID
            }
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
        legacyNoteID = nil
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
        // Deleting the note on screen returns to it on Undo.
        let reopen = active?.noteID == noteID && !isLibraryPresented
        guard removeNote(noteID: noteID) else { return false }
        undoRoute.record(deleteStep(noteID: noteID, reopen: reopen), in: .notesLibrary)
        return true
    }

    /// The delete itself, as a history step also runs it (Redo, and Undo of
    /// a duplicate).
    private func removeNote(noteID: UUID) -> Bool {
        if legacyNoteID == noteID {
            guard leaveLegacyNote(.openNote) else { return false }
        }
        let session = cache[noteID]
        if let session {
            session.engine.refreshCompositionActivity()
            guard NoteSessionPolicy.deleteAllowed(session.state, activity: session.engine.activity,
                    hasBatch: session.isImporting, hasMarkedText: session.engine.textView?.hasMarkedText() == true) else {
                session.notice = switch session.state {
                case .conflict: String(localized: "Keep this text as a new note before deleting it.")
                default: session.isImporting
                    ? String(localized: "Images are still being added. Delete the note when they finish.")
                    : String(localized: "Finish Writing Tools or composing text before deleting this note.")
                }
                return false
            }
            if NoteSessionPolicy.hasPendingWork(session.state) || !session.isPersisted {
                guard preserve(session), session.isPersisted, !NoteSessionPolicy.hasPendingWork(session.state) else {
                    session.notice = String(localized: "The latest text couldn’t be saved, so the note was not deleted.")
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
            if let session { session.notice = message } else { active?.notice = message }
            return false
        }
        if let session {
            session.saveTask?.cancel()
            session.durabilityTask?.cancel()
            session.pauseTask?.cancel()
            cache[noteID] = nil
        }
        guard store.delete(note) else {
            if let session {
                cache[noteID] = session
                touch(noteID)
                session.notice = storeMessage()
            }
            return false
        }
        recency.removeAll { $0 == noteID }
        if legacyNoteID == noteID { legacyNoteID = nil }
        if lastViewedNoteID == noteID { defaults?.removeObject(forKey: Self.lastViewedKey) }
        if let session, active === session {
            active = nil
            isLibraryPresented = true
        }
        session?.engine.detachView()
        return true
    }

    /// The Undo toast after Delete Note: the note comes back from Recently
    /// Deleted with its text, tags and images; `reopen` shows it again.
    @discardableResult
    func restoreDeletedNote(noteID: UUID, reopen: Bool) -> Bool {
        guard store.restoreDeleted(noteID: noteID) else { return false }
        if reopen, open(noteID: noteID) { isLibraryPresented = false }
        return true
    }

    /// Duplicate (⌘D): a new note with this note's current text, copies of
    /// its images and its tags, titled "… copy", and opened.
    @discardableResult
    func duplicateNote(noteID: UUID) -> Bool {
        guard let newID = makeDuplicate(noteID: noteID) else { return false }
        undoRoute.record(duplicateStep(newID: newID), in: .notesLibrary)
        return true
    }

    private func makeDuplicate(noteID: UUID) -> UUID? {
        // 1. The gates, before anything is read or written: the source's
        //    activity (composition, Writing Tools), a loading batch, and
        //    leaving the note on screen. A refusal creates nothing.
        if let session = cache[noteID] {
            session.engine.refreshCompositionActivity()
            guard NoteSessionPolicy.duplicateAllowed(session.state, activity: session.engine.activity,
                    hasBatch: session.isImporting, hasMarkedText: session.engine.textView?.hasMarkedText() == true) else {
                session.notice = switch session.state {
                case .conflict: String(localized: "Keep this text as a new note before duplicating it.")
                case .readOnly: String(localized: "This note can’t be duplicated here.")
                default: session.isImporting
                    ? String(localized: "Images are still being added. Duplicate the note when they finish.")
                    : String(localized: "Finish Writing Tools or composing text before duplicating this note.")
                }
                return nil
            }
        }
        guard prepareToLeave(.openNote) else { return nil }
        // 2. The source as it is now (its latest text was just preserved).
        let document: NoteDocument
        let staged: [StagedNoteAttachment]
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
        guard var (copy, images) = replacementForDeletedNote(document, oldID: noteID, staged: staged) else {
            active?.notice = String(localized: "An image is unavailable, so the note was not duplicated.")
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
              let note = store.note(withID: newID), let session = session(for: note).flatMap(presentSession) else {
            active?.notice = String(localized: "The note couldn’t be duplicated: \(storeMessage())")
            return nil
        }
        legacyNoteID = nil
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
    private func deleteStep(noteID: UUID, reopen: Bool) -> UndoStep {
        UndoStep(
            name: String(localized: "Delete Note"),
            undoOutcome: { [weak self] in
                guard let self else { return .obsolete }
                if self.restoreDeletedNote(noteID: noteID, reopen: reopen) { return .applied }
                return self.store.recentlyDeletedNotes().contains { $0.ref.id == noteID } ? .failed : .obsolete
            },
            redoOutcome: { [weak self] in
                guard let self else { return .obsolete }
                guard self.store.note(withID: noteID) != nil else { return .obsolete }
                return self.removeNote(noteID: noteID) ? .applied : .failed
            }
        )
    }

    /// Pin or Unpin: undo and redo set the state the step moved between.
    private func pinStep(_ pinned: Bool, noteID: UUID) -> UndoStep {
        UndoStep(
            name: pinned ? String(localized: "Pin Note") : String(localized: "Unpin Note"),
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
        UndoStep(
            name: String(localized: "Duplicate Note"),
            undoOutcome: { [weak self] in
                guard let self else { return .obsolete }
                guard self.store.note(withID: newID) != nil else { return .obsolete }
                return self.removeNote(noteID: newID) ? .applied : .failed
            },
            redoOutcome: { [weak self] in
                guard let self else { return .obsolete }
                if self.restoreDeletedNote(noteID: newID, reopen: false) { return .applied }
                return self.store.recentlyDeletedNotes().contains { $0.ref.id == newID } ? .failed : .obsolete
            }
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
        } else if let note = store.note(withID: noteID), !note.usesDocumentFormat {
            return NoteMarkdownExport.markdown(title: note.title, body: note.body)
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
        if let legacyNoteID { return legacyNoteID }
        if let active, active.isPersisted { return active.noteID }
        return lastViewedNoteID
    }
}
