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

/// The in-flight rename text. Observed only by the field that edits it.
@MainActor
final class TaskRenameDraft: ObservableObject {
    @Published var title = ""
}

@MainActor
final class PanelUIState: ObservableObject {
    @Published var isComposerPresented = false
    /// Whether the panel is the key window. Native Liquid Glass renders flat
    /// in a window that is not key, so while it is not (a hover reveal never
    /// takes the keyboard) the shell draws its controls in the Craft style.
    @Published private(set) var isPanelKey = false
    /// Bumped when an explicit open (Show Attic, quick capture) should put
    /// the keyboard in the current page's primary input (the Tasks add bar).
    @Published private(set) var primaryInputFocusRequest: UInt64 = 0
    @Published var editingTaskID: UUID?
    /// Rename text for `editingTaskID`, owned here rather than by the row view
    /// so an in-flight rename survives surface promotion, family swaps, and
    /// hosting-view replacement mid-edit. It lives in its own observable so
    /// each keystroke re-renders the editing field alone, never every row.
    let renameDraft = TaskRenameDraft()
    var editingDraftTitle: String {
        get { renameDraft.title }
        set { renameDraft.title = newValue }
    }
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
    @Published var confirmingTaskCompletionID: UUID?
    /// A child row's legacy attachments popover.
    @Published var presentedTaskAttachmentsID: UUID?
    /// The owner whose Add attachment picker is up. Kept apart from the
    /// popover mark so neither interaction can overwrite the other's; only
    /// the picker's own completion clears it, because the picker stays up
    /// across section switches and task reconciliation.
    @Published var taskAttachmentPickerOwnerID: UUID?
    /// The main composer's Add attachment picker is up.
    @Published var isComposerAttachmentPickerPresented = false
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
        if confirmingTaskDeletionID != nil || confirmingTaskCompletionID != nil || presentedTaskAttachmentsID != nil
            || taskAttachmentPickerOwnerID != nil || isComposerAttachmentPickerPresented {
            reasons.insert(.taskConfirmation)
        }
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

    /// Whether the pages are built. Nothing is built before the first
    /// reveal, and pages are released again after the panel has been hidden
    /// for a while (spec § Performance: released when hidden), so a hidden
    /// panel holds only the shell. What pages need to keep (drafts, undo,
    /// the open note or canvas) lives outside their views.
    @Published private(set) var isPageContentLoaded = false

    func loadPageContent() {
        guard !isPageContentLoaded else { return }
        isPageContentLoaded = true
        builtPages = [PanelPage(selectedSection)]
    }

    func releasePageContent() {
        guard isPageContentLoaded else { return }
        isPageContentLoaded = false
        builtPages = []
    }

    /// The pages built and kept while hidden behind the current one, so a
    /// switch back to them only shows them (spec § Performance: page switch
    /// within 50 ms). A page joins when it is first shown (or when the
    /// pointer rests on the page switch); the hidden release frees them.
    /// Notes is never kept: its editor saves and releases its locks when it
    /// leaves the screen, and it is rebuilt in Phase 2.
    @Published private(set) var builtPages: Set<PanelPage> = []

    static func keepsBuilt(_ page: PanelPage) -> Bool { page != .notes }

    /// Builds `page` behind the current one (the pointer is on the switch).
    func prepareBuiltPage(_ page: PanelPage) {
        guard isPageContentLoaded, Self.keepsBuilt(page), !builtPages.contains(page) else { return }
        builtPages.insert(page)
    }

    /// The hidden release: every page but the current one goes.
    func releaseBackgroundPages() {
        let current: Set<PanelPage> = isPageContentLoaded ? [PanelPage(selectedSection)] : []
        if builtPages != current { builtPages = current }
    }

    /// The item an agent last asked to show, for the page to scroll to and
    /// highlight. Pages clear it once shown.
    @Published var shownItem: AtticItemRef?

    /// An agent's `show` of an item; the page that lists it consumes it
    /// (nil once handled).
    func showItem(_ ref: AtticItemRef?) {
        shownItem = ref
    }

    func setPanelKey(_ isKey: Bool) {
        guard isPanelKey != isKey else { return }
        isPanelKey = isKey
    }

    func requestPrimaryInputFocus() {
        primaryInputFocusRequest &+= 1
    }

    /// Search (the menu-bar item): the Tasks page opens its Done search
    /// with the keyboard in the field. A counter, so each request is seen
    /// once, whether or not the page is built yet.
    @Published private(set) var searchRequest: UInt64 = 0

    func requestSearch() {
        searchRequest &+= 1
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
        if isPageContentLoaded {
            // The page being left stays built behind the new one unless it
            // is one that is never kept.
            let leaving = PanelPage(selectedSection)
            var pages = builtPages.filter { Self.keepsBuilt($0) || $0 != leaving }
            pages.insert(PanelPage(section))
            if pages != builtPages { builtPages = pages }
        }
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
        confirmingTaskCompletionID = nil
        presentedTaskAttachmentsID = nil
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
        if let confirmingTaskCompletionID, !availableIDs.contains(confirmingTaskCompletionID) {
            self.confirmingTaskCompletionID = nil
        }
        // A picker whose owner was deleted ends as a cancel; its own finish
        // path clears the mark (never cleared directly, see the property).
        if let taskAttachmentPickerOwnerID, !availableIDs.contains(taskAttachmentPickerOwnerID) {
            TaskAttachmentPicker.cancelIfOwned(by: taskAttachmentPickerOwnerID)
        }
        if let presentedTaskAttachmentsID, !availableIDs.contains(presentedTaskAttachmentsID) {
            self.presentedTaskAttachmentsID = nil
        }
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
