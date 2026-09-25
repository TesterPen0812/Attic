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

/// The Tasks page (spec § Tasks, v9): one title (Tasks, Backlog or Done),
/// one list sorted by state with status circles, the row quick look, the
/// selection bar, the page pill and the add bar that follows the page.
/// Built only from the design system. Swiping between Tasks, Backlog and
/// Done follows the trackpad 1:1 (a paging scroll view, the title moving
/// with its list), and the list stays lazy.
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
    /// The bottom stack's height: the add bar, plus the selection bar, a
    /// paste offer or an error line while they show.
    @State private var bottomControlsHeight: CGFloat = AtticControlSize.addBarHeight

    static let space = NamedCoordinateSpace.named("AtticTasksPage")

    /// The title's line box: 16 below the header, which moves inward with
    /// larger corners, so the gap under the header stays the same.
    private var titleTop: CGFloat { layout.headerBottom + AtticLayout.pageTitleTop }

    /// Room under the list for the add bar and its margins.
    static let footerZone: CGFloat = AtticControlSize.addBarHeight + AtticSpacing.panelMargin * 2
    private var footerZone: CGFloat { Self.footerZone }
    /// The list also clears the page pill above the add bar.
    static let listFooter: CGFloat = footerZone + AtticPagePillMetrics.collapsedHeight + AtticPagePillMetrics.toAddBar

    var body: some View {
        ZStack(alignment: .bottom) {
            pager
            bottomControls
        }
        .coordinateSpace(Self.space)
        .background(TasksWindowReveal(action: { model.resetForReveal() }, hidden: { model.pageDidHide() })
            .frame(width: 0, height: 0).accessibilityHidden(true))
        .atticKeyboardFocusTracking(focusTracker)
        .onKeyPress(phases: .down) { press in pageKey(press) }
        .onAppear {
            model.resetForReveal()
            chrome.bottomControlsHeight(footerZone)
        }

        .onChange(of: addBarFocused) { _, focused in chrome.typingLock(focused || model.editingTitleID != nil) }
        .onChange(of: model.editingTitleID) { _, id in chrome.typingLock(addBarFocused || id != nil) }
        // The shell's toast and notices sit above everything in the bottom
        // stack, so a selection bar or paste offer never hides under them.
        .preference(key: PanelPageNoticeClearancePreferenceKey.self,
                    value: footerZone + max(0, bottomControlsHeight - AtticControlSize.addBarHeight))

    }

    // MARK: - Title and page pill

    /// The page's one title. It belongs to its page, so a swipe carries it
    /// with the list.
    private func title(_ tab: TasksTab) -> some View {
        AtticText(verbatim: tab.pageTitle, style: .pageHeading, ink: .heading)
            .frame(height: AtticLayout.pageTitleHeight)
            .padding(.leading, AtticLayout.circleX)
            .padding(.top, titleTop)
            .padding(.bottom, AtticLayout.pageTitleToList)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("tasks-page-title")
    }

    private var pagePill: some View {
        AtticPagePill(
            items: TasksTab.allCases.map { tab in
                AtticPagePill.Item(page: tab, title: tab.pageTitle, icon: tab.pillIcon,
                                   accessibilityIdentifier: "tasks-page-\(tab.identifier)")
            },
            selection: Binding(get: { model.tab }, set: { model.select(tab: $0) })
        )
        .accessibilityIdentifier("tasks-page-pill")
    }

    // MARK: - Pages

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(TasksTab.allCases) { tab in
                    page(tab)
                        .containerRelativeFrame(.horizontal)
                        .id(tab)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: Binding(get: { Optional(model.tab) }, set: { if let tab = $0 { model.select(tab: tab) } }))
        .scrollIndicators(.never)
        .scrollDisabled(drag != nil)
        .scrollEdgeEffectHidden(true, for: .all)
    }

    private func page(_ tab: TasksTab) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            title(tab)
            switch tab {
            case .now, .backlog:
                listPage(tab)
            case .done:
                TasksDonePage(model: model, store: store, footerZone: Self.listFooter, cell: { row in cell(row, tab: .done, group: []) })
            }
        }
    }

    private func listSpace(_ tab: TasksTab) -> NamedCoordinateSpace {
        .named("AtticTasksList\(tab.rawValue)")
    }

    private func listPage(_ tab: TasksTab) -> some View {
        let rows = model.rows(for: tab)
        let groups = Dictionary(grouping: rows, by: \.status).mapValues { $0.map(\.id) }
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        cell(row, tab: tab, group: groups[row.status] ?? [])
                            .id(row.id)
                    }
                    if rows.isEmpty {
                        AtticEmptyLine(text: tab == .now
                            ? String(localized: "Nothing here yet. Add a task below.")
                            : String(localized: "Nothing in the backlog. Park ideas here for later."))
                    } else if tab == .now, model.hasDoneToday {
                        AtticEmptyLine(text: String(localized: "Done tasks move to Done tomorrow"), isFootnote: true)
                            .modifier(AtticScrollEdgeFade(space: listSpace(tab), top: Self.listTopFade, bottom: AtticEdgeBlur.panelBottom))
                    }
                }
                .animation(AtticMotionPreset.settle.animation(reduceMotion: design.reduceMotion), value: rows.map(\.id))
            }
            .contentMargins(.bottom, Self.listFooter, for: .scrollContent)
            .scrollIndicators(.automatic)
            .scrollEdgeEffectHidden(true, for: .all)
            .coordinateSpace(listSpace(tab))
            .onChange(of: focusedRow) { _, id in
                guard let id, rows.contains(where: { $0.id == id }), focusTracker.isKeyboardDriving else { return }
                withAnimation(AtticMotionPreset.settle.animation(reduceMotion: design.reduceMotion)) { proxy.scrollTo(id) }
            }
            // An agent's `show`: the row comes into view.
            .onChange(of: model.scrollRequest) { _, request in
                guard let request, rows.contains(where: { $0.id == request.id }) else { return }
                withAnimation(AtticMotionPreset.settle.animation(reduceMotion: design.reduceMotion)) {
                    proxy.scrollTo(request.id, anchor: .center)
                }
            }
        }
    }

    /// Rows fade as they pass under the switch.
    static let listTopFade: CGFloat = 16

    // MARK: - Row

    @ViewBuilder
    private func cell(_ row: TasksListRow, tab: TasksTab, group: [UUID]) -> some View {
        let id = row.id
        let expanded = model.expanded.contains(id) && row.status != .done
        let space = tab == .done ? NamedCoordinateSpace.named("AtticTasksDone") : listSpace(tab)
        VStack(alignment: .leading, spacing: 0) {
            AtticTaskRow(
                model: row.model,
                isSelected: model.selection.contains(id),
                selectionRun: selectionRun(for: id, in: tab),
                isExpanded: expanded,
                dropLabel: fileDropRow == id ? String(localized: "Add to page") : nil,
                actions: actions(for: id),
                onToggleExpanded: { model.toggleExpanded(id) },
                onSelect: { rowClicked(id, tab: tab) },
                focus: AtticRowFocus(binding: $focusedRow, id: id),
                titleEditing: model.editingTitleID == id
                    ? AtticTitleEditing(text: $model.editingTitle,
                                        commit: {
                                            let saved = model.commitTitle()
                                            if saved { focusedRow = id }
                                            return saved
                                        },
                                        cancel: { model.cancelEditing(); focusedRow = id })
                    : nil
            )
            .contextMenu { rowMenu(row, tab: tab) }
            // A Done log task's details open under its row (Esc or the
            // menu closes them), raised over the list like a pop-over.
            if model.doneDetailID == id, let detail = model.doneDetail(for: id) {
                TasksDoneDetailView(detail: detail, store: store, restore: {
                    model.doneDetailID = nil
                    model.restoreToNow(id)
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
            if expanded {
                AtticQuickLook(
                    subtasks: row.subtasks,
                    onToggle: { model.toggleSubtask($0.id) },
                    onAddSubtask: { model.beginAddingSubtask(to: id) },
                    onOpenPage: { model.openPage(id) },
                    newSubtask: model.newSubtaskParentID == id
                        ? AtticTitleEditing(text: $model.newSubtaskTitle, commit: { model.commitNewSubtask() },
                                            cancel: { model.cancelEditing() })
                        : nil
                )
                .transition(.opacity)
                if model.failedSave == .newSubtask(id) {
                    AtticErrorLine(message: String(localized: "Not saved"), onRetry: { _ = model.commitNewSubtask() })
                        .padding(.leading, AtticLayout.textX)
                }
            }
        }
        .modifier(AtticScrollEdgeFade(space: space, top: Self.listTopFade, bottom: AtticEdgeBlur.panelBottom))
        .modifier(TasksDragModifier(
            id: id, tab: tab, group: group, drag: $drag, enabled: tab != .done && model.editingTitleID == nil,
            offset: dragOffset(for: id), heights: { rowHeight($0, in: tab) },
            // The tabs a row could be dropped on went with v9's one title;
            // ⌘B and the menu still move a task between Tasks and Backlog.
            overTab: { _ in nil },
            onTarget: { model.dropTargetTab = $0 },
            onEnd: finishDrag
        ))
        .onDrop(of: TaskDropContent.dropTypes, delegate: TaskFileDropDelegate(
            canAccept: { content in content == .files && tab != .done && store.attachmentOwnerID(for: id) != nil },
            setTargeted: { targeted in fileDropRow = targeted ? id : (fileDropRow == id ? nil : fileDropRow) },
            perform: { content, providers in attachDroppedFiles(content, providers, to: id) }
        ))
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

    private func actions(for id: UUID) -> AtticTaskActions {
        AtticTaskActions(
            advance: {
                // Option-click on the circle completes (spec § The status
                // circle); a plain click, or Space, advances.
                if let event = NSApp.currentEvent, [.leftMouseUp, .leftMouseDown].contains(event.type),
                   event.modifierFlags.contains(.option) {
                    model.complete(id)
                } else {
                    model.advance(id)
                }
            },
            start: { model.setStatus(.inProgress, for: [id]) },
            complete: { model.targets(for: id).forEach(model.complete) },
            openPage: { model.openPage(id) },
            moveToBacklog: {
                let targets = model.targets(for: id)
                if model.tab == .backlog { model.moveToNow(targets) } else { model.moveToBacklog(targets) }
            },
            delete: { deleteAndMoveFocus(model.targets(for: id)) }
        )
    }

    private func deleteAndMoveFocus(_ ids: [UUID]) {
        let visible = visibleIDs()
        let next = visible.first { !ids.contains($0) && (visible.firstIndex(of: $0) ?? 0) > (ids.compactMap { visible.firstIndex(of: $0) }.max() ?? 0) }
            ?? visible.last { !ids.contains($0) }
        model.delete(ids)
        focusedRow = next
        if let next { model.selectOnly(next) }
    }

    // MARK: - Right-click menu

    @ViewBuilder
    private func rowMenu(_ row: TasksListRow, tab: TasksTab) -> some View {
        let targets = model.targets(for: row.id)
        let single = targets.count == 1
        if tab == .done {
            Button(String(localized: "Restore to Now")) { targets.forEach(model.restoreToNow) }
            if single {
                Button(model.doneDetailID == row.id ? String(localized: "Close Details") : String(localized: "Open Page")) {
                    if model.doneDetailID == row.id { model.doneDetailID = nil } else { model.openPage(row.id) }
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        } else {
            Section {
                ForEach([TaskStatus.todo, .inProgress, .done, .backlog], id: \.self) { status in
                    Button {
                        model.setStatus(status, for: targets)
                    } label: {
                        if single, row.status == status {
                            Label(status.menuTitle, systemImage: "checkmark")
                        } else {
                            Text(status.menuTitle)
                        }
                    }
                }
            }
            Menu(String(localized: "Priority")) {
                ForEach(TaskPriority.allCases.reversed(), id: \.self) { priority in
                    Button {
                        model.setPriority(priority, for: targets)
                    } label: {
                        if single, store.task(withID: row.id)?.priority == priority {
                            Label(priority.menuTitle, systemImage: "checkmark")
                        } else {
                            Text(priority.menuTitle)
                        }
                    }
                }
            }
            Divider()
            if tab == .backlog {
                Button(String(localized: "Move to Now")) { model.moveToNow(targets) }
                    .keyboardShortcut("b", modifiers: .command)
            } else {
                Button(String(localized: "Move to Backlog")) { model.moveToBacklog(targets) }
                    .keyboardShortcut("b", modifiers: .command)
            }
            if single {
                Button(String(localized: "Edit Title")) { model.selectOnly(row.id); model.beginEditingTitle(row.id) }
                    .keyboardShortcut(.return, modifiers: [])
                if row.status != .done {
                    Button(String(localized: "Add Subtask")) { model.beginAddingSubtask(to: row.id) }
                }
                Button(String(localized: "Open Page")) { model.openPage(row.id) }
                    .keyboardShortcut(.return, modifiers: .command)
            }
            Divider()
            Button(role: .destructive) {
                deleteAndMoveFocus(targets)
            } label: {
                Text(single ? String(localized: "Delete") : String(localized: "Delete \(targets.count) Tasks"))
            }
            .keyboardShortcut(.delete, modifiers: [])
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
            if modifiers == .command { model.undo(); return .handled }
            if modifiers == [.command, .shift] { model.redo(); return .handled }
        }
        guard model.editingTitleID == nil, model.newSubtaskParentID == nil, !addBarFocused else { return .ignored }
        let visible = visibleIDs()
        let current = focusedRow.flatMap { visible.contains($0) ? $0 : nil }
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
                model.moveBy(current, offset: step)
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
            if model.doneDetailID != nil { model.doneDetailID = nil; return .handled }
            if let current, model.expanded.contains(current) { model.setExpanded(current, false); return .handled }
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

    private func dragOffset(for id: UUID) -> CGFloat {
        guard let drag else { return 0 }
        if drag.id == id { return drag.translation }
        guard let index = drag.group.firstIndex(of: id) else { return 0 }
        let height = rowHeight(drag.id, in: drag.tab)
        if drag.startIndex < drag.targetIndex, index > drag.startIndex, index <= drag.targetIndex { return -height }
        if drag.targetIndex < drag.startIndex, index >= drag.targetIndex, index < drag.startIndex { return height }
        return 0
    }

    /// A row's height, from what it shows (no measuring, so scrolling never
    /// writes view state): 32 pt, 44 with a details line, plus the quick
    /// look's lines when it is open.
    private func rowHeight(_ id: UUID, in tab: TasksTab) -> CGFloat {
        guard let row = model.rows(for: tab).first(where: { $0.id == id }) else { return AtticLayout.rowPitch }
        let pitch = row.model.hasDetails ? AtticLayout.detailRowPitch : AtticLayout.rowPitch
        guard model.expanded.contains(id), row.status != .done else { return pitch }
        return pitch + CGFloat(row.subtasks.count + 2) * AtticLayout.subtaskPitch + AtticQuickLookMetrics.bottomPadding
    }

    private func finishDrag(_ finished: TasksDrag) {
        let reduceMotion = design.reduceMotion
        model.dropTargetTab = nil
        if let tab = finished.overTab {
            drag = nil
            AtticHaptics.tick(enabled: design.hapticsEnabled)
            if tab == .backlog { model.moveToBacklog([finished.id]) } else { model.moveToNow([finished.id]) }
            return
        }
        withAnimation(AtticMotionPreset.settle.animation(reduceMotion: reduceMotion)) {
            if finished.targetIndex != finished.startIndex {
                model.move(finished.id, toGroupIndex: finished.targetIndex)
                AtticHaptics.tick(enabled: design.hapticsEnabled)
            }
            drag = nil
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
        VStack(spacing: AtticSpacing.s8) {
            pagePill
                .padding(.bottom, AtticPagePillMetrics.toAddBar - AtticSpacing.s8)
            if model.failedSave == .paste {
                AtticErrorLine(message: String(localized: "Not saved"), onRetry: { model.retryPaste() })
            }
            if let offer = model.pasteOffer {
                pasteOfferBar(offer)
                    .transition(AtticMotionPreset.popover.transition(reduceMotion: design.reduceMotion))
            } else if model.selection.count > 1, model.tab != .done {
                selectionBar
                    .transition(AtticMotionPreset.popover.transition(reduceMotion: design.reduceMotion))
            }
            addBar
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomControlsHeight = $0 }
        .padding(.horizontal, max(AtticSpacing.panelMargin, layout.chromeInsets.leading))
        .padding(.bottom, max(AtticSpacing.panelMargin, layout.chromeInsets.bottom))
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion), value: model.selection.count > 1)
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion), value: model.pasteOffer)
    }

    @ViewBuilder
    private var addBar: some View {
        if model.tab == .done {
            // The Done log's search: the same native field (no chips), so
            // Search from the menu bar can put the keyboard in it and Esc
            // leaves it like the add bar.
            AtticAddBar(
                placeholder: model.addPlaceholder, text: $model.doneSearch, systemImage: "magnifyingglass",
                showsSend: false,
                tokens: AtticAddBar.Tokens(
                    chips: [],
                    isFocused: $addBarFocused,
                    actions: AtticTokenFieldActions(
                        submit: { _ in },
                        dismissChip: { _ in },
                        multilinePaste: { _ in false },
                        escape: { leaveAddBar() },
                        undoFallback: { model.undo() },
                        redoFallback: { model.redo() },
                        edited: { _, _ in },
                        caretMoved: { _ in }
                    )
                ),
                onSubmit: {}
            )
        } else {
            TasksAddBar(model: model, text: model.addBarState, isFocused: $addBarFocused, leave: leaveAddBar)
        }
    }

    /// Esc in the add bar (or the Done search) with nothing of its own to
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
        let tags = model.library.tags.counts().prefix(12).map(\.name)
        return AtticSelectionBar(count: ids.count, actions: [
            .init(systemName: "checkmark.circle", label: "State", handler: {}, menu: [TaskStatus.todo, .inProgress, .done, .backlog].map { status in
                AtticMenuCommand(status.menuLocalization) { model.setStatus(status, for: ids) }
            }),
            .init(systemName: "exclamationmark", label: "Priority", handler: {}, menu: TaskPriority.allCases.reversed().map { priority in
                AtticMenuCommand(priority.menuLocalization) { model.setPriority(priority, for: ids) }
            }),
            .init(systemName: "number", label: "Tag", handler: {}, menu: tags.isEmpty
                ? [AtticMenuCommand("No tags yet: type #tag in a title", isDisabled: true) {}]
                : tags.map { tag in AtticMenuCommand("#\(tag)") { model.addTag(tag, to: ids) } }),
            model.tab == .backlog
                ? .init(systemName: "tray.and.arrow.up", label: "Move to Now", handler: { model.moveToNow(ids) })
                : .init(systemName: "tray.and.arrow.down", label: "Move to Backlog", handler: { model.moveToBacklog(ids) }),
            .init(systemName: "trash", label: "Delete", handler: { deleteAndMoveFocus(ids) })
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
/// the list above it (spec: one frame per keystroke).
private struct TasksAddBar: View {
    @ObservedObject var model: TasksPageModel
    @ObservedObject var text: TasksAddBarState
    @Binding var isFocused: Bool
    let leave: () -> Bool

    var body: some View {
        AtticAddBar(
            placeholder: model.addPlaceholder,
            text: $text.text.text,
            tokens: AtticAddBar.Tokens(
                chips: text.text.chips(parser: model.parser, caret: text.caret),
                isFocused: $isFocused,
                actions: AtticTokenFieldActions(
                    submit: { command in model.submitAddBar(openingPage: command) },
                    dismissChip: { text.text.dismiss($0) },
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
                    edited: { range, replacement in text.text.edited(range, replacement: replacement) },
                    caretMoved: { text.caret = $0 }
                )
            ),
            onSubmit: { model.submitAddBar() }
        )
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
        case .backlog: "Backlog"
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
/// others slide apart), or onto the Now / Backlog label.
struct TasksDrag: Equatable {
    let id: UUID
    let tab: TasksTab
    let group: [UUID]
    let startIndex: Int
    var translation: CGFloat = 0
    var targetIndex: Int
    var overTab: TasksTab?
}

private struct TasksDragModifier: ViewModifier {
    let id: UUID
    let tab: TasksTab
    let group: [UUID]
    @Binding var drag: TasksDrag?
    let enabled: Bool
    let offset: CGFloat
    let heights: (UUID) -> CGFloat
    let overTab: (CGPoint) -> TasksTab?
    let onTarget: (TasksTab?) -> Void
    let onEnd: (TasksDrag) -> Void

    @Environment(\.atticDesign) private var design

    func body(content: Content) -> some View {
        let lifted = drag?.id == id
        Group {
            if lifted {
                AtticReorderLift { content }
            } else {
                content
            }
        }
        .offset(y: offset)
        .zIndex(lifted ? 1 : 0)
        .animation(lifted ? nil : AtticMotionPreset.settle.animation(reduceMotion: design.reduceMotion), value: offset)
        .gesture(
            DragGesture(minimumDistance: 5, coordinateSpace: TasksPage.space)
                .onChanged(changed)
                .onEnded { _ in
                    guard let finished = drag, finished.id == id else { return }
                    onEnd(finished)
                },
            including: enabled ? .all : .subviews
        )
    }

    private func changed(_ value: DragGesture.Value) {
        guard let start = group.firstIndex(of: id) else { return }
        var current = drag ?? TasksDrag(id: id, tab: tab, group: group, startIndex: start, targetIndex: start)
        guard current.id == id else { return }
        current.translation = value.translation.height
        current.overTab = overTab(value.location)
        current.targetIndex = Self.target(start: start, translation: current.translation, group: group, heights: heights)
        if current.overTab != drag?.overTab { onTarget(current.overTab) }
        drag = current
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
}
