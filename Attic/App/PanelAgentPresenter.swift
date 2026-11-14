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
        DrawTextEditorView.focusedInVisibleWindow != nil ||
            CanvasSemanticTextEditor.focusedInVisibleWindow != nil
    }

    /// The window that owns the keyboard. Tests replace it.
    var keyWindow: () -> NSWindow? = { NSApp.keyWindow }

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
        // Whichever Attic panel owns the keyboard (the docked one or a
        // detached page) with a text field or editor focused: the Draw
        // library's rename, search and tag fields set no lock, and a
        // floating panel has a key state of its own.
        if let window = keyWindow(), window is AtticPanel, window.firstResponder is NSText { return true }
        guard uiState.isPanelKey else { return false }
        let typing: Set<PanelInteractionLockReason> = [
            .quickEntryFocus, .taskComposer, .agentComposer, .taskEditing, .notesEditorFocus, .notesDirty
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
                let section: PanelSection = task.listedStatus == .backlog ? .backlog : .tasks
                if case let .refused(refusal) = reveal(section) { return .failed(refusal.explanation) }
                // The Tasks page selects the row on its tab and scrolls to it.
                uiState.showItem(ref)
                return .shown("the task “\(task.title)” on the Tasks page")
            case .note:
                guard let note = noteStore.note(withID: ref.id) else { return .notFound("note") }
                if case let .refused(refusal) = reveal(.notes) { return .failed(refusal.explanation) }
                guard noteDraft.pages.open(noteID: note.id) else {
                    return .failed("the Notes page is open, but the requested note could not be opened.")
                }
                noteDraft.pages.dismissLibrary()
                return .shown("the note “\(note.title)”")
            case .canvas:
                // With Draw on, the page context hands out Draw canvas ids and
                // the Canvas page shows the Draw board, so only a Draw canvas
                // can be shown; a legacy id would report a success that changes
                // nothing the person sees. Draw off keeps the legacy session.
                if AtticDraw.isEnabled {
                    let draw = DrawPageModel.shared
                    // One targeted read of the canvas wanted, never the library.
                    if draw.canvasID != ref.id {
                        do {
                            guard try draw.store.open(ref.id).canvas.deletedAt == nil else { return .notFound("canvas") }
                        } catch DrawStoreError.missingCanvas {
                            return .notFound("canvas")
                        } catch {
                            return .failed("that canvas could not be read (\(error.localizedDescription)).")
                        }
                    }
                    if case let .refused(refusal) = reveal(.canvas) { return .failed(refusal.explanation) }
                    if draw.canvasID != ref.id { draw.open(ref.id) }
                    guard draw.canvasID == ref.id else {
                        return .failed("the Canvas page is open, but that canvas could not be opened.")
                    }
                    return .shown("the canvas")
                }
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
