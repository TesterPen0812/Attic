import Combine
import Foundation

/// A named undo history: each page keeps its own for the session.
enum UndoHistoryID: Hashable {
    /// The Tasks list.
    case tasks
    case note(UUID)
    case canvas(UUID)
    /// Changes made across pages from one place (tag management, Recently
    /// Deleted), which belong to no single page.
    case library
}

/// One undoable step: how to reverse it and how to apply it again. Each
/// closure returns whether the store confirmed its save.
struct UndoStep {
    let name: String
    let undo: @MainActor () -> Bool
    let redo: @MainActor () -> Bool
}

/// The single undo route. Keys, menus, toolbars and agents all call these
/// methods, so there is one history per page and one way through it (audit
/// CVD-06). A step is recorded only after the store confirmed the change;
/// an undo or redo whose store call fails leaves the history exactly as it
/// was (audit CVD-02). Histories live here, not in views, so releasing a view
/// loses nothing.
@MainActor
final class UndoRoute: ObservableObject {
    private struct History {
        var undo: [UndoStep] = []
        var redo: [UndoStep] = []
    }

    nonisolated static let defaultLimit = 100

    /// Bumped whenever any history changes, for menus that show names.
    @Published private(set) var revision: UInt64 = 0
    private var histories: [UndoHistoryID: History] = [:]
    private let limit: Int

    init(limit: Int = UndoRoute.defaultLimit) {
        self.limit = max(1, limit)
    }

    /// Runs `change` and, only when it returns a step (the store saved),
    /// records that step and clears the history's redo list. Returns whether
    /// the change happened.
    @discardableResult
    func perform(in history: UndoHistoryID, _ change: () -> UndoStep?) -> Bool {
        guard let step = change() else { return false }
        record(step, in: history)
        return true
    }

    /// Records a step for a change that has already been confirmed.
    func record(_ step: UndoStep, in history: UndoHistoryID) {
        var entry = histories[history] ?? History()
        entry.undo.append(step)
        if entry.undo.count > limit { entry.undo.removeFirst(entry.undo.count - limit) }
        entry.redo.removeAll()
        histories[history] = entry
        revision &+= 1
    }

    @discardableResult
    func undo(in history: UndoHistoryID) -> Bool {
        guard var entry = histories[history], let step = entry.undo.last else { return false }
        guard step.undo() else { return false }
        entry.undo.removeLast()
        entry.redo.append(step)
        histories[history] = entry
        revision &+= 1
        return true
    }

    @discardableResult
    func redo(in history: UndoHistoryID) -> Bool {
        guard var entry = histories[history], let step = entry.redo.last else { return false }
        guard step.redo() else { return false }
        entry.redo.removeLast()
        entry.undo.append(step)
        histories[history] = entry
        revision &+= 1
        return true
    }

    func canUndo(in history: UndoHistoryID) -> Bool {
        histories[history]?.undo.isEmpty == false
    }

    func canRedo(in history: UndoHistoryID) -> Bool {
        histories[history]?.redo.isEmpty == false
    }

    /// "Undo Delete Task" in menus reads this.
    func undoName(in history: UndoHistoryID) -> String? {
        histories[history]?.undo.last?.name
    }

    func redoName(in history: UndoHistoryID) -> String? {
        histories[history]?.redo.last?.name
    }

    func undoCount(in history: UndoHistoryID) -> Int {
        histories[history]?.undo.count ?? 0
    }

    func clear(_ history: UndoHistoryID) {
        guard histories.removeValue(forKey: history) != nil else { return }
        revision &+= 1
    }
}
