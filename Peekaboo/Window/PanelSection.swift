import Foundation

/// Top-level surface shown in the Peekaboo panel. `tasks` and `backlog` keep
/// the existing task semantics through `TaskScope`; `notes` switches the panel
/// to the notes surface. Keeping notes out of `TaskScope` avoids entangling
/// notes with task status/priority ordering and the CloudKit task pipeline.
enum PanelSection: String, CaseIterable, Identifiable {
    case tasks
    case backlog
    case notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .backlog: "Backlog"
        case .notes: "Notes"
        }
    }

    var isNotes: Bool { self == .notes }

    var taskScope: TaskScope? {
        switch self {
        case .tasks: .tasks
        case .backlog: .backlog
        case .notes: nil
        }
    }

    var newItemTitle: String {
        switch self {
        case .tasks: "New Task"
        case .backlog: "New Backlog Idea"
        case .notes: "New Note"
        }
    }

    var composerPlaceholder: String {
        switch self {
        case .tasks: "What needs doing?"
        case .backlog: "Capture an idea…"
        case .notes: "Write a note…"
        }
    }

    var emptyStateTitle: String {
        switch self {
        case .tasks: "Nothing hiding here"
        case .backlog: "No ideas waiting"
        case .notes: "Nothing saved yet"
        }
    }

    func activeSubtitle(count: Int) -> String {
        switch self {
        case .tasks: count == 1 ? "1 Active Task" : "\(count) Active Tasks"
        case .backlog: count == 1 ? "1 Idea" : "\(count) Ideas"
        case .notes: count == 1 ? "1 Note" : "\(count) Notes"
        }
    }
}
