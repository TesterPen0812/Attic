import Combine
import SwiftUI

/// The document editor is the only Notes page. A task's page opened from
/// Notes replaces it until Back (`TaskNoteRouteHost`).
struct NotesPageHost: View {
    @ObservedObject var noteStore: NoteStore
    let taskStore: TaskStore
    @ObservedObject var noteDraft: NoteDraftController
    let uiState: PanelUIState
    let layout: PanelPageLayout
    let hasRestoredSession: Bool
    @Environment(\.atticPanelPageIsCurrent) private var isCurrent
    @State private var routeStateRevision = 0

    var body: some View {
        let _ = routeStateRevision
        #if ATTIC_LOCAL_ONLY
        let _ = PanelInvalidationProbe.notesHost?()
        #endif
        content
            .onAppear(perform: installTaskNoteHooks)
            .onReceive(uiState.$openTaskNoteID.dropFirst()) { _ in routeStateRevision &+= 1 }
            .onReceive(uiState.$taskNoteOrigin.dropFirst()) { _ in routeStateRevision &+= 1 }
    }

    @ViewBuilder
    private var content: some View {
        if !hasRestoredSession {
            ProgressView("Restoring draft…")
        } else if !isCurrent, uiState.taskNoteOrigin == .notes,
                  uiState.openTaskNoteID != nil || noteDraft.pages.taskNotePresenter != nil {
            // The composed task page already retains its warm native host and
            // lease. Preserve its old unmount boundary for native controls;
            // ordinary Notes is the view that needs to stay built.
            Color.clear
        } else {
            TaskNoteRouteHost(page: .notes, noteStore: noteStore, taskStore: taskStore, noteDraft: noteDraft,
                              uiState: uiState, layout: layout, isReady: hasRestoredSession) { _ in
                NotesEditorPage(controller: noteDraft.pages, noteStore: noteStore, noteDraft: noteDraft,
                                uiState: uiState, layout: layout, taskStore: taskStore)
            }
        }
    }

    /// All notes shows a task note's circle and opens its task's page.
    private func installTaskNoteHooks() {
        let pages = noteDraft.pages
        pages.taskStateLookup = { [taskStore] id in
            taskStore.listedTask(withID: id).map { TaskRowPresentation.state($0.status) }
        }
        pages.openTaskPage = { [taskStore, weak uiState] taskID in
            // A deleted task's note opens its page too, in the quiet
            // "Task deleted · Restore" state (§ 2.7.2), not as a plain note.
            guard let uiState,
                  taskStore.listedTask(withID: taskID) != nil || taskStore.deletedFamily(rootID: taskID) != nil else { return false }
            uiState.openTaskNote(taskID, from: .notes, backTitle: String(localized: "Back to All notes"))
            return true
        }
    }

    func closeTaskNoteRoute(_ taskID: UUID) {
        TaskNoteRouteHost<EmptyView>.closeRoute(taskID, uiState: uiState, controller: noteDraft.pages)
    }
}
