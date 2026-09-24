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
    /// Recently Deleted, or unknown.
    func state(of ref: AtticItemRef) -> LinkEndpointState {
        let context = ModelContext(container)
        let id = ref.id
        do {
            switch ref.kind {
            case .task:
                if tasks.task(withID: id) != nil { return .live }
                let rows = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
                guard !rows.isEmpty else { return .missing }
                return rows.allSatisfy { $0.deletedAt != nil } ? .deleted : .live
            case .note:
                let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
                guard !rows.isEmpty else { return .missing }
                return rows.allSatisfy { $0.deletedAt != nil } ? .deleted : .live
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
            return (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })))?
                .max { $0.updatedAt < $1.updatedAt }?.title
        case .note:
            guard let note = (try? context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })))?
                .max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
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
                undo: { [tasks = self.tasks] in tasks.delete(taskIDs: ids) },
                redo: { [tasks = self.tasks] in tasks.restoreDeleted(taskIDs: ids) }
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
            return UndoStep(
                name: name,
                undo: { [tasks = self.tasks] in tasks.restoreEditableStates([before]) },
                redo: { [tasks = self.tasks] in tasks.restoreEditableStates([after]) }
            )
        }
        return succeeded
    }

    /// A drag reorder within a group as one step.
    @discardableResult
    func moveTask(_ id: UUID, relativeTo targetID: UUID, in history: UndoHistoryID = .tasks) -> Bool {
        var succeeded = false
        undo.perform(in: history) {
            guard let task = tasks.task(withID: id) else { return nil }
            let group = tasks.tasks.filter {
                $0.parentID == task.parentID && $0.statusRaw == task.statusRaw && $0.priorityRaw == task.priorityRaw
            }.map(\.id)
            let before = group.compactMap(tasks.editableState(of:))
            guard tasks.reorder(taskID: id, relativeTo: targetID) else { return nil }
            succeeded = true
            let after = group.compactMap(tasks.editableState(of:))
            guard before != after else { return nil }
            return UndoStep(
                name: "Move Task",
                undo: { [tasks = self.tasks] in tasks.restoreEditableStates(before) },
                redo: { [tasks = self.tasks] in tasks.restoreEditableStates(after) }
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
                undo: { [weak self] in self?.performRestore(ref) ?? false },
                redo: { [weak self] in self?.performDelete(ref) ?? false }
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
                undo: { [weak self] in self?.performDelete(ref) ?? false },
                redo: { [weak self] in self?.performRestore(ref) ?? false }
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

    /// Removes for good what has been in Recently Deleted for 30 days, then
    /// the links of what was removed and links removed on their own that
    /// long ago. Called only by the daily cleanup; never by agents.
    @discardableResult
    func purgeExpired(now: Date, calendar: Calendar) -> RecentlyDeletedPurgeReport {
        let cutoff = RecentlyDeletedPolicy.purgeCutoff(now: now, calendar: calendar)
        var report = RecentlyDeletedPurgeReport()
        report.taskIDs = tasks.purgeDeleted(before: cutoff)
        report.noteIDs = notes?.purgeDeleted(before: cutoff) ?? []
        report.canvasIDs = canvases?.purgeDeletedCanvases(before: cutoff) ?? []
        report.attachmentCount = tasks.purgeRemovedAttachments(before: cutoff)
            + (notes?.purgeRemovedAttachments(before: cutoff) ?? 0)
        let purged = Set(report.taskIDs.map { AtticItemRef(.task, $0) })
            .union(report.noteIDs.map { AtticItemRef(.note, $0) })
            .union(report.canvasIDs.map { AtticItemRef(.canvas, $0) })
        report.removedLinks = links.purgeLinks(touching: purged) + links.purgeRemovedLinks(before: cutoff)
        return report
    }

    // MARK: - Tags

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
            guard applyTags(after, to: ref) else { return nil }
            succeeded = true
            return UndoStep(
                name: "Change Tags",
                undo: { [weak self] in self?.applyTags(before, to: ref) ?? false },
                redo: { [weak self] in self?.applyTags(after, to: ref) ?? false }
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
        var succeeded = false
        undo.perform(in: history) {
            guard let snapshot = operation(tags) else {
                _ = fail(tags.lastErrorMessage)
                return nil
            }
            succeeded = true
            guard !snapshot.isEmpty else { return nil }
            return UndoStep(
                name: name,
                undo: { [tags = self.tags] in tags.restore(snapshot) },
                redo: { [tags = self.tags] in operation(tags) != nil }
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
