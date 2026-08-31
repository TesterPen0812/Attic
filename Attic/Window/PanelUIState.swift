import Combine
import Foundation

/// Independent reasons that make hover-driven auto-hide unsafe. Presentation
/// state is intentionally not a lock by itself: a clean, unfocused saved note
/// may remain presented while an unpinned panel hides normally.
enum PanelInteractionLockReason: Hashable, Sendable {
    case quickEntryFocus
    case taskComposer
    case taskEditing
    case notesEditorFocus
    case notesDirty
    case notesConflict
    case notesImport
    case notesPopover
    case menuTracking
    case canvasConfirmation
    case windowMove
    case windowResize
    case blockingSave
}

@MainActor
final class PanelUIState: ObservableObject {
    @Published var isComposerPresented = false
    @Published var editingTaskID: UUID?
    @Published var editingNoteID: UUID?
    @Published var isCanvasConfirmationPresented = false
    @Published var isPanelPinned = false
    @Published var dockingPreviewCorner: ScreenCorner?
    @Published private(set) var panelSize = PanelGeometry.defaultPanelSize
    @Published private(set) var selectedSection: PanelSection = .tasks
    private(set) var draggedTaskID: UUID?
    @Published private var managedInteractionLocks: Set<PanelInteractionLockReason> = []

    /// Tasks/Backlog still drive `TaskStore`; Notes and Canvas use their own
    /// focused stores and surfaces.
    var selectedScope: TaskScope { selectedSection.taskScope ?? .tasks }

    var isDraggingTask: Bool { draggedTaskID != nil }

    var interactionLockReasons: Set<PanelInteractionLockReason> {
        var reasons = managedInteractionLocks
        if selectedSection.taskScope != nil, isComposerPresented {
            reasons.insert(.taskComposer)
        }
        if editingTaskID != nil {
            reasons.insert(.taskEditing)
        }
        if isCanvasConfirmationPresented {
            reasons.insert(.canvasConfirmation)
        }
        return reasons
    }

    var isInteractionLocked: Bool { !interactionLockReasons.isEmpty }

    var isWindowInteractionActive: Bool {
        managedInteractionLocks.contains(.windowMove)
            || managedInteractionLocks.contains(.windowResize)
    }

    /// Shared shell hook for focused editors, attachment imports, popovers,
    /// conflict UI, and blocking saves. Notes owns when its asynchronous work
    /// begins and ends; the panel owns only the resulting visibility lock.
    func setInteractionLock(
        _ reason: PanelInteractionLockReason,
        isActive: Bool
    ) {
        if isActive {
            guard !managedInteractionLocks.contains(reason) else { return }
            managedInteractionLocks.insert(reason)
        } else {
            guard managedInteractionLocks.contains(reason) else { return }
            managedInteractionLocks.remove(reason)
        }
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
        managedInteractionLocks.remove(.quickEntryFocus)
        managedInteractionLocks.remove(.notesEditorFocus)
        managedInteractionLocks.remove(.notesPopover)
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
