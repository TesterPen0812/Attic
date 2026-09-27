import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the page tells its host about itself: how tall its bottom controls
/// are (shell notices sit above them) and whether the panel must stay open
/// (someone is typing in it).
struct TasksPageChrome {
    var bottomControlsHeight: (CGFloat) -> Void = { _ in }
    var typingLock: (Bool) -> Void = { _ in }
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
    /// The add bar's strip has a picker open.
    @State private var composerPickerOpen = false
    /// "Started tasks stay together" (review 10), while it shows.
    @State private var boundaryHint = false
    @State private var boundaryHintTask: Task<Void, Never>?
    /// A row just added from the add bar, to bring into view.
    @State private var revealRequest: TasksPageModel.ScrollRequest?
    /// A Done row the keyboard moved to, to bring into view.
    @State private var doneReveal: TasksPageModel.ScrollRequest?
    /// Where the pointer is and where the rows are (not observed: it
    /// never redraws anything), so a right-click knows its row.
    @State private var pointer = TasksPointer()
    @State private var rightClickMonitor: Any?
    /// The add bar's text, edited the way typing does (the strip, suggestions).
    @State private var addBarEditor = AtticTokenFieldEditor()

    /// The Done page's search field has the keyboard.
    @State private var searchFocused = false
    /// The pager's scroll phase: only a person's swipe changes the page.
    @State private var pagerPhase: ScrollPhase = .idle
    @State private var swipeEndedAt: Date?
    /// The bottom stack's height: the add bar, plus the selection bar, a
    /// paste offer or an error line while they show.
    @State private var bottomControlsHeight: CGFloat = AtticControlSize.addBarHeight

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
        // One full-height viewport (owner fix 8, review 9): the lists run
        // to the panel's top edge and fade under the tabs and the header,
        // which float above them; at rest the first row sits where it
        // always did (a top content margin, not a moved row).
        ZStack(alignment: .top) {
            pager
            tabsBand
            tabs
        }
        .overlay(alignment: .bottom) { bottomControls }
        .coordinateSpace(Self.space)
        .atticKeyboardFocusTracking(focusTracker)
        .onKeyPress(phases: .down) { press in pageKey(press) }
        .onAppear {
            model.resetForReveal()
            chrome.bottomControlsHeight(footerZone)
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
        .onDisappear {
            if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor) }
            rightClickMonitor = nil
        }
        // The page's own view, so a press is placed from its event (its
        // window, its location), never from a remembered hover point.
        .background(TasksPointerProbe(pointer: pointer).accessibilityHidden(true))
        .onChange(of: addBarFocused) { _, focused in
            updateTypingLock()
            // A field that takes the keyboard takes it from the list: a row
            // left holding focus pulled it back (computer-use bug 2).
            if focused { focusedRow = nil }
            // A draft of only spaces is no draft: the placeholder returns
            // (bug 7).
            if !focused, model.addBar.text.trimmingCharacters(in: .whitespaces).isEmpty, !model.addBar.text.isEmpty {
                model.addBarState.clearDraft()
            }
        }
        .onChange(of: searchFocused) { _, focused in
            updateTypingLock()
            if focused { focusedRow = nil }
        }
        .onChange(of: composerPickerOpen) { _, _ in updateTypingLock() }
        .onChange(of: metaPopover) { _, _ in updateTypingLock() }
        .onChange(of: model.editingTitleID) { _, id in
            updateTypingLock()
            // The row gives up the keyboard so its title field can take it.
            if id != nil { focusedRow = nil }
        }
        .onChange(of: model.newSubtaskParentID) { _, id in
            updateTypingLock()
            if id != nil { focusedRow = nil }
        }
        // A page or tab change ends a drag and closes a row's pickers.
        .onChange(of: model.hides) { _, _ in cancelTransientState() }
        .onChange(of: model.tab) { _, _ in
            cancelTransientState()
            // The last page's row keeps no claim on the keyboard.
            focusedRow = nil
        }
        // Done's rows come into view as the keyboard reaches them too.
        .onChange(of: focusedRow) { _, id in
            guard let id, model.tab == .done, focusTracker.isKeyboardDriving else { return }
            doneReveal = TasksPageModel.ScrollRequest(id: id)
        }

        // Search (the menu-bar item): the keyboard goes to the Done page's
        // search field, not the add bar.
        .onChange(of: model.pendingSearchFocus, initial: true) { _, pending in
            guard pending else { return }
            model.pendingSearchFocus = false
            addBarFocused = false
            searchFocused = true
        }
        // The shell's toast and notices sit above everything in the bottom
        // stack, so a selection bar or paste offer never hides under them.
        .preference(key: PanelPageNoticeClearancePreferenceKey.self,
                    value: footerZone + max(0, bottomControlsHeight - AtticControlSize.addBarHeight))
    }

    /// The panel must stay open while someone types or picks in it: the add
    /// bar, Done's search, a title or new subtask, or an open picker (which
    /// may reach past the panel, review 16).
    private func updateTypingLock() {
        chrome.typingLock(addBarFocused || searchFocused || model.editingTitleID != nil
            || model.newSubtaskParentID != nil || composerPickerOpen || metaPopover != nil)
    }

    /// A drag in progress and a row's pickers end when the panel hides or
    /// the page changes (review 1); nothing stays lifted.
    private func cancelTransientState() {
        if drag != nil { drag = nil }
        if metaPopover != nil { metaPopover = nil }
    }

    // MARK: - Tabs

    /// Now · Later · Done under the header, in place of a title and the
    /// page pill. The tabs stay put while the pages swipe under them.
    private var tabs: some View {
        AtticPageTabs(
            items: TasksTab.allCases.map { tab in
                AtticPageTabs.Item(page: tab, title: tab.title, accessibilityIdentifier: "tasks-page-\(tab.identifier)")
            },
            selection: Binding(get: { model.tab }, set: { model.select(tab: $0) })
        )
        .accessibilityIdentifier("tasks-page-tabs")
        .padding(.leading, AtticLayout.pageTabsX)
        .padding(.top, tabsTop)
        .padding(.horizontal, cornerInset)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - Pages

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(TasksTab.allCases) { tab in
                    page(tab)
                        .containerRelativeFrame(.horizontal)
                        // The pages beside the current one are built for the
                        // swipe; VoiceOver reads only the page shown.
                        .accessibilityHidden(tab != model.tab)
                        .id(tab)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        // Only a swipe moves the page: the position the pager reports while
        // no one is scrolling (a reveal laying out, a resize) never selects
        // a neighbour, so the panel always opens on the page the model says.
        .scrollPosition(id: Binding(get: { Optional(model.tab) }, set: { reported in
            guard let tab = reported else { return }
            let justSwiped = swipeEndedAt.map { Date().timeIntervalSince($0) < 0.4 } ?? false
            guard Self.swipeMovesPage(pagerPhase) || justSwiped else { return }
            model.select(tab: tab)
        }))
        .onScrollPhaseChange { old, phase in
            pagerPhase = phase
            // The settled page can be reported just after the swipe ends.
            if phase == .idle, Self.swipeMovesPage(old) { swipeEndedAt = Date() }
        }
        .scrollIndicators(.never)
        .scrollDisabled(drag != nil)
        .scrollEdgeEffectHidden(true, for: .all)
    }

    /// The phases in which the pager follows a person's swipe (not a
    /// layout pass, and not its own animation to the selected page).
    nonisolated static func swipeMovesPage(_ phase: ScrollPhase) -> Bool {
        switch phase {
        case .tracking, .interacting, .decelerating: true
        case .idle, .animating: false
        @unknown default: false
        }
    }

    private func page(_ tab: TasksTab) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch tab {
            case .now, .backlog:
                listPage(tab)
            case .done:
                TasksDonePage(model: model, store: store, listTop: listTop, bottomClearance: bottomClearance,
                              mask: viewportMask, searchFocused: $searchFocused, reveal: $doneReveal,
                              cell: { row in cell(row, tab: .done, group: []) })
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
                            .transition(.opacity)
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
            }
            .contentMargins(.top, listTop, for: .scrollContent)
            .contentMargins(.bottom, bottomClearance, for: .scrollContent)
            .contentMargins(.top, listTop, for: .scrollIndicators)
            .contentMargins(.bottom, bottomClearance, for: .scrollIndicators)
            .scrollIndicators(.automatic)
            .scrollEdgeEffectHidden(true, for: .all)
            .mask { viewportMask }
            .onChange(of: focusedRow) { _, id in
                guard let id, rows.contains(where: { $0.id == id }), focusTracker.isKeyboardDriving else { return }
                withAnimation(travel) { proxy.scrollTo(id) }
            }
            // An agent's `show`, or a task just added: the row comes into view.
            .onChange(of: model.scrollRequest) { _, request in
                guard let request, rows.contains(where: { $0.id == request.id }) else { return }
                withAnimation(travel) { proxy.scrollTo(request.id, anchor: .center) }
            }
            .onChange(of: revealRequest) { _, request in
                guard let request, tab == model.tab else { return }
                // The row exists once the store's change reaches the list.
                DispatchQueue.main.async {
                    withAnimation(travel) { proxy.scrollTo(request.id) }
                }
            }
            // A row the keyboard completed leaves its place: the keyboard
            // moves on to the row that took it (review 8).
            .onChange(of: rows.map(\.id)) { old, new in
                guard tab == model.tab, let focused = focusedRow, !new.contains(focused),
                      let index = old.firstIndex(of: focused), !new.isEmpty else { return }
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
        GeometryReader { proxy in
            LinearGradient(
                stops: TasksViewport.maskStops(height: proxy.size.height, tabsTop: tabsTop, listTop: listTop,
                                                bottomStack: bottomControlsHeight + bottomInset)
                    .map { Gradient.Stop(color: .black.opacity($0.opacity), location: $0.location) },
                startPoint: .top, endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
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
            circleEdge: cornerInset + AtticLayout.textX - AtticSpacing.s4,
            heights: { rowHeight($0, in: tab) },
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
                meta: tab == .done || row.status == .done ? nil : rowMeta(for: id, open: live.metaPopover)
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
                    newSubtask: model.newSubtaskParentID == id
                        ? AtticTitleEditing(text: $model.newSubtaskTitle, commit: { model.commitNewSubtask() },
                                            cancel: { model.cancelEditing() },
                                            accessibilityLabel: String(localized: "New subtask of \(row.model.title)"))
                        : nil
                )
                .transition(.opacity)
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
                chips: model.titleEdit.chips(parser: model.parser, caret: model.titleEditCaret),
                dismissChip: { range in
                    model.titleHistory.checkpoint(model.titleEdit, caret: model.titleEditCaret)
                    model.titleEdit.dismiss(range)
                },
                edited: { range, replacement in
                    model.titleHistory.willEdit(model.titleEdit, caret: model.titleEditCaret, range: range, replacement: replacement)
                    model.titleEdit.edited(range, replacement: replacement)
                },
                caretMoved: { caret in
                    if model.titleEditCaret != caret { model.titleEditCaret = caret }
                    var shown = model.titleEdit
                    if shown.markShown(parser: model.parser, caret: caret) { model.titleEdit = shown }
                },
                undoFallback: { model.undo() },
                redoFallback: { model.redo() },
                undoDraft: { model.undoTitleEdit() },
                redoDraft: { model.redoTitleEdit() }
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
                onCreate: { tag in model.pickerChange(on: id) { model.toggleTag(tag, for: targets) } },
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
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2, tab != .done {
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
    /// The one scope rule (review 5): a pointer on a row's own control acts
    /// on that row; the keyboard and menus act on the selection the row is
    /// part of.
    private func commandTargets(for id: UUID) -> [UUID] {
        NSApp.currentEvent?.type == .keyDown ? model.targets(for: id) : [id]
    }

    private func actions(for id: UUID, in tab: TasksTab) -> AtticTaskActions {
        if tab == .done {
            return AtticTaskActions(
                // The same scope rule as live rows: the circle acts on its
                // row, Space and the menu on the selection it is part of.
                toggleDone: {
                    let targets = commandTargets(for: id)
                    model.report(model.toggleDone(targets), on: id) { model.toggleDone(targets) }
                },
                openPage: { toggleDetails(id) },
                restoreToNow: {
                    let targets = model.targets(for: id)
                    model.report(model.restoreToNow(targets), on: id) { model.restoreToNow(targets) }
                },
                names: .init(openPage: detailsActionName(for: id))
            )
        }
        return AtticTaskActions(
            // The circle's click acts on its row; Space on a row that is part
            // of a multi-selection acts on the selection, as the menu does
            // (review 5). A failure shows under the row (review 6).
            toggleDone: {
                let targets = commandTargets(for: id)
                if targets.count > 1 {
                    model.report(model.toggleDone(targets), on: id) { model.toggleDone(targets) }
                } else {
                    model.report(model.toggleDone(id), on: id) { model.toggleDone(id) }
                }
            },
            // ⇧Space and the menu: start or stop working.
            toggleWorking: { model.toggleWorking(model.targets(for: id)) },
            openPage: { model.openPage(id) },
            moveToBacklog: {
                let targets = model.targets(for: id)
                if model.tab == .backlog { model.moveToNow(targets) } else { model.moveToBacklog(targets) }
            },
            delete: { deleteAndMoveFocus(model.targets(for: id)) },
            // Return: the title in place (not in the Done log).
            editTitle: {
                guard model.tab != .done else { return }
                model.selectOnly(id)
                model.beginEditingTitle(id)
            },
            names: .init(openPage: AtticPhase1Labels.openLiveTaskAction(design.variants))
        )
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
        return isArchived(id) ? AtticPhase1Labels.showArchivedDetailsAction(design.variants)
            : AtticPhase1Labels.openLiveTaskAction(design.variants)
    }

    /// The right-click menu's name for `toggleDetails`.
    private func detailsMenuTitle(for id: UUID) -> String {
        if model.doneDetailID == id { return String(localized: "Close Details") }
        return isArchived(id) ? AtticPhase1Labels.showArchivedDetails(design.variants)
            : AtticPhase1Labels.openLiveTask(design.variants)
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

    @ViewBuilder
    private func rowMenu(_ row: TasksListRow, tab: TasksTab) -> some View {
        // The row the pointer right-clicked (computer-use review, bug 1):
        // resolved when the menu opens and again when a command runs, never
        // from whatever this row's menu was built with earlier.
        let id = menuRowID(row.id)
        let targets = menuTargets(row.id)
        let single = targets.count == 1
        // The row's date and tag lists live on live, unfinished rows only
        // (`AtticTaskRow.meta`); the menu offers them only there.
        let hostsPickers = tab != .done && store.task(withID: id).map { $0.status != .done } == true
        if tab == .done {
            // The same commands the row's keys and VoiceOver offer
            // (`actions(for:)`), for the row the pointer right-clicked.
            let actions = actions(for: id, in: tab)
            if let restore = actions.restoreToNow {
                Button(String(localized: "Restore to Now")) { restore() }
            }
            if single {
                Button(detailsMenuTitle(for: id)) { actions.openPage() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        } else {
            let allDone = targets.allSatisfy { store.listedTask(withID: $0)?.status == .done }
            let allWorking = targets.allSatisfy { store.task(withID: $0)?.status == .inProgress }
            // A menu for several tasks says so (bug 1): "3 Tasks".
            if single {
                Section { stateCommands(row.id, allDone: allDone, allWorking: allWorking) }
            } else {
                Section(String(localized: "\(targets.count) Tasks")) { stateCommands(row.id, allDone: allDone, allWorking: allWorking) }
            }
            // Date and Tags beside Priority (owner fixes 3 and 5 D): on
            // the menu's targets, a multi-selection too; one step each.
            Menu(String(localized: "Date")) {
                let choices = model.dateChoices
                let current = model.commonDueDay(targets)
                // One tick for one day: on a Sunday, Tomorrow and Next Week
                // are the same Monday; only the first is ticked.
                let ticked = choices.quick.first { $0.day == current }?.id
                ForEach(choices.quick) { quick in
                    // A toggle draws the native tick for the current day.
                    Toggle(isOn: Binding(get: { quick.id == ticked },
                                         set: { _ in menuCommand(row.id) { model.setDueDay(quick.day, for: $0) } })) {
                        Text(quick.menuTitle)
                    }
                    .badge(Text(verbatim: choices.detail(for: quick.day)))
                }
                // Offered only where the row can show the picker: a
                // completed-today row has no date control (round 4).
                if hostsPickers {
                    Divider()
                    Button(String(localized: "Pick a Date…")) {
                        openMeta(.date, on: menuRowID(row.id), targets: menuTargets(row.id))
                    }
                }
                Divider()
                Button(String(localized: "Remove Date")) { menuCommand(row.id) { model.setDueDay(nil, for: $0) } }
                    .disabled(targets.allSatisfy { model.dueDay(of: $0) == nil })
            }
            Menu(String(localized: "Tags")) {
                ForEach(model.tagChoices(for: targets).prefix(12), id: \.self) { tag in
                    let state = model.tagState(tag, for: targets)
                    if state == .mixed {
                        // Some of the selected tasks have it: a dash, and a
                        // click adds it to all (review 17).
                        Button { menuCommand(row.id) { model.toggleTag(tag, for: $0) } } label: { Label("#" + tag, systemImage: "minus") }
                    } else {
                        Toggle(isOn: Binding(get: { state == .on }, set: { _ in menuCommand(row.id) { model.toggleTag(tag, for: $0) } })) {
                            Text(verbatim: "#" + tag)
                        }
                    }
                }
                if hostsPickers {
                    Divider()
                    Button(String(localized: "New Tag…")) {
                        openMeta(.tags, on: menuRowID(row.id), targets: menuTargets(row.id), newTag: true)
                    }
                }
            }
            Menu(String(localized: "Priority")) {
                let priorities = Set(targets.compactMap { store.task(withID: $0)?.priority })
                ForEach(TaskPriority.allCases.reversed(), id: \.self) { priority in
                    Toggle(isOn: Binding(get: { priorities == [priority] },
                                         set: { _ in menuCommand(row.id) { model.setPriority(priority, for: $0) } })) {
                        Text(priority.menuTitle)
                    }
                }
            }
            Divider()
            if tab == .backlog {
                Button(String(localized: "Move to Now")) { menuCommand(row.id) { model.moveToNow($0) } }
                    .keyboardShortcut("b", modifiers: .command)
            } else {
                Button(String(localized: "Move to Later")) { menuCommand(row.id) { model.moveToBacklog($0) } }
                    .keyboardShortcut("b", modifiers: .command)
            }
            if single {
                Button(String(localized: "Edit Title")) {
                    let id = menuRowID(row.id)
                    model.selectOnly(id)
                    model.beginEditingTitle(id)
                }
                .keyboardShortcut(.return, modifiers: [])
                if store.task(withID: id)?.status != .done {
                    Button(String(localized: "Add Subtask")) { model.beginAddingSubtask(to: menuRowID(row.id)) }
                }
                Button(AtticPhase1Labels.openLiveTask(design.variants)) { model.openPage(menuRowID(row.id)) }
                    .keyboardShortcut(.return, modifiers: .command)
            }
            Divider()
            Button(role: .destructive) {
                deleteAndMoveFocus(menuTargets(row.id))
            } label: {
                Text(single ? String(localized: "Delete") : String(localized: "Delete \(targets.count) Tasks"))
            }
            .keyboardShortcut(.delete, modifiers: [])
        }
    }

    @ViewBuilder
    private func stateCommands(_ rowID: UUID, allDone: Bool, allWorking: Bool) -> some View {
        Button(allDone ? String(localized: "Mark as Not Done") : String(localized: "Complete")) {
            menuCommand(rowID) { model.toggleDone($0) }
        }
        .keyboardShortcut(.space, modifiers: [])
        Button(allWorking ? String(localized: "Stop Working") : String(localized: "Start Working")) {
            menuCommand(rowID) { model.toggleWorking($0) }
        }
        .keyboardShortcut(.space, modifiers: .shift)
    }

    /// The row this menu invocation was opened on (bound by the press that
    /// opened it), or this menu's own row.
    private func menuRowID(_ fallback: UUID) -> UUID {
        pointer.invocation?.row ?? fallback
    }

    /// What a menu command acts on: the invocation's targets, taken when
    /// the menu opened (the row, or the selection it was part of).
    private func menuTargets(_ fallback: UUID) -> [UUID] {
        if let invocation = pointer.invocation { return invocation.targets }
        return model.targets(for: fallback)
    }

    /// Runs a menu command on its targets; a failure shows under the menu's
    /// row with Retry (round 4: outcomes reach the UI).
    private func menuCommand(_ fallback: UUID, _ command: @escaping ([UUID]) -> CommandOutcome) {
        let row = menuRowID(fallback)
        let targets = menuTargets(fallback)
        model.report(command(targets), on: row) { command(targets) }
    }

    /// A press, before SwiftUI sees it. A secondary click or Control-click
    /// on a row binds the menu about to open to that row, selecting it
    /// unless it is already part of the selection (as in Finder); any other
    /// press, or one outside the list, ends the previous binding.
    private func mousePressed(_ event: NSEvent) {
        pointer.press(event, below: listTop - AtticLayout.pageTabsToList / 2) { id in
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
        let modifiers = press.modifiers.intersection([.command, .shift, .option, .control])
        if press.key == KeyEquivalent("z") || press.characters.lowercased() == "z" {
            // ⌘Z reaches the page only when the field being edited had
            // nothing of its own to undo (the Edit menu's Undo, a key
            // equivalent, takes a field's typing first): the Tasks history
            // then (Astra 23). The window's undo manager is never called
            // from here.
            if modifiers == .command { model.undo(); return .handled }
            if modifiers == [.command, .shift] { model.redo(); return .handled }
        }
        // Every editor keeps its own keys (review 8): the title, a new
        // subtask, the add bar and Done's search.
        guard model.editingTitleID == nil, model.newSubtaskParentID == nil, !addBarFocused, !searchFocused else { return .ignored }
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
                if atGroupEdge(current, step: step) {
                    showBoundaryHint()
                } else {
                    model.report(model.moveBy(current, offset: step), on: current) { model.moveBy(current, offset: step) }
                }
                return .handled
            }
            let next = visible[min(max(index + step, 0), visible.count - 1)]
            focusedRow = next
            if modifiers == .shift { model.extendSelection(to: next, visible: visible) } else { model.selectOnly(next) }
            return .handled
        case .return where modifiers.isEmpty:
            guard let current, model.tab != .done else { return .ignored }
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
            if drag != nil { drag = nil; return .handled }
            if model.doneDetailID != nil { model.doneDetailID = nil; return .handled }
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

    // MARK: - Drag

    /// A row's height, from what it shows (no measuring, so scrolling never
    /// writes view state): 34 pt, 48 with a details line, plus the quick
    /// look's lines when it is open.
    private func rowHeight(_ id: UUID, in tab: TasksTab) -> CGFloat {
        guard let row = model.rows(for: tab).first(where: { $0.id == id }) else { return AtticLayout.rowPitch }
        let pitch = row.model.hasDetails ? AtticLayout.detailRowPitch : AtticLayout.rowPitch
        guard model.expanded.contains(id), row.status != .done else { return pitch }
        return pitch + CGFloat(row.subtasks.count + 2) * AtticLayout.subtaskPitch + AtticQuickLookMetrics.bottomPadding
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
        // The lists take the new room on the next turn: the keystroke that
        // shows the strip draws at once, and the lists' margins (500 rows
        // re-laid out) follow while the strip fades in.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            DispatchQueue.main.async { if bottomControlsHeight != height { bottomControlsHeight = height } }
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
                    added: { id in revealRequest = TasksPageModel.ScrollRequest(id: id) })
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
        let tags = model.library.tags.counts().prefix(12).map(\.name)
        // Moving off the page ends the selection (computer-use bug 5):
        // Later and Now go through the moves, which clear it and confirm
        // with an Undo toast.
        // A failure shows under the first selected row, with Retry.
        let run: (@escaping () -> CommandOutcome) -> Void = { command in
            guard let first = ids.first else { return }
            model.report(command(), on: first, retry: command)
        }
        let move: (TaskStatus) -> Void = { status in
            if status == .backlog, model.tab != .backlog { run { model.moveToBacklog(ids) } }
            else if status == .todo, model.tab == .backlog { run { model.moveToNow(ids) } }
            else { run { model.setStatus(status, for: ids) } }
        }
        // Each button says what it does and to how many (tooltip and
        // VoiceOver, review UX 4).
        return AtticSelectionBar(count: count, actions: [
            .init(systemName: "checkmark.circle", label: "Set state of \(count) tasks", handler: {}, menu: [TaskStatus.todo, .inProgress, .done, .backlog].map { status in
                AtticMenuCommand(status.menuLocalization) { move(status) }
            }),
            .init(systemName: "exclamationmark", label: "Set priority of \(count) tasks", handler: {}, menu: TaskPriority.allCases.reversed().map { priority in
                AtticMenuCommand(priority.menuLocalization) { run { model.setPriority(priority, for: ids) } }
            }),
            .init(systemName: "number", label: "Tag \(count) tasks", handler: {}, menu: tags.isEmpty
                ? [AtticMenuCommand("No tags yet: type #tag in a title", isDisabled: true) {}]
                : tags.map { tag in
                    // Ticked when every selected task has it (a click removes
                    // it from all), a dash when some do (a click adds it).
                    let state = model.tagState(tag, for: ids)
                    return AtticMenuCommand("#\(tag)", systemImage: state == .on ? "checkmark" : (state == .mixed ? "minus" : nil)) {
                        run { model.toggleTag(tag, for: ids) }
                    }
                }),
            model.tab == .backlog
                ? .init(systemName: "tray.and.arrow.up", label: "Move \(count) tasks to Now", handler: { run { model.moveToNow(ids) } })
                : .init(systemName: "tray.and.arrow.down", label: "Move \(count) tasks to Later", handler: { run { model.moveToBacklog(ids) } }),
            .init(systemName: "trash", label: "Delete \(count) tasks", handler: { deleteAndMoveFocus(ids) })
        ])
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
    @State private var priorityPresented = false

    private var hasDraft: Bool { !text.text.text.trimmingCharacters(in: .whitespaces).isEmpty }

    private var suggestion: TaskAddBarText.Suggestion? {
        guard isFocused, let suggestion = text.text.suggestion(parser: model.parser, caret: text.caret, tags: model.cachedTags),
              suggestion.range != text.hiddenSuggestion else { return nil }
        return suggestion
    }

    var body: some View {
        let suggestion = suggestion
        let stripShown = showsStrip && (hasDraft || datePresented || priorityPresented)
        VStack(alignment: .leading, spacing: AtticPickerMetrics.stripToBar) {
                AtticComposerStrip(
                    datePresented: $datePresented,
                    priorityPresented: $priorityPresented,
                    onTag: { model.startTag(editor: editor) },
                    datePicker: {
                        TaskDatePickerView(choices: model.dateChoices, selected: currentDay, onPick: { day in
                            datePresented = false
                            model.pickDate(day, editor: editor)
                            editor.focus()
                        })
                    },
                    priorityPicker: {
                        TaskPriorityPickerView(current: currentPriority, onPick: { priority in
                            priorityPresented = false
                            model.pickPriority(priority, editor: editor)
                            editor.focus()
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
                .allowsHitTesting(stripShown)
                .accessibilityHidden(!stripShown)
                .padding(.bottom, stripShown ? 0 : -AtticPickerMetrics.stripToBar)
            AtticAddBar(
                placeholder: model.addPlaceholder,
                text: $text.text.text,
                tokens: AtticAddBar.Tokens(
                    chips: text.text.chips(parser: model.parser, caret: text.caret),
                    isFocused: $isFocused,
                    actions: AtticTokenFieldActions(
                        submit: { command in submit(openingPage: command) },
                        dismissChip: { range in
                            // Turning a chip into text is a step of its own:
                            // ⌘Z makes it a chip again (round 4).
                            text.history.checkpoint(text.text, caret: text.caret)
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
                        undoFallback: { model.undo() },
                        redoFallback: { model.redo() },
                        edited: { range, replacement in
                            text.history.willEdit(text.text, caret: text.caret, range: range, replacement: replacement)
                            text.text.edited(range, replacement: replacement)
                            text.hiddenSuggestion = nil
                            text.highlighted = 0
                        },
                        caretMoved: { caret in
                            if text.caret != caret { text.caret = caret }
                            // Assign only a change: every assignment redraws the bar.
                            var shown = text.text
                            if shown.markShown(parser: model.parser, caret: caret) { text.text = shown }
                        },
                        suggestionKey: { key in suggestionKey(key) },
                        undoDraft: { text.undoDraft() },
                        redoDraft: { text.redoDraft() }
                    ),
                    editor: editor
                ),
                onSubmit: { submit(openingPage: false) }
            )
        }
        // Over the strip and the bar, never pushing them (review 14).
        .overlay(alignment: .topLeading) {
            if let suggestion {
                AtticSuggestionList(items: items(for: suggestion), highlighted: min(text.highlighted, suggestion.count - 1)) { index in
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
        .onChange(of: datePresented || priorityPresented) { _, open in
            pickerOpen = open
            // A closed picker hands the keyboard back to the draft, where
            // its insertion point was (review 14).
            if !open { editor.focus() }
        }
    }

    private var currentDay: DueDay? {
        if case let .dueDay(day)? = text.text.activeTokens(parser: model.parser).first(where: { TaskAddBarText.PieceKind.date.matches($0.value) })?.value {
            return day
        }
        return nil
    }

    private var currentPriority: TaskPriority? {
        text.text.parts(parser: model.parser).priority
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
    /// The circle column's right edge in the page: a press left of it is
    /// the circle's.
    let circleEdge: CGFloat
    let heights: (UUID) -> CGFloat
    let onEnd: (TasksDrag) -> Void
    let onPushPastGroup: () -> Void
    @ViewBuilder let row: (TasksCellLive) -> Row
    @ViewBuilder let below: () -> Below

    @Environment(\.atticDesign) private var design
    @GestureState private var translation: CGFloat?
    /// This press was cancelled from outside (Esc, a hide, a page change):
    /// it moves nothing more until the button comes up.
    @State private var cancelled = false
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
                .simultaneousGesture(gesture, including: enabled ? .all : .subviews)
            below()
        }
        .modifier(AtticReorderLiftModifier(lifted: lifted))
        .offset(y: lifted ? (translation ?? 0) : offset)
        .zIndex(lifted ? 1 : 0)
        .animation(lifted || design.reduceMotion ? nil : AtticMotionPreset.settle.animation(reduceMotion: false), value: offset)
        .onChange(of: translation == nil) { _, ended in
            guard ended else { return }
            // Cancelled or ended: the lift goes either way (an ended drag
            // was committed by `onEnded` already).
            cancelled = false
            pushedPast = false
            if drag?.id == id { drag = nil }
        }
        .onChange(of: drag) { old, new in
            if old?.id == id, new == nil, translation != nil { cancelled = true }
        }
    }

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: TasksPage.space)
            .updating($translation) { value, state, _ in
                guard value.startLocation.x > circleEdge else { return }
                state = value.translation.height
            }
            .onChanged { value in
                guard !cancelled, value.startLocation.x > circleEdge, let start = group.firstIndex(of: id) else { return }
                let target = Self.target(start: start, translation: value.translation.height, group: group, heights: heights)
                if drag?.id != id {
                    drag = TasksDrag(id: id, tab: tab, group: group, startIndex: start, targetIndex: target)
                } else if drag?.targetIndex != target {
                    drag?.targetIndex = target
                }
                // Pushing past the group's end: say why it stops there.
                let past = Self.pushesPastGroup(start: start, translation: value.translation.height, group: group, heights: heights)
                if past, !pushedPast { onPushPastGroup() }
                if past != pushedPast { pushedPast = past }
            }
            .onEnded { value in
                guard !cancelled, value.startLocation.x > circleEdge, let start = group.firstIndex(of: id) else { return }
                let target = Self.target(start: start, translation: value.translation.height, group: group, heights: heights)
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
    }

    var invocation: Invocation?

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
    func press(_ event: NSEvent, below minY: CGFloat, select: (UUID) -> [UUID]) {
        guard MenuPress(type: event.type, modifiers: event.modifierFlags) != .none,
              let point = location(of: event), point.y >= minY, let id = row(at: point) else {
            invocation = nil
            return
        }
        invocation = Invocation(row: id, targets: select(id))
    }

    /// The event's location in the page, or nil when it is another
    /// window's event or outside the page.
    func location(of event: NSEvent) -> CGPoint? {
        guard let view, let window = view.window, event.window === window else { return nil }
        let point = view.convert(event.locationInWindow, from: nil)
        return view.bounds.contains(point) ? point : nil
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

/// The list viewport's geometry (owner fix 8, review 9), pure so the
/// clearance and the fade are tested directly.
enum TasksViewport {
    /// Where the first row rests: the tabs, then 14.
    static func listTop(tabsTop: CGFloat) -> CGFloat {
        tabsTop + AtticLayout.pageTabsHeight + AtticLayout.pageTabsToList
    }

    /// The room kept at the bottom: the measured bottom stack, its margin,
    /// and the 16 pt the list keeps from the bar.
    static func bottomClearance(stackHeight: CGFloat, bottomInset: CGFloat) -> CGFloat {
        max(stackHeight, AtticControlSize.addBarHeight) + bottomInset + AtticLayout.contentToAddBar
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
