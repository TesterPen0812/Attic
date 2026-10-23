import AppKit
import SwiftUI

/// Open in Window (OD-1): the task's page **moves** to its own window. The
/// panel's surface lets go durably first; the window then opens the same
/// task, reusing the warm editor. There is never a second live editor: a
/// task already in a window comes forward instead of opening in the panel.
///
/// The Phase 5 window system replaces this minimal host; the hook (move,
/// Move to Panel, one page per task) is what Phase 3 needs.
@MainActor
final class TaskNoteWindows: NSObject, NSWindowDelegate {
    static let shared = TaskNoteWindows()

    private struct Entry {
        let window: NSWindow
        let uiState: PanelUIState
    }
    private var entries: [UUID: Entry] = [:]
    /// Closing waits for the page's durable close; a refusal keeps it open.
    private var closing: Set<UUID> = []

    var openTaskIDs: Set<UUID> { Set(entries.keys) }

    func window(for taskID: UUID) -> NSWindow? { entries[taskID]?.window }

    /// A conversion has durably released its presenter. The minimal host
    /// hands writing to Notes until C2 supplies in-place window parity.
    func finishHandoff(_ taskID: UUID) {
        guard let entry = entries.removeValue(forKey: taskID) else { return }
        closing.remove(taskID)
        entry.window.delegate = nil
        entry.window.close()
        entry.window.contentViewController = nil
    }

    /// Brings the task's window forward. False when it has none.
    @discardableResult
    func bringForward(_ taskID: UUID) -> Bool {
        guard let window = entries[taskID]?.window else { return false }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return true
    }

    func open(taskID: UUID, tasks: TaskStore, controller: NotesPageController, noteStore: NoteStore,
              design: AtticDesignContext, uiState: PanelUIState) {
        if bringForward(taskID) { return }
        let size = CGSize(width: 380, height: 600)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = tasks.task(withID: taskID)?.title ?? String(localized: "Task")
        window.minSize = CGSize(width: 300, height: 360)
        window.backgroundColor = NSColor(design.tokens.panel.base.color)
        window.identifier = NSUserInterfaceItemIdentifier("task-note-window")
        window.delegate = self
        let root = TaskNoteWindowRoot(taskID: taskID, tasks: tasks, controller: controller, noteStore: noteStore) { [weak self] in
            self?.moveToPanel(taskID)
        }
        .environment(\.atticDesign, design)
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(size)
        window.center()
        entries[taskID] = Entry(window: window, uiState: uiState)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Move to Panel (Phase 5 Q5): the page has let go durably; the panel
    /// opens it over the page it shows.
    private func moveToPanel(_ taskID: UUID) {
        guard let entry = entries.removeValue(forKey: taskID) else { return }
        entry.window.delegate = nil
        entry.window.close()
        let uiState = entry.uiState
        uiState.openTaskNote(taskID, from: PanelPage(uiState.selectedSection))
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let (taskID, _) = entries.first(where: { $0.value.window === sender }) else { return true }
        guard let presenter = TaskNotePresenter.open(for: taskID) else {
            entries[taskID] = nil
            return true
        }
        guard !closing.contains(taskID) else { return false }
        closing.insert(taskID)
        Task { @MainActor in
            let closed = await presenter.close()
            closing.remove(taskID)
            guard closed, let entry = entries.removeValue(forKey: taskID) else { return }
            entry.window.delegate = nil
            entry.window.close()
        }
        return false
    }
}

/// The window's page: the same task page, with Move to Panel bottom-left.
private struct TaskNoteWindowRoot: View {
    let taskID: UUID
    let tasks: TaskStore
    let controller: NotesPageController
    let noteStore: NoteStore
    let onMoveToPanel: () -> Void

    var body: some View {
        GeometryReader { proxy in
            TaskNotePageContainer(taskID: taskID, tasks: tasks, controller: controller, noteStore: noteStore,
                                  layout: PanelPageLayout(cornerSize: 20, panelSize: proxy.size),
                                  backTitle: String(localized: "Move to Panel"), placement: .window,
                                  onClose: onMoveToPanel)
        }
        .ignoresSafeArea()
    }
}
