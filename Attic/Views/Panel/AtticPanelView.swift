import Combine
import SwiftUI
import SwiftData

#if ATTIC_LOCAL_ONLY
/// Narrow, test-only counters for the shell's retained-host invalidations.
@MainActor enum PanelInvalidationProbe {
    static var shell: (() -> Void)?
    static var tasksHost: (() -> Void)?
    static var notesHost: (() -> Void)?
    static var calendarHost: (() -> Void)?
    static var canvasHost: (() -> Void)?
    static var pageLayout: ((PanelPage, CGSize) -> Void)?
    static var pageRestingOffset: ((PanelPage, CGFloat) -> Void)?
    static var relevantSettings: (() -> Void)?
}
#endif

/// Settings for the panel's geometry, motion and appearance. Other settings
/// (such as the global quick-capture shortcut) must not rebuild retained pages.
@MainActor
private final class PanelRelevantSettingsObserver: ObservableObject {
    private var subscriptions: Set<AnyCancellable> = []

    init(settings: AppSettings) {
        func changed<Value>(_ publisher: Published<Value>.Publisher) -> AnyPublisher<Void, Never> {
            publisher.dropFirst().map { _ in () }.eraseToAnyPublisher()
        }
        Publishers.MergeMany([
            changed(settings.$panelCornerSize),
            changed(settings.$panelTheme),
            changed(settings.$panelSurfaceStyle),
            changed(settings.$panelTint),
            changed(settings.$panelTintLength),
            // The surface's glass lift: without it, only the island (which
            // observes every setting) changed until something else redrew.
            changed(settings.$brightenGlass),
            changed(settings.$appearance),
            changed(settings.$hapticsEnabled),
            changed(settings.$animations),
            changed(settings.$motionTuning)
        ])
        .sink { [weak self] in
            #if ATTIC_LOCAL_ONLY
            PanelInvalidationProbe.relevantSettings?()
            #endif
            self?.objectWillChange.send()
        }
        .store(in: &subscriptions)
    }
}

/// The shell responds to changes that affect its own composition and chrome.
/// Page-local flags remain owned by their page or their dedicated observer.
@MainActor
private final class PanelRelevantUIStateObserver: ObservableObject {
    private var subscriptions: Set<AnyCancellable> = []

    init(uiState: PanelUIState) {
        func changed<Value>(_ publisher: Published<Value>.Publisher) -> AnyPublisher<Void, Never> {
            publisher.dropFirst().map { _ in () }.eraseToAnyPublisher()
        }
        Publishers.MergeMany([
            changed(uiState.$selectedSection),
            changed(uiState.$panelSize),
            changed(uiState.$retainedPageSizeDuringLiveResize),
            changed(uiState.$isPageContentLoaded),
            changed(uiState.$builtPages),
            changed(uiState.$pagesElsewhere),
            changed(uiState.$isPanelPinned),
            changed(uiState.$primaryInputFocusRequest),
            changed(uiState.$openTaskNoteID),
            changed(uiState.$isComposerPresented)
        ])
        .sink { [weak self] in self?.objectWillChange.send() }
        .store(in: &subscriptions)
    }
}

/// The panel's shell: the surface, the header (Pin and the page switch), the
/// page host for the current page, and the notices above it (the Undo toast
/// and the error notice). Pages lay themselves out inside
/// `PanelPageLayout`; the shell owns everything around them.
struct AtticPanelView: View {
    let store: TaskStore
    let noteStore: NoteStore
    let canvasSession: CanvasSession
    let noteDraft: NoteDraftController
    let chromeInteractionState: PanelChromeInteractionState
    let uiState: PanelUIState
    @StateObject private var relevantUIState: PanelRelevantUIStateObserver
    /// The Draw page's model (its save notice shows like the other pages').
    let settings: AppSettings
    @StateObject private var relevantSettings: PanelRelevantSettingsObserver
    let toasts: PanelToastCenter

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    /// The Mac's setting (or a UI-test launch's, `AtticTransparencySeam`).
    private var reduceTransparency: Bool { AtticTransparencySeam.resolve(systemReduceTransparency) }
    @Environment(\.colorScheme) private var systemColorScheme
    /// What the Tasks page keeps while another page shows (the add bar's
    /// draft and pending attachments).
    @StateObject private var tasksPageState = TasksPageState()
    /// What the Calendar page keeps while another page shows.
    @StateObject private var calendarPageState: CalendarPageState
    /// The "+" card every page shares (Phase B), with its kept draft.
    @StateObject private var composerState = PanelComposerState()
    /// Whether the page switcher is open, for the header titles that make
    /// room for it. Not observed here: only those titles are.
    /// The top row's search and footprint, shared by the pages and the pin.
    @State private var topRowState = PanelTopRowState()
    /// The bars every page shares, drawn once above the pages.
    @State private var sharedChrome = PanelSharedChrome()
    @State private var noticeHeight: CGFloat = 0
    @State private var noticeClearance = PanelPageNoticeClearancePreferenceKey.defaultValue
    @State var hasRestoredNoteSession = false

    @MainActor
    init(
        store: TaskStore,
        noteStore: NoteStore,
        canvasSession: CanvasSession,
        noteDraft: NoteDraftController,
        chromeInteractionState: PanelChromeInteractionState,
        uiState: PanelUIState,
        settings: AppSettings,
        toasts: PanelToastCenter? = nil,
        tasksPageState: TasksPageState? = nil,
        calendarPageState: CalendarPageState? = nil,
        composerState: PanelComposerState? = nil
    ) {
        self.store = store
        self.noteStore = noteStore
        self.canvasSession = canvasSession
        self.noteDraft = noteDraft
        self.chromeInteractionState = chromeInteractionState
        self.uiState = uiState
        _relevantUIState = StateObject(wrappedValue: PanelRelevantUIStateObserver(uiState: uiState))
        self.settings = settings
        _relevantSettings = StateObject(wrappedValue: PanelRelevantSettingsObserver(settings: settings))
        self.toasts = toasts ?? PanelToastCenter()
        // A test hands one in to reach the page's model (round 12).
        _tasksPageState = StateObject(wrappedValue: tasksPageState ?? TasksPageState())
        _calendarPageState = StateObject(wrappedValue: calendarPageState ?? CalendarPageState())
        _composerState = StateObject(wrappedValue: composerState ?? PanelComposerState())
    }

    private var cornerRadius: CGFloat { settings.panelCornerSize }
    private var panelSize: CGSize { uiState.panelSize }
    private var pageLayout: PanelPageLayout {
        PanelPageLayout(cornerSize: cornerRadius, panelSize: panelSize)
    }
    private var chromeInsets: EdgeInsets { pageLayout.chromeInsets }
    private var currentPage: PanelPage { PanelPage(uiState.selectedSection) }

    /// The legacy pages still read the PR #5 palette for their own text.
    private var panelThemePalette: AtticPanelThemePalette {
        settings.panelTheme.palette(for: systemColorScheme, contrast: colorSchemeContrast)
    }
    private var panelSurfaceTreatment: AtticPanelSurfaceTreatment {
        settings.panelSurfaceTreatment(
            colorScheme: systemColorScheme,
            contrast: colorSchemeContrast,
            reduceTransparency: reduceTransparency
        )
    }
    private var panelAccentColor: Color {
        settings.panelTheme.usesSystemAccent ? Color.accentColor : panelThemePalette.accentColor
    }

    /// The native window leaves `AtticStyle.panelElevationMargin` around the
    /// surface, so the exterior elevation is drawn here.
    static let showsSurfaceElevation = true

    private static let exposesKeyStateForUITesting =
        ProcessInfo.processInfo.environment["ATTIC_UI_TESTING"] == "1"

    var body: some View {
        let _ = relevantSettings
        let _ = relevantUIState
        #if ATTIC_LOCAL_ONLY
        let _ = PanelInvalidationProbe.shell?()
        #endif
        PanelRootLayout { themedPanel }
    }

    // MARK: Composition

    private var panelContent: some View {
        ZStack {
            if uiState.isPageContentLoaded {
                // The current page, over any page kept built behind it (a
                // switch back only shows it). Only the current page takes
                // clicks, keys, VoiceOver and the notices' clearance.
                // A page pulled out lives in its own panel only (Accepted
                // "Tall island": pull a page out), never here as well.
                ForEach(PanelPage.allCases) { page in
                    if page == currentPage
                        || (uiState.builtPages.contains(page) && !uiState.pagesElsewhere.contains(page)) {
                        // A page leaving during a held resize must keep the
                        // live width for its entire slide. Only pages already
                        // resting behind the current transition are frozen.
                        let isTravelling = uiState.pageTransit.sliding && uiState.pageTransit.departingPage == page
                        let frozenSize = page == currentPage || isTravelling
                            ? nil : uiState.retainedPageSizeDuringLiveResize
                        let layout = frozenSize.map { PanelPageLayout(cornerSize: cornerRadius, panelSize: $0) }
                            ?? pageLayout
                        PanelResizeStablePageHost(
                            page: page,
                            isCurrent: page == currentPage,
                            isTravelling: isTravelling,
                            livePanelSize: panelSize,
                            frozenSize: frozenSize,
                            cornerSize: cornerRadius,
                            hasRestoredNoteSession: hasRestoredNoteSession,
                            primaryInputFocusRequest: uiState.primaryInputFocusRequest,
                            noticeHeight: noticeHeight,
                            headerControlRects: headerControlRects
                        ) {
                            pageHost(page, layout: layout)
                        }
                            .equatable()
                            // A fully invisible page has no reason to measure
                            // again at each intermediate window size. Its
                            // retained native editors and state stay mounted.
                            .frame(width: frozenSize?.width, height: frozenSize?.height,
                                   alignment: .topLeading)
                            // The outer frame accepts SwiftUI's actual offered
                            // size, including the proposal before the next
                            // AppKit size notification. The hidden content
                            // stays pinned at the top-leading origin.
                            .frame(minWidth: 0, maxWidth: .infinity,
                                   minHeight: 0, maxHeight: .infinity,
                                   alignment: .topLeading)
                            .onAppear {
                                PerformanceSignposts.noteInput("page-mounted \(page.rawValue)")
                            }
                            .onChange(of: page == currentPage) { _, shown in
                                if shown { PerformanceSignposts.noteInput("page-current \(page.rawValue)") }
                            }
                            .modifier(PanelSearchDismissOnEmptyClick(state: topRowState, page: page))
                            .modifier(PanelPageVisibility(
                                page: page,
                                isCurrent: page == currentPage,
                                // A page kept built rests on its side of the
                                // current one, so it moves in from there.
                                restingOffset: pageMotion.restingOffset(side: page.side(from: currentPage),
                                                                        width: panelSize.width),
                                motion: pageMotion,
                                // Canvas and Notes have page-local shortcuts;
                                // hidden, they must not fire. Tasks has none
                                // outside its menus, and disabling it would
                                // redraw the whole list on every switch.
                                disablesWhenHidden: page == .canvas || page == .notes
                            ))
                    }
                }
            }
        }
        // While a switch slides, the pages' scroll bars stay hidden: they
        // never flash or cross the panel (Accepted 2026-11-04).
        .environment(\.panelPageTransit, uiState.pageTransit)
        .coordinateSpace(PanelPageLayout.coordinateSpace)
        .overlay(alignment: .top) {
            header.modifier(PanelHeaderDim(state: topRowState, page: currentPage))
        }
        .overlay(alignment: .bottom) {
            // The bottom bar every page shares (owner, 2026-10-31): drawn
            // once, so a page switch never moves, fades or rebuilds it.
            if uiState.isPageContentLoaded || (PanelUIState.retainsLightweightHostsWhenHidden && uiState.hasEverLoadedPageContent) {
                PanelSharedBottomBar(chrome: sharedChrome, page: currentPage, layout: pageLayout, agentChat: uiState.agentChat)
            }
        }
        .overlay {
            // Over the bar, never in it: the card takes the bar's row (P4)
            // while the bar's own pills and "+" fade out under it.
            if uiState.isPageContentLoaded || (PanelUIState.retainsLightweightHostsWhenHidden && uiState.hasEverLoadedPageContent) {
                ComposerOverlay(model: composer, layout: pageLayout, chrome: sharedChrome, room: composerState.room)
            }
        }
        .overlay {
            // The floating agent chat, over the page and its bars. Closed, it
            // is an empty view, whatever its run is doing.
            if uiState.agentChat.isConnected, uiState.isPageContentLoaded {
                AgentChatHost(bar: uiState.agentChat.bar, room: composerState.room, model: uiState.agentChat, layout: pageLayout,
                              page: currentPage, chrome: sharedChrome,
                              rows: { [tasksPageState] ids in tasksPageState.builtModel?.agentRowFrames(ids) ?? [] },
                              selectPage: selectPage,
                              setTyping: { [uiState] in uiState.setInteractionLock(.agentComposer, isActive: $0) },
                              reach: { [uiState] in uiState.agentReach?($0) ?? false })
            }
        }
        .overlay(alignment: .topLeading) {
            if Self.exposesKeyStateForUITesting {
                // UI tests read whether the panel is key (the drawn or the
                // glass look) instead of waiting a fixed time.
                // A static text: its words are what the tests read (the
                // value of an empty element is not exposed on every runner).
                PanelKeyStateLabel(state: uiState.keyState)
            }
        }
        .overlay(alignment: .bottom) {
            notices
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onPreferenceChange(PanelPageNoticeClearancePreferenceKey.self) { clearance in
            guard noticeClearance != clearance else { return }
            // A page's bottom controls grow or shrink with a spring (the
            // composer's date and tags row): the notices ride it, never
            // jump (O17-02). Reduce Motion moves them at once.
            let reduced = reduceMotion || settings.animations == .reduced
            withAnimation(AtticMotionPreset.popover.animation(reduceMotion: reduced, showing: clearance > noticeClearance)) {
                noticeClearance = clearance
            }
        }
    }

    private var header: some View {
        PanelHeader(
            isPinned: uiState.isPanelPinned,
            page: currentPage,
            onTogglePin: { uiState.isPanelPinned.toggle() },
            onSelectPage: selectPage,
            onNewNote: newQuickNote
        )
        .padding(.leading, chromeInsets.leading)
        .padding(.trailing, chromeInsets.trailing)
        .padding(.top, chromeInsets.top)
        .frame(maxWidth: .infinity)
    }

    private var notices: some View {
        PanelCurrentNoticeOverlay(
            store: store, noteStore: noteStore, canvasSession: canvasSession,
            toasts: toasts, page: currentPage
        )
        .padding(.horizontal, chromeInsets.leading)
        .padding(.bottom, pageLayout.contentInsets.bottom + noticeClearance)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: PanelNoticeHeightPreferenceKey.self, value: proxy.size.height)
            }
        }
    }

    @ViewBuilder
    private func pageHost(_ page: PanelPage, layout: PanelPageLayout) -> some View {
        switch page {
        case .tasks:
            // Phase 3: a task's page opens over the list, which stays built
            // (covered) so Back returns to it exactly as it was.
            TaskNoteRouteHost(page: .tasks, noteStore: noteStore, taskStore: store, noteDraft: noteDraft,
                              uiState: uiState, layout: layout, isReady: hasRestoredNoteSession) { covered in
                TasksPageHost(
                    store: store,
                    uiState: uiState,
                    settings: settings,
                    state: tasksPageState,
                    layout: layout,
                    chromeInteractionState: chromeInteractionState,
                    primaryInputFocusRequest: uiState.primaryInputFocusRequest,
                    isCurrent: page == currentPage && !covered,
                    taskNotes: taskNoteEntryServices,
                    openCalendarDay: openCalendarDay
                )
            }
            .transition(pageTransition(.tasks))
        case .canvas:
            PanelCanvasNoticeAwareHost(
                canvasSession: canvasSession,
                toasts: toasts,
                uiState: uiState,
                layout: layout,
                noticeHeight: noticeHeight,
                headerControlRects: headerControlRects,
                headerBottom: PanelHeaderLayout.bottom(chromeInsets: layout.chromeInsets)
            )
            .transition(pageTransition(.canvas))
        case .notes:
            NotesPageHost(
                noteStore: noteStore,
                taskStore: store,
                noteDraft: noteDraft,
                uiState: uiState,
                layout: layout,
                hasRestoredSession: hasRestoredNoteSession
            )
            .transition(pageTransition(.notes))
        case .calendar:
            // A task's page opens over the Calendar, which stays built
            // (covered) so Back returns to it as it was.
            TaskNoteRouteHost(page: .calendar, noteStore: noteStore, taskStore: store, noteDraft: noteDraft,
                              uiState: uiState, layout: layout, isReady: hasRestoredNoteSession) { _ in
                CalendarPageHost(store: store, state: calendarPageState, uiState: uiState, layout: layout,
                                 onNewTask: startNewTask, taskNotes: calendarTaskNoteEntryServices)
            }
            .transition(pageTransition(.calendar))
        }
    }

    /// Now's next event (Accepted 2026-10-29): that day on the Calendar page.
    private var openCalendarDay: (DueDay) -> Void {
        { [weak calendarPageState, weak uiState, store, noteDraft, canvasSession, settings] day in
            guard let calendarPageState, let uiState else { return }
            let calendar = calendarPageState.model(store: store, resumeDefaults: uiState.resumeDefaults,
                                                    owner: uiState.isFloating ? .floating : .docked)
            calendar.goToToday()
            calendar.select(day)
            Self.selectSection(.calendar, uiState: uiState, noteDraft: noteDraft, canvasSession: canvasSession,
                               motion: PanelPageMotion.current(reduceMotion: AtticMotionPreference.reducesMotion
                                                               || settings.animations == .reduced))
        }
    }

    /// The Calendar's "+": the card, on that day.
    private func startNewTask(_ day: DueDay) {
        composer.open(on: .calendar(selected: day))
    }

    // MARK: The "+" card

    private var composer: ComposerModel {
        composerState.model(tasks: tasksPageState.model(for: store, toasts: toasts), services: composerServices)
    }

    private var composerRoute: PanelComposerRoute {
        PanelComposerRoute(open: { [composerState] page, kind in composerState.model?.open(on: page, as: kind) },
                           isOpen: { [composerState] in composerState.model?.isOpen ?? false },
                           startTags: { [composerState] tags in composerState.model?.startTags(tags) })
    }

    /// The card's kind for this page; nil where it has none (Canvas).
    private var composerPage: ComposerPage? {
        switch currentPage {
        case .tasks: .tasks(tasksPageState.model(for: store, toasts: toasts).tab)
        case .calendar: .calendar(selected: calendarPageState.model(store: store,
            resumeDefaults: uiState.resumeDefaults, owner: uiState.isFloating ? .floating : .docked).newTaskDay)
        case .notes: .notes
        default: nil
        }
    }

    /// ⇧⌘N in the panel: the card on Note; Canvas keeps the Notes page.
    private func newQuickNote() {
        guard let page = composerPage else {
            AppCoordinator.shared?.showNewNote()
            return
        }
        composer.open(on: page, as: .note)
    }

    private var composerServices: ComposerServices {
        let library = tasksPageState.model(for: store, toasts: toasts).library
        return ComposerServices(
            makeWriter: { try CalendarEventWriters.makeDefault(undoRoute: library.undo) },
            openTaskPage: { [uiState] id in
                let page = PanelPage(uiState.selectedSection)
                // A floating panel opens a task's page over its own page
                // only, never over one it doesn't host.
                if uiState.isFloating, page != .tasks, page != .calendar { return }
                uiState.openTaskNote(id, from: page == .calendar ? .calendar : .tasks, row: id)
            },
            openNote: { [noteDraft, uiState, canvasSession, settings] id in
                if uiState.isElsewhere(.notes) {
                    // Notes out in its own panel comes forward with the
                    // note; a floating panel's ⌘Return never switches the
                    // docked panel's page.
                    guard uiState.openElsewhere(.notes, switchesDocked: !uiState.isFloating) else { return }
                } else {
                    Self.selectSection(.notes, uiState: uiState, noteDraft: noteDraft, canvasSession: canvasSession,
                                       motion: PanelPageMotion.current(reduceMotion: AtticMotionPreference.reducesMotion
                                                                       || settings.animations == .reduced))
                }
                DispatchQueue.main.async {
                    guard noteDraft.pages.open(noteID: id) else { return }
                    noteDraft.pages.dismissLibrary()
                }
            },
            openEvent: { [weak composerState] event in
                Task { await composerState?.model?.openInCalendar(event) }
            },
            toast: { [toasts] message, undo in
                toasts.show(message, performing: undo)
            },
            eventFailure: { [toasts] message in
                toasts.showFailure(message)
            },
            drafts: ComposerDraftStore(defaults: settings.userDefaults))
    }

    /// Open Task Note and a row's file drop (Phase 3).
    private var taskNoteEntryServices: TaskNoteEntryServices {
        TaskNoteEntryServices(
            open: { [weak uiState, weak tasksPageState, store, toasts, weak pages = noteDraft.pages] id, backTitle in
                guard let uiState, let tasksPageState else { return }
                let model = tasksPageState.model(for: store, toasts: toasts)
                let query = model.trimmedQuery(for: model.tab)
                if TaskNoteWindows.shared.bringForward(id, searchQuery: query) { return }
                pages?.pendingTaskSearchQuery = query.isEmpty ? nil : query
                uiState.openTaskNote(id, from: .tasks, row: id, backTitle: backTitle)
            },
            addFiles: { [noteDraft, store, toasts, uiState] id, staging in
                TaskNoteFiles.add(staging, to: id, tasks: store, controller: noteDraft.pages, toasts: toasts) {
                    uiState.openTaskNote(id, from: .tasks, row: id, backTitle: nil)
                }
            },
            removeFromTasks: { [weak pages = noteDraft.pages] id in pages?.removeFromTasks?(id) },
            canRemoveFromTasks: { [weak store] id in
                guard let store else { return false }
                return TaskNoteConversion.hasWriting(id, in: ModelContext(store.container))
            },
            makeCheckbox: { [weak pages = noteDraft.pages, weak store, weak toasts] id in
                guard let pages, let store else { return }
                Task { @MainActor in await Self.makeCheckbox(subtaskID: id, pages: pages, tasks: store, toasts: toasts) }
            },
            noteOwners: noteDraft.pages.store.$notes
                .map { Set($0.compactMap(\.taskID)) }
                .removeDuplicates()
                .eraseToAnyPublisher())
    }

    private var calendarTaskNoteEntryServices: TaskNoteEntryServices {
        let services = taskNoteEntryServices
        return TaskNoteEntryServices(
            open: { [uiState, calendarPageState, store, weak pages = noteDraft.pages] id, backTitle in
                let query = calendarPageState.model(store: store, resumeDefaults: uiState.resumeDefaults,
                    owner: uiState.isFloating ? .floating : .docked).searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                pages?.pendingTaskSearchQuery = query.isEmpty ? nil : query
                uiState.openTaskNote(id, from: .calendar, row: id, backTitle: backTitle)
            },
            addFiles: { [noteDraft, store, toasts, uiState] id, staging in
                TaskNoteFiles.add(staging, to: id, tasks: store, controller: noteDraft.pages, toasts: toasts) {
                    uiState.openTaskNote(id, from: .calendar, row: id, backTitle: String(localized: "Back to Calendar"))
                }
            },
            removeFromTasks: services.removeFromTasks, canRemoveFromTasks: services.canRemoveFromTasks,
            noteOwners: services.noteOwners)
    }

    /// Where a task's page grows from on Tasks (Now, Later, Done, a search's
    /// results): its row's highlight and title, as laid out now.
    private func installTaskGrowOrigins() {
        uiState.growOriginProviders[.tasks] = { [weak tasksPageState, store, toasts] id in
            guard let tasksPageState else { return nil }
            let model = tasksPageState.model(for: store, toasts: toasts)
            guard let row = model.agentRowFrames([id]).first?.frame,
                  let window = model.rowPointer?.view?.window else { return nil }
            return AtticGrowOrigin.taskRow(row, title: store.listedTask(withID: id)?.title ?? "",
                                           windowNumber: window.windowNumber)
        }
    }

    /// A purge made an open task's note ordinary (§ 2.7.2): its page leaves
    /// and, if it was showing, the note opens in Notes.
    private func installTaskNotePurgePresentation() {
        let pages = noteDraft.pages
        pages.taskNoteBecameOrdinary = { [weak uiState, weak pages] taskID, _ in
            guard let uiState, let pages else { return }
            TaskNoteRouteHost<EmptyView>.closeRoute(taskID, uiState: uiState, controller: pages)
            uiState.switchPage(to: .notes, motion: .instant)
        }
        // Make Task from Note: the same document opens as the task's page.
        // Weak: these live on the Notes controller and must not keep it
        // (or the panel's state) alive.
        pages.makeTaskFromNote = { [weak pages, weak store, weak uiState, weak toasts] noteID in
            guard let pages, let store, let uiState, let toasts else { return }
            Task { @MainActor in
                switch await TaskNoteConversion.makeTask(fromNote: noteID, notes: pages, tasks: store) {
                case let .made(taskID):
                    let history = pages.undoRoute.workspace(for: .taskWorkspace(taskID))
                    let stepID = pages.undoRoute.undoStepID(in: history.historyID)
                    if TaskNoteWindows.shared.window(noteID: noteID) == nil {
                        uiState.openTaskNote(taskID, from: .notes, backTitle: String(localized: "Back to Notes"))
                    }
                    toasts.show(String(localized: "Added to Now"), answersUndoKey: false, performingAsync: { [weak pages, weak uiState, weak history] in
                        guard let pages, let uiState, let history, let stepID,
                              history.route.undoStepID(in: history.historyID) == stepID else { return .applied }
                        if let open = TaskNotePresenter.open(for: taskID), !open.page.retainsAcrossItemChanges, !(await open.close()) {
                            return .failed(CommandFailure(String(localized: "Couldn't undo: the note is in use")))
                        }
                        TaskNoteRouteHost<EmptyView>.closeRoute(taskID, uiState: uiState)
                        return await history.undoLatest(stepID: stepID) == .applied ? .applied
                            : .failed(CommandFailure(String(localized: "Couldn't undo")))
                    })
                case let .refused(reason):
                    pages.active?.showNotice(NoteNotice(kind: .didntWork, detail: reason))
                }
            }
        }
        pages.removeFromTasks = { [weak pages, weak store, weak uiState, weak toasts] taskID in
            guard let pages, let store, let uiState else { return }
            Task { @MainActor in
                await Self.removeFromTasks(taskID, pages: pages, tasks: store, uiState: uiState, toasts: toasts)
            }
        }
        pages.taskNoteMaterialized = { [weak pages, weak store, weak uiState, weak toasts] patch, operationID in
            guard let pages, let store, let uiState else { return }
            Task { @MainActor in
                await TaskNotePurgePresentation.finish(patch, operationID: operationID, tasks: store, notes: pages,
                                                       uiState: uiState, toasts: toasts) {
                    uiState.switchPage(to: .notes, motion: .instant)
                }
            }
        }
    }

    /// The chrome controls' frames in panel coordinates (top-left origin):
    /// the pin. The page switch is the Tall island now, outside the panel
    /// (Accepted 2026-10-31).
    private var headerControlRects: [CGRect] {
        [CGRect(x: chromeInsets.leading, y: chromeInsets.top,
                width: PanelHeaderLayout.pinSize.width, height: PanelHeaderLayout.height)]
    }

    /// AppKit's top drag lane keeps clear of the current page's top-row
    /// controls: the pin and any text after it, and the switch, ••• and
    /// Search; while the search is open, of the whole row.
    private func syncTopRowFootprint() {
        Self.syncTopRowFootprint(topRowState, uiState: uiState, settings: settings,
                                 chrome: chromeInteractionState)
    }

    /// Static so the top-row state's callback holds no copy of the view: a
    /// copy keeps the panel's stores and sessions alive after the panel goes.
    private static func syncTopRowFootprint(_ topRowState: PanelTopRowState, uiState: PanelUIState,
                                            settings: AppSettings, chrome: PanelChromeInteractionState) {
        let page = PanelPage(uiState.selectedSection)
        let insets = PanelPageLayout(cornerSize: settings.panelCornerSize, panelSize: uiState.panelSize).chromeInsets
        let footprint = topRowState.footprints[page]
        let searching = topRowState.isSearching(page)
        let leading = max(0, (footprint?.leading ?? 0) - insets.leading)
        let trailing = searching ? uiState.panelSize.width : max(0, (footprint?.trailing ?? 0) - insets.trailing)
        chrome.setTopRowControls(leading: leading, trailing: trailing)
    }

    // MARK: Surface, observation and theme

    private var surfacedPanel: some View {
        panelContent
            .environment(\.colorScheme, systemColorScheme)
            .foregroundStyle(panelThemePalette.primaryForegroundColor, panelThemePalette.secondaryForegroundColor)
            .environment(\.controlActiveState, .key)
            .modifier(PanelShellSurface(
                cornerSize: cornerRadius,
                elevation: Self.showsSurfaceElevation ? panelSurfaceTreatment.surfaceElevation : nil
            ))
            .atticContextMenu { panelMenuCommands }
    }

    private var storeObservedPanel: some View {
        surfacedPanel
            #if DEBUG
            // The capture bench (`ATTIC_PAGE_BENCH`): opens or folds the "+" card.
            .onReceive(NotificationCenter.default.publisher(for: .atticBenchToggleComposer)) { _ in
                guard let model = composerState.model else { return }
                if model.isOpen { model.close() } else { model.open(on: .tasks(.now)) }
            }
            #endif
            .onChange(of: uiState.openTaskNoteID) { _, taskID in
                // Task pages own Back's bottom row, including when opened by
                // a shortcut or agent rather than an outside mouse press.
                if taskID != nil {
                    composerState.model?.close(atOnce: true)
                    sharedChrome.tagBar.close()
                }
            }
            // The tag bar starts collapsed each time the panel opens
            // (Accepted 2026-11-13, 1A); the picked tags stay.
            #if DEBUG
            // Capture seam (`ATTIC_UI_TEST_TAG_BAR_OPEN=<seconds>`, UI testing
            // only): the tag bar opens by itself after the panel shows.
            .onAppear {
                let environment = ProcessInfo.processInfo.environment
                guard environment["ATTIC_UI_TESTING"] == "1",
                      let delay = environment["ATTIC_UI_TEST_TAG_BAR_OPEN"].flatMap(Double.init) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { sharedChrome.tagBar.open() }
            }
            #endif
            .onChange(of: uiState.revealCount) { _, _ in sharedChrome.tagBar.close() }
            .onChange(of: uiState.hideCount) { _, _ in sharedChrome.tagBar.close() }
            .onChange(of: uiState.selectedSection) { _, _ in
                // Gone whole, at once: never folding over the sliding pages.
                composerState.model?.close(atOnce: true)
                // Another page's bar starts collapsed too.
                sharedChrome.tagBar.close()
                syncBottomControlsHeight()
                syncTopRowFootprint()
                releaseTaskEntryInteractionLocks()
                if PerformanceSignposts.hasPendingPageSwitch {
                    DispatchQueue.main.async { PerformanceSignposts.pageLaidOut() }
                }
            }
            .task {
                await noteDraft.pages.startAndWait()
                hasRestoredNoteSession = true
            }
            // The store's frequent edits are observed only in this small
            // sidecar; they must not invalidate the whole retained shell.
            .background(PanelStoreRevisionObserver(store: store, uiState: uiState))
    }

    private var interactionObservedPanel: some View {
        storeObservedPanel
            .onAppear {
                topRowState.onFootprintChange = { [weak topRowState, weak uiState, weak settings, weak chromeInteractionState] in
                    guard let topRowState, let uiState, let settings, let chromeInteractionState else { return }
                    Self.syncTopRowFootprint(topRowState, uiState: uiState, settings: settings, chrome: chromeInteractionState)
                }
                syncTopRowFootprint()
                syncBottomControlsHeight()
                syncNoteDraftInteractionLocks()
                // The Notes session's hooks belong to the panel Notes is in.
                if !uiState.isElsewhere(.notes) { installTaskNotePurgePresentation() }
                installTaskGrowOrigins()
            }
            .background(PanelNoteDraftLockObserver(draft: noteDraft, uiState: uiState))
            .onChange(of: uiState.pagesElsewhere.contains(.notes)) { _, away in
                if !away { installTaskNotePurgePresentation() }
            }
            .onPreferenceChange(PanelNoticeHeightPreferenceKey.self) { measured in
                let resolved = max(0, measured.isFinite ? measured : 0)
                if abs(noticeHeight - resolved) >= 0.5 { noticeHeight = resolved }
            }
    }

    private var themedPanel: some View {
        interactionObservedPanel
            .atticKeyboardFocusTracking(uiState.keyboardFocus)
            // Shapes (Accepted 2026-10-30; owner, 2026-10-31: "the shape of
            // these controls in a circle too"): every control on the panel is
            // on curve 1.4, so a square one is a whole superellipse and never
            // a circle, the composer and "+" included, whatever page or bar it
            // is on. Surfaces set their own squircle; rings and dots stay
            // circles (they draw `Circle`).
            .atticDesignCorners()
            .environment(\.atticPanelThemePalette, panelThemePalette)
            .environment(\.atticPanelUsesSystemAccent, settings.panelTheme.usesSystemAccent)
            .environment(\.atticPanelUsesSystemOpaqueSurface, panelSurfaceTreatment.usesSystemOpaqueSurface)
            .environment(\.atticPanelToasts, toasts)
            .environment(\.panelResumeDefaults, uiState.resumeDefaults)
            .environment(\.panelTopRowState, topRowState)
            .environment(\.panelSharedChrome, sharedChrome)
            .environment(\.panelComposer, composerRoute)
            .environment(\.panelComposerRoom, composerState.room)
            // The Tall island (Accepted 2026-10-31) is another window: its
            // clicks come here, to the one page-switch path, and pointing
            // at it builds the other pages early, as the old switch did.
            .onReceive(uiState.island.requests) { selectPage($0) }
            .onReceive(uiState.island.approaches) { _ in prepareOtherPages() }
            .atticTagColours(store.commandLibrary)
            .tint(panelAccentColor)
            .accentColor(panelAccentColor)
            .atticDesignFromSystem(
                palette: settings.panelTheme,
                surface: settings.panelSurfaceStyle,
                tint: settings.panelTint,
                tintLength: settings.panelTintLength,
                hapticsEnabled: settings.panelHapticsEnabled,
                brightenGlass: settings.brightenGlass,
                animations: settings.animations,
                controls: PanelKeyTreatment.controls(isPanelKey: false, surface: settings.panelSurfaceStyle),
                motion: settings.motionTuning
            )
            // Native menus (context menus, pop-ups) follow Attic's chosen
            // appearance, not only the Mac's.
            .atticWindowAppearance(settings.appearance.designMode)
    }

    // MARK: Menus

    /// The panel's own right-click menu, with every shortcut shown. The
    /// current page is ticked, not greyed (Dropdown content: answers,
    /// owner, 2026-10-24, sheet 5).
    private var panelMenuCommands: [AtticMenuCommand] {
        var commands = PanelPage.allCases.map { page in
            AtticMenuCommand(
                verbatim: String(localized: String.LocalizationValue(page.title)),
                systemImage: page.systemName,
                shortcut: KeyboardShortcut(page.keyEquivalent, modifiers: .command),
                state: page == currentPage ? .on : nil
            ) { selectPage(page) }
        }
        commands.append(AtticMenuCommand(
            uiState.isPanelPinned ? "Unpin Panel" : "Pin Panel",
            // An action's icon, as Apple's Pin Tab / Unpin Tab: the outline
            // pin to pin (never a filled pin while unpinned, 13 Nov) and the
            // slashed pin to unpin.
            systemImage: uiState.isPanelPinned ? AtticRaisedButtonMetrics.unpinSymbol : AtticRaisedButtonMetrics.unpinnedSymbol,
            shortcut: KeyboardShortcut("p", modifiers: [.command, .shift]),
            startsSection: true
        ) { uiState.isPanelPinned.toggle() })
        commands.append(AtticMenuCommand(
            "Settings…",
            systemImage: "gearshape",
            shortcut: KeyboardShortcut(",", modifiers: .command)
        ) { AppCoordinator.shared?.openSettings() })
        return commands
    }

    // MARK: Pages

    /// Builds the pages the switch leads to (those the shell keeps), one per
    /// main-thread turn so the pointer never waits on all of them at once.
    private func prepareOtherPages() {
        uiState.onIslandApproach?()
    }

    private func selectPage(_ page: PanelPage) {
        guard page != currentPage else { return }
        selectSection(page.section)
    }

    func selectSection(_ section: PanelSection) {
        Self.selectSection(section, uiState: uiState, noteDraft: noteDraft, canvasSession: canvasSession, motion: pageMotion)
    }

    private static func selectSection(_ section: PanelSection, uiState: PanelUIState, noteDraft: NoteDraftController,
                                      canvasSession: CanvasSession, motion: PanelPageMotion) {
        guard uiState.selectedSection != section else { return }
        // A page out in its own panel: that panel comes forward instead.
        if uiState.routeElsewhere(section) { return }
        // O4-02: a drag tracked on the page being left is cancelled, not
        // committed when its button comes up on another page.
        AtticDragTracking.cancelAll()
        // A refused Notes close must leave every other state untouched, so
        // the refusal is decided before any focus or lock changes.
        if uiState.selectedSection.isNotes {
            guard noteDraft.prepareToLeave(.pageSwitch) else { return }
        }
        PerformanceSignposts.beginPageSwitch()
        uiState.setInteractionLock(.quickEntryFocus, isActive: false)
        if uiState.selectedSection.isCanvas {
            canvasSession.interruptActiveInteraction()
        }
        uiState.switchPage(to: section, motion: motion) {
            if section.isNotes {
                noteDraft.pages.present()
            }
        }
    }

    /// The motion every page switch uses: the full-width slide on the
    /// feel's navigation spring, a little quicker (Accepted 2026-11-04);
    /// instant under Reduce Motion or Animations: Reduced.
    private var pageMotion: PanelPageMotion {
        #if DEBUG
        // Hosted motion tests run on machines with different accessibility
        // settings. The existing test seam must apply to SwiftUI page travel
        // as well as AppKit and model-driven transitions.
        let systemReduced = AtticMotionPreference.systemReduceMotionOverride ?? reduceMotion
        return PanelPageMotion.current(reduceMotion: systemReduced || settings.animations == .reduced)
        #else
        PanelPageMotion.current(reduceMotion: reduceMotion || settings.animations == .reduced)
        #endif
    }

    /// A page built or released by a switch travels as a kept page does:
    /// in from its side of the page left, out to its side of the new one. It reads the
    /// switch as it runs (`PanelUIState.lastPageSwitch`). Pages never
    /// scale: they hold AppKit scroll views, which a SwiftUI scale would
    /// not carry (`AtticMotionPreset.scaleWeight`); an offset moves them.
    private func pageTransition(_ page: PanelPage) -> AnyTransition {
        .modifier(active: PanelPageTravel(page: page, uiState: uiState, width: panelSize.width, isAway: true),
                  identity: PanelPageTravel(page: page, uiState: uiState, width: panelSize.width, isAway: false))
    }

    /// Pages with their own bottom controls (the Tasks add bar) report their
    /// height themselves; every other page has one compact bottom bar.
    private func syncBottomControlsHeight() {
        guard !uiState.selectedSection.isTaskBased else { return }
        chromeInteractionState.bottomControlsHeight = AtticStyle.composerControlHeight
    }

    /// The Tasks page keeps its add-bar locks while it shows; once another
    /// page shows, nothing typed there can hold the panel open.
    private func releaseTaskEntryInteractionLocks() {
        guard !uiState.selectedSection.isTaskBased else { return }
        uiState.setInteractionLock(.quickEntryFocus, isActive: false)
        uiState.setInteractionLock(.taskComposer, isActive: false)
    }

}

/// Native editors and lists on an unseen page retain their state, but their
/// subtree must not be re-diffed for every intermediate window size. State and
/// observed-model changes inside the subtree still invalidate it normally.
/// As soon as a page becomes visible (or starts travelling), normal SwiftUI
/// comparison resumes for every frame.
private struct PanelResizeStablePageHost<Content: View>: View, Equatable {
    let page: PanelPage
    let isCurrent: Bool
    let isTravelling: Bool
    let livePanelSize: CGSize
    let frozenSize: CGSize?
    let cornerSize: CGFloat
    let hasRestoredNoteSession: Bool
    let primaryInputFocusRequest: UInt64
    let noticeHeight: CGFloat
    let headerControlRects: [CGRect]
    @ViewBuilder let content: () -> Content

    static func == (lhs: Self, rhs: Self) -> Bool {
        // On mouseDown, a previously hidden page changes from a live-size
        // proposal to a frozen-size proposal at exactly the same size. Its
        // content does not need to rebuild even for that first drag step.
        // A visible or travelling page always receives the live proposal;
        // release (rhs.frozenSize == nil) always restores normal updates.
        guard let frozenSize = rhs.frozenSize,
              !lhs.isCurrent, !lhs.isTravelling,
              !rhs.isCurrent, !rhs.isTravelling,
              (lhs.frozenSize ?? lhs.livePanelSize) == frozenSize else { return false }
        return lhs.page == rhs.page
            && lhs.cornerSize == rhs.cornerSize
            && lhs.hasRestoredNoteSession == rhs.hasRestoredNoteSession
            && lhs.primaryInputFocusRequest == rhs.primaryInputFocusRequest
            && lhs.noticeHeight == rhs.noticeHeight
    }

    var body: some View { content() }
}

/// Store revisions still reconcile task-route IDs, without subscribing the
/// entire panel surface to every task mutation.
private struct PanelStoreRevisionObserver: View {
    @ObservedObject var store: TaskStore
    let uiState: PanelUIState

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: store.revision) { _, _ in
                uiState.reconcileTaskIDs(Set(store.tasks.map(\.id)))
            }
    }
}

/// Note-draft changes affect interaction locks, not the shell's layout.
private struct PanelNoteDraftLockObserver: View {
    @ObservedObject var draft: NoteDraftController
    let uiState: PanelUIState

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: draft.isDirty) { _, _ in syncLocks() }
            .onChange(of: draft.hasConflict) { _, _ in syncLocks() }
            .onChange(of: draft.isImporting) { _, _ in syncLocks() }
    }

    private func syncLocks() {
        uiState.setInteractionLock(.notesDirty, isActive: draft.isDirty)
        uiState.setInteractionLock(.notesConflict, isActive: draft.hasConflict)
        uiState.setInteractionLock(.notesImport, isActive: draft.pages.active?.isImporting == true)
    }
}

/// Heavy page error state changes only the notice and its measured clearance.
private struct PanelCurrentNoticeOverlay: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var noteStore: NoteStore
    @ObservedObject var canvasSession: CanvasSession
    @ObservedObject var drawPage: DrawPageModel = .shared
    @ObservedObject var toasts: PanelToastCenter
    let page: PanelPage

    var body: some View {
        PanelNoticeStack(toasts: toasts, notice: currentNotice,
                         onRetry: retryCurrentNotice, onDismissNotice: dismissCurrentNotice)
    }

    private var currentNotice: PanelNoticeContent? {
        switch page {
        case .canvas:
            if AtticDraw.isEnabled { return drawPage.saveNotice }
            return canvasSession.lastErrorMessage.map {
                PanelNoticeContent(message: $0, canRetry: !canvasSession.failedImageIDs.isEmpty)
            }
        case .notes:
            return noteStore.lastErrorMessage.map { PanelNoticeContent(message: $0, canRetry: false) }
        case .tasks, .calendar:
            guard store.lastErrorOwnerID == nil else { return nil }
            return store.lastErrorMessage.map { PanelNoticeContent(message: $0, canRetry: false) }
        }
    }

    private func retryCurrentNotice() {
        guard page == .canvas else { return }
        if AtticDraw.isEnabled { return drawPage.retrySave() }
        if canvasSession.retryFailedImageDecodes() { canvasSession.dismissErrorMessage() }
    }

    private func dismissCurrentNotice() {
        switch page {
        case .canvas: AtticDraw.isEnabled ? drawPage.dismissSaveError() : canvasSession.dismissErrorMessage()
        case .notes: noteStore.dismissError()
        case .tasks, .calendar: store.dismissError()
        }
    }
}

/// The legacy Canvas's error clearance follows notices without redrawing the
/// shared panel on every toast, save or decode notification.
private struct PanelCanvasNoticeAwareHost: View {
    @ObservedObject var canvasSession: CanvasSession
    @ObservedObject var toasts: PanelToastCenter
    @ObservedObject var drawPage: DrawPageModel = .shared
    let uiState: PanelUIState
    let layout: PanelPageLayout
    let noticeHeight: CGFloat
    let headerControlRects: [CGRect]
    let headerBottom: CGFloat

    var body: some View {
        let hasNotice = AtticDraw.isEnabled ? drawPage.saveNotice != nil : canvasSession.lastErrorMessage != nil
        CanvasPageHost(canvasSession: canvasSession, uiState: uiState, layout: layout,
                       errorBannerHeight: hasNotice || toasts.current != nil ? noticeHeight : 0,
                       headerControlRects: headerControlRects, headerBottom: headerBottom)
    }
}

/// A page in the shell's stack: shown when current, otherwise kept built
/// but invisible and inert (no clicks, no keyboard shortcuts, hidden from
/// VoiceOver), and adding nothing to what the shell measures.
private struct AtticPanelPageIsCurrentKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False inside a page the shell keeps built behind the current one:
    /// such a page does no work nobody can see (Canvas decodes no images).
    var atticPanelPageIsCurrent: Bool {
        get { self[AtticPanelPageIsCurrentKey.self] }
        set { self[AtticPanelPageIsCurrentKey.self] = newValue }
    }
}

struct PanelPageVisibility: ViewModifier {
    /// The shell's page, so a local-only probe can report what this modifier
    /// was actually given. Nil for a view that is not one of the four pages.
    var page: PanelPage?
    let isCurrent: Bool
    /// Where the page rests while hidden (0 when it is current).
    let restingOffset: CGFloat
    /// The switch's motion: the pages' visibility and the top row's
    /// in-place fade read it.
    var motion: PanelPageMotion = .instant
    let disablesWhenHidden: Bool
    /// A task page growing from its row (`AtticGrowState`) shows its origin
    /// on its own schedule: away at the click, back from Back's.
    var opacityOverride: OpacityOverride?

    struct OpacityOverride {
        let shows: Bool
        let animation: Animation?
    }

    func body(content: Content) -> some View {
        #if ATTIC_LOCAL_ONLY
        if let page { PanelInvalidationProbe.pageRestingOffset?(page, restingOffset) }
        #endif
        return content
            .transformEnvironment(\.atticPanelPageIsCurrent) { $0 = $0 && isCurrent }
            .environment(\.panelPageMotion, motion)
            .transformEnvironment(\.panelPageTravel) { $0 += isCurrent ? 0 : restingOffset }
            .offset(x: isCurrent ? 0 : restingOffset)
            // Both pages fully drawn, edge to edge: the new one at once (it
            // starts outside the glass), the old one until it is out.
            .animation(opacityOverride.map(\.animation) ?? motion.pageOpacityAnimation(incoming: isCurrent)) {
                $0.opacity((opacityOverride?.shows ?? isCurrent) ? 1 : 0)
            }
            .allowsHitTesting(isCurrent)
            .disabled(disablesWhenHidden && !isCurrent)
            .accessibilityHidden(!isCurrent)
            .zIndex(isCurrent ? 1 : 0)
            .transformPreference(PanelPageNoticeClearancePreferenceKey.self) { value in
                if !isCurrent { value = 0 }
            }
    }
}

/// A page coming in or going out with a switch: away, it rests on its side
/// of the switch's other page (`PanelPageSwitch.restingSide`), transparent.
/// It holds the shell's state without observing it and reads the switch
/// when SwiftUI applies it, so a page leaving goes the way of the switch
/// that removes it, not the one that brought it.
private struct PanelPageTravel: ViewModifier {
    let page: PanelPage
    let uiState: PanelUIState
    let width: CGFloat
    let isAway: Bool

    func body(content: Content) -> some View {
        let motion = uiState.lastPageSwitch?.motion ?? .instant
        let travel = isAway ? motion.restingOffset(side: uiState.lastPageSwitch?.restingSide(of: page) ?? 0, width: width) : 0
        // Away is outside the glass (a whole width over): the page is drawn
        // whole all the way, as a kept page is.
        content
            .environment(\.panelPageMotion, motion)
            .transformEnvironment(\.panelPageTravel) { $0 += travel }
            .offset(x: travel)
    }
}

/// Owner, 3 Nov: controls retain native glass before the first click,
/// including over a Solid panel. Native window appearance is kept active
/// independently of keyboard ownership. Reduce Transparency still selects
/// the design system's opaque material in AtticDesignContext.
enum PanelKeyTreatment {
    static func controls(isPanelKey: Bool, surface: PanelSurfaceStyle = .solid) -> AtticControlMaterial {
        .liquidGlass
    }
}

private struct PanelNoticeHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension AppSettings {
    /// The Haptics setting (spec § Touch and sound: a light tick when a task
    /// is completed or a dragged item snaps into place, "can be turned
    /// off"), as the panel feeds it into the design context: every
    /// design-system component in the panel (the status circle's tick
    /// included) follows it.
    var panelHapticsEnabled: Bool { hapticsEnabled }
}

extension AppearancePreference {
    /// The design system's mode for this choice; nil follows the Mac.
    var designMode: AtticDesignContext.Mode? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The panel's root always takes exactly the room its window gives it, from
/// its top-leading corner, whatever its content asks for.
///
/// A flexible frame reports the larger of its content's size and the
/// proposal, and `NSHostingView` centres a root that is larger than its
/// bounds. So a single over-wide child (a bottom row whose status pill no
/// longer fit beside the buttons, a window frame that changed while
/// SwiftUI still laid out for the old one) used to push the whole panel
/// past its window on both sides, cutting the corner buttons off at the
/// left and right edges (owner, 2026-10-08). Here the content is proposed
/// the window's size and placed at its origin, every pass, including every
/// frame of a size change.
struct PanelRootLayout: Layout {
    #if DEBUG
    /// The size the root was last placed at (hosted tests compare it with
    /// the window's visible frame). SwiftUI may place from its async display
    /// link, so the recorder must not cross to the main actor.
    private final class PlacementRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var size: CGSize?

        func record(_ value: CGSize) { lock.withLock { size = value } }
        func latest() -> CGSize? { lock.withLock { size } }
    }

    private nonisolated static let placementRecorder = PlacementRecorder()
    nonisolated static var lastPlacedSize: CGSize? { placementRecorder.latest() }

    /// One entry point shared by normal SwiftUI layout and the off-thread
    /// regression. Layout is free to call this from a display-link thread.
    nonisolated static func recordPlacedSize(_ size: CGSize) {
        placementRecorder.record(size)
    }
    #endif

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Asked for an ideal size (no proposal), report the content's, so
        // nothing that measures the hosting view changes; given a size, take
        // exactly that.
        if let width = proposal.width, let height = proposal.height { return CGSize(width: width, height: height) }
        let ideal = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: proposal.width ?? ideal.width, height: proposal.height ?? ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
        #if DEBUG
        Self.recordPlacedSize(bounds.size)
        #endif
    }
}


extension AtticPanelView {
    /// Make Checkbox from a subtask row (C2): the page's own producer,
    /// `TaskNotePresenter.makeNoteCheckbox`, through the write gate,
    /// journal and the item's retained history. On the item's open page
    /// when there is one, else on a headless page closed straight after
    /// (as the agent's tool does). The toast's Undo is the history's step.
    @MainActor static func makeCheckbox(subtaskID: UUID, pages: NotesPageController, tasks: TaskStore,
                                        toasts: PanelToastCenter?) async {
        func report(_ reason: String) {
            toasts?.show(reason, actionTitle: String(localized: "Retry"), answersUndoKey: false) { [weak pages, weak tasks, weak toasts] in
                guard let pages, let tasks else { return }
                Task { @MainActor in await Self.makeCheckbox(subtaskID: subtaskID, pages: pages, tasks: tasks, toasts: toasts) }
            }
        }
        guard let parentID = tasks.task(withID: subtaskID)?.parentID,
              let coordinator = try? WorkspaceLegacyBridge.coordinator(for: tasks.container) else { return }
        await coordinator.sessions.retryHeadlessClosures()
        let presenter: TaskNotePresenter
        let headless: Bool
        if let open = TaskNotePresenter.open(for: parentID) {
            presenter = open
            headless = false
        } else {
            let library = tasks.commandLibrary ?? AtticLibrary(tasks: tasks)
            guard let made = try? TaskNotePresenter(taskID: parentID, tasks: tasks, library: library, notes: pages,
                                                    design: .default, columnInset: AtticNoteMetrics.columnInset, defaults: nil) else {
                report(String(localized: "Couldn't make the note checkbox"))
                return
            }
            presenter = made
            headless = true
        }
        let result = await presenter.makeNoteCheckbox(subtaskID: subtaskID, tasks: tasks, notes: pages)
        if headless, !(await presenter.close()), let lease = presenter.lease {
            _ = await coordinator.sessions.closeHeadless(presenter.page, lease: lease)
        }
        switch result {
        case let .madeCheckbox(entryID, recovery):
            let history = pages.undoRoute.workspace(for: .taskWorkspace(parentID))
            let message = recovery.map { String(localized: "Made note checkbox") + " · " + $0 } ?? String(localized: "Made note checkbox")
            toasts?.show(message, answersUndoKey: false, performingAsync: { [weak history] in
                guard let history, history.route.undoStepID(in: history.historyID) == entryID else { return .applied }
                return await history.undoLatest(stepID: entryID) == .applied ? .applied
                    : .failed(CommandFailure(String(localized: "Can't undo: the line was edited since")))
            })
        case let .refused(reason):
            report(reason)
        case .made:
            break
        }
    }

    @MainActor static func removeFromTasks(_ taskID: UUID, pages: NotesPageController,
        tasks: TaskStore, uiState: PanelUIState, toasts: PanelToastCenter?, moveFilesFirst: Bool = false) async {
        func report(_ reason: String) {
            toasts?.show(reason, actionTitle: String(localized: "Retry"), answersUndoKey: false) { [weak pages, weak tasks, weak uiState, weak toasts] in
                guard let pages, let tasks, let uiState else { return }
                Task { @MainActor in await Self.removeFromTasks(taskID, pages: pages, tasks: tasks,
                    uiState: uiState, toasts: toasts, moveFilesFirst: moveFilesFirst) }
            }
        }
        if moveFilesFirst {
            let moved: TaskAttachmentMigration.Outcome
            if TaskNoteWindows.shared.window(for: taskID) != nil {
                moved = await TaskNoteWindows.shared.moveFilesFirst(taskID, tasks: tasks, controller: pages)
            } else {
                if let open = TaskNotePresenter.open(for: taskID), !(await open.close()) { return }
                moved = await tasks.fileMigration.moveIntoNote(taskID, tasks: tasks, notes: pages)
            }
            switch moved {
            case .migrated, .reconciled, .unchanged: break
            case let .refused(reason): report(reason.reason); return
            case .deferred: report(String(localized: "Couldn't move the files now")); return
            }
        }
        let open = TaskNotePresenter.open(for: taskID)
        switch await TaskNoteConversion.removeTask(taskID, notes: pages, tasks: tasks, workspaceSession: open?.session) {
        case let .removed(noteID):
            let history = pages.undoRoute.workspace(for: .taskWorkspace(taskID))
            let entry = history.route.undoStepID(in: history.historyID)
            toasts?.show(String(localized: "Removed from Tasks"), answersUndoKey: false, performingAsync: { [weak pages, weak history, weak uiState] in
                guard let pages, let history, let uiState, let entry,
                      history.route.undoStepID(in: history.historyID) == entry else { return .applied }
                guard await history.undoLatest(stepID: entry) == .applied else {
                    return .failed(CommandFailure(String(localized: "Couldn't undo")))
                }
                await pages.retireConvertedNote(noteID, installingCommittedForm: false)
                if pages.retainsWindowSession(pages.workspaceSessionIfCached(noteID)) { return .applied }
                uiState.openTaskNote(taskID, from: .notes, backTitle: String(localized: "Back to Notes"))
                return .applied
            })
            // A mini window retains the page already installed by publication.
            if pages.retainsWindowSession(open?.session) { return }
            // The committed ordinary projection is already installed while
            // input is reserved; durable close preserves any queued writing.
            if let open, !(await open.close()) { return }
            TaskNoteWindows.shared.finishHandoff(taskID)
            TaskNoteRouteHost<EmptyView>.closeRoute(taskID, uiState: uiState, controller: pages)
            _ = pages.open(noteID: noteID)
            uiState.switchPage(to: .notes, motion: .instant)

        case let .refused(reason):
            if reason == TaskNoteConversion.earlierFilesReason {
                toasts?.show(reason, actionTitle: String(localized: "Move Files into Note"), answersUndoKey: false) { [weak pages, weak tasks, weak uiState, weak toasts] in
                    guard let pages, let tasks, let uiState else { return }
                    Task { @MainActor in await Self.removeFromTasks(taskID, pages: pages, tasks: tasks,
                        uiState: uiState, toasts: toasts, moveFilesFirst: true) }
                }
            } else { report(reason) }
        }
    }
}

#if DEBUG
extension Notification.Name {
    /// The capture bench: open or fold the "+" card.
    static let atticBenchToggleComposer = Notification.Name("AtticBenchToggleComposer")
}
#endif

/// Only this diagnostic label redraws when keyboard ownership changes.
private struct PanelKeyStateLabel: View {
    @ObservedObject var state: PanelKeyState
    var body: some View {
        Text(verbatim: state.isKey ? "key" : "not key")
            .font(.system(size: 1))
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
            .accessibilityIdentifier("panel-key-state")
            .accessibilityValue(state.isKey ? "key" : "not key")
    }
}
