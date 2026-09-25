#if DEBUG
import AppKit
import SwiftData
import SwiftUI

/// Preview builds only: the Tasks page on its own, in a panel-sized key
/// window, over an in-memory store (never the owner's data: it opens only
/// through the gallery's launch gate, which refuses the official identity).
///
///     open -n <preview.app> --args --attic-gallery --attic-tasks-page [--seed-500] [--dark]
///
/// `--seed-500` loads the Phase 0 performance seed (500 tasks and 5,000
/// finished ones in the Done log) instead of the small demo set.
@MainActor
enum TasksPagePreview {
    static let argument = "--attic-tasks-page"
    static let seedArgument = "--seed-500"

    private static var window: NSWindow?
    private static var retained: [AnyObject] = []

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    static func open() {
        let container: ModelContainer
        do {
            container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
            if ProcessInfo.processInfo.arguments.contains(seedArgument) {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticTasksPreview-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try PerformanceSeed.generate(in: container, root: root, includeDoneHistory: true)
            } else {
                try seedDemo(in: container)
            }
        } catch {
            NSLog("Attic Tasks preview: %@", error.localizedDescription)
            return
        }
        let store = TaskStore(container: container)
        let library = AtticLibrary(tasks: store)
        let model = TasksPageModel(library: library, services: TasksPageServices(openPage: { id in
            NSLog("Attic Tasks preview: open page for %@ (task pages arrive in Phase 3)", id.uuidString)
        }))
        retained = [store, library, model]
        let dark = ProcessInfo.processInfo.arguments.contains("--dark")
        let root = TasksPagePreviewRoot(model: model, store: store, mode: dark ? .dark : .light)
        let size = NSSize(width: AtticLayout.panelSize.width, height: AtticLayout.panelSize.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Attic Tasks Page"
        window.identifier = NSUserInterfaceItemIdentifier("AtticTasksPagePreview")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.center()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        for delay in [0.1, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !window.isKeyWindow else { return }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
        }
    }

    /// The v9 mockup's tasks, plus a backlog and a few days of the Done log.
    static func seedDemo(in container: ModelContainer) throws {
        let context = ModelContext(container)
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let today = DueDay(date: now, calendar: calendar)
        func day(_ offset: Int) -> DueDay? {
            calendar.date(byAdding: .day, value: offset, to: now).map { DueDay(date: $0, calendar: calendar) }
        }
        var order: Int64 = 100 * 1_024
        func task(_ title: String, _ status: TaskStatus = .todo, _ priority: TaskPriority = .none, due: DueDay? = nil,
                  tags: [String] = [], parent: UUID? = nil, completed: Date? = nil, logged: Bool = false) -> TaskItem {
            order -= 1_024
            let item = TaskItem(title: title, status: status, priority: priority, createdAt: now.addingTimeInterval(-86_400 * 3),
                                completedAt: completed, manualOrder: order, parentID: parent)
            item.dueDay = due
            item.tags = tags
            item.listOrderVersion = TaskItem.currentListOrderVersion
            if logged { item.doneLoggedAt = now }
            context.insert(item)
            return item
        }
        let launch = task("Finalize launch checklist", .inProgress, .high, due: today, tags: ["launch"])
        _ = task("Freeze strings", .done, parent: launch.id, completed: now)
        _ = task("Write release notes", parent: launch.id)
        _ = task("Tag the build", parent: launch.id)
        let ship = task("Ship appearance PR", .todo, .high)
        _ = task("Review contrast", .done, parent: ship.id, completed: now)
        _ = task("Record the preview", .done, parent: ship.id, completed: now)
        _ = task("Fix tint slider test", parent: ship.id)
        _ = task("Merge", parent: ship.id)
        _ = task("Email beta testers", .todo, .medium, due: day(3))
        _ = task("Book dentist", .todo, .low, due: day(1))
        _ = task("Call the plumber")
        _ = task("Renew domain", .done, completed: now)
        _ = task("Try the paper sketch idea", .backlog)
        _ = task("Research note templates", .backlog, tags: ["notes"])
        _ = task("Plan the spring trip", .backlog, .medium)
        for (offset, title) in [(1, "Send invoice"), (1, "Water the plants"), (2, "Call the bank"), (6, "Pay rent"), (40, "Renew passport")] {
            let completed = calendar.date(byAdding: .day, value: -offset, to: now) ?? now
            _ = task(title, .done, completed: completed, logged: true)
        }
        try context.save()
    }
}

private struct TasksPagePreviewRoot: View {
    @ObservedObject var model: TasksPageModel
    @ObservedObject var store: TaskStore
    let mode: AtticDesignContext.Mode
    @State private var addBarFocused = true
    @State private var noticeClearance = PanelPageNoticeClearancePreferenceKey.defaultValue

    var body: some View {
        GeometryReader { proxy in
            let layout = PanelPageLayout(cornerSize: 52, panelSize: proxy.size)
            TasksPage(
                model: model,
                store: store,
                layout: layout,
                addBarFocused: $addBarFocused
            )
            .background(AtticPanelStageSurface(cornerSize: 0))
            // The shell's notice stack, as in the panel: the page posts its
            // Undo toast there and reports how much room its controls take.
            .overlay(alignment: .bottom) {
                PanelNoticeStack(toasts: model.toasts, notice: nil, onRetry: {}, onDismissNotice: {})
                    .padding(.horizontal, layout.chromeInsets.leading)
                    .padding(.bottom, layout.contentInsets.bottom + noticeClearance)
            }
            .onPreferenceChange(PanelPageNoticeClearancePreferenceKey.self) { noticeClearance = $0 }
        }
        .atticDesign(AtticDesignContext(mode: mode))
        .atticWindowAppearance(mode)
        .frame(minWidth: 300, minHeight: 400)
    }
}
#endif
