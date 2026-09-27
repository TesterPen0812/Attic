import AppKit
import SwiftUI

/// The menu-bar item's menu (spec § The shell): Show Attic, New task, New
/// note, Search, Settings and Quit, each with its shortcut. It shows no counts, so it observes no store
/// and does no work while closed.
struct MenuBarView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var settings: AppSettings

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        settings = coordinator.settings
    }

    var body: some View {
        AtticMenuItems(commands: MenuBarCommands.commands(
            advertisedNewTaskShortcut: advertisedGlobalShortcut,
            variants: settings.reviewVariants,
            showPanel: coordinator.showPanel,
            newTask: coordinator.showNewTask,
            newNote: coordinator.showNewNote,
            search: coordinator.showSearch,
            openSettings: coordinator.openSettings,
            quit: { NSApp.terminate(nil) }
        ))
    }

    /// Only Carbon's registration makes this combination work from anywhere,
    /// and this menu is the only place it is advertised. While the system has
    /// refused it, showing the equivalent here would claim a binding that does
    /// nothing — so the command stays and the claim goes. The equivalent comes
    /// from the same combination the hot key registers, so the two cannot
    /// drift apart.
    private var advertisedGlobalShortcut: KeyboardShortcut? {
        guard coordinator.globalShortcutRegistration.isActive else { return nil }
        return coordinator.globalShortcutCombination.keyboardShortcut
    }
}

/// The menu's content, separate from the view so tests can read it.
enum MenuBarCommands {
    @MainActor
    static func commands(
        advertisedNewTaskShortcut: KeyboardShortcut?,
        variants: AtticReviewVariants = .decided,
        showPanel: @escaping () -> Void,
        newTask: @escaping () -> Void,
        newNote: @escaping () -> Void,
        search: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        quit: @escaping () -> Void
    ) -> [AtticMenuCommand] {
        [
            AtticMenuCommand("Show Attic", systemImage: "rectangle.topthird.inset.filled", action: showPanel),
            AtticMenuCommand("New task", systemImage: "checkmark.circle", shortcut: advertisedNewTaskShortcut, startsSection: true, action: newTask),
            AtticMenuCommand("New note", systemImage: "note.text", action: newNote),
            // ⌘K search arrives with the command palette (a later phase);
            // until then Search opens the Tasks page's Done search, the one
            // search Phase 1 has, with the keyboard in its field.
            // "Search Done Tasks…" with Explicit Phase 1 Labels.
            AtticMenuCommand(verbatim: AtticPhase1Labels.search(variants), systemImage: "magnifyingglass", action: search),
            AtticMenuCommand("Settings…", systemImage: "gearshape", shortcut: KeyboardShortcut(",", modifiers: .command), startsSection: true, action: openSettings),
            AtticMenuCommand("Quit Attic", systemImage: "power", shortcut: KeyboardShortcut("q", modifiers: .command), startsSection: true, action: quit)
        ]
    }
}
