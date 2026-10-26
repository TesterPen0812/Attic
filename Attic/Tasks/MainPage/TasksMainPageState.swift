import Combine
import Foundation

// The New list style's main page, part 2 (council direction D2 "Pick your
// Now", owner 2026-10-26): the card in place (pick 3A), picking into Now,
// the Due line, and Find across every list. Only the New style draws any of
// it; the Attic and Reminders styles never reach this state.

/// The task opened in place (3A): one at a time, in the list, or grown to
/// fill the list area (⌘↩). Shrinking returns to the same row and scroll.
struct TasksCardPlace: Equatable {
    let taskID: UUID
    /// The list it opened in (a result of Find opens in the results).
    let tab: TasksTab
    var isFull = false
}

/// The Due line above Now (D2): only when a task outside Now (in Later) is
/// due today or overdue.
enum TasksDueLine: Equatable {
    case none
    /// "Pay the electricity bill · Late 23 Oct · waiting in Later" + Pick.
    case one(id: UUID, title: String, due: DueDay)
    /// "N due in Later" + Pick.
    case several(count: Int)

    /// Later's open main tasks due on or before `today`, in Later's order.
    static func dueTasks(in later: [TaskItem], today: DueDay) -> [TaskItem] {
        later.filter { task in
            guard task.parentID == nil, task.deletedAt == nil, task.status == .backlog,
                  let day = task.dueDay else { return false }
            return day <= today
        }
    }

    static func make(later: [TaskItem], today: DueDay) -> TasksDueLine {
        let due = dueTasks(in: later, today: today)
        switch due.count {
        case 0: return .none
        case 1: return due[0].dueDay.map { .one(id: due[0].id, title: due[0].title, due: $0) } ?? .none
        default: return .several(count: due.count)
        }
    }
}

/// Pick mode (D2): Later opens with a ＋ on every task, due ones first.
/// Done and Esc both leave and keep the picks.
struct TasksPickSession: Equatable {
    /// In the order they were picked: that is the order they join Now in.
    private(set) var picked: [UUID] = []

    var count: Int { picked.count }

    func isPicked(_ id: UUID) -> Bool { picked.contains(id) }

    mutating func toggle(_ id: UUID) {
        if let index = picked.firstIndex(of: id) { picked.remove(at: index) } else { picked.append(id) }
    }

    /// Pick mode's two groups: DUE (today or overdue) first, then LATER,
    /// each in Later's own order.
    static func groups(_ later: [TaskItem], today: DueDay) -> (due: [TaskItem], later: [TaskItem]) {
        let due = Set(TasksDueLine.dueTasks(in: later, today: today).map(\.id))
        return (later.filter { due.contains($0.id) }, later.filter { !due.contains($0.id) })
    }
}

/// Find across every list (FINAL §3): the header's tabs become the field;
/// ✕ or Esc gives back the list, scroll and selection that were left.
struct TasksFindSession: Equatable {
    enum Scope: Equatable { case allLists, thisList }

    var query = ""
    var scope = Scope.allLists
    /// What Esc restores.
    let originTab: TasksTab
    let originSelection: Set<UUID>
    let originScrollAnchor: UUID?

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The lists the scope reaches.
    var tabs: [TasksTab] { scope == .allLists ? [.now, .backlog, .done] : [originTab] }
}

/// Results, grouped NOW · n, LATER · n, DONE · n (a list the scope leaves
/// out is not shown; an empty one in scope shows its zero).
struct TasksFindResults: Equatable {
    struct Group: Equatable, Identifiable {
        let tab: TasksTab
        let ids: [UUID]
        var id: TasksTab { tab }
        var title: String {
            let name = switch tab {
            case .now: String(localized: "NOW")
            case .backlog: String(localized: "LATER")
            case .done: String(localized: "DONE")
            }
            return "\(name) · \(ids.count)"
        }
    }

    var groups: [Group] = []
    var isEmpty: Bool { groups.allSatisfy(\.ids.isEmpty) }
    var allIDs: [UUID] { groups.flatMap(\.ids) }
}

/// The main page's own state, apart from the shared page model so the other
/// styles' rows never redraw for it.
@MainActor
final class TasksMainPageState: ObservableObject {
    @Published var card: TasksCardPlace?
    /// The writing the open card shows (nil while it loads).
    @Published var cardWriting: TaskNoteWriting.Snapshot?
    @Published var pick: TasksPickSession?
    /// Tasks just picked: tinted in Now until the next action.
    @Published var justPicked: Set<UUID> = []
    @Published var find: TasksFindSession?
    /// The quick-capture hotkey opened the add bar: what it adds files into
    /// Later (D2: nothing lands in Now by itself).
    @Published var captureIntoLater = false
    /// Bumped to ask the list to scroll to a row (the card's return).
    @Published var scrollRequest: (id: UUID, serial: Int)?

    struct DueKey: Equatable {
        let revision: UInt64
        let today: DueDay
    }

    var dueCache: (key: DueKey, line: TasksDueLine)?

    struct FindKey: Equatable {
        let revision: UInt64
        let query: String
        let scope: TasksFindSession.Scope
        let origin: TasksTab
    }

    var findCache: (key: FindKey, results: TasksFindResults)?
    /// Where the list stood when the card grew to full (shrink returns there).
    var fullReturnAnchor: UUID?
    private var scrollSerial = 0

    func requestScroll(to id: UUID) {
        scrollSerial &+= 1
        scrollRequest = (id, scrollSerial)
    }

    /// The next local midnight: the Due line is computed again then.
    static func nextMidnight(after date: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
    }
}
