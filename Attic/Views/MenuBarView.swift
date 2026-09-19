import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        Button("Show Attic", systemImage: "eye") {
            coordinator.showPanel()
        }

        Button("New task", systemImage: "plus") {
            coordinator.showNewTask()
        }
        .keyboardShortcut(advertisedGlobalShortcut)

        Button("New note", systemImage: "note.text") {
            coordinator.showNewNote()
        }

        Divider()

        HStack {
            Text("Active Tasks")
            Spacer()
            Text("\(activeTaskCount)")
                .foregroundStyle(.secondary)
        }

        HStack {
            Text("Notes")
            Spacer()
            Text("\(coordinator.noteStore.notes.count)")
                .foregroundStyle(.secondary)
        }

        Button {
            coordinator.openSettings()
        } label: {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Attic", systemImage: "power") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var activeTaskCount: Int {
        store.snapshot(for: .tasks).activeCount
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
