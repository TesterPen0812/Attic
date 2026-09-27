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

/// One open note: its engine (text, undo, staged images) and where it
/// stands against the store. Lives outside any view.
@MainActor
final class NoteSession: ObservableObject, Identifiable {
    nonisolated let id = UUID()
    /// The note's id (a new note's reserved id until its first save).
    @Published private(set) var noteID: UUID
    @Published fileprivate(set) var isPersisted: Bool
    fileprivate(set) var baseRevisionID: UUID?
    let engine: NoteEditorEngine
    let readOnlyReason: NoteReadOnlyReason?
    @Published fileprivate(set) var isDirty = false
    @Published fileprivate(set) var problem: NoteSaveProblem?
    /// Information for the slot (lowest priority), such as a refused change.
    @Published var notice: String?
    fileprivate(set) var lastEditAt: Date?
    fileprivate(set) var selection = NSRange(location: 0, length: 0)

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

    var isReadOnly: Bool { readOnlyReason != nil }

    /// Untouched: never saved, no text, no objects.
    var isUntouchedDraft: Bool { !isPersisted && engine.document().isEmpty && engine.objectIDs().isEmpty }
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

    let store: NoteStore
    let journal: NoteDraftJournaling?
    private let defaults: UserDefaults?
    private let saveDelay: Duration
    private let pauseVersionDelay: Duration
    private let now: () -> Date
    private var cache: [UUID: NoteSession] = [:]
    private var recency: [UUID] = []
    private let cacheLimit = 8
    private var saveTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var didStart = false
    /// Saves and closes the old editor's draft before the page moves on
    /// from a legacy note (set by `NoteDraftController`).
    var leaveLegacyNote: () -> Bool = { true }
    private static let lastViewedKey = "notes.lastViewedNote.v2"

    init(store: NoteStore, journal: NoteDraftJournaling?, defaults: UserDefaults? = nil,
         saveDelay: Duration = .milliseconds(300), pauseVersionDelay: Duration = .seconds(120),
         now: @escaping () -> Date = Date.init) {
        self.store = store
        self.journal = journal
        self.defaults = defaults
        self.saveDelay = saveDelay
        self.pauseVersionDelay = pauseVersionDelay
        self.now = now
        store.openDocumentNoteIDs = { [weak self] in
            guard let self, let active = self.active, active.isPersisted else { return [] }
            return [active.noteID]
        }
    }

    var lastViewedNoteID: UUID? {
        defaults?.string(forKey: Self.lastViewedKey).flatMap(UUID.init(uuidString:))
    }

    // MARK: Opening

    /// Recovery first, then the last note viewed, else a new draft.
    func start() {
        guard !didStart else { return }
        didStart = true
        if let recovered = recoverDrafts() {
            activate(recovered)
            return
        }
        if let last = lastViewedNoteID, store.note(withID: last) != nil, open(noteID: last) { return }
        _ = newNote()
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
        guard let load = store.loadDocument(noteID: note.id), let document = load.content.document else { return nil }
        var readOnlyReason: NoteReadOnlyReason?
        if case let .readOnly(_, reason, _) = load.content { readOnlyReason = reason }
        let session = NoteSession(noteID: note.id, isPersisted: true, baseRevisionID: load.revisionID,
                                  engine: makeEngine(noteID: note.id, document: document, readOnly: readOnlyReason != nil),
                                  readOnlyReason: readOnlyReason)
        return session
    }

    private func makeEngine(noteID: UUID, document: NoteDocument, readOnly: Bool) -> NoteEditorEngine {
        let engine = NoteEditorEngine(noteID: noteID, document: document, readOnly: readOnly, design: design,
                                      today: NoteDay(date: now()))
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
            guard let self, let session else { return }
            // What the note holds before a rewrite is kept as a version.
            if self.save(session), session.isPersisted {
                self.store.recordVersion(noteID: session.noteID, reason: .beforeWritingTools)
            }
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
    private func leaveActive() -> Bool {
        if legacyNoteID != nil {
            guard leaveLegacyNote() else { return false }
        }
        guard let session = active else { return true }
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

    /// The shell's flush (hide, quit, page switch): every session with
    /// unsaved text is saved or checkpointed. False only when some draft is
    /// in memory alone.
    @discardableResult
    func preserveAll() -> Bool {
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
        if save(session) { return true }
        guard let journal else {
            session.problem = .onlyInMemory(storeMessage())
            return false
        }
        do {
            try journal.write(journalEntry(for: session), staged: session.engine.stagedAttachments(for: session.engine.document()))
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

    private func journalEntry(for session: NoteSession) -> NoteDraftJournalEntry {
        let document = session.engine.document()
        let staged = session.engine.stagedAttachments(for: document)
        return NoteDraftJournalEntry(
            noteID: session.noteID,
            isPersisted: session.isPersisted,
            baseRevisionID: session.baseRevisionID,
            content: (try? NoteContentCodec.encode(document)) ?? Data(),
            selectionLocation: session.selection.location,
            selectionLength: session.selection.length,
            staged: staged.map { .init(id: $0.id, filename: $0.filename, contentTypeIdentifier: $0.contentTypeIdentifier,
                                       byteCount: $0.byteCount, digest: $0.digest) },
            savedAt: now()
        )
    }

    // MARK: Saving

    private func textDidChange(in session: NoteSession) {
        guard !session.isReadOnly else { return }
        session.isDirty = true
        session.lastEditAt = now()
        scheduleSave(session)
    }

    private func scheduleSave(_ session: NoteSession) {
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { @MainActor [weak self, weak session] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, let session, !Task.isCancelled else { return }
            if !self.save(session) { _ = self.preserve(session) }
        }
    }

    /// Writes the session to the store now. A never-saved draft with no
    /// content is not written (and counts as saved).
    @discardableResult
    func save(_ session: NoteSession) -> Bool {
        guard session.isDirty || session.problem != nil else { return true }
        guard !session.isReadOnly else { return true }
        let engine = session.engine
        let document = engine.document()
        let staged = engine.stagedAttachments(for: document)
        if !session.isPersisted {
            guard !document.isEmpty || !document.objectIDs.isEmpty else {
                session.isDirty = false
                session.problem = nil
                return true
            }
            switch store.createDocumentNote(id: session.noteID, document: document, staged: staged) {
            case let .success((noteID, revisionID)):
                if noteID != session.noteID {
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
        switch store.saveDocument(noteID: session.noteID, document: document, baseRevisionID: session.baseRevisionID, staged: staged) {
        case let .success(revisionID):
            session.baseRevisionID = revisionID
            didSave(session, staged: staged)
            return true
        case .failure(.noteMissing):
            // The note was deleted meanwhile: keep the text as a new note.
            let oldID = session.noteID
            session.isPersisted = false
            cache[oldID] = nil
            session.adopt(noteID: UUID())
            cache[session.noteID] = session
            session.notice = String(localized: "The note was deleted elsewhere, so your text was kept as a new note.")
            try? journal?.remove(noteID: oldID)
            return save(session)
        case .failure:
            return false
        }
    }

    private func didSave(_ session: NoteSession, staged: [StagedNoteAttachment]) {
        session.isDirty = false
        if session.problem != nil { session.problem = nil }
        session.engine.forgetStaged(Set(staged.map(\.id)))
        try? journal?.remove(noteID: session.noteID)
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
        guard let journal, let entries = try? journal.entries(), !entries.isEmpty else { return nil }
        var newest: NoteSession?
        for (entry, staged) in entries {
            guard case let .editable(document) = NoteContentCodec.decode(entry.content) else { continue }
            let persisted = entry.isPersisted && store.note(withID: entry.noteID) != nil
            let session = NoteSession(noteID: entry.noteID, isPersisted: persisted,
                                      baseRevisionID: entry.baseRevisionID,
                                      engine: makeEngine(noteID: entry.noteID, document: document, readOnly: false),
                                      readOnlyReason: nil)
            wire(session)
            session.engine.restoreStaged(staged)
            session.isDirty = true
            session.selection = NSRange(location: entry.selectionLocation, length: entry.selectionLength)
            if entry.isPersisted, !persisted {
                session.adopt(noteID: UUID())
                try? journal.remove(noteID: entry.noteID)
            }
            if !save(session) {
                session.problem = .notSaved(storeMessage())
            }
            session.notice = String(localized: "Restored unsaved text.")
            cache[session.noteID] = session
            touch(session.noteID)
            newest = session
        }
        return newest
    }

    // MARK: Look and images

    func update(design: AtticDesignContext) {
        guard design != self.design else { return }
        self.design = design
        for session in cache.values { session.engine.update(design: design) }
    }

    func panelDidShow() {
        active?.engine.refreshRelativeDates(today: NoteDay(date: now()))
    }

    /// Stages an image file for the active note (off the main thread for
    /// the read), then inserts it at the caret. Committed with the next save.
    func importImages(_ urls: [URL]) {
        guard let session = active, !session.isReadOnly else { return }
        Task { @MainActor [weak self, weak session] in
            for url in urls {
                let loaded = await Task.detached(priority: .userInitiated) { () -> (StagedNoteAttachment, CGSize?)? in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url), Int64(data.count) <= AttachmentLimits.maxBytesPerAttachment,
                          let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return nil }
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    return (StagedNoteAttachment(id: UUID(), filename: url.lastPathComponent,
                                                 contentTypeIdentifier: type.identifier, byteCount: Int64(data.count),
                                                 digest: digest, data: data),
                            NoteImageDecoder.pixelSize(of: data))
                }.value
                guard let self, let session else { return }
                guard let (item, size) = loaded else {
                    session.notice = String(localized: "“\(url.lastPathComponent)” isn’t an image Attic can add (up to 15 MB).")
                    continue
                }
                session.engine.insertImage(item, pixelSize: size)
                _ = self
            }
        }
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
