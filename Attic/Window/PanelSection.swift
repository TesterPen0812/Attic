import Foundation

/// Top-level surface shown in the Attic panel. Tasks and Backlog retain the
/// existing `TaskScope` semantics; Notes and Canvas own independent stores and
/// interaction state. Calendar reads tasks and calendar events, read-only.
enum PanelSection: String, CaseIterable, Hashable, Identifiable {
    case tasks
    case backlog
    case notes
    case calendar
    case canvas

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .backlog: "Later"
        case .notes: "Notes"
        case .calendar: "Calendar"
        case .canvas: "Canvas"
        }
    }

    var isNotes: Bool { self == .notes }
    /// Tasks and Backlog share the Tasks page.
    var isTaskBased: Bool { taskScope != nil }
    var isCanvas: Bool { self == .canvas }
    var isCalendar: Bool { self == .calendar }

    var taskScope: TaskScope? {
        switch self {
        case .tasks: .tasks
        case .backlog: .backlog
        case .notes, .calendar, .canvas: nil
        }
    }

    var newItemTitle: String {
        switch self {
        case .tasks: "New Task"
        case .backlog: "New Task for Later"
        case .notes: "New Note"
        case .calendar: "New Task"
        case .canvas: "Canvas"
        }
    }

    var composerPlaceholder: String {
        switch self {
        case .tasks: "What needs doing?"
        case .backlog: "Capture an idea…"
        case .notes: "Write a note…"
        case .calendar: "What needs doing?"
        case .canvas: "Draw on the canvas"
        }
    }

    var emptyStateTitle: String {
        switch self {
        case .tasks: "Nothing hiding here"
        case .backlog: "No ideas waiting"
        case .notes: "Nothing saved yet"
        case .calendar: "Nothing on this day"
        case .canvas: "Blank canvas"
        }
    }

}
