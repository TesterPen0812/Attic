import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var store: TaskStore
    let coordinator: AppCoordinator

    var body: some View {
        Button("Show Attic", systemImage: "eye") {
            coordinator.showPanel()
        }

        Button("New task", systemImage: "plus") {
            coordinator.showNewTask()
        }
        .keyboardShortcut(.space, modifiers: [.control, .option])

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
}
