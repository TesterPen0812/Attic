import AppKit
import Combine
import CryptoKit
import UniformTypeIdentifiers

/// Whether the Notes page uses the new editor. Internal: a defaults key,
/// on by default only in the Phase 2 preview identity. A note already in
/// the new format always opens in the new editor, whatever this says.
enum NotesEditorSetting {
    static let defaultsKey = "AtticUseNewNotesEditor"
    static let previewBundlePrefix = "com.taha.Attic.preview.notes"

    static func isEnabled(defaults: UserDefaults = .standard, bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Bool {
        if defaults.object(forKey: defaultsKey) != nil { return defaults.bool(forKey: defaultsKey) }
        return bundleIdentifier?.hasPrefix(previewBundlePrefix) ?? false
    }
}

/// A problem the status slot shows, most urgent first (plan §3.12).
enum NoteSaveProblem: Equatable {
    /// Neither the store nor the recovery checkpoint took the draft: it is
    /// only in memory and is never released.
    case onlyInMemory(String)
    /// The store refused; the recovery checkpoint holds the draft.
    case notSaved(String)
    /// The canonical stored note moved on; the draft remains in recovery.
    case changedElsewhere
    case deletedElsewhere
}

enum NoteStatusItem: Equatable {
    case onlyInMemory(String), notSaved(String), changedElsewhere, deletedElsewhere
    case proposal(String), importing, notice(String), readOnly(String)

    var label: String {
        switch self {
        case .onlyInMemory: String(localized: "Only in memory")
        case .notSaved: String(localized: "Not saved")
        case .changedElsewhere: String(localized: "Changed elsewhere")
        case .deletedElsewhere: String(localized: "Deleted elsewhere")
        case let .proposal(agent): "\(agent) has changes"
        case .importing: String(localized: "Adding images")
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
        case .importing: String(localized: "Images are still being added to this note.")
        }
    }
}

private struct DamagedNoteRecovery: Error {}

fileprivate struct NoteImportBatch {
    let id: UUID
    let urls: [URL]
    var loaded: [(StagedNoteAttachment, CGSize?)]? = nil
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
    @Published private(set) var engine: NoteEditorEngine
    let readOnlyReason: NoteReadOnlyReason?
    @Published fileprivate(set) var state: State {
        didSet {
            engine.setWritingToolsAvailable(NoteSessionPolicy.writingToolsAvailable(state,
                activity: engine.activity, refusedSinceLastStoreSave: refusedWritingToolsSinceSave))
        }
    }
    fileprivate(set) var isDirty: Bool {
        get {
            switch state {
            case .dirty, .notSaved, .onlyInMemory, .conflict: true
            default: false
            }
        }
        set {
            if newValue {
                if case .clean = state { state = .dirty }
                if case .untouched = state { state = .dirty }
            } else if case .dirty = state {
                state = isPersisted ? .clean : .untouched
            }
        }
    }
    fileprivate var editGeneration: UInt64 = 0
    fileprivate(set) var problem: NoteSaveProblem? {
        get {
            switch state {
            case let .notSaved(reason): .notSaved(reason)
            case let .onlyInMemory(reason): .onlyInMemory(reason)
            case .conflict(.changed): .changedElsewhere
            case .conflict(.deleted): .deletedElsewhere
            default: nil
            }
        }
        set {
            switch newValue {
            case let .notSaved(reason): state = .notSaved(reason)
            case let .onlyInMemory(reason): state = .onlyInMemory(reason)
            case .changedElsewhere: state = .conflict(.changed)
            case .deletedElsewhere: state = .conflict(.deleted)
            case nil: state = isPersisted ? .clean : .untouched
            }
        }
    }
    /// Information for the slot (lowest priority), such as a refused change.
    @Published var notice: String?
    fileprivate(set) var lastEditAt: Date?
    fileprivate(set) var selection = NSRange(location: 0, length: 0)
    fileprivate(set) var scrollOffset: CGFloat = 0
    fileprivate var recoverySourceID: UUID?
    @Published fileprivate var importBatch: NoteImportBatch?
    fileprivate var importTask: Task<Void, Never>?
    fileprivate var refusedWritingToolsSinceSave = false
    fileprivate var saveTask: Task<Void, Never>?
    fileprivate var pauseTask: Task<Void, Never>?

    fileprivate init(noteID: UUID, isPersisted: Bool, baseRevisionID: UUID?, engine: NoteEditorEngine,
                     readOnlyReason: NoteReadOnlyReason?) {
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
        engine = replacement
    }

    var isReadOnly: Bool { readOnlyReason != nil }
    var isConflict: Bool { if case .conflict = state { true } else { false } }
    var isImporting: Bool { importBatch != nil }

    /// Untouched: never saved, no text, no objects.
    var isUntouchedDraft: Bool {
        !isPersisted && importBatch == nil && engine.document().isEmpty && engine.objectIDs().isEmpty
    }
}

/// The new Notes page's sessions (Phase 2): opening, creating, saving and
/// preserving notes, independent of views.
///
/// Contracts (critique finding 1; spec § Reliability):
/// - text is saved within `saveDelay` (300 ms) of the last edit, and on
///   hide, quit, page switch and navigation;
/// - before any navigation the draft is saved or checkpointed; if both fail
///   the session stays, marked "Only in memory", and navigation is refused;
/// - recovered drafts reopen before the normal opening rule;
/// - a never-saved draft with no content is discarded, nothing else is.
@MainActor
final class NotesPageController: ObservableObject {
    enum LeaveReason { case openNote, newNote, library, pageSwitch, hide, quit, exitToOldPage }
    @Published private(set) var active: NoteSession?
    /// A legacy note the page shows in the old editor.
    @Published private(set) var legacyNoteID: UUID?
    @Published var isLibraryPresented = false
    @Published private(set) var design: AtticDesignContext = .default
    @Published private(set) var recoveryWarnings: [String] = []

    let store: NoteStore
    let journal: NoteDraftJournaling?
    private let defaults: UserDefaults?
    private let saveDelay: Duration
    private let pauseVersionDelay: Duration
    private let now: () -> Date
    private let imageLoader: @Sendable (URL) async -> (StagedNoteAttachment, CGSize?)?
    private let prepareDocument: @Sendable (NoteDocument) async -> PreparedNoteDocument?
    private var cache: [UUID: NoteSession] = [:]
    private var recency: [UUID] = []
    private var proposalStatusCache: [UUID: (revision: UInt64, agent: String?)] = [:]
    private let cacheLimit = 8
    private var didStart = false
    private var didRecoverAtLaunch = false
    private var newestRecovered: NoteSession?
    private var isPageVisible = false
    /// Saves and closes the old editor's draft before the page moves on
    /// from a legacy note (set by `NoteDraftController`).
    var leaveLegacyNote: (LeaveReason) -> Bool = { _ in true }
    private static let lastViewedKey = "notes.lastViewedNote.v2"

    private static func viewStateKey(_ id: UUID) -> String { "notes.viewState.\(id.uuidString)" }

    init(store: NoteStore, journal: NoteDraftJournaling?, defaults: UserDefaults? = nil,
         saveDelay: Duration = .milliseconds(300), pauseVersionDelay: Duration = .seconds(120),
         now: @escaping () -> Date = Date.init,
         imageLoader: @escaping @Sendable (URL) async -> (StagedNoteAttachment, CGSize?)? = NotesPageController.loadImageFile,
         prepareDocument: @escaping @Sendable (NoteDocument) async -> PreparedNoteDocument? = { document in
             await Task.detached { try? PreparedNoteDocument(document) }.value
         }) {
        self.store = store
        self.journal = journal
        self.defaults = defaults
        self.saveDelay = saveDelay
        self.pauseVersionDelay = pauseVersionDelay
        self.now = now
        self.imageLoader = imageLoader
        self.prepareDocument = prepareDocument
        store.agentWriteDisposition = { [weak self] id in
            self?.agentDisposition(for: id) ?? .direct
        }
        store.recoveryReferencedAttachmentIDs = { [weak self] in
            guard let self, let journal = self.journal else { return [] }
            var ids = Set<UUID>()
            let entries: [NoteDraftRecoveryEntry]
            do { entries = try journal.recoveryEntries() }
            catch {
                self.reportRecoveryRetentionWarning("Recovery copies could not be checked. Removed images are being kept until they can be checked.")
                throw error
            }
            for item in entries {
                guard case let .valid(entry, _) = item,
                      let document = NoteContentCodec.decode(entry.content).document else {
                    self.reportRecoveryRetentionWarning("A damaged recovery copy is keeping removed images safe until it is repaired.")
                    throw DamagedNoteRecovery()
                }
                ids.formUnion(document.attachmentIDs)
                ids.formUnion(entry.staged.map(\.id))
            }
            return ids
        }
        store.recoveryProtectedRevisionIDs = { [weak self] in
            guard let journal = self?.journal else { return [] }
            let entries = try journal.recoveryEntries()
            var bases = Set<UUID>()
            for item in entries {
                guard case let .valid(entry, _) = item else { throw DamagedNoteRecovery() }
                if let base = entry.baseRevisionID { bases.insert(base) }
            }
            return bases
        }
    }

    private func reportRecoveryRetentionWarning(_ warning: String) {
        if !recoveryWarnings.contains(warning) { recoveryWarnings.append(warning) }
        active?.notice = warning
    }

    var lastViewedNoteID: UUID? {
        defaults?.string(forKey: Self.lastViewedKey).flatMap(UUID.init(uuidString:))
    }

    /// Failed sessions are listed even when no note row was ever committed.
    var failedDrafts: [NoteSession] {
        recency.reversed().compactMap { cache[$0] }.filter { $0.problem != nil }
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
        let agent = store.pendingEdits(noteID: session.noteID).first.map {
            $0.agentName.isEmpty ? String(localized: "Agent") : $0.agentName
        }
        proposalStatusCache[session.noteID] = (store.revision, agent)
        return agent
    }

    func statusItems(for session: NoteSession) -> [NoteStatusItem] {
        var items: [NoteStatusItem] = []
        switch session.problem {
        case let .onlyInMemory(reason): items.append(.onlyInMemory(reason))
        case let .notSaved(reason): items.append(.notSaved(reason))
        case .changedElsewhere: items.append(.changedElsewhere)
        case .deletedElsewhere: items.append(.deletedElsewhere)
        case nil: break
        }
        if let agent = proposalAgent(for: session) { items.append(.proposal(agent)) }
        if session.isImporting { items.append(.importing) }
        if let notice = session.notice { items.append(.notice(notice)) }
        if let reason = session.readOnlyReason { items.append(.readOnly(reason.message)) }
        return items
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
        if !didRecoverAtLaunch { recoverAtLaunch() }
        didStart = true
        isPageVisible = true
        pruneObsoleteViewState()
        if let recovered = newestRecovered {
            newestRecovered = nil
            if let shown = presentSession(recovered) {
                activate(shown)
                return
            }
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
                                  engine: makeEngine(noteID: note.id, document: document, readOnly: readOnlyReason != nil),
                                  readOnlyReason: readOnlyReason)
        if let state = defaults?.dictionary(forKey: Self.viewStateKey(note.id)) {
            session.selection = NSRange(location: state["location"] as? Int ?? 0,
                                        length: state["length"] as? Int ?? 0)
            session.scrollOffset = CGFloat(state["scroll"] as? Double ?? 0)
        }
        return session
    }

    private func makeEngine(noteID: UUID, document: NoteDocument, readOnly: Bool,
                            staged: [StagedNoteAttachment] = []) -> NoteEditorEngine {
        let engine = NoteEditorEngine(noteID: noteID, document: document, readOnly: readOnly, design: design,
                                      today: NoteDay(date: now()), imageProvider: self, stagedAttachments: staged)
        return engine
    }

    private func activate(_ session: NoteSession) {
        wire(session)
        cache[session.noteID] = session
        touch(session.noteID)
        active = session
        if session.isPersisted { remember(session.noteID) }
    }

    /// A clean cached session is rebuilt once, at presentation, if its store
    /// revision moved. A missing clean note is dropped.
    private func presentSession(_ session: NoteSession) -> NoteSession? {
        guard case .clean = session.state, session.isPersisted else { return session }
        guard let note = store.note(withID: session.noteID) else {
            cache[session.noteID] = nil
            session.engine.detachView()
            return nil
        }
        guard session.baseRevisionID != note.revisionID else { return session }
        cache[session.noteID] = nil
        session.engine.detachView()
        return self.session(for: note)
    }

    func present() {
        isPageVisible = true
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
        engine.imageProvider = self
        engine.onTextChange = { [weak self, weak session] in
            guard let self, let session else { return }
            self.textDidChange(in: session)
        }
        engine.onActivityChanged = { [weak self, weak session] old, new in
            guard let self, let session else { return }
            if old != .idle && new == .idle {
                self.completeImportIfPossible(in: session)
                if session.isDirty || session.problem != nil {
                    _ = self.preserve(session)
                } else {
                    self.clearRecoveryCopy(noteID: session.noteID)
                }
            }
            self.updateWritingToolsAvailability(for: session)
        }
        engine.onNotice = { [weak session] message in session?.notice = message }
        engine.onWritingToolsWillBegin = { [weak self, weak session] in
            guard let self, let session else { return false }
            guard NoteSessionPolicy.writingToolsAvailable(session.state, activity: engine.activity,
                    refusedSinceLastStoreSave: session.refusedWritingToolsSinceSave) else {
                engine.writingToolsRefusalReason = String(localized: "Writing Tools unavailable — couldn't save a safety copy.")
                return false
            }
            let saved = self.save(session)
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
            activity: session.engine.activity, refusedSinceLastStoreSave: session.refusedWritingToolsSinceSave))
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
            return NoteSessionPolicy.canEvict(session.state, activity: session.engine.activity,
                                              hasBatch: session.isImporting, presence: presence)
        }) {
            recency.removeAll { $0 == evict }
            cache[evict]?.saveTask?.cancel()
            cache[evict]?.pauseTask?.cancel()
            cache[evict]?.engine.detachView()
            cache[evict] = nil
        }
    }

    private func agentDisposition(for noteID: UUID) -> NoteAgentWriteDisposition {
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
        if let session = active {
            captureViewState(session)
            guard preserve(session) else { return false }
            if session.isPersisted, !session.isDirty {
                store.recordVersion(noteID: session.noteID, reason: .leave)
                if store.applyPendingEdits(noteID: session.noteID) > 0 {
                    cache[session.noteID] = nil
                }
            }
            if session.isUntouchedDraft { cache[session.noteID] = nil }
            session.pauseTask?.cancel()
        }
        if reason == .hide || reason == .quit {
            guard preserveAll() else { return false }
        }
        if reason == .pageSwitch || reason == .hide || reason == .quit || reason == .exitToOldPage {
            isPageVisible = false
        }
        return true
    }

    private func canLeaveComposition(in session: NoteSession) -> Bool {
        if session.engine.writingToolsBeganInView,
           let textView = session.engine.textView,
           textView.isWritingToolsActive,
           let coordinator = textView.writingToolsCoordinator {
            coordinator.stopWritingTools()
            if session.engine.activity == .writingToolsSafe || session.engine.activity == .writingToolsRefused {
                session.engine.writingToolsDidEnd()
            }
        }
        if session.engine.writingToolsBeganInView,
           session.engine.activity == .writingToolsSafe || session.engine.activity == .writingToolsRefused,
           session.engine.textView?.isWritingToolsActive == false {
            session.engine.writingToolsDidEnd()
        }
        guard NoteSessionPolicy.canLeave(session.engine.activity),
              session.engine.textView?.hasMarkedText() != true else {
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
        present()
    }

    /// The shell's flush (hide, quit, page switch): every session with
    /// unsaved text is saved or checkpointed. False only when some draft is
    /// in memory alone.
    @discardableResult
    func preserveAll() -> Bool {
        if let active, !canLeaveComposition(in: active) { return false }
        if let active { captureViewState(active) }
        var ok = true
        for session in cache.values where session.isDirty || session.problem != nil {
            ok = preserve(session) && ok
        }
        return ok
    }

    /// Save, else checkpoint, else keep in memory and say so.
    @discardableResult
    func preserve(_ session: NoteSession) -> Bool {
        session.saveTask?.cancel()
        if NoteSessionPolicy.dueSaveAction(session.state, activity: session.engine.activity) == .checkpointOnly {
            return checkpoint(session, silent: true)
        }
        guard session.isDirty || session.problem != nil else { return true }
        if save(session) { return true }
        guard let journal else {
            session.problem = .onlyInMemory(storeMessage())
            return false
        }
        do {
            let document = checkpointDocument(for: session)
            try journal.write(journalEntry(for: session, document: document),
                              staged: session.engine.stagedAttachments(for: document))
            if case .conflict = session.state {
                // Conflicted text stays a conflict while its recovery copy is updated.
            } else if !(session.engine.isWritingToolsSessionActive && session.engine.isWritingToolsBlocked) {
                session.problem = .notSaved(storeMessage())
            }
            return true
        } catch {
            session.problem = .onlyInMemory("\(storeMessage()) The recovery copy failed too: \(error.localizedDescription)")
            return false
        }
    }

    /// An activity can defer a store write without making the status say it failed.
    private func checkpoint(_ session: NoteSession, silent: Bool) -> Bool {
        guard let journal else {
            session.problem = .onlyInMemory(String(localized: "There is no recovery copy for this note."))
            return false
        }
        do {
            let document = checkpointDocument(for: session)
            try journal.write(journalEntry(for: session, document: document),
                              staged: session.engine.stagedAttachments(for: document))
            if !silent, session.problem == nil { session.problem = .notSaved(storeMessage()) }
            return true
        } catch {
            session.problem = .onlyInMemory("The recovery copy failed: \(error.localizedDescription)")
            return false
        }
    }

    private func storeMessage() -> String {
        store.lastErrorMessage ?? String(localized: "The note could not be saved.")
    }

    private func checkpointDocument(for session: NoteSession) -> NoteDocument {
        session.engine.checkpointDocument()
    }

    private func journalEntry(for session: NoteSession, document: NoteDocument) -> NoteDraftJournalEntry {
        let staged = session.engine.stagedAttachments(for: document)
        return NoteDraftJournalEntry(
            noteID: session.noteID,
            isPersisted: session.isPersisted,
            baseRevisionID: session.baseRevisionID,
            content: (try? NoteContentCodec.encode(document)) ?? Data(),
            selectionLocation: session.selection.location,
            selectionLength: session.selection.length,
            scrollOffset: Double(session.scrollOffset),
            staged: staged.map { .init(id: $0.id, filename: $0.filename, contentTypeIdentifier: $0.contentTypeIdentifier,
                                       byteCount: $0.byteCount, digest: $0.digest) },
            savedAt: now()
        )
    }

    // MARK: Saving

    /// All paths that replace a stored document or rekey a draft use this gate.
    private func canCommit(_ session: NoteSession, resolvingConflict: Bool = false) -> Bool {
        NoteSessionPolicy.canWriteStore(resolvingConflict ? .dirty : session.state,
            activity: session.engine.activity)
            && session.engine.textView?.hasMarkedText() != true
    }

    private func textDidChange(in session: NoteSession) {
        guard !session.isReadOnly else { return }
        if !session.isDirty { session.isDirty = true }
        session.editGeneration &+= 1
        session.lastEditAt = now()
        updateWritingToolsAvailability(for: session)
        scheduleSave(session)
    }

    private func scheduleSave(_ session: NoteSession) {
        session.saveTask?.cancel()
        let delay = saveDelay
        session.saveTask = Task { @MainActor [weak self, weak session] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, let session, !Task.isCancelled else { return }
            if NoteSessionPolicy.dueSaveAction(session.state, activity: session.engine.activity) == .checkpointOnly {
                _ = self.checkpoint(session, silent: true)
                return
            }
            let generation = session.editGeneration
            let noteID = session.noteID
            let document = session.engine.document()
            let staged = session.engine.stagedAttachments(for: document)
            let prepared = await self.prepareDocument(document)
            guard !Task.isCancelled, generation == session.editGeneration, noteID == session.noteID else { return }
            guard let prepared else { _ = self.preserve(session); return }
            if !self.save(session, snapshot: document, stagedSnapshot: staged, prepared: prepared) {
                _ = self.preserve(session)
            }
        }
    }

    /// Writes the session to the store now. A never-saved draft with no
    /// content is not written (and counts as saved).
    @discardableResult
    func save(_ session: NoteSession, snapshot: NoteDocument? = nil,
              stagedSnapshot: [StagedNoteAttachment]? = nil, prepared: PreparedNoteDocument? = nil) -> Bool {
        guard canCommit(session) else { return false }
        guard session.isDirty || session.problem != nil else { return true }
        guard !session.isReadOnly else { return true }
        let engine = session.engine
        let document = snapshot ?? engine.document()
        let staged = stagedSnapshot ?? engine.stagedAttachments(for: document)
        if !session.isPersisted {
            guard !document.isEmpty || !document.objectIDs.isEmpty else {
                session.isDirty = false
                session.problem = nil
                return true
            }
            switch store.createDocumentNote(id: session.noteID, document: document, staged: staged, prepared: prepared) {
            case let .success((noteID, revisionID)):
                if noteID != session.noteID {
                    session.recoverySourceID = session.noteID
                    cache[session.noteID] = nil
                    session.adopt(noteID: noteID)
                    cache[noteID] = session
                    touch(noteID)
                }
                session.isPersisted = true
                session.baseRevisionID = revisionID
                didSave(session, staged: staged)
                remember(noteID)
                return true
            case .failure(.staleRevision):
                session.problem = .changedElsewhere
                return false
            case .failure:
                return false
            }
        }
        switch store.saveDocument(noteID: session.noteID, document: document,
                                  baseRevisionID: session.baseRevisionID, staged: staged, prepared: prepared) {
        case let .success(revisionID):
            session.baseRevisionID = revisionID
            didSave(session, staged: staged)
            return true
        case .failure(.noteMissing):
            session.state = .conflict(.deleted)
            return false
        case .failure(.staleRevision):
            session.problem = .changedElsewhere
            return false
        case .failure:
            return false
        }
    }

    /// The explicit escape from a stale base. The original note is untouched.
    @discardableResult
    func keepAsNewNote() -> Bool {
        guard let session = active,
              NoteSessionPolicy.keepAsNewAllowed(session.state, activity: session.engine.activity,
                                                 hasBatch: session.isImporting),
              preserve(session) else { return false }
        let document = checkpointDocument(for: session)
        let notice = session.state == .conflict(.deleted)
            ? String(localized: "Your text was kept as a new note. The deleted note remains in Recently Deleted.")
            : String(localized: "Your text was kept as a new note. The changed note is still available.")
        return saveAsNewNote(session, document: document,
            staged: session.engine.stagedAttachments(for: document),
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
        guard case let .success((newID, revisionID)) = store.createDocumentNote(id: UUID(), document: replacement,
                                                                                  staged: images) else { return false }
        cache[oldID] = nil
        session.recoverySourceID = oldID
        session.adopt(noteID: newID)
        session.replaceEngine(makeEngine(noteID: newID, document: replacement, readOnly: false))
        wire(session)
        if active === session { active = session }
        cache[newID] = session
        touch(newID)
        session.baseRevisionID = revisionID
        session.notice = successNotice
        didSave(session, staged: images)
        remember(newID)
        return true
    }

    private func didSave(_ session: NoteSession, staged: [StagedNoteAttachment]) {
        captureViewState(session)
        session.isDirty = false
        if session.problem != nil { session.problem = nil }
        session.refusedWritingToolsSinceSave = false
        updateWritingToolsAvailability(for: session)
        session.engine.forgetStaged(Set(staged.map(\.id)))
        clearRecoveryCopy(noteID: session.noteID)
        if let source = session.recoverySourceID {
            clearRecoveryCopy(noteID: source)
            session.recoverySourceID = nil
        }
        schedulePauseVersion(session)
    }

    private func clearRecoveryCopy(noteID: UUID) {
        guard let journal else { return }
        do { try journal.remove(noteID: noteID) }
        catch {
            // A committed document replaces a stale checkpoint if removal
            // fails. Recovery compares content with the store and drops it.
            guard let stored = store.loadDocument(noteID: noteID),
                  let document = stored.content.document,
                  let content = try? NoteContentCodec.encode(document) else {
                active?.notice = String(localized: "Saved, but an old recovery copy could not be cleared.")
                return
            }
            let saved = NoteDraftJournalEntry(noteID: noteID, isPersisted: true,
                baseRevisionID: stored.revisionID, content: content,
                selectionLocation: 0, selectionLength: 0, staged: [], savedAt: now())
            do { try journal.write(saved, staged: []) }
            catch {
                active?.notice = String(localized: "Saved, but an old recovery copy could not be cleared.")
            }
        }
    }

    /// A version after 2 minutes without edits.
    private func schedulePauseVersion(_ session: NoteSession) {
        session.pauseTask?.cancel()
        let delay = pauseVersionDelay
        session.pauseTask = Task { @MainActor [weak self, weak session] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, let session, !Task.isCancelled, session.isPersisted, !session.isDirty else { return }
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
    func copyActiveText() {
        guard let active else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(active.engine.plainText, forType: .string)
    }

    // MARK: Recovery

    /// Materializes recovery drafts before agent access starts. Safe to call
    /// again from `start()` in tests that do not create an AppCoordinator.
    func recoverAtLaunch() {
        guard !didRecoverAtLaunch else { return }
        didRecoverAtLaunch = true
        guard let journal else { return }
        let entries: [NoteDraftRecoveryEntry]
        do { entries = try journal.recoveryEntries() }
        catch {
            recoveryWarnings.append("Recovery copies could not be listed: \(error.localizedDescription)")
            return
        }
        for item in entries {
            guard case let .valid(entry, staged) = item else {
                if case let .damaged(message) = item { recoveryWarnings.append(message) }
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
            if stored?.content.document == document {
                try? journal.remove(noteID: entry.noteID)
                continue
            }
            let available = Set(staged.map(\.id))
                .union(((try? store.attachmentRows(forNoteID: entry.noteID)) ?? []).map(\.id))
            guard Set(document.attachmentIDs).isSubset(of: available) else {
                recoveryWarnings.append("Recovery copy for \(entry.noteID.uuidString) refers to an image that is missing from both the checkpoint and the note store.")
                continue
            }
            let session = NoteSession(noteID: entry.noteID,
                isPersisted: stored != nil || entry.baseRevisionID != nil || !replicas.isEmpty,
                baseRevisionID: entry.baseRevisionID,
                engine: makeEngine(noteID: entry.noteID, document: document, readOnly: false, staged: staged),
                readOnlyReason: nil)
            wire(session)
            session.selection = NSRange(location: entry.selectionLocation, length: entry.selectionLength)
            session.scrollOffset = CGFloat(entry.scrollOffset ?? 0)
            let deleted = stored == nil && (entry.baseRevisionID != nil || replicas.contains { $0.deletedAt != nil })
            if deleted {
                session.state = .conflict(.deleted)
            } else if (entry.baseRevisionID == nil && !replicas.isEmpty)
                        || (entry.baseRevisionID != nil && stored?.revisionID != entry.baseRevisionID) {
                session.state = .conflict(.changed)
            } else {
                session.state = .dirty
                if !save(session), !session.isConflict {
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
            if case let .valid(entry, _) = item { return entry.noteID }
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
        let stored = (try? store.attachmentRows(forNoteID: oldID)) ?? []
        for index in replacement.blocks.indices where replacement.blocks[index].kind == .image {
            guard let oldAttachmentID = replacement.blocks[index].attachmentID else { return nil }
            let newID: UUID
            if let existing = mapping[oldAttachmentID] {
                newID = existing
            } else {
                guard let source = staged.first(where: { $0.id == oldAttachmentID })
                    ?? stored.first(where: { $0.id == oldAttachmentID }).flatMap({ row in
                        row.payload.map { data in
                            StagedNoteAttachment(id: row.id, filename: row.originalFilename,
                                                 contentTypeIdentifier: row.contentTypeIdentifier,
                                                 byteCount: Int64(data.count),
                                                 digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), data: data)
                        }
                    }) else { return nil }
                guard validImagePayload(source) else { return nil }
                newID = UUID()
                mapping[oldAttachmentID] = newID
                copied.append(StagedNoteAttachment(id: newID, filename: source.filename,
                                                   contentTypeIdentifier: source.contentTypeIdentifier,
                                                   byteCount: source.byteCount, digest: source.digest, data: source.data))
            }
            replacement.blocks[index].attachmentID = newID
            replacement.blocks[index].id = UUID()
        }
        return (replacement, copied)
    }

    private func validImagePayload(_ item: StagedNoteAttachment) -> Bool {
        item.byteCount > 0 && item.byteCount <= AttachmentLimits.maxBytesPerAttachment
            && item.byteCount == Int64(item.data.count)
            && item.digest == SHA256.hash(data: item.data).map { String(format: "%02x", $0) }.joined()
            && UTType(item.contentTypeIdentifier)?.conforms(to: .image) == true
            && NoteImageDecoder.pixelSize(of: item.data) != nil
    }

    // MARK: Look and images

    func update(design: AtticDesignContext) {
        guard design != self.design else { return }
        self.design = design
        for session in cache.values { session.engine.update(design: design) }
    }

    /// Reads every file before making one undoable document change.
    func importImages(_ urls: [URL]) {
        guard let session = active, !session.isReadOnly, !urls.isEmpty else { return }
        guard NoteSessionPolicy.commandAllowed(session.engine.activity) else {
            session.notice = String(localized: "Finish Writing Tools or composing text before adding images.")
            return
        }
        guard session.importBatch == nil else {
            session.notice = String(localized: "Finish the current image import before adding more images.")
            return
        }
        let batchID = UUID()
        session.engine.beginImageImport()
        session.importBatch = NoteImportBatch(id: batchID, urls: urls)
        let loader = imageLoader
        session.importTask = Task { @MainActor [weak self, session] in
            guard let self else { return }
            var loaded: [(StagedNoteAttachment, CGSize?)] = []
            for url in urls {
                guard !Task.isCancelled, let (item, pixelSize) = await loader(url) else {
                    if !Task.isCancelled {
                        self.dropImport(in: session, batchID: batchID,
                            notice: String(localized: "The image batch could not be read, so none of its images were added."))
                    }
                    return
                }
                loaded.append((StagedNoteAttachment(id: UUID(), filename: item.filename,
                    contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount,
                    digest: item.digest, data: item.data), pixelSize))
            }
            guard !Task.isCancelled, var batch = session.importBatch, batch.id == batchID else { return }
            batch.loaded = loaded
            session.importBatch = batch
            session.importTask = nil
            self.completeImportIfPossible(in: session)
        }
    }

    private func completeImportIfPossible(in session: NoteSession) {
        guard let batch = session.importBatch, let loaded = batch.loaded else { return }
        guard session.engine.activity == .idle else { return }
        if session.isPersisted && store.note(withID: session.noteID) == nil {
            session.state = .conflict(.deleted)
            _ = checkpoint(session, silent: true)
        }
        switch NoteSessionPolicy.importCompletion(session.state, activity: session.engine.activity) {
        case .deferUntilIdle:
            return
        case .drop:
            dropImport(in: session, batchID: batch.id,
                notice: String(localized: "The note was deleted or is read only, so the images were not added."))
        case .insert:
            session.importBatch = nil
            session.importTask = nil
            guard session.engine.insertImportedImages(loaded) else {
                session.notice = String(localized: "The images could not be added to this note.")
                return
            }
            _ = preserve(session)
        }
    }

    func cancelActiveImport() {
        guard let session = active, let batch = session.importBatch else { return }
        dropImport(in: session, batchID: batch.id,
            notice: String(localized: "The image import was cancelled."))
    }

    private func dropImport(in session: NoteSession, batchID: UUID, notice: String) {
        guard session.importBatch?.id == batchID else { return }
        session.importTask?.cancel()
        session.importTask = nil
        session.importBatch = nil
        session.engine.cancelImageImport()
        session.notice = notice
    }

    nonisolated private static func loadImageFile(_ url: URL) async -> (StagedNoteAttachment, CGSize?)? {
        await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), !data.isEmpty,
                  Int64(data.count) <= AttachmentLimits.maxBytesPerAttachment,
                  let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                  let pixelSize = NoteImageDecoder.pixelSize(of: data) else { return nil }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return (StagedNoteAttachment(id: UUID(), filename: url.lastPathComponent,
                                         contentTypeIdentifier: type.identifier, byteCount: Int64(data.count),
                                         digest: digest, data: data), pixelSize)
        }.value
    }
}

extension NotesPageController: NoteImageProviding {
    func fileURL(forAttachment id: UUID) async -> URL? {
        guard let row = attachmentRow(id) else { return nil }
        return await store.materializedURL(for: row)
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
        guard let row = attachmentRow(id), let data = row.payload else { return nil }
        let item = StagedNoteAttachment(id: row.id, filename: row.originalFilename, contentTypeIdentifier: row.contentTypeIdentifier,
                                    byteCount: Int64(data.count),
                                    digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), data: data)
        return validImagePayload(item) ? item : nil
    }

    private func attachmentRow(_ id: UUID) -> NoteAttachment? {
        store.attachmentsByNoteID.values.lazy.flatMap { $0 }.first { $0.id == id }
    }
}

/// The decisions shared by autosave, navigation, imports and agent writes.
/// Inputs are values so the policy can be tested without a store or a view.
enum NoteSessionPolicy {
    enum DueSaveAction: Equatable { case preserve, checkpointOnly }
    enum Presence: Equatable { case onScreen, background, released }
    enum AgentDisposition: Equatable { case proposal, direct, flush, refuseImport }
    enum ImportCompletion: Equatable { case insert, deferUntilIdle, drop }

    static func canWriteStore(_ state: NoteSession.State, activity: NoteEditorEngine.Activity) -> Bool {
        guard activity == .idle else { return false }
        switch state {
        case .conflict, .readOnly: return false
        default: return true
        }
    }

    static func dueSaveAction(_ state: NoteSession.State, activity: NoteEditorEngine.Activity) -> DueSaveAction {
        guard activity == .idle else { return .checkpointOnly }
        if case .conflict = state { return .checkpointOnly }
        return .preserve
    }

    static func canLeave(_ activity: NoteEditorEngine.Activity) -> Bool { activity == .idle }
    static func commandAllowed(_ activity: NoteEditorEngine.Activity) -> Bool { activity == .idle }

    static func canEvict(_ state: NoteSession.State, activity: NoteEditorEngine.Activity,
                         hasBatch: Bool, presence: Presence) -> Bool {
        guard activity == .idle, !hasBatch, presence != .onScreen else { return false }
        switch state {
        case .untouched, .clean, .readOnly: return true
        default: return false
        }
    }

    static func writingToolsAvailable(_ state: NoteSession.State, activity: NoteEditorEngine.Activity,
                                      refusedSinceLastStoreSave: Bool) -> Bool {
        guard activity == .idle, !refusedSinceLastStoreSave else { return false }
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

    static func keepAsNewAllowed(_ state: NoteSession.State, activity: NoteEditorEngine.Activity,
                                 hasBatch: Bool) -> Bool {
        guard activity == .idle, !hasBatch else { return false }
        if case .conflict = state { return true }
        return false
    }
}
