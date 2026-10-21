import SwiftUI

/// The document editor is the only Notes page. A task's page opened from
/// Notes replaces it until Back (`TaskNoteRouteHost`).
struct NotesPageHost: View {
    @ObservedObject var noteStore: NoteStore
    let taskStore: TaskStore
    @ObservedObject var noteDraft: NoteDraftController
    @ObservedObject var uiState: PanelUIState
    let layout: PanelPageLayout
    let hasRestoredSession: Bool

    var body: some View {
        content.onAppear(perform: installTaskNoteHooks)
    }

    @ViewBuilder
    private var content: some View {
        if !hasRestoredSession {
            ProgressView("Restoring draft…")
        } else {
            TaskNoteRouteHost(page: .notes, noteStore: noteStore, taskStore: taskStore, noteDraft: noteDraft,
                              uiState: uiState, layout: layout, isReady: hasRestoredSession) { _ in
                NotesEditorPage(controller: noteDraft.pages, noteStore: noteStore, noteDraft: noteDraft,
                                uiState: uiState, layout: layout)
            }
        }
    }

    /// All notes shows a task note's circle and opens its task's page.
    private func installTaskNoteHooks() {
        let pages = noteDraft.pages
        pages.taskStateLookup = { [taskStore] id in
            taskStore.listedTask(withID: id).map { TaskRowPresentation.state($0.status) }
        }
        pages.openTaskPage = { [taskStore, uiState] taskID in
            guard taskStore.task(withID: taskID) != nil else { return false }
            uiState.openTaskNote(taskID, from: .notes, backTitle: String(localized: "Back to All notes"))
            return true
        }
    }

    func closeTaskNoteRoute(_ taskID: UUID) {
        TaskNoteRouteHost<EmptyView>.closeRoute(taskID, uiState: uiState)
    }
}
