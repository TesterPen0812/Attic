import SwiftUI

/// State the Tasks page keeps while another page is showing. The shell owns
/// one instance for the panel's lifetime, so switching to Notes and back never
/// loses what was typed or attached in the add bar.
@MainActor
final class TasksPageState: ObservableObject {
    @Published var quickEntryTitle = ""
    @Published var quickEntryPriority: TaskPriority = .none
    /// Pending attachments for the task being written; same lifetime as the
    /// draft title above.
    let composerAttachments = TaskComposerAttachments()
}

/// The one place the shell hosts the Tasks page. The shell decides where the
/// page sits and when its add bar (the page's primary input) is focused; the
/// page decides everything inside it.
struct TasksPageHost: View {
    let store: TaskStore
    let uiState: PanelUIState
    let settings: AppSettings
    let subtaskPanels: SubtaskPanelController
    let state: TasksPageState
    let layout: PanelPageLayout
    let chromeInteractionState: PanelChromeInteractionState
    /// The add bar's focus. The shell owns it so quick capture and page
    /// switches can move focus into or out of the page.
    let primaryInputFocus: FocusState<Bool>.Binding

    var body: some View {
        LegacyTasksPage(
            store: store,
            uiState: uiState,
            subtaskPanels: subtaskPanels,
            state: state,
            composerAttachments: state.composerAttachments,
            layout: layout,
            chromeInteractionState: chromeInteractionState,
            usesOriginalTheme: settings.panelTheme == .original,
            isQuickEntryFocused: primaryInputFocus
        )
    }
}
