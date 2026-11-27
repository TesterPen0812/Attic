import SwiftUI

/// Tracks drafts in every mounted Calendar page, including pulled-out panels.
/// Weak ownership lets closing a panel release its model normally.
@MainActor
final class CalendarDraftTerminationRegistry {
    static let shared = CalendarDraftTerminationRegistry()

    enum Owner: Equatable { case docked, floating }
    enum Preparation: Equatable { case ready, refused(Owner) }

    private final class Entry {
        weak var rows: CalendarEventRowState?
        let owner: Owner
        init(_ rows: CalendarEventRowState, owner: Owner) { self.rows = rows; self.owner = owner }
    }

    private var entries: [Entry] = []

    func register(_ rows: CalendarEventRowState, owner: Owner) {
        entries.removeAll { $0.rows == nil }
        guard !entries.contains(where: { $0.rows === rows }) else { return }
        entries.append(Entry(rows, owner: owner))
    }

    /// Only the docked Calendar draft belongs to a docked-panel dismissal.
    /// A pulled-out Calendar keeps editing in its own window.
    func openRows(for owner: Owner) -> [CalendarEventRowState] {
        entries.removeAll { $0.rows == nil }
        return entries.compactMap { entry in
            guard entry.owner == owner, let rows = entry.rows, rows.rowID != nil else { return nil }
            return rows
        }
    }

    func prepareForTerminationDurably() async -> Bool {
        await prepareForTerminationResult() == .ready
    }

    func prepareForTerminationResult() async -> Preparation {
        entries.removeAll { $0.rows == nil }
        let owners = entries.compactMap { entry -> (CalendarEventRowState, Owner)? in
            guard let rows = entry.rows else { return nil }
            return (rows, entry.owner)
        }
        var failedOwner: Owner?
        for (rows, owner) in owners {
            let settled = await rows.waitForInFlightWorkBeforeQuit()
            let closed = settled ? await rows.close() : false
            if !closed, failedOwner == nil { failedOwner = owner }
        }
        if let failedOwner { return .refused(failedOwner) }
        // An await can admit a newly mounted panel or newer typing. Never
        // approve quit while any owner still holds an open draft.
        if let stillOpen = entries.first(where: { $0.rows?.rowID != nil }) {
            return .refused(stillOpen.owner)
        }
        return .ready
    }
}

/// What the Calendar page keeps while another page shows: its model (the
/// selected day, the month, the search), made the first time the page
/// appears.
@MainActor
final class CalendarPageState: ObservableObject {
    private var model: CalendarPageModel?
    var activeEventRows: CalendarEventRowState? { model?.eventRows }

    /// The page's calendar events: EventKit in the app, the stub in tests.
    static func makeSource() -> CalendarEventSource { CalendarEventSources.makeDefault() }

    #if DEBUG
    /// Test seam: the clock of the models made from here (a day rollover).
    static var now: (() -> Date)?
    #endif
    private static var modelNow: () -> Date {
        #if DEBUG
        if let now { return now }
        #endif
        return Date.init
    }

    func model(store: TaskStore, resumeDefaults: UserDefaults?,
               owner: CalendarDraftTerminationRegistry.Owner) -> CalendarPageModel {
        if let model { return model }
        let made = CalendarPageModel(store: store, source: Self.makeSource(), now: Self.modelNow, makeWriter: {
            guard let undo = store.commandLibrary?.undo else { throw CalendarEventWriteError.undoUnavailable }
            return try CalendarEventWriters.makeDefault(undoRoute: undo)
        }, resumeDefaults: resumeDefaults)
        model = made
        CalendarDraftTerminationRegistry.shared.register(made.eventRows, owner: owner)
        return made
    }
}

/// A shell page in a kept host of its own (page-host-tech-note.md, Way 1;
/// host-boundary.md §10 step 2). Drawn while it is the page shown or the
/// page a switch's slide is carrying out; in use (clicks, keys, reads) only
/// while shown. Hidden, its graph keeps its state and is not run, laid out
/// or walked by the shell's updates; the update that draws it again takes
/// the current root, size and environment before the slide's first frame.
/// It observes only the slide's start and end. The page is held as a value,
/// not a closure, so the shell's re-runs compare it equal and skip it.
/// It never claims the keyboard: shown, the window keeps it, as when the
/// page sat in the panel's own host, so Tab, Esc and ⌘Z take the trunk's
/// path. Calendar has no list that owns keys, unlike the Tasks tab hosts;
/// a click into Search or a field takes the keyboard the ordinary way.
/// The host carries the page's keyboard tag, so while the page is hidden
/// neither it nor anything under it is a key view (`PanelPageKeyboard`).
struct PanelPageKeptHost<Content: View>: View {
    let page: PanelPage
    let isCurrent: Bool
    @ObservedObject var transit: PanelPageTransit
    let content: Content
    /// The leaving root is laid out in the panel's update (`KeptContentHost.laysOutOnLeave`):
    /// for a page whose leave actions (commands released, editor resigned,
    /// a drawing finished) must run where they ran in the panel's own host.
    let laysOutOnLeave: Bool
    /// The page sets the shell's notice clearance (Notes): it is carried out
    /// of the host, since a preference does not cross an `NSHostingView` and
    /// the shell reads it (`AtticPanelView`'s `PanelPageNoticeClearancePreferenceKey`).
    let carriesNoticeClearance: Bool
    /// Held, not observed: only `KeptNoticeClearance.Out` observes it.
    @State private var clearance = KeptNoticeClearance()

    init(page: PanelPage, isCurrent: Bool, transit: PanelPageTransit, laysOutOnLeave: Bool = false,
         carriesNoticeClearance: Bool = false, @ViewBuilder content: () -> Content) {
        self.page = page
        self.isCurrent = isCurrent
        self.transit = transit
        self.laysOutOnLeave = laysOutOnLeave
        self.carriesNoticeClearance = carriesNoticeClearance
        self.content = content()
    }

    var body: some View {
        KeptContentHost(drawn: isCurrent || (transit.sliding && transit.departingPage == page),
                        interactive: isCurrent, space: PanelPageLayout.coordinateSpace, claimsKeyboard: false,
                        page: page, laysOutOnLeave: laysOutOnLeave) {
            content.modifier(KeptNoticeClearance.In(clearance: clearance, carried: carriesNoticeClearance))
        }
        .modifier(KeptNoticeClearance.Out(clearance: clearance, carried: carriesNoticeClearance))
    }
}

/// A kept page's notice clearance as its content last reported it, read
/// outside its host. Until the content reports, the key's default: what the
/// page's subtree reported in the panel's own host when it set none.
@MainActor
final class KeptNoticeClearance: ObservableObject {
    @Published var value = PanelPageNoticeClearancePreferenceKey.defaultValue

    /// Takes the content's value inside the host.
    struct In: ViewModifier {
        let clearance: KeptNoticeClearance
        let carried: Bool
        @ViewBuilder func body(content: Content) -> some View {
            if carried {
                content.onPreferenceChange(PanelPageNoticeClearancePreferenceKey.self) { [clearance] value in
                    if clearance.value != value { clearance.value = value }
                }
            } else {
                content
            }
        }
    }

    /// Sets the preference outside the host; observes only this object.
    struct Out: ViewModifier {
        @ObservedObject var clearance: KeptNoticeClearance
        let carried: Bool
        @ViewBuilder func body(content: Content) -> some View {
            if carried {
                content.preference(key: PanelPageNoticeClearancePreferenceKey.self, value: clearance.value)
            } else {
                content
            }
        }
    }
}

/// The Calendar page as the shell hands it over: references and values
/// only, no closure, so the shell's re-runs (each size write of a resize
/// on another page) compare it equal and skip it while it is hidden. It
/// makes the page's closures itself: the route host's page, the footer's
/// "+" and the task-note services (moved from `AtticPanelView`).
struct CalendarPageSlot: View {
    let store: TaskStore
    let noteStore: NoteStore
    let noteDraft: NoteDraftController
    let uiState: PanelUIState
    let calendarPageState: CalendarPageState
    let tasksPageState: TasksPageState
    let composerState: PanelComposerState
    let toasts: PanelToastCenter
    let layout: PanelPageLayout
    /// Notes has restored its session (a task's page opens only after).
    let isReady: Bool

    var body: some View {
        // A task's page opens over the Calendar, which stays built
        // (covered) so Back returns to it as it was.
        TaskNoteRouteHost(page: .calendar, noteStore: noteStore, taskStore: store, noteDraft: noteDraft,
                          uiState: uiState, layout: layout, isReady: isReady) { _ in
            CalendarPageHost(store: store, state: calendarPageState, uiState: uiState, layout: layout,
                             onNewTask: { [composerState] day in Self.startNewTask(day, composerState: composerState) },
                             taskNotes: AtticPanelView.calendarTaskNoteEntryServices(
                                 uiState: uiState, calendarPageState: calendarPageState,
                                 tasksPageState: tasksPageState, store: store, toasts: toasts, noteDraft: noteDraft))
        }
    }

    /// The Calendar's "+": the card, on that day, through the shell's one
    /// card (as `AtticPanelView.composerRoute` opens it for every page).
    static func startNewTask(_ day: DueDay, composerState: PanelComposerState) {
        composerState.model?.open(on: .calendar(selected: day))
    }
}

/// The Calendar page in the shell. Its task rows act as the Tasks page's
/// do: the circle completes (or reopens) through the same command. Open
/// Page in the row menu or ⌘Return opens over Calendar until Back.
struct CalendarPageHost: View {
    #if DEBUG
    /// Test seam (HiddenPagesCountersTests): how many times the body has run.
    static var bodyEvaluations = 0
    #endif
    let store: TaskStore
    @ObservedObject var state: CalendarPageState
    /// Not observed: the body follows only whether the panel is on screen
    /// (`panelOnScreen`, from the hide and reveal counts). `resumeDefaults`
    /// is a constant and `isFloating` is not published (it matters only
    /// when the page's model is first made); the rest is read in actions.
    let uiState: PanelUIState
    let layout: PanelPageLayout
    /// The footer's "+": the add-a-task flow, for that day.
    let onNewTask: (DueDay) -> Void
    var taskNotes: TaskNoteEntryServices?
    /// `uiState.isPanelOnScreen` as of its last hide or reveal; nil until
    /// the first one (then the value is read as it is).
    @State private var panelOnScreen: Bool?

    var body: some View {
        #if DEBUG
        let _ = Self.bodyEvaluations += 1
        #endif
        CalendarPage(model: state.model(store: store, resumeDefaults: uiState.resumeDefaults,
                                        owner: uiState.isFloating ? .floating : .docked),
                     layout: layout, taskActions: taskActions, onNewTask: onNewTask,
                     panelIsVisible: panelOnScreen ?? uiState.isPanelOnScreen)
            // A publisher sends before its property changes: each count
            // is taken from the value sent, the other from the state.
            .onReceive(uiState.$revealCount.dropFirst()) { [uiState] reveals in
                panelOnScreen = reveals > uiState.hideCount
            }
            .onReceive(uiState.$hideCount.dropFirst()) { [uiState] hides in
                panelOnScreen = uiState.revealCount > hides
            }
    }

    private var taskActions: CalendarTaskRowActions {
        CalendarTaskRowActions(
            toggleDone: { [store] id in CalendarAgendaCommands.toggleDone(id, store: store) },
            open: { [uiState, state, store] id in
                let query = state.model(store: store, resumeDefaults: uiState.resumeDefaults,
                                        owner: uiState.isFloating ? .floating : .docked)
                    .searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                if TaskNoteWindows.shared.bringForward(id, searchQuery: query) { return }
                if let taskNotes { taskNotes.open(id, String(localized: "Back to Calendar")) }
                else { uiState.openTaskNote(id, from: .calendar, row: id, backTitle: String(localized: "Back to Calendar")) }
            },
            rename: { [store] id, title in CalendarAgendaCommands.rename(id, to: title, store: store) },
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


/// The agenda's own edits are steps in Calendar's history, beside the "+"
/// card's events, tasks and notes made there: ⌘Z on Calendar undoes the
/// newest thing done on Calendar, whatever its kind (w3 composer).
enum CalendarAgendaCommands {
    static let history: UndoHistoryID = .calendar

    @MainActor
    static func toggleDone(_ id: UUID, store: TaskStore) {
        guard let task = store.listedTask(withID: id) else { return }
        if let library = store.commandLibrary {
            _ = task.status == .done ? AtticSounds.play(.undone, after: library.reopenTasks([id], in: history))
                : AtticSounds.play(.done, after: library.completeTask(id, in: history))
        } else {
            _ = store.setStatus(task.status == .done ? .todo : .done, for: task)
        }
    }

    @MainActor
    static func rename(_ id: UUID, to title: String, store: TaskStore) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let task = store.task(withID: id) else { return false }
        guard trimmed != task.title else { return true }
        if let library = store.commandLibrary { return library.updateTask(id, title: trimmed, in: history).isApplied }
        return store.rename(task, to: trimmed)
    }
}
