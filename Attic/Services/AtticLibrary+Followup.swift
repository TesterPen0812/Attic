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
        undo.perform(in: history) {
            let (restoredItems, restoredAttachments, failures) = performRestoreAll(items: items, attachments: attachments)
            report.restored = restoredItems.count + restoredAttachments.count
            report.failures = failures
            guard report.restored > 0 else { return nil }
            let count = report.restored
            return UndoStep(
                name: count == 1 ? "Restore Item" : "Restore \(count) Items",
                undoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    // Files first, then subtasks restored on their own, then
                    // everything else: a main task's delete would otherwise
                    // take a separately restored subtask along with it.
                    var outcomes = restoredAttachments.map { self.removeAttachmentOutcome($0) }
                    let ordered = restoredItems.sorted { lhs, rhs in
                        let lhsChild = lhs.kind == .task && self.tasks.listedTask(withID: lhs.id)?.parentID != nil
                        let rhsChild = rhs.kind == .task && self.tasks.listedTask(withID: rhs.id)?.parentID != nil
                        return lhsChild && !rhsChild
                    }
                    outcomes += ordered.map { self.deleteOutcome($0) }
                    return Self.combined(outcomes)
                },
                redoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    let (again, againAttachments, _) = self.performRestoreAll(items: restoredItems, attachments: restoredAttachments)
                    if !again.isEmpty || !againAttachments.isEmpty { return .applied }
                    let removed = Set(self.recentlyDeletedAttachments().map(\.attachmentID))
                    let stillDeleted = restoredItems.contains { self.state(of: $0) == .deleted }
                        || restoredAttachments.contains { removed.contains($0.attachmentID) }
                    return stillDeleted ? .failed : .obsolete
                }
            )
        }
        return report
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
    ) -> (items: [AtticItemRef], attachments: [DeletedAttachmentSummary], failures: [RestoreReport.Failure]) {
        var restored: [AtticItemRef] = []
        var failures: [RestoreReport.Failure] = []
        let taskRefs = items.filter { $0.kind == .task }
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
        return (restored, restoredAttachments, failures)
    }
}
