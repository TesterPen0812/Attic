import Combine
import Foundation

/// A named undo history: each page keeps its own for the session.
enum UndoHistoryID: Hashable {
    /// The Tasks list.
    case tasks
    /// The task workspace exists before its own note is first saved.
    case taskWorkspace(UUID)
    case note(UUID)
    case canvas(UUID)
    /// Changes made across pages from one place (tag management, Recently
    /// Deleted), which belong to no single page.
    case library
    /// The Notes page's All notes: pin, duplicate and delete of a note
    /// (⌘Z / ⇧⌘Z while the library has focus). Apart from `.library` so
    /// Settings' Recently Deleted and tag changes never mix with it.
    case notesLibrary
}

/// What happened when a step was undone or redone.
enum UndoOutcome: Equatable, Error {
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
    let id: UUID
    let name: String
    let undo: @MainActor () -> UndoOutcome
    let redo: @MainActor () -> UndoOutcome
    var workspacePayload: WorkspaceHistory.TextGroup? = nil
    var operationID: UUID? = nil
    var attachmentIDs: Set<UUID> = []
    var replay: (@MainActor (Bool, @escaping @MainActor () throws -> Void) async -> UndoOutcome)? = nil

    /// A step whose closures only report whether the store confirmed its
    /// save; a refusal keeps the step.
    init(id: UUID = UUID(), name: String, undo: @escaping @MainActor () -> Bool, redo: @escaping @MainActor () -> Bool) {
        self.id = id
        self.name = name
        self.undo = { undo() ? .applied : .failed }
        self.redo = { redo() ? .applied : .failed }
    }

    /// A step that can tell a failure worth retrying from one that can never
    /// apply again.
    init(
        id: UUID = UUID(),
        name: String,
        undoOutcome: @escaping @MainActor () -> UndoOutcome,
        redoOutcome: @escaping @MainActor () -> UndoOutcome
    ) {
        self.id = id
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
    let ownershipID = UUID()
    private var workspaces: [UndoHistoryID: WorkspaceHistory] = [:]
    private var aliases: [UndoHistoryID: UndoHistoryID] = [:]
    private var replaying: Set<UndoHistoryID> = []
    var onOwnershipChanged: (() -> Void)?
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

    /// Steps recorded while `capturingSteps` runs go to its caller instead
    /// of a history: a field's commit (`WorkspaceFieldUndo.commit`) hands the
    /// one confirmed step to the workspace history itself.
    private var captures: [(UndoStep) -> Void] = []

    /// Runs `change` and returns the steps it would have recorded, without
    /// recording them.
    func capturingSteps(_ change: () -> Void) -> [UndoStep] {
        var steps: [UndoStep] = []
        captures.append { steps.append($0) }
        defer { captures.removeLast() }
        change()
        return steps
    }

    /// Records a step for a change that has already been confirmed.
    func record(_ step: UndoStep, in history: UndoHistoryID) {
        if let capture = captures.last { capture(step); return }
        let history = resolved(history)
        var entry = histories[history] ?? History()
        entry.undo.append(step)
        if entry.undo.count > limit { entry.undo.removeFirst(entry.undo.count - limit) }
        entry.redo.removeAll()
        histories[history] = entry
        touch(history)
        evictInactiveHistories()
        revision &+= 1
        onOwnershipChanged?()
    }

    /// Undoes the history's last step. Returns whether it applied; a step
    /// that failed stays, one that can never apply again is dropped (and the
    /// next undo reaches the step before it).
    @discardableResult
    func undo(in history: UndoHistoryID) -> Bool {
        undoStep(in: history) == .applied
    }

    @discardableResult
    func redo(in history: UndoHistoryID) -> Bool {
        redoStep(in: history) == .applied
    }

    /// `undo(in:)` with what happened: nil when there was nothing to undo.
    @discardableResult
    func undoStep(in history: UndoHistoryID) -> UndoOutcome? {
        let history = resolved(history)
        guard !replaying.contains(history), var entry = histories[history], let step = entry.undo.last, step.replay == nil else { return nil }
        let outcome = step.undo()
        switch outcome {
        case .failed:
            break
        case .obsolete:
            entry.undo.removeLast()
            histories[history] = entry
            revision &+= 1
        onOwnershipChanged?()
        case .applied:
            entry.undo.removeLast()
            entry.redo.append(step)
            histories[history] = entry
            touch(history)
            revision &+= 1
        onOwnershipChanged?()
        }
        return outcome
    }

    /// `redo(in:)` with what happened: nil when there was nothing to redo.
    @discardableResult
    func redoStep(in history: UndoHistoryID) -> UndoOutcome? {
        let history = resolved(history)
        guard !replaying.contains(history), var entry = histories[history], let step = entry.redo.last, step.replay == nil else { return nil }
        let outcome = step.redo()
        switch outcome {
        case .failed:
            break
        case .obsolete:
            entry.redo.removeLast()
            histories[history] = entry
            revision &+= 1
        onOwnershipChanged?()
        case .applied:
            entry.redo.removeLast()
            entry.undo.append(step)
            histories[history] = entry
            touch(history)
            revision &+= 1
        onOwnershipChanged?()
        }
        return outcome
    }

    func canUndo(in history: UndoHistoryID) -> Bool {
        let history = resolved(history)
        return histories[history]?.undo.isEmpty == false
    }

    func canRedo(in history: UndoHistoryID) -> Bool {
        let history = resolved(history)
        return histories[history]?.redo.isEmpty == false
    }

    /// "Undo Delete Task" in menus reads this.
    func undoName(in history: UndoHistoryID) -> String? {
        let history = resolved(history)
        return histories[history]?.undo.last.map { $0.workspacePayload?.payloads.last?.name ?? $0.name }
    }

    func redoName(in history: UndoHistoryID) -> String? {
        let history = resolved(history)
        return histories[history]?.redo.last.map { $0.workspacePayload?.payloads.first?.name ?? $0.name }
    }

    /// The step an undo would reverse now.
    func undoStepID(in history: UndoHistoryID) -> UUID? {
        let history = resolved(history)
        return histories[history]?.undo.last?.id
    }

    func undoCount(in history: UndoHistoryID) -> Int {
        let history = resolved(history)
        return histories[history]?.undo.count ?? 0
    }

    func clear(_ history: UndoHistoryID) {
        let history = resolved(history)
        guard histories.removeValue(forKey: history) != nil else { return }
        recency.removeAll { $0 == history }
        revision &+= 1
        onOwnershipChanged?()
    }

    func workspace(for key: UndoHistoryID) -> WorkspaceHistory {
        let key = resolved(key)
        if let existing = workspaces[key] { return existing }
        let workspace = WorkspaceHistory(route: self, historyID: key)
        workspaces[key] = workspace
        return workspace
    }

    /// Aliasing never merges independently ordered histories. A note created
    /// lazily and later detached keeps the existing sequence and step identities.
    @discardableResult
    func alias(_ alias: UndoHistoryID, to target: UndoHistoryID) -> Bool {
        let target = resolved(target), current = resolved(alias)
        if current == target { return true }
        guard histories[current] == nil, !replaying.contains(current) else { return false }
        aliases[alias] = target
        return true
    }

    /// Move the existing task workspace to its ordinary-note identity. Keep
    /// cursor, entries, replay rights and all old aliases; never merge histories.
    func rekey(_ workspace: WorkspaceHistory, to key: UndoHistoryID) -> Bool {
        let old = resolved(workspace.historyID), destination = resolved(key)
        if old == key { return true }
        guard workspaces[old] === workspace, !replaying.contains(old),
              destination == old || (histories[destination] == nil && workspaces[destination] == nil),
              histories[key] == nil, workspaces[key] == nil else { return false }
        let reflected = aliases.keys.filter { resolved($0) == old }
        if let value = histories.removeValue(forKey: old) { histories[key] = value }
        workspaces.removeValue(forKey: old); workspaces[key] = workspace
        recency = recency.map { $0 == old ? key : $0 }
        for alias in reflected where alias != key { aliases[alias] = key }
        aliases.removeValue(forKey: key); aliases[old] = key
        workspace.didRekey(to: key)
        revision &+= 1; onOwnershipChanged?()
        return true
    }

    private func resolved(_ key: UndoHistoryID) -> UndoHistoryID {
        var key = key
        var seen = Set<UndoHistoryID>()
        while let next = aliases[key], seen.insert(key).inserted { key = next }
        return key
    }

    struct Checkpoint {
        fileprivate let key: UndoHistoryID
        fileprivate let undo: [UndoStep]
        fileprivate let redo: [UndoStep]
    }
    func checkpoint(in history: UndoHistoryID) -> Checkpoint {
        let key = resolved(history), value = histories[key] ?? History()
        return Checkpoint(key: key, undo: value.undo, redo: value.redo)
    }
    func rewind(to checkpoint: Checkpoint) {
        let key = resolved(checkpoint.key)
        guard !replaying.contains(key) else { return }
        histories[key] = History(undo: checkpoint.undo, redo: checkpoint.redo)
        touch(key)
        revision &+= 1
        onOwnershipChanged?()
    }
    func steps(in history: UndoHistoryID, redo: Bool) -> [UndoStep] {
        let value = histories[resolved(history)] ?? History()
        return redo ? value.redo : value.undo
    }
    var referencedOperationIDs: Set<UUID> {
        Set(histories.values.flatMap { ($0.undo + $0.redo).compactMap(\.operationID) })
    }
    var referencedAttachmentIDs: Set<UUID> {
        histories.values.reduce(into: Set<UUID>()) { ids, history in
            for step in history.undo + history.redo {
                ids.formUnion(step.attachmentIDs)
                if let payload = step.workspacePayload { ids.formUnion(payload.attachmentIDs) }
            }
        }
    }
    func isReplaying(in history: UndoHistoryID) -> Bool { replaying.contains(resolved(history)) }

    /// The replay's receipt carries this cursor effect. Its first publication
    /// step commits the cursor, even when a later editor/index step fails. The
    /// pending gate refuses a second inverse; retry runs publication only.
    @discardableResult
    func replay(in history: UndoHistoryID, redo: Bool) async -> UndoOutcome? {
        let key = resolved(history)
        guard !replaying.contains(key), let entry = histories[key],
              let step = (redo ? entry.redo : entry.undo).last else { return nil }
        guard let replay = step.replay else {
            return redo ? redoStep(in: key) : undoStep(in: key)
        }
        replaying.insert(key)
        defer { replaying.remove(key) }
        var committed = false
        let outcome = await replay(redo, { [self] in
            if committed { return }
            guard var current = histories[key],
                  (redo ? current.redo : current.undo).last?.id == step.id else {
                throw WorkspaceFoundationError.conflict
            }
            if redo { current.redo.removeLast(); current.undo.append(step) }
            else { current.undo.removeLast(); current.redo.append(step) }
            histories[key] = current
            committed = true
            revision &+= 1
            onOwnershipChanged?()
        })
        return committed ? .applied : outcome
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
