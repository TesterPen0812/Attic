import Combine
import SwiftUI
import UniformTypeIdentifiers

/// State the Tasks page keeps while another page is showing. The shell owns
/// one instance for the panel's lifetime, so switching to Notes and back never
/// loses what was typed, selected or expanded: it holds the page's model.
@MainActor
final class TasksPageState: ObservableObject {
    private var model: TasksPageModel?
    /// The last Search request the page acted on (`PanelUIState.searchRequest`).
    var handledSearchRequest: UInt64 = 0
    /// A request can precede the page's mount. Keep consumption with the
    /// page state so rebuilding or returning never replays an old request.
    var handledPrimaryInputFocusRequest: UInt64 = 0
    /// Where the page remembers its page and views across relaunch (L7);
    /// nil keeps them for the session only.
    let memory: TasksPageMemory?

    init(memory: TasksPageMemory? = nil) {
        self.memory = memory
    }

    /// The page model, made once over the app's command layer (the same
    /// undo history agents use), or over a library of its own when the
    /// store has none (tests that host the panel alone).
    func model(for store: TaskStore, toasts: PanelToastCenter?) -> TasksPageModel {
        if let model, model.store === store, toasts == nil || model.toasts === toasts { return model }
        let library = store.commandLibrary ?? AtticLibrary(tasks: store)
        let made = TasksPageModel(library: library, toasts: toasts, memory: memory)
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
    let state: TasksPageState
    let layout: PanelPageLayout
    let chromeInteractionState: PanelChromeInteractionState
    /// The shell's request for the add bar's keyboard (an explicit open on
    /// Tasks), as a value so each new one reaches this page.
    let primaryInputFocusRequest: UInt64
    /// False while another page shows and this one is kept built behind it.
    var isCurrent = true
    /// Phase 3: open task pages and fill task notes. Nil: Phase 1's rows
    /// (⌘Return opens files, a drop attaches to the task).
    var taskNotes: TaskNoteEntryServices?

    @State private var addBarFocused = false
    @State private var editHold: PanelEditHold
    @State private var filesHold: PanelEditHold
    /// The shell's one toast host: the page's Undo toasts show there.
    @Environment(\.atticPanelToasts) private var toasts

    init(store: TaskStore, uiState: PanelUIState, settings: AppSettings, state: TasksPageState,
         layout: PanelPageLayout, chromeInteractionState: PanelChromeInteractionState,
         primaryInputFocusRequest: UInt64, isCurrent: Bool = true, taskNotes: TaskNoteEntryServices? = nil,
         editHold: PanelEditHold? = nil, filesHold: PanelEditHold? = nil) {
        self.taskNotes = taskNotes
        self.store = store
        self.uiState = uiState
        self.settings = settings
        self.state = state
        self.layout = layout
        self.chromeInteractionState = chromeInteractionState
        self.primaryInputFocusRequest = primaryInputFocusRequest
        self.isCurrent = isCurrent
        _editHold = State(initialValue: editHold ?? PanelEditHold())
        _filesHold = State(initialValue: filesHold ?? PanelEditHold())
    }

    /// Before the page's first build: rows capture whether a title click
    /// opens the task's page when they are drawn.
    private func installTaskNoteServices(_ model: TasksPageModel) {
        guard let taskNotes, model.services.openTaskNote == nil else { return }
        model.services.openTaskNote = { [weak model] id in
            taskNotes.open(id, String(localized: "Back to \(model?.tab.title ?? TasksTab.now.title)"))
        }
        model.services.addFilesToTaskNote = taskNotes.addFiles
        model.services.removeFromTasks = taskNotes.removeFromTasks
        model.services.canRemoveFromTasks = taskNotes.canRemoveFromTasks
        model.services.makeCheckbox = taskNotes.makeCheckbox
        // The row glyph follows the note store (owned by the model, outside
        // view updates).
        model.observeNoteOwners(taskNotes.noteOwners)
        model.notePreviewSource = taskNotes.notePreviews
        model.notePhotoCountSource = taskNotes.notePhotoCounts
        model.services.notePhotos = taskNotes.notePhotos
        model.services.notePhotoURL = taskNotes.notePhotoURL
        model.services.removeNotePhoto = taskNotes.removeNotePhoto
    }

    /// The host's callbacks, also exercised without the Tasks page's own
    /// monitors when testing the lifetime of its holds.
    var pageChrome: TasksPageChrome { pageChrome(editHold: editHold, filesHold: filesHold) }

    func pageChrome(editHold: PanelEditHold, filesHold: PanelEditHold) -> TasksPageChrome {
        TasksPageChrome(
            bottomControlsHeight: { chromeInteractionState.bottomControlsHeight = $0 },
            typingLock: { uiState.setInteractionLock(.quickEntryFocus, isActive: $0) },
            editLock: { [editHold] editing in
                editHold.apply = { [uiState] active in uiState.setInteractionLock(.taskEditing, isActive: active) }
                editHold.set(editing)
            },
            filesLock: { [filesHold] visible in
                filesHold.apply = { [uiState] active in uiState.setInteractionLock(.taskFilesVisible, isActive: active) }
                filesHold.set(visible)
            }
        )
    }

    var body: some View {
        let model = state.model(for: store, toasts: toasts)
        let _ = installTaskNoteServices(model)
        TasksPage(
            model: model,
            store: store,
            // A wide panel keeps a readable column (U-42).
            layout: layout.readingColumn(),
            addBarFocused: $addBarFocused,
            chrome: pageChrome
        )
        .equatable()
        // Swipe to close (owner, 2026-10-01; pinned or not, 2026-10-02): a
        // swipe toward the panel's edge past the last page that way is the
        // panel's.
        .onAppear { [settings] in
            model.pagerSwipe.closeCorner = { settings.corner }
        }
        // Edit mode holds the panel only for the page being shown (round
        // 5): an editor left open behind Notes never keeps Notes up.
        .onChange(of: isCurrent) { _, current in
            editHold.setSuspended(!current)
            filesHold.setSuspended(!current)
            model.isPageShown = current
        }
        .onDisappear {
            editHold.setSuspended(true)
            filesHold.setSuspended(true)
        }
        // Kept built behind another page, it shows again where it was left
        // (its tab, its selection): only a reveal of the panel starts it on
        // Now (`revealCount`, below).
        .onChange(of: isCurrent) { _, current in
            guard current else { return }
            model.pageDidReturn()
            // Back from a task's page: the anchor row has the keyboard.
            if let row = uiState.taskNoteReturnRow, uiState.openTaskNoteID == nil {
                uiState.taskNoteReturnRow = nil
                model.requestReturnFocus(row)
            }
            handlePrimaryInputFocusRequest()
            chromeInteractionState.bottomControlsHeight = TasksPage.footerZone
            syncDraftLock(model)
        }
        // Text typed in the add bar holds the panel open (the shell's
        // composer lock) until it is added or cleared; it is kept either way.
        .onReceive(model.addBarState.$text.map { !$0.text.isEmpty }
            .combineLatest(model.addBarState.$files.map { !$0.isEmpty }) { $0 || $1 }
            .removeDuplicates()) { hasDraft in
            guard isCurrent else { return }
            // On the next turn (round 4): the shell's published lock redraws
            // what observes the shell, and the first keystroke's frame is
            // the add bar's alone. A turn late changes nothing for hiding.
            DispatchQueue.main.async { uiState.setInteractionLock(.taskComposer, isActive: hasDraft) }
        }
        .onAppear {
            // "Attach file…" in a row's files list (A1): the picker, which
            // keeps the panel open while it is up; the list opens on what
            // was attached.
            // Add Files to Note… (slice 2): the picker, then the row drop's
            // path into the task's note.
            model.services.chooseFilesForNote = { [uiState, weak model] id in
                guard !TaskAttachmentPicker.isPresenting(uiState), model?.services.addFilesToTaskNote != nil else { return }
                uiState.taskAttachmentPickerOwnerID = id
                TaskAttachmentPickerSession.present(owner: id) { urls in
                    if uiState.taskAttachmentPickerOwnerID == id { uiState.taskAttachmentPickerOwnerID = nil }
                    guard !urls.isEmpty else { return }
                    model?.services.addFilesToTaskNote?(id, TaskAttachmentStaging(urls: urls))
                }
            }
            // Add Photo… in the replica's panel (R2): the same picker and
            // path into the task's note, for images.
            model.services.chooseImagesForNote = { [uiState, weak model] id in
                guard !TaskAttachmentPicker.isPresenting(uiState), model?.services.addFilesToTaskNote != nil else { return }
                uiState.taskAttachmentPickerOwnerID = id
                TaskAttachmentPickerSession.present(owner: id, allowedTypes: [.image]) { urls in
                    if uiState.taskAttachmentPickerOwnerID == id { uiState.taskAttachmentPickerOwnerID = nil }
                    guard !urls.isEmpty else { return }
                    model?.services.addFilesToTaskNote?(id, TaskAttachmentStaging(urls: urls))
                }
            }
            model.services.chooseFiles = { [store, uiState, weak model] id in
                // A family whose files are in its note adds to the note.
                if store.fileMigration.isMigrated(id), let choose = model?.services.chooseFilesForNote { choose(id); return }
                TaskAttachmentPicker.choose(for: id, store: store, uiState: uiState) { _, ownerID in
                    model?.setFilesExpanded(ownerID, true)
                }
            }
            // The add bar's Attach (O17-06): the files wait for the new task.
            model.services.chooseComposerFiles = { [uiState, weak model] in
                guard !TaskAttachmentPicker.isPresenting(uiState) else { return }
                uiState.isComposerAttachmentPickerPresented = true
                TaskAttachmentPickerSession.present(owner: nil) { urls in
                    uiState.isComposerAttachmentPickerPresented = false
                    model?.addComposerFiles(urls: urls)
                }
            }
            editHold.setSuspended(!isCurrent)
            filesHold.setSuspended(!isCurrent)
            if model.isPageShown != isCurrent { model.isPageShown = isCurrent }
            // Only the page shown takes the shell's focus (a page built
            // behind Notes, or prepared on approach, never takes it).
            if isCurrent, uiState.isComposerPresented { addBarFocused = true }
            handlePrimaryInputFocusRequest()
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
                // Search results on the shown tab (blur rollout captures).
                if let query = environment["ATTIC_UI_TEST_TASKS_SEARCH"], !query.isEmpty {
                    model.setSearchQuery(query, for: model.tab)
                }
                if environment["ATTIC_UI_TEST_COMPLETED_OPEN"] == "1" { model.completedTodayExpanded = true }
                // The first row with subtasks, its quick look open.
                if environment["ATTIC_UI_TEST_EXPAND_FIRST"] == "1",
                   let row = model.rows(for: model.tab).first(where: { $0.model.subtasks != nil }) {
                    model.setExpanded(row.id, true)
                }
                // The first row with subtasks gets N generated files of
                // different kinds (in-memory store only), its files list open.
                if let count = environment["ATTIC_UI_TEST_SEED_FILES"].flatMap(Int.init), count > 0,
                   let row = model.rows(for: model.tab).first(where: { $0.model.subtasks != nil }) {
                    Task { @MainActor in
                        guard let urls = try? TasksCaptureFiles.make(count) else { return }
                        _ = await store.attachStagedFiles(to: row.id) { TaskAttachmentStaging(urls: urls) }
                        model.setFilesExpanded(row.id, true)
                    }
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
        .onReceive(model.editorsIdle) { _ in
            DispatchQueue.main.async { showItemIfNeeded(model, uiState.shownItem) }
        }
        // Quick capture (the global shortcut) and the shell's own focus
        // requests put the insertion point in the add bar.
        // Only while this page is the one shown: the shell's composer is
        // also Notes' New Note, which a Tasks page kept behind must neither
        // take nor end (round 5's CI: New Note closed at once).
        // An explicit open on Tasks (the hotkey, the corner): the keyboard
        // lands in the add bar. The request is the shell's counter:
        // relayed through a `@FocusState` no view was focused on, SwiftUI
        // dropped it (H5-05).
        .onChange(of: primaryInputFocusRequest) { _, _ in handlePrimaryInputFocusRequest() }
        .onChange(of: uiState.isComposerPresented) { _, presented in if presented, isCurrent { addBarFocused = true } }
        .onChange(of: addBarFocused) { _, focused in
            if !focused, isCurrent, uiState.isComposerPresented { uiState.endAdding() }
        }
    }

    private func syncDraftLock(_ model: TasksPageModel) {
        uiState.setInteractionLock(.taskComposer, isActive: !model.addBar.text.isEmpty || !model.addBarState.files.isEmpty)
    }

    private func handlePrimaryInputFocusRequest() {
        guard isCurrent, primaryInputFocusRequest != state.handledPrimaryInputFocusRequest else { return }
        state.handledPrimaryInputFocusRequest = primaryInputFocusRequest
        addBarFocused = true
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
        // edit blocks stays, and is tried again when the edit ends. One
        // whose Done log page could not be read is held by the page, which
        // finishes it once the page loads (round 5, F3).
        guard model.show(ref.id) != .blocked else { return }
        // Cleared after this change is delivered, not inside it.
        DispatchQueue.main.async { if uiState.shownItem == ref { uiState.showItem(nil) } }
    }
}

#if DEBUG
import AppKit

/// Capture seam files (`ATTIC_UI_TEST_SEED_FILES`): small real files of
/// different kinds, written to the app's own temporary folder so the
/// in-memory UI-testing store can attach them. Never the owner's data.
enum TasksCaptureFiles {
    static func make(_ count: Int) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attic-capture-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kinds: [(String, () -> Data)] = [
            ("Launch brief.pdf", pdf),
            ("Moodboard.png", { image(.systemTeal, type: .png) }),
            ("Press release draft.docx", { Data("Draft".utf8) }),
            ("Venue photo.jpg", { image(.systemOrange, type: .jpeg) }),
            ("Budget.csv", { Data("item,cost\nvenue,1200\n".utf8) }),
            ("Assets.zip", { Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: 0, count: 18)) }),
            ("Meeting notes.txt", { Data("Agenda\n- intro\n".utf8) })
        ]
        return try (0..<count).map { index in
            let (name, data) = kinds[index % kinds.count]
            let prefix = index < kinds.count ? "" : "\(index / kinds.count + 1) "
            let url = folder.appendingPathComponent(prefix + name)
            try data().write(to: url)
            return url
        }
    }

    private static func image(_ color: NSColor, type: NSBitmapImageRep.FileType) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: color, ending: .white)?.draw(in: NSRect(x: 0, y: 0, width: 320, height: 200), angle: 45)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: type, properties: [:]) ?? Data()
    }

    private static func pdf() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 72, y: 600, width: 468, height: 120))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
#endif
