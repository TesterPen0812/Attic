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
}

private struct DamagedNoteRecovery: Error {}

/// One open note: its engine (text, undo, staged images) and where it
/// stands against the store. Lives outside any view.
@MainActor
final class NoteSession: ObservableObject, Identifiable {
    nonisolated let id = UUID()
    /// The note's id (a new note's reserved id until its first save).
    @Published private(set) var noteID: UUID
    @Published fileprivate(set) var isPersisted: Bool
    fileprivate(set) var baseRevisionID: UUID?
    @Published private(set) var engine: NoteEditorEngine
    let readOnlyReason: NoteReadOnlyReason?
    @Published fileprivate(set) var isDirty = false
    fileprivate var editGeneration: UInt64 = 0
    @Published fileprivate(set) var problem: NoteSaveProblem?
    /// Information for the slot (lowest priority), such as a refused change.
    @Published var notice: String?
    fileprivate(set) var lastEditAt: Date?
    fileprivate(set) var selection = NSRange(location: 0, length: 0)
    fileprivate(set) var scrollOffset: CGFloat = 0
    fileprivate var recoverySourceID: UUID?
    fileprivate var pendingImportIDs = Set<UUID>()
    fileprivate var importTask: Task<Void, Never>?
    fileprivate var blocksAutomaticRekey = false

    fileprivate init(noteID: UUID, isPersisted: Bool, baseRevisionID: UUID?, engine: NoteEditorEngine,
                     readOnlyReason: NoteReadOnlyReason?) {
        self.noteID = noteID
        self.isPersisted = isPersisted
        self.baseRevisionID = baseRevisionID
        self.engine = engine
        self.readOnlyReason = readOnlyReason
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

    /// Untouched: never saved, no text, no objects.
    var isUntouchedDraft: Bool {
        !isPersisted && pendingImportIDs.isEmpty && engine.document().isEmpty && engine.objectIDs().isEmpty
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
    private let cacheLimit = 8
    private var saveTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var didStart = false
    private var isPageVisible = false
    /// Saves and closes the old editor's draft before the page moves on
    /// from a legacy note (set by `NoteDraftController`).
    var leaveLegacyNote: () -> Bool = { true }
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
        store.openDocumentNoteIDs = { [weak self] in
            guard let self, self.isPageVisible, !self.isLibraryPresented,
                  let active = self.active, active.isPersisted else { return [] }
            return [active.noteID]
        }
        store.recoveryReferencedAttachmentIDs = { [weak self] in
            guard let self, let journal = self.journal else { return [] }
            var ids = Set<UUID>()
            for item in try journal.recoveryEntries() {
                guard case let .valid(entry, _) = item,
                      let document = NoteContentCodec.decode(entry.content).document else {
                    throw DamagedNoteRecovery()
                }
                ids.formUnion(document.attachmentIDs)
                ids.formUnion(entry.staged.map(\.id))
            }
            return ids
        }
    }

    var lastViewedNoteID: UUID? {
        defaults?.string(forKey: Self.lastViewedKey).flatMap(UUID.init(uuidString:))
    }

    /// Failed sessions are listed even when no note row was ever committed.
    var failedDrafts: [NoteSession] {
        recency.reversed().compactMap { cache[$0] }.filter { $0.problem != nil }
    }

    @discardableResult
    func openFailedDraft(sessionID: UUID) -> Bool {
        guard let draft = cache.values.first(where: { $0.id == sessionID }) else { return false }
        if active !== draft { guard leaveActive() else { return false } }
        legacyNoteID = nil
        activate(draft)
        isLibraryPresented = false
        return true
    }

    // MARK: Opening

    /// Recovery first, then the last note viewed, else a new draft.
    func start() {
        guard !didStart else { return }
        didStart = true
        isPageVisible = true
        if let recovered = recoverDrafts() {
            activate(recovered)
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
        if let active, active.noteID == noteID, legacyNoteID == nil { return true }
        guard let note = store.note(withID: noteID) else { return false }
        guard leaveActive() else { return false }
        if !note.usesDocumentFormat {
            active = nil
            legacyNoteID = noteID
            remember(noteID)
            return true
        }
        legacyNoteID = nil
        guard let session = session(for: note) else { return false }
        activate(session)
        return true
    }

    /// A new draft; the current one is preserved first.
    @discardableResult
    func newNote() -> Bool {
        if let active, active.isUntouchedDraft, legacyNoteID == nil { return true }
        guard leaveActive() else { return false }
        legacyNoteID = nil
        let id = UUID()
        let session = NoteSession(noteID: id, isPersisted: false, baseRevisionID: nil,
                                  engine: makeEngine(noteID: id, document: .blank, readOnly: false),
                                  readOnlyReason: nil)
        activate(session)
        return true
    }

    private func session(for note: NoteItem) -> NoteSession? {
        if let cached = cache[note.id] {
            // A clean cached session whose note moved on (an agent's edit
            // applied, a restore) is rebuilt from the store.
            if cached.isDirty || cached.problem != nil || cached.baseRevisionID == note.revisionID { return cached }
            cache[note.id] = nil
        }
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

    private func wire(_ session: NoteSession) {
        let engine = session.engine
        engine.imageProvider = self
        engine.onTextChange = { [weak self, weak session] in
            guard let self, let session else { return }
            self.textDidChange(in: session)
        }
        engine.onNotice = { [weak session] message in session?.notice = message }
        engine.onBeforeCopy = { [weak self, weak session] in
            guard let self, let session else { return }
            _ = self.save(session)
        }
        engine.onWritingToolsWillBegin = { [weak self, weak session] in
            guard let self, let session else { return false }
            // What the note holds before a rewrite is kept as a version.
            return self.save(session) && session.isPersisted
                && self.store.recordVersion(noteID: session.noteID, reason: .beforeWritingTools)
        }
        engine.onSelectionChange = { [weak session] range in session?.selection = range }
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
            return !session.isDirty && session.problem == nil && session !== active
        }) {
            recency.removeAll { $0 == evict }
            cache[evict]?.engine.detachView()
            cache[evict] = nil
        }
    }

    // MARK: Leaving

    /// Preserves the active draft, then runs the "leave" rules: a version
    /// of the note as left, and any pending agent edit whose base still
    /// matches applies. Returns false (and keeps the session) when the draft
    /// could not be preserved anywhere.
    private func leaveActive(closeLegacy: Bool = true) -> Bool {
        if closeLegacy, legacyNoteID != nil {
            guard leaveLegacyNote() else { return false }
        }
        guard let session = active else { return true }
        guard canLeaveComposition(in: session) else { return false }
        captureViewState(session)
        cancelImport(in: session)
        guard preserve(session) else { return false }
        if session.isPersisted, !session.isDirty {
            store.recordVersion(noteID: session.noteID, reason: .leave)
            if store.applyPendingEdits(noteID: session.noteID) > 0 {
                cache[session.noteID]?.engine.detachView()
                cache[session.noteID] = nil
            }
        }
        if session.isUntouchedDraft { cache[session.noteID] = nil }
        pauseTask?.cancel()
        return true
    }

    /// Shell adapter for page switch, hide and quit. The legacy controller
    /// has already flushed before calling this method.
    func leaveForNavigation() -> Bool {
        if let active, !canLeaveComposition(in: active) { return false }
        guard preserveAll(), leaveActive(closeLegacy: false) else { return false }
        isPageVisible = false
        return true
    }

    private func canLeaveComposition(in session: NoteSession) -> Bool {
        guard session.engine.textView?.hasMarkedText() != true else {
            session.notice = String(localized: "Finish composing text before leaving this note.")
            return false
        }
        return true
    }

    func showLibrary() -> Bool {
        guard leaveActive() else { return false }
        isLibraryPresented = true
        return true
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
        saveTask?.cancel()
        guard session.isDirty || session.problem != nil else { return true }
        if session.pendingImportIDs.isEmpty && save(session) { return true }
        guard let journal else {
            session.problem = .onlyInMemory(storeMessage())
            return false
        }
        do {
            let document = checkpointDocument(for: session)
            try journal.write(journalEntry(for: session, document: document),
                              staged: session.engine.stagedAttachments(for: document))
            session.problem = .notSaved(storeMessage())
            return true
        } catch {
            session.problem = .onlyInMemory("\(storeMessage()) The recovery copy failed too: \(error.localizedDescription)")
            return false
        }
    }

    private func storeMessage() -> String {
        store.lastErrorMessage ?? String(localized: "The note could not be saved.")
    }

    private func checkpointDocument(for session: NoteSession) -> NoteDocument {
        var document = session.engine.document()
        document.blocks.removeAll { $0.kind == .image && $0.attachmentID.map(session.pendingImportIDs.contains) == true }
        if document.blocks.isEmpty { document.blocks = [.text("")] }
        return document
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

    private func textDidChange(in session: NoteSession) {
        guard !session.isReadOnly else { return }
        session.isDirty = true
        session.editGeneration &+= 1
        session.lastEditAt = now()
        scheduleSave(session)
    }

    private func scheduleSave(_ session: NoteSession) {
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { @MainActor [weak self, weak session] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, let session, !Task.isCancelled else { return }
            guard session.pendingImportIDs.isEmpty else { _ = self.preserve(session); return }
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
        guard session.isDirty || session.problem != nil else { return true }
        guard !session.isReadOnly else { return true }
        guard session.pendingImportIDs.isEmpty else { return false }
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
            guard !session.blocksAutomaticRekey else { return false }
            // The deleted row can own images that the draft already saved.
            // Copy those bytes with new IDs in the replacement transaction.
            let oldID = session.noteID
            guard let (replacement, images) = replacementForDeletedNote(document, oldID: oldID, staged: staged) else {
                session.notice = String(localized: "The note was deleted elsewhere. Its images are unavailable, so this draft remains in recovery until they can be restored.")
                return false
            }
            switch store.createDocumentNote(id: UUID(), document: replacement, staged: images) {
            case let .success((newID, revisionID)):
                cache[oldID] = nil
                session.recoverySourceID = oldID
                session.adopt(noteID: newID)
                session.replaceEngine(makeEngine(noteID: newID, document: replacement, readOnly: false))
                wire(session)
                if active === session { active = session }
                cache[newID] = session
                touch(newID)
                session.baseRevisionID = revisionID
                session.notice = String(localized: "The note was deleted elsewhere, so your text was kept as a new note.")
                didSave(session, staged: images)
                remember(newID)
                return true
            case .failure:
                return false
            }
        case .failure:
            return false
        }
    }

    private func didSave(_ session: NoteSession, staged: [StagedNoteAttachment]) {
        captureViewState(session)
        session.isDirty = false
        if session.problem != nil { session.problem = nil }
        session.engine.forgetStaged(Set(staged.map(\.id)))
        try? journal?.remove(noteID: session.noteID)
        if let source = session.recoverySourceID {
            try? journal?.remove(noteID: source)
            session.recoverySourceID = nil
        }
        schedulePauseVersion(session)
    }

    /// A version after 2 minutes without edits.
    private func schedulePauseVersion(_ session: NoteSession) {
        pauseTask?.cancel()
        let delay = pauseVersionDelay
        pauseTask = Task { @MainActor [weak self, weak session] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, let session, !Task.isCancelled, session.isPersisted, !session.isDirty else { return }
            self.store.recordVersion(noteID: session.noteID, reason: .pause)
        }
    }

    /// Retry from the slot.
    func retry() {
        guard let active else { return }
        active.blocksAutomaticRekey = false
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

    /// Saves every checkpointed draft back to the store. Returns the session
    /// to open first: the newest recovered draft.
    private func recoverDrafts() -> NoteSession? {
        guard let journal else { return nil }
        let entries: [NoteDraftRecoveryEntry]
        do { entries = try journal.recoveryEntries() }
        catch {
            recoveryWarnings.append("Recovery copies could not be listed: \(error.localizedDescription)")
            return nil
        }
        var newest: NoteSession?
        for item in entries {
            guard case let .valid(entry, staged) = item else {
                if case let .damaged(message) = item { recoveryWarnings.append(message) }
                continue
            }
            guard case let .editable(document) = NoteContentCodec.decode(entry.content) else {
                recoveryWarnings.append("Recovery copy for \(entry.noteID.uuidString) contains unreadable note content.")
                continue
            }
            let available = Set(staged.map(\.id))
                .union(((try? store.attachmentRows(forNoteID: entry.noteID)) ?? []).map(\.id))
            guard Set(document.attachmentIDs).isSubset(of: available) else {
                recoveryWarnings.append("Recovery copy for \(entry.noteID.uuidString) refers to an image that is missing from both the checkpoint and the note store.")
                continue
            }
            let session = NoteSession(noteID: entry.noteID, isPersisted: entry.isPersisted,
                                      baseRevisionID: entry.baseRevisionID,
                                      engine: makeEngine(noteID: entry.noteID, document: document, readOnly: false, staged: staged),
                                      readOnlyReason: nil)
            wire(session)
            session.isDirty = true
            session.selection = NSRange(location: entry.selectionLocation, length: entry.selectionLength)
            session.scrollOffset = CGFloat(entry.scrollOffset ?? 0)
            if !save(session) {
                session.problem = .notSaved(storeMessage())
            }
            session.notice = String(localized: "Restored unsaved text.")
            cache[session.noteID] = session
            touch(session.noteID)
            newest = session
        }
        if !recoveryWarnings.isEmpty { newest?.notice = recoveryWarnings.joined(separator: " ") }
        return newest
    }

    private func captureViewState(_ session: NoteSession) {
        if let scroll = session.engine.scrollView {
            session.scrollOffset = max(0, scroll.contentView.bounds.origin.y)
        }
        defaults?.set(["location": session.selection.location,
                       "length": session.selection.length,
                       "scroll": Double(session.scrollOffset)],
                      forKey: Self.viewStateKey(session.noteID))
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
                                                 byteCount: Int64(data.count), digest: row.contentDigest, data: data)
                        }
                    }) else { return nil }
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

    // MARK: Look and images

    func update(design: AtticDesignContext) {
        guard design != self.design else { return }
        self.design = design
        for session in cache.values { session.engine.update(design: design) }
    }

    func panelDidShow() {
        isPageVisible = true
        active?.engine.refreshRelativeDates(today: NoteDay(date: now()))
    }

    /// Reserves all positions synchronously, then loads the batch off actor.
    /// A failed item cancels the whole batch without changing typed text.
    func importImages(_ urls: [URL]) {
        guard let session = active, !session.isReadOnly, !urls.isEmpty else { return }
        guard session.pendingImportIDs.isEmpty else {
            session.notice = String(localized: "Finish the current image import before adding more images.")
            return
        }
        let originID = session.noteID
        let reservations = urls.map { url in
            StagedNoteAttachment(id: UUID(), filename: url.lastPathComponent,
                                 contentTypeIdentifier: "public.image", byteCount: 0,
                                 digest: "", data: Data())
        }
        session.engine.history.beginGroup()
        for item in reservations { session.engine.insertImage(item, pixelSize: nil) }
        session.engine.history.endGroup()
        let ids = Set(reservations.map(\.id))
        session.pendingImportIDs.formUnion(ids)
        let loader = imageLoader
        session.importTask = Task { @MainActor [weak self, session] in
            guard let self else { return }
            var loaded: [StagedNoteAttachment] = []
            for (url, reserved) in zip(urls, reservations) {
                guard !Task.isCancelled, let (item, _) = await loader(url) else {
                    self.cancelImport(in: session)
                    session.notice = String(localized: "The image batch could not be read, so none of its images were added.")
                    _ = self.preserve(session)
                    return
                }
                loaded.append(StagedNoteAttachment(id: reserved.id, filename: item.filename,
                                                   contentTypeIdentifier: item.contentTypeIdentifier,
                                                   byteCount: item.byteCount, digest: item.digest, data: item.data))
            }
            guard !Task.isCancelled, session.noteID == originID else {
                self.cancelImport(in: session)
                return
            }
            if session.isPersisted && self.store.note(withID: originID) == nil {
                session.blocksAutomaticRekey = true
                self.cancelImport(in: session)
                session.notice = String(localized: "This note was deleted while images were loading. The draft remains in recovery; Retry saves it as a new note.")
                _ = self.preserve(session)
                return
            }
            session.pendingImportIDs.subtract(ids)
            session.importTask = nil
            session.engine.completeImageImport(loaded)
            if !self.save(session) { _ = self.preserve(session) }
        }
    }

    private func cancelImport(in session: NoteSession) {
        guard !session.pendingImportIDs.isEmpty else { return }
        session.importTask?.cancel()
        session.importTask = nil
        let ids = session.pendingImportIDs
        session.pendingImportIDs = []
        session.engine.cancelImageImport(ids)
    }

    nonisolated private static func loadImageFile(_ url: URL) async -> (StagedNoteAttachment, CGSize?)? {
        await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), Int64(data.count) <= AttachmentLimits.maxBytesPerAttachment,
                  let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return nil }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return (StagedNoteAttachment(id: UUID(), filename: url.lastPathComponent,
                                         contentTypeIdentifier: type.identifier, byteCount: Int64(data.count),
                                         digest: digest, data: data), NoteImageDecoder.pixelSize(of: data))
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
        guard let row = attachmentRow(id), let data = row.payload else { return nil }
        return StagedNoteAttachment(id: row.id, filename: row.originalFilename, contentTypeIdentifier: row.contentTypeIdentifier,
                                    byteCount: row.byteCount, digest: row.contentDigest, data: data)
    }

    private func attachmentRow(_ id: UUID) -> NoteAttachment? {
        store.attachmentsByNoteID.values.lazy.flatMap { $0 }.first { $0.id == id }
    }
}
