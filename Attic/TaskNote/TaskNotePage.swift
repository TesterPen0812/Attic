import AppKit
import Combine
import SwiftUI

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
    private var engineObservation: AnyCancellable?
    private var hasMounted = false
    private var closeWork: Task<Bool, Never>?
    var isClosing: Bool { closeWork != nil }
    /// Rings in the head and the block only while the keyboard drives.
    private static let focusTracker = AtticKeyboardFocusTracker()

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
                                    head: Self.headView(model, design: design),
                                    block: Self.blockView(model, design: design),
                                    columnInset: columnInset,
                                    blockHeight: { [weak model] in model?.blockHeight ?? TaskNoteMetrics.blockHeader })
        engine.setCompatibilityTitle(model.head.title)
        model.onGeometryChange = { [weak self] in
            guard let self else { return }
            self.host.engine.setCompatibilityTitle(self.model.head.title)
            self.host.setNeedsRestack()
        }
        model.onFocusWriting = { [weak self] atTop in self?.host.focusWriting(atTop: atTop) }
        if canReuse {
            if cached?.design != design {
                host.setRegions(head: Self.headView(model, design: design), block: Self.blockView(model, design: design))
            }
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

    private static func headView(_ model: TaskNotePageModel, design: AtticDesignContext) -> AnyView {
        AnyView(TaskNoteHeadView(model: model).environment(\.atticDesign, design).atticKeyboardFocusTracking(focusTracker))
    }

    private static func blockView(_ model: TaskNotePageModel, design: AtticDesignContext) -> AnyView {
        AnyView(TaskNoteSubtasksBlock(model: model).environment(\.atticDesign, design).atticKeyboardFocusTracking(focusTracker))
    }

    func update(design: AtticDesignContext) {
        guard lease != nil, design != self.design else { return }
        self.design = design
        notes?.update(design: design)
        host.engine.update(design: design)
        model.reduceMotion = design.reduceMotion
        host.setRegions(head: Self.headView(model, design: design), block: Self.blockView(model, design: design))
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

// MARK: - The page

/// The task's note over the Notes page (§ 5.4): the composed scroll, then
/// the bottom row with Back (bottom-left), the Notes status slot and Aa.
/// The riding title (§ 2.2) is round 2b.
struct TaskNotePage: View {
    @ObservedObject var presenter: TaskNotePresenter
    @ObservedObject var model: TaskNotePageModel
    @ObservedObject var controller: NotesPageController
    @ObservedObject var noteStore: NoteStore
    let layout: PanelPageLayout
    let onBack: () -> Void

    @Environment(\.atticDesign) private var design
    @StateObject private var chrome = NotesPageChrome()
    @StateObject private var damaged: NoteDamagedRecoveryExit

    init(presenter: TaskNotePresenter, controller: NotesPageController, noteStore: NoteStore,
         layout: PanelPageLayout, onBack: @escaping () -> Void) {
        self.presenter = presenter
        self.model = presenter.model
        self.controller = controller
        self.noteStore = noteStore
        self.layout = layout
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

    var body: some View {
        ZStack(alignment: .bottom) {
            TaskNoteHostRepresentable(presenter: presenter, chrome: chrome, columnInset: columnInset,
                                      topInset: topInset, bottomInset: bottomInset, design: design,
                                      engineGeneration: presenter.engineGeneration)
                .atticScrollUnderFade(topBand: layout.headerBottom, restTop: topInset,
                                      bottomBand: bottomControls, restBottom: bottomInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("task-note-page")
            bottomRow
                .padding(.leading, layout.chromeInsets.leading)
                .padding(.trailing, layout.chromeInsets.trailing)
                .padding(.bottom, layout.chromeInsets.bottom)
        }
        .onChange(of: design) { _, newValue in presenter.update(design: newValue) }
        .onChange(of: chrome.isFormatPopoverOpen) { _, open in
            chrome.controls?.isFormatPopoverOpen = open
            if !open {
                DispatchQueue.main.async {
                    guard presenter.lease != nil else { return }
                    presenter.host.focusWriting(atTop: false)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var bottomRow: some View {
        AtticControlGroup {
            HStack(spacing: 0) {
                AtticRaisedButton(systemName: "chevron.left", label: "Back", help: String(localized: "Back to Notes")) {
                    onBack()
                }
                .accessibilityLabel(String(localized: "Back to Notes"))
                .accessibilityIdentifier("task-note-back")
                Spacer(minLength: AtticSpacing.s12)
                if let session = presenter.session {
                    NoteStatusSlot(controller: controller, store: noteStore, session: session, damaged: damaged,
                                   leadingItems: taskItems)
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
                        chrome.openFormatPopover(keyboard: false)
                    }
                    .accessibilityIdentifier("task-note-format")
                    .atticDropdown(isPresented: $chrome.isFormatPopoverOpen, prefer: .above, label: String(localized: "Format")) {
                        if let controls = chrome.controls {
                            NoteFormatPopoverView(model: controls.formatModel, openedByKeyboard: chrome.formatPopoverByKeyboard) {
                                chrome.isFormatPopoverOpen = false
                            }
                        }
                    }
                }
            }
            .frame(height: buttonHeight)
        }
    }

    /// A task command that changed nothing (§ 5.6), quietly in the slot.
    private var taskItems: [AtticStatusItem] {
        guard let failure = model.failure else { return [] }
        return [AtticStatusItem(id: "taskFailure", systemName: "exclamationmark.circle", title: failure.message,
                                tone: .warning,
                                actions: failure.canRetry ? [.init(title: String(localized: "Retry"), handler: { model.retryFailure() })] : [])]
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
            let controls = NoteFormatControls(engine: engine, textView: textView, scrollView: host.scrollView, design: design,
                                              noteID: engine.noteID, isNewDraft: false)
            controls.requestFormatPopover = { [weak chrome] keyboard in chrome?.openFormatPopover(keyboard: keyboard) }
            controls.closeFormatPopover = { [weak chrome] in chrome?.isFormatPopoverOpen = false }
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
    let onClose: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var presenter: TaskNotePresenter?
    @State private var openFailed = false
    @State private var closing = false

    var body: some View {
        Group {
            if let presenter {
                TaskNotePage(presenter: presenter, controller: controller, noteStore: noteStore,
                             layout: layout, onBack: back)
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
        guard let library = tasks.commandLibrary else { openFailed = true; return }
        do {
            presenter = try controller.openTaskNote(taskID: taskID, tasks: tasks, library: library,
                design: design, columnInset: layout.chromeInsets.leading + AtticNoteMetrics.columnInset)
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
