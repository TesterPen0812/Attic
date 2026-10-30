import AppKit
import SwiftUI

/// The minimal window keeps the same page, lease and history as its item
/// changes form. Open in Window / Move to Panel still release durably before
/// another surface acquires the editor.
@MainActor
final class TaskNoteWindows: NSObject, NSWindowDelegate {
    static let shared = TaskNoteWindows()

    @MainActor private final class Entry {
        let window: NSWindow
        let uiState: PanelUIState
        var presenter: TaskNotePresenter
        let design: AtticDesignContext
        var taskAliases: Set<UUID>
        init(window: NSWindow, uiState: PanelUIState, presenter: TaskNotePresenter, design: AtticDesignContext) {
            self.window = window; self.uiState = uiState; self.presenter = presenter
            self.design = design
            taskAliases = [presenter.taskID]
        }
    }
    /// Stable host IDs, independent of the current task/note alias.
    private var entries: [UUID: Entry] = [:]
    private var closing: Set<UUID> = []

    var openTaskIDs: Set<UUID> { Set(entries.values.compactMap { $0.presenter.isOrdinary ? nil : $0.presenter.taskID }) }
    func window(for taskID: UUID) -> NSWindow? { entry(taskID)?.value.window }
    func window(noteID: UUID) -> NSWindow? { entries.values.first { $0.presenter.session?.noteID == noteID }?.window }
    func session(noteID: UUID, controller: NotesPageController) -> NoteSession? {
        entries.values.first { $0.presenter.page.controller === controller && $0.presenter.session?.noteID == noteID && $0.presenter.lease != nil }?.presenter.session
    }
    private func entry(_ taskID: UUID) -> Dictionary<UUID, Entry>.Element? {
        entries.first { $0.value.taskAliases.contains(taskID) }
    }

    /// Called only after a durable handoff (or fixture teardown).
    func finishHandoff(_ taskID: UUID) {
        guard let (id, entry) = entry(taskID) else { return }
        entries[id] = nil; closing.remove(id)
        entry.window.delegate = nil
        entry.window.close()
        entry.window.contentViewController = nil
    }

    /// Publication updates metadata before replacing the reserved engine.
    /// No window or lease is recreated, including Undo/Redo and agent Review.
    func prepareProjection(session: NoteSession, taskID: UUID?) {
        guard let entry = entries.values.first(where: { $0.presenter.session === session && $0.presenter.lease != nil }) else { return }
        entry.presenter.prepareItemProjection(taskID: taskID)
        if let taskID { entry.taskAliases.insert(taskID) }
        entry.window.title = taskID == nil ? (entry.presenter.page.controller?.store.note(withID: session.noteID)?.title ?? "") : entry.presenter.model.head.title
    }

    func allowsProjection(session: NoteSession) -> Bool {
        guard let presenter = entries.values.first(where: { $0.presenter.session === session })?.presenter,
              presenter.model.hasFieldDrafts else { return true }
        presenter.page.history.holdPublicationInput { [weak presenter] in presenter?.model.hasFieldDrafts == true }
        session.showNotice(NoteNotice(kind: .didntWork, detail: "Your field draft is kept. Cancel it to finish updating this item."))
        return false
    }

    /// File migration already requires a durable editor handoff. Release
    /// that lease, then remount the migrated page in the same native window,
    /// including refusals. The migration retains its existing journal/history.
    func moveFilesFirst(_ taskID: UUID, tasks: TaskStore, controller: NotesPageController) async -> TaskAttachmentMigration.Outcome {
        guard let (id, entry) = entry(taskID), !closing.contains(id) else { return .deferred }
        closing.insert(id)
        defer { closing.remove(id) }
        guard await entry.presenter.close() else { return .deferred }
        WorkspaceCrashHook.reach("C2-window-migration-released")
        let outcome = await tasks.fileMigration.moveIntoNote(taskID, tasks: tasks, notes: controller)
        guard restoreAfterFileMove(taskID, entry: entry, tasks: tasks, controller: controller) else { return .deferred }
        return outcome
    }

    private func restoreAfterFileMove(_ taskID: UUID, entry: Entry, tasks: TaskStore, controller: NotesPageController) -> Bool {
        do {
            guard let library = tasks.commandLibrary else { throw WorkspaceFoundationError.protectedOwner }
            let presenter = try TaskNotePresenter(taskID: taskID, tasks: tasks, library: library, notes: controller,
                design: entry.design, columnInset: 28)
            guard let lease = presenter.lease else { return false }
            try presenter.page.retainAcrossItemChanges(lease: lease)
            entry.presenter = presenter
            installRoot(entry)
            WorkspaceCrashHook.reach("C2-window-migration-rebound")
            return true
        } catch {
            let frame = entry.window.frame
            entry.window.contentViewController = NSHostingController(rootView: VStack(spacing: 12) {
                Text("Couldn't reopen this item yet. Your writing and files are kept.")
                Button("Retry") { [weak self, weak entry, weak tasks, weak controller] in
                    guard let self, let entry, let tasks, let controller else { return }
                    _ = self.restoreAfterFileMove(taskID, entry: entry, tasks: tasks, controller: controller)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding())
            entry.window.setFrame(frame, display: false)
            return false
        }
    }

    private func installRoot(_ entry: Entry) {
        guard let controller = entry.presenter.page.controller else { return }
        let taskID = entry.presenter.taskID
        let root = TaskNoteWindowRoot(presenter: entry.presenter, controller: controller, noteStore: controller.store) { [weak self] in
            Task { @MainActor in _ = await self?.moveToPanel(taskID: taskID) }
        }.environment(\.atticDesign, entry.design)
        let frame = entry.window.frame
        entry.window.contentViewController = NSHostingController(rootView: root)
        entry.window.setFrame(frame, display: false)
    }

    @discardableResult
    func bringForward(_ taskID: UUID, searchQuery: String? = nil) -> Bool {
        guard let entry = entry(taskID)?.value else { return false }
        if let searchQuery { entry.presenter.revealSearchResult(searchQuery) }
        entry.window.makeKeyAndOrderFront(nil); NSApp.activate()
        return true
    }
    @discardableResult
    func bringForward(noteID: UUID, searchQuery: String? = nil) -> Bool {
        guard let entry = entries.values.first(where: { $0.presenter.session?.noteID == noteID }) else { return false }
        if let searchQuery { entry.presenter.revealSearchResult(searchQuery) }
        entry.window.makeKeyAndOrderFront(nil); NSApp.activate()
        return true
    }

    func open(taskID: UUID, tasks: TaskStore, controller: NotesPageController, noteStore: NoteStore,
              design: AtticDesignContext, uiState: PanelUIState) {
        if bringForward(taskID) { return }
        guard let library = tasks.commandLibrary else { return }
        let presenter: TaskNotePresenter
        do {
            presenter = try TaskNotePresenter.open(for: taskID) ?? TaskNotePresenter(taskID: taskID, tasks: tasks,
                library: library, notes: controller, design: design, columnInset: 28)
            guard presenter.page.controller === controller, let lease = presenter.lease else { return }
            try presenter.page.retainAcrossItemChanges(lease: lease)
        } catch { return }
        let size = CGSize(width: 380, height: 600)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.title = presenter.model.head.title
        window.minSize = CGSize(width: 300, height: 360)
        window.backgroundColor = NSColor(design.tokens.panel.base.color)
        window.identifier = NSUserInterfaceItemIdentifier("task-note-window")
        window.delegate = self
        let id = UUID()
        let entry = Entry(window: window, uiState: uiState, presenter: presenter, design: design)
        entries[id] = entry
        installRoot(entry)
        window.setContentSize(size); window.center()
        window.makeKeyAndOrderFront(nil); NSApp.activate()
    }

    @discardableResult
    func moveToPanel(taskID: UUID) async -> Bool {
        guard let (id, entry) = entry(taskID), !closing.contains(id) else { return false }
        closing.insert(id)
        if entry.presenter.isOrdinary, let controller = entry.presenter.page.controller,
           !(await controller.prepareToLeaveDurably(.openNote)) {
            closing.remove(id)
            return false
        }
        let closed = await entry.presenter.close()
        closing.remove(id)
        guard closed, entries[id] === entry else { return false }
        if entry.presenter.isOrdinary, let noteID = entry.presenter.session?.noteID,
           let controller = entry.presenter.page.controller {
            guard controller.open(noteID: noteID) else {
                // A destination can become busy during the durable close.
                // Keep this native window as the retry surface in that case.
                let frame = entry.window.frame
                entry.window.contentViewController = NSHostingController(rootView: VStack(spacing: 12) {
                    Text("Finish editing in the panel, then move this item.")
                    Button("Move to Panel") { [weak self] in Task { @MainActor in _ = await self?.moveToPanel(taskID: taskID) } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding())
                entry.window.setFrame(frame, display: false)
                return false
            }
            controller.dismissLibrary()
            entry.uiState.switchPage(to: .notes, motion: .instant)
        } else {
            entry.uiState.openTaskNote(entry.presenter.taskID, from: PanelPage(entry.uiState.selectedSection))
        }
        entries[id] = nil
        entry.window.delegate = nil; entry.window.close(); entry.window.contentViewController = nil
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let (id, entry) = entries.first(where: { $0.value.window === sender }) else { return true }
        guard !closing.contains(id) else { return false }
        closing.insert(id)
        Task { @MainActor in
            let closed = await entry.presenter.close()
            closing.remove(id)
            guard closed, entries[id] === entry else { return }
            entries[id] = nil
            entry.window.delegate = nil; entry.window.close(); entry.window.contentViewController = nil
        }
        return false
    }
}

private struct TaskNoteWindowRoot: View {
    @ObservedObject var presenter: TaskNotePresenter
    let controller: NotesPageController
    let noteStore: NoteStore
    let onMoveToPanel: () -> Void

    var body: some View {
        GeometryReader { proxy in
            TaskNotePage(presenter: presenter, controller: controller, noteStore: noteStore,
                         layout: PanelPageLayout(cornerSize: 20, panelSize: proxy.size),
                         backTitle: String(localized: "Move to Panel"), placement: .window, onBack: onMoveToPanel)
                .id(presenter.projectionGeneration)
        }.ignoresSafeArea()
    }
}
