import SwiftUI

/// What the Calendar page keeps while another page shows: its model (the
/// selected day, the month, the search), made the first time the page
/// appears.
@MainActor
final class CalendarPageState: ObservableObject {
    private var model: CalendarPageModel?

    /// The page's calendar events: EventKit in the app, the stub in tests.
    static func makeSource() -> CalendarEventSource { CalendarEventSources.makeDefault() }

    func model(store: TaskStore) -> CalendarPageModel {
        if let model { return model }
        let made = CalendarPageModel(store: store, source: Self.makeSource())
        model = made
        return made
    }
}

/// The Calendar page in the shell. Its task rows act as the Tasks page's
/// do: the circle completes (or reopens) through the same command. Open
/// Page in the row menu or ⌘Return opens over Calendar until Back.
struct CalendarPageHost: View {
    let store: TaskStore
    @ObservedObject var state: CalendarPageState
    let uiState: PanelUIState
    let layout: PanelPageLayout
    /// The footer's "+": the add-a-task flow, for that day.
    let onNewTask: (DueDay) -> Void
    var taskNotes: TaskNoteEntryServices?

    var body: some View {
        CalendarPage(model: state.model(store: store), layout: layout, taskActions: taskActions, onNewTask: onNewTask)
    }

    private var taskActions: CalendarTaskRowActions {
        CalendarTaskRowActions(
            toggleDone: { [store] id in
                guard let task = store.listedTask(withID: id) else { return }
                if let library = store.commandLibrary {
                    _ = task.status == .done ? library.reopenTasks([id]) : library.completeTask(id)
                } else {
                    _ = store.setStatus(task.status == .done ? .todo : .done, for: task)
                }
            },
            open: { [uiState, state, store] id in
                let query = state.model(store: store).searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                if TaskNoteWindows.shared.bringForward(id, searchQuery: query) { return }
                if let taskNotes { taskNotes.open(id, String(localized: "Back to Calendar")) }
                else { uiState.openTaskNote(id, from: .calendar, row: id, backTitle: String(localized: "Back to Calendar")) }
            },
            removeFromTasks: taskNotes?.removeFromTasks,
            canRemoveFromTasks: { id in
                store.listedTask(withID: id)?.parentID == nil && taskNotes?.canRemoveFromTasks?(id) == true
            },
            addFiles: taskNotes.map { services in
                { id in
                    guard !TaskAttachmentPicker.isPresenting(uiState) else { return }
                    uiState.taskAttachmentPickerOwnerID = id
                    TaskAttachmentPickerSession.present(owner: id) { urls in
                        if uiState.taskAttachmentPickerOwnerID == id { uiState.taskAttachmentPickerOwnerID = nil }
                        guard !urls.isEmpty else { return }
                        services.addFiles(id, TaskAttachmentStaging(urls: urls))
                    }
                }
            }
        )
    }
}
