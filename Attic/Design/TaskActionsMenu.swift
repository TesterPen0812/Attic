import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Shared context-menu content for a task: edit, copy, priority, move, delete.
struct TaskActionsMenu: View {
    @ObservedObject var store: TaskStore
    let task: TaskItem
    var editLabel = "Edit"
    var deleteRequested: (() -> Void)? = nil
    var statusRequested: ((TaskStatus) -> Void)? = nil
    let edit: () -> Void

    var body: some View {
        Button(editLabel, systemImage: "pencil", action: edit)

        Button("Copy", systemImage: "doc.on.doc", action: copyTitle)

        Menu("Priority") {
            ForEach(TaskPriority.allCases.reversed()) { priority in
                Button {
                    store.setPriority(priority, for: task)
                } label: {
                    if task.priority == priority {
                        Label(priority.title, systemImage: "checkmark")
                    } else {
                        Text(priority.title)
                    }
                }
            }
        }

        Menu("Move to") {
            ForEach(TaskStatus.moveMenuOrder) { status in
                Button {
                    if let statusRequested { statusRequested(status) }
                    else { store.setStatus(status, for: task) }
                } label: {
                    if task.status == status {
                        Label(status.title, systemImage: "checkmark")
                    } else {
                        Text(status.title)
                    }
                }
            }
        }

        Divider()

        Button(store.subtasks(of: task.id).isEmpty ? "Delete" : "Delete task and subtasks", systemImage: "trash", role: .destructive) {
            if let deleteRequested { deleteRequested() }
            else { store.delete(task) }
        }
    }

    private func copyTitle() {
        #if canImport(UIKit)
        UIPasteboard.general.string = task.title
        #else
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(task.title, forType: .string)
        #endif
    }
}
