import AppKit

/// An agent's `show` over the real panel: reveal the page (and item)
/// without taking the keyboard, never while the person is typing in Attic,
/// and report what actually happened. A refused reveal changes nothing, and
/// an item (a canvas, a note) is selected only once its page is showing.
@MainActor
final class PanelAgentPresenter: AgentPanelPresenting {
    private let uiState: PanelUIState
    private let store: TaskStore
    private let noteStore: NoteStore
    private let canvasSession: CanvasSession
    private let noteDraft: NoteDraftController
    private let reveal: (PanelSection) -> PanelRevealOutcome
    /// Whether a canvas text editor holds the keyboard in the visible panel.
    /// It sets no interaction lock, so it is asked directly. Tests replace it.
    var canvasTextEditorIsActive: () -> Bool = {
        CanvasSemanticTextEditor.focusedInVisibleWindow != nil
    }

    init(
        uiState: PanelUIState,
        store: TaskStore,
        noteStore: NoteStore,
        canvasSession: CanvasSession,
        noteDraft: NoteDraftController,
        reveal: @escaping (PanelSection) -> PanelRevealOutcome
    ) {
        self.uiState = uiState
        self.store = store
        self.noteStore = noteStore
        self.canvasSession = canvasSession
        self.noteDraft = noteDraft
        self.reveal = reveal
    }

    /// The person is typing in the panel: the add bar, a title, a note, or
    /// canvas text. An agent's `show` then moves nothing.
    var isUserTypingInPanel: Bool {
        guard uiState.isPanelKey else { return false }
        let typing: Set<PanelInteractionLockReason> = [
            .quickEntryFocus, .taskComposer, .taskEditing, .subtaskComposer, .notesEditorFocus, .notesDirty
        ]
        if !uiState.interactionLockReasons.isDisjoint(with: typing) { return true }
        return uiState.selectedSection.isCanvas && canvasTextEditorIsActive()
    }

    func presentForAgent(_ target: AgentShowTarget) -> AgentShowOutcome {
        guard !isUserTypingInPanel else { return .userIsTyping }
        switch target {
        case let .page(page):
            if case let .refused(refusal) = reveal(page.section) { return .failed(refusal.explanation) }
            return .shown("the \(page.title) page")
        case let .item(ref):
            switch ref.kind {
            case .task:
                guard let task = store.listedTask(withID: ref.id) else { return .notFound("task") }
                let section: PanelSection = task.status == .backlog ? .backlog : .tasks
                if case let .refused(refusal) = reveal(section) { return .failed(refusal.explanation) }
                // The Tasks page selects the row on its tab and scrolls to it.
                uiState.showItem(ref)
                return .shown("the task “\(task.title)” on the Tasks page")
            case .note:
                guard let note = noteStore.note(withID: ref.id) else { return .notFound("note") }
                if case let .refused(refusal) = reveal(.notes) { return .failed(refusal.explanation) }
                if uiState.editingNoteID != note.id {
                    guard !noteDraft.isActive || noteDraft.close() else {
                        return .failed("the Notes page is open, but the note being edited could not be saved, so “\(note.title)” was not opened.")
                    }
                    guard noteDraft.beginEditing(note) else {
                        return .failed("the Notes page is open, but “\(note.title)” could not be opened.")
                    }
                    uiState.beginEditingNote(note)
                }
                return .shown("the note “\(note.title)”")
            case .canvas:
                guard canvasSession.canvases.contains(where: { $0.id == ref.id }) else { return .notFound("canvas") }
                // The board changes only once the Canvas page is showing.
                if case let .refused(refusal) = reveal(.canvas) { return .failed(refusal.explanation) }
                guard canvasSession.selectCanvas(ref.id) else {
                    return .failed("the Canvas page is open, but that canvas could not be selected.")
                }
                return .shown("the canvas")
            }
        }
    }
}
