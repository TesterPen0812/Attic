import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers

/// What the page tells its host about itself: how tall its bottom controls
/// are (shell notices sit above them) and whether the panel must stay open
/// (someone is typing in it).
struct TasksPageChrome {
    var bottomControlsHeight: (CGFloat) -> Void = { _ in }
    var typingLock: (Bool) -> Void = { _ in }
    /// Edit mode: an editor, a picker or a popover is open. The host holds
    /// the panel open until it closes (then a short grace).
    var editLock: (Bool) -> Void = { _ in }
}

/// The Tasks page (spec § Tasks, Direction A): the page tabs (Now · Later ·
/// Done) under the header, one list with status circles that complete in
/// one click, "Completed today" after Now's open tasks, the row quick look,
/// the selection bar, and the add bar, which always adds. Built only from
/// the design system. Swiping between the pages follows the trackpad 1:1
/// (a paging scroll view under the tabs), and the list stays lazy.
struct TasksPage: View {
    @ObservedObject var model: TasksPageModel
    @ObservedObject var store: TaskStore
    let layout: PanelPageLayout
    /// The add bar's keyboard focus (the shell's quick capture sets it).
    @Binding var addBarFocused: Bool
    var chrome = TasksPageChrome()

    @Environment(\.atticDesign) private var design
    @Environment(\.atticTagColouring) private var tagColouring
    /// How the lists meet the floating controls: Clean cut with the
    /// scroll-under fade (A15, owner 2026-10-04, replacing D1's fade before
    /// the controls); the native soft edge stays off everywhere.
    @ObservedObject private var scrollEdges = AtticScrollEdgeLab.shared
    @StateObject private var focusTracker = AtticKeyboardFocusTracker()
    /// The subtask lines' and strip buttons' own focus, reached by the
    /// page's Tab order (A10). Not observed.
    @State private var focusRequests = AtticFocusRequests()
    /// The stop Tab last sent the keyboard to, while it settles (not observed).
    @State private var tabTarget = TasksTabTarget()
    /// The rows' keyboard focus. Its `FocusState` is owned by
    /// `TasksRowFocusOwner`, under the page's body, not by the page: SwiftUI
    /// redraws a focus state's owner whenever a focusable view comes or
    /// goes, and as the page's own it redrew the whole page each time a
    /// list built new rows (the frame Done's first results arrive in).
    @State private var rowFocus = TasksRowFocusLink()
    private var focusedRow: AtticRowFocusID? {
        get { rowFocus.binding.wrappedValue }
        nonmutating set { rowFocus.binding.wrappedValue = newValue }
    }
    @State private var drag: TasksDrag?
    @State private var fileDropRow: TasksRowID?
    /// A row's date or tag list that is open (owner fix 5 C and D).
    @State private var metaPopover: TasksMetaPopover?
    /// The selection bar's Date or Tags picker (round 10).
    @State private var selectionPicker: SelectionPicker?
    /// The add bar's strip has a picker open.
    @State private var composerPickerOpen = false
    /// "Started tasks stay together" (review 10), while it shows, and
    /// what it says.
    @State private var boundaryHint = false
    @State private var boundaryHintText = String(localized: "Started tasks stay together")
    /// The rows a keyboard or menu reorder just exchanged, held invisible
    /// for a moment so they dissolve into their new places (round 13).
    @State private var reorderFade: Set<UUID> = []
    @State private var boundaryHintTask: Task<Void, Never>?
    /// A Done row the keyboard moved to, to bring into view.
    @State private var doneReveal: TasksPageModel.ScrollRequest?
    /// Where the pointer is and where the rows are (not observed: it
    /// never redraws anything), so a right-click knows its row.
    @State private var pointer: TasksPointer
    /// The drag in progress, outside view state (round 4).
    @State private var dragSession = TasksDragSession()
    @State private var rightClickMonitor: Any?
    /// ⌘F on Done, before any menu sees it (CI run 3: the Edit menu's Find
    /// sent it to whichever text view had the keyboard, the add bar or a
    /// field editor left behind, and the search never opened).
    @State private var findMonitor: Any?
    /// Scroll events, before a list or the panel sees them: the pager's
    /// swipe (round 9).
    @State private var scrollMonitor: Any?
    /// The add bar's text, edited the way typing does (the strip, suggestions).
    @State private var addBarEditor = AtticTokenFieldEditor()
    /// Each built list's scroll proxy, for `show` (not observed).
    @State private var listProxies = TasksListProxies()
    /// Which view draws each Done line (not observed).
    @State private var doneSlots = TasksDoneSlots()
    /// Whether the search showed on the tabs' line when the page last drew
    /// (not observed), and a redraw for Done's query: the page does not
    /// redraw for an applied Done query (`TasksDoneResults`), so when one
    /// changes whether the search shows (a query applied while the field
    /// has no keyboard: an agent's, or a composition committed as the field
    /// let go), the query watcher asks for one here.
    @State private var drawnSearch = TasksDrawnSearch()
    @State private var searchRedraw = 0

    /// The page's Find field (Done's search, Now's and Later's Find) has
    /// the keyboard.
    @State private var searchFocused = false
    /// The page the search field was opened on: moving to another page
    /// lets it go (each page keeps its own query).
    @State private var searchTab: TasksTab = .done
    /// The View Options button's AppKit view: ⌥⌘V opens its menu there.
    @State private var viewOptionsAnchor = AtticMenuAnchor.Holder()
    /// A person's swipe between the pages (round 9: the page owns the
    /// gesture): the model's, so every navigation route cancels it. Not
    /// observed: only the pages' placement redraws while a swipe moves.
    private var swipe: TasksPagerSwipe { model.pagerSwipe }
    /// The bottom stack's height: the add bar, plus the selection bar, a
    /// paste offer or an error line while they show.
    @State private var bottomControlsHeight: CGFloat = TasksViewport.reservedStack
    /// The bottom stack's measured height, observed only by the viewport's
    /// fade and the notice clearance: a keystroke that shows the strip
    /// redraws those, never the page and its 500 rows (round 4: the first
    /// keystroke's cost). Held in `@State`, not `@StateObject`, so the page
    /// itself does not observe it.
    @State private var bottomStack = TasksBottomStackHeight()

    /// `pointer` is the page's own unless a test hands one in to read the
    /// rows' frames and place a press (round 12).
    init(model: TasksPageModel, store: TaskStore, layout: PanelPageLayout, addBarFocused: Binding<Bool>,
         chrome: TasksPageChrome = TasksPageChrome(), pointer: TasksPointer = TasksPointer()) {
        self.model = model
        self.store = store
        self.layout = layout
        _addBarFocused = addBarFocused
        self.chrome = chrome
        _pointer = State(initialValue: pointer)
    }

    static let space = NamedCoordinateSpace.named("AtticTasksPage")
    #if DEBUG
    /// Hosted scroll-frame regression, alongside PanelHeader and AtticAddBar.
    static var tabsEvaluations = 0
    #endif

    /// The row that has the keyboard on the page shown, if any. The focus
    /// state is qualified by page (round 12: a task Now keeps under
    /// "Completed today" and its copy on Done are two rows), so a copy
    /// on another page never answers for it.
    private var focusedID: UUID? {
        focusedRow.flatMap { $0.page == model.tab.rawValue ? $0.id : nil }
    }

    /// Gives the keyboard to `id` on the page shown (nil lets it go).
    private func setFocus(_ id: UUID?) {
        focusedRow = id.map { AtticRowFocusID(page: model.tab.rawValue, id: $0) }
    }

    /// The tabs sit 14 below the header, which moves inward with larger
    /// corners, so the gap under the header stays the same.
    private var tabsTop: CGFloat { layout.headerBottom + AtticLayout.pageTabsTop }

    /// Room under the list for the add bar and its margins.
    static let footerZone: CGFloat = AtticControlSize.addBarHeight + AtticSpacing.panelMargin * 2
    private var footerZone: CGFloat { Self.footerZone }
    /// The list clears the add bar by at least 16 pt (visual A); the rest
    /// of the height flexes.
    static let listFooter: CGFloat = AtticControlSize.addBarHeight + AtticStyle.chromeMinimumInset + AtticLayout.contentToAddBar

    var body: some View {
        // The page's own state changed (or it is new): its content redraws.
        // The focus owner alone redraws for focusable views coming and
        // going, and the content again only when the focused row changes.
        let generation = TasksRowFocusLink.nextGeneration()
        TasksRowFocusOwner { [rowFocus] focus in
            let _ = rowFocus.binding = focus
            TasksPageFocusedContent(generation: generation, focusedRow: focus.wrappedValue) {
                // In three parts (round 10: one chain was too long for the
                // compiler to type-check in time on CI).
                observingModel(observingEdits(frame))
            }
            .equatable()
        }
    }

    /// The page, its overlays, its keys and its monitors.
    private var frame: some View {
        // A15: each list runs under the controls and fades there. The
        // controls retain their page-level layer and hit points; the lifted
        // card stays above both.
        ZStack(alignment: .top) {
            // Clean cut with the scroll-under fade (A15). The native soft
            // edge stays off. Round 4 (owner): the rows dissolve into the
            // panel's top and bottom edges, once for the whole pager.
            pager
            // The controls float over the lists in both, in the page's own
            // layer.
            tabsBand
            tabs
        }
        // The neighbours are drawn only as they slide in, never past the
        // page's edge (the panel's shadow margin lies beyond it). Here, not
        // on the pager, so the lists still run under the controls.
        .clipped()

        // A reorder's lifted card, over everything on the page.
        // (A preview's `ATTIC_UI_TEST_LIFT=off` leaves the layer out: an A/B
        // switch.)
        .overlay {
            if AtticPreviewOverrides.current.drawsLiftLayer {
                TasksLiftedCardLayer(lift: pointer.liftedCard) { lift in liftedCardRow(lift) }
            }
        }
        // Files dropped on a row attach to its task (the "Add to page"
        // label shows on the row under them): one destination for the page,
        // which finds the row from the rows' frames.
        .tasksFileDrop(delegate: TasksFileDropDelegate(
            target: { point in fileDropTarget(at: point) },
            canAccept: { content, id in content == .files && store.attachmentOwnerID(for: id) != nil },
            setTargeted: { id in
                let row = id.map { TasksRowID(tab: model.tab, id: $0) }
                if fileDropRow != row { fileDropRow = row }
            },
            perform: { content, providers, id in attachDroppedFiles(content, providers, to: id) }
        ))
        // The bottom stack owns its whole band (round 7, R4): a row scrolled
        // under the strip, the gaps between its buttons, a selection bar or
        // the add bar is never clicked, right-clicked or dragged through it.
        .overlay(alignment: .bottom) {
            TasksBottomBand(stack: bottomStack, bottomInset: bottomInset)
        }
        .overlay(alignment: .bottom) { bottomControls }
        .coordinateSpace(Self.space)
        .atticKeyboardFocusTracking(focusTracker)
        .environment(\.atticFocusRequests, focusRequests)
        .onKeyPress(phases: .down) { press in pageKey(press) }
        .onAppear { pageAppeared() }
        .onDisappear {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
            if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor) }
            rightClickMonitor = nil
            if let findMonitor { NSEvent.removeMonitor(findMonitor) }
            findMonitor = nil
        }
        // The page's own view, so a press is placed from its event (its
        // window, its location), never from a remembered hover point.
        .background(TasksPointerProbe(pointer: pointer).accessibilityHidden(true))
        #if DEBUG
        // UI tests read how many drags out began and ended.
        .overlay(alignment: .topLeading) {
            if Self.exposesDragOutState { TasksDragOutStateProbe() }
        }
        #endif
    }

    private func pageAppeared() {
        model.resetForReveal()
        // The page opens where the tab is, without a slide.
        model.showPagerPage(animated: false)
        // The settle steps on this page's display (round 11).
        swipe.motion.clockView = { [pointer] in pointer.view }
        swipe.onCancel = { [weak model] in
            // After the navigation that cancelled it has chosen its tab.
            DispatchQueue.main.async { model?.showPagerPage() }
        }
        chrome.bottomControlsHeight(footerZone)
        // After the first frame: the parser's and the date words' first
        // use (formatters, calendars) happens here, not in the first
        // keystroke (round 4).
        DispatchQueue.main.async { model.warmUpShorthand() }
        #if DEBUG
        // Capture seam (`ATTIC_UI_TEST_META=date|tags`, optionally
        // `@<seconds>`, 2.5 by default): a row's date or tag list opens by
        // itself for hands-off captures and the on-screen performance gate,
        // which also closes it after `ATTIC_UI_TEST_META_CLOSE` seconds.
        let environment = ProcessInfo.processInfo.environment
        if let seam = environment["ATTIC_UI_TEST_META"] {
            let parts = seam.split(separator: "@", maxSplits: 1).map(String.init)
            let kind = parts.first ?? seam
            let delay = parts.count > 1 ? Double(parts[1]) ?? 2.5 : 2.5
            let close = environment["ATTIC_UI_TEST_META_CLOSE"].flatMap(Double.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let rows = model.rows(for: model.tab)
                if kind == "date", let row = rows.first(where: { $0.model.due != nil && $0.model.state != .inProgress }) {
                    PerformanceSignposts.noteInput("picker-open date")
                    openMeta(.date, on: row.id)
                } else if kind == "tags", let row = rows.first(where: { !$0.model.tags.isEmpty }) {
                    PerformanceSignposts.noteInput("picker-open tags")
                    openMeta(.tags, on: row.id)
                } else {
                    return
                }
                if let close {
                    DispatchQueue.main.asyncAfter(deadline: .now() + close) {
                        PerformanceSignposts.noteInput("picker-close")
                        metaPopover = nil
                    }
                }
            }
        }
        #endif
        if findMonitor == nil {
            findMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                findPressed(event) || viewOptionsPressed(event) || searchEscapePressed(event) || searchDownPressed(event)
                    || editorEscapePressed(event) || pageEscapePressed(event) || undoPressed(event) || taskShortcutPressed(event)
                    || tabPressed(event)
                    ? nil : event
            }
        }
        if scrollMonitor == nil {
            // The pager reads scroll events itself (round 9): a
            // horizontal swipe over the lists is its own, every other
            // scroll goes on to the list (or the panel) untouched.
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [model, pointer, swipe, bottomStack, listProxies] event in
                // Gated before any state is read (round 10): a page that
                // is not shown, or not in this event's visible window,
                // takes nothing, not even a gesture it owned before.
                guard model.isPageShown, let window = pointer.view?.window, window.isVisible,
                      event.window === window else { return event }
                let allowed = Self.pagerTakes(event, pointer: pointer, band: swipe.band,
                                              stackHeight: bottomStack.height, pageShown: model.isPageShown)
                if event.phase == .began { PerformanceSignposts.noteInput("scroll-began") }
                let sample = TasksPagerSwipe.Sample(event)
                let consumed = model.pagerScrolled(sample, allowed: allowed)
                listProxies.apply(TasksScrollerRule.change(phase: sample.phase, momentum: sample.momentum, axis: swipe.axis))
                return consumed ? nil : event
            }
        }
        if rightClickMonitor == nil {
            // Every mouse press: a secondary click or a Control-click
            // binds the menu about to open to its row; any other press
            // ends the last menu's binding (round 4, Astra's final 3).
            rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
                mousePressed(event)
                return event
            }
        }
    }

    /// What the editors, fields and pickers change.
    private func observingEdits<Content: View>(_ content: Content) -> some View {
        content
        .onChange(of: addBarFocused) { _, focused in
            updateTypingLock()
            // A field that takes the keyboard takes it from the list: a row
            // left holding focus pulled it back (computer-use bug 2).
            if focused { focusedRow = nil }
            // A draft of only spaces is no draft: the placeholder returns
            // (bug 7).
            // Leaving a bar with no words also lets its strip picks go (round
            // 7: they came back unseen with the next keystroke).
            if !focused, model.addBar.text.trimmingCharacters(in: .whitespaces).isEmpty,
               !model.addBar.text.isEmpty || model.addBar.picked != TaskAddBarText.Picks() {
                model.addBarState.clearDraft()
            }
        }
        .onChange(of: searchFocused) { _, focused in
            updateTypingLock()
            // Into the search, however it got there (the magnifier, ⌘F,
            // typing, or a click back into a search already open): no row
            // stays lit behind it (round 7, R3).
            if focused {
                focusedRow = nil
                if !model.selection.isEmpty { model.clearSelection() }
            }
        }
        // Hidden behind another page, the search lets the keyboard go: its
        // pending focus is cancelled and nothing typed reaches it (R2).
        .onChange(of: model.isPageShown) { _, shown in
            if !shown, searchFocused { searchFocused = false }
        }
        .onChange(of: composerPickerOpen) { _, _ in updateTypingLock() }
        .onChange(of: metaPopover) { old, new in
            updateTypingLock()
            // Move to Task… closed by Esc or a click outside, its subtask
            // still on the line it was opened from: the keyboard goes back
            // to that line (A8 P3-A8-1: it went nowhere). The dropdown hands
            // AppKit's first responder back to the panel; the line's focus is
            // SwiftUI's own. A choice moves the subtask and the keyboard to
            // its parent itself.
            guard let subtask = Self.subtaskToRefocus(closed: old, now: new), let old else { return }
            DispatchQueue.main.async {
                guard model.isPageShown, model.tab == old.tab, !AtticTextInput.hasKeyboard,
                      model.rows(for: old.tab).contains(where: { $0.id == old.id && $0.subtasks.contains { $0.id == subtask } })
                else { return }
                focusRequests.focus(AtticSubtaskFocusID(id: subtask))
            }
        }
        .onChange(of: selectionPicker) { _, _ in updateTypingLock() }
        // VoiceOver hears how many are selected as the selection grows or
        // shrinks past one (round 10).
        .onChange(of: model.selection.count) { old, new in
            guard new > 1 || old > 1 else { return }
            if new < 2 { selectionPicker = nil }
            AccessibilityNotification.Announcement(new > 1 ? String(localized: "\(new) selected") : String(localized: "Selection cleared")).post()
        }
        .onChange(of: model.editingTitleID) { _, id in
            updateTypingLock()
            // The row gives up the keyboard so its title field can take it.
            if id != nil { focusedRow = nil }
        }
        .onChange(of: model.newSubtaskParentID) { _, id in
            updateTypingLock()
            if id != nil { focusedRow = nil }
        }
        .onChange(of: model.renamingSubtaskID) { _, id in
            updateTypingLock()
            if id != nil { focusedRow = nil }
        }
    }

    /// What the model and the view's own state change.
    private func observingModel<Content: View>(_ content: Content) -> some View {
        content
        // An agent's `show`: the row it brought into view takes the
        // keyboard (round 5, F3), once the list has it.
        .onChange(of: model.scrollRequest) { _, request in
            takeScrollRequest(in: model.tab)
            guard let request else { return }
            let destination = request.tab ?? model.tab
            DispatchQueue.main.async {
                guard model.tab == destination else { return }
                setFocus(request.id)
            }
        }
        // A page or tab change ends a drag, closes a row's pickers and ends
        // a menu's binding.
        .onChange(of: model.hides) { _, _ in cancelTransientState() }
        // A row's picker goes with its row (H10-03): its card closed with
        // the anchor, and the page leaves edit mode with it.
        .onChange(of: store.revision) { _, _ in closePickerOfAMissingRow() }
        // A menu opening decides whether the last press opened it: if not
        // (the keyboard, VoiceOver, another menu), no earlier binding holds.
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            pointer.menuBegan(with: NSApp.currentEvent)
        }
        .onChange(of: model.tab) { _, _ in
            cancelTransientState()
            // Each page keeps its own query; the field lets the keyboard go
            // with the page it searched (read when the change lands: a
            // search opened on the new page meanwhile keeps it).
            if searchFocused, searchTab != model.tab { searchFocused = false }
            // The last page's row keeps no claim on the keyboard.
            focusedRow = nil
            // A tab, a key, ⌘1–3, `show` or Search: the page goes straight
            // there. A swipe's own live tab leaves the page with the fingers.
            if !swipe.isTracking { model.showPagerPage() }
        }
        // What the scroll monitor reads that lives in the view.
        .onChange(of: design.reduceMotion, initial: true) { _, reduced in swipe.reduced = reduced }
        .onChange(of: drag != nil, initial: true) { _, dragging in
            swipe.dragActive = dragging
            // However the drag ended (a page change, a hide), the card goes.
            if !dragging { pointer.liftedCard.end() }
        }
        .onChange(of: pagerBand, initial: true) { _, band in swipe.band = band }
        .onChange(of: focusedRow) { _, focus in
            // Tab reached a row of a page kept built beside the one shown
            // (hidden, so nothing showed where the keyboard was): the
            // keyboard goes on to the shown page's rows or the add bar.
            if let focus, model.isPageShown, focus.page != model.tab.rawValue,
               let page = TasksTab(rawValue: focus.page) {
                keepKeyboardOnShownPage(arrivedOn: page)
                return
            }
            // The rows draw the keyboard's ring from the model's copy of
            // the focus (deep review P2-04): a lazy list's cell reading the
            // page's focus state read it as it was when the list was built
            // (nil; measured in the hosted page), so the row that had the
            // keyboard drew no ring, by Tab or by an arrow. The cells redraw
            // on the model's changes only (round 11), and a focus change is
            // not one, so they are told here; each compares its snapshot,
            // and only the rows whose focus changed rebuild.
            model.keyboardFocus = focus
            model.cellUpdates.objectWillChange.send()
            pointer.keyboardRow = focus.flatMap { focus in
                TasksTab(rawValue: focus.page).map { TasksRowID(tab: $0, id: focus.id) }
            }
            // Done's rows come into view as the keyboard reaches them too.
            guard let id = focus?.id, focus?.page == TasksTab.done.rawValue, model.tab == .done,
                  focusTracker.isKeyboardDriving else { return }
            doneReveal = TasksPageModel.ScrollRequest(id: id, tab: .done)
        }
        // Find, or a view, changes what a list holds: the list starts at
        // its top, at the first match (deep review P2-01: a query typed
        // far down a long list left an empty viewport past the matches).
        .onChange(of: model.trimmedQuery(for: .now)) { _, _ in showListTop(.now) }
        .onChange(of: model.trimmedQuery(for: .backlog)) { _, _ in showListTop(.backlog) }
        // Done's query is published to the Done page alone: its own watcher.
        .background(TasksDoneQueryWatcher(results: model.doneResults, model: model, changed: { showListTop(.done) },
                                          applied: { if drawnSearch.shown != searchShown { searchRedraw &+= 1 } }))
        .onChange(of: model.viewOptions(for: .now)) { _, _ in showListTop(.now) }
        .onChange(of: model.viewOptions(for: .backlog)) { _, _ in showListTop(.backlog) }

        // Search (the menu-bar item): the keyboard goes to the Done page's
        // search field on the tabs' line, not the add bar.
        .onChange(of: model.pendingSearchFocus, initial: true) { _, pending in
            guard pending else { return }
            model.pendingSearchFocus = false
            beginSearch()
        }
        // The shell's toast and notices sit above everything in the bottom
        // stack, so a selection bar or paste offer never hides under them.
        .background(TasksNoticeClearance(stack: bottomStack, footerZone: footerZone))
    }

    /// Tab or Shift-Tab moved the keyboard into a row of a page kept built
    /// beside the one shown (deep review P2-04: a Tab stop with nothing to
    /// show for it, since that page is hidden). It goes where the next
    /// visible stop is, in the direction it was travelling: past a page
    /// after the shown one, on to the add bar (Tab) or back to the shown
    /// page's last row (Shift-Tab); past a page before it, on to the shown
    /// page's first row (Tab) or back to the add bar (Shift-Tab, wrapping
    /// as the window's key loop does).
    private func keepKeyboardOnShownPage(arrivedOn page: TasksTab) {
        let event = NSApp.currentEvent
        let backward = event?.type == .keyDown && event?.modifierFlags.contains(.shift) == true
        let order = TasksTab.allCases
        let after = (order.firstIndex(of: page) ?? 0) > (order.firstIndex(of: model.tab) ?? 0)
        let rows = visibleIDs()
        focusTracker.noteKeyboardNavigation()
        if backward == after, let row = backward ? rows.last : rows.first {
            setFocus(row)
        } else {
            focusedRow = nil
            addBarFocused = true
        }
    }

    /// A list whose rows a query or a view changed: back to its top, where
    /// its first match is (deep review P2-01). Once the list has laid out
    /// what it now holds (the next turn); a list not built starts at its
    /// top when it is.
    private func showListTop(_ tab: TasksTab) {
        model.scrollOffsets[tab] = nil
        DispatchQueue.main.async { [listProxies] in
            guard let scroll = listProxies.scrollViews[tab] else { return }
            TasksScrollKeeper.scrollToTop(scroll)
        }
    }

    /// A `show`'s scroll request, taken once by the list that holds its
    /// row, as soon as that list is built (round 10).
    private func takeScrollRequest(in tab: TasksTab) {
        guard let proxy = listProxies.lists[tab] else { return }
        let ids = tab == .done ? model.doneDays().flatMap { $0.rows.map(\.id) } : model.rows(for: tab).map(\.id)
        guard let request = model.claimScrollRequest(holding: ids, in: tab) else { return }
        let place = rowPlace(request.id, in: tab)
        DispatchQueue.main.async { [listProxies] in
            // The list's own AppKit scroll view first, to the row's place
            // from the rows' heights (a lazy list has not built a far row
            // yet); then SwiftUI's scroll to the row itself, which centres
            // it exactly once it is built.
            if let place, let scroll = listProxies.scrollViews[tab] { TasksScrollKeeper.centre(place, in: scroll) }
            scroll(proxy, to: request.id, in: tab, anchor: .center)
        }
    }

    /// Scrolls a list to `id`'s row: on Done, to the line that draws it
    /// (`TasksDoneSlots`).
    private func scroll(_ proxy: ScrollViewProxy, to id: UUID, in tab: TasksTab, anchor: UnitPoint? = nil) {
        if tab == .done, let line = doneSlots.line(for: id) {
            proxy.scrollTo(line, anchor: anchor)
        } else {
            proxy.scrollTo(id, anchor: anchor)
        }
    }

    /// Whether Done's rows hold nothing of their own, so a new query's rows
    /// may come up in the views that drew the last query's
    /// (`TasksDoneSlots`): no keyboard focus, selection, editor, pop-over,
    /// details, drag or file on them, the pointer over none of them, and
    /// VoiceOver off. Otherwise each task's row is drawn by its own view.
    private func doneRowsAreInterchangeable() -> Bool {
        let done = TasksTab.done.rawValue
        return !NSWorkspace.shared.isVoiceOverEnabled
            && drag == nil && metaPopover == nil && fileDropRow == nil
            && model.selection.isEmpty && model.doneDetailID == nil && model.editingTitleID == nil
            && model.renamingSubtaskID == nil && model.newSubtaskParentID == nil
            && focusedRow?.page != done && model.keyboardFocus?.page != done
            && !pointer.isOverRow(on: .done)
    }

    /// A row's top and height in its list's content, from the heights of
    /// the rows (and headings) before it.
    private func rowPlace(_ id: UUID, in tab: TasksTab) -> (top: CGFloat, height: CGFloat)? {
        var top: CGFloat = 0
        if tab == .done {
            for day in model.doneDays() {
                top += AtticLayout.rowPitch
                for row in day.rows {
                    let height = pointer.frames[TasksRowID(tab: .done, id: row.id)]?.height ?? AtticLayout.rowPitch
                    if row.id == id { return (top, height) }
                    top += height
                }
            }
            return nil
        }
        let sections = model.sections(for: tab)
        if model.viewOptions(for: tab).filters, model.trimmedQuery(for: tab).isEmpty { top += AtticLayout.rowPitch }
        for row in sections.open {
            if row.id == id { return (top, rowHeight(id, in: tab)) }
            top += rowHeight(row.id, in: tab)
        }
        guard tab == .now, !sections.done.isEmpty else { return nil }
        top += AtticCompletedLineMetrics.top + AtticCompletedLineMetrics.height + AtticSpacing.s4
        for row in sections.done {
            if row.id == id { return (top, rowHeight(id, in: tab)) }
            top += rowHeight(row.id, in: tab)
        }
        return nil
    }

    /// The panel must stay open while someone types or picks in it: the add
    /// bar, Done's search, a title or new subtask, or an open picker (which
    /// may reach past the panel, review 16).
    private func updateTypingLock() {
        // A field with the keyboard and nothing open: a hold that lapses
        // once the pointer has left and the keyboard is idle.
        chrome.typingLock(addBarFocused || searchFocused)
        // Edit mode (round 5, the owner's item 2): a title or subtask
        // editor, the strip's pickers, a row's date or tag picker. The panel
        // stays until it closes, wherever the pointer goes. Context menus
        // hold it through the shell's menu-tracking lock; suggestions show
        // only over a draft, which the composer lock holds.
        chrome.editLock(model.editingTitleID != nil || model.newSubtaskParentID != nil || model.renamingSubtaskID != nil
            || composerPickerOpen || metaPopover != nil || selectionPicker != nil)
    }

    /// When a change elsewhere (an agent's delete or move) takes the row of
    /// an open date, tag or Move to Task list out of its page, the list is
    /// closed: its card already left with the row, and an open one holds
    /// the panel and the page's keys (H10-03).
    private func closePickerOfAMissingRow() {
        guard let open = metaPopover else { return }
        let hasAnchor: Bool
        if open.tab == .done {
            let task = store.listedTask(withID: open.id)
            let query = model.doneSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            hasAnchor = task?.status == .done && (query.isEmpty || task?.title.localizedStandardContains(query) == true)
        } else {
            hasAnchor = model.rows(for: open.tab).contains { $0.id == open.id }
        }
        let hasTargets = open.targets.allSatisfy { store.listedTask(withID: $0) != nil }
        let hasChild = open.kind != .move || (model.expanded.contains(open.id)
            && open.targets.allSatisfy { store.task(withID: $0)?.parentID == open.id })
        if !hasAnchor || !hasTargets || !hasChild { metaPopover = nil }
    }

    /// A drag in progress and a row's pickers end when the panel hides or
    /// the page changes (review 1); nothing stays lifted.
    private func cancelTransientState() {
        cancelDrag()
        if metaPopover != nil { metaPopover = nil }
        if selectionPicker != nil { selectionPicker = nil }
        pointer.endInvocation()
    }

    // MARK: - Tabs

    /// Now · Later · Done under the header, in place of a title and the
    /// page pill. The tabs stay put while the pages swipe under them. A
    /// magnifier sits at the line's end on every page (owner item 17, card B
    /// of v22; follow-up part 2, item 6), and on Now and Later View Options
    /// after it; while searching, the search field takes the line.
    private var tabs: some View {
        #if DEBUG
        Self.tabsEvaluations += 1
        #endif
        return ZStack(alignment: .topLeading) {
            // ⌥⌘V's anchor where View Options sits, mounted whatever the
            // line shows: Find takes the line, and the button and its own
            // anchor with it (GPT-6.1's review: the key did nothing then).
            AtticMenuAnchor(holder: viewOptionsAnchor)
                .frame(width: AtticControlSize.smallMinWidth, height: AtticControlSize.smallHeight)
                .padding(.trailing, lineEndInset)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, tabsTop + (AtticLayout.pageTabsHeight - AtticControlSize.smallHeight) / 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            let _ = searchRedraw
            if drawnSearchShown {
                Group {
                    if model.tab == .done {
                        TasksDoneSearchField(model: model, input: model.doneSearchInput,
                                             isFocused: $searchFocused, onEscape: endSearch)
                    } else {
                        AtticTabsSearchField(placeholder: model.searchPlaceholder(for: model.tab),
                                             text: Binding(get: { model.searchQuery(for: model.tab) },
                                                           set: { model.setSearchQuery($0, for: model.tab) }),
                                             isFocused: $searchFocused, onEscape: endSearch)
                    }
                }
                    .accessibilityIdentifier(model.tab == .done ? "tasks-done-search" : "tasks-find")
                    .id(model.tab)
                    // Centred on the tabs' line.
                    .padding(.top, tabsTop - (AtticControlSize.smallHeight - AtticLayout.pageTabsHeight) / 2)
                    // It comes in from the magnifier's end, the tabs leave
                    // toward the other (round 9: springy, a fade when
                    // motion is reduced).
                    .transition(AtticMotionPreset.popover.transition(reduceMotion: design.reduceMotion, edge: .trailing))
            } else {
                HStack(spacing: 0) {
                    AtticPageTabs(
                        items: TasksTab.allCases.map { tab in
                            AtticPageTabs.Item(page: tab, title: tab.title, accessibilityIdentifier: "tasks-page-\(tab.identifier)")
                        },
                        selection: Binding(get: { model.tab }, set: { model.select(tab: $0) })
                    )
                    .accessibilityIdentifier("tasks-page-tabs")
                    .padding(.leading, AtticLayout.pageTabsX)
                    Spacer(minLength: 0)
                    // Find (⌘F) on every page: Done's magnifier.
                    // Quiet icons (D-10): the labels' own grey, primary only when on.
                    AtticSmallButton(systemName: "magnifyingglass",
                                     label: model.tab == .done ? "Search done tasks (⌘F)" : "Find (⌘F)",
                                     quietIcon: true, action: beginSearch)
                        .accessibilityIdentifier(model.tab == .done ? "tasks-done-search-button" : "tasks-find-button")
                        .padding(.trailing, model.tab == .done ? lineEndInset : 0)
                    if model.tab != .done {
                        // View Options (⌥⌘V): a second quiet icon, its dot
                        // while a filter hides tasks.
                        let view = model.viewOptions(for: model.tab)
                        AtticMenuButton(systemName: "line.3.horizontal.decrease", label: "View Options (⌥⌘V)",
                                        commands: { viewCommands(for: model.tab) },
                                        showsDot: view.filters, value: view.spokenValue,
                                        quietIcon: !view.filters)
                            .accessibilityIdentifier("tasks-view-options")
                            .padding(.trailing, lineEndInset)
                            // It pops in where it sits (a fade in Calm).
                            .transition(AtticMotionPreset.popover.transition(reduceMotion: design.reduceMotion, edge: nil))
                    }
                }
                .frame(height: AtticLayout.pageTabsHeight)
                .padding(.top, tabsTop)
                .transition(AtticMotionPreset.popover.transition(reduceMotion: design.reduceMotion, edge: .leading))
            }
        }
        .padding(.horizontal, cornerInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The search springs in and leaves at once (its field lets the
        // keyboard go with it).
        .animation(searchShown ? AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion)
                               : AtticMotionPreset.popover.exit(reduceMotion: design.reduceMotion), value: searchShown)
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion, showing: model.tab == .done),
                   value: model.tab == .done)
        .onChange(of: searchShown) { _, _ in PerformanceSignposts.watchFrames("SearchMotion", seconds: 0.35) }
    }

    /// The last icon's glyph ends where the rows' dates end.
    private var lineEndInset: CGFloat {
        max(0, AtticLayout.rowHighlightInset + AtticTaskRowMetrics.dateInset
            - (AtticControlSize.smallMinWidth - AtticSmallControlMetrics.iconSize) / 2)
    }

    /// The search is on the tabs' line while it has the keyboard or a
    /// query (owner item 17; every page since item 6); Esc, or clearing and
    /// leaving, returns the tabs.
    private var searchShown: Bool {
        searchFocused || !model.searchQuery(for: model.tab).isEmpty
    }

    /// `searchShown`, noted as the page draws it (`drawnSearch`).
    private var drawnSearchShown: Bool {
        let shown = searchShown
        drawnSearch.shown = shown
        return shown
    }

    /// View Options (item 6, option A): Show, the priority filter, Sort
    /// by, Reset View; the system's own menu (type-select, Return,
    /// VoiceOver), each choice ticked.
    func viewCommands(for tab: TasksTab) -> [AtticMenuCommand] {
        let view = model.viewOptions(for: tab)
        func set(_ change: @escaping (inout TasksViewOptions) -> Void) -> () -> Void {
            { [model] in
                var next = model.viewOptions(for: tab)
                change(&next)
                model.setViewOptions(next, for: tab)
            }
        }
        var list: [AtticMenuCommand] = [.header(String(localized: "Show"))]
        let shows: [(TasksViewOptions.Show, String)] = [(.all, String(localized: "All Tasks")),
                                                        (.dueOrOverdue, String(localized: "Due or Overdue")),
                                                        (.overdueOnly, String(localized: "Overdue Only"))]
        list += shows.map { show, title in
            AtticMenuCommand(verbatim: title, state: view.show == show ? .on : .off, action: set { $0.show = show })
        }
        let priorities: [(TasksViewOptions.Priority, String)] = [(.any, String(localized: "Any Priority")),
                                                                 (.mediumAndHigh, String(localized: "Medium and High")),
                                                                 (.highOnly, String(localized: "High Only"))]
        list += priorities.enumerated().map { index, entry in
            AtticMenuCommand(verbatim: entry.1, startsSection: index == 0, state: view.priority == entry.0 ? .on : .off,
                             action: set { $0.priority = entry.0 })
        }
        list.append(.header(String(localized: "Sort by")))
        let sorts: [(TasksViewOptions.Sort, String)] = [(.manual, String(localized: "Manual Order")),
                                                        (.dueDate, String(localized: "Due Date")),
                                                        (.priority, String(localized: "Priority"))]
        list += sorts.map { sort, title in
            AtticMenuCommand(verbatim: title, state: view.sort == sort ? .on : .off, action: set { $0.sort = sort })
        }
        list.append(AtticMenuCommand(verbatim: String(localized: "Reset View"), isDisabled: view.isDefault, startsSection: true) {
            [model] in model.setViewOptions(TasksViewOptions(), for: tab)
        })
        return list
    }

    /// ⌥⌘V, or a click on the button: the menu under the button.
    private func openViewOptions() {
        guard model.tab != .done, let anchor = viewOptionsAnchor.view, anchor.window != nil else { return }
        swipe.cancel()
        if let open = pointer.openViewOptions {
            open(anchor)
            return
        }
        AtticNativeMenu.popUp(viewCommands(for: model.tab), in: anchor)
    }

    /// ⌥⌘V on Now or Later while this page is shown in its key window,
    /// with no editor or pop-over open (the add bar or Find may have the
    /// keyboard: the key is never theirs). True when it took the key.
    private func viewOptionsPressed(_ event: NSEvent) -> Bool {
        guard Self.answersViewOptions(event: event, pageShown: model.isPageShown, tab: model.tab,
                                      pageWindow: pointer.view?.window, popoverOpen: AtticTextInput.isPopoverOpen),
              model.editingTitleID == nil, model.newSubtaskParentID == nil, model.renamingSubtaskID == nil,
              metaPopover == nil, drag == nil else { return false }
        openViewOptions()
        return true
    }

    /// Whether ⌥⌘V belongs to View Options (pure, tested directly).
    static func answersViewOptions(event: NSEvent, pageShown: Bool, tab: TasksTab, pageWindow: NSWindow?, popoverOpen: Bool) -> Bool {
        guard pageShown, tab != .done, !popoverOpen, let pageWindow, event.window === pageWindow, pageWindow.isKeyWindow,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command, .option],
              event.keyCode == 9 || event.charactersIgnoringModifiers?.lowercased() == "v" else { return false }
        return true
    }

    /// The magnifier, ⌘F, typing on the Done page, or the menu bar's
    /// Search: the keyboard goes to the search field on the tabs' line.
    private func beginSearch() {
        // Every way into the search is an explicit choice of page: a swipe
        // in progress ends here (round 10, Astra's round 9 check).
        swipe.cancel()
        addBarFocused = false
        // No row stays lit behind the search (round 5, the owner's item 16).
        focusedRow = nil
        model.clearSelection()
        searchTab = model.tab
        searchFocused = true
    }

    /// ⌘F while this page is the one the shell shows, on any page (Done's
    /// search, Now's and Later's Find), in its own key window, with no
    /// pop-over open: the search takes the tabs' line.
    /// True when it took the key. A Tasks page kept built behind Notes or
    /// Canvas never answers (round 7, R2).
    private func findPressed(_ event: NSEvent) -> Bool {
        guard Self.answersFind(event: event, pageShown: model.isPageShown, tab: model.tab,
                               pageWindow: pointer.view?.window, popoverOpen: AtticTextInput.isPopoverOpen) else { return false }
        beginSearch()
        return true
    }

    /// Esc in a subtask's field (a new one, or a rename): it stops. Here,
    /// as for the Done search: the panel's hosting view answers Esc itself,
    /// so the field's exit command did not always reach it (round 10, CI
    /// run 3: the new-subtask field stayed open and the quick look with it).
    private func editorEscapePressed(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
              model.isPageShown, !AtticTextInput.isPopoverOpen, let window = pointer.view?.window, event.window === window,
              !Self.isComposing(window.firstResponder), (window.firstResponder as? NSTextView)?.isFieldEditor == true else { return false }
        if let parent = model.newSubtaskParentID {
            model.cancelEditing()
            setFocus(parent)
            return true
        }
        if model.renamingSubtaskID != nil {
            model.cancelSubtaskRename()
            return true
        }
        return false
    }

    /// Move to Task…'s subtask when its pop-over has just closed (A10).
    nonisolated static func subtaskToRefocus(closed old: TasksMetaPopover?, now new: TasksMetaPopover?) -> UUID? {
        guard new == nil, let old, old.kind == .move else { return nil }
        return old.targets.first
    }

    // MARK: Tab

    /// Tab and ⇧Tab walk the page's own order (A10, `TasksTabOrder`): the
    /// panel's key loop is AppKit's (`AtticPanelHostingView`, the import
    /// freeze), and AppKit's loop took the keyboard to rows out of view, with
    /// no ring and no scroll, and stopped on nothing. Every stop here is
    /// drawn: a row scrolls into view and shows its ring as it is reached.
    /// Asked at the key press only, never during layout. Editors, pickers,
    /// the add bar's suggestions and an input method keep their own Tab.
    private func tabPressed(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 48 else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers.isEmpty || modifiers == .shift,
              model.isPageShown, let window = pointer.view?.window, event.window === window, window.isKeyWindow,
              !AtticTextInput.isPopoverOpen, !Self.isComposing(window.firstResponder),
              model.editingTitleID == nil, model.newSubtaskParentID == nil, model.renamingSubtaskID == nil,
              metaPopover == nil, selectionPicker == nil, !composerPickerOpen, drag == nil else { return false }
        // A field of another kind keeps its Tab; the add bar's suggestion
        // list takes it (review 15).
        if AtticTextInput.hasKeyboard, !addBarFocused, !searchFocused { return false }
        if addBarFocused, TasksAddBar.showsSuggestion(model: model, text: model.addBarState) { return false }
        let stops = tabStops()
        let current = currentTabStop(in: stops)
        guard let next = TasksTabOrder.next(after: current, in: stops, forward: modifiers.isEmpty) else { return false }
        focusTracker.noteKeyboardNavigation()
        moveKeyboard(to: next, from: current, in: stops)
        return true
    }

    /// The page's stops as drawn now (`TasksTabOrder.stops`).
    private func tabStops() -> [TasksTabStop] {
        let tab = model.tab
        let ids = visibleIDs()
        var open: [UUID: [UUID]] = [:]
        if tab != .done, !model.expanded.isEmpty {
            for row in model.rows(for: tab) where model.expanded.contains(row.id) && row.status != .done {
                open[row.id] = row.subtasks.map(\.id)
            }
        }
        let draft = !model.addBarState.text.text.trimmingCharacters(in: .whitespaces).isEmpty
        return TasksTabOrder.stops(find: searchShown, rows: ids.map { ($0, open[$0] ?? []) },
                                   strip: draft && model.pasteOffer == nil && NSApp.isFullKeyboardAccessEnabled)
    }

    /// Where the keyboard is among `stops`, if it is on one.
    private func currentTabStop(in stops: [TasksTabStop]) -> TasksTabStop? {
        if searchFocused { return .find }
        if addBarFocused { return .addBar }
        if let strip = focusRequests.current?.base as? AtticStripFocusID { return .strip(strip) }
        if let subtask = model.focusedSubtaskID, stops.contains(.subtask(subtask)) { return .subtask(subtask) }
        if let id = focusedID { return .row(id) }
        return nil
    }

    private func moveKeyboard(to stop: TasksTabStop, from current: TasksTabStop?, in stops: [TasksTabStop]) {
        let tab = model.tab
        tabTarget.stop = stop
        switch stop {
        case .find:
            focusedRow = nil
            addBarFocused = false
            searchFocused = true
        case .addBar:
            focusedRow = nil
            searchFocused = false
            addBarFocused = true
        case let .strip(button):
            focusedRow = nil
            searchFocused = false
            addBarFocused = false
            DispatchQueue.main.async { focusRequests.focus(button) }
        case let .row(id):
            searchFocused = false
            addBarFocused = false
            // From a field, or round the end: the list goes to the row's
            // place first (a far row of a lazy list is not built yet).
            if !TasksTabOrder.isListNeighbour(current, of: stop, in: stops),
               let scroll = listProxies.scrollViews[tab], let place = rowPlace(id, in: tab) {
                TasksScrollKeeper.centre(place, in: scroll)
            }
            settleKeyboard(on: stop, in: tab, attempts: Self.tabSettleAttempts, landed: { focusedID == id }, revealing: id) {
                setFocus(id)
            }
        case let .subtask(id):
            focusedRow = nil
            searchFocused = false
            addBarFocused = false
            let parent = TasksTabOrder.parent(of: id, in: stops)
            settleKeyboard(on: stop, in: tab, attempts: Self.tabSettleAttempts, landed: { model.focusedSubtaskID == id },
                           revealing: parent) {
                focusRequests.focus(AtticSubtaskFocusID(id: id))
            }
        }
    }

    /// How many frames Tab's row may take to be built and settle in view.
    static let tabSettleAttempts = 8

    /// Gives `stop` the keyboard (`focus`) and brings row `revealing` into
    /// the list's clear part, a frame at a time until the focus has landed
    /// and the row needs no more scrolling (A10, CI: the list's own reveal
    /// did not run for a focus the page set, and a row a lazy list had not
    /// built could not take the keyboard, which then stayed where it was).
    /// A later Tab, or another page, ends it.
    private func settleKeyboard(on stop: TasksTabStop, in tab: TasksTab, attempts: Int, landed: @escaping () -> Bool,
                                revealing row: UUID?, focus: @escaping () -> Void) {
        tabTarget.stop = stop
        func attempt(_ left: Int) {
            guard tabTarget.stop == stop, model.tab == tab, model.isPageShown else { return }
            if !landed() { focus() }
            var scrolled = false
            if let row, let proxy = listProxies.lists[tab] { scrolled = revealRow(row, in: tab, proxy: proxy, animation: nil) }
            guard left > 1, scrolled || !landed() else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { attempt(left - 1) }
        }
        attempt(attempts)
    }

    /// Esc with no field typing, wherever the keyboard is in the page (a
    /// menu that just closed, a click on the bar or the space under the
    /// rows leaves no row focused, and the list's own key handler never
    /// ran: round 12, CU bug 4, the expanded quick look stayed and the
    /// panel closed). The same chain as the list's.
    private func pageEscapePressed(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53,
              event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
              model.isPageShown, let window = pointer.view?.window, event.window === window, window.isKeyWindow,
              !AtticTextInput.hasKeyboard, !AtticTextInput.isPopoverOpen, !Self.isComposing(window.firstResponder),
              model.editingTitleID == nil, model.newSubtaskParentID == nil, model.renamingSubtaskID == nil,
              !addBarFocused, !searchFocused, metaPopover == nil else { return false }
        let visible = visibleIDs()
        return handleEscape(visible: visible, current: keyboardRow(visible: visible))
    }

    /// Esc's chain (spec § Keyboard map): a drag in progress stops, a Done
    /// detail closes, a search ends, then the open quick look closes (the
    /// keyboard's row, or the only one open) and the keyboard returns to its
    /// row (review UX 2), then a multi-selection clears. False when nothing
    /// was left for Esc to do, so it goes on to the panel.
    private func handleEscape(visible: [UUID], current: UUID?) -> Bool {
        if drag != nil { cancelDrag(); return true }
        if model.tab == .done, model.doneDetailID != nil { model.doneDetailID = nil; return true }
        // A search left with its query: Esc ends it (the tabs return).
        if !model.searchQuery(for: model.tab).isEmpty { endSearch(); return true }
        let open = current.flatMap { model.expanded.contains($0) ? $0 : nil }
            ?? (model.expanded.count == 1 ? model.expanded.first.flatMap { visible.contains($0) ? $0 : nil } : nil)
            ?? model.selection.first { model.expanded.contains($0) && visible.contains($0) }
        if let open {
            toggleExpanded(open)
            setFocus(open)
            return true
        }
        if model.selection.count > 1 { model.clearSelection(); return true }
        return false
    }

    /// ⌘Z and ⇧⌘Z with no field typing: the Tasks history, wherever the
    /// keyboard is in the page (round 10, CI run 3: after a click on the
    /// selection bar no view in the page had the keyboard, so the list's
    /// own ⌘Z never ran). A field that is typing keeps its own.
    private func undoPressed(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, model.isPageShown, let window = pointer.view?.window, event.window === window,
              window.isKeyWindow, !AtticTextInput.hasKeyboard, event.charactersIgnoringModifiers?.lowercased() == "z" else { return false }
        switch event.modifierFlags.intersection([.command, .shift, .option, .control]) {
        case .command: model.undo()
        case [.command, .shift]: model.redo()
        default: return false
        }
        return true
    }

    /// ⌘C, ⌘D and ⇧⌘I on the row the keyboard is on (or the selection):
    /// before any menu sees them (round 10), as ⌘F is, since the app's Edit
    /// menu answers ⌘C itself. ⌘C and ⌘D run the command the row's menu
    /// holds for their key (`taskCommands`), so the key and the menu can
    /// never differ; ⇧⌘I opens that menu. An editor or a picker keeps every
    /// key; the composer and Find keep the keys they act on
    /// (`typingFieldPasses`).
    private func taskShortcutPressed(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, model.isPageShown, let window = pointer.view?.window, event.window === window,
              window.isKeyWindow, model.editingTitleID == nil, model.newSubtaskParentID == nil,
              model.renamingSubtaskID == nil, metaPopover == nil, drag == nil else { return false }
        if AtticTextInput.hasKeyboard || addBarFocused || searchFocused {
            return typingFieldShortcutPressed(event, in: window)
        }
        let shortcuts = [AtticTaskShortcut.actions, AtticTaskShortcut.copy, AtticTaskShortcut.duplicate] + AtticTaskShortcut.priorities
        guard let shortcut = shortcuts.first(where: {
            AtticTaskShortcut.matches($0, characters: event.charactersIgnoringModifiers, keyCode: event.keyCode, modifiers: event.modifierFlags)
        }) else { return false }
        let visible = visibleIDs()
        guard let current = model.shortcutRow(focusedRow: keyboardRow(visible: visible), visible: Set(visible)) else { return false }
        // No right-click's binding decides a key's targets.
        pointer.endInvocation()
        if shortcut == AtticTaskShortcut.actions {
            showActions(for: current, anchor: nil, tab: model.tab)
            return true
        }
        guard let command = AtticMenuCommand.command(for: shortcut, in: taskCommands(current, tab: model.tab)) else { return false }
        command.action()
        return true
    }

    /// The rule for a typing field (the composer, Find) with the keyboard
    /// while rows are selected, as the menu model has it: a key equivalent
    /// goes to the field when the field acts on it, else to the command
    /// that acts on the selection (CU recheck 4b, P2: with the composer
    /// focused, ⇧⌘I and ⌘Return did nothing for a selected Later row).
    /// - The field keeps text editing, ⌘C and ⌘D (the Edit menu's, on its
    ///   text) and ⌥⌘0–3, as before.
    /// - ⇧⌘I, which no typing field acts on, opens the selected row's
    ///   actions.
    /// - ⌘Return stays the composer's while it holds a draft (it adds the
    ///   task and opens it); with no draft to add, and in Find, which has
    ///   no ⌘Return, it opens the selected row's files.
    /// Editors (a title, a subtask) and pickers keep every key.
    static func typingFieldPasses(_ shortcut: KeyboardShortcut, composerDraft: String?) -> Bool {
        if shortcut == AtticTaskShortcut.actions { return true }
        if shortcut == AtticTaskShortcut.openPage {
            return composerDraft?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        }
        return false
    }

    /// `typingFieldPasses` for the composer or Find with the keyboard: the
    /// key runs as the selected row's command, never as the field's key.
    private func typingFieldShortcutPressed(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard addBarFocused || searchFocused, !AtticTextInput.isPopoverOpen, !Self.isComposing(window.firstResponder),
              let shortcut = [AtticTaskShortcut.actions, AtticTaskShortcut.openPage].first(where: {
                  AtticTaskShortcut.matches($0, characters: event.charactersIgnoringModifiers, keyCode: event.keyCode,
                                            modifiers: event.modifierFlags)
              }),
              Self.typingFieldPasses(shortcut, composerDraft: addBarFocused ? model.addBar.text : nil),
              !model.selection.isEmpty else { return false }
        let visible = visibleIDs()
        guard let current = model.shortcutRow(focusedRow: nil, visible: Set(visible)) else { return false }
        pointer.endInvocation()
        if shortcut == AtticTaskShortcut.actions {
            showActions(for: current, anchor: nil, tab: model.tab)
            return true
        }
        guard let command = AtticMenuCommand.command(for: shortcut, in: taskCommands(current, tab: model.tab)) else { return false }
        AtticTextInput.passingToSelection { command.action() }
        return true
    }

    /// Esc with the keyboard in the Done search ends it. Here, not in the
    /// field's exit command: the panel's hosting view answers Esc itself
    /// (it ends a resize or move, else passes it up), so SwiftUI's exit
    /// command never reached the field inside the panel (round 7, found by
    /// the shell test).
    private func searchEscapePressed(_ event: NSEvent) -> Bool {
        guard searchFocused, model.isPageShown, event.keyCode == 53,
              event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
              !AtticTextInput.isPopoverOpen, let window = pointer.view?.window, event.window === window,
              // An input method composing keeps its Esc: it cancels the
              // composition, and only the next Esc ends the search (G2).
              !Self.isComposing(window.firstResponder) else { return false }
        endSearch()
        return true
    }

    /// Whether a mouse event lands on the page's search field itself.
    static func isOnSearchField(_ event: NSEvent, in window: NSWindow, placeholder: String) -> Bool {
        guard let content = window.contentView,
              let field = AtticTabsSearchField.searchField(in: content, placeholder: placeholder) else { return false }
        return field.bounds.contains(field.convert(event.locationInWindow, from: nil))
    }

    /// The responder is a text view with marked text (an input method
    /// composing).
    static func isComposing(_ responder: NSResponder?) -> Bool {
        (responder as? NSTextView)?.hasMarkedText() == true
    }

    /// Where the pager takes a swipe or a wheel: over the lists, between
    /// the tabs' band and the bottom stack's (the header, the tabs and the
    /// add bar keep theirs; over the header a swipe toward the panel's
    /// edge still hides the panel), on the page the shell shows, with no
    /// ⌘, ⌥ or ⌃ held.
    static func pagerTakes(_ event: NSEvent, pointer: TasksPointer, band: TasksPagerBand, stackHeight: CGFloat,
                           pageShown: Bool) -> Bool {
        guard pageShown, event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let point = pointer.location(of: event), let view = pointer.view else { return false }
        return band.contains(point, height: view.bounds.height, stackHeight: stackHeight)
    }

    /// The pager's band in the page (see `pagerTakes`).
    private var pagerBand: TasksPagerBand {
        TasksPagerBand(top: listTop - AtticLayout.pageTabsToList / 2, bottomInset: bottomInset)
    }

    /// Whether ⌘F belongs to the page's search (pure, tested directly).
    static func answersFind(event: NSEvent, pageShown: Bool, tab: TasksTab, pageWindow: NSWindow?, popoverOpen: Bool) -> Bool {
        guard pageShown, !popoverOpen, let pageWindow, event.window === pageWindow, pageWindow.isKeyWindow,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "f" else { return false }
        return true
    }

    /// Esc (or the field's "Esc"): the search ends, the tabs return, and the
    /// Done log shows whole again.
    private func endSearch() {
        model.setSearchQuery("", for: model.tab)
        searchFocused = false
    }

    /// ↓ in the search field: the keyboard goes to the first match, so
    /// Return (the title) and the row's keys work from there; Esc there
    /// ends the search. Nothing to reach: the field keeps the key.
    private func searchDownPressed(_ event: NSEvent) -> Bool {
        guard searchFocused, model.isPageShown, event.keyCode == 125,
              event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
              !AtticTextInput.isPopoverOpen, let window = pointer.view?.window, event.window === window,
              !Self.isComposing(window.firstResponder) else { return false }
        if model.tab == .done { model.flushDoneSearchInput() }
        guard !model.searchQuery(for: model.tab).isEmpty,
              let first = visibleIDs().first else { return false }
        searchFocused = false
        focusTracker.noteKeyboardNavigation()
        model.selectOnly(first)
        DispatchQueue.main.async { setFocus(first) }
        return true
    }

    /// Where the lists' first row rests: under the tabs, as before.
    private var listTop: CGFloat { TasksViewport.listTop(tabsTop: tabsTop) }

    private var edgeStyle: AtticScrollEdgeStyle { scrollEdges.style }

    /// The viewport ends below the tallest control on the tabs line (the
    /// Find field and the quiet buttons are taller than the tab labels).
    private var viewportTop: CGFloat { TasksViewport.controlsBottom(tabsTop: tabsTop) }

    /// The tabs' band owns its clicks (review 9): a row scrolled under it
    /// is not clickable through it. The header above owns its own (the
    /// window drag region).
    private var tabsBand: some View {
        Color.clear
            .frame(height: listTop - AtticLayout.pageTabsToList / 2)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {}
            .accessibilityHidden(true)
    }

    /// What the lists keep clear at the bottom: the whole bottom stack as
    /// measured (the add bar, the strip, a selection bar or paste offer),
    /// its margin, and the 16 pt the list keeps from the bar.
    private var bottomClearance: CGFloat {
        TasksViewport.bottomClearance(stackHeight: bottomControlsHeight, bottomInset: bottomInset)
    }

    private var bottomInset: CGFloat { max(AtticSpacing.panelMargin, layout.chromeInsets.bottom) }

    private var bottomMargin: CGFloat { TasksViewport.bottomMargin(bottomInset: bottomInset) }

    /// Brings a row into the part of the list nothing covers (keys, a new
    /// task): the page's geometry decides how.
    @discardableResult
    private func revealRow(_ id: UUID, in tab: TasksTab, proxy: ScrollViewProxy, animation: Animation?) -> Bool {
        let reveal = TasksViewport.reveal(frame: pointer.frames[TasksRowID(tab: tab, id: id)], height: rowHeight(id, in: tab),
                                          viewport: pointer.view?.bounds.height ?? layout.panelSize.height,
                                          listTop: listTop,
                                          bottomMargin: edgeStyle == .systemSoft
                                            ? TasksViewport.controlsInset(stack: bottomStack.height, bottomInset: bottomInset) + AtticLayout.contentToAddBar
                                            : bottomMargin,
                                          bottomClearance: bottomClearance)
        switch reveal {
        case .none: return false
        case .minimal: withAnimation(animation) { scroll(proxy, to: id, in: tab) }
        case let .bottom(fraction): withAnimation(animation) { scroll(proxy, to: id, in: tab, anchor: UnitPoint(x: 0, y: fraction)) }
        }
        return true
    }

    // MARK: - Pages

    /// The three pages side by side, placed by the pager's position (round
    /// 9: the page owns the swipe, see `TasksPager.swift`). Only the page
    /// shown is built, and the pages beside it only while a swipe or a
    /// slide shows them (`TasksPagerSpan`); only the page shown takes
    /// clicks and is read by VoiceOver.
    private var pager: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                TasksPagerPages(span: swipe.span, model: model, store: store, motion: swipe.motion, count: TasksTab.allCases.count,
                                shown: TasksTab.allCases.firstIndex(of: model.tab) ?? 0, size: proxy.size,
                                page: { index, drawn in page(TasksTab.allCases[index], drawn: drawn) },
                                token: { [model] index in model.pageToken(TasksTab.allCases[index]) })
                if TasksPagerMotion.tracing {
                    TasksPagerTrace(motion: swipe.motion)
                }
            }
            .onChange(of: width, initial: true) { _, width in swipe.width = width }
        }
    }

    /// A page; `drawn` false: kept built but hidden (its list's scroll
    /// view is hidden in AppKit: it draws nothing and VoiceOver skips it).
    private func page(_ tab: TasksTab, drawn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch tab {
            case .now, .backlog:
                listPage(tab, drawn: drawn)
            case .done:
                TasksDonePage(model: model, updates: drawn ? model.cellUpdates : TasksCellUpdates.quiet,
                              results: drawn ? model.doneResults : TasksDoneResults.quiet, store: store,
                              listTop: listTop, bottomClearance: bottomClearance,
                              bottomMargin: bottomMargin, viewportTop: viewportTop, bottomInset: bottomInset, bottomStack: bottomStack, drawn: drawn,
                              edges: edgeStyle, mask: viewportMask, reveal: $doneReveal,
                              revealRow: { id, proxy in revealRow(id, in: .done, proxy: proxy, animation: nil) },
                              cell: { row in cell(row, tab: .done, group: [], drawn: drawn) },
                              proxies: listProxies,
                              registerList: { proxy in
                                  listProxies.lists[.done] = proxy
                                  takeScrollRequest(in: .done)
                              },
                              slots: doneSlots,
                              rowsAreInterchangeable: { doneRowsAreInterchangeable() })
            }
        }
        // Larger corners move the pin (and the add bar) inward; the tabs
        // and the list follow, so the tabs stay on the pin's edge.
        .padding(.horizontal, cornerInset)
    }

    /// The page's edge: the circles (16 in the page) sit on the content
    /// line, 12 inside the controls' line at this corner size.
    private var cornerInset: CGFloat {
        max(0, layout.chromeInsets.leading + AtticLayout.contentFromChrome - AtticLayout.circleX)
    }

    private func listSpace(_ tab: TasksTab) -> NamedCoordinateSpace {
        .named("AtticTasksList\(tab.rawValue)")
    }

    private func listPage(_ tab: TasksTab, drawn: Bool) -> some View {
        let rows = model.rows(for: tab)
        let sections = model.sections(for: tab)
        let groups = Dictionary(grouping: rows, by: \.status).mapValues { $0.map(\.id) }
        let travel = design.reduceMotion ? nil : AtticMotionPreset.settle.animation(reduceMotion: false)
        let view = model.viewOptions(for: tab)
        let query = model.trimmedQuery(for: tab)
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // An active filter never hides silently (item 6): what
                    // is shown, and Show All.
                    if view.filters, query.isEmpty {
                        AtticViewLine(summary: view.summary, actionTitle: String(localized: "Show All")) {
                            model.showAll(on: tab)
                        }
                        .accessibilityIdentifier("tasks-view-line")
                    }
                    ForEach(sections.open) { row in
                        cell(row, tab: tab, group: groups[row.status] ?? [], drawn: drawn)
                            .id(row.id)
                            .opacity(reorderFade.contains(row.id) ? 0.001 : 1)
                            // A moved row pops back in with the feel (1, none, in Calm).
                            .scaleEffect(reorderFade.contains(row.id) ? AtticMotionPreset.settle.hiddenScale(reduceMotion: design.reduceMotion) : 1)
                            // A row added or leaving drops into or rises
                            // out of its place (round 9).
                            .transition(AtticMotionPreset.settle.transition(reduceMotion: design.reduceMotion, edge: .top))
                    }
                    if !query.isEmpty {
                        // Find's quiet count, or that nothing matches (as on
                        // Done).
                        if sections.open.isEmpty {
                            AtticEmptyLine(text: String(localized: "No tasks on \(tab.title) match “\(query)”."))
                                .accessibilityIdentifier("tasks-empty-line")
                        } else if let count = model.listSearchCount(for: tab) {
                            AtticText(verbatim: String(localized: "\(count.matches) of \(count.total) tasks on \(tab.title)"),
                                      style: .rowMeta, ink: .helper)
                                .frame(height: AtticLayout.rowPitch)
                                .padding(.leading, AtticLayout.textX)
                                .accessibilityIdentifier("tasks-find-count")
                        }
                    } else if sections.open.isEmpty, view.filters {
                        AtticEmptyLine(text: String(localized: "Nothing in this view"))
                            .accessibilityIdentifier("tasks-empty-line")
                    } else if sections.open.isEmpty, let message = model.emptyMessage[tab] {
                        AtticEmptyLine(text: message)
                            .accessibilityIdentifier("tasks-empty-line")
                        // Now is empty and Later has tasks: one quiet step
                        // there (review 24).
                        if tab == .now, model.offersLater {
                            AtticQuietAction(systemName: nil, title: String(localized: "Choose from Later"), trailingChevron: true,
                                             emphasised: true) { model.select(tab: .backlog) }
                                .padding(.leading, AtticLayout.pageTabsX)
                                .accessibilityIdentifier("tasks-choose-from-later")
                        }
                    }
                    // Done tasks recede into one quiet line; a click shows
                    // them under it (and hides them again).
                    if tab == .now, !sections.done.isEmpty {
                        AtticCompletedLine(title: String(localized: "Completed today"), count: sections.done.count,
                                           isExpanded: model.completedTodayExpanded) {
                            withAnimation(travel) {
                                model.toggleCompletedToday()
                            }
                        }
                        .accessibilityIdentifier("tasks-completed-today")
                        // Under an empty message it is the next row (one
                        // row apart); after tasks, 12 below the last one.
                        .padding(.top, sections.open.isEmpty
                            ? (AtticLayout.rowPitch - AtticCompletedLineMetrics.height) / 2
                            : AtticCompletedLineMetrics.top)
                        .padding(.bottom, model.completedTodayExpanded ? AtticSpacing.s4 : 0)
                        if model.completedTodayExpanded {
                            ForEach(sections.done) { row in
                                cell(row, tab: tab, group: groups[row.status] ?? [], drawn: drawn)
                                    .id(row.id)
                            }
                        }
                    }
                    if edgeStyle == .systemSoft {
                        TasksListTailClearance(stack: bottomStack, bottomInset: bottomInset, bottomClearance: bottomClearance)
                    }
                }
                .animation(reorderFade.isEmpty ? travel : nil, value: rows.map(\.id))
                // The list's place is kept while its page is not built.
                .background(TasksScrollKeeper(model: model, tab: tab, proxies: listProxies, drawn: drawn).accessibilityHidden(true))
                // The clearance past the add bar's zone is room at the end
                // of the list, not margin (see `TasksViewport.bottomMargin`).
                .padding(.bottom, edgeStyle == .cleanCut ? bottomClearance - bottomMargin : 0)
            }
            .scrollIndicators(.automatic)
            .tasksListEdges(edgeStyle, top: viewportTop, listTop: listTop, bottomInset: bottomInset,
                            bottomMargin: bottomMargin, bottomClearance: bottomClearance,
                            stack: bottomStack, mask: viewportMask)
            .onChange(of: focusedRow) { _, focus in
                guard let focus, focus.page == tab.rawValue, rows.contains(where: { $0.id == focus.id }),
                      focusTracker.isKeyboardDriving else { return }
                let id = focus.id
                revealRow(id, in: tab, proxy: proxy, animation: travel)
            }
            // An agent's `show`, or a task just added: the row comes into view.
            // The list registers where it can be scrolled; the page takes
            // a `show`'s request to it (below), also one made before this
            // list was built (round 10, Astra's round 9 check).
            .onAppear {
                listProxies.lists[tab] = proxy
                takeScrollRequest(in: tab)
            }
            .onChange(of: model.addedRequest) { _, request in
                guard let request, tab == model.tab else { return }
                // The row exists once the store's change reaches the list.
                DispatchQueue.main.async {
                    revealRow(request.id, in: tab, proxy: proxy, animation: travel)
                }
            }
            // A row the keyboard completed leaves its place: the keyboard
            // moves on to the row that took it (review 8). A row the pointer
            // completed takes nothing with it: no row is lit that the person
            // did not reach (round 5).
            .onChange(of: rows.map(\.id)) { old, new in
                if tab == model.tab { PerformanceSignposts.watchFrames("RowsMotion", seconds: 0.35) }
                guard tab == model.tab, let focused = focusedID, !new.contains(focused),
                      let index = old.firstIndex(of: focused), !new.isEmpty else { return }
                guard focusTracker.isKeyboardDriving else {
                    focusedRow = nil
                    return
                }
                let next = new[min(index, new.count - 1)]
                setFocus(next)
                model.selectOnly(next)
            }
        }
    }

    /// Clean cut (the default since 2026-10-03): the viewport's fade, by
    /// position in the viewport, not per row (owner fix 8, review 9), so an
    /// open quick look fades line by line as it passes under the tabs and
    /// header, or under the add bar (A15: the scroll-under fade). The system
    /// soft edge uses no mask.
    private var viewportMask: some View {
        TasksViewportMask(tabsTop: tabsTop, topEdge: layout.scrollEdgeFadeTop,
                          bottomEdge: bottomInset + AtticControlSize.panelButton.height / 2)
    }

    // MARK: - Row

    /// `drawn` false: the page is kept built but not drawn; the row does no
    /// work until it is (round 11).
    @ViewBuilder
    private func cell(_ row: TasksListRow, tab: TasksTab, group: [UUID], drawn: Bool = true) -> some View {
        let id = row.id
        // Read when the cell draws (the closures below run in the cell's
        // own body), never captured when the list built it.
        let expanded = { model.expanded.contains(id) && row.status != .done }
        // Every row drags, out of the panel as a copy (owner-approved,
        // 2026-10-01); only Now's and Later's manual order reorders. A
        // sorted view (item 6) and Done have no place to drag to: there the
        // row's drag group is the row alone, so nothing moves aside, the
        // release lands it back and commits nothing, and leaving the panel
        // hands it off (GPT-6.1's review).
        let reorders = Self.reorders(tab: tab, manual: model.reorders(on: tab))
        TasksReorderCell(
            model: model, updates: drawn ? model.cellUpdates : TasksCellUpdates.quiet, focus: rowFocus.binding,
            id: id, tab: tab, group: reorders ? group : [id], drag: $drag, metaPopover: $metaPopover, fileDropRow: $fileDropRow,
            enabled: model.editingTitleID != id,
            session: dragSession,
            pointer: pointer,
            allowsStart: { [pointer, dragSession] point in
                // Not the circle column (before the row reports its
                // controls), and never one of the row's controls.
                point.x > cornerInset + AtticLayout.textX - AtticSpacing.s4
                    && !dragSession.isOnControl(TasksRowID(tab: tab, id: id), at: point,
                                                rowOrigin: pointer.frames[TasksRowID(tab: tab, id: id)]?.origin)
            },
            heights: { rowHeight($0, in: tab) },
            onBegin: {
                beginDragSession(in: tab)
                if let origin = pointer.frames[TasksRowID(tab: tab, id: id)] {
                    pointer.liftedCard.begin(id: id, tab: tab, origin: origin)
                }
            },
            onMove: { [pointer] translation in pointer.liftedCard.follow(translation) },
            onEnd: finishDrag,
            onPushPastGroup: { if reorders { showBoundaryHint() } }
        ) { live in
            let isSelected = model.selection.contains(id)
            let run = selectionRun(for: id, in: tab)
            let isExpanded = expanded()
            // Only the page that answers the keyboard opens an editor: the
            // copy a kept page draws of the same task shows none (round 12).
            let editing = model.editingTitleID == id && live.isActive
            #if DEBUG
            let _ = pointer.noteDrawnFocus(TasksRowID(tab: tab, id: id), live.focus.isFocused)
            #endif
            // The row redraws only when what it shows changed (round 11):
            // every change to the page's model reached every row's cell, and
            // each rebuilt its whole row. An editor or a picker open on the
            // row always redraws it (they show live state).
            TasksRowSnapshot(key: TasksRowKey(model: row.model, isSelected: isSelected, selectionRun: run, isExpanded: isExpanded,
                                              isDropTarget: live.isDropTarget, isFocused: live.focus.isFocused, tab: tab,
                                              layout: layout, isLive: editing || live.metaPopover != nil)) {
                AtticTaskRow(
                    model: row.model,
                    isSelected: isSelected,
                    selectionRun: run,
                    isExpanded: isExpanded,
                    dropLabel: live.isDropTarget ? String(localized: "Add to page") : nil,
                    actions: actions(for: id, in: tab),
                    onToggleExpanded: { toggleExpanded(id) },
                    onSelect: { rowClicked(id, tab: tab) },
                    focus: live.focus,
                    titleEditing: editing ? titleEditing(for: id) : nil,
                    // Every row, done ones too (round 10): a finished task shows
                    // no date or tags, but its pickers open from its row.
                    meta: rowMeta(for: id, open: live.metaPopover),
                    onActions: { anchor in showActions(for: id, anchor: anchor, tab: tab) }
                )
                .contextMenu { rowMenu(row, tab: tab) }
            }
            .equatable()
        } below: { live in
            // Read here, in the cell's own body, as `live.isActive` is.
            let active = model.tab == tab && model.isPageShown
            // A Done log task's details open under its row (Esc or the
            // menu closes them), raised over the list like a pop-over.
            // Only on Done (round 12's identity: Now's "Completed today"
            // draws the same task, and never opens these).
            if tab == .done, model.doneDetailID == id, let detail = model.doneDetail(for: id) {
                TasksDoneDetailView(detail: detail, store: store, restore: {
                    // The details close only once the restore saved; a
                    // failure shows under the row with Retry (round 4).
                    if model.report(model.restoreToNow(id), on: id, retry: { model.restoreToNow(id) }).isApplied {
                        model.doneDetailID = nil
                    }
                })
                .padding(.leading, AtticLayout.textX - AtticPopoverMetrics.padding - AtticPopoverMetrics.rowPadding)
                .padding(.bottom, AtticSpacing.s8)
                // Raised from its row: it grows from the row's corner.
                .transition(AtticMotionPreset.popover.transition(reduceMotion: design.reduceMotion, anchor: .topLeading))
                .onExitCommand { model.doneDetailID = nil }
            }
            if model.failedSave == .title(id) {
                AtticErrorLine(message: String(localized: "Not saved"), onRetry: { _ = model.commitTitle() })
                    .padding(.leading, AtticLayout.textX)
            }
            if let failure = model.rowFailure, failure.id == id {
                AtticErrorLine(message: failure.canRetry ? String(localized: "Not saved") : failure.message,
                               actionTitle: failure.canRetry ? String(localized: "Retry") : String(localized: "OK"),
                               onRetry: { failure.canRetry ? model.retryRowFailure() : model.dismissRowFailure() })
                    .padding(.leading, AtticLayout.textX)
                    .accessibilityIdentifier("tasks-row-failure")
            }
            if expanded() {
                AtticQuickLook(
                    subtasks: row.subtasks,
                    onToggle: { subtask in model.report(model.toggleSubtask(subtask.id), on: id) { model.toggleSubtask(subtask.id) } },
                    onAddSubtask: { model.beginAddingSubtask(to: id) },
                    onOpenPage: { openFiles(id) },
                    commands: { subtask in subtaskCommands(subtask, of: id, in: row.subtasks) },
                    onFocusChange: { subtaskID, focused in
                        if focused { model.focusedSubtaskID = subtaskID } else if model.focusedSubtaskID == subtaskID { model.focusedSubtaskID = nil }
                    },
                    renaming: (active ? model.renamingSubtaskID : nil).map { renaming in
                        (renaming, AtticTitleEditing(text: $model.subtaskRename, commit: { model.commitSubtaskRename() },
                                                     cancel: { model.cancelSubtaskRename() },
                                                     accessibilityLabel: String(localized: "Rename subtask"),
                                                     emptyBackspace: { model.backspaceEmptySubtask() },
                                            pageUndo: { native in (model.taskChangeOwnsUndo || !native) && model.undo().isApplied },
                                            pageRedo: { native in (model.taskChangeOwnsRedo || !native) && model.redo().isApplied },
                                            didEdit: { model.noteTextEdit() }))
                    },
                    newSubtask: model.newSubtaskParentID == id && active
                        ? AtticTitleEditing(text: $model.newSubtaskTitle, commit: { model.commitNewSubtask() },
                                            cancel: { model.cancelEditing() },
                                            accessibilityLabel: String(localized: "New subtask of \(row.model.title)"),
                                            placeholder: String(localized: "Add subtask…"),
                                            emptyBackspace: { model.backspaceEmptySubtask() },
                                            pageUndo: { native in (model.taskChangeOwnsUndo || !native) && model.undo().isApplied },
                                            pageRedo: { native in (model.taskChangeOwnsRedo || !native) && model.redo().isApplied },
                                            didEdit: { model.noteTextEdit() })
                        : nil,
                    popover: movePopover(parentID: id, open: live.metaPopover),
                    onReorder: { subtaskID, index, group in
                        let move = { model.reorderSubtask(subtaskID, toGroupIndex: index, group: group) }
                        if model.report(move(), on: id, retry: move).isApplied {
                            AtticHaptics.tick(enabled: design.hapticsEnabled)
                        }
                    }
                )
                // It opens from under its row (a fade in Calm).
                .transition(AtticMotionPreset.expand.transition(reduceMotion: design.reduceMotion, edge: nil, anchor: .top))
                if model.subtaskRenameFailed, let renaming = model.renamingSubtaskID,
                   row.subtasks.contains(where: { $0.id == renaming }) {
                    AtticErrorLine(message: String(localized: "Not saved"), onRetry: { _ = model.commitSubtaskRename() })
                        .padding(.leading, AtticLayout.textX)
                }
                if model.failedSave == .newSubtask(id) {
                    AtticErrorLine(message: String(localized: "Not saved"), onRetry: { _ = model.commitNewSubtask() })
                        .padding(.leading, AtticLayout.textX)
                }
            }
        }
        // Files dropped on a row: one drop destination for the page
        // (`fileDropTarget(at:)`), not one per row (round 11: a drop
        // destination on every row made a screenful of rows slower to build).
    }

    /// The quick look opens and closes with the expansion motion (review
    /// 21, the Motion Lab: `expand`); Reduce Motion shows it at once.
    private func toggleExpanded(_ id: UUID) {
        PerformanceSignposts.watchFrames("QuickLookMotion", seconds: 0.35)
        withAnimation(design.reduceMotion ? nil : AtticMotionPreset.expand.animation(reduceMotion: false)) {
            model.toggleExpanded(id)
        }
    }

    /// The title editor with the add bar's shorthand (owner fix 4).
    private func titleEditing(for id: UUID) -> AtticTitleEditing {
        AtticTitleEditing(
            text: $model.editingTitle,
            commit: {
                let saved = model.commitTitle()
                if saved { setFocus(id) }
                return saved
            },
            cancel: { model.cancelEditing(); setFocus(id) },
            tokens: AtticTitleEditing.Tokens(
                chips: model.titleEdit.tokenChips(parser: model.parser, caret: model.titleEditCaret),
                dismissChip: { range in
                    model.titleHistory.checkpoint(model.titleEdit, selection: model.titleEditCurrentSelection)
                    model.titleEdit.dismiss(range)
                },
                edited: { range, replacement in
                    model.noteTextEdit()
                    model.titleHistory.willEdit(model.titleEdit, selection: model.titleEditCurrentSelection, range: range, replacement: replacement)
                    model.titleEdit.edited(range, replacement: replacement)
                },
                caretMoved: { caret in
                    if model.titleEditCaret != caret { model.titleEditCaret = caret }
                    var shown = model.titleEdit
                    if shown.markShown(parser: model.parser, caret: caret) { model.titleEdit = shown }
                },
                undoDraft: { model.taskChangeOwnsUndo ? nil : model.undoTitleEdit() },
                redoDraft: { model.taskChangeOwnsRedo ? nil : model.redoTitleEdit() },
                selectionMoved: { model.titleEditSelection = $0 },
                undoFallback: { model.undo() },
                redoFallback: { model.redo() }
            )
        )
    }

    // MARK: - A row's date and tags (owner fix 5 C and D)

    /// `open` is the cell's live reading of the open picker: the page's own
    /// state read from a closure the list kept is not current.
    private func rowMeta(for id: UUID, open: TasksMetaPopover?) -> AtticRowMeta {
        AtticRowMeta(
            onDate: { openMeta(.date, on: id) },
            onTags: { openMeta(.tags, on: id) },
            datePresented: metaBinding(.date, id: id, open: open),
            tagsPresented: metaBinding(.tags, id: id, open: open),
            isDateOpen: open?.kind == .date,
            isTagsOpen: open?.kind == .tags,
            datePicker: { AnyView(datePicker(for: id, open: open)) },
            tagPicker: { AnyView(tagPicker(for: id, open: open)) }
        )
    }

    /// A click on a row's date or tags opens its picker for that row alone;
    /// the menu's "Pick a Date…" and "New Tag…" open it for the menu's
    /// targets (a multi-selection too).
    private func openMeta(_ kind: TasksMetaPopover.Kind, on id: UUID, targets: [UUID]? = nil, newTag: Bool = false) {
        metaPopover = TasksMetaPopover(id: id, tab: model.tab, kind: kind, targets: targets ?? [id], newTag: newTag)
    }

    private func metaBinding(_ kind: TasksMetaPopover.Kind, id: UUID, open: TasksMetaPopover?) -> Binding<Bool> {
        let shown = open?.id == id && open?.kind == kind
        return Binding(
            get: { shown },
            set: { now in if !now, shown { metaPopover = nil } }
        )
    }

    private func datePicker(for id: UUID, open: TasksMetaPopover?) -> some View {
        let targets = open?.targets ?? [id]
        // The pop-over closes only once the change saved; a failure stays
        // in it with Retry (round 4).
        return VStack(alignment: .leading, spacing: 0) {
            TaskDatePickerView(
                choices: model.dateChoices,
                selected: model.commonDueDay(targets),
                forRow: true,
                onPick: { day in
                    if model.pickerChange(on: id, { model.setDueDay(day, for: targets) }) { metaPopover = nil }
                },
                onRemove: {
                    if model.pickerChange(on: id, { model.setDueDay(nil, for: targets) }) { metaPopover = nil }
                }
            )
            TasksPickerFailureLine(model: model, id: id) { metaPopover = nil }
        }
        .onDisappear { model.clearPickerFailure() }
    }

    private func tagPicker(for id: UUID, open: TasksMetaPopover?) -> some View {
        let targets = open?.targets ?? [id]
        return VStack(alignment: .leading, spacing: 0) {
            TaskTagPickerView(
                allTags: model.tagChoices(for: targets),
                state: { model.tagState($0, for: targets) },
                onToggle: { tag in model.pickerChange(on: id) { model.toggleTag(tag, for: targets) } },
                onCreate: { tag, completed in
                    model.pickerChange(on: id, onSaved: completed) { model.toggleTag(tag, for: targets) }
                },
                focusField: true
            )
            TasksPickerFailureLine(model: model, id: id, closeOnRetrySuccess: nil)
        }
        .onDisappear { model.clearPickerFailure() }
    }

    private func selectionRun(for id: UUID, in tab: TasksTab) -> AtticSelectionRun {
        guard model.selection.contains(id), model.selection.count > 1 else { return .single }
        let ids = tab == .done ? model.doneDays().flatMap { $0.rows.map(\.id) } : model.rows(for: tab).map(\.id)
        guard let index = ids.firstIndex(of: id) else { return .single }
        let above = index > 0 && model.selection.contains(ids[index - 1]) && !model.expanded.contains(ids[index - 1])
        let below = index + 1 < ids.count && model.selection.contains(ids[index + 1]) && !model.expanded.contains(id)
        switch (above, below) {
        case (false, false): return .single
        case (false, true): return .first
        case (true, true): return .middle
        case (true, false): return .last
        }
    }

    private func visibleIDs() -> [UUID] {
        model.tab == .done ? model.doneDays().flatMap { $0.rows.map(\.id) } : model.rows(for: model.tab).map(\.id)
    }

    private func rowClicked(_ id: UUID, tab: TasksTab) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            model.selectOnly(id)
            model.beginEditingTitle(id)
            return
        }
        model.click(id, modifiers: modifiers, visible: visibleIDs())
        setFocus(id)
    }

    /// What a row offers, decided once for the keys, the circle, VoiceOver
    /// and the right-click menu (Astra 19). A Done page row completes or
    /// un-completes, restores to Now and shows its details (a Done log
    /// task) or its files (one still in Now's done group); nothing else.
    /// One haptic tick per completing command, once it saved (review 22).
    private func completionFeedback(_ outcome: CommandOutcome, _ ids: [UUID]) {
        guard outcome.isApplied, ids.contains(where: { store.listedTask(withID: $0)?.status == .done }) else { return }
        AtticHaptics.tick(enabled: design.hapticsEnabled)
    }

    /// The one scope rule (review 5): a pointer on a row's own control acts
    /// on that row; the keyboard and menus act on the selection the row is
    /// part of.
    private func commandTargets(for id: UUID) -> [UUID] {
        NSApp.currentEvent?.type == .keyDown ? model.targets(for: id) : [id]
    }

    /// Internal for tests: the keys' and VoiceOver's commands, reported the menu's way.
    func actions(for id: UUID, in tab: TasksTab) -> AtticTaskActions {
        if tab == .done {
            return AtticTaskActions(
                // The same scope rule as live rows: the circle acts on its
                // row, Space and the menu on the selection it is part of.
                toggleDone: {
                    let targets = commandTargets(for: id)
                    model.report(model.toggleDone(targets), on: id) { model.toggleDone(targets) }
                },
                openPage: { toggleDetails(id) },
                // Round 10: Delete (to Recently Deleted), Edit Title and the
                // metadata edits, without changing completion.
                delete: { deleteAndMoveFocus(model.targets(for: id)) },
                editTitle: {
                    model.selectOnly(id)
                    model.beginEditingTitle(id)
                },
                restoreToNow: {
                    let targets = model.targets(for: id)
                    model.report(model.restoreToNow(targets), on: id) { model.restoreToNow(targets) }
                },
                copy: { model.copy(model.targets(for: id)) },
                duplicate: { runCommand(on: id) { model.duplicate($0) } },
                changePriority: { showPriority(for: id) },
                showActions: { showActions(for: id, anchor: nil, tab: tab) },
                names: .init(openPage: detailsActionName(for: id))
            )
        }
        let unfinished = store.task(withID: id).map { $0.status != .done } == true
        return AtticTaskActions(
            // The circle's click acts on its row; Space on a row that is part
            // of a multi-selection acts on the selection, as the menu does
            // (review 5). A failure shows under the row (review 6).
            toggleDone: {
                let targets = commandTargets(for: id)
                let outcome = targets.count > 1
                    ? model.report(model.toggleDone(targets), on: id) { model.toggleDone(targets) }
                    : model.report(model.toggleDone(id), on: id) { model.toggleDone(id) }
                completionFeedback(outcome, targets)
            },
            // ⇧Space (and VoiceOver): start or stop working, with the same
            // failure line and Retry the menu's command shows (round 5, F5).
            toggleWorking: {
                let targets = model.targets(for: id)
                model.report(model.toggleWorking(targets), on: id) { model.toggleWorking(targets) }
            },
            openPage: { openFiles(id) },
            // ⌘B: to Later, or back to Now from Later, reported the same way.
            moveToBacklog: {
                let targets = model.targets(for: id)
                let onLater = model.tab == .backlog
                let move = { onLater ? model.moveToNow(targets) : model.moveToBacklog(targets) }
                model.report(move(), on: id, retry: move)
            },
            delete: { deleteAndMoveFocus(model.targets(for: id)) },
            // Return: the title in place.
            editTitle: {
                model.selectOnly(id)
                model.beginEditingTitle(id)
            },
            moveUp: unfinished && model.reorders(on: tab) ? { moveRow(id, by: -1) } : nil,
            moveDown: unfinished && model.reorders(on: tab) ? { moveRow(id, by: 1) } : nil,
            addSubtask: unfinished ? { model.beginAddingSubtask(to: id) } : nil,
            copy: { model.copy(model.targets(for: id)) },
            duplicate: { runCommand(on: id) { model.duplicate($0) } },
            changePriority: { showPriority(for: id) },
            showActions: { showActions(for: id, anchor: nil, tab: tab) },
            names: .init(openPage: String(localized: "Open files"))
        )
    }

    /// One command for all routes. A main-queue block can run inside
    /// NSMenu's nested tracking loop; it does not mean the menu has closed.
    /// Present in the default mode, after AppKit finishes tracking and
    /// restores the source window's responder and ordering state.
    ///
    /// A menu's choice runs through `AtticTextInput.choosing`, so the
    /// Return that chose Open Files… is never mistaken for a typing field's
    /// key (PR prep, P2). The queued block does not wake a sleeping run
    /// loop by itself (`CFRunLoopPerformBlock`), so the loop is woken.
    private func openFiles(_ id: UUID) {
        guard !AtticTextInput.ownsCurrentKey else {
            SubtaskPanelController.log.notice("Open Files \(id, privacy: .public) refused: the key belongs to a typing field")
            return
        }
        pointer.endInvocation()
        RunLoop.main.perform(inModes: [.default]) { [model] in
            MainActor.assumeIsolated { model.openPage(id) }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// A key's or VoiceOver's command on the row's targets, with its
    /// failure under the row (Retry).
    private func runCommand(on id: UUID, _ command: @escaping ([UUID]) -> CommandOutcome) {
        let targets = model.targets(for: id)
        model.report(command(targets), on: id) { command(targets) }
    }

    /// ⌘Return on a Done page row: its details open or close in place, for
    /// a Done log task and one still in Now's done group alike (follow-up
    /// part 2, L6: the date, priority and tags a finished task keeps show
    /// there, with its files).
    private func toggleDetails(_ id: UUID) {
        model.doneDetailID = model.doneDetailID == id ? nil : id
    }

    /// VoiceOver's name for `toggleDetails`.
    private func detailsActionName(for id: UUID) -> String {
        model.doneDetailID == id ? String(localized: "Close details") : String(localized: "Show details")
    }

    /// The right-click menu's name for `toggleDetails`.
    private func detailsMenuTitle(for id: UUID) -> String {
        model.doneDetailID == id ? String(localized: "Close Details") : String(localized: "Show Details")
    }

    private func deleteAndMoveFocus(_ ids: [UUID]) {
        let visible = visibleIDs()
        let next = visible.first { !ids.contains($0) && (visible.firstIndex(of: $0) ?? 0) > (ids.compactMap { visible.firstIndex(of: $0) }.max() ?? 0) }
            ?? visible.last { !ids.contains($0) }
        // Focus moves only once the delete saved (Astra 6); a failure shows
        // under the row the command came from.
        guard let first = ids.first, model.report(model.delete(ids), on: first, retry: { model.delete(ids) }).isApplied else { return }
        setFocus(next)
        if let next { model.selectOnly(next) }
    }

    // MARK: - Right-click menu

    /// The right-click menu: the task's commands (`taskCommands`), the
    /// same list the actions button and ⇧⌘I open.
    private func rowMenu(_ row: TasksListRow, tab: TasksTab) -> some View {
        AtticMenuItems { taskCommands(row.id, tab: tab) }
    }

    /// Every command a row offers, in one list (round 10: one definition
    /// for the right-click menu, the actions button, ⇧⌘I, and the keys
    /// ⌘C and ⌘D, which run the command this list holds for their key).
    /// It acts on the menu's targets: the row, or the selection it is part
    /// of. Each command shows its key from `AtticTaskShortcut`.
    func taskCommands(_ rowID: UUID, tab: TasksTab) -> [AtticMenuCommand] {
        // The row's identity on its page: a task Now keeps under "Completed
        // today" and its copy on Done are two rows (round 12).
        let key = TasksRowID(tab: tab, id: rowID)
        let id = menuRowID(key)
        let targets = menuTargets(key)
        let single = targets.count == 1
        let listed = targets.compactMap { store.listedTask(withID: $0) }
        let allDone = !listed.isEmpty && listed.allSatisfy { $0.status == .done }
        let allWorking = !listed.isEmpty && listed.allSatisfy { $0.status == .inProgress }
        let unfinished = store.task(withID: id).map { $0.status != .done } == true
        var list: [AtticMenuCommand] = []
        // A menu for several tasks says so (bug 1): "3 Tasks".
        if !single { list.append(.header(String(localized: "\(targets.count) Tasks"))) }
        if tab == .done {
            // On a selection it restores them all, as one step (round 6).
            list.append(AtticMenuCommand(verbatim: single ? String(localized: "Restore to Now")
                                                          : String(localized: "Restore \(targets.count) Tasks to Now"),
                                         startsSection: single) {
                menuCommand(key) { model.restoreToNow($0) }
            })
            list.append(AtticMenuCommand(verbatim: String(localized: "Mark as Not Done"), shortcut: AtticTaskShortcut.complete) {
                menuCommand(key) { model.toggleDone($0) }
            })
            if single {
                list.append(AtticMenuCommand(verbatim: detailsMenuTitle(for: id), shortcut: AtticTaskShortcut.openPage) {
                    guard !AtticTextInput.ownsCurrentKey else { return }
                    toggleDetails(menuRowID(key))
                })
            }
        } else {
            list.append(AtticMenuCommand(verbatim: allDone ? String(localized: "Mark as Not Done") : String(localized: "Complete"),
                                         shortcut: AtticTaskShortcut.complete, startsSection: single) {
                menuCommand(key) { targets in
                    let outcome = model.toggleDone(targets)
                    completionFeedback(outcome, targets)
                    return outcome
                }
            })
            list.append(AtticMenuCommand(verbatim: allWorking ? String(localized: "Stop Working") : String(localized: "Start Working"),
                                         shortcut: AtticTaskShortcut.working) {
                menuCommand(key) { model.toggleWorking($0) }
            })
        }
        if single {
            list.append(AtticMenuCommand(verbatim: String(localized: "Edit Title"), shortcut: AtticTaskShortcut.editTitle,
                                         startsSection: true) {
                guard !AtticTextInput.ownsCurrentKey else { return }
                let id = menuRowID(key)
                model.selectOnly(id)
                model.beginEditingTitle(id)
            })
        }
        // Date, Tags and Priority (owner fixes 3 and 5 D): on the menu's
        // targets, a multi-selection too; one step each. Done's rows too,
        // without changing completion (round 10).
        list.append(.submenu(String(localized: "Date"), startsSection: !single, dateCommands(key, targets: targets)))
        list.append(.submenu(String(localized: "Tags"), tagCommands(key, targets: targets)))
        list.append(.submenu(String(localized: "Priority"), priorityCommands(key, targets: targets)))
        if tab == .backlog {
            list.append(AtticMenuCommand(verbatim: String(localized: "Move to Now"), shortcut: AtticTaskShortcut.later) {
                menuCommand(key) { model.moveToNow($0) }
            })
        } else if tab == .now {
            list.append(AtticMenuCommand(verbatim: String(localized: "Move to Later"), shortcut: AtticTaskShortcut.later) {
                menuCommand(key) { model.moveToBacklog($0) }
            })
        }
        // The common actions stay at the top; the rarer file and reorder
        // commands sit together under More (follow-up part 2, L5), with
        // the same keys: the keys run them from this one list wherever
        // they sit (`AtticMenuCommand.command(for:in:)` reads submenus).
        if single, tab != .done, unfinished {
            list.append(AtticMenuCommand(verbatim: String(localized: "Add Subtask"), startsSection: true) {
                model.beginAddingSubtask(to: menuRowID(key))
            })
        }
        list.append(AtticMenuCommand(verbatim: String(localized: "Copy"), shortcut: AtticTaskShortcut.copy,
                                     startsSection: !(single && tab != .done && unfinished)) {
            model.copy(menuTargets(key))
            pointer.endInvocation()
        })
        list.append(AtticMenuCommand(verbatim: String(localized: "Duplicate"), shortcut: AtticTaskShortcut.duplicate) {
            menuCommand(key) { model.duplicate($0) }
        })
        if single, tab != .done {
            var more = [AtticMenuCommand(verbatim: String(localized: "Open Files…"), shortcut: AtticTaskShortcut.openPage) {
                openFiles(menuRowID(key))
            }]
            // Reorder (round 10): the same rule as ⌘↑ ⌘↓ and a drag.
            if unfinished {
                more.append(AtticMenuCommand(verbatim: String(localized: "Move Up"), shortcut: AtticTaskShortcut.moveUp,
                                             isDisabled: !canMove(id, by: -1), startsSection: true) {
                    moveRow(menuRowID(key), by: -1)
                })
                more.append(AtticMenuCommand(verbatim: String(localized: "Move Down"), shortcut: AtticTaskShortcut.moveDown,
                                             isDisabled: !canMove(id, by: 1)) {
                    moveRow(menuRowID(key), by: 1)
                })
            }
            list.append(.submenu(String(localized: "More"), more))
        }
        list.append(AtticMenuCommand(verbatim: single ? String(localized: "Delete") : String(localized: "Delete \(targets.count) Tasks"),
                                     shortcut: AtticTaskShortcut.delete, isDestructive: true, startsSection: true) {
            // A menu's Delete key equivalent never reaches past a field
            // that is typing (round 5, the owner's blocker).
            guard !AtticTextInput.ownsCurrentKey else { return }
            deleteAndMoveFocus(menuTargets(key))
        })
        return list
    }

    /// Date ▸: the quick days (one tick for one day: on a Sunday, Tomorrow
    /// and Next Week are the same Monday; only the first is ticked), Pick
    /// a Date…, Remove Date.
    private func dateCommands(_ key: TasksRowID, targets: [UUID]) -> [AtticMenuCommand] {
        let choices = model.dateChoices
        let current = model.commonDueDay(targets)
        let ticked = choices.quick.first { $0.day == current }?.id
        var list = choices.quick.map { quick in
            AtticMenuCommand(verbatim: quick.menuTitle, state: quick.id == ticked ? .on : .off,
                             detail: choices.detail(for: quick.day)) {
                menuCommand(key) { model.setDueDay(quick.day, for: $0) }
            }
        }
        list.append(AtticMenuCommand(verbatim: String(localized: "Pick a Date…"), startsSection: true) {
            openMeta(.date, on: menuRowID(key), targets: menuTargets(key))
        })
        list.append(AtticMenuCommand(verbatim: String(localized: "Remove Date"), isDisabled: targets.allSatisfy { model.dueDay(of: $0) == nil },
                                     startsSection: true) {
            menuCommand(key) { model.setDueDay(nil, for: $0) }
        })
        return list
    }

    /// Tags ▸: the targets' tags, then the library's most used (twelve), a
    /// tick when every target has one and a dash when some do (review 17);
    /// All Tags… opens the searchable picker with every tag and creation.
    private func tagCommands(_ key: TasksRowID, targets: [UUID]) -> [AtticMenuCommand] {
        var list = model.tagChoices(for: targets).prefix(12).map { tag in
            AtticMenuCommand(verbatim: "#" + tag, state: model.tagState(tag, for: targets), swatch: tagColouring.hue(for: tag)) {
                menuCommand(key) { model.toggleTag(tag, for: $0) }
            }
        }
        list.append(AtticMenuCommand(verbatim: String(localized: "All Tags…"), startsSection: true) {
            openMeta(.tags, on: menuRowID(key), targets: menuTargets(key), newTag: true)
        })
        return list
    }

    /// Priority ▸: No Priority, Low, Medium, High with ⌥⌘0–3 (follow-up
    /// part 2), ticked when every target has it.
    private func priorityCommands(_ key: TasksRowID, targets: [UUID]) -> [AtticMenuCommand] {
        let priorities = Set(targets.compactMap { store.listedTask(withID: $0)?.priority })
        return TaskPriority.choices.map { priority in
            AtticMenuCommand(verbatim: priority.menuTitle, shortcut: priority.shortcut, state: priorities == [priority] ? .on : .off) {
                menuCommand(key) { model.setPriority(priority, for: $0) }
            }
        }
    }

    /// A quick-look subtask's commands (round 10), one list for its keys,
    /// its right-click menu and its VoiceOver actions: done or not (Space),
    /// Rename (Return), Move Up and Down among the subtasks in its state
    /// (⌘↑ ⌘↓), Delete (⌫, to Recently Deleted). A failure shows under
    /// the parent row with Retry.
    func subtaskCommands(_ subtask: AtticSubtaskModel, of parentID: UUID,
                                 in shown: [AtticSubtaskModel]) -> [AtticMenuCommand] {
        let siblings = shown.filter { $0.isDone == subtask.isDone }
        let index = siblings.firstIndex { $0.id == subtask.id }
        let run: (@escaping () -> CommandOutcome) -> Void = { command in
            model.report(command(), on: parentID, retry: command)
        }
        return [
            AtticMenuCommand(verbatim: subtask.isDone ? String(localized: "Mark as Not Done") : String(localized: "Mark as Done"),
                             shortcut: AtticTaskShortcut.complete) {
                run { model.toggleSubtask(subtask.id) }
            },
            AtticMenuCommand(verbatim: String(localized: "Rename"), shortcut: AtticTaskShortcut.editTitle) {
                model.beginRenamingSubtask(subtask.id)
            },
            AtticMenuCommand(verbatim: String(localized: "Move Up"), shortcut: AtticTaskShortcut.moveUp,
                             isDisabled: (index ?? 0) == 0, startsSection: true) {
                run { model.moveSubtask(subtask.id, by: -1) }
            },
            AtticMenuCommand(verbatim: String(localized: "Move Down"), shortcut: AtticTaskShortcut.moveDown,
                             isDisabled: index.map { $0 + 1 >= siblings.count } ?? true) {
                run { model.moveSubtask(subtask.id, by: 1) }
            },
            // Control audit item 5: to another task, or a task of its own.
            AtticMenuCommand(verbatim: String(localized: "Move to Task…"), startsSection: true) {
                openMeta(.move, on: parentID, targets: [subtask.id])
            },
            AtticMenuCommand(verbatim: String(localized: "Make Standalone Task")) {
                run {
                    let outcome = model.makeStandalone(subtask.id)
                    // The keyboard follows it to its new row.
                    if outcome.isApplied { setFocus(subtask.id) }
                    return outcome
                }
            },
            AtticMenuCommand(verbatim: String(localized: "Delete"), shortcut: AtticTaskShortcut.delete, isDestructive: true,
                             startsSection: true) {
                guard !AtticTextInput.ownsCurrentKey else { return }
                run { model.deleteSubtask(subtask.id) }
            }
        ]
    }

    /// Move to Task…'s list, pointing at the subtask's line, while it is
    /// open on this row (control audit item 5). Choosing a task moves the
    /// subtask there and closes it; a failure stays in it with Retry.
    private func movePopover(parentID: UUID, open: TasksMetaPopover?) -> (id: UUID, popover: AtticAnchoredPopover)? {
        guard let open, open.kind == .move, let subtaskID = open.targets.first else { return nil }
        let popover = AtticAnchoredPopover(isPresented: metaBinding(.move, id: parentID, open: open)) {
            AnyView(
                VStack(alignment: .leading, spacing: 0) {
                    TaskMovePickerView(choices: model.moveChoices(forSubtask: subtaskID)) { destination in
                        if model.pickerChange(on: parentID, { model.moveSubtask(subtaskID, toTask: destination) }) {
                            metaPopover = nil
                            setFocus(parentID)
                        }
                    }
                    TasksPickerFailureLine(model: model, id: parentID) { metaPopover = nil }
                }

                .onDisappear { model.clearPickerFailure() }
            )
        }
        return (subtaskID, popover)
    }

    /// Whether ⌘↑ (-1) or ⌘↓ (1) can move the row within its group.
    private func canMove(_ id: UUID, by step: Int) -> Bool {
        guard model.reorders(on: model.tab), let task = store.task(withID: id), task.status != .done else { return false }
        // A narrowed view moves among what it shows (item 6).
        if model.narrows(model.tab) {
            let shown = shownGroup(of: task)
            guard let index = shown.firstIndex(of: id) else { return false }
            return shown.indices.contains(index + step)
        }
        let group = store.orderGroup(of: task)
        guard let index = group.firstIndex(where: { $0.id == id }) else { return false }
        return group.indices.contains(index + step)
    }

    /// ⌘↑ ⌘↓, Move Up and Move Down, VoiceOver's "Move up" and "Move
    /// down": within the task's group; at the group's edge the hint says
    /// why (review 10).
    private func moveRow(_ id: UUID, by step: Int) {
        guard !AtticTextInput.ownsCurrentKey else { return }
        pointer.endInvocation()
        // A sorted view has no place to move a task to (item 6): the hint
        // says how to get one.
        guard model.reorders(on: model.tab) else {
            showBoundaryHint(String(localized: "Choose Manual Order to reorder"))
            return
        }
        if atGroupEdge(id, step: step) {
            showBoundaryHint()
        } else if model.narrows(model.tab), let task = store.task(withID: id) {
            // A filter or Find: one place among the tasks shown.
            let shown = shownGroup(of: task)
            guard let index = shown.firstIndex(of: id), shown.indices.contains(index + step) else { return }
            let move = { model.moveVisible(id, toShownIndex: index + step, in: shown) }
            reorderWithoutCrossing { model.report(move(), on: id, retry: move) }
        } else {
            reorderWithoutCrossing {
                model.report(model.moveBy(id, offset: step), on: id) { model.moveBy(id, offset: step) }
            }
        }
    }

    /// The rows of `task`'s state as the page shows them (item 6).
    private func shownGroup(of task: TaskItem) -> [UUID] {
        model.rows(for: model.tab).filter { $0.status == task.status }.map(\.id)
    }

    /// Full animation: two rows that exchange places by sliding past each
    /// other cross while translucent, and their titles and circles collide
    /// (round 13, review 61). The rows take their new places at once and
    /// the two that moved dissolve in there; nothing travels through
    /// another row. Reduced motion already changes places at once.
    private func reorderWithoutCrossing(_ change: () -> Void) {
        guard !design.reduceMotion else { change(); return }
        let before = model.rows(for: model.tab).map(\.id)
        // The list's placement animation is off while `reorderFade` holds
        // rows, and both change in this one update.
        change()
        let after = model.rows(for: model.tab).map(\.id)
        reorderFade = Set(after.indices.filter { before.indices.contains($0) && before[$0] != after[$0] }.map { after[$0] })
        guard !reorderFade.isEmpty else { return }
        // A run-loop timer in the common modes, not a dispatch block: the
        // menu runs its command while it is still tracking, and a block
        // queued from there waited, leaving both rows hidden for good (CI
        // run 2's recording of a menu Move Down).
        let fade = $reorderFade
        let timer = Timer(timeInterval: 0.04, repeats: false) { _ in
            MainActor.assumeIsolated {
                // The feel's spring when things spring in; otherwise (Calm,
                // Reduced) the short fade it always was.
                let pops = !AtticMotionPreference.reducesMotion && AtticMotionTuning.current.appear == .spring
                withAnimation(pops ? AtticMotionPreset.settle.animation(reduceMotion: false) : .easeOut(duration: 0.16)) {
                    fade.wrappedValue = []
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// ⇧⌘I, the actions button and VoiceOver's "Show actions": the task's
    /// whole menu (for a selection, the selection's), under `anchor` or at
    /// the row.
    private func showActions(for id: UUID, anchor: NSView?, tab: TasksTab) {
        if !model.selection.contains(id) { model.selectOnly(id) }
        // The keyboard follows the row the menu is about, so the keys after
        // it act from there (round 12, CU bug 2).
        if focusedID != id, model.selection.count == 1 { setFocus(id) }
        presentMenu(taskCommands(id, tab: tab), at: TasksRowID(tab: tab, id: id), anchor: anchor)
    }

    /// Opens the row's native menu under `anchor`, or at the row's title
    /// line, as a context menu (its submenus placed as the right-click
    /// menu's are, PR prep P3).
    private func presentMenu(_ commands: [AtticMenuCommand], at id: TasksRowID, anchor: NSView?) {
        if let anchor, anchor.window != nil {
            AtticNativeMenu.popUpContextMenu(commands, in: anchor)
        } else if let view = pointer.view, let frame = pointer.frames[id] {
            AtticNativeMenu.popUpContextMenu(commands, in: view, at: CGPoint(x: frame.minX + AtticLayout.textX, y: frame.minY + AtticLayout.rowPitch))
        } else if let view = pointer.view {
            AtticNativeMenu.popUpContextMenu(commands, in: view, at: CGPoint(x: AtticLayout.textX, y: listTop))
        }
    }

    /// VoiceOver's "Change priority": the Priority choices at the row.
    private func showPriority(for id: UUID) {
        if !model.selection.contains(id) { model.selectOnly(id) }
        if focusedID != id, model.selection.count == 1 { setFocus(id) }
        let key = TasksRowID(tab: model.tab, id: id)
        presentMenu(priorityCommands(key, targets: model.targets(for: id)), at: key, anchor: nil)
    }

    /// The row a menu command acts from: always the menu's own row.
    private func menuRowID(_ row: TasksRowID) -> UUID { row.id }

    /// What a menu command acts on: the targets its opening press took on
    /// this row (the row, or the selection it was part of then), or, for a
    /// menu no press opened, the row's targets now (round 5, F2).
    private func menuTargets(_ row: TasksRowID) -> [UUID] {
        pointer.binding(for: row)?.targets ?? model.targets(for: row.id)
    }

    /// Runs a menu command on its targets; a failure shows under the menu's
    /// row with Retry (round 4: outcomes reach the UI). The command ends
    /// the binding: the next menu is bound by its own opening.
    private func menuCommand(_ row: TasksRowID, _ command: @escaping ([UUID]) -> CommandOutcome) {
        guard !AtticTextInput.ownsCurrentKey else { return }
        let targets = menuTargets(row)
        pointer.endInvocation()
        model.report(command(targets), on: row.id) { command(targets) }
    }

    /// A press, before SwiftUI sees it. A secondary click or Control-click
    /// on a row binds the menu about to open to that row, selecting it
    /// unless it is already part of the selection (as in Finder); any other
    /// press, or one outside the list, ends the previous binding.
    private func mousePressed(_ event: NSEvent) {
        // Gated before any selection, focus or drag state changes (round 12,
        // Astra): a page kept built behind Notes or Canvas, or hidden with
        // the panel, or a press in another window, takes nothing. The
        // monitor stays installed while the page is kept, so a right-click
        // in Notes over a hidden row's position selected that task and
        // bound a menu to it.
        guard model.isPageShown, !model.isHidden, let window = pointer.view?.window, window.isVisible,
              event.window === window else {
            pointer.endInvocation()
            return
        }
        dragSession.newPress()
        // A plain click in the list that no row takes (the space under the
        // rows, a day heading, Done's search) clears the selection and the
        // keyboard's row, as in a native list (round 5: the owner's Done
        // row stayed lit after a click elsewhere).
        let bandTop = TasksBottomBand.height(stack: bottomStack.height, bottomInset: bottomInset)
        // A plain click on the tabs' line (the search field, or back into
        // a search already open): no row stays lit (round 7, R3).
        if searchShown, event.type == .leftMouseDown,
           event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty,
           let point = pointer.location(of: event), point.y < listTop - AtticLayout.pageTabsToList / 2,
           point.y > layout.headerBottom {
            if !model.selection.isEmpty { model.clearSelection() }
            if focusedRow != nil {
                if Self.isOnSearchField(event, in: window, placeholder: model.searchPlaceholder(for: model.tab)) {
                    // A click on the query's own text, which the field
                    // takes with the click: the row lets go of the keyboard
                    // now, before it. Cleared through the focus state, the
                    // row's focus went after the click and took the
                    // keyboard from the field to the panel, so ↓ reached
                    // nothing (CU recheck 4b, P2).
                    focusedRow = nil
                    window.contentView?.layoutSubtreeIfNeeded()
                } else {
                    focusedRow = nil
                }
            }
        }
        if pointer.isPlainPressOutsideRows(event, tab: model.tab, top: listTop - AtticLayout.pageTabsToList / 2,
                                           bottomInset: bandTop) {
            if !model.selection.isEmpty { model.clearSelection() }
            if focusedRow != nil { focusedRow = nil }
        }
        // Only the rows' visible part: between the tabs' band and the
        // bottom stack's band (round 7, R4).
        pointer.press(event, tab: model.tab, below: listTop - AtticLayout.pageTabsToList / 2, aboveBottom: bandTop) { id in
            if !model.selection.contains(id) { model.selectOnly(id) }
            return model.targets(for: id)
        }
    }

    // MARK: - Keys

    /// The row the keys act from: the row that shows the keyboard, unless a
    /// programmatic selection (the actions menu, a restore) has since moved
    /// the selection elsewhere, in which case the selection wins so a key
    /// never acts from a stale row (round 12, CU bug 2). With no row focused,
    /// the one selected row.
    private func keyboardRow(visible: [UUID]) -> UUID? {
        let live = Set(visible)
        let selected = model.selection.intersection(live)
        if let focused = focusedID, live.contains(focused), selected.isEmpty || selected.contains(focused) { return focused }
        if selected.count == 1 { return selected.first }
        return nil
    }

    /// The quick-look subtask that has the keyboard, with its parent row and
    /// its commands: the one answer to "does a subtask own this key", read
    /// from the focus the subtask line itself reports (Tab, a click).
    private func subtaskKeyboardOwner(visible: [UUID]) -> (parent: UUID, commands: [AtticMenuCommand])? {
        guard let focused = model.focusedSubtaskID else { return nil }
        let live = Set(visible)
        guard let row = model.rows(for: model.tab).first(where: { live.contains($0.id) && $0.subtasks.contains { $0.id == focused } }),
              let subtask = row.subtasks.first(where: { $0.id == focused }) else { return nil }
        return (row.id, subtaskCommands(subtask, of: row.id, in: row.subtasks))
    }

    /// The list's keys (spec § Keyboard map, Tasks row): ↑ ↓ move, ⇧↑ ⇧↓
    /// extend, ⌘↑ ⌘↓ reorder, Return edits the title, → and ← open and close
    /// the quick look, Esc closes it or clears a selection, ⌘A selects all,
    /// ⌘Z and ⇧⌘Z undo and redo. Space, ⇧Space, ⌘B, Delete and ⌘Return are
    /// the row's own (`AtticTaskKeys`).
    private func pageKey(_ press: KeyPress) -> KeyPress.Result {
        // A field that is typing keeps every key, ⌘Z included (round 5:
        // the owner's Backspace in the tag picker deleted the task).
        guard !AtticTextInput.hasKeyboard else { return .ignored }
        let modifiers = press.modifiers.intersection([.command, .shift, .option, .control])
        if press.key == KeyEquivalent("z") || press.characters.lowercased() == "z" {
            // ⌘Z with no field typing: the Tasks history (Astra 23). The
            // window's undo manager is never called from here.
            if modifiers == .command { model.undo(); return .handled }
            if modifiers == [.command, .shift] { model.redo(); return .handled }
        }
        // Typing on Done faster than the search field takes the keyboard
        // (it appears, then focuses): the letters join the query, never
        // lost (round 8, CI run 3: "inv" became "i").
        if searchFocused, model.isPageShown, modifiers.isEmpty || modifiers == .shift,
           Self.startsSearch(press.characters) {
            let text = model.searchQuery(for: model.tab) + press.characters
            if model.tab == .done { model.typeDoneSearch(text) }
            else { model.setSearchQuery(text, for: model.tab) }
            return .handled
        }
        // Every editor keeps its own keys (review 8): the title, a new
        // subtask, the add bar and Done's search.
        guard model.editingTitleID == nil, model.newSubtaskParentID == nil, model.renamingSubtaskID == nil,
              !addBarFocused, !searchFocused else { return .ignored }
        // Typing on the Done page starts a search there (owner item 17):
        // the letter is the query's first, the field takes the tabs' line.
        // Now and Later open Find with ⌘F or the magnifier only (item 6):
        // their letters may be a draft reaching the add bar a moment late.
        if model.tab == .done, model.isPageShown, modifiers.isEmpty || modifiers == .shift, Self.startsSearch(press.characters) {
            model.typeDoneSearch(press.characters)
            beginSearch()
            return .handled
        }
        let visible = visibleIDs()
        // The focused row, or the one selected row when the keyboard is
        // elsewhere in the page (a click on a row in a panel that was not
        // key yet can leave focus on the page's first control).
        var current = keyboardRow(visible: visible)
        // A subtask that has the keyboard (Tab, a click) owns its keys, ahead
        // of its parent's: SwiftUI hands a key to this page's handler before
        // the focused subtask's own, so ⌘↑ ⌘↓ and Return would otherwise move
        // and rename the parent (round 13). Any other key acts from the
        // parent, as ↑ ↓ and Esc always did.
        if let owner = subtaskKeyboardOwner(visible: visible) {
            if AtticMenuCommand.performSubtaskKey(key: press.key, characters: press.characters,
                                                  modifiers: press.modifiers, in: owner.commands) == .handled { return .handled }
            current = owner.parent
        }
        switch press.key {
        case .downArrow, .upArrow:
            let step = press.key == .downArrow ? 1 : -1
            guard let current, let index = visible.firstIndex(of: current) else {
                let first = step > 0 ? visible.first : visible.last
                setFocus(first)
                if let first { model.selectOnly(first) }
                focusTracker.noteKeyboardNavigation()
                return .handled
            }
            if modifiers == .command {
                // The same rule as a drag (review 10): a task moves within
                // its group; at the group's edge the hint says why.
                guard model.tab != .done else { return .handled }
                moveRow(current, by: step)
                return .handled
            }
            let next = visible[min(max(index + step, 0), visible.count - 1)]
            setFocus(next)
            if modifiers == .shift {
                model.extendSelection(to: next, visible: visible, from: current)
            } else {
                model.selectOnly(next)
            }
            return .handled
        case .return where modifiers.isEmpty:
            // Done's rows too (round 10).
            guard let current else { return .ignored }
            model.beginEditingTitle(current)
            return .handled
        case .rightArrow where modifiers.isEmpty:
            guard let current, model.tab != .done else { return .ignored }
            model.setExpanded(current, true)
            return .handled
        case .leftArrow where modifiers.isEmpty:
            guard let current, model.expanded.contains(current) else { return .ignored }
            model.setExpanded(current, false)
            return .handled
        case .escape:
            return handleEscape(visible: visible, current: current) ? .handled : .ignored
        default:
            if modifiers == .command, press.characters.lowercased() == "a", let first = visible.first, let last = visible.last {
                model.selectOnly(first)
                model.extendSelection(to: last, visible: visible)
                return .handled
            }
            return .ignored
        }
    }

    /// A key that starts a Done search: one printable character, not a
    /// space (Space completes) and not a function key (arrows, Page Up).
    nonisolated static func startsSearch(_ characters: String) -> Bool {
        guard characters.count == 1, let character = characters.first, !character.isWhitespace, !character.isNewline else { return false }
        return character.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }

    // MARK: - Drag

    /// A row's height as laid out (its quick look, an error or an editor
    /// under it included; round 4), or, before it has been laid out, from
    /// what it shows: 34 pt, 48 with a details line, plus the quick look.
    private func rowHeight(_ id: UUID, in tab: TasksTab) -> CGFloat {
        if let measured = pointer.frames[TasksRowID(tab: tab, id: id)]?.height, measured > 0 { return measured }
        guard let row = model.rows(for: tab).first(where: { $0.id == id }) else { return AtticLayout.rowPitch }
        let pitch = row.model.hasDetails ? AtticLayout.detailRowPitch : AtticLayout.rowPitch
        guard model.expanded.contains(id), row.status != .done else { return pitch }
        return pitch + CGFloat(row.subtasks.count + 2) * AtticLayout.subtaskPitch + AtticQuickLookMetrics.bottomPadding
    }

    /// A drag began: a timer while it lasts reads Esc (SwiftUI's mouse
    /// tracking holds key events until the button is up, so the key's own
    /// state is read) and scrolls the list near its edges.
    private func beginDragSession(in tab: TasksTab) {
        dragSession.timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { dragTick(in: tab) }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragSession.timer = timer
    }

    private func dragTick(in tab: TasksTab) {
        guard let current = drag, !dragSession.isCancelled else { return }
        // Esc while the button is down cancels: nothing moves, and the
        // release commits nothing.
        if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(53)) {
            cancelDrag()
            return
        }
        // Out of the panel's window, the reorder becomes a drag to another
        // app (owner-approved, 2026-10-01): a copy as text, nothing moves.
        if let location = dragSession.location, let view = pointer.view, let window = view.window,
           Self.leavesPanel(view.convert(location, to: nil), in: window) {
            beginDragOut(current, at: location)
            return
        }
        guard let location = dragSession.location,
              let scrollView = listScrollView(at: location) else { return }
        let step = TasksDragSession.autoScrollStep(
            y: location.y, top: listTop,
            bottom: (pointer.view?.bounds.height ?? 0) - bottomClearance
        )
        guard step != 0 else { return }
        let clip = scrollView.contentView
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
        var origin = clip.bounds.origin
        let before = origin.y
        origin.y = min(max(origin.y + step, -clip.contentInsets.top), maxY)
        let moved = origin.y - before
        guard moved != 0 else { return }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        var next = current
        next.scrolled += moved
        let total = dragSession.translation + next.scrolled
        next.targetIndex = TasksReorderCell<EmptyView, EmptyView>.target(
            start: current.startIndex, translation: total, group: current.group, heights: { rowHeight($0, in: tab) }
        )
        drag = next
    }

    /// Whether a row's drag reorders (Now's and Later's manual order) or
    /// only carries it out of the panel (a sorted view, Done).
    nonisolated static func reorders(tab: TasksTab, manual: Bool) -> Bool {
        tab != .done && manual
    }

    /// Whether a window point is outside the panel's visible surface (its
    /// window's frame without the transparent shadow margin).
    static func leavesPanel(_ windowPoint: CGPoint, in window: NSWindow) -> Bool {
        let screen = window.convertPoint(toScreen: windowPoint)
        let surface = (window as? AtticPanel)?.visibleContentFrame ?? window.frame
        return !surface.contains(screen)
    }

    /// The reorder left the panel: it ends where it started (nothing moves),
    /// and the dragged tasks (the whole selection when the row is part of
    /// it) go on as a copy, as text, Markdown and RTF.
    private func beginDragOut(_ current: TasksDrag, at location: CGPoint) {
        let ids = model.selection.contains(current.id) && model.selection.count > 1 ? model.orderedSelection() : [current.id]
        let export = model.export(ids)
        cancelDrag()
        guard let export, let view = pointer.view else { return }
        if let start = pointer.startDragOut {
            start(export, location)
            return
        }
        TasksDragOut.begin(export, count: ids.count, from: view, at: location) { [dragSession] in
            // The drag ate the button's release: the next press starts afresh.
            dragSession.end()
        }
    }

    /// The list's scroll view under a page point (the page's current tab).
    private func listScrollView(at point: CGPoint) -> NSScrollView? {
        guard let page = pointer.view, let window = page.window else { return nil }
        let windowPoint = page.convert(point, to: nil)
        var found: NSScrollView?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, !scroll.isHiddenOrHasHiddenAncestor,
               scroll.convert(scroll.bounds, to: nil).contains(windowPoint),
               (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height {
                found = scroll
            }
            view.subviews.forEach(visit)
        }
        if let content = window.contentView { visit(content) }
        return found
    }

    /// Cancels the drag in progress: the row settles back, the neighbours
    /// return, and its release commits nothing.
    private func cancelDrag() {
        guard drag != nil else { return }
        dragSession.cancel()
        dragSession.timer?.invalidate()
        dragSession.timer = nil
        drag = nil
        pointer.liftedCard.end()
    }

    /// The lifted card: the row as it is, never interactive.
    @ViewBuilder
    private func liftedCardRow(_ lift: TasksLiftedCard.Lift) -> some View {
        // Done's rows are its log's (a drag out of Done lifts one too).
        let rows = lift.tab == .done ? model.doneDays().flatMap(\.rows) : model.rows(for: lift.tab)
        if let row = rows.first(where: { $0.id == lift.id }) {
            AtticTaskRow(model: row.model, isSelected: model.selection.contains(lift.id),
                         selectionRun: .single, actions: actions(for: lift.id, in: lift.tab), onToggleExpanded: {})
        }
    }

    /// The drop: the card settles into the gap the neighbours opened (the
    /// Lively settle; at once when motion is reduced), then the move is
    /// one step, committed with nothing animating, so the row appears
    /// exactly where the card lies. The lift clears whether the save works
    /// or not.
    private func finishDrag(_ finished: TasksDrag) {
        // The keyboard comes to the moved row, so ⌘Z (and Esc) reach the
        // list right after a drop.
        setFocus(finished.id)
        let commit = {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                drag = nil
                pointer.liftedCard.end()
                if finished.targetIndex != finished.startIndex {
                    // A filter or Find: among the rows shown (item 6).
                    let narrowed = model.narrows(model.tab)
                    let move = {
                        narrowed ? model.moveVisible(finished.id, toShownIndex: finished.targetIndex, in: finished.group)
                                 : model.move(finished.id, toGroupIndex: finished.targetIndex)
                    }
                    let moved = model.report(move(), on: finished.id, retry: move)
                    // The tick confirms a move that saved, never a failed one.
                    if moved.isApplied { AtticHaptics.tick(enabled: design.hapticsEnabled) }
                }
            }
        }
        guard !design.reduceMotion, let lift = pointer.liftedCard.lift, lift.id == finished.id else {
            commit()
            return
        }
        var landing = finished
        landing.scrolled = drag?.id == finished.id ? (drag?.scrolled ?? finished.scrolled) : finished.scrolled
        landing.landing = true
        drag = landing
        let y = TasksLiftedCard.landing(of: landing, originY: lift.origin.minY, heights: { rowHeight($0, in: finished.tab) })
        withAnimation(AtticMotionPreset.settle.animation(reduceMotion: false)) {
            pointer.liftedCard.land(at: y)
        } completion: {
            // Only the drag that landed (a new press may have begun).
            guard drag?.id == finished.id, drag?.landing == true else { return }
            commit()
        }
    }

    /// ⌘↑ ⌘↓ at the first or last place of a group, with the neighbouring
    /// group right there: started and not started tasks stay apart.
    private func atGroupEdge(_ id: UUID, step: Int) -> Bool {
        guard model.tab != .done else { return false }
        let rows = model.rows(for: model.tab)
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return false }
        let neighbour = index + step
        guard rows.indices.contains(neighbour) else { return false }
        return rows[neighbour].status != rows[index].status && rows[neighbour].status != .done && rows[index].status != .done
    }

    /// "Started tasks stay together" for two seconds (review 10), or why a
    /// sorted view does not reorder (item 6).
    private func showBoundaryHint(_ message: String = String(localized: "Started tasks stay together")) {
        boundaryHintTask?.cancel()
        boundaryHintText = message
        withAnimation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion)) { boundaryHint = true }
        AccessibilityNotification.Announcement(message).post()
        boundaryHintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(AtticMotionPreset.popover.leaveAnimation(reduceMotion: design.reduceMotion)) { boundaryHint = false }
        }
    }

    // MARK: - Files

    /// The row a file over `point` (the page's space) would land on: one
    /// of the page shown, in the lists' band (not under the tabs or the
    /// bottom stack). Done's rows take no files.
    private func fileDropTarget(at point: CGPoint) -> UUID? {
        guard model.tab != .done, let height = pointer.view?.bounds.height,
              pagerBand.contains(point, height: height, stackHeight: bottomStack.height) else { return nil }
        return Self.row(at: point, frames: pointer.frames, tab: model.tab, among: Set(model.rows(for: model.tab).map(\.id)))
    }

    /// The row among `ids` on `tab`'s page whose frame holds `point` (pure,
    /// tested). Frames are keyed by page and task: a task drawn on two
    /// pages is two rows, and only the page shown answers (round 12).
    static func row(at point: CGPoint, frames: [TasksRowID: CGRect], tab: TasksTab, among ids: Set<UUID>) -> UUID? {
        frames.first { $0.key.tab == tab && ids.contains($0.key.id) && $0.value.contains(point) }?.key.id
    }

    private func attachDroppedFiles(_ content: TaskDropContent, _ providers: [NSItemProvider], to id: UUID) {
        fileDropRow = nil
        guard content == .files, let owner = store.attachmentOwnerID(for: id) else { return }
        Task { @MainActor in
            guard let ids = await store.attachStagedFiles(to: owner, stage: { try await TaskDroppedFiles.stage(providers) }) else { return }
            let title = store.task(withID: owner)?.title ?? ""
            AccessibilityNotification.Announcement(
                ids.count == 1 ? String(localized: "Added 1 file to \(title)") : String(localized: "Added \(ids.count) files to \(title)")
            ).post()
        }
    }

    // MARK: - Bottom controls

    private var bottomControls: some View {
        VStack(alignment: .leading, spacing: AtticSpacing.s8) {
            if model.failedSave == .paste {
                AtticErrorLine(message: String(localized: "Not saved"), onRetry: { model.retryPaste() })
            }
            if boundaryHint {
                TasksBoundaryHint(text: boundaryHintText)
                    .transition(AtticMotionPreset.popover.transition(reduceMotion: design.reduceMotion))
            }
            // A paste offer owns the area over the bar while it asks; the
            // selection bar shows when the add bar is not being used.
            if let offer = model.pasteOffer {
                pasteOfferBar(offer)
                    .frame(maxWidth: .infinity)
                    .transition(AtticMotionPreset.popover.transition(reduceMotion: design.reduceMotion))
            } else if model.selection.count > 1, model.tab != .done, !addBarFocused {
                selectionBar
                    .frame(maxWidth: .infinity)
                    .transition(AtticMotionPreset.popover.transition(reduceMotion: design.reduceMotion))
            }
            addBar
        }
        // The lists' clearance changes only past the room always kept for
        // the strip (a selection bar, a paste offer): the strip appearing
        // with the first keystroke never re-lays the lists.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            bottomStack.height = height
            let clearance = max(height, TasksViewport.reservedStack)
            if bottomControlsHeight != clearance { bottomControlsHeight = clearance }
        }
        .padding(.horizontal, max(AtticSpacing.panelMargin, layout.chromeInsets.leading))
        .padding(.bottom, bottomInset)
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion, showing: model.selection.count > 1),
                   value: model.selection.count > 1)
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion, showing: model.pasteOffer != nil),
                   value: model.pasteOffer)
        .onChange(of: model.selection.count > 1) { _, _ in PerformanceSignposts.watchFrames("SelectionBarMotion", seconds: 0.35) }
    }

    /// The add bar always adds (Direction A): on Done it adds to Now; the
    /// Done log's search is a field at the top of its list. Its strip and
    /// suggestions belong to it (review 14).
    private var addBar: some View {
        TasksAddBar(model: model, text: model.addBarState, isFocused: $addBarFocused, editor: addBarEditor,
                    showsStrip: model.pasteOffer == nil,
                    pickerOpen: $composerPickerOpen, leave: leaveAddBar,
                    added: { _ in })
    }


    /// Esc in the add bar with nothing of its own to
    /// close: the keyboard leaves the field. The next Esc reaches the panel,
    /// which hides (spec § Keyboard map).
    private func leaveAddBar() -> Bool {
        guard addBarFocused else { return false }
        addBarFocused = false
        return true
    }

    private func pasteOfferBar(_ offer: TaskPasteOffer) -> some View {
        let height = AtticControlSize.smallHeight + AtticControlSize.capsuleInset * 2
        return HStack(spacing: AtticSelectionBarMetrics.controlSpacing) {
            AtticSmallButton(systemName: nil, title: "Add \(offer.lineCount) tasks", label: "Add \(offer.lineCount) tasks") {
                model.acceptPaste(asOne: false)
            }
            AtticSmallButton(systemName: nil, title: "Add as one task", label: "Add as one task") {
                model.acceptPaste(asOne: true)
            }
            AtticSmallButton(systemName: "xmark", label: "Cancel") { model.dismissPasteOffer() }
        }
        .padding(AtticControlSize.capsuleInset)
        .frame(height: height)
        .atticRaisedMaterial(cornerRadius: AtticRadius.control(height: height), interactive: false)
    }

    private var selectionBar: some View {
        let ids = model.orderedSelection()
        let count = ids.count
        let first = ids.first
        // Moving off the page ends the selection (computer-use bug 5):
        // Later and Now go through the moves, which clear it and confirm
        // with an Undo toast.
        // A failure shows under the first selected row, with Retry.
        let run: (@escaping () -> CommandOutcome) -> Void = { command in
            guard let first else { return }
            model.report(command(), on: first, retry: command)
        }
        let move: (TaskStatus) -> Void = { status in
            if status == .backlog, model.tab != .backlog { run { model.moveToBacklog(ids) } }
            else if status == .todo, model.tab == .backlog { run { model.moveToNow(ids) } }
            else { run { model.setStatus(status, for: ids) } }
        }
        // Each button says what it does and to how many (tooltip and
        // VoiceOver, review UX 4). Its choices are read as the menu opens.
        return AtticSelectionBar(count: count, actions: [
            .init(systemName: "checkmark.circle", label: "Set state of \(count) tasks", handler: {}, menu: {
                let states = Set(ids.compactMap { store.task(withID: $0)?.status })
                return [TaskStatus.todo, .inProgress, .done, .backlog].map { status in
                    AtticMenuCommand(verbatim: status.menuTitle, state: states == [status] ? .on : .off) { move(status) }
                }
            }),
            .init(systemName: "exclamationmark", label: "Set priority of \(count) tasks", handler: {}, menu: {
                let priorities = Set(ids.compactMap { store.task(withID: $0)?.priority })
                // Ticked when every selected task has it, as the tags are.
                return TaskPriority.choices.map { priority in
                    AtticMenuCommand(verbatim: priority.menuTitle, shortcut: priority.shortcut,
                                     state: priorities == [priority] ? .on : .off) {
                        run { model.setPriority(priority, for: ids) }
                    }
                }
            }),
            // Round 10: Date and every tag (search, creation, mixed states)
            // as the row pickers show them, for the whole selection.
            .init(systemName: "calendar", label: "Set date of \(count) tasks", handler: { selectionPicker = .date },
                  popover: AtticAnchoredPopover(isPresented: selectionPickerBinding(.date), content: {
                      AnyView(selectionDatePicker(ids))
                  })),
            .init(systemName: "number", label: "Tag \(count) tasks", handler: { selectionPicker = .tags },
                  popover: AtticAnchoredPopover(isPresented: selectionPickerBinding(.tags), content: {
                      AnyView(selectionTagPicker(ids))
                  })),
            model.tab == .backlog
                ? .init(systemName: "tray.and.arrow.up", label: "Move \(count) tasks to Now", handler: { run { model.moveToNow(ids) } })
                : .init(systemName: "tray.and.arrow.down", label: "Move \(count) tasks to Later", handler: { run { model.moveToBacklog(ids) } }),
            .init(systemName: "trash", label: "Delete \(count) tasks", handler: { deleteAndMoveFocus(ids) })
        ], summary: selectionSummary(ids))
    }

    /// The selection bar's Date or Tags picker, while open (round 10).
    enum SelectionPicker: Equatable { case date, tags }

    private func selectionPickerBinding(_ picker: SelectionPicker) -> Binding<Bool> {
        Binding(get: { selectionPicker == picker }, set: { open in
            if open { selectionPicker = picker } else if selectionPicker == picker { selectionPicker = nil }
        })
    }

    private func selectionDatePicker(_ ids: [UUID]) -> some View {
        let anchor = ids.first ?? UUID()
        return VStack(alignment: .leading, spacing: 0) {
            TaskDatePickerView(
                choices: model.dateChoices,
                selected: model.commonDueDay(ids),
                forRow: true,
                onPick: { day in
                    if model.pickerChange(on: anchor, { model.setDueDay(day, for: ids) }) { selectionPicker = nil }
                },
                onRemove: {
                    if model.pickerChange(on: anchor, { model.setDueDay(nil, for: ids) }) { selectionPicker = nil }
                }
            )
            TasksPickerFailureLine(model: model, id: anchor) { selectionPicker = nil }
        }
        .onDisappear { model.clearPickerFailure() }
    }

    private func selectionTagPicker(_ ids: [UUID]) -> some View {
        let anchor = ids.first ?? UUID()
        return VStack(alignment: .leading, spacing: 0) {
            TaskTagPickerView(
                allTags: model.tagChoices(for: ids),
                state: { model.tagState($0, for: ids) },
                onToggle: { tag in model.pickerChange(on: anchor) { model.toggleTag(tag, for: ids) } },
                onCreate: { tag, completed in
                    model.pickerChange(on: anchor, onSaved: completed) { model.toggleTag(tag, for: ids) }
                },
                focusField: true
            )
            TasksPickerFailureLine(model: model, id: anchor, closeOnRetrySuccess: nil)
        }
        .onDisappear { model.clearPickerFailure() }
    }

    /// What VoiceOver hears after "N selected": what the selected tasks
    /// share, or that they differ ("mixed priority, due Friday, tagged
    /// launch, some tagged home").
    private func selectionSummary(_ ids: [UUID]) -> String {
        let tasks = ids.compactMap { store.listedTask(withID: $0) }
        guard !tasks.isEmpty else { return "" }
        var parts: [String] = []
        let states = Set(tasks.map(\.status))
        parts.append(states.count == 1 ? (states.first.map { $0.menuTitle } ?? "") : String(localized: "mixed state"))
        let priorities = Set(tasks.map(\.priority))
        if priorities.count > 1 {
            parts.append(String(localized: "mixed priority"))
        } else if let priority = priorities.first, priority != .none {
            parts.append(priority.spokenTitle)
        }
        let days = Set(tasks.map(\.dueDay))
        if days.count > 1 {
            parts.append(String(localized: "mixed dates"))
        } else if let day = days.first ?? nil {
            parts.append(String(localized: "due \(model.dueText(day))"))
        }
        let tags = model.tagChoices(for: ids)
        let all = tags.filter { model.tagState($0, for: ids) == .on }
        let some = tags.filter { model.tagState($0, for: ids) == .mixed }
        if !all.isEmpty { parts.append(String(localized: "tagged \(all.joined(separator: ", "))")) }
        if !some.isEmpty { parts.append(String(localized: "some tagged \(some.joined(separator: ", "))")) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Redraws

/// Whether the page's search showed when the page last drew.
final class TasksDrawnSearch {
    var shown = false
}

/// What a row's cell last reported: its frame in the page and its
/// controls' frames in the row. A Done cell can draw another task after a
/// new query (`TasksDoneSlots`); what it reported then moves to that task.
final class TasksCellReports {
    var frame: CGRect?
    var controls: [CGRect]?
}

/// Where the page reaches its rows' focus state, which `TasksRowFocusOwner`
/// holds: set as the owner draws the page, read by the page's handlers.
@MainActor
final class TasksRowFocusLink {
    var binding: FocusState<AtticRowFocusID?>.Binding!

    private static var generation: UInt64 = 0
    /// A new number each time the page's body runs (`TasksPageFocusedContent`).
    static func nextGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }
}

/// Owns the rows' `FocusState` for the Tasks page. SwiftUI redraws a focus
/// state's owner when the focus system's views change (a list building or
/// letting go of focusable rows), so the owner is this small view: it hands
/// the page's content the binding, and the content is redrawn only when
/// the page's body ran again or the focused row changed.
struct TasksRowFocusOwner<Content: View>: View {
    @FocusState private var focusedRow: AtticRowFocusID?
    @ViewBuilder let content: (FocusState<AtticRowFocusID?>.Binding) -> Content

    var body: some View { content($focusedRow) }
}

/// The Tasks page's content under its focus owner: equal (not redrawn)
/// while the page's body has not run again and the focused row is the same.
struct TasksPageFocusedContent<Content: View>: View, Equatable {
    let generation: UInt64
    let focusedRow: AtticRowFocusID?
    @ViewBuilder let content: () -> Content

    var body: some View { content() }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated { lhs.generation == rhs.generation && lhs.focusedRow == rhs.focusedRow }
    }
}

/// The page redraws from its own observed state (the model, the store); a
/// parent redrawing (a lock, the panel's key state, another page showing)
/// passes the same inputs and does not redraw the list. The chrome's
/// callbacks are the shell's and do not change what the page shows.
extension TasksPage: Equatable {
    nonisolated static func == (lhs: TasksPage, rhs: TasksPage) -> Bool {
        MainActor.assumeIsolated {
            lhs.model === rhs.model && lhs.store === rhs.store && lhs.layout == rhs.layout
                && lhs.addBarFocused == rhs.addBarFocused
        }
    }
}

// MARK: - Add bar

/// The add bar, observing its own text: a keystroke redraws the bar, never
/// the list above it (spec: one frame per keystroke). Its strip (Date · Tag ·
/// Priority, owner fix 5 A2) shows for a draft and while one of its pickers
/// is open; the suggestions (5 B) float above it while a `#tag` or a date
/// word is being typed.
private struct TasksAddBar: View {
    @ObservedObject var model: TasksPageModel
    @ObservedObject var text: TasksAddBarState
    @Binding var isFocused: Bool
    let editor: AtticTokenFieldEditor
    /// A paste offer owns the area over the bar while it asks.
    let showsStrip: Bool
    @Binding var pickerOpen: Bool
    let leave: () -> Bool
    let added: (UUID) -> Void

    @Environment(\.atticDesign) private var design
    @State private var datePresented = false
    @State private var tagsPresented = false
    @State private var priorityPresented = false

    private var hasDraft: Bool { !text.text.text.trimmingCharacters(in: .whitespaces).isEmpty }

    private var suggestion: TaskAddBarText.Suggestion? {
        guard isFocused else { return nil }
        return Self.suggestion(model: model, text: text)
    }

    static func suggestion(model: TasksPageModel, text: TasksAddBarState) -> TaskAddBarText.Suggestion? {
        guard let suggestion = text.text.suggestion(parser: model.parser, caret: text.caret, tags: model.cachedTags),
              suggestion.range != text.hiddenSuggestion else { return nil }
        return suggestion
    }

    /// The suggestion list shows over the focused bar (it takes Tab).
    static func showsSuggestion(model: TasksPageModel, text: TasksAddBarState) -> Bool {
        suggestion(model: model, text: text) != nil
    }

    var body: some View {
        let suggestion = suggestion
        let anyPicker = datePresented || tagsPresented || priorityPresented
        let stripShown = showsStrip && (hasDraft || anyPicker)
        // What the new task will get, typed or picked (owner item 18): the
        // strip's buttons show it, and its pickers tick it.
        let parts = text.text.parts(parser: model.parser)
        VStack(alignment: .leading, spacing: AtticPickerMetrics.stripToBar) {
                AtticComposerStrip(
                    datePresented: $datePresented,
                    tagsPresented: $tagsPresented,
                    priorityPresented: $priorityPresented,
                    date: parts.dueDay.map { day in
                        let words = model.dueText(day)
                        return AtticStripValue(text: words, spoken: words)
                    },
                    tags: TasksComposerValues.tags(parts.tags),
                    priority: TasksComposerValues.priority(parts.priority),
                    onClearDate: { model.clearComposer(.date, editor: editor); editor.focus() },
                    onClearTags: { model.clearComposer(.tags, editor: editor); editor.focus() },
                    onClearPriority: { model.clearComposer(.priority, editor: editor); editor.focus() },
                    datePicker: {
                        TaskDatePickerView(choices: model.dateChoices, selected: parts.dueDay, onPick: { day in
                            datePresented = false
                            model.pickDate(day, editor: editor)
                        })
                    },
                    tagPicker: {
                        // Ticks and unticks, and stays open (as a row's).
                        TaskTagPickerView(
                            allTags: model.composerTagChoices,
                            state: { model.composerTagState($0) },
                            onToggle: { model.toggleComposerTag($0, editor: editor) },
                            onCreate: { name, _ in
                                model.toggleComposerTag(name, editor: editor)
                                return true
                            },
                            focusField: true
                        )
                    },
                    priorityPicker: {
                        TaskPriorityPickerView(current: parts.priority, onPick: { priority in
                            priorityPresented = false
                            model.pickPriority(priority, editor: editor)
                        })
                    }
                )
                // The first icon on the circles' line (x 36), as the bar's plus.
                .padding(.leading, AtticAddBarMetrics.iconSlot / 2 - AtticSmallControlMetrics.labelPadding - AtticSmallControlMetrics.iconSize / 2)
                // Built with the bar and shown by a frame and an opacity, as
                // the send button is: the first keystroke changes those,
                // never builds the strip (spec: one frame per keystroke).
                .frame(height: stripShown ? AtticControlSize.smallHeight : 0, alignment: .top)
                .opacity(stripShown ? 1 : 0)
                // It rises into place with the bar's spring (round 9).
                .offset(y: stripShown || design.reduceMotion ? 0 : AtticMotionPreset.popover.rise)
                // And pops from the bar's corner in the spring style.
                .scaleEffect(stripShown ? 1 : AtticMotionPreset.popover.hiddenScale(reduceMotion: design.reduceMotion),
                             anchor: .bottomLeading)
                .allowsHitTesting(stripShown)
                .accessibilityHidden(!stripShown)
                .padding(.bottom, stripShown ? 0 : -AtticPickerMetrics.stripToBar)
            AtticAddBar(
                placeholder: model.addPlaceholder,
                text: $text.text.text,
                tokens: AtticAddBar.Tokens(
                    chips: text.text.tokenChips(parser: model.parser, caret: text.caret),
                    isFocused: $isFocused,
                    actions: AtticTokenFieldActions(
                        submit: { command in submit(openingPage: command) },
                        dismissChip: { range in
                            // Turning a chip into text is a step of its own:
                            // ⌘Z makes it a chip again (round 4).
                            text.history.checkpoint(text.text, selection: text.currentSelection)
                            text.text.dismiss(range)
                        },
                        multilinePaste: { pasted in
                            guard let offer = TaskPasteOffer(pasted) else { return false }
                            model.pasteOffer = offer
                            return true
                        },
                        escape: {
                            if model.pasteOffer != nil { model.dismissPasteOffer(); return true }
                            return leave()
                        },
                        edited: { range, replacement in
                            model.noteTextEdit()
                            model.addBarEdited(range, replacement: replacement)
                        },
                        caretMoved: { caret in model.addBarCaretMoved(caret) },
                        suggestionKey: { key in suggestionKey(key) },
                        undoDraft: { model.taskChangeOwnsUndo ? nil : text.undoDraft() },
                        redoDraft: { model.taskChangeOwnsRedo ? nil : text.redoDraft() },
                        selectionMoved: { text.selection = $0 },
                        // Spec § Undo: typing first, then the page (the
                        // task just added, round 5's CI).
                        undoFallback: { model.undo() },
                        redoFallback: { model.redo() }
                    ),
                    editor: editor
                ),
                onSubmit: { submit(openingPage: false) }
            )
        }
        .atticDropdown(isPresented: Binding(get: { suggestion != nil }, set: { shown in
            if !shown, let suggestion { text.hiddenSuggestion = suggestion.range }
        }), prefer: .above, label: String(localized: "Suggestions"), takesKeyboard: false, contentHasCard: true,
                         contentHeight: suggestion.map { CGFloat($0.count) * AtticDropdownMetrics.rowHeight + AtticDropdownMetrics.inset * 2 },
                         contentWidth: suggestion.map { AtticSuggestionList.idealWidth(items(for: $0)) }) {
            if let suggestion {
                AtticSuggestionList(items: items(for: suggestion), highlighted: min(text.highlighted, suggestion.count - 1),
                                    onHover: { index in if text.highlighted != index { text.highlighted = index } }) { index in
                    model.accept(suggestion, choice: index, editor: editor)
                    text.highlighted = 0
                }
            }
        }
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion, showing: stripShown), value: stripShown)
        .onChange(of: stripShown) { _, _ in PerformanceSignposts.watchFrames("StripMotion", seconds: 0.35) }
        .onChange(of: datePresented || tagsPresented || priorityPresented) { _, open in
            pickerOpen = open
            // A closed picker hands the keyboard back to the draft, where
            // its insertion point was (review 14).
            if !open { editor.focus() }
        }
        #if DEBUG
        // Capture seam (`ATTIC_UI_TEST_POPOVER=tag|priority`, preview
        // identities only): a draft, then the strip's picker opens by itself.
        .onAppear {
            guard let seam = AtticDropdownCaptureSeam.current, seam == .tag || seam == .priority else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                text.text.text = "Pay rent"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if seam == .tag { tagsPresented = true } else { priorityPresented = true }
                }
            }
        }
        #endif
    }

    private func submit(openingPage: Bool) {
        if let id = model.submitAddBar(openingPage: openingPage) { added(id) }
    }

    /// The suggestion list's keys (review 15): ↑ ↓ move, Tab or Return take
    /// the highlighted choice and keep editing, Esc hides the list (the
    /// draft stays). With no list, every key goes on as usual.
    private func suggestionKey(_ key: AtticSuggestionKey) -> Bool {
        guard let suggestion else { return false }
        switch key {
        case .up, .down:
            text.highlighted = key == .up ? max(text.highlighted - 1, 0) : min(text.highlighted + 1, suggestion.count - 1)
            // VoiceOver hears the choice the keyboard is on (not the whole
            // list on every keystroke).
            let item = items(for: suggestion)[text.highlighted]
            AccessibilityNotification.Announcement([item.title, item.detail].compactMap { $0 }.joined(separator: ", ")).post()
        case .accept:
            model.accept(suggestion, choice: min(text.highlighted, suggestion.count - 1), editor: editor)
            text.highlighted = 0
        case .dismiss: text.hiddenSuggestion = suggestion.range
        }
        return true
    }

    private func items(for suggestion: TaskAddBarText.Suggestion) -> [AtticSuggestionList.Item] {
        switch suggestion {
        case let .tags(_, _, matches, create):
            return matches.map { AtticSuggestionList.Item(id: $0, title: "#" + $0) }
                + (create.map { [AtticSuggestionList.Item(id: "create-" + $0, title: String(localized: "Create #\($0)"), systemName: "plus")] } ?? [])
        case let .date(_, _, title, day):
            return [AtticSuggestionList.Item(id: day.rawValue, title: title, systemName: "calendar",
                                             detail: model.dateChoices.longDetail(for: day))]
        }
    }
}

/// What the strip's buttons show for the new task (owner item 18).
enum TasksComposerValues {
    /// The Tag button's value: the first tag, and how many more; its
    /// tooltip, all of them.
    static func tags(_ tags: [String]) -> AtticStripValue? {
        guard let first = tags.first else { return nil }
        let more = tags.count - 1
        return AtticStripValue(
            text: more > 0 ? "#\(first) +\(more)" : "#\(first)",
            spoken: more > 0 ? String(localized: "\(first) and \(more) more") : first,
            // The tooltip names every tag (deep review P3-01).
            full: tags.map { "#" + $0 }.joined(separator: " ")
        )
    }

    /// The Priority button's value: its mark, `!!` in High's orange.
    static func priority(_ priority: TaskPriority?) -> AtticStripValue? {
        switch priority {
        case .high?: AtticStripValue(text: "!!", ink: .priorityMark, style: .priorityMark, spoken: String(localized: "High"))
        case .medium?: AtticStripValue(text: "!", ink: .helper, style: .priorityMark, spoken: String(localized: "Medium"))
        case .low?: AtticStripValue(text: "↓", ink: .helper, style: .priorityMark, spoken: String(localized: "Low"))
        case .none?, nil: nil
        }
    }
}

// MARK: - Menu titles

extension TaskStatus {
    var menuTitle: String { String(localized: menuLocalization) }

    var menuLocalization: String.LocalizationValue {
        switch self {
        case .todo: "To Do"
        case .inProgress: "In Progress"
        case .done: "Done"
        case .backlog: "Later"
        }
    }
}

extension TaskPriority {
    var menuTitle: String { String(localized: menuLocalization) }

    var menuLocalization: String.LocalizationValue {
        switch self {
        case .none: "No Priority"
        case .low: "Low  ↓"
        case .medium: "Medium  !"
        case .high: "High  !!"
        }
    }
}

// MARK: - Drag to reorder

/// A row being dragged within its group (reorder: it lifts in place, the
/// others slide apart). ⌘B and the menu move a task between Now and Later.
/// The live translation is the cell's own gesture state; the page holds
/// only which row is lifted and where it would land.
struct TasksDrag: Equatable {
    let id: UUID
    let tab: TasksTab
    let group: [UUID]
    let startIndex: Int
    var targetIndex: Int
    /// How far the list has scrolled under the drag (edge auto-scroll):
    /// the row keeps under the pointer and lands by where it is.
    var scrolled: CGFloat = 0
    /// Released: the lifted card settles into the gap the neighbours
    /// opened, and the move is committed once it is there.
    var landing = false
}

/// The card a reorder lifts (owner, 2026-10-01: the lifted row was unsteady,
/// sat under other rows and was see-through). It is drawn over the whole
/// page, outside the list, so no row is ever above it and scrolling under
/// it never moves it: it stays under the pointer while the neighbours
/// spring aside. The row's own place in the list keeps the gesture and is
/// invisible meanwhile. Observed only by the card itself, so following the
/// pointer redraws the card and nothing else. Used on the main thread only
/// (it lives on the page's `TasksPointer`).
final class TasksLiftedCard: ObservableObject {
    struct Lift: Equatable {
        let id: UUID
        let tab: TasksTab
        /// The row's frame in the page when it was lifted.
        let origin: CGRect
        /// The card's top in the page.
        var y: CGFloat
    }

    @Published private(set) var lift: Lift?

    func begin(id: UUID, tab: TasksTab, origin: CGRect) {
        lift = Lift(id: id, tab: tab, origin: origin, y: origin.minY)
    }

    /// The pointer moved `translation` from where the press began.
    func follow(_ translation: CGFloat) {
        guard var lift else { return }
        let y = lift.origin.minY + translation
        guard y != lift.y else { return }
        lift.y = y
        self.lift = lift
    }

    /// The card settles at `y` (the caller animates it).
    func land(at y: CGFloat) {
        guard var lift else { return }
        lift.y = y
        self.lift = lift
    }

    func end() {
        if lift != nil { lift = nil }
    }

    /// Where the card lands: the top of the gap the neighbours opened at
    /// `drag.targetIndex` (the rows between moved by the lifted row's
    /// height), less what the list scrolled under the drag.
    nonisolated static func landing(of drag: TasksDrag, originY: CGFloat, heights: (UUID) -> CGFloat) -> CGFloat {
        var y = originY - drag.scrolled
        if drag.targetIndex > drag.startIndex {
            for index in (drag.startIndex + 1)...drag.targetIndex where drag.group.indices.contains(index) {
                y += heights(drag.group[index])
            }
        } else if drag.targetIndex < drag.startIndex {
            for index in drag.targetIndex..<drag.startIndex where drag.group.indices.contains(index) {
                y -= heights(drag.group[index])
            }
        }
        return y
    }
}

/// Draws the lifted card where the pointer holds it.
struct TasksLiftedCardLayer<Card: View>: View {
    @ObservedObject var lift: TasksLiftedCard
    @ViewBuilder let card: (TasksLiftedCard.Lift) -> Card

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let current = lift.lift {
                card(current)
                    .frame(width: current.origin.width, alignment: .topLeading)
                    .modifier(AtticReorderLiftModifier(lifted: true))
                    .offset(x: current.origin.minX, y: current.y)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One drag's live state outside view state (round 4, Astra's final 7):
/// whether it was cancelled (Esc while tracking, a hide, a page change),
/// where the pointer is, the last translation, the rows' control frames
/// (a press on them never starts a drag), and the edge auto-scroll's timer.
@MainActor
final class TasksDragSession {
    /// Set when the drag is cancelled: nothing about this press moves or
    /// commits until the button comes up (`end`).
    private(set) var isCancelled = false
    var translation: CGFloat = 0
    var location: CGPoint?
    var controlFrames: [TasksRowID: [CGRect]] = [:]
    /// Which cell reported each row's control frames (`TasksCellReports`).
    private var controlOwners: [TasksRowID: ObjectIdentifier] = [:]
    var timer: Timer?

    /// A row's controls, as its cell reports them.
    func setControlFrames(_ frames: [CGRect], for row: TasksRowID, from cell: TasksCellReports) {
        controlFrames[row] = frames
        controlOwners[row] = ObjectIdentifier(cell)
    }

    /// A cell now draws another task (a Done row after a new query,
    /// `TasksDoneSlots`): its controls move to that task, and the task it
    /// drew keeps none of them unless another cell reported them since.
    func moveControlFrames(from old: TasksRowID, to new: TasksRowID, of cell: TasksCellReports) {
        if controlOwners[old] == ObjectIdentifier(cell) {
            controlFrames[old] = nil
            controlOwners[old] = nil
        }
        guard let frames = cell.controls else { return }
        setControlFrames(frames, for: new, from: cell)
    }

    func cancel() { isCancelled = true }

    /// This press's decision, taken once when it starts (round 5, F4): a
    /// press on a row's title stays a drag however far the row then moves
    /// or the list scrolls under it, and a press on a control never
    /// becomes one.
    private var press: (id: UUID, start: CGPoint, allowed: Bool)?

    /// Whether the press that started at `start` on row `id` may drag.
    /// `decide` runs once per press, when the row is where it was pressed;
    /// every later update and the release reuse its answer.
    func allows(_ id: UUID, start: CGPoint, decide: (CGPoint) -> Bool) -> Bool {
        if let press, press.id == id, press.start == start { return press.allowed }
        let allowed = decide(start)
        press = (id, start, allowed)
        return allowed
    }

    /// A mouse button went down: whatever the last press decided is
    /// forgotten. A press that never dragged (on a control, or a click)
    /// ends no gesture, so without this its answer could be reused by a
    /// later press at the same point once the row had moved.
    func newPress() {
        press = nil
    }

    /// The press is over (released or cancelled by the system).
    func end() {
        press = nil
        isCancelled = false
        timer?.invalidate()
        timer = nil
        location = nil
        translation = 0
    }

    /// A press at `point` (page space) on row `id`, whose frame in the page
    /// starts at `origin`, landed on one of its controls.
    func isOnControl(_ id: TasksRowID, at point: CGPoint, rowOrigin origin: CGPoint?) -> Bool {
        guard let origin, let frames = controlFrames[id] else { return false }
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        return frames.contains { $0.insetBy(dx: -2, dy: -2).contains(local) }
    }

    /// The edge auto-scroll's step for a pointer at `y`: 0 inside the
    /// usable viewport, up to `maximum` points a tick within `zone` of its
    /// top (negative) or bottom (positive) edge, growing with depth.
    nonisolated static func autoScrollStep(y: CGFloat, top: CGFloat, bottom: CGFloat, zone: CGFloat = 40, maximum: CGFloat = 14) -> CGFloat {
        guard bottom > top else { return 0 }
        if y < top + zone { return -maximum * min(1, max(0, (top + zone - y) / zone)) }
        if y > bottom - zone { return maximum * min(1, max(0, (y - (bottom - zone)) / zone)) }
        return 0
    }
}

/// A row that can be dragged to reorder (owner fix 6, review 1). The lift is
/// a modifier (the row keeps its identity mid-drag); the translation lives in
/// `@GestureState`, which resets itself when the system cancels the drag, and
/// that reset clears the lift, so nothing stays lifted. The drag starts on
/// the row itself (not its circle, its quick look or a text field), at
/// once, without a hold, key or not.
struct TasksReorderCell<Row: View, Below: View>: View {
    /// The cell redraws itself when the selection, editing or keyboard
    /// focus move (the focus ring lagging a row behind, the computer-use
    /// review's bug 4): it observes every change to the model through
    /// `updates` while its page is drawn, and nothing while its page is kept
    /// built but not drawn (round 11).
    let model: TasksPageModel
    @ObservedObject var updates: TasksCellUpdates
    var focus: FocusState<AtticRowFocusID?>.Binding
    let id: UUID
    let tab: TasksTab
    let group: [UUID]
    @Binding var drag: TasksDrag?
    /// Page state the row shows (its open picker, a file over it), read in
    /// this cell's own body so the row redraws when they change: a lazy
    /// list's cells are not rebuilt when only the page's state changes.
    @Binding var metaPopover: TasksMetaPopover?
    @Binding var fileDropRow: TasksRowID?
    let enabled: Bool
    /// The drag's live state: cancellation, pointer, control frames.
    let session: TasksDragSession
    /// Where the rows are in the page (each cell reports its own).
    let pointer: TasksPointer
    /// Whether a press at this page point may start a drag (not on the
    /// row's circle, checklist, date or tags).
    let allowsStart: (CGPoint) -> Bool
    let heights: (UUID) -> CGFloat
    let onBegin: () -> Void
    /// The pointer moved the lifted row this far (the lifted card follows).
    let onMove: (CGFloat) -> Void
    let onEnd: (TasksDrag) -> Void
    let onPushPastGroup: () -> Void
    @ViewBuilder let row: (TasksCellLive) -> Row
    @ViewBuilder let below: (TasksCellLive) -> Below

    @Environment(\.atticDesign) private var design
    @GestureState private var translation: CGFloat?
    @State private var pushedPast = false
    /// What this cell last reported of its row (its frame, its controls).
    @State private var reports = TasksCellReports()

    var body: some View {
        let lifted = drag?.id == id && translation != nil
        let hidden = lifted || (drag?.id == id && drag?.landing == true)
        // Read here, in the cell's own body, so a new target moves the
        // neighbours at once (a list's lazy cells do not re-read the page).
        let offset = drag.map { Self.offset(of: id, in: $0, heights: heights) } ?? 0
        // Drawn is not active: a page kept built beside the one shown draws
        // its rows, but the keyboard, the editors and the pickers belong to
        // the copy on the page the person is on (round 12).
        let active = model.tab == tab && model.isPageShown
        let focusID = AtticRowFocusID(page: tab.rawValue, id: id)
        let live = TasksCellLive(
            metaPopover: active && metaPopover?.id == id && metaPopover?.tab == tab ? metaPopover : nil,
            // Whether it has the keyboard: the model's copy of the page's
            // focus (`TasksPageModel.keyboardFocus`), read as the cell draws.
            focus: AtticRowFocus(binding: focus, id: focusID, isFocused: active && model.keyboardFocus == focusID,
                                 isActive: { [model, tab] in model.tab == tab && model.isPageShown }),
            isDropTarget: active && fileDropRow == TasksRowID(tab: tab, id: id),
            isActive: active
        )
        VStack(alignment: .leading, spacing: 0) {
            // An ordinary gesture on the row: its buttons (the circle, the
            // date, the tags, the checklist) keep their clicks; a press that
            // moves 4 pt drags at once, with no hold.
            row(live)
                .onPreferenceChange(AtticRowControlFramesKey.self) { [session, id, tab, reports] frames in
                    MainActor.assumeIsolated {
                        reports.controls = frames
                        session.setControlFrames(frames, for: TasksRowID(tab: tab, id: id), from: reports)
                    }
                }
                .simultaneousGesture(gesture, including: enabled ? .all : .subviews)
            below(live)
        }
        // Lifted, the row is the card over the page (`TasksLiftedCard`):
        // its place here keeps the gesture alive and shows nothing, until
        // the card has landed in the gap.
        .opacity(hidden ? 0.001 : 1)
        .offset(y: hidden ? 0 : offset)
        .animation(hidden || design.reduceMotion ? nil : AtticMotionPreset.settle.animation(reduceMotion: false), value: offset)
        // A Done row's cell can draw another task after a new query
        // (`TasksDoneSlots`): its controls' frames go with it.
        .onChange(of: id) { [session, pointer, tab, reports] old, new in
            session.moveControlFrames(from: TasksRowID(tab: tab, id: old), to: TasksRowID(tab: tab, id: new), of: reports)
            pointer.moveFrame(from: TasksRowID(tab: tab, id: old), to: TasksRowID(tab: tab, id: new), of: reports)
        }
        // Each row's frame in the page, for the pointer's questions (which
        // row a right-click, a drop or a drag-out is on) and the reveal.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: TasksPage.space) } action: { [pointer, tab, id, reports] frame in
            reports.frame = frame
            pointer.setFrame(frame, for: TasksRowID(tab: tab, id: id), from: reports)
        }
        .onDisappear { [pointer, tab, id, reports] in pointer.removeFrame(for: TasksRowID(tab: tab, id: id), of: reports) }
        .onChange(of: translation == nil) { _, ended in
            guard ended else { return }
            // Released, cancelled by the system or by Esc: the lift goes
            // (a release is landing, committed by `onEnded`), and the next
            // press starts afresh.
            pushedPast = false
            if drag?.id == id, drag?.landing != true { drag = nil }
            session.end()
        }
    }

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: TasksPage.space)
            .updating($translation) { value, state, _ in
                guard session.allows(id, start: value.startLocation, decide: allowsStart) else { return }
                state = value.translation.height
            }
            .onChanged { value in
                guard !session.isCancelled, session.allows(id, start: value.startLocation, decide: allowsStart),
                      let start = group.firstIndex(of: id) else { return }
                session.translation = value.translation.height
                session.location = value.location
                onMove(value.translation.height)
                let scrolled = drag?.id == id ? (drag?.scrolled ?? 0) : 0
                let moved = value.translation.height + scrolled
                let target = Self.target(start: start, translation: moved, group: group, heights: heights)
                if drag?.id != id {
                    drag = TasksDrag(id: id, tab: tab, group: group, startIndex: start, targetIndex: target)
                    onBegin()
                    onMove(value.translation.height)
                } else if drag?.targetIndex != target {
                    drag?.targetIndex = target
                }
                // Pushing past the group's end: say why it stops there.
                let past = Self.pushesPastGroup(start: start, translation: moved, group: group, heights: heights)
                if past, !pushedPast { onPushPastGroup() }
                if past != pushedPast { pushedPast = past }
            }
            .onEnded { value in
                // A cancelled press never commits on release.
                guard !session.isCancelled, session.allows(id, start: value.startLocation, decide: allowsStart),
                      let start = group.firstIndex(of: id) else { return }
                let moved = value.translation.height + (drag?.id == id ? (drag?.scrolled ?? 0) : 0)
                let target = Self.target(start: start, translation: moved, group: group, heights: heights)
                onEnd(TasksDrag(id: id, tab: tab, group: group, startIndex: start, targetIndex: target))
            }
    }

    /// How far a neighbour moves aside while `drag` is on its way: the
    /// dragged row's height, for the rows between where it was and where
    /// it would land.
    static func offset(of id: UUID, in drag: TasksDrag, heights: (UUID) -> CGFloat) -> CGFloat {
        guard drag.id != id, let index = drag.group.firstIndex(of: id) else { return 0 }
        let height = heights(drag.id)
        if drag.startIndex < drag.targetIndex, index > drag.startIndex, index <= drag.targetIndex { return -height }
        if drag.targetIndex < drag.startIndex, index >= drag.targetIndex, index < drag.startIndex { return height }
        return 0
    }

    /// The place the row would land: it passes a neighbour once it has
    /// moved more than half that neighbour's height.
    static func target(start: Int, translation: CGFloat, group: [UUID], heights: (UUID) -> CGFloat) -> Int {
        var target = start
        var remaining = translation
        if remaining > 0 {
            for index in (start + 1)..<max(start + 1, group.count) {
                let height = heights(group[index])
                guard remaining > height / 2 else { break }
                target = index
                remaining -= height
            }
        } else if remaining < 0, start > 0 {
            for index in stride(from: start - 1, through: 0, by: -1) {
                let height = heights(group[index])
                guard -remaining > height / 2 else { break }
                target = index
                remaining += height
            }
        }
        return target
    }

    /// The row has been pushed more than half a row beyond its group's
    /// first or last place (where the other group begins).
    static func pushesPastGroup(start: Int, translation: CGFloat, group: [UUID], heights: (UUID) -> CGFloat) -> Bool {
        guard group.indices.contains(start) else { return false }
        let own = heights(group[start])
        if translation > 0 {
            let room = group[(start + 1)...].reduce(0) { $0 + heights($1) }
            return translation > room + own / 2
        }
        let room = group[..<start].reduce(0) { $0 + heights($1) }
        return -translation > room + own / 2
    }
}

/// "Not saved · Retry" inside an open picker, for its row's change.
private struct TasksPickerFailureLine: View {
    @ObservedObject var model: TasksPageModel
    let id: UUID
    /// Called when a retry saved (a date pop-over then closes).
    var closeOnRetrySuccess: (() -> Void)?

    var body: some View {
        if let failure = model.pickerFailure, failure.id == id {
            AtticErrorLine(message: failure.canRetry ? String(localized: "Not saved") : failure.message,
                           actionTitle: failure.canRetry ? String(localized: "Retry") : String(localized: "OK"),
                           onRetry: {
                               if failure.canRetry {
                                   if model.retryPickerChange() { closeOnRetrySuccess?() }
                               } else {
                                   model.clearPickerFailure()
                               }
                           })
                .padding(.horizontal, AtticPopoverMetrics.rowPadding)
                .accessibilityIdentifier("tasks-picker-failure")
        }
    }
}

/// What a row shows from the page's state, read by its cell as it draws
/// (the page's state read from a closure the lazy list kept is stale).
struct TasksCellLive {
    let metaPopover: TasksMetaPopover?
    let focus: AtticRowFocus
    let isDropTarget: Bool
    /// The row's page is the one shown, on the tab the person is on: it
    /// alone opens editors and pickers and takes the keyboard (round 12).
    let isActive: Bool
}

/// A quiet line over the add bar while a drag or ⌘↑ ⌘↓ meets the edge of
/// its group (review 10).
private struct TasksBoundaryHint: View {
    let text: String

    var body: some View {
        HStack(spacing: AtticSpacing.s4) {
            AtticIcon(systemName: "arrow.up.and.down", size: AtticTaskRowMetrics.detailsIconSize, weight: .medium, ink: .icon)
            AtticText(verbatim: text, style: .controlLabel, ink: .helper)
        }
        .frame(height: AtticErrorLineMetrics.height)
        .padding(.leading, AtticLayout.textX - AtticSpacing.panelMargin - AtticTaskRowMetrics.detailsIconSize - AtticSpacing.s4)
        .accessibilityElement(children: .combine)
    }
}

/// The rows' frames in the page and the current menu invocation, kept out
/// of view state (writing them redraws nothing).
final class TasksPointer {
    /// Each row's frame in the page, by its identity on its page: a task
    /// that two pages list (Now's "Completed today" and Done) is two rows
    /// with two frames (round 12).
    var frames: [TasksRowID: CGRect] = [:]
    /// The card a reorder lifts, over the whole page.
    let liftedCard = TasksLiftedCard()
    /// Tests: receives a drag out of the panel instead of AppKit.
    var startDragOut: ((TasksTextExport, CGPoint) -> Void)?
    /// Tests: receives ⌥⌘V's anchor instead of the native menu.
    var openViewOptions: ((NSView) -> Void)?
    /// The page's own view: a press is placed in the page from its event.
    weak var view: NSView?
    /// The row that has the keyboard (the page's focus), for tests: which
    /// row a Tab reached (deep review P2-04).
    var keyboardRow: TasksRowID?

    #if DEBUG
    /// Tests: the rows whose cells last drew them as the keyboard's row (with
    /// its ring), so a test can tell a focus the row never drew (P2-04).
    private(set) var drawnFocus: Set<TasksRowID> = []

    func noteDrawnFocus(_ row: TasksRowID, _ focused: Bool) {
        if focused { drawnFocus.insert(row) } else { drawnFocus.remove(row) }
    }
    #endif

    /// One context menu's binding: the row it was opened on and what its
    /// commands act on, taken at the press that opened it.
    struct Invocation: Equatable {
        let row: TasksRowID
        let targets: [UUID]
        /// The opening press's timestamp: the menu that begins with this
        /// event is the one it binds.
        var pressedAt: TimeInterval = 0
    }

    private(set) var invocation: Invocation?

    /// The binding for a menu on `row`: only one opened by a press on that
    /// same row (a menu on another row never inherits it).
    func binding(for row: TasksRowID) -> Invocation? {
        invocation?.row == row ? invocation : nil
    }

    /// A menu begins tracking during `event`. A binding holds only for the
    /// menu its own press opened; one opened any other way (keyboard,
    /// VoiceOver, the menu bar) ends it.
    func menuBegan(with event: NSEvent?) {
        guard let invocation, event.map({ $0.timestamp != invocation.pressedAt }) ?? true else { return }
        self.invocation = nil
    }

    /// The menu's command ran, or the page hid, changed tab or ended a
    /// drag: no binding outlives it.
    func endInvocation() {
        invocation = nil
    }

    /// What kind of press opens a context menu.
    enum MenuPress: Equatable {
        case none, secondary, control

        init(type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) {
            switch type {
            case .rightMouseDown: self = .secondary
            case .leftMouseDown where modifiers.intersection(.deviceIndependentFlagsMask).contains(.control): self = .control
            default: self = .none
            }
        }
    }

    /// A press, before SwiftUI sees it: a secondary click or Control-click
    /// on a row (below `minY`, the tabs' band) binds the menu about to open
    /// to that row, with the targets `select` returns (it selects the row
    /// unless it is part of the selection); any other press, or one off the
    /// rows or in another window, ends the previous binding.
    func press(_ event: NSEvent, tab: TasksTab, below minY: CGFloat, aboveBottom bottomBand: CGFloat = 0,
               select: (UUID) -> [UUID]) {
        guard MenuPress(type: event.type, modifiers: event.modifierFlags) != .none,
              let point = location(of: event), point.y >= minY,
              point.y <= (view?.bounds.height ?? .greatestFiniteMagnitude) - bottomBand,
              let id = row(at: point, in: tab) else {
            invocation = nil
            return
        }
        invocation = Invocation(row: TasksRowID(tab: tab, id: id), targets: select(id), pressedAt: event.timestamp)
    }

    /// Which cell reported each row's frame (`TasksCellReports`).
    private var frameOwners: [TasksRowID: ObjectIdentifier] = [:]

    func setFrame(_ frame: CGRect, for row: TasksRowID, from cell: TasksCellReports) {
        frames[row] = frame
        frameOwners[row] = ObjectIdentifier(cell)
    }

    /// A cell now draws another task (`TasksDoneSlots`): its frame moves to
    /// that task, and the task it drew keeps none unless another cell
    /// reported one since.
    func moveFrame(from old: TasksRowID, to new: TasksRowID, of cell: TasksCellReports) {
        removeFrame(for: old, of: cell)
        guard let frame = cell.frame else { return }
        setFrame(frame, for: new, from: cell)
    }

    /// A cell went: the frame it reported goes with it.
    func removeFrame(for row: TasksRowID, of cell: TasksCellReports) {
        guard frameOwners[row] == nil || frameOwners[row] == ObjectIdentifier(cell) else { return }
        frames[row] = nil
        frameOwners[row] = nil
    }

    /// Whether the pointer is over one of `tab`'s rows now.
    func isOverRow(on tab: TasksTab) -> Bool {
        guard let view, let window = view.window else { return false }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return frames.contains { $0.key.tab == tab && $0.value.contains(point) }
    }

    /// The event's location in the page, or nil when it is another
    /// window's event or outside the page.
    func location(of event: NSEvent) -> CGPoint? {
        guard let view, let window = view.window, event.window === window else { return nil }
        let point = view.convert(event.locationInWindow, from: nil)
        return view.bounds.contains(point) ? point : nil
    }

    /// A plain left click in the list's space (below `top`, above the
    /// bottom stack) that no row holds.
    func isPlainPressOutsideRows(_ event: NSEvent, tab: TasksTab, top: CGFloat, bottomInset: CGFloat) -> Bool {
        guard event.type == .leftMouseDown,
              event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty,
              let view, let point = location(of: event), point.y >= top, point.y <= view.bounds.height - bottomInset
        else { return false }
        return row(at: point, in: tab) == nil
    }

    /// The row under `point` on page `tab`: the one whose frame holds it
    /// (the list's visible part; a row's frame is the row and its quick
    /// look). Only the page the person is on answers: a copy another page
    /// keeps of the same task, or a page beside it, is never under it.
    func row(at point: CGPoint, in tab: TasksTab) -> UUID? {
        frames.first { $0.key.tab == tab && $0.value.contains(point) && $0.value.height < 2_000 }?.key.id
    }
}

/// A flipped, click-through view the size of the page: its coordinates are
/// the page's, so an event's location converts straight into them.
private struct TasksPointerProbe: NSViewRepresentable {
    let pointer: TasksPointer

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        pointer.view = view
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) { pointer.view = view }

    final class ProbeView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// What a task row shows (round 11): a row whose key is unchanged is not
/// rebuilt when the page's model changes elsewhere (a selection moving,
/// a keystroke in an editor). Its closures read the model when they run,
/// so skipping a rebuild never leaves one acting on stale state.
struct TasksRowKey: Equatable {
    let model: AtticTaskRowModel
    let isSelected: Bool
    let selectionRun: AtticSelectionRun
    let isExpanded: Bool
    let isDropTarget: Bool
    let isFocused: Bool
    let tab: TasksTab
    let layout: PanelPageLayout
    /// A title editor or a picker is open on the row: it always redraws.
    let isLive: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        !lhs.isLive && !rhs.isLive && lhs.model == rhs.model && lhs.isSelected == rhs.isSelected
            && lhs.selectionRun == rhs.selectionRun && lhs.isExpanded == rhs.isExpanded && lhs.isDropTarget == rhs.isDropTarget
            && lhs.isFocused == rhs.isFocused && lhs.tab == rhs.tab
            // Native layout resizes the row. Its controls and callbacks
            // change only when the chrome insets change, not every pixel
            // of the panel size (owner F-14).
            && lhs.layout.chromeInsets == rhs.layout.chromeInsets
    }
}

/// A task row drawn only when its key changes (see `TasksRowKey`).
struct TasksRowSnapshot<Content: View>: View, Equatable {
    let key: TasksRowKey
    @ViewBuilder let content: () -> Content

    var body: some View { content() }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated { lhs.key == rhs.key }
    }
}

/// DropDelegate has no cancellation callback. The drop session supplies
/// its terminal event, including cancel without an exit.
private struct TasksFileDropDestination: ViewModifier {
    let delegate: TasksFileDropDelegate
    func body(content: Content) -> some View {
        content.onDrop(of: TaskDropContent.dropTypes, delegate: delegate)
            .onTaskFileDropEnded { delegate.setTargeted(nil) }
            .onDisappear { delegate.setTargeted(nil) }
    }
}

extension View {
    func tasksFileDrop(delegate: TasksFileDropDelegate) -> some View {
        modifier(TasksFileDropDestination(delegate: delegate))
    }
}

/// Files dropped on the Tasks page (round 11): the row under them takes
/// them. Files are accepted anywhere on the page, so the drop is followed
/// as it moves; only a row that can hold files highlights and takes them.
struct TasksFileDropDelegate: DropDelegate {
    let target: (CGPoint) -> UUID?
    let canAccept: (TaskDropContent, UUID) -> Bool
    let setTargeted: (UUID?) -> Void
    let perform: (TaskDropContent, [NSItemProvider], UUID) -> Void

    private func row(for info: DropInfo) -> (content: TaskDropContent, id: UUID)? {
        let content = TaskDropContent.classify(info)
        guard content == .files, let id = target(info.location), canAccept(content, id) else { return nil }
        return (content, id)
    }

    func validateDrop(info: DropInfo) -> Bool {
        TaskDropContent.classify(info) == .files
    }

    func dropEntered(info: DropInfo) {
        setTargeted(row(for: info)?.id)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let found = row(for: info)
        setTargeted(found?.id)
        return DropProposal(operation: found == nil ? .forbidden : .copy)
    }

    func dropExited(info: DropInfo) {
        setTargeted(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        setTargeted(nil)
        guard let found = row(for: info) else { return false }
        let providers = TaskDropContent.providers(for: found.content, in: info)
        guard !providers.isEmpty else { return false }
        perform(found.content, providers, found.id)
        return true
    }
}

/// A row's open date or tag list, and the tasks it changes.
struct TasksMetaPopover: Equatable {
    /// `move`: Move to Task… for the subtask in `targets` (control audit
    /// item 5), from its line in the quick look of row `id`.
    enum Kind { case date, tags, move }
    let id: UUID
    /// The page whose copy of the row opened it (a task can be listed by two).
    let tab: TasksTab
    let kind: Kind
    let targets: [UUID]
    var newTag = false
}

/// The bottom stack's measured height (see `TasksPage.bottomStack`).
@MainActor
final class TasksBottomStackHeight: ObservableObject {
    @Published var height: CGFloat = AtticControlSize.addBarHeight {
        didSet { scheduleMask() }
    }
    /// What the Clean cut preview mask uses: the height a moment later.
    /// The native viewport follows `height` immediately. Changing
    /// the lists' mask re-renders their layers (about 12 ms with 500 rows),
    /// so it follows the strip after the keystroke's frame, while the strip
    /// is still fading in, never inside it (round 4: the first keystroke).
    @Published private(set) var maskHeight: CGFloat = AtticControlSize.addBarHeight
    private var pending: DispatchWorkItem?

    private func scheduleMask() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.maskHeight != self.height else { return }
                self.maskHeight = self.height
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}

/// The viewport's fade: only the tabs line (plain text) has one; the
/// header and the bottom stack are glass (owner, 2026-10-06).
private struct TasksViewportMask: View {
    let tabsTop: CGFloat
    var topEdge: CGFloat = 0
    var bottomEdge: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                stops: TasksViewport.maskStops(height: proxy.size.height, tabsTop: tabsTop,
                                               topEdge: topEdge, bottomEdge: bottomEdge)
                    .map { Gradient.Stop(color: .black.opacity($0.opacity), location: $0.location) },
                startPoint: .top, endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }
}

/// The bottom stack's band (round 7, R4): from the panel's bottom edge to
/// just above the top of what the stack shows (the add bar, the strip and
/// its gaps, a selection bar or paste offer), across the page's width. It
/// takes every press there, so nothing reaches a row scrolled beneath;
/// the stack's own controls sit above it and keep theirs.
struct TasksBottomBand: View {
    @ObservedObject var stack: TasksBottomStackHeight
    let bottomInset: CGFloat

    /// The band's height: the stack, its bottom margin, and half the gap
    /// the list keeps above it.
    nonisolated static func height(stack: CGFloat, bottomInset: CGFloat) -> CGFloat {
        max(stack, AtticControlSize.addBarHeight) + bottomInset + AtticPickerMetrics.stripToBar / 2
    }

    var body: some View {
        Color.clear
            .frame(height: Self.height(stack: stack.height, bottomInset: bottomInset))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {}
            .gesture(DragGesture(minimumDistance: 0))
            .accessibilityHidden(true)
    }
}

/// Tells the shell how high its toast and notices must sit (above the
/// bottom stack as it is), from its own small view.
private struct TasksNoticeClearance: View {
    @ObservedObject var stack: TasksBottomStackHeight
    let footerZone: CGFloat

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .preference(key: PanelPageNoticeClearancePreferenceKey.self,
                        value: footerZone + max(0, stack.height - AtticControlSize.addBarHeight))
            .accessibilityHidden(true)
    }
}

#if DEBUG
extension TasksPage {
    static let exposesDragOutState = ProcessInfo.processInfo.environment["ATTIC_UI_TESTING"] == "1"
}

/// UI tests: the drags out of the panel (began, ended), as a 1 pt text.
private struct TasksDragOutStateProbe: View {
    @ObservedObject private var probe = TasksDragOut.Probe.shared

    var body: some View {
        let state = "began \(probe.began) ended \(probe.ended)"
        Text(verbatim: state)
            .font(.system(size: 1))
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
            .accessibilityIdentifier("tasks-drag-out-state")
            .accessibilityValue(state)
    }
}
#endif

extension View {
    /// The control layer remains outside the list's AppKit containers.
    func tasksListEdges<Mask: View>(_ style: AtticScrollEdgeStyle, top: CGFloat, listTop: CGFloat,
                                    bottomInset: CGFloat, bottomMargin: CGFloat, bottomClearance: CGFloat,
                                    stack: TasksBottomStackHeight, mask: Mask) -> some View {
        modifier(TasksListEdges(style: style, top: top, listTop: listTop, bottomInset: bottomInset,
                                bottomMargin: bottomMargin, bottomClearance: bottomClearance, stack: stack, cleanMask: mask))
    }
}

/// Observes control-height changes only. Scroll offsets stay in AppKit:
/// neither the header, composer nor this modifier observes them.
private struct TasksListEdges<Mask: View>: ViewModifier {
    let style: AtticScrollEdgeStyle
    let top: CGFloat
    let listTop: CGFloat
    let bottomInset: CGFloat
    let bottomMargin: CGFloat
    let bottomClearance: CGFloat
    @ObservedObject var stack: TasksBottomStackHeight
    let cleanMask: Mask

    @ViewBuilder
    func body(content: Content) -> some View {
        switch style {
        case .systemSoft:
            let bottom = TasksViewport.controlsInset(stack: stack.height, bottomInset: bottomInset)
            content
                // Keep the first and last rows' resting clearance. Only
                // these small empty gaps form native edge pockets now.
                .atticScrollEdgeEffect(style)
                .safeAreaBar(edge: .top, spacing: 0) { AtticScrollEdgeBar(height: max(0, listTop - top)) }
                .safeAreaBar(edge: .bottom, spacing: 0) { AtticScrollEdgeBar(height: AtticLayout.contentToAddBar) }
                // The system pocket may extend beyond its scroll view.
                // Clip it here, before the padding that excludes controls.
                .clipped()
                .padding(.top, top)
                .padding(.bottom, bottom)
        case .cleanCut:
            content
                .contentMargins(.top, listTop, for: .scrollContent)
                .contentMargins(.bottom, bottomMargin, for: .scrollContent)
                .contentMargins(.top, listTop, for: .scrollIndicators)
                .contentMargins(.bottom, bottomClearance, for: .scrollIndicators)
                .atticScrollEdgeEffect(style)
                .mask { cleanMask }
                .mask { TasksPlainControlsMask(stackHeight: stack.height, bottomInset: bottomInset) }
        }
    }
}

/// The strip, selection bar and failure/paste lines have plain labels,
/// unlike the glass add bar. Rows disappear before those labels and may
/// still run behind the add bar. The measured stack follows immediately;
/// the delayed mask height must never leave two text lines superimposed.
struct TasksPlainControlsMask: View {
    let stackHeight: CGFloat
    let bottomInset: CGFloat

    var body: some View {
        GeometryReader { proxy in
            if stackHeight > AtticControlSize.addBarHeight + 0.5 {
                let height = max(1, proxy.size.height)
                let top = max(0, height - bottomInset - stackHeight)
                let bottom = max(top, height - bottomInset - AtticControlSize.addBarHeight)
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: max(0, top - AtticSpacing.s8) / height),
                    .init(color: .clear, location: top / height),
                    .init(color: .clear, location: bottom / height),
                    .init(color: .black, location: min(height, bottom + AtticSpacing.s8) / height),
                    .init(color: .black, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            } else {
                Color.black
            }
        }
        .allowsHitTesting(false)
    }
}

/// Resting room at the document's end, not a scroll content margin: a
/// content margin would enlarge the native pocket along with the gap.
struct TasksListTailClearance: View {
    @ObservedObject var stack: TasksBottomStackHeight
    let bottomInset: CGFloat
    let bottomClearance: CGFloat

    var body: some View {
        Color.clear
            .frame(height: max(0, bottomClearance
                               - TasksViewport.controlsInset(stack: stack.height, bottomInset: bottomInset)
                               - AtticLayout.contentToAddBar))
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// The list viewport's geometry (owner fix 8, review 9), pure so the
/// clearance and the fade are tested directly.
enum TasksViewport {
    /// The bottom stack's room the lists always keep: the add bar, and the
    /// strip over it with its gap (it comes and goes with the draft).
    static let reservedStack = AtticControlSize.addBarHeight + AtticPickerMetrics.stripToBar + AtticControlSize.smallHeight

    /// Below every control on the tabs line, including Find's taller field.
    static func controlsBottom(tabsTop: CGFloat) -> CGFloat {
        tabsTop + (AtticLayout.pageTabsHeight + AtticControlSize.smallHeight) / 2
    }

    /// Bottom edge at the top of the visible stack. Idle, the composer
    /// keeps an empty strip-to-bar gap; it is not a control.
    static func controlsInset(stack: CGFloat, bottomInset: CGFloat) -> CGFloat {
        let idle = AtticControlSize.addBarHeight + AtticPickerMetrics.stripToBar
        let visible = stack <= idle + 0.5 ? AtticControlSize.addBarHeight : stack
        return max(visible, AtticControlSize.addBarHeight) + bottomInset
    }

    /// Where the first row rests: the tabs, then 14.
    static func listTop(tabsTop: CGFloat) -> CGFloat {
        tabsTop + AtticLayout.pageTabsHeight + AtticLayout.pageTabsToList
    }

    /// The room kept at the bottom: the measured bottom stack, its margin,
    /// and the 16 pt the list keeps from the bar.
    static func bottomClearance(stackHeight: CGFloat, bottomInset: CGFloat) -> CGFloat {
        max(stackHeight, AtticControlSize.addBarHeight) + bottomInset + AtticLayout.contentToAddBar
    }

    /// The lists' bottom content margin: only the add bar's own zone. A
    /// scroll view takes no clicks in its content margins, so the rest of
    /// the clearance (the strip's room, a selection bar, the 16 pt gap) is
    /// room at the end of the list instead, and a row resting above the
    /// bar takes its click (round 6: Done's "Pay rent" did not).
    static func bottomMargin(bottomInset: CGFloat) -> CGFloat {
        AtticControlSize.addBarHeight + bottomInset
    }

    /// How to bring a row into the part of the list nothing covers (under
    /// the tabs, above the bottom stack), as the full margins used to.
    enum Reveal: Equatable {
        /// It is there already.
        case none
        /// Scroll as little as possible (above the list's top, or not laid
        /// out yet): the scroll view's own rule does it.
        case minimal
        /// Below the clear part: the row's point at this fraction lines up
        /// with the same fraction of the scroll view's visible part, which
        /// puts its bottom on the clearance line.
        case bottom(CGFloat)
    }

    /// `frame` is the row in the page (nil when not laid out), `height`
    /// its height, `viewport` the page's height.
    static func reveal(frame: CGRect?, height: CGFloat, viewport: CGFloat, listTop: CGFloat,
                       bottomMargin: CGFloat, bottomClearance: CGFloat) -> Reveal {
        guard let frame, viewport > 0 else { return .minimal }
        let clearBottom = viewport - bottomClearance
        if frame.minY < listTop - 0.5 { return .minimal }
        if frame.maxY <= clearBottom + 0.5 { return .none }
        // The visible part runs from the top margin to the bottom margin;
        // the room at the end of the list lies inside it.
        let visible = viewport - bottomMargin - listTop
        let room = bottomClearance - bottomMargin
        guard visible - height > 0 else { return .minimal }
        return .bottom(min(max((visible - room - height) / (visible - height), 0), 1))
    }

    /// The fade by position in the viewport (owner, 2026-10-06: no fade
    /// behind glass): rows run under the header and the bottom stack (the
    /// composer and the strip are glass) at full strength, and are faint
    /// only behind the Now · Later · Done line, plain text with no glass of
    /// its own, back to full a few points either side
    /// (`AtticScrollUnderFade`). Static geometry.
    /// Round 4: rows also dissolve into the panel's top and bottom edges
    /// (`topEdge`, `bottomEdge`; 0 for none).
    static func maskStops(height: CGFloat, tabsTop: CGFloat,
                          topEdge: CGFloat = 0, bottomEdge: CGFloat = 0) -> [(location: CGFloat, opacity: Double)] {
        AtticScrollUnderFade.stops(height: height, plainText: [tabsTop...(tabsTop + AtticLayout.pageTabsHeight)],
                                   topEdge: topEdge, bottomEdge: bottomEdge)
    }
}

/// The lists' scroll proxies while they are built (not observed): the
/// page scrolls a list to a `show`'s row through them (round 10).
@MainActor
final class TasksListProxies {
    var lists: [TasksTab: ScrollViewProxy] = [:]
    /// Each built list's AppKit scroll view (`TasksScrollKeeper`).
    private var scrollViewRefs: [TasksTab: WeakScrollView] = [:]

    var scrollViews: [TasksTab: NSScrollView] {
        get { scrollViewRefs.compactMapValues(\.view) }
        set { scrollViewRefs = newValue.mapValues { WeakScrollView(view: $0) } }
    }

    private struct WeakScrollView {
        weak var view: NSScrollView?
    }

    // MARK: Scrollers (owner, 2026-10-01)

    /// The lists' scrollers are hidden while a page swipe may be under
    /// way, and come back for vertical scrolling.
    private(set) var scrollersHidden = false
    private var showWork: DispatchWorkItem?

    func apply(_ change: TasksScrollerRule.Change) {
        switch change {
        case .keep:
            return
        case .hide:
            showWork?.cancel()
            setScrollersHidden(true)
        case .show:
            showWork?.cancel()
            setScrollersHidden(false)
        case .showLater:
            guard scrollersHidden else { return }
            showWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.setScrollersHidden(false) }
            }
            showWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + TasksScrollerRule.showDelay, execute: work)
        }
    }

    private func setScrollersHidden(_ hidden: Bool) {
        scrollersHidden = hidden
        for scroll in scrollViews.values {
            TasksScrollKeeper.styleScrollers(of: scroll, hidden: hidden)
        }
    }
}

/// When the lists' scrollers show (owner, 2026-10-01: a thick, permanent
/// scroller, and a tall thumb during page swipes): thin overlay scrollers
/// whatever the system's "Show scroll bars" setting, shown by AppKit only
/// while a list scrolls, and hidden from the moment two fingers touch until
/// the gesture turns out vertical, so a page swipe never shows one.
enum TasksScrollerRule {
    enum Change: Equatable { case keep, hide, show, showLater }

    /// After a gesture that was not a vertical scroll ends, how long before
    /// the scrollers may show again (any flash AppKit began while they were
    /// hidden has faded by then).
    static let showDelay: TimeInterval = 1.0

    static func change(phase: TasksPagerSwipe.Sample.Phase, momentum: Bool,
                       axis: TasksPagerSwipe.Axis?) -> Change {
        if momentum { return .keep }
        switch phase {
        case .mayBegin:
            return .hide
        case .began, .changed:
            switch axis {
            case .vertical?, .foreign?: return .show
            case .undecided?, .horizontal?, .turned?, .cancelled?, .closing?: return .hide
            case nil: return .keep
            }
        case .ended, .cancelled:
            return axis == .vertical ? .keep : .showLater
        case .none:
            // A mouse wheel: an ordinary vertical scroll.
            return .show
        }
    }
}

// MARK: - Tab order (A10)

/// The stop Tab last sent the keyboard to (`TasksPage.settleKeyboard`).
@MainActor
final class TasksTabTarget {
    var stop: TasksTabStop?
}

/// One stop of the Tasks page's own Tab order.
enum TasksTabStop: Hashable {
    case find
    case row(UUID)
    case subtask(UUID)
    case addBar
    case strip(AtticStripFocusID)
}

/// The Tasks page's Tab order (A10), restoring Phase 1's: top to bottom as
/// drawn, every stop visible. Find while it shows on the tabs' line; each
/// row of the page shown (the filtered rows when a query or a view narrows
/// it), with the subtask lines of its open quick look under it; the add bar;
/// then the strip's buttons while a draft shows them and keyboard
/// navigation is on (buttons are Tab stops on the Mac only then). Tab after
/// the last stop goes round to the first: never to an unseen stop.
enum TasksTabOrder {
    static func stops(find: Bool, rows: [(id: UUID, subtasks: [UUID])], strip: Bool) -> [TasksTabStop] {
        var stops: [TasksTabStop] = find ? [.find] : []
        for row in rows {
            stops.append(.row(row.id))
            stops.append(contentsOf: row.subtasks.map(TasksTabStop.subtask))
        }
        stops.append(.addBar)
        if strip { stops.append(contentsOf: AtticStripFocusID.all.map(TasksTabStop.strip)) }
        return stops
    }

    /// The stop after (or, `forward` false, before) `current`, round the
    /// ends; from nowhere on the page, the first (or the last).
    static func next(after current: TasksTabStop?, in stops: [TasksTabStop], forward: Bool) -> TasksTabStop? {
        guard !stops.isEmpty else { return nil }
        guard let current, let index = stops.firstIndex(of: current) else { return forward ? stops.first : stops.last }
        return stops[(index + (forward ? 1 : stops.count - 1)) % stops.count]
    }

    /// Whether the keyboard moves from a row (or a subtask line) to the
    /// stop next to it in the list, not round the end and not from a field:
    /// that row is built and the list's own reveal is enough.
    static func isListNeighbour(_ current: TasksTabStop?, of stop: TasksTabStop, in stops: [TasksTabStop]) -> Bool {
        switch current {
        case .row?, .subtask?: break
        default: return false
        }
        guard let current, let a = stops.firstIndex(of: current), let b = stops.firstIndex(of: stop) else { return false }
        return abs(a - b) == 1
    }

    /// The row whose quick look holds subtask `id`.
    static func parent(of id: UUID, in stops: [TasksTabStop]) -> UUID? {
        guard let index = stops.firstIndex(of: .subtask(id)) else { return nil }
        for stop in stops[..<index].reversed() { if case let .row(row) = stop { return row } }
        return nil
    }
}
