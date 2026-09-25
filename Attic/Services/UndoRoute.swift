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

/// What happened when a step was undone or redone.
enum UndoOutcome: Equatable {
    /// The store confirmed the change.
    case applied
    /// The store refused or failed to save; nothing changed and the step can
    /// be tried again (a full disk, a replica conflict someone can resolve).
    case failed
    /// The step can never apply again: what it changes is gone (removed for
    /// good, in Recently Deleted, or changed since on every field it
    /// touches). The route drops it so it cannot block the steps before it.
    case obsolete
}

/// One undoable step: how to reverse it and how to apply it again.
struct UndoStep {
    /// Which step this is, so something bound to it (the Undo toast) can
    /// tell whether it is still the one an undo would reverse.
    let id = UUID()
    let name: String
    let undo: @MainActor () -> UndoOutcome
    let redo: @MainActor () -> UndoOutcome

    /// A step whose closures only report whether the store confirmed its
    /// save; a refusal keeps the step.
    init(name: String, undo: @escaping @MainActor () -> Bool, redo: @escaping @MainActor () -> Bool) {
        self.name = name
        self.undo = { undo() ? .applied : .failed }
        self.redo = { redo() ? .applied : .failed }
    }

    /// A step that can tell a failure worth retrying from one that can never
    /// apply again.
    init(
        name: String,
        undoOutcome: @escaping @MainActor () -> UndoOutcome,
        redoOutcome: @escaping @MainActor () -> UndoOutcome
    ) {
        self.name = name
        self.undo = undoOutcome
        self.redo = redoOutcome
    }
}

/// The single undo route. Keys, menus, toolbars and agents all call these
/// methods, so there is one history per page and one way through it (audit
/// CVD-06). A step is recorded only after the store confirmed the change;
/// an undo or redo whose store call fails leaves the history exactly as it
/// was (audit CVD-02). A step that can never apply again (`.obsolete`) is
/// dropped instead, so it never blocks the steps before it. Histories live
/// here, not in views, so releasing a view loses nothing.
@MainActor
final class UndoRoute: ObservableObject {
    private struct History {
        var undo: [UndoStep] = []
        var redo: [UndoStep] = []
    }

    nonisolated static let defaultLimit = 100
    /// Steps kept across every history together.
    nonisolated static let defaultTotalLimit = 400
    /// Histories kept at once (the Tasks list plus recently used notes and
    /// canvases).
    nonisolated static let defaultHistoryLimit = 24

    /// Bumped whenever any history changes, for menus that show names.
    @Published private(set) var revision: UInt64 = 0
    private var histories: [UndoHistoryID: History] = [:]
    /// Least recently used first; the last one is the page in use.
    private var recency: [UndoHistoryID] = []
    private let limit: Int
    private let totalLimit: Int
    private let historyLimit: Int

    /// Memory stays bounded across the session: each history keeps at most
    /// `limit` steps, and when all histories together exceed `totalLimit`
    /// steps or `historyLimit` histories, whole histories of the pages used
    /// least recently are dropped. The page in use always keeps its complete
    /// sequence, so undo there never skips a step.
    init(
        limit: Int = UndoRoute.defaultLimit,
        totalLimit: Int = UndoRoute.defaultTotalLimit,
        historyLimit: Int = UndoRoute.defaultHistoryLimit
    ) {
        self.limit = max(1, limit)
        self.totalLimit = max(self.limit, totalLimit)
        self.historyLimit = max(1, historyLimit)
    }

    /// Histories currently kept, least recently used first.
    var retainedHistories: [UndoHistoryID] { recency }

    var totalStepCount: Int {
        histories.values.reduce(0) { $0 + $1.undo.count + $1.redo.count }
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
        touch(history)
        evictInactiveHistories()
        revision &+= 1
    }

    /// Undoes the history's last step. Returns whether it applied; a step
    /// that failed stays, one that can never apply again is dropped (and the
    /// next undo reaches the step before it).
    @discardableResult
    func undo(in history: UndoHistoryID) -> Bool {
        guard var entry = histories[history], let step = entry.undo.last else { return false }
        switch step.undo() {
        case .failed:
            return false
        case .obsolete:
            entry.undo.removeLast()
            histories[history] = entry
            revision &+= 1
            return false
        case .applied:
            entry.undo.removeLast()
            entry.redo.append(step)
            histories[history] = entry
            touch(history)
            revision &+= 1
            return true
        }
    }

    @discardableResult
    func redo(in history: UndoHistoryID) -> Bool {
        guard var entry = histories[history], let step = entry.redo.last else { return false }
        switch step.redo() {
        case .failed:
            return false
        case .obsolete:
            entry.redo.removeLast()
            histories[history] = entry
            revision &+= 1
            return false
        case .applied:
            entry.redo.removeLast()
            entry.undo.append(step)
            histories[history] = entry
            touch(history)
            revision &+= 1
            return true
        }
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

    /// The step an undo would reverse now.
    func undoStepID(in history: UndoHistoryID) -> UUID? {
        histories[history]?.undo.last?.id
    }

    func undoCount(in history: UndoHistoryID) -> Int {
        histories[history]?.undo.count ?? 0
    }

    func clear(_ history: UndoHistoryID) {
        guard histories.removeValue(forKey: history) != nil else { return }
        recency.removeAll { $0 == history }
        revision &+= 1
    }

    private func touch(_ history: UndoHistoryID) {
        recency.removeAll { $0 == history }
        recency.append(history)
    }

    private func evictInactiveHistories() {
        while recency.count > 1,
              recency.count > historyLimit || totalStepCount > totalLimit {
            histories.removeValue(forKey: recency.removeFirst())
        }
    }
}
