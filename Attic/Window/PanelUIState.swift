import Combine
import Foundation

enum NoteEditorPresentation: Equatable {
    case hidden
    case new
    case editing(UUID)

    var isPresented: Bool {
        switch self {
        case .hidden: false
        case .new, .editing: true
        }
    }

    var noteID: UUID? {
        guard case let .editing(noteID) = self else { return nil }
        return noteID
    }
}

@MainActor
final class PanelUIState: ObservableObject {
    @Published private(set) var isTaskComposerPresented = false
    @Published var editingTaskID: UUID?
    @Published private(set) var noteEditorPresentation: NoteEditorPresentation = .hidden
    @Published var isMenuTracking = false
    @Published private(set) var selectedSection: PanelSection = .tasks
    private(set) var draggedTaskID: UUID?

    /// Tasks/Backlog still drive `TaskStore`; notes are a separate surface.
    /// Kept computed so task views can derive creation status/placeholder.
    var selectedScope: TaskScope { selectedSection.taskScope ?? .tasks }

    var editingNoteID: UUID? { noteEditorPresentation.noteID }

    var isComposerPresented: Bool {
        selectedSection.isNotes
            ? noteEditorPresentation.isPresented
            : isTaskComposerPresented
    }

    var isDraggingTask: Bool { draggedTaskID != nil }

    var isInteractionLocked: Bool {
        isComposerPresented || editingTaskID != nil || isMenuTracking
    }

    /// Compatibility entry point for callers that create whichever item belongs
    /// to the currently selected section. The resulting note state is still
    /// explicit: a new note is never represented as an editing UUID.
    func beginAdding() {
        if selectedSection.isNotes {
            beginNewNote()
        } else {
            beginAddingTask()
        }
    }

    func beginAddingTask() {
        editingTaskID = nil
        isTaskComposerPresented = true
    }

    func beginNewNote() {
        editingTaskID = nil
        noteEditorPresentation = .new
    }

    func selectSection(_ section: PanelSection) {
        guard selectedSection != section else { return }
        isTaskComposerPresented = false
        editingTaskID = nil
        draggedTaskID = nil
        selectedSection = section
    }

    /// Ends the task composer for the current task section. Note editor state is
    /// deliberately separate so navigating through Tasks cannot discard a
    /// suspended note session.
    func endAdding() {
        guard !selectedSection.isNotes else {
            endNoteEditing()
            return
        }
        isTaskComposerPresented = false
    }

    func endNoteEditing() {
        noteEditorPresentation = .hidden
    }

    func beginEditing(_ task: TaskItem) {
        isTaskComposerPresented = false
        editingTaskID = task.id
    }

    func endEditing() {
        editingTaskID = nil
    }

    func beginEditingNote(_ note: NoteItem) {
        editingTaskID = nil
        noteEditorPresentation = .editing(note.id)
    }

    /// Reconciles presentation with the app-owned draft after autosave or a
    /// fresh-context import. A first autosave promotes `.new` to `.editing`,
    /// while a discarded or remotely removed clean draft becomes `.hidden`.
    func reconcileNoteEditor(activeNoteID: UUID?, isActive: Bool) {
        if !isActive {
            noteEditorPresentation = .hidden
        } else if let activeNoteID {
            noteEditorPresentation = .editing(activeNoteID)
        } else {
            noteEditorPresentation = .new
        }
    }

    func reconcileTaskIDs(_ availableIDs: Set<UUID>) {
        if let editingTaskID, !availableIDs.contains(editingTaskID) {
            self.editingTaskID = nil
        }
        if let draggedTaskID, !availableIDs.contains(draggedTaskID) {
            self.draggedTaskID = nil
        }
    }

    func beginDragging(_ task: TaskItem) {
        draggedTaskID = task.id
    }

    func endDragging() {
        draggedTaskID = nil
    }

    func finishDragging(releasedOutsidePanel: Bool) -> UUID? {
        guard let draggedTaskID else { return nil }
        self.draggedTaskID = nil
        return releasedOutsidePanel ? draggedTaskID : nil
    }
}
