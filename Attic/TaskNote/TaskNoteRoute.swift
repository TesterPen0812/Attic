import SwiftUI

/// The task page's route on one panel page (UX plan § 5.3–5.4): the page
/// opens over its origin and Back returns there exactly as it was left.
///
/// Notes replaces its editor with the page (one live editor, OD-1). Tasks
/// keeps its list built under the page, covered and inert, so its tab,
/// scroll, selection and anchor row are all still there after Back.
struct TaskNoteRouteHost<Origin: View>: View {
    let page: PanelPage
    @ObservedObject var noteStore: NoteStore
    let taskStore: TaskStore
    @ObservedObject var noteDraft: NoteDraftController
    @ObservedObject var uiState: PanelUIState
    let layout: PanelPageLayout
    /// Notes has restored its session (the page opens only after).
    let isReady: Bool
    @ViewBuilder let origin: (_ covered: Bool) -> Origin

    @Environment(\.atticDesign) private var design
    @State private var presentedTaskID: UUID?
    @State private var taskRouteGeneration = 0

    /// The route this page serves: only a page opened from here.
    private var requestedID: UUID? { uiState.taskNoteOrigin == page ? uiState.openTaskNoteID : nil }

    // A remounted section still shows its retained owner during a handoff.
    private var displayedTaskID: UUID? {
        presentedTaskID ?? (uiState.taskNoteOrigin == page ? noteDraft.pages.taskNotePresenter?.taskID : nil)
    }

    var body: some View {
        let shown = isReady ? displayedTaskID : nil
        ZStack {
            if page == .notes {
                // Notes: the page replaces the editor (one live editor).
                if shown == nil { origin(false) }
            } else {
                origin(shown != nil)
                    .modifier(PanelPageVisibility(isCurrent: shown == nil, restingOffset: 0, disablesWhenHidden: false))
            }
            if let taskID = shown {
                TaskNotePageContainer(taskID: taskID, tasks: taskStore, controller: noteDraft.pages,
                                      noteStore: noteStore, layout: layout,
                                      backTitle: uiState.taskNoteBackTitle,
                                      onOpenInWindow: { openInWindow(taskID) }) {
                    Self.closeRoute(taskID, uiState: uiState)
                }
                .id("\(taskID)-\(taskRouteGeneration)")
            }
        }
        .task(id: requestedID) {
            let requested = requestedID
            // Not this page's route, and none shown here: nothing to hand off.
            guard requested != nil || presentedTaskID != nil else { return }
            let previous = noteDraft.pages.taskNotePresenter
            let previousID = displayedTaskID
            guard await noteDraft.pages.prepareTaskNoteRoute(requested) else {
                if !Task.isCancelled, uiState.taskNoteOrigin == page { uiState.openTaskNoteID = previousID }
                return
            }
            guard !Task.isCancelled else { return }
            if previous != nil, previous?.lease == nil { taskRouteGeneration &+= 1 }
            // At once: the page is the next frame (no crossfade holding two
            // editors on screen, OD-1).
            presentedTaskID = requested
        }
    }

    /// Back's (and a late close's) end of the route. A newer route stays.
    static func closeRoute(_ taskID: UUID, uiState: PanelUIState) {
        guard uiState.openTaskNoteID == taskID else { return }
        uiState.openTaskNoteID = nil
    }

    /// OD-1: Open in window **moves** the page. The panel's surface lets go
    /// first (durably), then the window takes the one editor.
    private func openInWindow(_ taskID: UUID) {
        TaskNoteWindows.shared.open(taskID: taskID, tasks: taskStore, controller: noteDraft.pages, noteStore: noteStore,
                                    design: design, uiState: uiState)
    }
}

/// What the Tasks page needs to open task pages and fill task notes.
@MainActor
struct TaskNoteEntryServices {
    let open: (_ taskID: UUID, _ backTitle: String) -> Void
    let addFiles: (_ taskID: UUID, _ staging: TaskAttachmentStaging) -> Void
}
