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
/// do: the circle completes (or reopens) through the same command, and the
/// title opens the task's page over the Calendar until Back.
struct CalendarPageHost: View {
    let store: TaskStore
    @ObservedObject var state: CalendarPageState
    let uiState: PanelUIState
    let layout: PanelPageLayout
    /// The footer's "+": the add-a-task flow, for that day.
    let onNewTask: (DueDay) -> Void

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
            open: { [uiState] id in
                uiState.openTaskNote(id, from: .calendar, row: id, backTitle: String(localized: "Back to Calendar"))
            }
        )
    }
}
