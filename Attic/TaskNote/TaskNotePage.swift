import AppKit
import Combine
import SwiftUI
import os

@MainActor
struct TaskNoteWarmPresentation {
    let model: TaskNotePageModel
    let host: TaskNoteComposedHost
    let design: AtticDesignContext
    let draftGeneration: UInt64
    let viewGeneration: UInt64
}

/// One open task's note: the registry session and its lease, the page model
/// and the composed host. Made once per open; the engine and its text view
/// live as long as this does (stable editor identity, § 9.1).
@MainActor
final class TaskNotePresenter: ObservableObject {
    let taskID: UUID
    let model: TaskNotePageModel
    let host: TaskNoteComposedHost
    /// The workspace's own note session; nil for a task with no note yet
    /// (lazy creation is slice 1: the writing shows its placeholder).
    let session: NoteSession?
    private let page: WorkspacePageSession
    private(set) var lease: WorkspacePageSession.Lease?
    private let surfaceID = UUID()
    private var design: AtticDesignContext
    private weak var notes: NotesPageController?
    @Published private(set) var engineGeneration: UInt64 = 0
    /// The title riding in the header (0 hidden, 1 shown).
    @Published private(set) var headerTitleProgress: CGFloat = 0
    private var engineObservation: AnyCancellable?
    private var hasMounted = false
    private var closeWork: Task<Bool, Never>?
    var isClosing: Bool { closeWork != nil }
    /// Rings in the head and the block only while the keyboard drives.
    private static let focusTracker = AtticKeyboardFocusTracker()
    /// The page's menus, filled by the mounted page (the head is built once).
    let menus = TaskNoteMenuRelay()
    /// The task's own note is in Recently Deleted (§ 5.6): Restore Note.
    let deletedNoteID: UUID?
    /// Every open task page, panel or window (one per task: OD-1).
    private static var live: [UUID: WeakPresenter] = [:]
    private struct WeakPresenter { weak var presenter: TaskNotePresenter? }
    static func open(for taskID: UUID) -> TaskNotePresenter? {
        guard let presenter = live[taskID]?.presenter, presenter.lease != nil else { return nil }
        return presenter
    }

    enum OpenError: Error { case unavailable }

    init(taskID: UUID, tasks: TaskStore, library: AtticLibrary, notes: NotesPageController,
         design: AtticDesignContext, columnInset: CGFloat, defaults: UserDefaults? = .standard) throws {
        // The Notes page may never have been shown: its engines take the
        // panel's look before this session's engine is made (CU P1, Dark ink).
        notes.update(design: design)
        self.notes = notes
        let coordinator = try WorkspaceLegacyBridge.coordinator(for: tasks.container)
        let page = try coordinator.sessions.session(for: .task(taskID), notes: notes)
        lease = try page.acquire(surfaceID: surfaceID)
        self.page = page
        self.taskID = taskID
        self.design = design
        session = page.note
        deletedNoteID = page.note == nil ? coordinator.sessions.deletedOwnNoteID(taskID) : nil
        let cached = session?.taskNotePresentation
        session?.taskNotePresentation = nil
        let canReuse = cached.map { $0.model.taskID == taskID && $0.model.store === tasks
            && $0.model.library === library && $0.model.history === page.history
            && $0.host.engine === page.note?.engine } ?? false
        let model = canReuse ? cached!.model
            : TaskNotePageModel(taskID: taskID, store: tasks, library: library, history: page.history, defaults: defaults)
        self.model = model
        model.reduceMotion = design.reduceMotion
        let engine: NoteEditorEngine
        if let note = page.note {
            engine = note.engine
        } else {
            // A task with no note: nothing is created by opening it (§ 2.1).
            let blank = (try? NoteDocument.blank.taskSnapshot(title: model.head.title)) ?? .blank
            engine = NoteEditorEngine(noteID: UUID(), document: blank, readOnly: true, design: design, bodyOnly: true)
        }
        host = canReuse ? cached!.host : TaskNoteComposedHost(engine: engine,
                                    head: Self.headView(model, design: design, menus: menus),
                                    block: Self.blockView(model, design: design, menus: menus),
                                    columnInset: columnInset,
                                    blockHeight: { [weak model] in model?.blockHeight ?? TaskNoteMetrics.blockHeader })
        engine.setCompatibilityTitle(model.head.title)
        model.onGeometryChange = { [weak self] in
            guard let self else { return }
            self.host.engine.setCompatibilityTitle(self.model.head.title)
            self.host.setNeedsRestack()
        }
        model.onFocusWriting = { [weak self] atTop in self?.host.focusWriting(atTop: atTop) }
        host.onHeaderProgress = { [weak self] progress in self?.headerTitleProgress = progress }
        model.deletedNote = deletedNoteID != nil
        Self.live[taskID] = WeakPresenter(presenter: self)
        if canReuse {
            // New regions every time: their menus belong to this presenter.
            host.setRegions(head: Self.headView(model, design: design, menus: menus), block: Self.blockView(model, design: design, menus: menus))
            let canResumeViewport = cached?.draftGeneration == session?.callbackStamp.draft
                && cached?.viewGeneration == engine.viewGeneration
                && cached?.design == design && host.columnInset == columnInset && engine.textView == nil
            host.columnInset = columnInset
            model.resume()
            host.resume(reusingViewport: canResumeViewport)
            engine.setCompatibilityTitle(model.head.title)
        }
        engineObservation = session?.$engine.dropFirst().sink { [weak self] replacement in
            guard let self, self.lease != nil else { return }
            self.host.replaceEngine(replacement)
            replacement.setCompatibilityTitle(self.model.head.title)
            self.engineGeneration &+= 1
        }
    }

    private static func headView(_ model: TaskNotePageModel, design: AtticDesignContext, menus: TaskNoteMenuRelay) -> AnyView {
        return AnyView(TaskNoteHeadView(model: model, openNoteMenu: { menus.noteMenu() }, taskMenu: { menus.taskMenu() })
            .environment(\.atticDesign, design).atticKeyboardFocusTracking(focusTracker))
    }

    private static func blockView(_ model: TaskNotePageModel, design: AtticDesignContext, menus: TaskNoteMenuRelay) -> AnyView {
        return AnyView(TaskNoteSubtasksBlock(model: model, restoreNote: { menus.restoreNote() })
            .environment(\.atticDesign, design).atticKeyboardFocusTracking(focusTracker))
    }

    func update(design: AtticDesignContext) {
        guard lease != nil, design != self.design else { return }
        self.design = design
        notes?.update(design: design)
        host.engine.update(design: design)
        model.reduceMotion = design.reduceMotion
        host.setRegions(head: Self.headView(model, design: design, menus: menus), block: Self.blockView(model, design: design, menus: menus))
    }

    /// A section return remounts the same native page. Only a first open
    /// starts at the top; subsequent mounts keep the reading position.
    func restoreViewStateOnMount() {
        host.restack()
        if !hasMounted { host.scrollToTop(); hasMounted = true }
        if let session {
            let length = host.engine.textStorage.length
            let selection = session.selection
            host.textView.setSelectedRange(NSRange(location: min(selection.location, length),
                length: min(selection.length, max(0, length - selection.location))))
        }
    }

    /// Back: preserves durably first, then lets go of the lease. Refused
    /// (composition in progress, a save that has not landed) keeps the page.
    func close() async -> Bool {
        if let closeWork { return await closeWork.value }
        guard let lease else { return true }
        guard model.resolveFieldDrafts() else { return false }
        let work = Task { @MainActor in await self.finishClose(lease) }
        closeWork = work
        let closed = await work.value
        closeWork = nil
        return closed
    }

    private func finishClose(_ lease: WorkspacePageSession.Lease) async -> Bool {
        model.releaseHold()
        guard await page.close(lease, resolvingFields: { self.model.resolveFieldDrafts() }) else { return false }
        self.lease = nil
        engineObservation = nil
        model.suspend()
        host.invalidate()
        if let session {
            session.taskNotePresentation = .init(model: model, host: host, design: design,
                                                  draftGeneration: session.callbackStamp.draft,
                                                  viewGeneration: session.engine.viewGeneration)
        }
        if notes?.taskNotePresenter === self { notes?.taskNotePresenter = nil }
        return true
    }
}

extension TaskNoteComposedHost {
    /// New root views for the head and the block (a change of look). The
    /// hosting controllers and the text view stay.
    func setRegions(head: AnyView, block: AnyView) {
        headRootView = head
        blockRootView = block
        restack()
    }
}

/// The page's menus, filled by the mounted page. The head and the block are
/// native regions made once per presenter, so they call through this.
@MainActor
final class TaskNoteMenuRelay {
    var noteMenu: () -> Void = {}
    var taskMenu: () -> [AtticMenuCommand] = { [] }
    var restoreNote: () -> Void = {}
}

/// Where a task's page lives (OD-1: one place at a time).
enum TaskNotePlacement: Equatable {
    case panel
    /// Its own window: Back becomes Move to Panel.
    case window
}

/// The task's note over its origin (§ 5.4): the composed scroll, then the
/// bottom row with Back (bottom-left, its destination in the tooltip, VO and
/// menus), the Notes status slot and Aa.
struct TaskNotePage: View {
    @ObservedObject var presenter: TaskNotePresenter
    @ObservedObject var model: TaskNotePageModel
    @ObservedObject var controller: NotesPageController
    @ObservedObject var noteStore: NoteStore
    let layout: PanelPageLayout
    var backTitle = String(localized: "Back to Notes")
    var placement: TaskNotePlacement = .panel
    var onOpenInWindow: (() -> Void)?
    /// The page reopens on the same task (after Delete Note… or Restore Note).
    var onReopen: () -> Void = {}
    let onBack: () -> Void

    @Environment(\.atticDesign) private var design
    @StateObject private var chrome = NotesPageChrome()
    @StateObject private var damaged: NoteDamagedRecoveryExit
    @State private var confirming: Confirmation?

    enum Confirmation: Identifiable {
        case deleteTask, deleteNote
        var id: Self { self }
    }

    init(presenter: TaskNotePresenter, controller: NotesPageController, noteStore: NoteStore,
         layout: PanelPageLayout, backTitle: String = String(localized: "Back to Notes"),
         placement: TaskNotePlacement = .panel, onOpenInWindow: (() -> Void)? = nil,
         onReopen: @escaping () -> Void = {}, onBack: @escaping () -> Void) {
        self.presenter = presenter
        self.model = presenter.model
        self.controller = controller
        self.noteStore = noteStore
        self.layout = layout
        self.backTitle = backTitle
        self.placement = placement
        self.onOpenInWindow = onOpenInWindow
        self.onReopen = onReopen
        self.onBack = onBack
        _damaged = StateObject(wrappedValue: NoteDamagedRecoveryExit(perform: { [controller] command in
            await controller.perform(command)
        }))
    }

    private var buttonHeight: CGFloat { AtticControlSize.panelButton.height }
    private var columnInset: CGFloat { layout.chromeInsets.leading + AtticNoteMetrics.columnInset }
    private var topInset: CGFloat { layout.headerBottom + AtticNoteMetrics.titleTopGap }
    private var bottomInset: CGFloat { layout.chromeInsets.bottom + buttonHeight + AtticSpacing.s12 }
    private var bottomControls: CGFloat { layout.chromeInsets.bottom + buttonHeight }
    private var leaveTitle: String { placement == .window ? String(localized: "Move to Panel") : backTitle }

    var body: some View {
        ZStack(alignment: .bottom) {
            TaskNoteHostRepresentable(presenter: presenter, chrome: chrome, columnInset: columnInset,
                                      topInset: topInset, bottomInset: bottomInset, design: design,
                                      engineGeneration: presenter.engineGeneration, onEscape: onBack)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("task-note-page")
            // Content shows under the floating controls, blurred (owner,
            // 2026-10-17): the Notes page's own variable blur.
            AtticEdgeBlurBackdrops(AtticFloatingEdges(top: layout.headerBottom, bottom: bottomControls))
            if placement == .panel { headerTitle }
            bottomRow
                .padding(.leading, layout.chromeInsets.leading)
                .padding(.trailing, layout.chromeInsets.trailing)
                .padding(.bottom, layout.chromeInsets.bottom)
        }
        .onChange(of: design) { _, newValue in presenter.update(design: newValue) }
        .onChange(of: chrome.formatRow.isOpen) { _, open in
            chrome.controls?.isFormatBarOpen = open
            if !open {
                DispatchQueue.main.async {
                    guard presenter.lease != nil else { return }
                    presenter.host.focusWriting(atTop: false)
                }
            }
        }
        .onAppear(perform: installMenus)
        // Esc from the head or the block goes Back (§ 7: after inner layers).
        .onKeyPress(.escape) {
            guard !model.isEditingTitle, model.renamingID == nil else { return .ignored }
            onBack()
            return .handled
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { kind in
            switch kind {
            case .deleteTask:
                Button(String(localized: "Delete Task"), role: .destructive) { model.deleteTask() }
            case .deleteNote:
                Button(String(localized: "Delete Note"), role: .destructive) { deleteNote() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { kind in
            Text(verbatim: confirmationMessage(kind))
        }
        .accessibilityElement(children: .contain)
    }

    /// `p3-21` panel 3: the task's title rides in the header once the head
    /// has scrolled away; it opens the note's menu, as the Notes header
    /// title does (today's control).
    private var headerTitle: some View {
        let progress = presenter.headerTitleProgress
        return AtticHeaderTitleRoom(chromeInset: layout.chromeInsets.leading, switcherWidth: PanelHeaderLayout.pageSwitchWidth) {
            AtticHeaderTitle(title: model.head.title) { presentNoteMenu() }
                .opacity(progress)
                .offset(y: design.reduceMotion ? 0 : (1 - progress) * -6)
                .scaleEffect(design.reduceMotion ? 1 : 0.94 + 0.06 * progress, anchor: .top)
                .allowsHitTesting(progress > 0.5)
                .accessibilityHidden(progress < 0.5)
                .accessibilityIdentifier("task-note-header-title")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, layout.chromeInsets.top)
    }

    private var bottomRow: some View {
        AtticControlGroup {
            NoteFormatRowSwitch(state: chrome.formatRow, model: { [weak chrome] in chrome?.controls?.formatModel }) {
            HStack(spacing: 0) {
                AtticRaisedButton(systemName: placement == .window ? "rectangle.portrait.and.arrow.right" : "chevron.left",
                                  label: placement == .window ? "Move to Panel" : "Back",
                                  help: leaveTitle + "  (Esc)") {
                    onBack()
                }
                .accessibilityLabel(leaveTitle)
                .accessibilityIdentifier("task-note-back")
                Spacer(minLength: AtticSpacing.s12)
                if let session = presenter.session {
                    NoteStatusSlot(controller: controller, store: noteStore, session: session, damaged: damaged,
                                   maxWidth: AtticNoteMetrics.pillMaxWidth(panelWidth: layout.panelSize.width, chromeInset: layout.chromeInsets.leading, showsFormat: true), leadingItems: taskItems)
                        .transition(.opacity)
                } else if let item = taskItems.first {
                    // A task with no note: its command failures still show,
                    // in the same pill, without creating a note (review P2-6).
                    AtticStatusPill(item: item, inlineAction: item.actions.first) {}
                        .transition(.opacity)
                }
                Spacer(minLength: AtticSpacing.s12)
                if presenter.session?.isReadOnly == false {
                    AtticRaisedButton(systemName: "textformat", label: "Format", help: String(localized: "Format (⌘T)")) {
                        chrome.openFormatBar(keyboard: false)
                    }
                    .accessibilityIdentifier("task-note-format")

                }
            }
            .frame(height: buttonHeight)
            }
        }
    }

    /// A task command that changed nothing (§ 5.6), quietly in the slot.
    private var taskItems: [AtticStatusItem] {
        guard let failure = model.failure else { return [] }
        return [AtticStatusItem(id: "taskFailure", systemName: "exclamationmark.circle", title: failure.message,
                                tone: .caution,
                                actions: failure.canRetry ? [.init(title: String(localized: "Retry"), handler: { model.retryFailure() })] : [])]
    }

    // MARK: Menus (§ 5.5)

    private func installMenus() {
        presenter.menus.noteMenu = { presentNoteMenu() }
        presenter.menus.taskMenu = { taskCommands() }
        presenter.menus.restoreNote = { restoreNote() }
    }

    /// The note's ⋯: Insert and Format, then the note's own commands.
    /// Delete Note… names what goes (P5's scope rule: inside a task's note
    /// the task and its note could be confused).
    func noteCommands() -> [AtticMenuCommand] {
        var commands: [AtticMenuCommand] = []
        let session = presenter.session
        let persisted = session?.isPersisted == true && presenter.deletedNoteID == nil
        if let session, !session.isReadOnly {
            let router = chrome.controls?.router ?? NoteCommandRouter(engine: session.engine)
            commands += router.menuCommands(from: .noteMenu)
        }
        if let session, persisted {
            let id = session.noteID
            let pinned = noteStore.note(withID: id)?.isPinned ?? false
            commands.append(AtticMenuCommand(pinned ? "Unpin from Top" : "Pin to Top", startsSection: !commands.isEmpty,
                                             identifier: "task-note-menu-pin") {
                controller.setPinned(!pinned, noteID: id)
            })
            commands.append(AtticMenuCommand("Copy as Markdown", shortcut: KeyboardShortcut("c", modifiers: [.command, .option, .shift]),
                                             identifier: "task-note-menu-copy-markdown") {
                controller.copyMarkdown(noteID: id)
            })
            let engine = session.engine
            commands.append(AtticMenuCommand("Print…", shortcut: KeyboardShortcut("p", modifiers: .command),
                                             identifier: "task-note-menu-print") {
                Task { _ = await engine.printNote() }
            })
        }
        if presenter.deletedNoteID != nil {
            commands.append(AtticMenuCommand("Restore Note", startsSection: !commands.isEmpty,
                                             identifier: "task-note-menu-restore-note") { restoreNote() })
        }
        commands.append(contentsOf: placementCommands(startsSection: !commands.isEmpty))
        if persisted {
            commands.append(AtticMenuCommand("Delete Note…", isDestructive: true, startsSection: true,
                                             identifier: "task-note-menu-delete-note") { confirming = .deleteNote })
        }
        return commands
    }

    /// The task's menu: right-click the head (§ 5.5). Delete Task… names
    /// what goes and what stays (`p3-22` row 1).
    func taskCommands() -> [AtticMenuCommand] {
        guard model.head.exists else { return [] }
        let done = model.head.state == .done
        var commands: [AtticMenuCommand] = [
            AtticMenuCommand(verbatim: done ? String(localized: "Mark as Not Done") : String(localized: "Complete"),
                             shortcut: AtticTaskShortcut.complete) { model.toggleTask() }.identified("task-note-task-complete"),
            AtticMenuCommand(verbatim: String(localized: "Edit Title")) {
                model.requestFocus(.title)
            }.identified("task-note-task-edit-title"),
        ]
        if !done {
            commands.append(AtticMenuCommand(verbatim: String(localized: "Add Subtask")) {
                if model.isFolded { model.setFolded(false) }
                model.requestFocus(.add)
            }.identified("task-note-task-add-subtask"))
        }
        commands.append(contentsOf: placementCommands(startsSection: true))
        commands.append(AtticMenuCommand(verbatim: String(localized: "Delete Task…"), isDestructive: true, startsSection: true) {
            confirming = .deleteTask
        }.identified("task-note-task-delete"))
        return commands
    }

    private func placementCommands(startsSection: Bool) -> [AtticMenuCommand] {
        var commands: [AtticMenuCommand] = []
        if let onOpenInWindow, placement == .panel {
            commands.append(AtticMenuCommand(verbatim: String(localized: "Open in Window"), startsSection: startsSection) {
                onOpenInWindow()
            }.identified("task-note-open-window"))
        }
        commands.append(AtticMenuCommand(verbatim: leaveTitle, startsSection: startsSection && commands.isEmpty) {
            onBack()
        }.identified("task-note-menu-back"))
        return commands
    }

    private func presentNoteMenu() {
        let commands = noteCommands()
        let head = presenter.host.headView
        let width = head.bounds.width - columnInset + 4
        let anchor = NSRect(x: max(0, width - 30), y: 0, width: 28, height: TaskNoteMetrics.titleLineHeight + 4)
        AtticNativeMenu.popUpContextMenu(commands, below: anchor, in: head)
    }

    private var confirmationTitle: String {
        switch confirming {
        case .deleteTask: String(localized: "Delete “\(model.head.title)”?")
        case .deleteNote: String(localized: "Delete this note?")
        case nil: ""
        }
    }

    private func confirmationMessage(_ kind: Confirmation) -> String {
        switch kind {
        case .deleteTask:
            let count = model.head.subtasks.total
            let subtasks = count == 0 ? String(localized: "The task goes")
                : String(localized: "The task and its \(count) subtasks go")
            return subtasks + " " + String(localized: "to Recently Deleted for 30 days. Its note stays in All notes, and you can keep editing it.")
        case .deleteNote:
            return String(localized: "Its writing and files go to Recently Deleted for 30 days. “\(model.head.title)” and its subtasks stay in Tasks.")
        }
    }

    // MARK: Lifecycle (`p3-22`: nothing cascades)

    private static let log = Logger(subsystem: "com.taha.Attic", category: "TaskPage")

    private func deleteNote() {
        guard let session = presenter.session else { return }
        let id = session.noteID
        Task { @MainActor in
            // Leave the page durably first (its draft is saved), then delete
            // the note itself; the page comes back with Restore Note.
            guard await presenter.close() else {
                Self.log.notice("Delete Note: the page kept its note (close refused)")
                return
            }
            guard await controller.deleteNoteDurably(noteID: id) else {
                Self.log.notice("Delete Note refused by the store")
                onReopen()
                return
            }
            onReopen()
        }
    }

    private func restoreNote() {
        guard let id = presenter.deletedNoteID else {
            Self.log.notice("Restore Note: no deleted note on this page")
            return
        }
        Task { @MainActor in
            guard controller.restoreDeletedNote(noteID: id, reopen: false) else {
                Self.log.notice("Restore Note refused by the store")
                return
            }
            guard await presenter.close() else {
                Self.log.notice("Restore Note: the page could not close to reopen")
                return
            }
            onReopen()
        }
    }
}

/// The composed host inside SwiftUI. The host (and so the text view) belongs
/// to the presenter: SwiftUI may rebuild this representable, never the editor.
struct TaskNoteHostRepresentable: NSViewRepresentable {
    let presenter: TaskNotePresenter
    let chrome: NotesPageChrome
    let columnInset: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let design: AtticDesignContext
    let engineGeneration: UInt64
    /// Esc with nothing left to close in the writing goes Back (§ 7).
    var onEscape: (() -> Void)?

    @MainActor
    final class Coordinator {
        var controls: NoteFormatControls?
        var objects: NoteObjectControls?
        weak var engine: NoteEditorEngine?

        func invalidate() {
            controls?.invalidate()
            objects?.invalidate()
            controls = nil
            objects = nil
            engine = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let host = presenter.host
        host.setContentInsets(top: topInset, bottom: bottomInset)
        host.columnInset = columnInset
        configureControls(context.coordinator)
        let engine = host.engine
        let textView = host.textView
        textView.escapeFallback = onEscape
        // The page's first frame: the open request's interval ends there.
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { PerformanceSignposts.taskPageDidDraw() } }
        DispatchQueue.main.async {
            guard presenter.lease != nil, host.engine === engine, host.textView === textView else { return }
            presenter.restoreViewStateOnMount()
            if !engine.isReadOnly { textView.window?.makeFirstResponder(textView) }
        }
        return host.scrollView
    }

    private func configureControls(_ coordinator: Coordinator) {
        guard presenter.lease != nil else { return }
        let host = presenter.host
        let engine = host.engine
        guard coordinator.engine !== engine else { return }
        coordinator.invalidate()
        host.onInvalidate = { [weak coordinator] in coordinator?.invalidate() }
        chrome.controls = nil
        chrome.objectControls = nil
        coordinator.engine = engine
        let textView = host.textView
        if !engine.isReadOnly {
            let controls = NoteFormatControls(engine: engine, textView: textView, scrollView: host.scrollView, design: design)
            controls.requestFormatBar = { [weak chrome] keyboard in chrome?.openFormatBar(keyboard: keyboard) }
            controls.closeFormatBar = { [weak chrome] in chrome?.closeFormatBar() }
            // ⌃⇧Tab leaves the writing for the Subtasks block (§ 7); ⌃Tab
            // enters the next card's controls (cards are slice 3).
            controls.leaveEditor = { [weak model = presenter.model] forward in
                if !forward { model?.focusBlockFromWriting() }
            }
            coordinator.controls = controls
            chrome.controls = controls
            let objects = NoteObjectControls(engine: engine, textView: textView)
            coordinator.objects = objects
            chrome.objectControls = objects
        }
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard presenter.lease != nil else { return }
        configureControls(context.coordinator)
        presenter.host.textView.escapeFallback = onEscape
        presenter.host.setContentInsets(top: topInset, bottom: bottomInset)
        presenter.host.columnInset = columnInset
        context.coordinator.controls?.update(design: design)
        context.coordinator.objects?.applyLook()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.invalidate()
    }
}

/// Opens the presenter once for the shown task and closes it on Back.
struct TaskNotePageContainer: View {
    let taskID: UUID
    let tasks: TaskStore
    @ObservedObject var controller: NotesPageController
    let noteStore: NoteStore
    let layout: PanelPageLayout
    var backTitle = String(localized: "Back to Notes")
    var placement: TaskNotePlacement = .panel
    var onOpenInWindow: (() -> Void)?
    let onClose: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var presenter: TaskNotePresenter?
    @State private var openFailed = false
    @State private var closing = false

    var body: some View {
        Group {
            if let presenter {
                TaskNotePage(presenter: presenter, controller: controller, noteStore: noteStore,
                             layout: layout, backTitle: backTitle, placement: placement,
                             onOpenInWindow: onOpenInWindow.map { open in { moveToWindow(open) } },
                             onReopen: reopen, onBack: back)
                    // A reopened page is a new presenter with its own host:
                    // its native views must be mounted, never the old ones.
                    .id(ObjectIdentifier(presenter))
            } else if openFailed {
                AtticText("This task's note can't be opened here.", style: .body, ink: .helper)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .onAppear(perform: open)
    }

    private func open() {
        guard presenter == nil, !openFailed else { return }
        // OD-1: one live page per task. Open in a window already, it comes
        // forward there instead of opening a second editor here.
        if placement == .panel, TaskNoteWindows.shared.bringForward(taskID) {
            onClose()
            return
        }
        guard let library = tasks.commandLibrary else { openFailed = true; return }
        let inset = layout.chromeInsets.leading + AtticNoteMetrics.columnInset
        do {
            switch placement {
            case .panel:
                presenter = try controller.openTaskNote(taskID: taskID, tasks: tasks, library: library,
                                                        design: design, columnInset: inset)
            case .window:
                presenter = try TaskNotePresenter(taskID: taskID, tasks: tasks, library: library, notes: controller,
                                                  design: design, columnInset: inset)
            }
        } catch {
            openFailed = true
        }
        #if DEBUG
        if let presenter { TaskNoteCaptureScript.runIfRequested(presenter) }
        #endif
    }

    /// Back keeps the page when the session refuses to let go (a
    /// composition, a save not yet durable); it never loses the draft.
    private func back() {
        guard !closing else { return }
        guard let presenter else { onClose(); return }
        closing = true
        Task { @MainActor in
            let closed = await presenter.close()
            closing = false
            if closed { onClose() }
        }
    }

    /// OD-1: the panel's page lets go durably, then the window takes the
    /// same task (the warm editor moves with it).
    private func moveToWindow(_ open: @escaping () -> Void) {
        guard !closing, let presenter else { return }
        closing = true
        Task { @MainActor in
            let closed = await presenter.close()
            closing = false
            guard closed else { return }
            open()
            onClose()
        }
    }

    /// Delete Note… or Restore Note changed what the task's page holds: it
    /// opens again on the same task.
    private func reopen() {
        Task { @MainActor in
            if let presenter, presenter.lease != nil { guard await presenter.close() else { return } }
            presenter = nil
            openFailed = false
            open()
        }
    }
}

extension NotesPageController {
    /// Route handoff uses Back's durable boundary, including field resolution.
    /// The caller keeps the old page mounted until this succeeds.
    func prepareTaskNoteRoute(_ taskID: UUID?) async -> Bool {
        guard let presenter = taskNotePresenter, presenter.taskID != taskID || presenter.isClosing else { return true }
        return await presenter.close()
    }

    /// The rebuilt section container resumes its navigation owner's lease.
    /// A different workspace still cannot steal that lease or its draft.
    func openTaskNote(taskID: UUID, tasks: TaskStore, library: AtticLibrary,
                      design: AtticDesignContext, columnInset: CGFloat,
                      defaults: UserDefaults? = .standard) throws -> TaskNotePresenter {
        if let presenter = taskNotePresenter, presenter.lease != nil {
            guard presenter.taskID == taskID, presenter.model.store === tasks,
                  presenter.model.library === library else { throw TaskNotePresenter.OpenError.unavailable }
            presenter.update(design: design)
            presenter.host.columnInset = columnInset
            return presenter
        }
        let presenter = try TaskNotePresenter(taskID: taskID, tasks: tasks, library: library, notes: self,
            design: design, columnInset: columnInset, defaults: defaults)
        taskNotePresenter = presenter
        return presenter
    }
}

extension AtticMenuCommand {
    /// The same command with an identifier (UI tests, key routing).
    func identified(_ identifier: String) -> AtticMenuCommand {
        var copy = self
        copy.identifier = identifier
        return copy
    }
}
