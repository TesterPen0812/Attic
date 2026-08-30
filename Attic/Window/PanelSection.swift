import Foundation

/// Top-level surface shown in the Attic panel. Tasks and Backlog retain the
/// existing `TaskScope` semantics; Notes and Canvas own independent stores and
/// interaction state.
enum PanelSection: String, CaseIterable, Hashable, Identifiable {
    case tasks
    case backlog
    case notes
    case canvas

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .backlog: "Backlog"
        case .notes: "Notes"
        case .canvas: "Canvas"
        }
    }

    var isNotes: Bool { self == .notes }
    var isCanvas: Bool { self == .canvas }

    var taskScope: TaskScope? {
        switch self {
        case .tasks: .tasks
        case .backlog: .backlog
        case .notes, .canvas: nil
        }
    }

    var newItemTitle: String {
        switch self {
        case .tasks: "New Task"
        case .backlog: "New Backlog Idea"
        case .notes: "New Note"
        case .canvas: "Canvas"
        }
    }

    var composerPlaceholder: String {
        switch self {
        case .tasks: "What needs doing?"
        case .backlog: "Capture an idea…"
        case .notes: "Write a note…"
        case .canvas: "Draw on the canvas"
        }
    }

    var emptyStateTitle: String {
        switch self {
        case .tasks: "Nothing hiding here"
        case .backlog: "No ideas waiting"
        case .notes: "Nothing saved yet"
        case .canvas: "Blank canvas"
        }
    }

    func activeSubtitle(count: Int) -> String {
        switch self {
        case .tasks: count == 1 ? "1 Active Task" : "\(count) Active Tasks"
        case .backlog: count == 1 ? "1 Idea" : "\(count) Ideas"
        case .notes: count == 1 ? "1 Note" : "\(count) Notes"
        case .canvas: count == 1 ? "1 Stroke" : "\(count) Strokes"
        }
    }
}
