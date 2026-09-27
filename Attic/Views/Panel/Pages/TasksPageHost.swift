import Combine
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
            syncDraftLock(model)
        }
        // Text typed in the add bar holds the panel open (the shell's
        // composer lock) until it is added or cleared; it is kept either way.
        .onReceive(model.addBarState.$text.map { !$0.text.isEmpty }.removeDuplicates()) { hasDraft in
            guard isCurrent else { return }
            // On the next turn (round 4): the shell's published lock redraws
            // what observes the shell, and the first keystroke's frame is
            // the add bar's alone. A turn late changes nothing for hiding.
            DispatchQueue.main.async { uiState.setInteractionLock(.taskComposer, isActive: hasDraft) }
        }
        .onAppear {
            // Task pages arrive in Phase 3; until then "Open page" opens the
            // task's detail panel on its files (the old subpanel stays only
            // for a task's files).
            model.services.openPage = { [subtaskPanels] id in
                // The old panel for the task's files only: subtasks live in
                // the row's quick look (Done log tasks open in the page).
                subtaskPanels.openFilesPanel(for: id)
            }
            if primaryInputFocus.wrappedValue || uiState.isComposerPresented { addBarFocused = true }
            handleSearchRequest(model, request: uiState.searchRequest)
            showItemIfNeeded(model, uiState.shownItem)
            syncDraftLock(model)
            #if DEBUG
            // Capture seams (UI testing only): open on a tab, or with
            // Completed today open.
            let environment = ProcessInfo.processInfo.environment
            if environment["ATTIC_UI_TESTING"] == "1" {
                if let raw = environment["ATTIC_UI_TEST_TASKS_TAB"],
                   let tab = TasksTab.allCases.first(where: { $0.identifier == raw }) {
                    model.openForCapture(tab)
                }
                if environment["ATTIC_UI_TEST_COMPLETED_OPEN"] == "1" { model.completedTodayExpanded = true }
                // The first row with subtasks, its quick look open.
                if environment["ATTIC_UI_TEST_EXPAND_FIRST"] == "1",
                   let row = model.rows(for: model.tab).first(where: { $0.model.subtasks != nil }) {
                    model.setExpanded(row.id, true)
                }
            }
            #endif
        }
        // The host does not observe the shell's state (it would redraw on
        // every change to it), so it listens to the two requests meant for
        // Tasks alone: they arrive while Tasks is already showing, too.
        // Search (the menu-bar item): the Done page's search, focused.
        .onReceive(uiState.$searchRequest) { request in handleSearchRequest(model, request: request) }
        // Reveal and hide come from the panel controller (Astra 7); a
        // covered or off-Space window is still open and keeps its place.
        .onReceive(uiState.$revealCount.dropFirst()) { _ in model.resetForReveal() }
        .onReceive(uiState.$hideCount.dropFirst()) { _ in model.pageDidHide() }
        // An agent's `show` of a task: its tab, the row selected in view.
        .onReceive(uiState.$shownItem) { item in showItemIfNeeded(model, item) }
        // A deferred `show` runs once the edit that blocked it has ended.
        .onReceive(model.$editingTitleID.combineLatest(model.$newSubtaskParentID)) { title, subtask in
            guard title == nil, subtask == nil else { return }
            DispatchQueue.main.async { showItemIfNeeded(model, uiState.shownItem) }
        }
        // Quick capture (the global shortcut) and the shell's own focus
        // requests put the insertion point in the add bar.
        .onChange(of: primaryInputFocus.wrappedValue) { _, focused in if focused { addBarFocused = true } }
        .onChange(of: uiState.isComposerPresented) { _, presented in if presented { addBarFocused = true } }
        .onChange(of: addBarFocused) { _, focused in if !focused, uiState.isComposerPresented { uiState.endAdding() } }
    }

    private func syncDraftLock(_ model: TasksPageModel) {
        uiState.setInteractionLock(.taskComposer, isActive: !model.addBar.text.isEmpty)
    }

    /// `request` is the new value: a published value is sent before the
    /// property changes.
    private func handleSearchRequest(_ model: TasksPageModel, request: UInt64) {
        guard request != state.handledSearchRequest else { return }
        state.handledSearchRequest = request
        // The page puts the keyboard in the Done page's search field.
        model.beginSearch()
    }

    private func showItemIfNeeded(_ model: TasksPageModel, _ item: AtticItemRef?) {
        guard let ref = item, ref.kind == .task else { return }
        // Acknowledged only once handled (round 4): a request an unsaved
        // edit blocks stays, and is tried again when the edit ends.
        guard model.show(ref.id) || model.store.listedTask(withID: ref.id) == nil else { return }
        // Cleared after this change is delivered, not inside it.
        DispatchQueue.main.async { if uiState.shownItem == ref { uiState.showItem(nil) } }
    }
}
