import Foundation

/// The Phase 1 follow-up (control audit items 5 and 11): a subtask moved to
/// another task or made a task of its own, and several Recently Deleted
/// items restored together. Each is one undoable step, recorded only after
/// the store confirmed the save.
extension AtticLibrary {
    // MARK: - Item 5: Move to Task… and Make Standalone Task

    /// Moves a subtask to another main task (`newParentID`), or makes it a
    /// main task of its own (nil), as one step (`TaskStore.reparentSubtask`
    /// says where it lands and what it keeps). Undo puts it back under its
    /// old main task, in its old place; redo moves it again. Both refuse,
    /// changing nothing, once the main task they need is gone, finished or
    /// in Recently Deleted.
    @discardableResult
    func moveSubtask(_ id: UUID, toTask newParentID: UUID?, in history: UndoHistoryID = .tasks) -> CommandOutcome {
        var succeeded = false
        let serial = tasks.errorSerial
        undo.perform(in: history) {
            guard let task = tasks.task(withID: id), let oldParentID = task.parentID else { return nil }
            let scope = Array(Set(tasks.reparentScope(of: id, to: newParentID) + [id]))
            let scopeBefore = scope.compactMap(tasks.editableState(of:))
            guard tasks.reparentSubtask(id, to: newParentID) else { return nil }
            succeeded = true
            let scopeAfter = scope.compactMap(tasks.editableState(of:))
            let families = [oldParentID] + (newParentID.map { [$0] } ?? [])
            for family in families { subtaskOrderChanges.send(family) }
            // The step keeps only what the move changed: a sibling it left
            // alone (and that may be deleted afterwards) does not belong to
            // it, while one a re-spacing moved does.
            let beforeByID = Dictionary(scopeBefore.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let afterByID = Dictionary(scopeAfter.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let changed = Set(beforeByID.keys).union(afterByID.keys).filter { beforeByID[$0] != afterByID[$0] }
            guard !changed.isEmpty else { return nil }
            let before = scopeBefore.filter { changed.contains($0.id) }
            let after = scopeAfter.filter { changed.contains($0.id) }
            return UndoStep(
                name: newParentID == nil ? "Make Standalone Task" : "Move to Task",
                undoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    let outcome = self.tasks.applyEditableTransition(from: after, to: before)
                    if outcome == .applied { for family in families { self.subtaskOrderChanges.send(family) } }
                    return outcome
                },
                redoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    let outcome = self.tasks.applyEditableTransition(from: before, to: after)
                    if outcome == .applied { for family in families { self.subtaskOrderChanges.send(family) } }
                    return outcome
                }
            )
        }
        return taskOutcome(succeeded, since: serial, ids: [id])
    }

    // MARK: - Item 11: Restore Selected

    /// What Restore Selected did: how many came back, and each one that
    /// could not, with the reason.
    struct RestoreReport: Equatable {
        var restored = 0
        var failures: [Failure] = []

        struct Failure: Equatable {
            let item: AtticItemRef?
            let attachmentID: UUID?
            let message: String
        }
    }

    /// Restores several Recently Deleted entries as one step (control audit
    /// item 11): Undo sends every one that came back to Recently Deleted
    /// again, Redo restores them again. Tasks come back in one save when
    /// they all can (the store's own all-or-nothing restore); when one of
    /// them can't, the others still come back, one by one. Notes, canvases
    /// and attachments are restored one by one (each store saves its own).
    /// Items come back before attachments, so a file whose task was
    /// selected too returns to it.
    @discardableResult
    func restoreRecentlyDeleted(
        items: [AtticItemRef],
        attachments: [DeletedAttachmentSummary],
        in history: UndoHistoryID = .library
    ) -> RestoreReport {
        var report = RestoreReport()
        // Repeats of one entry restore it once (and do not fail the second time).
        var seenItems = Set<AtticItemRef>()
        var seenAttachments = Set<UUID>()
        let items = items.filter { seenItems.insert($0).inserted }
        let attachments = attachments.filter { seenAttachments.insert($0.attachmentID).inserted }
        undo.perform(in: history) {
            let (restoredItems, restoredAttachments, failures, owned) = performRestoreAll(items: items, attachments: attachments)
            report.restored = restoredItems.count + restoredAttachments.count
            report.failures = failures
            guard report.restored > 0 else { return nil }
            let count = report.restored
            let progress = BulkRestoreProgress(items: restoredItems, attachments: restoredAttachments, owned: owned)
            return UndoStep(
                name: count == 1 ? "Restore Item" : "Restore \(count) Items",
                undoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    return self.sendBack(progress)
                },
                redoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    return self.restoreAgain(progress)
                }
            )
        }
        return report
    }

    /// Where each part of a Restore Selected step stands. Undo and Redo work
    /// on the parts that have not been through them yet, so a retry after a
    /// partial failure never repeats (or reverses) what already applied.
    private final class BulkRestoreProgress {
        enum Phase {
            /// Restored, as when the step ran (or as Redo left it).
            case restored
            /// Sent back to Recently Deleted by Undo.
            case sentBack
            /// Gone or changed by something else: the step no longer reaches it.
            case dropped
        }

        let items: [AtticItemRef]
        let attachments: [DeletedAttachmentSummary]
        var itemPhase: [AtticItemRef: Phase]
        var attachmentPhase: [UUID: Phase]
        /// For each restored main task, the tasks its restore brought back,
        /// read before the restore cleared its deletion record (and read
        /// again each time Redo restores it). Undo deletes a main task only
        /// while every live subtask is one of these or one this step tracks.
        var owned: [UUID: Set<UUID>]

        init(items: [AtticItemRef], attachments: [DeletedAttachmentSummary], owned: [UUID: Set<UUID>]) {
            self.items = items
            self.attachments = attachments
            self.owned = owned
            itemPhase = Dictionary(items.map { ($0, .restored) }, uniquingKeysWith: { first, _ in first })
            attachmentPhase = Dictionary(attachments.map { ($0.attachmentID, .restored) }, uniquingKeysWith: { first, _ in first })
        }

        func anyPart(_ phase: Phase) -> Bool {
            itemPhase.values.contains(phase) || attachmentPhase.values.contains(phase)
        }
    }

    /// Undo: sends the parts still restored back to Recently Deleted, files
    /// first, then subtasks restored on their own, then everything else (a
    /// main task's delete would otherwise take a separately restored subtask
    /// along with it). `.failed` while a part could not go back, and the step
    /// stays for a retry that touches only those.
    private func sendBack(_ progress: BulkRestoreProgress) -> UndoOutcome {
        var outcomes: [UndoOutcome] = []
        for attachment in progress.attachments where progress.attachmentPhase[attachment.attachmentID] == .restored {
            let outcome = removeAttachmentOutcome(attachment)
            switch outcome {
            case .applied: progress.attachmentPhase[attachment.attachmentID] = .sentBack
            case .obsolete: progress.attachmentPhase[attachment.attachmentID] = .dropped
            case .failed: break
            }
            outcomes.append(outcome)
        }
        let pending = progress.items.filter { progress.itemPhase[$0] == .restored }.sorted { lhs, rhs in
            let lhsChild = lhs.kind == .task && tasks.listedTask(withID: lhs.id)?.parentID != nil
            let rhsChild = rhs.kind == .task && tasks.listedTask(withID: rhs.id)?.parentID != nil
            return lhsChild && !rhsChild
        }
        var failed = Set<AtticItemRef>()
        let tracked = progress.items.filter { $0.kind == .task }.map(\.id)
        for ref in pending {
            // What this step may take: what its restore brought back for the
            // task, plus the tasks it tracks itself.
            let reach = FamilyOwnership((progress.owned[ref.id] ?? [ref.id]).union(tracked))
            // Deleting a main task takes its subtasks with it, whatever the
            // step tracked. Look at the family it would take right now.
            if ref.kind == .task, let listed = tasks.listedTask(withID: ref.id), listed.parentID == nil {
                guard let family = try? tasks.liveSubtaskIDs(of: ref.id) else {
                    outcomes.append(.failed)
                    failed.insert(ref)
                    continue
                }
                // A live subtask this restore did not bring back and does not
                // track came back through another history (Recently Deleted and
                // Tasks undo separately). Deleting the main task would undo
                // that, so the step no longer reaches it and the family stays.
                if !family.isSubset(of: reach.members) {
                    progress.itemPhase[ref] = .dropped
                    outcomes.append(.obsolete)
                    continue
                }
                let members = family.map { AtticItemRef(.task, $0) }
                // A subtask this step already sent back (or let go of) that is
                // live again was restored by someone else: the delete would
                // undo that. The step no longer reaches the main task.
                if members.contains(where: { progress.itemPhase[$0] == .sentBack || progress.itemPhase[$0] == .dropped }) {
                    progress.itemPhase[ref] = .dropped
                    outcomes.append(.obsolete)
                    continue
                }
                // A subtask that would not go back stays where it is, so the
                // main task stays with it; the retry takes both.
                if members.contains(where: failed.contains) {
                    outcomes.append(.failed)
                    failed.insert(ref)
                    continue
                }
            }
            let outcome = deleteOutcome(ref, owning: reach)
            switch outcome {
            case .applied: progress.itemPhase[ref] = .sentBack
            case .obsolete: progress.itemPhase[ref] = .dropped
            case .failed: failed.insert(ref)
            }
            outcomes.append(outcome)
        }
        return settled(outcomes, progress: progress, reached: .sentBack)
    }

    /// Redo: restores the parts that Undo sent back and that are still in
    /// Recently Deleted. `.failed` while one of them could not come back; the
    /// failure is reported, the step stays on the Redo list, and the next
    /// Undo targets only the parts that did come back.
    private func restoreAgain(_ progress: BulkRestoreProgress) -> UndoOutcome {
        let sentBack = progress.items.filter { progress.itemPhase[$0] == .sentBack }
        let attachments = progress.attachments.filter { progress.attachmentPhase[$0.attachmentID] == .sentBack }
        // Nothing comes back that this step does not own. A task's deletion
        // record now may hold tasks another history deleted since (Tasks and
        // Recently Deleted undo separately): restoring it would undo that, so
        // the step lets go of it. An unreadable record stays for a retry.
        // Each task is judged alone; the ones that pass still come back.
        let tracked = Set(progress.items.filter { $0.kind == .task }.map(\.id))
        var outcomes: [UndoOutcome] = []
        var items: [AtticItemRef] = []
        for ref in sentBack {
            guard ref.kind == .task else { items.append(ref); continue }
            let reach = (progress.owned[ref.id] ?? [ref.id]).union(tracked)
            switch restoreClearance(of: [ref.id], owning: reach) {
            case .success:
                items.append(ref)
            case .failure(.obsolete):
                progress.itemPhase[ref] = .dropped
                outcomes.append(.obsolete)
            case .failure:
                outcomes.append(.failed)
            }
        }
        let (again, againAttachments, _, againOwned) = performRestoreAll(items: items, attachments: attachments)
        for ref in items {
            if again.contains(ref) {
                progress.itemPhase[ref] = .restored
                if let members = againOwned[ref.id] { progress.owned[ref.id] = members }
                outcomes.append(.applied)
            } else if state(of: ref) == .deleted {
                outcomes.append(.failed)
            } else {
                progress.itemPhase[ref] = .dropped
                outcomes.append(.obsolete)
            }
        }
        let stillDeleted = Set(recentlyDeletedAttachments().map(\.attachmentID))
        for attachment in attachments {
            if againAttachments.contains(where: { $0.attachmentID == attachment.attachmentID }) {
                progress.attachmentPhase[attachment.attachmentID] = .restored
                outcomes.append(.applied)
            } else if stillDeleted.contains(attachment.attachmentID) {
                outcomes.append(.failed)
            } else {
                progress.attachmentPhase[attachment.attachmentID] = .dropped
                outcomes.append(.obsolete)
            }
        }
        return settled(outcomes, progress: progress, reached: .restored)
    }

    /// The outcome of one Undo or Redo pass: failed while a part failed;
    /// otherwise applied when the pass, or an earlier retry of it, moved
    /// anything; obsolete when nothing is left for it to reach.
    private func settled(_ outcomes: [UndoOutcome], progress: BulkRestoreProgress, reached phase: BulkRestoreProgress.Phase) -> UndoOutcome {
        if outcomes.contains(.failed) { return .failed }
        if outcomes.contains(.applied) || progress.anyPart(phase) { return .applied }
        return .obsolete
    }

    /// One outcome for a step made of several: applied when any part
    /// applied and none failed; failed when one failed; obsolete when
    /// nothing could apply again.
    static func combined(_ outcomes: [UndoOutcome]) -> UndoOutcome {
        if outcomes.contains(.failed) { return .failed }
        if outcomes.contains(.applied) { return .applied }
        return .obsolete
    }

    private func performRestoreAll(
        items: [AtticItemRef],
        attachments: [DeletedAttachmentSummary]
    ) -> (
        items: [AtticItemRef],
        attachments: [DeletedAttachmentSummary],
        failures: [RestoreReport.Failure],
        owned: [UUID: Set<UUID>]
    ) {
        var restored: [AtticItemRef] = []
        var failures: [RestoreReport.Failure] = []
        let taskRefs = items.filter { $0.kind == .task }
        // What each delete covers, read before a restore clears the record.
        let recorded = tasks.recordedDeletionMembers(ofRoots: taskRefs.map(\.id))
        if taskRefs.count > 1, tasks.restoreDeleted(taskIDs: taskRefs.map(\.id)) {
            restored += taskRefs
        } else {
            // One by one, until a pass brings nothing more back: a subtask
            // deleted on its own returns only once its main task has.
            var pending = taskRefs
            var reasons: [AtticItemRef: String] = [:]
            var progressed = true
            while progressed, !pending.isEmpty {
                progressed = false
                pending = pending.filter { ref in
                    guard performRestore(ref) else {
                        reasons[ref] = lastErrorMessage
                        return true
                    }
                    restored.append(ref)
                    progressed = true
                    return false
                }
            }
            failures += pending.map { .init(item: $0, attachmentID: nil, message: reasons[$0] ?? "Unknown error.") }
        }
        for ref in items where ref.kind != .task {
            if performRestore(ref) {
                restored.append(ref)
            } else {
                failures.append(.init(item: ref, attachmentID: nil, message: lastErrorMessage ?? "Unknown error."))
            }
        }
        var restoredAttachments: [DeletedAttachmentSummary] = []
        for attachment in attachments {
            if performRestoreAttachment(attachment) {
                restoredAttachments.append(attachment)
            } else {
                failures.append(.init(item: nil, attachmentID: attachment.attachmentID, message: lastErrorMessage ?? "Unknown error."))
            }
        }
        let owned = Dictionary(restored.filter { $0.kind == .task }.map {
            ($0.id, recorded[$0.id] ?? [$0.id])
        }, uniquingKeysWith: { first, _ in first })
        return (restored, restoredAttachments, failures, owned)
    }
}
