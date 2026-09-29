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
    /// The tags the store holds for this note (as loaded or last saved). A
    /// save writes the engine's tags only when they differ.
    fileprivate(set) var baseTags: [String] = []
    @Published private(set) var engine: NoteEditorEngine
    let readOnlyReason: NoteReadOnlyReason?
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
    private let pauseVersionDelay: Duration
    private let now: () -> Date
    let imageLoader: @Sendable (URL) async -> (StagedNoteAttachment, CGSize?)?
    private let prepareDocument: @Sendable (NoteDocument) async -> PreparedNoteDocument?
    private var cache: [UUID: NoteSession] = [:]
    private var recency: [UUID] = []
    private var proposalStatusCache: [UUID: (revision: UInt64, agent: String?)] = [:]
    private let cacheLimit = 8
    private var didStart = false
    private var didRecoverAtLaunch = false
    private var newestRecovered: NoteSession?
    private var isPageVisible = false
    /// New Note from the menu bar before the page first appeared: honoured
    /// by `start()` (after a recovered draft, which always opens first).
    private var pendingNewNote = false
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
        attachUndoRoute(undoRoute)
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
        let agent = store.pendingEdits(noteID: session.noteID).first.map {
            $0.agentName.isEmpty ? String(localized: "Agent") : $0.agentName
        }
        proposalStatusCache[session.noteID] = (store.revision, agent)
        return agent
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
        guard session.baseRevisionID != note.revisionID else {
            // Tags set elsewhere (an agent, another page) move no revision.
            if note.tags != session.baseTags, session.engine.tags == session.baseTags {
                session.baseTags = note.tags
                session.engine.setTags(note.tags)
            }
            return session
        }
        cache[session.noteID] = nil
        session.engine.detachView()
        return self.session(for: note)
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
        engine.imageProvider = self
        engine.onTextChange = { [weak self, weak session] in
            guard let self, let session else { return }
            self.textDidChange(in: session)
        }
        engine.onActivityChanged = { [weak self, weak session] old, new in
            guard let self, let session else { return }
            if old != .idle && new == .idle {
                self.completeImportIfPossible(in: session)
                if NoteSessionPolicy.hasPendingWork(session.state) {
                    _ = self.preserve(session)
                } else {
                    self.clearRecoveryCopy(noteID: session.noteID)
                }
            }
            self.updateWritingToolsAvailability(for: session)
        }
        engine.onNotice = { [weak session] message in session?.notice = message }
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
        }
        if reason == .hide || reason == .quit {
            guard preserveAll() else { return false }
        }
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
    func preserveAll() -> Bool {
        if let active { captureViewState(active) }
        var ok = true
        for session in cache.values where NoteSessionPolicy.hasPendingWork(session.state) {
            ok = preserve(session) && ok
        }
        return ok
    }

    /// Save, else checkpoint, else keep in memory and say so.
    @discardableResult
    func preserve(_ session: NoteSession) -> Bool {
        session.saveTask?.cancel()
        session.engine.refreshCompositionActivity()
        if NoteSessionPolicy.dueSaveAction(session.state, activity: session.engine.activity,
                hasMarkedText: session.engine.textView?.hasMarkedText() == true) == .checkpointOnly {
            return checkpoint(session, silent: true)
        }
        guard NoteSessionPolicy.hasPendingWork(session.state) else { return true }
        if save(session) { return true }
        guard let journal else {
            session.state = .onlyInMemory(storeMessage())
            return false
        }
        do {
            let document = checkpointDocument(for: session)
            try journal.write(journalEntry(for: session, document: document),
                              staged: session.engine.stagedAttachments(for: document))
            if case .conflict = session.state {
                // Conflicted text stays a conflict while its recovery copy is updated.
            } else if !(session.engine.isWritingToolsSessionActive && session.engine.isWritingToolsBlocked) {
                session.state = .notSaved(storeMessage())
            }
            return true
        } catch {
            session.state = .onlyInMemory("\(storeMessage()) The recovery copy failed too: \(error.localizedDescription)")
            return false
        }
    }

    /// An activity can defer a store write without making the status say it failed.
    private func checkpoint(_ session: NoteSession, silent: Bool) -> Bool {
        guard let journal else {
            session.state = .onlyInMemory(String(localized: "There is no recovery copy for this note."))
            return false
        }
        do {
            let document = checkpointDocument(for: session)
            try journal.write(journalEntry(for: session, document: document),
                              staged: session.engine.stagedAttachments(for: document))
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
            savedAt: now(),
            tags: session.engine.tags,
            tagsChanged: session.isPersisted ? session.pendingTags != nil : !session.engine.tags.isEmpty
        )
    }

    // MARK: Saving

    /// All paths that replace a stored document or rekey a draft use this gate.
    private func canCommit(_ session: NoteSession, resolvingConflict: Bool = false) -> Bool {
        NoteSessionPolicy.canWriteStore(resolvingConflict ? .dirty : session.state,
            activity: session.engine.activity,
            hasMarkedText: session.engine.textView?.hasMarkedText() == true)
    }

    private func textDidChange(in session: NoteSession) {
        guard !session.isReadOnly else { return }
        if !NoteSessionPolicy.hasPendingWork(session.state) { session.state = .dirty }
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
            await self.runDueSave(session)
        }
    }

    /// The timer body is separate so the lifecycle matrix can fire it without
    /// wall-clock waits; production still waits for the coalescing delay.
    func runDueSave(_ session: NoteSession) async {
        session.engine.refreshCompositionActivity()
        if NoteSessionPolicy.dueSaveAction(session.state, activity: session.engine.activity,
                hasMarkedText: session.engine.textView?.hasMarkedText() == true) == .checkpointOnly {
            _ = checkpoint(session, silent: true)
            return
        }
        let generation = session.editGeneration
        let noteID = session.noteID
        let document = session.engine.document()
        let staged = session.engine.stagedAttachments(for: document)
        let prepared = await prepareDocument(document)
        guard !Task.isCancelled, generation == session.editGeneration, noteID == session.noteID else { return }
        guard let prepared else { _ = preserve(session); return }
        if !save(session, snapshot: document, stagedSnapshot: staged, prepared: prepared) {
            _ = preserve(session)
        }
    }

    /// Writes the session to the store now. A never-saved draft with no
    /// content is not written (and counts as saved).
    @discardableResult
    func save(_ session: NoteSession, snapshot: NoteDocument? = nil,
              stagedSnapshot: [StagedNoteAttachment]? = nil, prepared: PreparedNoteDocument? = nil) -> Bool {
        guard canCommit(session) else { return false }
        guard NoteSessionPolicy.hasPendingWork(session.state) else { return true }
        guard !session.isReadOnly else { return true }
        let engine = session.engine
        let document = snapshot ?? engine.document()
        let staged = stagedSnapshot ?? engine.stagedAttachments(for: document)
        let tags = session.engine.tags
        if !session.isPersisted {
            guard !document.isEmpty || !document.objectIDs.isEmpty || !tags.isEmpty else {
                session.state = .untouched
                return true
            }
            switch store.createDocumentNote(id: session.noteID, document: document, staged: staged,
                                            prepared: prepared, tags: tags.isEmpty ? nil : tags) {
            case let .success((noteID, revisionID)):
                session.isPersisted = true
                session.baseRevisionID = revisionID
                session.baseTags = tags
                didSave(session, staged: staged)
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
        let pendingTags = session.pendingTags
        switch store.saveDocument(noteID: session.noteID, document: document,
                                  baseRevisionID: session.baseRevisionID, staged: staged, prepared: prepared,
                                  tags: pendingTags) {
        case let .success(revisionID):
            session.baseRevisionID = revisionID
            if let pendingTags { session.baseTags = pendingTags }
            didSave(session, staged: staged)
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
    func keepAsNewNote() -> Bool {
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
        let tags = session.engine.tags
        guard case let .success((newID, revisionID)) = store.createDocumentNote(id: UUID(), document: replacement,
                                                                                  staged: images,
                                                                                  tags: tags.isEmpty ? nil : tags) else {
            session.notice = String(localized: "Couldn’t save a new note; your text is still in recovery.")
            return false
        }
        cache[oldID] = nil
        session.adopt(noteID: newID)
        session.replaceEngine(makeEngine(noteID: newID, document: replacement, readOnly: false, tags: tags))
        session.baseTags = tags
        wire(session)
        if active === session { active = session }
        cache[newID] = session
        touch(newID)
        session.baseRevisionID = revisionID
        session.notice = successNotice
        didSave(session, staged: images, clearOldCheckpoint: oldID)
        remember(newID)
        return true
    }

    private func didSave(_ session: NoteSession, staged: [StagedNoteAttachment],
                         clearOldCheckpoint oldID: UUID? = nil) {
        captureViewState(session)
        session.state = .clean
        session.refusedWritingToolsSinceSave = false
        updateWritingToolsAvailability(for: session)
        session.engine.forgetStaged(Set(staged.map(\.id)))
        clearRecoveryCopy(noteID: session.noteID)
        if let oldID { clearRecoveryCopy(noteID: oldID) }
        schedulePauseVersion(session)
    }

    private func clearRecoveryCopy(noteID: UUID) {
        if !retireRecoveryCopy(noteID: noteID) {
            active?.notice = String(localized: "Saved, but an old recovery copy could not be cleared.")
        }
    }

    /// Removes a note's recovery copy, or, if removal fails, writes the
    /// stored state over it (recovery drops a copy that matches its note,
    /// live or deleted). False only when neither worked, so a stale copy
    /// is still there.
    fileprivate func retireRecoveryCopy(noteID: UUID) -> Bool {
        guard let journal else { return true }
        do {
            try journal.remove(noteID: noteID)
            return true
        } catch {
            guard let stored = store.loadDocument(noteID: noteID),
                  let document = stored.content.document,
                  let content = try? NoteContentCodec.encode(document) else { return false }
            let saved = NoteDraftJournalEntry(noteID: noteID, isPersisted: true,
                baseRevisionID: stored.revisionID, content: content,
                selectionLocation: 0, selectionLength: 0, staged: [], savedAt: now(),
                tags: store.note(withID: noteID)?.tags ?? [], tagsChanged: false)
            do {
                try journal.write(saved, staged: [])
                return true
            } catch {
                return false
            }
        }
    }

    /// A version after 2 minutes without edits.
    private func schedulePauseVersion(_ session: NoteSession) {
        session.pauseTask?.cancel()
        let delay = pauseVersionDelay
        session.pauseTask = Task { @MainActor [weak self, weak session] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, let session, !Task.isCancelled, session.isPersisted,
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
    func copyActiveText() {
        guard let active else { return }
        let pasteboard = NSPasteboard.general
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
            let snapshot = try recoverySnapshot(of: session)
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

    private func recoverySnapshot(of session: NoteSession) throws -> NoteRecoverySnapshot {
        let document = session.engine.document()
        var attachments = session.engine.stagedAttachments(for: document)
        var unavailable: [UUID] = []
        var seen = Set(attachments.map(\.id))
        for id in document.attachmentIDs where !seen.contains(id) {
            seen.insert(id)
            if let stored = imageBytes(forAttachment: id) { attachments.append(stored) } else { unavailable.append(id) }
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
            noteID: session.noteID, title: NoteStore.normalizedTitle(document.title), content: content,
            markdown: NoteMarkdownExport.markdown(document) { names[$0] },
            tags: session.engine.tags, reason: reason, savedAt: now(),
            attachments: attachments, unavailableAttachmentIDs: unavailable)
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
                try? journal.remove(noteID: entry.noteID)
                continue
            }
            let storedTags = store.note(withID: entry.noteID)?.tags ?? []
            if stored?.content.document == document, entry.changedTags == nil || entry.changedTags == storedTags {
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
                engine: makeEngine(noteID: entry.noteID, document: document, readOnly: false, staged: staged,
                                   tags: entry.tags ?? storedTags),
                readOnlyReason: nil)
            // Unchanged tags stay the stored ones' business (nothing is written
            // over them), yet the draft keeps them, even if its note is gone.
            session.baseTags = entry.changedTags == nil ? (entry.tags ?? storedTags) : storedTags
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
        guard NoteSessionPolicy.commandAllowed(session.engine.activity,
                hasMarkedText: session.engine.textView?.hasMarkedText() == true) else {
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
            if NoteSessionPolicy.hasPendingWork(session.state) {
                session.state = .conflict(.deleted)
                _ = checkpoint(session, silent: true)
            } else {
                dropImport(in: session, batchID: batch.id,
                    notice: String(localized: "The note was deleted or is read only, so the images were not added."))
                return
            }
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
        // can't be removed is replaced by the saved state; if neither works,
        // nothing is deleted (the copy would come back as a conflict).
        guard retireRecoveryCopy(noteID: noteID) else {
            let message = String(localized: "An old recovery copy of this note couldn’t be cleared, so the note was not deleted. Try again.")
            if let session { session.notice = message } else { active?.notice = message }
            return false
        }
        if let session {
            session.saveTask?.cancel()
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
        let before = store.note(withID: noteID)?.isPinned
        guard applyPinned(pinned, noteID: noteID) else { return false }
        // A pin that changed nothing is not a step.
        if let before, before != pinned {
            undoRoute.record(pinStep(pinned, noteID: noteID), in: .notesLibrary)
        }
        return true
    }

    private func applyPinned(_ pinned: Bool, noteID: UUID) -> Bool {
        if let session = cache[noteID], !session.isPersisted {
            guard preserve(session), session.isPersisted else { return false }
        }
        return store.setPinned(pinned, noteID: noteID)
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
        guard let note = store.note(withID: noteID) else { return .obsolete }
        if note.isPinned == pinned { return .applied }
        return applyPinned(pinned, noteID: noteID) ? .applied : .failed
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
            document = session.engine.document()
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
