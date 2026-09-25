import SwiftUI

/// State the Tasks page keeps while another page is showing. The shell owns
/// one instance for the panel's lifetime, so switching to Notes and back never
/// loses what was typed, selected or expanded: it holds the page's model.
@MainActor
final class TasksPageState: ObservableObject {
    private var model: TasksPageModel?
    /// The last Search request the page acted on (`PanelUIState.searchRequest`).
    var handledSearchRequest: UInt64 = 0

    /// The page model, made once over the app's command layer (the same
    /// undo history agents use), or over a library of its own when the
    /// store has none (tests that host the panel alone).
    func model(for store: TaskStore, toasts: PanelToastCenter?) -> TasksPageModel {
        if let model, model.store === store, toasts == nil || model.toasts === toasts { return model }
        let library = store.commandLibrary ?? AtticLibrary(tasks: store)
        let made = TasksPageModel(library: library, toasts: toasts)
        model = made
        return made
    }
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
    /// False while another page shows and this one is kept built behind it.
    var isCurrent = true

    @State private var addBarFocused = false
    /// The shell's one toast host: the page's Undo toasts show there.
    @Environment(\.atticPanelToasts) private var toasts

    var body: some View {
        let model = state.model(for: store, toasts: toasts)
        TasksPage(
            model: model,
            store: store,
            layout: layout,
            addBarFocused: $addBarFocused,
            chrome: TasksPageChrome(
                bottomControlsHeight: { chromeInteractionState.bottomControlsHeight = $0 },
                typingLock: { uiState.setInteractionLock(.quickEntryFocus, isActive: $0) }
            )
        )
        .equatable()
        // Kept built behind another page, it is opened again when it shows.
        .onChange(of: isCurrent) { _, current in
            guard current else { return }
            model.resetForReveal()
            chromeInteractionState.bottomControlsHeight = TasksPage.footerZone
        }
        .onAppear {
            // Task pages arrive in Phase 3; until then "Open page" opens the
            // task's detail panel on its files (the old subpanel stays only
            // for a task's files).
            model.services.openPage = { [subtaskPanels] id in
                // A fresh open always starts on Subtasks; switch it to the
                // files once it is up (Done log tasks open in the page).
                subtaskPanels.openFamilyPanel(for: id, focusEntry: false)
                subtaskPanels.showPanelView(.attachments, for: id)
            }
            if primaryInputFocus.wrappedValue || uiState.isComposerPresented { addBarFocused = true }
            handleSearchRequest(model)
            showItemIfNeeded(model)
        }
        // Search (the menu-bar item): the Done page's search, focused.
        .onChange(of: uiState.searchRequest) { _, _ in handleSearchRequest(model) }
        // An agent's `show` of a task: its tab, the row selected in view.
        .onChange(of: uiState.shownItem) { _, _ in showItemIfNeeded(model) }
        // Quick capture (the global shortcut) and the shell's own focus
        // requests put the insertion point in the add bar.
        .onChange(of: primaryInputFocus.wrappedValue) { _, focused in if focused { addBarFocused = true } }
        .onChange(of: uiState.isComposerPresented) { _, presented in if presented { addBarFocused = true } }
        .onChange(of: addBarFocused) { _, focused in if !focused, uiState.isComposerPresented { uiState.endAdding() } }
    }

    private func handleSearchRequest(_ model: TasksPageModel) {
        guard uiState.searchRequest != state.handledSearchRequest else { return }
        state.handledSearchRequest = uiState.searchRequest
        model.beginSearch()
        addBarFocused = true
    }

    private func showItemIfNeeded(_ model: TasksPageModel) {
        guard let ref = uiState.shownItem, ref.kind == .task else { return }
        uiState.showItem(nil)
        model.show(ref.id)
    }
}
