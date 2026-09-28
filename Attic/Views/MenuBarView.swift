import AppKit
import SwiftUI

/// The menu-bar item's menu (spec § The shell): Show Attic, New task, New
/// note, Search, Settings and Quit, each with its shortcut. It shows no counts, so it observes no store
/// and does no work while closed.
struct MenuBarView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        AtticMenuItems(commands: MenuBarCommands.commands(
            advertisedNewTaskShortcut: advertisedGlobalShortcut,
            showPanel: coordinator.showPanel,
            newTask: coordinator.showNewTask,
            newNote: coordinator.showNewNote,
            search: coordinator.showSearch,
            openSettings: coordinator.openSettings,
            quit: { NSApp.terminate(nil) },
            openPage: coordinator.showPage,
            // Pins or unpins as the menu shows it (never a blind toggle), so
            // a second route to the same key can never undo it.
            togglePin: { [pinned = coordinator.isPanelPinned] in coordinator.setPinned(!pinned) },
            isPinned: coordinator.isPanelPinned
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
    /// New note from anywhere in Attic (round 10, audit item 12): ⌘N stays
    /// the page's own new item; ⇧⌘N is always a note. Free in the spec's
    /// key map (Notes uses ⇧⌘L and ⇧⌘K).
    static let newNoteShortcut = KeyboardShortcut("n", modifiers: [.command, .shift])
    /// Search Done Tasks from anywhere in Attic: ⌘F stays the page's own
    /// find (Done's search, Notes' All notes search). Free in the key map.
    static let searchShortcut = KeyboardShortcut("f", modifiers: [.command, .shift])
    static let pinShortcut = KeyboardShortcut("p", modifiers: [.command, .shift])

    @MainActor
    static func commands(
        advertisedNewTaskShortcut: KeyboardShortcut?,
        showPanel: @escaping () -> Void,
        newTask: @escaping () -> Void,
        newNote: @escaping () -> Void,
        search: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        quit: @escaping () -> Void,
        openPage: @escaping (PanelPage) -> Void = { _ in },
        togglePin: @escaping () -> Void = {},
        isPinned: Bool = false
    ) -> [AtticMenuCommand] {
        // Open ▸ (round 10): the pages and Pin, with the keys the panel
        // answers, so this menu lists every command there is.
        var open = PanelPage.allCases.map { page in
            AtticMenuCommand(verbatim: page.title, systemImage: page.systemName,
                             shortcut: KeyboardShortcut(page.keyEquivalent, modifiers: .command)) { openPage(page) }
        }
        open.append(AtticMenuCommand(verbatim: String(localized: "Pin Panel"), systemImage: "pin", shortcut: pinShortcut,
                                     startsSection: true, state: isPinned ? .on : .off, action: togglePin))
        return [
            AtticMenuCommand("Show Attic", systemImage: "rectangle.topthird.inset.filled", action: showPanel),
            AtticMenuCommand("New task", systemImage: "checkmark.circle", shortcut: advertisedNewTaskShortcut, startsSection: true, action: newTask),
            AtticMenuCommand("New note", systemImage: "note.text", shortcut: newNoteShortcut, action: newNote),
            // ⌘K search arrives with the command palette (a later phase);
            // until then Search opens the Tasks page's Done search, the one
            // search Phase 1 has, with the keyboard in its field, and says so.
            AtticMenuCommand("Search Done Tasks…", systemImage: "magnifyingglass", shortcut: searchShortcut, action: search),
            .submenu(String(localized: "Open"), systemImage: "rectangle.stack", startsSection: true, open),
            AtticMenuCommand("Settings…", systemImage: "gearshape", shortcut: KeyboardShortcut(",", modifiers: .command), startsSection: true, action: openSettings),
            AtticMenuCommand("Quit Attic", systemImage: "power", shortcut: KeyboardShortcut("q", modifiers: .command), startsSection: true, action: quit)
        ]
    }
}
