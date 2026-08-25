import Combine
import Foundation

/// Owns note text independently of SwiftUI view lifetime and SwiftData model
/// instances. Drafts are debounced while typing and flushed before transitions
/// that could otherwise discard the editor.
@MainActor
final class NoteDraftController: ObservableObject {
    enum Conflict: Equatable {
        case remoteChange
        case missingOriginal
    }

    private struct PersistedSnapshot: Equatable {
        let noteID: UUID
        let title: String
        let body: String
    }

    @Published var title = "" {
        didSet { draftDidChange() }
    }

    @Published var body = "" {
        didSet { draftDidChange() }
    }

    @Published private(set) var activeNoteID: UUID?
    @Published private(set) var isActive = false
    @Published private(set) var isDirty = false
    @Published private(set) var conflict: Conflict?

    private let noteStore: NoteStore
    private let autosaveDelay: Duration
    private var autosaveTask: Task<Void, Never>?
    private var isApplyingSnapshot = false
    private var persistedSnapshot: PersistedSnapshot?
    private var generation: UInt64 = 0

    init(
        noteStore: NoteStore,
        autosaveDelay: Duration = .milliseconds(500)
    ) {
        self.noteStore = noteStore
        self.autosaveDelay = autosaveDelay
    }

    var canPersist: Bool {
        conflict == nil && (activeNoteID != nil || Self.hasContent(title: title, body: body))
    }

    var hasConflict: Bool { conflict != nil }

    var conflictMessage: String? {
        switch conflict {
        case .remoteChange:
            "This note changed on another device while you were editing it."
        case .missingOriginal:
            "This note was deleted on another device while you were editing it."
        case nil:
            nil
        }
    }

    /// Flushes the previous draft before creating a new editing session.
    @discardableResult
    func beginNew() -> Bool {
        guard flush() else { return false }
        applySnapshot(noteID: nil, title: "", body: "", isActive: true)
        return true
    }

    /// Flushes the previous note before loading another note. Pending text is
    /// therefore never associated with the newly selected model by accident.
    @discardableResult
    func beginEditing(_ note: NoteItem) -> Bool {
        if isActive, activeNoteID == note.id {
            return true
        }
        guard flush() else { return false }
        applySnapshot(
            noteID: note.id,
            title: note.title,
            body: note.body,
            isActive: true
        )
        return true
    }

    /// Persists pending text without closing the editor. The current store
    /// snapshot is compared with the snapshot loaded into the editor before a
    /// write, preventing autosave from silently overwriting a CloudKit change.
    @discardableResult
    func flush() -> Bool {
        cancelAutosave()

        guard isActive, isDirty else { return conflict == nil }
        guard conflict == nil else { return false }

        if let activeNoteID {
            guard let note = noteStore.notes.first(where: { $0.id == activeNoteID }) else {
                registerConflict(.missingOriginal)
                return false
            }

            let currentSnapshot = Self.snapshot(for: note)
            guard currentSnapshot == persistedSnapshot else {
                registerConflict(.remoteChange)
                return false
            }

            guard Self.hasContent(title: title, body: body) else {
                // Preserve the app's established behavior: clearing every field
                // does not erase an existing note. Revert to the last persisted
                // snapshot rather than converting an accidental close into loss.
                applySnapshot(
                    noteID: note.id,
                    title: note.title,
                    body: note.body,
                    isActive: true
                )
                return true
            }

            guard noteStore.update(note, title: title, body: body) else {
                return false
            }
            persistedSnapshot = Self.snapshot(for: note)
            isDirty = false
            return true
        }

        guard Self.hasContent(title: title, body: body) else {
            // A blank new draft does not create an empty record.
            isDirty = false
            return true
        }

        guard let created = noteStore.create(title: title, body: body) else {
            return false
        }
        activeNoteID = created.id
        persistedSnapshot = Self.snapshot(for: created)
        isDirty = false
        return true
    }

    /// Flushes and clears the editor only after persistence succeeds.
    @discardableResult
    func close() -> Bool {
        guard flush() else { return false }
        discardDraft()
        return true
    }

    /// Reconciles the active editor with a refreshed SwiftData context. Clean
    /// drafts accept remote updates. Dirty drafts stop autosaving and expose an
    /// explicit conflict instead of choosing a winner silently.
    @discardableResult
    func reconcileWithStore() -> Bool {
        guard isActive, let activeNoteID else { return true }

        guard let note = noteStore.notes.first(where: { $0.id == activeNoteID }) else {
            if isDirty {
                registerConflict(.missingOriginal)
                return true
            }
            discardDraft()
            return false
        }

        let currentSnapshot = Self.snapshot(for: note)
        guard currentSnapshot != persistedSnapshot else {
            if conflict != nil {
                conflict = nil
                scheduleAutosaveIfNeeded()
            }
            return true
        }

        if isDirty {
            registerConflict(.remoteChange)
            return true
        }

        applySnapshot(
            noteID: note.id,
            title: note.title,
            body: note.body,
            isActive: true
        )
        return true
    }

    /// Replaces the local draft with the latest remote value.
    @discardableResult
    func useRemoteVersion() -> Bool {
        guard let activeNoteID,
              let note = noteStore.notes.first(where: { $0.id == activeNoteID }) else {
            return false
        }
        applySnapshot(
            noteID: note.id,
            title: note.title,
            body: note.body,
            isActive: true
        )
        return true
    }

    /// Explicitly chooses the local draft when both sides changed.
    @discardableResult
    func overwriteRemoteVersion() -> Bool {
        guard conflict == .remoteChange,
              let activeNoteID,
              let note = noteStore.notes.first(where: { $0.id == activeNoteID }),
              Self.hasContent(title: title, body: body),
              noteStore.update(note, title: title, body: body) else {
            return false
        }
        persistedSnapshot = Self.snapshot(for: note)
        conflict = nil
        isDirty = false
        return true
    }

    /// Keeps both versions by creating a new note for the local draft. This is
    /// also the recovery path when the original record was deleted remotely.
    @discardableResult
    func saveAsNew() -> Bool {
        cancelAutosave()
        guard isActive,
              Self.hasContent(title: title, body: body),
              let created = noteStore.create(title: title, body: body) else {
            return false
        }
        activeNoteID = created.id
        persistedSnapshot = Self.snapshot(for: created)
        conflict = nil
        isDirty = false
        return true
    }

    /// Clears editor state after a user-confirmed deletion succeeds.
    func discardDeletedNote(_ noteID: UUID) {
        guard activeNoteID == noteID else { return }
        discardDraft()
    }

    func discardDraft() {
        applySnapshot(noteID: nil, title: "", body: "", isActive: false)
    }

    private func draftDidChange() {
        guard isActive, !isApplyingSnapshot else { return }
        isDirty = true
        generation &+= 1
        scheduleAutosaveIfNeeded()
    }

    private func scheduleAutosaveIfNeeded() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard isActive, isDirty, conflict == nil else { return }

        let scheduledGeneration = generation
        let delay = autosaveDelay
        autosaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  scheduledGeneration == self.generation else {
                return
            }
            _ = flush()
        }
    }

    private func registerConflict(_ conflict: Conflict) {
        cancelAutosave()
        self.conflict = conflict
    }

    private func cancelAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    private func applySnapshot(
        noteID: UUID?,
        title: String,
        body: String,
        isActive: Bool
    ) {
        cancelAutosave()
        generation &+= 1
        isApplyingSnapshot = true
        activeNoteID = noteID
        self.title = title
        self.body = body
        self.isActive = isActive
        persistedSnapshot = noteID.map {
            PersistedSnapshot(noteID: $0, title: title, body: body)
        }
        conflict = nil
        isDirty = false
        isApplyingSnapshot = false
    }

    private static func snapshot(for note: NoteItem) -> PersistedSnapshot {
        PersistedSnapshot(noteID: note.id, title: note.title, body: note.body)
    }

    private static func hasContent(title: String, body: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
