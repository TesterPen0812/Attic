import Foundation

@MainActor
extension DrawStore {
    func canUndo(on id: UUID) -> Bool {
        _ = revision; _ = pendingEdits
        return pending[id] == nil && !(histories[id]?.undo.isEmpty ?? true)
    }
    func canRedo(on id: UUID) -> Bool {
        _ = revision; _ = pendingEdits
        return pending[id] == nil && !(histories[id]?.redo.isEmpty ?? true)
    }
    func pinHistoryStep(_ stepID: UUID) -> AnyObject? {
        let pin = pins.pin(stepID)
        func contains(_ history: History) -> Bool {
            history.undo.contains { $0.id == stepID } || history.redo.contains { $0.id == stepID }
        }
        if let id = lastDelta?.canvas.id, let history = histories[id], contains(history) { capUndo(on: id) }
        else if let entry = histories.first(where: { contains($0.value) }) { capUndo(on: entry.key) }
        return pin
    }
    func historyMustResume() -> DrawSaveResult {
        .held(String(localized: "Undo and Redo are waiting for this drawing to finish saving."))
    }
    func undoStepID(on id: UUID) -> UUID? { histories[id]?.undo.last?.id }
    func redoStepID(on id: UUID) -> UUID? { histories[id]?.redo.last?.id }

    func undo(on id: UUID) -> DrawSaveResult {
        guard canUndo(on: id), let step = histories[id]?.undo.last else { return .unchanged }
        guard (try? state(id)) != nil else { return .held("Could not reload this canvas for Undo.") }
        return IdleLatencyTrace.span("draw_store_undo") { execute(step.reversed, action: .undo) }
    }
    func redo(on id: UUID) -> DrawSaveResult {
        guard canRedo(on: id), let step = histories[id]?.redo.last else { return .unchanged }
        guard (try? state(id)) != nil else { return .held("Could not reload this canvas for Redo.") }
        return execute(step, action: .redo)
    }

    /// Legacy pending projection, removed when global admission replaces tails.
    func projectedHistory(on id: UUID) -> History {
        var history = histories[id] ?? History()
        for edit in pending[id] ?? [] {
            switch edit.action {
            case .edit:
                for step in typingStepsPending[id]?[edit.step.id] ?? [edit.step] {
                    history.undo.append(step)
                    let excess = max(0, history.undo.count - Self.maxHistorySteps)
                    let discard = history.undo.prefix(excess).prefix { !pins.isPinned($0.id) }.count
                    history.undo.removeFirst(discard)
                }
                history.redo = []
            case .undo:
                _ = history.undo.popLast()
                history.redo.append(edit.step.reversed)
            case .redo:
                _ = history.redo.popLast()
                history.undo.append(edit.step)
                let excess = max(0, history.undo.count - Self.maxHistorySteps)
                let discard = history.undo.prefix(excess).prefix { !pins.isPinned($0.id) }.count
                history.undo.removeFirst(discard)
            }
        }
        return history
    }
    func historyChanges(on id: UUID) -> (undo: [DrawChange], redo: [DrawChange])? {
        guard recoveryIssue == nil else { return nil }
        let history = projectedHistory(on: id)
        return (history.undo.map(\.change), history.redo.map(\.change))
    }
    func acknowledgedHistoryAvailability(on id: UUID) -> (undo: Bool, redo: Bool) {
        guard let edits = pending[id] else {
            pendingAvailability[id] = nil
            return (!(histories[id]?.undo.isEmpty ?? true), !(histories[id]?.redo.isEmpty ?? true))
        }
        if let cached = pendingAvailability[id], cached.count == edits.count, cached.last == edits.last?.id {
            return (cached.undo, cached.redo)
        }
        let history = projectedHistory(on: id)
        let value = (edits.count, edits.last?.id, !history.undo.isEmpty, !history.redo.isEmpty)
        pendingAvailability[id] = value
        return (value.2, value.3)
    }
    func acknowledgeHistory(redo: Bool, on id: UUID) -> DrawSaveResult {
        guard recoveryIssue == nil else { return .held(recoveryIssue!) }
        guard pending[id] != nil else { return redo ? self.redo(on: id) : undo(on: id) }
        let history = projectedHistory(on: id)
        guard let next = redo ? history.redo.last : history.undo.last else { return .unchanged }
        let step = stamped(redo ? next : next.reversed)
        show(step)
        pending[id]?.append(Pending(step: step, action: redo ? .redo : .undo))
        let published = publishPending(id, outcome: pendingEdits[id]?.outcome ?? .retry(""))
        guard !checkpointDirty.contains(id) else { return published }
        return flush(id, head: .auto)
    }

    /// A confirmed save moves history and publishes its delta exactly once.
    func commit(_ step: Step, action: Action) -> DrawDelta {
        let id = step.change.canvasID
        switch action {
        case .edit:
            expireRedoOffers(on: id)
            appendUndo(step, on: id); histories[id]?.redo = []
        case .undo:
            _ = histories[id]?.undo.popLast()
            histories[id, default: History()].redo.append(step.reversed)
        case .redo:
            _ = histories[id]?.redo.popLast()
            appendUndo(step, on: id)
        }
        capUndo(on: id)
        revision &+= 1
        let delta = DrawDelta(canvas: step.after,
                              upserted: step.change.objectsAfter.values.filter { $0.deletedAt == nil }.sorted(by: Self.objectOrder),
                              removedIDs: step.change.objectIDs.filter { step.change.objectsAfter[$0]?.deletedAt != nil || step.change.objectsAfter[$0] == nil }.sorted { $0.uuidString < $1.uuidString },
                              revision: revision)
        lastDelta = delta
        trimCachedStates(protecting: id)
        return delta
    }
    func expireRedoOffers(on id: UUID) {
        for step in histories[id]?.redo ?? [] { pins.expire(step.id) }
    }
    func appendUndo(_ step: Step, on id: UUID) {
        histories[id, default: History()].undo.append(step)
    }
    func expireOversizedOffers(history: History, prints: [UUID: StepFootprint]? = nil) {
        guard pins.hasPins else { return }
        for stack in [history.undo, history.redo] {
            while let first = stack.firstIndex(where: { pins.isPinned($0.id) }) {
                let suffix = stack[first...]
                if suffix.count > Self.maxHistorySteps { pins.expire(stack[first].id); continue }
                guard let prints else { break }
                var footprint = HistoryLedger()
                for step in suffix { if let measured = prints[step.id] { footprint.add(measured) } }
                if footprint.total > Self.maxProtectedHistoryBytes { pins.expire(stack[first].id); continue }
                break
            }
        }
    }
    func capUndo(on id: UUID) {
        if let history = histories[id] { expireOversizedOffers(history: history) }
        let removable: Int = {
            guard let stack = histories[id]?.undo, stack.count > Self.maxHistorySteps else { return 0 }
            let excess = stack.count - Self.maxHistorySteps
            return stack.prefix(excess).prefix { !pins.isPinned($0.id) }.count
        }()
        if removable > 0 { histories[id]?.undo.removeFirst(removable) }
    }
}
