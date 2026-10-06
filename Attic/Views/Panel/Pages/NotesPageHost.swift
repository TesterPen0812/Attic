import SwiftUI

/// The one place the shell hosts the Notes page (rebuilt in phase 2).
struct NotesPageHost: View {
    @ObservedObject var noteStore: NoteStore
    let taskStore: TaskStore
    @ObservedObject var noteDraft: NoteDraftController
    @ObservedObject var uiState: PanelUIState
    let layout: PanelPageLayout
    /// False until the shell has restored the last note session.
    let hasRestoredSession: Bool

    @State private var presentedTaskID: UUID?
    @State private var taskRouteGeneration = 0
    // A remounted section still shows its retained owner during a handoff.
    private var displayedTaskID: UUID? { presentedTaskID ?? noteDraft.pages.taskNotePresenter?.taskID }

    private var horizontalInset: CGFloat { layout.contentInsets.leading }

    /// The Phase 2 editor hosts the page when the internal switch is on, or
    /// when the old page opened a note already in the new format (only the
    /// new editor may write it).
    private var usesNewEditor: Bool {
        if NotesEditorSetting.isEnabled() { return true }
        guard uiState.isComposerPresented, let id = noteDraft.activeNoteID else { return false }
        return noteStore.note(withID: id)?.usesDocumentFormat ?? false
    }

    private var legacyExitAction: (() -> Void)? {
        guard !NotesEditorSetting.isEnabled() else { return nil }
        return { exitToOldPage() }
    }

    var body: some View {
        Group {
            if !hasRestoredSession {
                ProgressView("Restoring draft…")
            } else if let taskID = displayedTaskID {
                TaskNotePageContainer(taskID: taskID, tasks: taskStore, controller: noteDraft.pages,
                                      noteStore: noteStore, layout: layout) {
                    uiState.openTaskNoteID = nil
                }
                .id("\(taskID)-\(taskRouteGeneration)")
            } else if usesNewEditor {
                NotesEditorPage(controller: noteDraft.pages, noteStore: noteStore, noteDraft: noteDraft,
                                uiState: uiState, layout: layout,
                                exitToOldPage: legacyExitAction)
                    .onAppear { openDocumentNoteFromOldPage() }
            } else if uiState.isComposerPresented {
                NoteComposerView(noteDraft: noteDraft, uiState: uiState,
                                 topContentInset: layout.contentInsets.top + 64,
                                 bottomContentInset: layout.contentInsets.bottom)
                    .padding(.horizontal, horizontalInset)
            } else {
                NotesPanelContent(
                    noteStore: noteStore,
                    noteDraft: noteDraft,
                    uiState: uiState,
                    topContentInset: layout.contentInsets.top + 64,
                    bottomContentInset: layout.contentInsets.bottom
                )
            }
        }
        .task(id: uiState.openTaskNoteID) {
            let requested = uiState.openTaskNoteID
            let previous = noteDraft.pages.taskNotePresenter
            let previousID = displayedTaskID
            guard await noteDraft.pages.prepareTaskNoteRoute(requested) else {
                if !Task.isCancelled { uiState.openTaskNoteID = previousID }
                return
            }
            guard !Task.isCancelled else { return }
            if previous != nil, previous?.lease == nil { taskRouteGeneration &+= 1 }
            presentedTaskID = requested
        }
    }

    /// The old page opened a new-format note: show it in the new editor
    /// (the old draft stays clean; the store refuses its writes to it).
    private func openDocumentNoteFromOldPage() {
        guard !NotesEditorSetting.isEnabled(), let id = noteDraft.activeNoteID else { return }
        _ = noteDraft.pages.open(noteID: id)
    }

    private func exitToOldPage() {
        guard noteDraft.prepareToLeave(.exitToOldPage) else { return }
        noteDraft.discardDraft()
        uiState.endAdding()
    }
}
