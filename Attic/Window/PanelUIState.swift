import Combine
import Foundation

/// Independent reasons that make hover-driven auto-hide unsafe. Presentation
/// state is intentionally not a lock by itself: a clean, unfocused composer
/// or saved note may remain presented while an unpinned panel hides normally.
enum PanelInteractionLockReason: Hashable, Sendable {
    case quickEntryFocus
    case taskComposer
    case taskEditing
    case subtaskComposer
    case taskConfirmation
    case notesEditorFocus
    case notesDirty
    case notesConflict
    case notesImport
    case notesPopover
    case menuTracking
    case canvasConfirmation
    case windowMove
    case windowResize
    case panelSwipe
    case blockingSave
}

@MainActor
final class PanelUIState: ObservableObject {
    @Published var isComposerPresented = false
    @Published var editingTaskID: UUID?
    /// Rename text for `editingTaskID`, owned here rather than by the row view
    /// so an in-flight rename survives surface promotion, family swaps, and
    /// hosting-view replacement mid-edit.
    @Published var editingDraftTitle = ""
    @Published var editingNoteID: UUID?
    @Published var subtaskDrafts: [UUID: String] = [:]
    /// Families whose inline Add entry is activated. Separate from drafts: an
    /// activated-but-empty entry stays visible, a draft reactivates the entry
    /// on any surface that presents the family, and only an explicit cancel
    /// (Escape) deactivates.
    @Published private(set) var subtaskEntryActiveIDs: Set<UUID> = []
    @Published var focusedSubtaskParentID: UUID?
    @Published private(set) var subtaskEntryRequest: UInt64 = 0
    @Published var confirmingTaskDeletionID: UUID?
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
        if editingTaskID != nil {
            reasons.insert(.taskEditing)
        }
        if confirmingTaskDeletionID != nil { reasons.insert(.taskConfirmation) }
        // .subtaskComposer is a managed lock owned by SubtaskPanelController:
        // it only engages while a TRANSIENT surface holds a draft or focused
        // entry — a draft typed into the independent pinned window, or one
        // retained after dismissal, must never hold the main panel open.
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
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        // AppKit already enforced the display's usable bounds. Reapplying the
        // preferred minimum here would make SwiftUI larger than its window.
        guard abs(panelSize.width - size.width) >= 0.25
                || abs(panelSize.height - size.height) >= 0.25 else { return }
        panelSize = size
    }

    func beginAdding() {
        editingTaskID = nil
        editingNoteID = nil
        isComposerPresented = true
    }

    /// Focused entry lives in the auxiliary subtask surface (transient or
    /// pinned), which watches `subtaskEntryRequest` for re-focus bumps.
    func focusSubtaskEntry(for parentID: UUID) {
        focusedSubtaskParentID = parentID
        subtaskEntryRequest &+= 1
    }

    /// The '+ Add subtask' affordance opens the entry field and focuses it.
    func activateSubtaskEntry(for parentID: UUID) {
        subtaskEntryActiveIDs.insert(parentID)
        focusSubtaskEntry(for: parentID)
    }

    /// Commit/save paths keep the entry active for chain-adding; the focus
    /// pointer simply moves on.
    func deactivateSubtaskEntry(for parentID: UUID) {
        subtaskEntryActiveIDs.remove(parentID)
        if focusedSubtaskParentID == parentID {
            focusedSubtaskParentID = nil
        }
    }

    /// Escape cancels the entry deliberately: deactivates it and discards the
    /// unsubmitted draft. Incidental focus loss, pin/unpin and surface hide
    /// all preserve the draft — only this path drops it.
    func cancelSubtaskEntry(for parentID: UUID) {
        deactivateSubtaskEntry(for: parentID)
        subtaskDrafts[parentID] = nil
    }

    func selectSection(_ section: PanelSection) {
        guard selectedSection != section else { return }
        managedInteractionLocks.remove(.quickEntryFocus)
        managedInteractionLocks.remove(.notesEditorFocus)
        managedInteractionLocks.remove(.notesPopover)
        managedInteractionLocks.remove(.subtaskComposer)
        isComposerPresented = false
        editingTaskID = nil
        editingDraftTitle = ""
        editingNoteID = nil
        draggedTaskID = nil
        focusedSubtaskParentID = nil
        confirmingTaskDeletionID = nil
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
        editingDraftTitle = task.title
    }

    func endEditing() {
        editingTaskID = nil
        editingDraftTitle = ""
    }

    /// Editing a note reuses the composer slot so the panel reserves height
    /// for a multi-line body instead of clipping an inline editor.
    func beginEditingNote(_ note: NoteItem) {
        editingTaskID = nil
        editingNoteID = note.id
        isComposerPresented = true
    }

    func reconcileTaskIDs(_ availableIDs: Set<UUID>) {
        if let confirmingTaskDeletionID, !availableIDs.contains(confirmingTaskDeletionID) {
            self.confirmingTaskDeletionID = nil
        }
        subtaskDrafts = subtaskDrafts.filter { availableIDs.contains($0.key) }
        if let focusedSubtaskParentID, !availableIDs.contains(focusedSubtaskParentID) {
            self.focusedSubtaskParentID = nil
        }
        if let editingTaskID, !availableIDs.contains(editingTaskID) {
            self.editingTaskID = nil
            editingDraftTitle = ""
        }
        subtaskEntryActiveIDs = subtaskEntryActiveIDs.intersection(availableIDs)
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
