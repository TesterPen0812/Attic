import SwiftUI

/// The document editor is the only Notes page.
struct NotesPageHost: View {
    @ObservedObject var noteStore: NoteStore
    let taskStore: TaskStore
    @ObservedObject var noteDraft: NoteDraftController
    @ObservedObject var uiState: PanelUIState
    let layout: PanelPageLayout
    let hasRestoredSession: Bool

    @State private var presentedTaskID: UUID?
    @State private var taskRouteGeneration = 0
    // A remounted section still shows its retained owner during a handoff.
    private var displayedTaskID: UUID? { presentedTaskID ?? noteDraft.pages.taskNotePresenter?.taskID }

    var body: some View {
        Group {
            if !hasRestoredSession {
                ProgressView("Restoring draft…")
            } else if let taskID = displayedTaskID {
                TaskNotePageContainer(taskID: taskID, tasks: taskStore, controller: noteDraft.pages,
                                      noteStore: noteStore, layout: layout) {
                    closeTaskNoteRoute(taskID)
                }
                .id("\(taskID)-\(taskRouteGeneration)")
            } else {
                NotesEditorPage(controller: noteDraft.pages, noteStore: noteStore, noteDraft: noteDraft,
                                uiState: uiState, layout: layout)
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

    func closeTaskNoteRoute(_ taskID: UUID) {
        guard uiState.openTaskNoteID == taskID else { return }
        uiState.openTaskNoteID = nil
    }
}
