import Foundation

@MainActor
extension DrawStore {
    private struct AgentUndoSeal: Codable {
        let step: Step
        let saved: DrawSnapshot
    }

    func agentUndoProof(on id: UUID, stepID: UUID) -> Data? {
        guard pending[id] == nil, recoveryIssue == nil,
              let step = histories[id]?.undo.last, step.id == stepID,
              let saved = try? open(id) else { return nil }
        return try? JSONEncoder().encode(AgentUndoSeal(step: step, saved: saved))
    }

    func undoAgentStep(on id: UUID, proof: Data) -> DrawSaveResult {
        guard let seal = try? JSONDecoder().decode(AgentUndoSeal.self, from: proof),
              seal.step.change.canvasID == id, pending[id] == nil, recoveryIssue == nil else {
            return .held("Draw has changed or refused Undo")
        }
        // Never consume an owner's newer same-session history entry.
        if let currentHead = undoStepID(on: id), currentHead != seal.step.id,
           currentHead != agentReplayHeads[id] {
            return .held("Draw has changed or refused Undo")
        }
        guard let persisted = try? repository.load(id),
              persisted.canvas == seal.saved.canvas,
              persisted.objects.filter({ $0.deletedAt == nil }).sorted(by: Self.objectOrder) == seal.saved.objects
        else { return .held("Draw has changed or refused Undo") }
        guard repository.matchesAgentUndoPrestate(seal.step.change.reversed) else {
            return .held("Draw has divergent physical replicas; reconcile them before Undo")
        }
        let cacheMatchesStore = states[id].map { cached in
            cached.persisted && cached.canvas == persisted.canvas &&
                cached.objects.count == persisted.objects.count &&
                persisted.objects.allSatisfy { cached.objects[$0.id] == $0 }
        } ?? false
        if !cacheMatchesStore {
            do { try reload(id) }
            catch { return .held("Draw has changed or refused Undo") }
            guard (try? open(id)) == seal.saved else { return .held("Draw has changed or refused Undo") }
        }
        // The original sparse inverse is validated against every physical copy.
        var inverse = seal.step.reversed
        inverse.id = UUID()
        let result = execute(inverse, action: .edit)
        if result.isSaved { agentReplayHeads[id] = undoStepID(on: id) }
        return result
    }
}
