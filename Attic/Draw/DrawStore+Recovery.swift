import Foundation

@MainActor
extension DrawStore {
    struct RecoveryLoadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A complete saved base is required before applying any sparse recovery
    /// patch. A failed read is not an absent canvas and is never cached as one.
    func recoverDrafts() {
        guard let recovery, recovery.issue == nil else {
            refreshRecoveryIssue()
            return
        }
        for (id, record) in recovery.records { recoverDraft(id, record: record) }
        refreshRecoveryIssue()
    }

    func refreshRecoveryIssue() {
        recoveryIssue = recovery?.issue ?? recoveryLoadFailures.sorted { $0.key.uuidString < $1.key.uuidString }.first?.value
    }

    func recoverDraft(_ id: UUID, record: DrawRecoveryJournal.Record) {
        guard let first = record.edits.first else { return }
        // Retain the original record and ownership even if the full load fails.
        pending[id] = record.edits
        if record.unattempted { unsubmittedHeads.insert(id) }
        recoveredCanvasIDs.insert(id)
        do {
            if let saved = try repository.load(id) {
                states[id] = State(canvas: saved.canvas,
                    objects: Dictionary(uniqueKeysWithValues: saved.objects.map { ($0.id, $0) }), persisted: true)
            } else {
                // Only a genuinely never-saved, initially empty canvas has an
                // absent base. objectsBefore is a sparse patch, not a snapshot.
                guard !first.step.beforePersisted, first.step.change.before == nil,
                      first.step.change.objectsBefore.isEmpty else { throw DrawStoreError.missingCanvas }
                states[id] = State(canvas: first.step.before)
            }
            recoveryLoadFailures[id] = nil
            for edit in record.edits { show(edit.step) }
            let result: DrawWriteOutcome = record.unattempted
                ? .retry("The recovered next edit has not been saved. Retry when ready.")
                : repository.reconcile(first.step.change)
            switch result {
            case .committed:
                pending[id]?.removeFirst()
                if pending[id]?.isEmpty == true {
                    pending[id] = nil
                    pendingEdits[id] = nil
                    recoveredCanvasIDs.remove(id)
                    unsubmittedHeads.remove(id)
                } else {
                    unsubmittedHeads.insert(id)
                    let next = pending[id]!
                    pendingEdits[id] = DrawPendingEdit(
                        canvas: next.last!.step.after, objects: states[id]?.snapshot.objects ?? [],
                        outcome: .retry("The recovered next edit has not been saved. Retry when ready."), count: next.count)
                }
                try? recovery?.update(id, edits: pending[id], proof: nil, unattempted: pending[id] != nil)
            case let .retry(message):
                pendingEdits[id] = DrawPendingEdit(
                    canvas: record.edits.last!.step.after, objects: states[id]?.snapshot.objects ?? [],
                    outcome: .retry(message), count: record.edits.count)
            case let .held(message):
                pendingEdits[id] = DrawPendingEdit(
                    canvas: record.edits.last!.step.after, objects: states[id]?.snapshot.objects ?? [],
                    outcome: .held(message), count: record.edits.count)
            }
        } catch {
            // Do not publish an empty objects array as a pending projection.
            // The board's ordinary throwing open route displays the load error.
            states[id] = nil
            pendingEdits[id] = nil
            recoveryLoadFailures[id] = "Could not load this drawing. Its recovery data has been preserved. Retry to load it."
            pendingGeneration &+= 1
        }
        refreshRecoveryIssue()
    }

    func retryRecoveryLoad(on id: UUID) -> DrawSaveResult? {
        guard recoveryLoadFailures[id] != nil else { return nil }
        guard let record = recovery?.records[id] else {
            return .held("The drawing recovery record could not be read. Its files have been preserved.")
        }
        recoverDraft(id, record: record)
        if let message = recoveryLoadFailures[id] { return .held(message) }
        return nil
    }

    func retry(on id: UUID) -> DrawSaveResult {
        if let failure = retryRecoveryLoad(on: id) { return failure }
        guard pending[id] != nil else { return .unchanged }
        guard case .retry = pendingEdits[id]?.outcome else {
            return .held("The stored state needs reconciliation before Retry.")
        }
        return flush(id, head: .write)
    }
    func reconcile(on id: UUID) -> DrawSaveResult {
        if let failure = retryRecoveryLoad(on: id) { return failure }
        guard pending[id] != nil else { return .unchanged }
        return flush(id, head: .reconcile)
    }

    /// Retained history follows the latest quiet thumbnail, not an old one.
    func stamped(_ step: Step) -> Step {
        var step = step
        let thumbnail = states[step.change.canvasID]?.canvas.thumbnail
        let dark = states[step.change.canvasID]?.canvas.thumbnailDark
        step.before.thumbnail = thumbnail; step.before.thumbnailDark = dark
        step.after.thumbnail = thumbnail; step.after.thumbnailDark = dark
        if step.change.before != nil { step.change.before?.thumbnail = thumbnail; step.change.before?.thumbnailDark = dark }
        if step.change.after != nil { step.change.after?.thumbnail = thumbnail; step.change.after?.thumbnailDark = dark }
        return step
    }
    func write(_ step: Step) -> DrawWriteOutcome {
        step.change.before == nil && step.change.after == nil ? .committed : repository.write(step.change)
    }
    func show(_ step: Step) {
        pendingGeneration &+= 1
        let id = step.change.canvasID
        states[id]?.canvas = step.after
        states[id]?.persisted = step.afterPersisted
        for objectID in step.change.objectIDs { states[id]?.objects[objectID] = step.change.objectsAfter[objectID] }
    }

    func execute(_ step: Step, action: Action) -> DrawSaveResult {
        if action == .edit { expireRedoOffers(on: step.change.canvasID) }
        let step = stamped(step)
        if let recovery, step.change.before != nil || step.change.after != nil {
            unsubmittedHeads.insert(step.change.canvasID)
            do {
                try IdleLatencyTrace.span("draw_store_recovery") {
                    try recovery.update(step.change.canvasID, edits: [Pending(step: step, action: action)],
                                        proof: nil, unattempted: true)
                }
            } catch {
                show(step)
                pending[step.change.canvasID] = [Pending(step: step, action: action)]
                return publishPending(step.change.canvasID, outcome: .held(
                    "The drawing is not saved yet. Its crash-recovery checkpoint could not be written: \(error.localizedDescription)"))
            }
        }
        unsubmittedHeads.remove(step.change.canvasID)
        let outcome = IdleLatencyTrace.span("draw_store_write") { write(step) }
        show(step)
        switch outcome {
        case .committed:
            try? recovery?.update(step.change.canvasID, edits: nil, proof: nil)
            return .saved(commit(step, action: action))
        case .retry(let message):
            pending[step.change.canvasID] = [Pending(step: step, action: action)]
            return publishPending(step.change.canvasID, outcome: .retry(message))
        case .held(let message):
            pending[step.change.canvasID] = [Pending(step: step, action: action)]
            return publishPending(step.change.canvasID, outcome: .held(message))
        }
    }

    func flush(_ id: UUID, head: Head) -> DrawSaveResult {
        if let message = recoveryLoadFailures[id] { return .held(message) }
        if pending[id]?.isEmpty == true {
            do { try recovery?.update(id, edits: nil, proof: nil) }
            catch { return .held("The cancelled name is not saved yet. Retry to save the drawing without it: \(error.localizedDescription)") }
            pending[id] = nil; pendingEdits[id] = nil
            pendingAvailability[id] = nil; unsubmittedHeads.remove(id); checkpointDirty.remove(id)
            recoveredCanvasIDs.remove(id)
            return .unchanged
        }
        var saved: [DrawDelta] = []
        var first = true
        while var edit = pending[id]?.first {
            var outcome: DrawWriteOutcome
            let reconcileFirst: Bool
            switch head {
            case .reconcile: reconcileFirst = first
            case .write: reconcileFirst = false
            case .auto: if first, case .held = pendingEdits[id]?.outcome { reconcileFirst = true } else { reconcileFirst = false }
            }
            if reconcileFirst && !unsubmittedHeads.contains(id) {
                outcome = repository.reconcile(edit.step.change)
            } else {
                edit.step = stamped(edit.step)
                pending[id]?[0] = edit
                if let recovery, unsubmittedHeads.contains(id) || checkpointDirty.contains(id) {
                    do {
                        try recovery.update(id, edits: pending[id], proof: repository.recoveryProof(for: id),
                                            unattempted: unsubmittedHeads.contains(id))
                        checkpointDirty.remove(id)
                    } catch {
                        return publishPending(id, outcome: .held(
                            "The drawing is not saved yet. The recovery checkpoint could not be written before saving: \(error.localizedDescription)"))
                    }
                }
                unsubmittedHeads.remove(id)
                outcome = write(edit.step)
            }
            first = false
            switch outcome {
            case .committed:
                pending[id]?.removeFirst()
                if pending[id]?.isEmpty == false { unsubmittedHeads.insert(id) }
                if pending[id]?.isEmpty == true {
                    pending[id] = nil
                    pendingAvailability[id] = nil
                    pendingEdits[id] = nil
                    recoveredCanvasIDs.remove(id)
                }
                if let steps = typingStepsPending[id]?[edit.step.id] {
                    for step in steps { saved.append(commit(step, action: edit.action)) }
                    typingStepsPending[id]?[edit.step.id] = nil
                } else { saved.append(commit(edit.step, action: edit.action)) }
                if let recovery {
                    do { try recovery.update(id, edits: pending[id], proof: nil, unattempted: pending[id] != nil) }
                    catch {
                        if pending[id] != nil {
                            return publishPending(id, outcome: .held("The remaining drawing changes are not saved yet. The recovery checkpoint could not be updated: \(error.localizedDescription)"))
                        }
                    }
                }
            case .retry(let message): return publishPending(id, outcome: .retry(message))
            case .held(let message): return publishPending(id, outcome: .held(message))
            }
        }
        guard let last = saved.last else { return .unchanged }
        guard saved.count > 1 else { return .saved(last) }
        var upserted: [UUID: DrawObject] = [:], removed = Set<UUID>()
        for delta in saved {
            for object in delta.upserted { upserted[object.id] = object; removed.remove(object.id) }
            for objectID in delta.removedIDs { upserted[objectID] = nil; removed.insert(objectID) }
        }
        return .saved(DrawDelta(canvas: last.canvas, upserted: upserted.values.sorted(by: Self.objectOrder),
                                removedIDs: removed.sorted { $0.uuidString < $1.uuidString }, revision: last.revision))
    }

    @discardableResult
    func publishPending(_ id: UUID, outcome: DrawSaveResult) -> DrawSaveResult {
        guard let edits = pending[id], let last = edits.last else { return outcome }
        var published = outcome
        if let recovery {
            do {
                try recovery.update(id, edits: edits, proof: repository.recoveryProof(for: id),
                                    unattempted: unsubmittedHeads.contains(id))
                checkpointDirty.remove(id)
            } catch {
                checkpointDirty.insert(id)
                published = .held("The drawing is not saved yet. Its crash-recovery checkpoint could not be written: \(error.localizedDescription)")
            }
        }
        pendingEdits[id] = DrawPendingEdit(canvas: last.step.after, objects: states[id]?.snapshot.objects ?? [],
                                           outcome: published, count: edits.count, lastStepID: last.step.id)
        return published
    }
}
