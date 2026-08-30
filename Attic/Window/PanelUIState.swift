import Combine
import Foundation

@MainActor
final class PanelUIState: ObservableObject {
    @Published var isComposerPresented = false
    @Published var editingTaskID: UUID?
    @Published var editingNoteID: UUID?
    @Published var isMenuTracking = false
    @Published var isCanvasConfirmationPresented = false
    @Published var isPanelPinned = false
    @Published var dockingPreviewCorner: ScreenCorner?
    @Published private(set) var panelSize = PanelGeometry.defaultPanelSize
    @Published private(set) var selectedSection: PanelSection = .tasks
    private(set) var draggedTaskID: UUID?

    /// Tasks/Backlog still drive `TaskStore`; Notes and Canvas use their own
    /// focused stores and surfaces.
    var selectedScope: TaskScope { selectedSection.taskScope ?? .tasks }

    var isDraggingTask: Bool { draggedTaskID != nil }

    var isInteractionLocked: Bool {
        isComposerPresented
            || editingTaskID != nil
            || isMenuTracking
            || isCanvasConfirmationPresented
            || isWindowInteractionActive
    }

    private(set) var isWindowInteractionActive = false

    func setWindowInteractionActive(_ isActive: Bool) {
        isWindowInteractionActive = isActive
    }

    func updatePanelSize(_ size: CGSize) {
        let clamped = PanelGeometry.clampedPanelSize(size)
        guard abs(panelSize.width - clamped.width) >= 0.25
                || abs(panelSize.height - clamped.height) >= 0.25 else { return }
        panelSize = clamped
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
        isCanvasConfirmationPresented = false
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
