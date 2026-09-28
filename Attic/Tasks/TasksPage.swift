import AppKit
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
    @StateObject private var focusTracker = AtticKeyboardFocusTracker()
    @FocusState private var focusedRow: UUID?
    @State private var drag: TasksDrag?
    @State private var fileDropRow: UUID?
    /// A row's date or tag list that is open (owner fix 5 C and D).
    @State private var metaPopover: TasksMetaPopover?
    /// The selection bar's Date or Tags picker (round 10).
    @State private var selectionPicker: SelectionPicker?
    /// The add bar's strip has a picker open.
    @State private var composerPickerOpen = false
    /// "Started tasks stay together" (review 10), while it shows.
    @State private var boundaryHint = false
    @State private var boundaryHintTask: Task<Void, Never>?
    /// A Done row the keyboard moved to, to bring into view.
    @State private var doneReveal: TasksPageModel.ScrollRequest?
    /// Where the pointer is and where the rows are (not observed: it
    /// never redraws anything), so a right-click knows its row.
    @State private var pointer = TasksPointer()
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

    /// The Done page's search field has the keyboard.
    @State private var searchFocused = false
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

    static let space = NamedCoordinateSpace.named("AtticTasksPage")

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
        // In three parts (round 10: one chain was too long for the
        // compiler to type-check in time on CI).
        observingModel(observingEdits(frame))
    }

    /// The page, its overlays, its keys and its monitors.
    private var frame: some View {
        // One full-height viewport (owner fix 8, review 9): the lists run
        // to the panel's top edge and fade under the tabs and the header,
        // which float above them; at rest the first row sits where it
        // always did (a top content margin, not a moved row).
        ZStack(alignment: .top) {
            pager
            tabsBand
            tabs
        }
        // The bottom stack owns its whole band (round 7, R4): a row scrolled
        // under the strip, the gaps between its buttons, a selection bar or
        // the add bar is never clicked, right-clicked or dragged through it.
        .overlay(alignment: .bottom) {
            TasksBottomBand(stack: bottomStack, bottomInset: bottomInset)
        }
        .overlay(alignment: .bottom) { bottomControls }
        .coordinateSpace(Self.space)
        .atticKeyboardFocusTracking(focusTracker)
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
    }

    private func pageAppeared() {
        model.resetForReveal()
        // The page opens where the tab is, without a slide.
        model.showPagerPage(animated: false)
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
        // Capture seam (`ATTIC_UI_TEST_META=date|tags`): a row's date or
        // tag list opens by itself for hands-off captures.
        if let kind = ProcessInfo.processInfo.environment["ATTIC_UI_TEST_META"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let rows = model.rows(for: model.tab)
                if kind == "date", let row = rows.first(where: { $0.model.due != nil && $0.model.state != .inProgress }) {
                    openMeta(.date, on: row.id)
                } else if kind == "tags", let row = rows.first(where: { !$0.model.tags.isEmpty }) {
                    openMeta(.tags, on: row.id)
                }
            }
        }
        #endif
        if findMonitor == nil {
            findMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                findPressed(event) || searchEscapePressed(event) || editorEscapePressed(event)
                    || undoPressed(event) || taskShortcutPressed(event) ? nil : event
            }
        }
        if scrollMonitor == nil {
            // The pager reads scroll events itself (round 9): a
            // horizontal swipe over the lists is its own, every other
            // scroll goes on to the list (or the panel) untouched.
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [model, pointer, swipe, bottomStack] event in
                // Gated before any state is read (round 10): a page that
                // is not shown, or not in this event's visible window,
                // takes nothing, not even a gesture it owned before.
                guard model.isPageShown, let window = pointer.view?.window, window.isVisible,
                      event.window === window else { return event }
                let allowed = Self.pagerTakes(event, pointer: pointer, band: swipe.band,
                                              stackHeight: bottomStack.height, pageShown: model.isPageShown)
                return model.pagerScrolled(TasksPagerSwipe.Sample(event), allowed: allowed) ? nil : event
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
        .onChange(of: metaPopover) { _, _ in updateTypingLock() }
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
            DispatchQueue.main.async { focusedRow = request.id }
        }
        // A page or tab change ends a drag, closes a row's pickers and ends
        // a menu's binding.
        .onChange(of: model.hides) { _, _ in cancelTransientState() }
        // A menu opening decides whether the last press opened it: if not
        // (the keyboard, VoiceOver, another menu), no earlier binding holds.
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            pointer.menuBegan(with: NSApp.currentEvent)
        }
        .onChange(of: model.tab) { _, _ in
            cancelTransientState()
            // The last page's row keeps no claim on the keyboard.
            focusedRow = nil
            // A tab, a key, ⌘1–3, `show` or Search: the page goes straight
            // there. A swipe's own live tab leaves the page with the fingers.
            if !swipe.isTracking { model.showPagerPage() }
        }
        // What the scroll monitor reads that lives in the view.
        .onChange(of: design.reduceMotion, initial: true) { _, reduced in swipe.reduced = reduced }
        .onChange(of: drag != nil, initial: true) { _, dragging in swipe.dragActive = dragging }
        .onChange(of: pagerBand, initial: true) { _, band in swipe.band = band }
        // Done's rows come into view as the keyboard reaches them too.
        .onChange(of: focusedRow) { _, id in
            guard let id, model.tab == .done, focusTracker.isKeyboardDriving else { return }
            doneReveal = TasksPageModel.ScrollRequest(id: id)
        }

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
            proxy.scrollTo(request.id, anchor: .center)
        }
    }

    /// A row's top and height in its list's content, from the heights of
    /// the rows (and headings) before it.
    private func rowPlace(_ id: UUID, in tab: TasksTab) -> (top: CGFloat, height: CGFloat)? {
        var top: CGFloat = 0
        if tab == .done {
            for day in model.doneDays() {
                top += AtticLayout.rowPitch
                for row in day.rows {
                    let height = pointer.frames[row.id]?.height ?? AtticLayout.rowPitch
                    if row.id == id { return (top, height) }
                    top += height
                }
            }
            return nil
        }
        let sections = model.sections(for: tab)
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
    /// page pill. The tabs stay put while the pages swipe under them. On
    /// Done a magnifier sits at the line's end (owner item 17, card B of
    /// v22); while searching, the search field takes the line.
    private var tabs: some View {
        ZStack(alignment: .topLeading) {
            if searchShown {
                AtticTabsSearchField(placeholder: model.searchPlaceholder, text: $model.doneSearch,
                                     isFocused: $searchFocused, onEscape: endSearch)
                    .accessibilityIdentifier("tasks-done-search")
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
                    if model.tab == .done {
                        // Its glyph ends where the rows' dates end. ⌘F too.
                        AtticSmallButton(systemName: "magnifyingglass", label: "Search done tasks (⌘F)", action: beginSearch)
                            .accessibilityIdentifier("tasks-done-search-button")
                            .padding(.trailing, max(0, AtticLayout.rowHighlightInset + AtticTaskRowMetrics.dateInset
                                - (AtticControlSize.smallMinWidth - AtticSmallControlMetrics.iconSize) / 2))
                            .transition(.opacity)
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
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion), value: model.tab == .done)
    }

    /// The Done search is on the tabs' line while it has the keyboard or a
    /// query (owner item 17); Esc, or clearing and leaving, returns the tabs.
    private var searchShown: Bool {
        model.tab == .done && (searchFocused || !model.doneSearch.isEmpty)
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
        searchFocused = true
    }

    /// ⌘F while this page is the one the shell shows, on Done, in its own
    /// key window, with no pop-over open: the search takes the tabs' line.
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
            focusedRow = parent
            return true
        }
        if model.renamingSubtaskID != nil {
            model.cancelSubtaskRename()
            return true
        }
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
    /// never differ; ⇧⌘I opens that menu. A field typing, an editor or a
    /// picker keeps every key.
    private func taskShortcutPressed(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, model.isPageShown, let window = pointer.view?.window, event.window === window,
              window.isKeyWindow, !AtticTextInput.hasKeyboard, model.editingTitleID == nil, model.newSubtaskParentID == nil,
              model.renamingSubtaskID == nil, !addBarFocused, !searchFocused, metaPopover == nil, drag == nil else { return false }
        let shortcuts = [AtticTaskShortcut.actions, AtticTaskShortcut.copy, AtticTaskShortcut.duplicate]
        guard let shortcut = shortcuts.first(where: {
            AtticTaskShortcut.matches($0, characters: event.charactersIgnoringModifiers, keyCode: event.keyCode, modifiers: event.modifierFlags)
        }) else { return false }
        guard let current = model.shortcutRow(focusedRow: focusedRow, visible: Set(visibleIDs())) else { return false }
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

    /// Esc with the keyboard in the Done search ends it. Here, not in the
    /// field's exit command: the panel's hosting view answers Esc itself
    /// (it ends a resize or move, else passes it up), so SwiftUI's exit
    /// command never reached the field inside the panel (round 7, found by
    /// the shell test).
    private func searchEscapePressed(_ event: NSEvent) -> Bool {
        guard searchFocused, model.isPageShown, model.tab == .done, event.keyCode == 53,
              event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
              !AtticTextInput.isPopoverOpen, let window = pointer.view?.window, event.window === window,
              // An input method composing keeps its Esc: it cancels the
              // composition, and only the next Esc ends the search (G2).
              !Self.isComposing(window.firstResponder) else { return false }
        endSearch()
        return true
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

    /// Whether ⌘F belongs to the Done search (pure, tested directly).
    static func answersFind(event: NSEvent, pageShown: Bool, tab: TasksTab, pageWindow: NSWindow?, popoverOpen: Bool) -> Bool {
        guard pageShown, tab == .done, !popoverOpen, let pageWindow, event.window === pageWindow, pageWindow.isKeyWindow,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "f" else { return false }
        return true
    }

    /// Esc (or the field's "Esc"): the search ends, the tabs return, and the
    /// Done log shows whole again.
    private func endSearch() {
        if !model.doneSearch.isEmpty { model.doneSearch = "" }
        searchFocused = false
    }

    /// Where the lists' first row rests: under the tabs, as before.
    private var listTop: CGFloat { TasksViewport.listTop(tabsTop: tabsTop) }

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
    private func revealRow(_ id: UUID, in tab: TasksTab, proxy: ScrollViewProxy, animation: Animation?) {
        let reveal = TasksViewport.reveal(frame: pointer.frames[id], height: rowHeight(id, in: tab),
                                          viewport: pointer.view?.bounds.height ?? layout.panelSize.height,
                                          listTop: listTop, bottomMargin: bottomMargin, bottomClearance: bottomClearance)
        switch reveal {
        case .none: break
        case .minimal: withAnimation(animation) { proxy.scrollTo(id) }
        case let .bottom(fraction): withAnimation(animation) { proxy.scrollTo(id, anchor: UnitPoint(x: 0, y: fraction)) }
        }
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
                                shown: TasksTab.allCases.firstIndex(of: model.tab) ?? 0, size: proxy.size) { index in
                    page(TasksTab.allCases[index])
                }
                if TasksPagerMotion.tracing {
                    TasksPagerTrace(motion: swipe.motion)
                }
            }
            .onChange(of: width, initial: true) { _, width in swipe.width = width }
        }
        // The neighbours are drawn only as they slide in, never past the
        // page's edge (the panel's shadow margin lies beyond it).
        .clipped()
    }

    private func page(_ tab: TasksTab) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch tab {
            case .now, .backlog:
                listPage(tab)
            case .done:
                TasksDonePage(model: model, store: store, listTop: listTop, bottomClearance: bottomClearance,
                              bottomMargin: bottomMargin,
                              mask: viewportMask, reveal: $doneReveal,
                              revealRow: { id, proxy in revealRow(id, in: .done, proxy: proxy, animation: nil) },
                              cell: { row in cell(row, tab: .done, group: []) },
                              proxies: listProxies,
                              registerList: { proxy in
                                  listProxies.lists[.done] = proxy
                                  takeScrollRequest(in: .done)
                              })
            }
        }
        // Larger corners move the pin (and the add bar) inward; the tabs
        // and the list follow, so the tabs stay on the pin's edge.
        .padding(.horizontal, cornerInset)
    }

    /// How far the controls sit inside their 12 pt line at this corner size.
    private var cornerInset: CGFloat { max(0, layout.chromeInsets.leading - AtticSpacing.panelMargin) }

    private func listSpace(_ tab: TasksTab) -> NamedCoordinateSpace {
        .named("AtticTasksList\(tab.rawValue)")
    }

    private func listPage(_ tab: TasksTab) -> some View {
        let rows = model.rows(for: tab)
        let sections = model.sections(for: tab)
        let groups = Dictionary(grouping: rows, by: \.status).mapValues { $0.map(\.id) }
        let travel = design.reduceMotion ? nil : AtticMotionPreset.settle.animation(reduceMotion: false)
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections.open) { row in
                        cell(row, tab: tab, group: groups[row.status] ?? [])
                            .id(row.id)
                            // A row added or leaving drops into or rises
                            // out of its place (round 9).
                            .transition(AtticMotionPreset.settle.transition(reduceMotion: design.reduceMotion, edge: .top))
                    }
                    if sections.open.isEmpty, let message = model.emptyMessage[tab] {
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
                                cell(row, tab: tab, group: groups[row.status] ?? [])
                                    .id(row.id)
                            }
                        }
                    }
                }
                .animation(travel, value: rows.map(\.id))
                // The list's place is kept while its page is not built.
                .background(TasksScrollKeeper(model: model, tab: tab, proxies: listProxies).accessibilityHidden(true))
                // The clearance past the add bar's zone is room at the end
                // of the list, not margin (see `TasksViewport.bottomMargin`).
                .padding(.bottom, bottomClearance - bottomMargin)
            }
            .contentMargins(.top, listTop, for: .scrollContent)
            .contentMargins(.bottom, bottomMargin, for: .scrollContent)
            .contentMargins(.top, listTop, for: .scrollIndicators)
            .contentMargins(.bottom, bottomClearance, for: .scrollIndicators)
            .scrollIndicators(.automatic)
            .scrollEdgeEffectHidden(true, for: .all)
            .mask { viewportMask }
            .onChange(of: focusedRow) { _, id in
                guard let id, rows.contains(where: { $0.id == id }), focusTracker.isKeyboardDriving else { return }
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
                guard tab == model.tab, let focused = focusedRow, !new.contains(focused),
                      let index = old.firstIndex(of: focused), !new.isEmpty else { return }
                guard focusTracker.isKeyboardDriving else {
                    focusedRow = nil
                    return
                }
                let next = new[min(index, new.count - 1)]
                focusedRow = next
                model.selectOnly(next)
            }
        }
    }

    /// The viewport's fade (owner fix 8, review 9): by position in the
    /// viewport, not per row, so an open quick look fades line by line as
    /// it passes under the tabs and header, or under the add bar.
    private var viewportMask: some View {
        TasksViewportMask(stack: bottomStack, tabsTop: tabsTop, listTop: listTop, bottomInset: bottomInset)
    }

    // MARK: - Row

    @ViewBuilder
    private func cell(_ row: TasksListRow, tab: TasksTab, group: [UUID]) -> some View {
        let id = row.id
        // Read when the cell draws (the closures below run in the cell's
        // own body), never captured when the list built it.
        let expanded = { model.expanded.contains(id) && row.status != .done }
        TasksReorderCell(
            model: model, focus: $focusedRow,
            id: id, tab: tab, group: group, drag: $drag, metaPopover: $metaPopover, fileDropRow: $fileDropRow,
            enabled: tab != .done && model.editingTitleID != id,
            session: dragSession,
            allowsStart: { [pointer, dragSession] point in
                // Not the circle column (before the row reports its
                // controls), and never one of the row's controls.
                point.x > cornerInset + AtticLayout.textX - AtticSpacing.s4
                    && !dragSession.isOnControl(id, at: point, rowOrigin: pointer.frames[id]?.origin)
            },
            heights: { rowHeight($0, in: tab) },
            onBegin: { beginDragSession(in: tab) },
            onEnd: finishDrag,
            onPushPastGroup: showBoundaryHint
        ) { live in
            AtticTaskRow(
                model: row.model,
                isSelected: model.selection.contains(id),
                selectionRun: selectionRun(for: id, in: tab),
                isExpanded: expanded(),
                dropLabel: live.isDropTarget ? String(localized: "Add to page") : nil,
                actions: actions(for: id, in: tab),
                onToggleExpanded: { toggleExpanded(id) },
                onSelect: { rowClicked(id, tab: tab) },
                focus: live.focus,
                titleEditing: model.editingTitleID == id ? titleEditing(for: id) : nil,
                // Every row, done ones too (round 10): a finished task shows
                // no date or tags, but its pickers open from its row.
                meta: rowMeta(for: id, open: live.metaPopover),
                onActions: { anchor in showActions(for: id, anchor: anchor, tab: tab) }
            )
            .contextMenu { rowMenu(row, tab: tab) }
        } below: {
            // A Done log task's details open under its row (Esc or the
            // menu closes them), raised over the list like a pop-over.
            if model.doneDetailID == id, let detail = model.doneDetail(for: id) {
                TasksDoneDetailView(detail: detail, store: store, restore: {
                    // The details close only once the restore saved; a
                    // failure shows under the row with Retry (round 4).
                    if model.report(model.restoreToNow(id), on: id, retry: { model.restoreToNow(id) }).isApplied {
                        model.doneDetailID = nil
                    }
                })
                .padding(.leading, AtticLayout.textX - AtticPopoverMetrics.padding - AtticPopoverMetrics.rowPadding)
                .padding(.bottom, AtticSpacing.s8)
                .transition(AtticMotionPreset.popover.transition(reduceMotion: design.reduceMotion))
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
                    onOpenPage: { model.openPage(id) },
                    commands: { subtask in subtaskCommands(subtask, of: id, in: row.subtasks) },
                    onFocusChange: { subtaskID, focused in
                        if focused { model.focusedSubtaskID = subtaskID } else if model.focusedSubtaskID == subtaskID { model.focusedSubtaskID = nil }
                    },
                    renaming: model.renamingSubtaskID.map { renaming in
                        (renaming, AtticTitleEditing(text: $model.subtaskRename, commit: { model.commitSubtaskRename() },
                                                     cancel: { model.cancelSubtaskRename() },
                                                     accessibilityLabel: String(localized: "Rename subtask")))
                    },
                    newSubtask: model.newSubtaskParentID == id
                        ? AtticTitleEditing(text: $model.newSubtaskTitle, commit: { model.commitNewSubtask() },
                                            cancel: { model.cancelEditing() },
                                            accessibilityLabel: String(localized: "New subtask of \(row.model.title)"))
                        : nil
                )
                .transition(.opacity)
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
        .onGeometryChange(for: CGRect.self) { $0.frame(in: Self.space) } action: { [pointer] frame in pointer.frames[id] = frame }
        .onDisappear { [pointer] in pointer.frames[id] = nil }
        .onDrop(of: TaskDropContent.dropTypes, delegate: TaskFileDropDelegate(
            canAccept: { content in content == .files && tab != .done && store.attachmentOwnerID(for: id) != nil },
            setTargeted: { targeted in fileDropRow = targeted ? id : (fileDropRow == id ? nil : fileDropRow) },
            perform: { content, providers in attachDroppedFiles(content, providers, to: id) }
        ))
    }

    /// The quick look opens and closes with the expansion motion (review
    /// 21); Reduce Motion shows it at once.
    private func toggleExpanded(_ id: UUID) {
        withAnimation(design.reduceMotion ? nil : AtticMotionPreset.settle.animation(reduceMotion: false)) {
            model.toggleExpanded(id)
        }
    }

    /// The title editor with the add bar's shorthand (owner fix 4).
    private func titleEditing(for id: UUID) -> AtticTitleEditing {
        AtticTitleEditing(
            text: $model.editingTitle,
            commit: {
                let saved = model.commitTitle()
                if saved { focusedRow = id }
                return saved
            },
            cancel: { model.cancelEditing(); focusedRow = id },
            tokens: AtticTitleEditing.Tokens(
                chips: model.titleEdit.tokenChips(parser: model.parser, caret: model.titleEditCaret),
                dismissChip: { range in
                    model.titleHistory.checkpoint(model.titleEdit, selection: model.titleEditCurrentSelection)
                    model.titleEdit.dismiss(range)
                },
                edited: { range, replacement in
                    model.titleHistory.willEdit(model.titleEdit, selection: model.titleEditCurrentSelection, range: range, replacement: replacement)
                    model.titleEdit.edited(range, replacement: replacement)
                },
                caretMoved: { caret in
                    if model.titleEditCaret != caret { model.titleEditCaret = caret }
                    var shown = model.titleEdit
                    if shown.markShown(parser: model.parser, caret: caret) { model.titleEdit = shown }
                },
                undoDraft: { model.undoTitleEdit() },
                redoDraft: { model.redoTitleEdit() },
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
        metaPopover = TasksMetaPopover(id: id, kind: kind, targets: targets ?? [id], newTag: newTag)
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
        .atticPickerSurface()
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
        .atticPickerSurface()
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
        focusedRow = id
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
            openPage: { model.openPage(id) },
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
            moveUp: unfinished ? { moveRow(id, by: -1) } : nil,
            moveDown: unfinished ? { moveRow(id, by: 1) } : nil,
            addSubtask: unfinished ? { model.beginAddingSubtask(to: id) } : nil,
            copy: { model.copy(model.targets(for: id)) },
            duplicate: { runCommand(on: id) { model.duplicate($0) } },
            changePriority: { showPriority(for: id) },
            showActions: { showActions(for: id, anchor: nil, tab: tab) },
            names: .init(openPage: String(localized: "Open files"))
        )
    }

    /// A key's or VoiceOver's command on the row's targets, with its
    /// failure under the row (Retry).
    private func runCommand(on id: UUID, _ command: @escaping ([UUID]) -> CommandOutcome) {
        let targets = model.targets(for: id)
        model.report(command(targets), on: id) { command(targets) }
    }

    /// ⌘Return on a Done page row: a Done log task's details open or close
    /// in place; a task still in Now's done group opens its files.
    private func toggleDetails(_ id: UUID) {
        if model.doneDetailID == id { model.doneDetailID = nil } else { model.openPage(id) }
    }

    private func isArchived(_ id: UUID) -> Bool {
        store.task(withID: id) == nil
    }

    /// VoiceOver's name for `toggleDetails`.
    private func detailsActionName(for id: UUID) -> String {
        if model.doneDetailID == id { return String(localized: "Close details") }
        return isArchived(id) ? String(localized: "Show details") : String(localized: "Open files")
    }

    /// The right-click menu's name for `toggleDetails`.
    private func detailsMenuTitle(for id: UUID) -> String {
        if model.doneDetailID == id { return String(localized: "Close Details") }
        return isArchived(id) ? String(localized: "Show Details") : String(localized: "Open Files…")
    }

    private func deleteAndMoveFocus(_ ids: [UUID]) {
        let visible = visibleIDs()
        let next = visible.first { !ids.contains($0) && (visible.firstIndex(of: $0) ?? 0) > (ids.compactMap { visible.firstIndex(of: $0) }.max() ?? 0) }
            ?? visible.last { !ids.contains($0) }
        // Focus moves only once the delete saved (Astra 6); a failure shows
        // under the row the command came from.
        guard let first = ids.first, model.report(model.delete(ids), on: first, retry: { model.delete(ids) }).isApplied else { return }
        focusedRow = next
        if let next { model.selectOnly(next) }
    }

    // MARK: - Right-click menu

    /// The right-click menu: the task's commands (`taskCommands`), the
    /// same list the actions button and ⇧⌘I open.
    private func rowMenu(_ row: TasksListRow, tab: TasksTab) -> some View {
        AtticMenuItems(commands: taskCommands(row.id, tab: tab))
    }

    /// Every command a row offers, in one list (round 10: one definition
    /// for the right-click menu, the actions button, ⇧⌘I, and the keys
    /// ⌘C and ⌘D, which run the command this list holds for their key).
    /// It acts on the menu's targets: the row, or the selection it is part
    /// of. Each command shows its key from `AtticTaskShortcut`.
    func taskCommands(_ rowID: UUID, tab: TasksTab) -> [AtticMenuCommand] {
        let id = menuRowID(rowID)
        let targets = menuTargets(rowID)
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
                menuCommand(rowID) { model.restoreToNow($0) }
            })
            list.append(AtticMenuCommand(verbatim: String(localized: "Mark as Not Done"), shortcut: AtticTaskShortcut.complete) {
                menuCommand(rowID) { model.toggleDone($0) }
            })
            if single {
                list.append(AtticMenuCommand(verbatim: detailsMenuTitle(for: id), shortcut: AtticTaskShortcut.openPage) {
                    guard !AtticTextInput.ownsCurrentKey else { return }
                    toggleDetails(menuRowID(rowID))
                })
            }
        } else {
            list.append(AtticMenuCommand(verbatim: allDone ? String(localized: "Mark as Not Done") : String(localized: "Complete"),
                                         shortcut: AtticTaskShortcut.complete, startsSection: single) {
                menuCommand(rowID) { targets in
                    let outcome = model.toggleDone(targets)
                    completionFeedback(outcome, targets)
                    return outcome
                }
            })
            list.append(AtticMenuCommand(verbatim: allWorking ? String(localized: "Stop Working") : String(localized: "Start Working"),
                                         shortcut: AtticTaskShortcut.working) {
                menuCommand(rowID) { model.toggleWorking($0) }
            })
        }
        if single {
            list.append(AtticMenuCommand(verbatim: String(localized: "Edit Title"), shortcut: AtticTaskShortcut.editTitle,
                                         startsSection: true) {
                guard !AtticTextInput.ownsCurrentKey else { return }
                let id = menuRowID(rowID)
                model.selectOnly(id)
                model.beginEditingTitle(id)
            })
        }
        // Date, Tags and Priority (owner fixes 3 and 5 D): on the menu's
        // targets, a multi-selection too; one step each. Done's rows too,
        // without changing completion (round 10).
        list.append(.submenu(String(localized: "Date"), startsSection: !single, dateCommands(rowID, targets: targets)))
        list.append(.submenu(String(localized: "Tags"), tagCommands(rowID, targets: targets)))
        list.append(.submenu(String(localized: "Priority"), priorityCommands(rowID, targets: targets)))
        if tab == .backlog {
            list.append(AtticMenuCommand(verbatim: String(localized: "Move to Now"), shortcut: AtticTaskShortcut.later) {
                menuCommand(rowID) { model.moveToNow($0) }
            })
        } else if tab == .now {
            list.append(AtticMenuCommand(verbatim: String(localized: "Move to Later"), shortcut: AtticTaskShortcut.later) {
                menuCommand(rowID) { model.moveToBacklog($0) }
            })
        }
        if single, tab != .done {
            if unfinished {
                list.append(AtticMenuCommand(verbatim: String(localized: "Add Subtask"), startsSection: true) {
                    model.beginAddingSubtask(to: menuRowID(rowID))
                })
            }
            list.append(AtticMenuCommand(verbatim: String(localized: "Open Files…"), shortcut: AtticTaskShortcut.openPage,
                                         startsSection: !unfinished) {
                guard !AtticTextInput.ownsCurrentKey else { return }
                model.openPage(menuRowID(rowID))
            })
            // Reorder (round 10): the same rule as ⌘↑ ⌘↓ and a drag.
            if unfinished {
                list.append(AtticMenuCommand(verbatim: String(localized: "Move Up"), shortcut: AtticTaskShortcut.moveUp,
                                             isDisabled: !canMove(id, by: -1), startsSection: true) {
                    moveRow(menuRowID(rowID), by: -1)
                })
                list.append(AtticMenuCommand(verbatim: String(localized: "Move Down"), shortcut: AtticTaskShortcut.moveDown,
                                             isDisabled: !canMove(id, by: 1)) {
                    moveRow(menuRowID(rowID), by: 1)
                })
            }
        }
        list.append(AtticMenuCommand(verbatim: String(localized: "Copy"), shortcut: AtticTaskShortcut.copy, startsSection: true) {
            model.copy(menuTargets(rowID))
            pointer.endInvocation()
        })
        list.append(AtticMenuCommand(verbatim: String(localized: "Duplicate"), shortcut: AtticTaskShortcut.duplicate) {
            menuCommand(rowID) { model.duplicate($0) }
        })
        list.append(AtticMenuCommand(verbatim: single ? String(localized: "Delete") : String(localized: "Delete \(targets.count) Tasks"),
                                     shortcut: AtticTaskShortcut.delete, isDestructive: true, startsSection: true) {
            // A menu's Delete key equivalent never reaches past a field
            // that is typing (round 5, the owner's blocker).
            guard !AtticTextInput.ownsCurrentKey else { return }
            deleteAndMoveFocus(menuTargets(rowID))
        })
        return list
    }

    /// Date ▸: the quick days (one tick for one day: on a Sunday, Tomorrow
    /// and Next Week are the same Monday; only the first is ticked), Pick
    /// a Date…, Remove Date.
    private func dateCommands(_ rowID: UUID, targets: [UUID]) -> [AtticMenuCommand] {
        let choices = model.dateChoices
        let current = model.commonDueDay(targets)
        let ticked = choices.quick.first { $0.day == current }?.id
        var list = choices.quick.map { quick in
            AtticMenuCommand(verbatim: quick.menuTitle, state: quick.id == ticked ? .on : .off,
                             detail: choices.detail(for: quick.day)) {
                menuCommand(rowID) { model.setDueDay(quick.day, for: $0) }
            }
        }
        list.append(AtticMenuCommand(verbatim: String(localized: "Pick a Date…"), startsSection: true) {
            openMeta(.date, on: menuRowID(rowID), targets: menuTargets(rowID))
        })
        list.append(AtticMenuCommand(verbatim: String(localized: "Remove Date"), isDisabled: targets.allSatisfy { model.dueDay(of: $0) == nil },
                                     startsSection: true) {
            menuCommand(rowID) { model.setDueDay(nil, for: $0) }
        })
        return list
    }

    /// Tags ▸: the targets' tags, then the library's most used (twelve), a
    /// tick when every target has one and a dash when some do (review 17);
    /// All Tags… opens the searchable picker with every tag and creation.
    private func tagCommands(_ rowID: UUID, targets: [UUID]) -> [AtticMenuCommand] {
        var list = model.tagChoices(for: targets).prefix(12).map { tag in
            AtticMenuCommand(verbatim: "#" + tag, state: model.tagState(tag, for: targets)) {
                menuCommand(rowID) { model.toggleTag(tag, for: $0) }
            }
        }
        list.append(AtticMenuCommand(verbatim: String(localized: "All Tags…"), startsSection: true) {
            openMeta(.tags, on: menuRowID(rowID), targets: menuTargets(rowID), newTag: true)
        })
        return list
    }

    /// Priority ▸: No Priority, Medium, High (Low only while every target
    /// has it, round 7 R6), ticked when every target has it.
    private func priorityCommands(_ rowID: UUID, targets: [UUID]) -> [AtticMenuCommand] {
        let priorities = Set(targets.compactMap { store.listedTask(withID: $0)?.priority })
        return TaskPriority.choices(keeping: priorities).map { priority in
            AtticMenuCommand(verbatim: priority.menuTitle, state: priorities == [priority] ? .on : .off) {
                menuCommand(rowID) { model.setPriority(priority, for: $0) }
            }
        }
    }

    /// A quick-look subtask's commands (round 10), one list for its keys,
    /// its right-click menu and its VoiceOver actions: done or not (Space),
    /// Rename (Return), Move Up and Down among the subtasks in its state
    /// (⌘↑ ⌘↓), Delete (⌫, to Recently Deleted). A failure shows under
    /// the parent row with Retry.
    private func subtaskCommands(_ subtask: AtticSubtaskModel, of parentID: UUID,
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
            AtticMenuCommand(verbatim: String(localized: "Delete"), shortcut: AtticTaskShortcut.delete, isDestructive: true,
                             startsSection: true) {
                guard !AtticTextInput.ownsCurrentKey else { return }
                run { model.deleteSubtask(subtask.id) }
            }
        ]
    }

    /// Whether ⌘↑ (-1) or ⌘↓ (1) can move the row within its group.
    private func canMove(_ id: UUID, by step: Int) -> Bool {
        guard model.tab != .done, let task = store.task(withID: id), task.status != .done else { return false }
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
        if atGroupEdge(id, step: step) {
            showBoundaryHint()
        } else {
            model.report(model.moveBy(id, offset: step), on: id) { model.moveBy(id, offset: step) }
        }
    }

    /// ⇧⌘I, the actions button and VoiceOver's "Show actions": the task's
    /// whole menu (for a selection, the selection's), under `anchor` or at
    /// the row.
    private func showActions(for id: UUID, anchor: NSView?, tab: TasksTab) {
        if !model.selection.contains(id) { model.selectOnly(id) }
        presentMenu(taskCommands(id, tab: tab), at: id, anchor: anchor)
    }

    /// Opens a native menu under `anchor`, or at the row's title line.
    private func presentMenu(_ commands: [AtticMenuCommand], at id: UUID, anchor: NSView?) {
        if let anchor, anchor.window != nil {
            AtticNativeMenu.popUp(commands, in: anchor)
        } else if let view = pointer.view, let frame = pointer.frames[id] {
            AtticNativeMenu.popUp(commands, in: view, at: CGPoint(x: frame.minX + AtticLayout.textX, y: frame.minY + AtticLayout.rowPitch))
        } else if let view = pointer.view {
            AtticNativeMenu.popUp(commands, in: view, at: CGPoint(x: AtticLayout.textX, y: listTop))
        }
    }

    /// VoiceOver's "Change priority": the Priority choices at the row.
    private func showPriority(for id: UUID) {
        if !model.selection.contains(id) { model.selectOnly(id) }
        presentMenu(priorityCommands(id, targets: model.targets(for: id)), at: id, anchor: nil)
    }

    /// The row a menu command acts from: always the menu's own row.
    private func menuRowID(_ row: UUID) -> UUID { row }

    /// What a menu command acts on: the targets its opening press took on
    /// this row (the row, or the selection it was part of then), or, for a
    /// menu no press opened, the row's targets now (round 5, F2).
    private func menuTargets(_ row: UUID) -> [UUID] {
        pointer.binding(for: row)?.targets ?? model.targets(for: row)
    }

    /// Runs a menu command on its targets; a failure shows under the menu's
    /// row with Retry (round 4: outcomes reach the UI). The command ends
    /// the binding: the next menu is bound by its own opening.
    private func menuCommand(_ row: UUID, _ command: @escaping ([UUID]) -> CommandOutcome) {
        guard !AtticTextInput.ownsCurrentKey else { return }
        let targets = menuTargets(row)
        pointer.endInvocation()
        model.report(command(targets), on: row) { command(targets) }
    }

    /// A press, before SwiftUI sees it. A secondary click or Control-click
    /// on a row binds the menu about to open to that row, selecting it
    /// unless it is already part of the selection (as in Finder); any other
    /// press, or one outside the list, ends the previous binding.
    private func mousePressed(_ event: NSEvent) {
        dragSession.newPress()
        // A plain click in the list that no row takes (the space under the
        // rows, a day heading, Done's search) clears the selection and the
        // keyboard's row, as in a native list (round 5: the owner's Done
        // row stayed lit after a click elsewhere).
        let bandTop = TasksBottomBand.height(stack: bottomStack.height, bottomInset: bottomInset)
        // A plain click on Done's tabs' line (the search field, or back
        // into a search already open): no row stays lit (round 7, R3).
        if model.tab == .done, event.type == .leftMouseDown,
           event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty,
           let point = pointer.location(of: event), point.y < listTop - AtticLayout.pageTabsToList / 2,
           point.y > layout.headerBottom {
            if !model.selection.isEmpty { model.clearSelection() }
            if focusedRow != nil { focusedRow = nil }
        }
        if pointer.isPlainPressOutsideRows(event, top: listTop - AtticLayout.pageTabsToList / 2,
                                           bottomInset: bandTop) {
            if !model.selection.isEmpty { model.clearSelection() }
            if focusedRow != nil { focusedRow = nil }
        }
        // Only the rows' visible part: between the tabs' band and the
        // bottom stack's band (round 7, R4).
        pointer.press(event, below: listTop - AtticLayout.pageTabsToList / 2, aboveBottom: bandTop) { id in
            if !model.selection.contains(id) { model.selectOnly(id) }
            return model.targets(for: id)
        }
    }

    // MARK: - Keys

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
        if searchFocused, model.tab == .done, model.isPageShown, modifiers.isEmpty || modifiers == .shift,
           Self.startsSearch(press.characters) {
            model.doneSearch += press.characters
            return .handled
        }
        // Every editor keeps its own keys (review 8): the title, a new
        // subtask, the add bar and Done's search.
        guard model.editingTitleID == nil, model.newSubtaskParentID == nil, model.renamingSubtaskID == nil,
              !addBarFocused, !searchFocused else { return .ignored }
        // Typing on the Done page starts a search there (owner item 17):
        // the letter is the query's first, the field takes the tabs' line.
        if model.tab == .done, model.isPageShown, modifiers.isEmpty || modifiers == .shift, Self.startsSearch(press.characters) {
            model.doneSearch = press.characters
            beginSearch()
            return .handled
        }
        let visible = visibleIDs()
        // The focused row, or the one selected row when the keyboard is
        // elsewhere in the page (a click on a row in a panel that was not
        // key yet can leave focus on the page's first control).
        let current = (focusedRow ?? (model.selection.count == 1 ? model.selection.first : nil))
            .flatMap { visible.contains($0) ? $0 : nil }
        switch press.key {
        case .downArrow, .upArrow:
            let step = press.key == .downArrow ? 1 : -1
            guard let current, let index = visible.firstIndex(of: current) else {
                focusedRow = step > 0 ? visible.first : visible.last
                if let focusedRow { model.selectOnly(focusedRow) }
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
            focusedRow = next
            if modifiers == .shift { model.extendSelection(to: next, visible: visible) } else { model.selectOnly(next) }
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
            if drag != nil { cancelDrag(); return .handled }
            if model.doneDetailID != nil { model.doneDetailID = nil; return .handled }
            // A search left with its query: Esc ends it (the tabs return).
            if model.tab == .done, !model.doneSearch.isEmpty { endSearch(); return .handled }
            // Esc closes the quick look the keyboard is in (or the one
            // open) and the keyboard returns to its row (review UX 2).
            let open = current.flatMap { model.expanded.contains($0) ? $0 : nil }
                ?? (model.expanded.count == 1 ? model.expanded.first.flatMap { visible.contains($0) ? $0 : nil } : nil)
            if let open {
                toggleExpanded(open)
                focusedRow = open
                return .handled
            }
            if model.selection.count > 1 { model.clearSelection(); return .handled }
            return .ignored
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
        if let measured = pointer.frames[id]?.height, measured > 0 { return measured }
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
    }

    /// The drop: the move is one step; the lift clears whether the save
    /// works or not.
    private func finishDrag(_ finished: TasksDrag) {
        let travel = design.reduceMotion ? nil : AtticMotionPreset.settle.animation(reduceMotion: false)
        // The keyboard comes to the moved row, so ⌘Z (and Esc) reach the
        // list right after a drop.
        focusedRow = finished.id
        withAnimation(travel) {
            drag = nil
            if finished.targetIndex != finished.startIndex {
                let moved = model.report(model.move(finished.id, toGroupIndex: finished.targetIndex), on: finished.id) {
                    model.move(finished.id, toGroupIndex: finished.targetIndex)
                }
                // The tick confirms a move that saved, never a failed one.
                if moved.isApplied { AtticHaptics.tick(enabled: design.hapticsEnabled) }
            }
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

    /// "Started tasks stay together" for two seconds (review 10).
    private func showBoundaryHint() {
        boundaryHintTask?.cancel()
        withAnimation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion)) { boundaryHint = true }
        AccessibilityNotification.Announcement(String(localized: "Started tasks stay together")).post()
        boundaryHintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion)) { boundaryHint = false }
        }
    }

    // MARK: - Files

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
                TasksBoundaryHint()
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
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion), value: model.selection.count > 1)
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion), value: model.pasteOffer)
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
                return TaskPriority.choices(keeping: priorities).map { priority in
                    AtticMenuCommand(verbatim: priority.menuTitle, state: priorities == [priority] ? .on : .off) {
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
        .atticPickerSurface()
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
        .atticPickerSurface()
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
        guard isFocused, let suggestion = text.text.suggestion(parser: model.parser, caret: text.caret, tags: model.cachedTags),
              suggestion.range != text.hiddenSuggestion else { return nil }
        return suggestion
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
                        edited: { range, replacement in model.addBarEdited(range, replacement: replacement) },
                        caretMoved: { caret in model.addBarCaretMoved(caret) },
                        suggestionKey: { key in suggestionKey(key) },
                        undoDraft: { text.undoDraft() },
                        redoDraft: { text.redoDraft() },
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
        // Over the strip and the bar, never pushing them (review 14).
        .overlay(alignment: .topLeading) {
            if let suggestion {
                AtticSuggestionList(items: items(for: suggestion), highlighted: min(text.highlighted, suggestion.count - 1),
                                    onHover: { index in if text.highlighted != index { text.highlighted = index } }) { index in
                    model.accept(suggestion, choice: index, editor: editor)
                    text.highlighted = 0
                }
                .padding(.leading, AtticAddBarMetrics.iconSlot + AtticAddBarMetrics.gap - AtticPopoverMetrics.padding - AtticPopoverMetrics.rowPadding)
                .transition(.opacity)
                // Its own height above the composer's top (rows are 28 tall).
                .offset(y: -(CGFloat(suggestion.count) * AtticControlSize.smallHeight + AtticPopoverMetrics.padding * 2
                    + AtticPickerMetrics.stripToBar))
            }
        }
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion), value: stripShown)
        .onChange(of: datePresented || tagsPresented || priorityPresented) { _, open in
            pickerOpen = open
            // A closed picker hands the keyboard back to the draft, where
            // its insertion point was (review 14).
            if !open { editor.focus() }
        }
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
    /// The Tag button's value: the first tag, and how many more.
    static func tags(_ tags: [String]) -> AtticStripValue? {
        guard let first = tags.first else { return nil }
        let more = tags.count - 1
        return AtticStripValue(
            text: more > 0 ? "#\(first) +\(more)" : "#\(first)",
            spoken: more > 0 ? String(localized: "\(first) and \(more) more") : first
        )
    }

    /// The Priority button's value: its mark, `!!` in High's orange.
    static func priority(_ priority: TaskPriority?) -> AtticStripValue? {
        switch priority {
        case .high?: AtticStripValue(text: "!!", ink: .priorityMark, style: .priorityMark, spoken: String(localized: "High"))
        case .medium?: AtticStripValue(text: "!", ink: .helper, style: .priorityMark, spoken: String(localized: "Medium"))
        case .low?: AtticStripValue(text: String(localized: "Low"), spoken: String(localized: "Low"))
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
        case .low: "Low"
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
    var controlFrames: [UUID: [CGRect]] = [:]
    var timer: Timer?

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
    func isOnControl(_ id: UUID, at point: CGPoint, rowOrigin origin: CGPoint?) -> Bool {
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
    /// Observed here, in the cell: a lazy list does not rebuild a cell when
    /// only the page's state changes, so the cell redraws itself when the
    /// selection, editing or keyboard focus move (the focus ring lagging a
    /// row behind, the computer-use review's bug 4).
    @ObservedObject var model: TasksPageModel
    var focus: FocusState<UUID?>.Binding
    let id: UUID
    let tab: TasksTab
    let group: [UUID]
    @Binding var drag: TasksDrag?
    /// Page state the row shows (its open picker, a file over it), read in
    /// this cell's own body so the row redraws when they change: a lazy
    /// list's cells are not rebuilt when only the page's state changes.
    @Binding var metaPopover: TasksMetaPopover?
    @Binding var fileDropRow: UUID?
    let enabled: Bool
    /// The drag's live state: cancellation, pointer, control frames.
    let session: TasksDragSession
    /// Whether a press at this page point may start a drag (not on the
    /// row's circle, checklist, date or tags).
    let allowsStart: (CGPoint) -> Bool
    let heights: (UUID) -> CGFloat
    let onBegin: () -> Void
    let onEnd: (TasksDrag) -> Void
    let onPushPastGroup: () -> Void
    @ViewBuilder let row: (TasksCellLive) -> Row
    @ViewBuilder let below: () -> Below

    @Environment(\.atticDesign) private var design
    @GestureState private var translation: CGFloat?
    @State private var pushedPast = false

    var body: some View {
        let lifted = drag?.id == id && translation != nil
        // Read here, in the cell's own body, so a new target moves the
        // neighbours at once (a list's lazy cells do not re-read the page).
        let offset = drag.map { Self.offset(of: id, in: $0, heights: heights) } ?? 0
        let live = TasksCellLive(
            metaPopover: metaPopover?.id == id ? metaPopover : nil,
            focus: AtticRowFocus(binding: focus, id: id),
            isDropTarget: fileDropRow == id
        )
        VStack(alignment: .leading, spacing: 0) {
            // An ordinary gesture on the row: its buttons (the circle, the
            // date, the tags, the checklist) keep their clicks; a press that
            // moves 4 pt drags at once, with no hold.
            row(live)
                .onPreferenceChange(AtticRowControlFramesKey.self) { [session, id] frames in
                    MainActor.assumeIsolated { session.controlFrames[id] = frames }
                }
                .simultaneousGesture(gesture, including: enabled ? .all : .subviews)
            below()
        }
        .modifier(AtticReorderLiftModifier(lifted: lifted))
        // The lifted row follows the pointer, plus whatever the list has
        // scrolled under it.
        .offset(y: lifted ? (translation ?? 0) + (drag?.scrolled ?? 0) : offset)
        .zIndex(lifted ? 1 : 0)
        .animation(lifted || design.reduceMotion ? nil : AtticMotionPreset.settle.animation(reduceMotion: false), value: offset)
        .onChange(of: translation == nil) { _, ended in
            guard ended else { return }
            // Released, cancelled by the system or by Esc: the lift goes
            // (a release was committed by `onEnded` already), and the next
            // press starts afresh.
            pushedPast = false
            if drag?.id == id { drag = nil }
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
                let scrolled = drag?.id == id ? (drag?.scrolled ?? 0) : 0
                let moved = value.translation.height + scrolled
                let target = Self.target(start: start, translation: moved, group: group, heights: heights)
                if drag?.id != id {
                    drag = TasksDrag(id: id, tab: tab, group: group, startIndex: start, targetIndex: target)
                    onBegin()
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
}

/// A quiet line over the add bar while a drag or ⌘↑ ⌘↓ meets the edge of
/// its group (review 10).
private struct TasksBoundaryHint: View {
    var body: some View {
        HStack(spacing: AtticSpacing.s4) {
            AtticIcon(systemName: "arrow.up.and.down", size: AtticTaskRowMetrics.detailsIconSize, weight: .medium, ink: .icon)
            AtticText(verbatim: String(localized: "Started tasks stay together"), style: .controlLabel, ink: .helper)
        }
        .frame(height: AtticErrorLineMetrics.height)
        .padding(.leading, AtticLayout.textX - AtticSpacing.panelMargin - AtticTaskRowMetrics.detailsIconSize - AtticSpacing.s4)
        .accessibilityElement(children: .combine)
    }
}

/// The rows' frames in the page and the current menu invocation, kept out
/// of view state (writing them redraws nothing).
final class TasksPointer {
    var frames: [UUID: CGRect] = [:]
    /// The page's own view: a press is placed in the page from its event.
    weak var view: NSView?

    /// One context menu's binding: the row it was opened on and what its
    /// commands act on, taken at the press that opened it.
    struct Invocation: Equatable {
        let row: UUID
        let targets: [UUID]
        /// The opening press's timestamp: the menu that begins with this
        /// event is the one it binds.
        var pressedAt: TimeInterval = 0
    }

    private(set) var invocation: Invocation?

    /// The binding for a menu on `row`: only one opened by a press on that
    /// same row (a menu on another row never inherits it).
    func binding(for row: UUID) -> Invocation? {
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
    func press(_ event: NSEvent, below minY: CGFloat, aboveBottom bottomBand: CGFloat = 0, select: (UUID) -> [UUID]) {
        guard MenuPress(type: event.type, modifiers: event.modifierFlags) != .none,
              let point = location(of: event), point.y >= minY,
              point.y <= (view?.bounds.height ?? .greatestFiniteMagnitude) - bottomBand,
              let id = row(at: point) else {
            invocation = nil
            return
        }
        invocation = Invocation(row: id, targets: select(id), pressedAt: event.timestamp)
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
    func isPlainPressOutsideRows(_ event: NSEvent, top: CGFloat, bottomInset: CGFloat) -> Bool {
        guard event.type == .leftMouseDown,
              event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty,
              let view, let point = location(of: event), point.y >= top, point.y <= view.bounds.height - bottomInset
        else { return false }
        return row(at: point) == nil
    }

    /// The row under `point`: the one whose frame holds it (the list's
    /// visible part; a row's frame is the row and its quick look).
    func row(at point: CGPoint) -> UUID? {
        frames.first { $0.value.contains(point) && $0.value.height < 2_000 }?.key
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

/// A row's open date or tag list, and the tasks it changes.
struct TasksMetaPopover: Equatable {
    enum Kind { case date, tags }
    let id: UUID
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
    /// What the viewport's fade uses: the height a moment later. Changing
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

/// The viewport's fade, redrawn by itself when the bottom stack changes.
private struct TasksViewportMask: View {
    @ObservedObject var stack: TasksBottomStackHeight
    let tabsTop: CGFloat
    let listTop: CGFloat
    let bottomInset: CGFloat

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                stops: TasksViewport.maskStops(height: proxy.size.height, tabsTop: tabsTop, listTop: listTop,
                                                bottomStack: stack.maskHeight + bottomInset)
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

/// The list viewport's geometry (owner fix 8, review 9), pure so the
/// clearance and the fade are tested directly.
enum TasksViewport {
    /// The bottom stack's room the lists always keep: the add bar, and the
    /// strip over it with its gap (it comes and goes with the draft).
    static let reservedStack = AtticControlSize.addBarHeight + AtticPickerMetrics.stripToBar + AtticControlSize.smallHeight

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

    /// The fade by position in the viewport: nothing over the header, a
    /// faint trace under the tabs (so they stay readable over scrolled
    /// text), fully there from the first row's resting place down to the
    /// bottom zone, and receding under the bottom stack.
    static func maskStops(height: CGFloat, tabsTop: CGFloat, listTop: CGFloat, bottomStack: CGFloat) -> [(location: CGFloat, opacity: Double)] {
        guard height > 0 else { return [(0, 1), (1, 1)] }
        let tabsBottom = tabsTop + AtticLayout.pageTabsHeight
        // The fade starts in the 16 pt the list keeps from the bar and
        // reaches a faint trace under the controls: without the per-row
        // blur, text under see-through glass must be quieter than before.
        let fadeStart = max(height - bottomStack - AtticLayout.contentToAddBar * 1.75, listTop)
        let barTop = max(height - bottomStack, fadeStart)
        let points: [(CGFloat, Double)] = [
            (0, 0),
            (tabsTop - AtticLayout.pageTabsTop / 2, 0.04),
            (tabsBottom, 0.14),
            (listTop, 1),
            (fadeStart, 1),
            (barTop, 0.22),
            (height, 0.06)
        ]
        var result: [(location: CGFloat, opacity: Double)] = []
        var last: CGFloat = -1
        for (y, opacity) in points {
            let location = min(max(y / height, 0), 1)
            guard location > last || result.isEmpty else { continue }
            result.append((location, opacity))
            last = location
        }
        return result
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
}
