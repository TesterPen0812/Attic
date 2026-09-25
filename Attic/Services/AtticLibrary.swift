import Foundation
import SwiftData

/// What one Recently Deleted purge removed for good.
struct RecentlyDeletedPurgeReport: Equatable {
    var taskIDs: Set<UUID> = []
    var noteIDs: Set<UUID> = []
    var canvasIDs: Set<UUID> = []
    var attachmentCount = 0
    var removedLinks = 0

    var itemCount: Int { taskIDs.count + noteIDs.count + canvasIDs.count }
}

/// The store-level command layer. Every model change a person or an agent
/// makes through it (create, edit, state change, move, delete, restore,
/// tag, link) is one undoable step in the history it names, recorded only
/// after the store confirmed the save. It also answers the questions that
/// span stores: Recently Deleted, tags, links and whether an item is live.
///
/// Phase 0 routes agent changes and store-API deletes/restores through it;
/// keys, menus and toolbars join in later phases without a second route.
@MainActor
final class AtticLibrary {
    let tasks: TaskStore
    let notes: NoteStore?
    let canvases: CanvasStore?
    let links: LinkStore
    let tags: TagService
    let undo: UndoRoute
    private let container: ModelContainer
    private(set) var lastErrorMessage: String?

    init(
        tasks: TaskStore,
        notes: NoteStore? = nil,
        canvases: CanvasStore? = nil,
        undo: UndoRoute? = nil,
        now: @escaping () -> Date = Date.init,
        persist: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.tasks = tasks
        self.notes = notes
        self.canvases = canvases
        self.undo = undo ?? UndoRoute()
        container = tasks.container
        links = LinkStore(container: tasks.container, now: now, persist: persist)
        tags = TagService(container: tasks.container, persist: persist)
        links.endpointState = { [weak self] ref in self?.state(of: ref) ?? .missing }
        tags.afterChange = { [weak self] in self?.refreshItemStores() }
    }

    // MARK: - Item state

    /// Whether an item is live (shown somewhere, including the Done log), in
    /// Recently Deleted, or unknown. Decided by the replica presentation
    /// shows (`TaskStore/NoteStore.canonicalReplicas`, the canvas winner), so
    /// an item listed in Recently Deleted is `.deleted` here even while an
    /// older replica is still live; the restore then applies its own replica
    /// safety checks.
    func state(of ref: AtticItemRef) -> LinkEndpointState {
        let context = ModelContext(container)
        let id = ref.id
        do {
            switch ref.kind {
            case .task:
                if tasks.task(withID: id) != nil { return .live }
                let rows = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
                guard let winner = TaskStore.canonicalReplicas(from: rows).first else { return .missing }
                return winner.deletedAt != nil ? .deleted : .live
            case .note:
                let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
                guard let winner = NoteStore.canonicalReplicas(from: rows).first else { return .missing }
                return winner.deletedAt != nil ? .deleted : .live
            case .canvas:
                if canvases?.canvases.contains(where: { $0.id == id }) == true { return .live }
                let rows = try context.fetch(FetchDescriptor<CanvasBoardItem>(predicate: #Predicate { $0.id == id }))
                guard !rows.isEmpty else { return .missing }
                let winner = CanvasStore.winningBoardReplica(in: rows)
                if winner.purgedAt != nil { return .missing }
                return winner.tombstoned ? .deleted : .live
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            return .missing
        }
    }

    /// A short, human title for an item, whatever its state.
    func title(of ref: AtticItemRef) -> String? {
        let context = ModelContext(container)
        let id = ref.id
        switch ref.kind {
        case .task:
            return (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })))
                .flatMap { TaskStore.canonicalReplicas(from: $0).first }?.title
        case .note:
            guard let note = (try? context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })))
                .flatMap({ NoteStore.canonicalReplicas(from: $0).first }) else { return nil }
            return note.title.isEmpty ? String(note.body.split(whereSeparator: \.isNewline).first ?? "") : note.title
        case .canvas:
            guard let rows = try? context.fetch(FetchDescriptor<CanvasBoardItem>(predicate: #Predicate { $0.id == id })),
                  !rows.isEmpty else { return nil }
            return CanvasStore.winningBoardReplica(in: rows).name
        }
    }

    // MARK: - Tasks

    /// One step for the whole batch: undo moves every new task to Recently
    /// Deleted in one save, redo brings them all back.
    @discardableResult
    func createTasks(_ drafts: [TaskDraft], in history: UndoHistoryID = .tasks) -> [TaskItem]? {
        var created: [TaskItem]?
        undo.perform(in: history) {
            guard let tasks = self.tasks.commit(drafts), !tasks.isEmpty else { return nil }
            created = tasks
            let ids = tasks.map(\.id)
            return UndoStep(
                name: ids.count == 1 ? "Add Task" : "Add \(ids.count) Tasks",
                undoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    if self.tasks.delete(taskIDs: ids) { return .applied }
                    // Tasks that left the list since (deleted, or moved to the
                    // Done log) can't be taken back by this step any more.
                    return ids.allSatisfy { self.tasks.task(withID: $0) != nil } ? .failed : .obsolete
                },
                redoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    if self.tasks.restoreDeleted(taskIDs: ids) { return .applied }
                    return ids.allSatisfy { self.state(of: AtticItemRef(.task, $0)) == .deleted } ? .failed : .obsolete
                }
            )
        }
        return created
    }

    /// An edit of title, priority, state, tags or due date as one step.
    @discardableResult
    func updateTask(
        _ id: UUID,
        title: String? = nil,
        priority: TaskPriority? = nil,
        status: TaskStatus? = nil,
        tags newTags: [String]? = nil,
        dueDay: DueDay?? = nil,
        allowingUnfinishedSubtasks: Bool = false,
        in history: UndoHistoryID = .tasks
    ) -> Bool {
        var succeeded = false
        undo.perform(in: history) {
            guard let task = tasks.task(withID: id), let before = tasks.editableState(of: id),
                  tasks.update(
                    task,
                    title: title,
                    priority: priority,
                    status: status,
                    tags: newTags,
                    dueDay: dueDay,
                    allowingUnfinishedSubtasks: allowingUnfinishedSubtasks
                  ),
                  let after = tasks.editableState(of: id) else { return nil }
            succeeded = true
            guard before != after else { return nil }
            let name = status != nil && status?.rawValue != before.statusRaw ? "Change Task State" : "Edit Task"
            return editStep(name, before: [before], after: [after])
        }
        return succeeded
    }

    /// A reorder within a group (⌘↑ ⌘↓, or a drop onto a row) as one step.
    @discardableResult
    func moveTask(_ id: UUID, relativeTo targetID: UUID, in history: UndoHistoryID = .tasks) -> Bool {
        orderStep(id, in: history) { tasks.reorder(taskID: id, relativeTo: targetID) }
    }

    /// A drag reorder to a place in the task's group as one step.
    @discardableResult
    func moveTask(_ id: UUID, toIndex index: Int, in history: UndoHistoryID = .tasks) -> Bool {
        orderStep(id, in: history) { tasks.move(taskID: id, toIndex: index) }
    }

    private func orderStep(_ id: UUID, in history: UndoHistoryID, _ move: () -> Bool) -> Bool {
        var succeeded = false
        undo.perform(in: history) {
            guard let task = tasks.task(withID: id) else { return nil }
            let group = tasks.orderGroup(of: task).map(\.id)
            let before = group.compactMap(tasks.editableState(of:))
            guard move() else { return nil }
            succeeded = true
            let after = group.compactMap(tasks.editableState(of:))
            guard before != after else { return nil }
            return editStep("Move Task", before: before, after: after)
        }
        return succeeded
    }

    /// Completes a task with its unfinished subtasks as one step.
    @discardableResult
    func completeTask(_ id: UUID, in history: UndoHistoryID = .tasks) -> Bool {
        var succeeded = false
        undo.perform(in: history) {
            guard let task = tasks.task(withID: id) else { return nil }
            let family = [id] + (tasks.parent(of: task) == nil ? tasks.subtasks(of: id).map(\.id) : [])
            let before = family.compactMap(tasks.editableState(of:))
            guard tasks.completeFamily(taskID: id) else { return nil }
            succeeded = true
            let after = family.compactMap(tasks.editableState(of:))
            guard before != after else { return nil }
            return editStep("Complete Task", before: before, after: after)
        }
        return succeeded
    }

    /// The same edit applied to several tasks as one step (the selection
    /// bar): all of them change, or none does.
    @discardableResult
    func updateTasks(
        _ ids: [UUID],
        priority: TaskPriority? = nil,
        status: TaskStatus? = nil,
        addingTag: String? = nil,
        in history: UndoHistoryID = .tasks
    ) -> Bool {
        let ids = ids.filter { tasks.task(withID: $0) != nil }
        guard !ids.isEmpty else { return false }
        var succeeded = false
        undo.perform(in: history) {
            // Completing a main task takes its open subtasks along, as the
            // circle does; their states are part of the step.
            var touched = ids
            if status == .done {
                for id in ids { touched += tasks.subtasks(of: id).map(\.id) }
            }
            let before = touched.compactMap(tasks.editableState(of:))
            for id in ids {
                guard let task = tasks.task(withID: id) else { continue }
                let ok: Bool
                if status == .done, priority == nil, addingTag == nil {
                    ok = tasks.completeFamily(taskID: id)
                } else {
                    ok = tasks.update(
                        task,
                        priority: priority,
                        status: status,
                        tags: addingTag.map { AtticTag.normalizedSet(task.tags + [$0]) },
                        allowingUnfinishedSubtasks: true
                    )
                }
                guard ok else {
                    // Put back what earlier tasks in the batch already took.
                    let partial = touched.compactMap(tasks.editableState(of:))
                    _ = tasks.applyEditableTransition(from: partial, to: before)
                    return nil
                }
            }
            succeeded = true
            let after = touched.compactMap(tasks.editableState(of:))
            guard before != after else { return nil }
            let name = status != nil ? "Change Task State" : "Edit Tasks"
            return editStep(name, before: before, after: after)
        }
        return succeeded
    }

    /// Moves several tasks to Recently Deleted as one step (the selection
    /// bar, Delete on a multi-selection). Undo brings them all back.
    @discardableResult
    func deleteTasks(_ ids: [UUID], in history: UndoHistoryID = .tasks) -> Bool {
        guard ids.count > 1 else {
            return ids.first.map { delete(AtticItemRef(.task, $0), in: history) } ?? false
        }
        return undo.perform(in: history) {
            guard tasks.delete(taskIDs: ids) else { return nil }
            return UndoStep(
                name: "Delete \(ids.count) Tasks",
                undoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    if self.tasks.restoreDeleted(taskIDs: ids) { return .applied }
                    return ids.allSatisfy { self.state(of: AtticItemRef(.task, $0)) == .deleted } ? .failed : .obsolete
                },
                redoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    if self.tasks.delete(taskIDs: ids) { return .applied }
                    return ids.allSatisfy { self.tasks.task(withID: $0) != nil } ? .failed : .obsolete
                }
            )
        }
    }

    /// Brings a finished task back to Now as to do, as one step; undo puts
    /// it back where it was (the done group, or the Done log).
    @discardableResult
    func restoreToNow(_ id: UUID, in history: UndoHistoryID = .tasks) -> Bool {
        var succeeded = false
        undo.perform(in: history) {
            guard let before = tasks.listedEditableState(of: id) else { return nil }
            let loggedAt = tasks.listedTask(withID: id)?.doneLoggedAt
            guard tasks.restoreToNow(taskID: id), let after = tasks.editableState(of: id) else { return nil }
            succeeded = true
            let tasks = self.tasks
            return UndoStep(
                name: "Restore Task",
                undoOutcome: {
                    let outcome = tasks.applyEditableTransition(from: [after], to: [before])
                    guard outcome == .applied, let loggedAt else { return outcome }
                    _ = tasks.returnToDoneLog(taskID: id, loggedAt: loggedAt)
                    return .applied
                },
                redoOutcome: {
                    guard tasks.listedTask(withID: id) != nil else { return .obsolete }
                    return tasks.restoreToNow(taskID: id) ? .applied : .failed
                }
            )
        }
        return succeeded
    }

    // MARK: - Delete and restore

    /// Moves any item to Recently Deleted as one step. Agents and people use
    /// the same call; nothing here deletes permanently.
    @discardableResult
    func delete(_ ref: AtticItemRef, in history: UndoHistoryID? = nil) -> Bool {
        undo.perform(in: history ?? Self.defaultHistory(for: ref)) {
            guard performDelete(ref) else { return nil }
            return UndoStep(
                name: "Delete \(Self.noun(for: ref.kind))",
                undoOutcome: { [weak self] in self?.restoreOutcome(ref) ?? .obsolete },
                redoOutcome: { [weak self] in self?.deleteOutcome(ref) ?? .obsolete }
            )
        }
    }

    /// Restores an item from Recently Deleted, with what its delete took
    /// along and its links, as one step.
    @discardableResult
    func restore(_ ref: AtticItemRef, in history: UndoHistoryID = .library) -> Bool {
        undo.perform(in: history) {
            guard performRestore(ref) else { return nil }
            return UndoStep(
                name: "Restore \(Self.noun(for: ref.kind))",
                undoOutcome: { [weak self] in self?.deleteOutcome(ref) ?? .obsolete },
                redoOutcome: { [weak self] in self?.restoreOutcome(ref) ?? .obsolete }
            )
        }
    }

    /// Attachments removed on their own from live tasks and notes.
    func recentlyDeletedAttachments() -> [DeletedAttachmentSummary] {
        (tasks.recentlyDeletedAttachments() + (notes?.recentlyDeletedAttachments() ?? []))
            .sorted { $0.deletedAt != $1.deletedAt ? $0.deletedAt > $1.deletedAt : $0.attachmentID.uuidString < $1.attachmentID.uuidString }
    }

    /// Puts a removed attachment back on its task or note.
    @discardableResult
    func restoreAttachment(_ summary: DeletedAttachmentSummary) -> Bool {
        switch summary.owner.kind {
        case .task:
            return tasks.restoreAttachment(summary.attachmentID) || fail(tasks.lastErrorMessage)
        case .note:
            guard let notes else { return fail("Notes are unavailable.") }
            return notes.restoreAttachment(summary.attachmentID) || fail(notes.lastErrorMessage)
        case .canvas:
            return fail("Canvas images are restored with the canvas's own undo.")
        }
    }

    /// Everything in Recently Deleted, newest deletion first.
    func recentlyDeleted() -> [DeletedItemSummary] {
        (tasks.recentlyDeletedTasks()
            + (notes?.recentlyDeletedNotes() ?? [])
            + (canvases?.recentlyDeletedCanvases() ?? []))
            .sorted { lhs, rhs in
                lhs.deletedAt != rhs.deletedAt
                    ? lhs.deletedAt > rhs.deletedAt
                    : lhs.ref.id.uuidString < rhs.ref.id.uuidString
            }
    }

    /// Removes for good what has been in Recently Deleted for 30 days, with
    /// the links of what was removed, then links removed on their own that
    /// long ago. Each store removes its items and their links in one save
    /// (`LinkStore.stagePurge`), so a failed save keeps both for the next
    /// cleanup and a link never outlives its item. Called only by the daily
    /// cleanup; never by agents.
    @discardableResult
    func purgeExpired(now: Date, calendar: Calendar) -> RecentlyDeletedPurgeReport {
        let cutoff = RecentlyDeletedPolicy.purgeCutoff(now: now, calendar: calendar)
        var report = RecentlyDeletedPurgeReport()
        var staged = 0
        func stageLinks(_ kind: AtticItemKind) -> (ModelContext, Set<UUID>) throws -> Void {
            { [links] context, ids in
                staged = try links.stagePurge(touching: Set(ids.map { AtticItemRef(kind, $0) }), in: context)
            }
        }
        func committed(_ ids: Set<UUID>) -> Set<UUID> {
            if !ids.isEmpty {
                report.removedLinks += staged
                if staged > 0 { links.stagedPurgeWasSaved() }
            }
            staged = 0
            return ids
        }
        report.taskIDs = committed(tasks.purgeDeleted(before: cutoff, alongside: stageLinks(.task)))
        report.noteIDs = committed(notes?.purgeDeleted(before: cutoff, alongside: stageLinks(.note)) ?? [])
        report.canvasIDs = committed(
            canvases?.purgeDeletedCanvases(before: cutoff, alongside: stageLinks(.canvas)) ?? []
        )
        report.attachmentCount = tasks.purgeRemovedAttachments(before: cutoff)
            + (notes?.purgeRemovedAttachments(before: cutoff) ?? 0)
        report.removedLinks += links.purgeRemovedLinks(before: cutoff)
        return report
    }

    // MARK: - Tags

    /// Undo and redo move the item's tags by the difference this change
    /// made (see `tagDelta`), so tags added or renamed since, through any
    /// history, survive.
    @discardableResult
    func setTags(_ newTags: [String], on ref: AtticItemRef, in history: UndoHistoryID? = nil) -> Bool {
        var succeeded = false
        undo.perform(in: history ?? Self.defaultHistory(for: ref)) {
            guard let before = currentTags(of: ref) else {
                _ = fail("No \(ref.kind.rawValue) exists with id \(ref.id.uuidString).")
                return nil
            }
            let after = AtticTag.normalizedSet(newTags)
            guard before != after else {
                succeeded = true
                return nil
            }
            // A task's tags go through its editable-state step, which finds
            // it in the Done log too.
            let taskBefore = ref.kind == .task ? tasks.editableState(of: ref.id) : nil
            guard applyTags(after, to: ref) else { return nil }
            succeeded = true
            if let taskBefore, let taskAfter = tasks.editableState(of: ref.id) {
                return editStep("Change Tags", before: [taskBefore], after: [taskAfter])
            }
            return UndoStep(
                name: "Change Tags",
                undoOutcome: { [weak self] in self?.moveTags(of: ref, from: after, to: before) ?? .obsolete },
                redoOutcome: { [weak self] in self?.moveTags(of: ref, from: before, to: after) ?? .obsolete }
            )
        }
        return succeeded
    }

    @discardableResult
    func renameTag(_ tag: String, to newName: String, in history: UndoHistoryID = .library) -> Bool {
        tagOperation("Rename Tag", in: history) { $0.rename(tag, to: newName) }
    }

    @discardableResult
    func mergeTags(_ sources: [String], into target: String, in history: UndoHistoryID = .library) -> Bool {
        tagOperation("Merge Tags", in: history) { $0.merge(sources, into: target) }
    }

    @discardableResult
    func deleteTag(_ tag: String, in history: UndoHistoryID = .library) -> Bool {
        tagOperation("Delete Tag", in: history) { $0.delete(tag) }
    }

    // MARK: - Links

    @discardableResult
    func link(
        _ source: AtticItemRef,
        to target: AtticItemRef,
        kind: ItemLinkKind,
        in history: UndoHistoryID? = nil
    ) -> ItemLinkRecord? {
        var record: ItemLinkRecord?
        undo.perform(in: history ?? Self.defaultHistory(for: source)) {
            guard let created = links.link(source, to: target, kind: kind) else { return nil }
            record = created
            return UndoStep(
                name: "Link",
                undo: { [links = self.links] in links.unlink(created.id) },
                redo: { [links = self.links] in links.restoreLink(created.id) }
            )
        }
        return record
    }

    @discardableResult
    func unlink(_ linkID: UUID, in history: UndoHistoryID) -> Bool {
        undo.perform(in: history) {
            guard links.unlink(linkID) else { return nil }
            return UndoStep(
                name: "Remove Link",
                undo: { [links = self.links] in links.restoreLink(linkID) },
                redo: { [links = self.links] in links.unlink(linkID) }
            )
        }
    }

    // MARK: - Private

    private func performDelete(_ ref: AtticItemRef) -> Bool {
        switch ref.kind {
        case .task:
            guard tasks.task(withID: ref.id) != nil else { return fail("No task exists with id \(ref.id.uuidString).") }
            return tasks.delete(taskIDs: [ref.id]) || fail(tasks.lastErrorMessage)
        case .note:
            guard let notes, let note = notes.note(withID: ref.id) else {
                return fail("No note exists with id \(ref.id.uuidString).")
            }
            return notes.delete(note) || fail(notes.lastErrorMessage)
        case .canvas:
            guard let canvases, canvases.canvases.contains(where: { $0.id == ref.id }) else {
                return fail("No canvas exists with id \(ref.id.uuidString).")
            }
            return canvases.deleteCanvas(ref.id) || fail(canvases.lastErrorMessage)
        }
    }

    private func performRestore(_ ref: AtticItemRef) -> Bool {
        switch ref.kind {
        case .task:
            return tasks.restoreDeleted(taskID: ref.id) || fail(tasks.lastErrorMessage)
        case .note:
            guard let notes else { return fail("Notes are unavailable.") }
            return notes.restoreDeleted(noteID: ref.id) || fail(notes.lastErrorMessage)
        case .canvas:
            guard let canvases else { return fail("Canvases are unavailable.") }
            return canvases.restoreCanvas(ref.id) || fail(canvases.lastErrorMessage)
        }
    }

    /// Undo/redo of a delete: moving an item that is no longer shown (gone,
    /// already in Recently Deleted, or a task the daily cleanup moved to the
    /// Done log) can never apply again.
    private func deleteOutcome(_ ref: AtticItemRef) -> UndoOutcome {
        if performDelete(ref) { return .applied }
        let shown: Bool = switch ref.kind {
        case .task: tasks.task(withID: ref.id) != nil
        case .note: notes?.note(withID: ref.id) != nil
        case .canvas: canvases?.canvases.contains(where: { $0.id == ref.id }) == true
        }
        return shown ? .failed : .obsolete
    }

    /// Undo/redo of a restore: only an item still in Recently Deleted can be
    /// restored; a refusal of one that is (a replica conflict) is kept.
    private func restoreOutcome(_ ref: AtticItemRef) -> UndoOutcome {
        if performRestore(ref) { return .applied }
        return state(of: ref) == .deleted ? .failed : .obsolete
    }

    /// One task edit step: undo and redo write only the fields it changed,
    /// and only where nothing changed them since
    /// (`TaskStore.applyEditableTransition`).
    private func editStep(_ name: String, before: [TaskEditableState], after: [TaskEditableState]) -> UndoStep {
        UndoStep(
            name: name,
            undoOutcome: { [tasks = self.tasks] in tasks.applyEditableTransition(from: after, to: before) },
            redoOutcome: { [tasks = self.tasks] in tasks.applyEditableTransition(from: before, to: after) }
        )
    }

    /// Moves an item's tags by the difference between `from` and `to`: the
    /// tags `to` lacks are removed, the ones it adds come back, and anything
    /// else on the item now stays.
    private func moveTags(of ref: AtticItemRef, from: [String], to: [String]) -> UndoOutcome {
        guard let current = currentTags(of: ref) else { return .obsolete }
        let target = Self.tagDelta(current: current, from: from, to: to)
        guard target != AtticTag.normalizedSet(current) else { return .applied }
        return applyTags(target, to: ref) ? .applied : .failed
    }

    static func tagDelta(current: [String], from: [String], to: [String]) -> [String] {
        let from = Set(from)
        let to = Set(to)
        return AtticTag.normalizedSet(Set(current).subtracting(from.subtracting(to)).union(to.subtracting(from)))
    }

    private func currentTags(of ref: AtticItemRef) -> [String]? {
        switch ref.kind {
        case .task: tasks.task(withID: ref.id)?.tags
        case .note: notes?.note(withID: ref.id)?.tags
        case .canvas: canvases?.canvases.first(where: { $0.id == ref.id })?.tags
        }
    }

    private func applyTags(_ newTags: [String], to ref: AtticItemRef) -> Bool {
        switch ref.kind {
        case .task:
            guard let task = tasks.task(withID: ref.id) else { return fail("No task exists with id \(ref.id.uuidString).") }
            return tasks.setTags(newTags, for: task) || fail(tasks.lastErrorMessage)
        case .note:
            guard let notes, let note = notes.note(withID: ref.id) else {
                return fail("No note exists with id \(ref.id.uuidString).")
            }
            return notes.setTags(newTags, for: note) || fail(notes.lastErrorMessage)
        case .canvas:
            guard let canvases else { return fail("Canvases are unavailable.") }
            return canvases.setTags(newTags, forCanvas: ref.id) || fail(canvases.lastErrorMessage)
        }
    }

    private func tagOperation(
        _ name: String,
        in history: UndoHistoryID,
        _ operation: @escaping (TagService) -> TagChangeSnapshot?
    ) -> Bool {
        /// The rows the latest run of the operation changed: each redo runs the
        /// operation again and records what that run changed, so the next
        /// undo also covers rows that gained the tag in between.
        final class Changes {
            var snapshot: TagChangeSnapshot
            init(_ snapshot: TagChangeSnapshot) { self.snapshot = snapshot }
        }
        var succeeded = false
        undo.perform(in: history) {
            guard let snapshot = operation(tags) else {
                _ = fail(tags.lastErrorMessage)
                return nil
            }
            succeeded = true
            guard !snapshot.isEmpty else { return nil }
            let changes = Changes(snapshot)
            return UndoStep(
                name: name,
                undo: { [tags = self.tags] in tags.revert(changes.snapshot) },
                redo: { [tags = self.tags] in
                    guard let rerun = operation(tags) else { return false }
                    changes.snapshot = rerun
                    return true
                }
            )
        }
        return succeeded
    }

    private func refreshItemStores() {
        tasks.refresh()
        notes?.refresh()
        canvases?.refresh()
    }

    /// Always false, so failures read `return store.op() || fail(...)`.
    private func fail(_ message: String?) -> Bool {
        lastErrorMessage = message ?? "Unknown error."
        return false
    }

    static func defaultHistory(for ref: AtticItemRef) -> UndoHistoryID {
        switch ref.kind {
        case .task: .tasks
        case .note: .note(ref.id)
        case .canvas: .canvas(ref.id)
        }
    }

    static func noun(for kind: AtticItemKind) -> String {
        switch kind {
        case .task: "Task"
        case .note: "Note"
        case .canvas: "Canvas"
        }
    }
}
