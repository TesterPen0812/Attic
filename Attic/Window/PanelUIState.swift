import Combine
import Foundation

@MainActor
final class PanelUIState: ObservableObject {
    @Published var isComposerPresented = false
    @Published var editingTaskID: UUID?
    @Published var editingNoteID: UUID?
    @Published var isMenuTracking = false
    @Published private(set) var selectedSection: PanelSection = .tasks
    @Published private(set) var draggedTaskID: UUID?

    /// Tasks/Backlog still drive `TaskStore`; notes are a separate surface.
    /// Kept computed so task views can derive creation status/placeholder.
    var selectedScope: TaskScope { selectedSection.taskScope ?? .tasks }

    var isDraggingTask: Bool { draggedTaskID != nil }

    var isInteractionLocked: Bool {
        isComposerPresented || editingTaskID != nil || isMenuTracking
    }

    func beginAdding() {
        editingTaskID = nil
        editingNoteID = nil
        isComposerPresented = true
    }

    func selectSection(_ section: PanelSection) {
        guard selectedSection != section else { return }
        isComposerPresented = false
        editingTaskID = nil
        editingNoteID = nil
        draggedTaskID = nil
        selectedSection = section
    }

    func endAdding() {
        isComposerPresented = false
        editingNoteID = nil
    }

    func beginEditing(_ task: TaskItem) {
        isComposerPresented = false
        editingNoteID = nil
        editingTaskID = task.id
    }

    func endEditing() {
        editingTaskID = nil
    }

    /// Editing a note reuses the composer slot so the panel reserves height
    /// for a multi-line body instead of clipping an inline editor.
    func beginEditingNote(_ note: NoteItem) {
        editingTaskID = nil
        editingNoteID = note.id
        isComposerPresented = true
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
