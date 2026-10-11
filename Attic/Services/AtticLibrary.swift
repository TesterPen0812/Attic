import Combine
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
    /// Each tag's colour (colour pass, owner 2026-10-10).
    let tagColours: TagColourStore
    let undo: UndoRoute
    private var tagInventoryObservation: AnyCancellable?
    private var tagColourObservation: AnyCancellable?
    private var tagColourRefreshPending = false
    private let container: ModelContainer
    private(set) var lastErrorMessage: String?
    /// The last task command that changed nothing, and why (Astra 6). Also
    /// set by `createTasks`, which returns the tasks instead of an outcome.
    private(set) var lastFailure: CommandFailure?
    /// A main task's subtasks were reordered on purpose (moved, or a move
    /// undone or redone, from any history that reaches this library): the
    /// id is the main task's. A page holding the quick look's order lets go
    /// of it, so the open list shows the new order (round 10b).
    let subtaskOrderChanges = PassthroughSubject<UUID, Never>()

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
        tagColours = TagColourStore(container: tasks.container, persist: persist, now: now)
        let colours = tagColours
        tags.carryColour = { [weak colours] sources, target, targetInUse, context in
            try colours?.carry(from: sources, to: target, targetInUse: targetInUse, in: context)
        }
        links.endpointState = { [weak self] ref in self?.state(of: ref) ?? .missing }
        tasks.commandLibrary = self
        let inventory = tags
        tasks.tagInventoryWillSave = { [weak inventory] in inventory?.invalidate(in: $0) }
        tasks.tagInventoryDidSave = { [weak inventory] in inventory?.publishInventoryChange() }
        tasks.tagInventoryDidRefresh = { [weak inventory] in inventory?.invalidateInventory() }
        notes?.tagInventoryWillSave = { [weak inventory] in inventory?.invalidate(in: $0) }
        notes?.tagInventoryDidSave = { [weak inventory] in inventory?.publishInventoryChange() }
        notes?.tagInventoryDidRefresh = { [weak inventory] in inventory?.invalidateInventory() }
        notes?.sharedTagCounts = { [weak inventory] in inventory?.countsByName }
        canvases?.tagInventoryWillSave = { [weak inventory] in inventory?.invalidate(in: $0) }
        canvases?.tagInventoryDidSave = { [weak inventory] in inventory?.publishInventoryChange() }
        canvases?.tagInventoryDidRefresh = { [weak inventory] in inventory?.invalidateInventory() }
        tagInventoryObservation = tags.inventoryChanges.sink { [weak notes] in notes?.objectWillChange.send() }
        tags.afterChange = { [weak self] in self?.refreshItemStores() }
        // Tags come and go through every store and agents: whenever the set
        // in use changes, new tags get their colour (once per change, after
        // the save that changed it).
        tagColourObservation = tags.inventoryChanges.sink { [weak self] in self?.scheduleTagColourRefresh() }
        scheduleTagColourRefresh()
    }

    // MARK: - Tag colours

    /// Gives every tag in use with no colour its colour and rebuilds the
    /// palette. Runs on its own after any change to the tags in use.
    func refreshTagColours() {
        tagColours.refresh(inUse: tags.namesOldestFirst)
    }

    private func scheduleTagColourRefresh() {
        guard !tagColourRefreshPending else { return }
        tagColourRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            tagColourRefreshPending = false
            refreshTagColours()
        }
    }

    /// Changes a tag's colour (the tag menu's Colour row), as one undo step.
    @discardableResult
    func setTagHue(_ hue: AtticTagHue, for tag: String, in history: UndoHistoryID = .library) -> Bool {
        guard let name = AtticTag.normalize(tag) else { return fail(TagServiceError.invalidTag(tag).localizedDescription) }
        let previous = tagColours.palette.hue(for: name)
        guard previous != hue else { return true }
        var succeeded = false
        undo.perform(in: history) {
            guard tagColours.setHue(hue, for: name) else {
                _ = fail(tagColours.lastErrorMessage)
                return nil
            }
            succeeded = true
            return UndoStep(
                name: String(localized: "Tag Colour"),
                undo: { [colours = tagColours] in colours.setHue(previous, for: name) },
                redo: { [colours = tagColours] in colours.setHue(hue, for: name) }
            )
        }
        return succeeded
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
        let serial = tasks.errorSerial
        defer { if created == nil { _ = taskOutcome(false, since: serial, ids: []) } }
        undo.perform(in: history) {
            guard let tasks = self.tasks.commit(drafts), !tasks.isEmpty else { return nil }
            created = tasks
            let ids = tasks.map(\.id)
            // What this step made: the tasks and any subtasks they came with.
            let owned = FamilyOwnership(liveFamilyMembers(of: ids))
            return UndoStep(
                name: ids.count == 1 ? "Add Task" : "Add \(ids.count) Tasks",
                undoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    return self.deleteFamiliesFromHistory(ids, owning: owned)
                },
                redoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    return self.restoreFamiliesFromHistory(ids, owning: owned)
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
    ) -> CommandOutcome {
        var succeeded = false
        let serial = tasks.errorSerial
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
        return taskOutcome(succeeded, since: serial, ids: [id])
    }

    /// Restore an archived task with all requested edits as one durable
    /// operation and one history step. Nothing enters history on failure.
    @discardableResult
    func restoreAndUpdateTask(
        _ id: UUID,
        title: String? = nil,
        priority: TaskPriority? = nil,
        status: TaskStatus,
        tags: [String]? = nil,
        dueDay: DueDay?? = nil,
        in history: UndoHistoryID = .tasks
    ) -> CommandOutcome {
        var succeeded = false
        let serial = tasks.errorSerial
        undo.perform(in: history) {
            guard let before = tasks.listedEditableState(of: id),
                  let loggedAt = tasks.listedTask(withID: id)?.doneLoggedAt,
                  tasks.restoreAndUpdateTask(id, title: title, priority: priority, status: status,
                                             tags: tags, dueDay: dueDay) else { return nil }
            // The save has committed even if the subsequent list refresh
            // failed. Missing presentation state can only omit history.
            succeeded = true
            guard let after = tasks.editableState(of: id) else { return nil }
            let store = self.tasks
            return UndoStep(
                name: "Change Task State",
                undoOutcome: { store.undoReturnFromDoneLog(from: [after], to: [before], logging: [id: loggedAt]) },
                redoOutcome: {
                    // Undo may restore fields but leave a changed family
                    // live. That compound restoration no longer applies.
                    guard store.listedTask(withID: id)?.doneLoggedAt != nil else { return .obsolete }
                    return store.restoreAndUpdateTask(id, title: title, priority: priority, status: status,
                                                      tags: tags, dueDay: dueDay) ? .applied : .failed
                }
            )
        }
        return taskOutcome(succeeded, since: serial, ids: [id])
    }

    /// A reorder within a group (⌘↑ ⌘↓, or a drop onto a row) as one step.
    @discardableResult
    func moveTask(_ id: UUID, relativeTo targetID: UUID, in history: UndoHistoryID = .tasks) -> CommandOutcome {
        orderStep(id, in: history) { tasks.reorder(taskID: id, relativeTo: targetID) }
    }

    /// A drag reorder to a place in the task's group as one step.
    @discardableResult
    func moveTask(_ id: UUID, toIndex index: Int, in history: UndoHistoryID = .tasks) -> CommandOutcome {
        orderStep(id, in: history) { tasks.move(taskID: id, toIndex: index) }
    }

    private func orderStep(_ id: UUID, in history: UndoHistoryID, _ move: () -> Bool) -> CommandOutcome {
        var succeeded = false
        let serial = tasks.errorSerial
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
        return taskOutcome(succeeded, since: serial, ids: [id])
    }

    /// Completes a task with its unfinished subtasks as one step.
    @discardableResult
    func completeTask(_ id: UUID, in history: UndoHistoryID = .tasks) -> CommandOutcome {
        var succeeded = false
        let serial = tasks.errorSerial
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
        return taskOutcome(succeeded, since: serial, ids: [id])
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
    ) -> CommandOutcome {
        let requested = ids
        let ids = ids.filter { tasks.task(withID: $0) != nil }
        guard !ids.isEmpty else { return taskOutcome(false, since: tasks.errorSerial, ids: requested) }
        var succeeded = false
        let serial = tasks.errorSerial
        undo.perform(in: history) {
            // Completing a main task takes its open subtasks along, as the
            // circle does; their states are part of the step.
            var touched = ids
            if status == .done {
                for id in ids { touched += tasks.subtasks(of: id).map(\.id) }
            }
            let before = touched.compactMap(tasks.editableState(of:))
            // One context, one save: every task changes or none does.
            guard tasks.updateBatch(ids, priority: priority, status: status, addingTag: addingTag) else { return nil }
            succeeded = true
            let after = touched.compactMap(tasks.editableState(of:))
            guard before != after else { return nil }
            let name = status != nil ? "Change Task State" : "Edit Tasks"
            return editStep(name, before: before, after: after)
        }
        return taskOutcome(succeeded, since: serial, ids: ids)
    }

    /// Moves several tasks to Recently Deleted as one step (the selection
    /// bar, Delete on a multi-selection). Undo brings them all back.
    @discardableResult
    func deleteTasks(_ ids: [UUID], in history: UndoHistoryID = .tasks) -> CommandOutcome {
        let serial = tasks.errorSerial
        guard ids.count > 1 else {
            let deleted = ids.first.map { delete(AtticItemRef(.task, $0), in: history) } ?? false
            return taskOutcome(deleted, since: serial, ids: ids)
        }
        let deleted = undo.perform(in: history) {
            guard deleteFamiliesNow(ids) else { return nil }
            // What this delete took, to keep Redo from taking more.
            let owned = FamilyOwnership(recordedMembers(of: ids))
            return UndoStep(
                name: "Delete \(ids.count) Tasks",
                undoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    return self.restoreFamiliesFromHistory(ids, owning: owned)
                },
                redoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    return self.deleteFamiliesFromHistory(ids, owning: owned)
                }
            )
        }
        return taskOutcome(deleted, since: serial, ids: ids)
    }

    /// Brings a finished task back to Now as to do, as one step; undo puts
    /// it back where it was (the done group, or the Done log), in one save
    /// over its replicas and family (`TaskStore.undoRestoreToNow`, Astra 4).
    @discardableResult
    func restoreToNow(_ id: UUID, in history: UndoHistoryID = .tasks) -> CommandOutcome {
        restoreToNow([id], in: history)
    }

    /// Restore to Now for one or several finished tasks as one step and one
    /// save (round 4): undo puts every one back where it was (today's done
    /// group, or the Done log with its family) in one save; redo restores
    /// them all again.
    @discardableResult
    func restoreToNow(_ ids: [UUID], in history: UndoHistoryID = .tasks) -> CommandOutcome {
        var succeeded = false
        let serial = tasks.errorSerial
        undo.perform(in: history) {
            let before = ids.compactMap(tasks.listedEditableState(of:))
            guard before.count == ids.count else { return nil }
            var logging: [UUID: Date] = [:]
            for id in ids { if let loggedAt = tasks.listedTask(withID: id)?.doneLoggedAt { logging[id] = loggedAt } }
            guard tasks.restoreToNow(taskIDs: ids) else { return nil }
            let after = ids.compactMap(tasks.editableState(of:))
            succeeded = true
            let store = self.tasks
            return UndoStep(
                name: ids.count == 1 ? "Restore Task" : "Restore \(ids.count) Tasks",
                undoOutcome: {
                    store.undoReturnFromDoneLog(from: after, to: before, logging: logging)
                },
                redoOutcome: {
                    guard ids.allSatisfy({ store.listedTask(withID: $0) != nil }) else { return .obsolete }
                    return store.restoreToNow(taskIDs: ids) ? .applied : .failed
                }
            )
        }
        return taskOutcome(succeeded, since: serial, ids: ids)
    }

    /// Reopens finished tasks (the circle, Space, "Mark as Not Done"),
    /// each back to the state and place it was finished from, with the
    /// subtasks finished along with it (`TaskStore.reopen`, Astra 20), as
    /// one step and one save whatever the undo history holds. Undo finishes
    /// them again, and puts Done log tasks back in the log, in one save.
    @discardableResult
    func reopenTasks(_ ids: [UUID], in history: UndoHistoryID = .tasks) -> CommandOutcome {
        var succeeded = false
        let serial = tasks.errorSerial
        undo.perform(in: history) {
            let before = ids.flatMap(tasks.listedFamilyStates(of:))
            guard !before.isEmpty, before.count >= ids.count else { return nil }
            let logged = ids.compactMap { id in tasks.listedTask(withID: id).flatMap { $0.doneLoggedAt.map { (id, $0) } } }
            guard tasks.reopen(taskIDs: ids) else { return nil }
            succeeded = true
            let after = before.map(\.id).compactMap(tasks.listedEditableState(of:))
            guard before != after else { return nil }
            let store = self.tasks
            let name = ids.count == 1 ? "Reopen Task" : "Reopen \(ids.count) Tasks"
            guard !logged.isEmpty else { return editStep(name, before: before, after: after) }
            return UndoStep(
                name: name,
                undoOutcome: {
                    // Finished again and back in the log, families and all,
                    // in one save.
                    store.undoReturnFromDoneLog(from: after, to: before, logging: Dictionary(logged, uniquingKeysWith: { first, _ in first }))
                },
                redoOutcome: {
                    store.reopen(taskIDs: ids) ? .applied : (ids.allSatisfy { store.listedTask(withID: $0) != nil } ? .failed : .obsolete)
                }
            )
        }
        return taskOutcome(succeeded, since: serial, ids: ids)
    }

    // MARK: - Undo and redo, with outcomes

    /// Undoes the history's last step and says what happened (the toast's
    /// Undo, ⌘Z): `.failed` keeps the step to try again; a step that can
    /// never apply again is dropped and reported as not retryable.
    @discardableResult
    func undo(in history: UndoHistoryID) -> CommandOutcome {
        let serial = tasks.errorSerial
        return historyOutcome(undo.undoStep(in: history), since: serial, verb: String(localized: "undo"))
    }

    @discardableResult
    func redo(in history: UndoHistoryID) -> CommandOutcome {
        let serial = tasks.errorSerial
        return historyOutcome(undo.redoStep(in: history), since: serial, verb: String(localized: "redo"))
    }

    private func historyOutcome(_ outcome: UndoOutcome?, since serial: UInt64, verb: String) -> CommandOutcome {
        let reported = tasks.errorSerial != serial ? tasks.lastErrorMessage : nil
        switch outcome {
        case .applied?:
            return .applied
        case nil:
            return recordFailure(CommandFailure(String(localized: "Nothing to \(verb)."), canRetry: false))
        case .obsolete?:
            return recordFailure(CommandFailure(reported ?? String(localized: "This change can no longer be undone."), canRetry: false))
        case .failed?:
            return recordFailure(CommandFailure(reported ?? String(localized: "Couldn’t \(verb). Try again."), canRetry: true))
        }
    }

    /// A task command's outcome. A failure carries the store's own message
    /// when this command reported one (whatever family owns the notice),
    /// and is not retryable when a task it names is gone from the lists or
    /// the store refused the edit (a rule, not a save).
    func taskOutcome(_ succeeded: Bool, since serial: UInt64, ids: [UUID]) -> CommandOutcome {
        if succeeded { return .applied }
        if ids.contains(where: { tasks.listedTask(withID: $0) == nil }) {
            return recordFailure(.taskGone)
        }
        if tasks.errorSerial != serial, let message = tasks.lastErrorMessage {
            return recordFailure(CommandFailure(message, canRetry: tasks.lastErrorIsRetryable))
        }
        return recordFailure(CommandFailure(String(localized: "Couldn’t save the change. Try again.")))
    }

    private func recordFailure(_ failure: CommandFailure) -> CommandOutcome {
        lastFailure = failure
        lastErrorMessage = failure.message
        return .failed(failure)
    }

    // MARK: - Delete and restore

    /// Moves any item to Recently Deleted as one step. Agents and people use
    /// the same call; nothing here deletes permanently.
    @discardableResult
    func delete(_ ref: AtticItemRef, in history: UndoHistoryID? = nil) -> Bool {
        undo.perform(in: history ?? Self.defaultHistory(for: ref)) {
            guard performDelete(ref) else { return nil }
            // What this delete took, to keep Redo from taking more.
            let owned = FamilyOwnership(ownedMembers(of: ref))
            return UndoStep(
                name: "Delete \(Self.noun(for: ref.kind))",
                undoOutcome: { [weak self] in self?.restoreOutcome(ref, owning: owned) ?? .obsolete },
                redoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    return self.deleteOutcome(ref, owning: owned)
                }
            )
        }
    }

    /// Restores an item from Recently Deleted, with what its delete took
    /// along and its links, as one step.
    @discardableResult
    func restore(_ ref: AtticItemRef, in history: UndoHistoryID = .library) -> Bool {
        undo.perform(in: history) {
            // Read before the restore clears the record of what came back.
            let owned = FamilyOwnership(ownedMembers(of: ref))
            guard performRestore(ref) else { return nil }
            return UndoStep(
                name: "Restore \(Self.noun(for: ref.kind))",
                undoOutcome: { [weak self] in self?.deleteOutcome(ref, owning: owned) ?? .obsolete },
                redoOutcome: { [weak self] in
                    guard let self else { return .obsolete }
                    return self.restoreOutcome(ref, owning: owned)
                }
            )
        }
    }

    /// Attachments removed on their own from live tasks and notes.
    func recentlyDeletedAttachments() -> [DeletedAttachmentSummary] {
        (tasks.recentlyDeletedAttachments() + (notes?.recentlyDeletedAttachments() ?? []))
            .sorted { $0.deletedAt != $1.deletedAt ? $0.deletedAt > $1.deletedAt : $0.attachmentID.uuidString < $1.attachmentID.uuidString }
    }

    /// Puts a removed attachment back on its task or note, as one step:
    /// undo removes it again (back to Recently Deleted), redo restores it.
    @discardableResult
    func restoreAttachment(_ summary: DeletedAttachmentSummary, in history: UndoHistoryID = .library) -> Bool {
        undo.perform(in: history) {
            guard performRestoreAttachment(summary) else { return nil }
            return UndoStep(
                name: "Restore Attachment",
                undoOutcome: { [weak self] in self?.removeAttachmentOutcome(summary) ?? .obsolete },
                redoOutcome: { [weak self] in self?.restoreAttachmentOutcome(summary) ?? .obsolete }
            )
        }
    }

    /// Undo of an attachment restore: remove it again, if it is still shown
    /// on its live task or note.
    func removeAttachmentOutcome(_ summary: DeletedAttachmentSummary) -> UndoOutcome {
        switch summary.owner.kind {
        case .task:
            guard tasks.task(withID: summary.owner.id)?.attachments.contains(where: { $0.id == summary.attachmentID }) == true else {
                return .obsolete
            }
            return tasks.removeAttachment(summary.attachmentID, from: summary.owner.id) ? .applied : .failed
        case .note:
            guard let notes,
                  let attachment = notes.attachments(for: summary.owner.id).first(where: { $0.id == summary.attachmentID }) else {
                return .obsolete
            }
            return notes.removeAttachment(attachment) ? .applied : .failed
        case .canvas:
            return .obsolete
        }
    }

    /// Redo of an attachment restore: only one still removed can come back.
    private func restoreAttachmentOutcome(_ summary: DeletedAttachmentSummary) -> UndoOutcome {
        if performRestoreAttachment(summary) { return .applied }
        return recentlyDeletedAttachments().contains { $0.attachmentID == summary.attachmentID } ? .failed : .obsolete
    }

    func performRestoreAttachment(_ summary: DeletedAttachmentSummary) -> Bool {
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
        purgeDeleted(before: RecentlyDeletedPolicy.purgeCutoff(now: now, calendar: calendar))
    }

    /// Empties Recently Deleted: removes for good exactly the deletions the
    /// person confirmed (`selection`, the entries the confirmation listed,
    /// each with the deletion time it had then), including canvases deleted
    /// before Recently Deleted existed. Anything deleted after the list was
    /// shown, restored since, or deleted again, is not in the selection and
    /// stays. The same replica rules as the daily cleanup apply: anything
    /// whose copies disagree, or whose delete is incomplete, is kept and
    /// stays listed. Called only from Settings, after the person confirmed;
    /// agents can never empty Recently Deleted.
    @discardableResult
    func emptyRecentlyDeleted(_ selection: RecentlyDeletedSelection) -> RecentlyDeletedPurgeReport {
        guard !selection.isEmpty else { return RecentlyDeletedPurgeReport() }
        return purgeDeleted(before: .distantFuture, confirmed: selection)
    }

    private func purgeDeleted(before cutoff: Date, confirmed: RecentlyDeletedSelection? = nil) -> RecentlyDeletedPurgeReport {
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
        report.taskIDs = committed(tasks.purgeDeleted(
            before: cutoff, confirmed: confirmed?.items(.task), alongside: stageLinks(.task)
        ))
        report.noteIDs = committed(notes?.purgeDeleted(
            before: cutoff, confirmed: confirmed?.items(.note), alongside: stageLinks(.note)
        ) ?? [])
        report.canvasIDs = committed(canvases?.purgeDeletedCanvases(
            before: cutoff, confirmed: confirmed?.items(.canvas), alongside: stageLinks(.canvas)
        ) ?? [])
        report.attachmentCount = tasks.purgeRemovedAttachments(before: cutoff, confirmed: confirmed?.attachments(of: .task))
            + (notes?.purgeRemovedAttachments(before: cutoff, confirmed: confirmed?.attachments(of: .note)) ?? 0)
        // Links removed on their own are not listed in Recently Deleted, so
        // emptying it leaves them to the daily cleanup's 30 days.
        if confirmed == nil {
            report.removedLinks += links.purgeRemovedLinks(before: cutoff)
        }
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

    /// `includingDoneLog`: also reach a task the daily cleanup moved to the
    /// Done log, which the undo of a restore has to send back.
    private func performDelete(_ ref: AtticItemRef, includingDoneLog: Bool = false) -> Bool {
        switch ref.kind {
        case .task:
            let listed = includingDoneLog ? tasks.listedTask(withID: ref.id) : tasks.task(withID: ref.id)
            guard listed != nil else { return fail("No task exists with id \(ref.id.uuidString).") }
            return deleteFamiliesNow([ref.id], includingDoneLog: includingDoneLog) || fail(tasks.lastErrorMessage)
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

    func performRestore(_ ref: AtticItemRef) -> Bool {
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

    /// Undo/redo of a delete, and the undo of a restore: moving an item that
    /// is no longer listed (gone or already in Recently Deleted) can never
    /// apply again. A task in the Done log is listed: a restored archived
    /// task goes back to Recently Deleted from there, without a history step
    /// of its own.
    ///
    /// `owning`: the tasks the step that is being undone or redone brought
    /// back or took away. Deleting a main task takes every live subtask with
    /// it, so a live subtask outside that set was put there by some other
    /// step (Tasks and Recently Deleted keep separate histories); the step
    /// no longer reaches the task and the family stays.
    func deleteOutcome(_ ref: AtticItemRef, owning: FamilyOwnership) -> UndoOutcome {
        if ref.kind == .task {
            if let stop = familyGuard(of: [ref.id], owning: owning.members) { return stop }
        }
        if performDelete(ref, includingDoneLog: true) {
            if ref.kind == .task { owning.members = ownedMembers(of: ref) }
            return .applied
        }
        let shown: Bool = switch ref.kind {
        case .task: tasks.listedTask(withID: ref.id) != nil
        case .note: notes?.note(withID: ref.id) != nil
        case .canvas: canvases?.canvases.contains(where: { $0.id == ref.id }) == true
        }
        return shown ? .failed : .obsolete
    }

    /// What one restore or delete step owns: the tasks that came back with
    /// (or went with) the task it was made for, read from the deletion
    /// record. Undo and Redo check a family delete against this instead of
    /// the family as it is right now.
    final class FamilyOwnership {
        var members: Set<UUID>
        init(_ members: Set<UUID>) { self.members = members }
    }

    enum FamilyCheck {
        /// Every live subtask the delete would take belongs to the step.
        case owned
        /// One does not: someone else restored or created it.
        case foreign
        /// The family could not be read.
        case reads
    }

    /// The tasks the deletion record for `ref` covers (itself included), or
    /// empty for a note or canvas. Only `restore` and `delete` call it, while
    /// the record exists.
    func ownedMembers(of ref: AtticItemRef) -> Set<UUID> {
        ownedMembers(of: [ref.id], kind: ref.kind)
    }

    func recordedMembers(of ids: [UUID]) -> Set<UUID> {
        ownedMembers(of: ids, kind: .task)
    }

    private func ownedMembers(of ids: [UUID], kind: AtticItemKind) -> Set<UUID> {
        guard kind == .task else { return [] }
        let byRoot = tasks.recordedDeletionMembers(ofRoots: ids)
        return ids.reduce(into: Set(ids)) { $0.formUnion(byRoot[$1] ?? []) }
    }

    /// Whether deleting these tasks would take only tasks in `owned`: the
    /// live subtasks (every replica, the Done log included) of each main
    /// task among them, read now.
    func familyCheck(of ids: [UUID], owned: Set<UUID>) -> FamilyCheck {
        for id in ids {
            guard let listed = tasks.listedTask(withID: id), listed.parentID == nil else { continue }
            guard let family = try? tasks.liveSubtaskIDs(of: id) else { return .reads }
            if !family.isSubset(of: owned) { return .foreign }
        }
        return .owned
    }

    /// The tasks a step owns when it has just made `ids`: each main task and
    /// the live subtasks it has now (a duplicate carries its copies).
    func liveFamilyMembers(of ids: [UUID]) -> Set<UUID> {
        var members = Set(ids)
        for id in ids {
            if let family = try? tasks.liveSubtaskIDs(of: id) { members.formUnion(family) }
        }
        return members
    }

    /// Nil when deleting these tasks takes only what the step owns; the
    /// outcome that stops the step otherwise (`.obsolete` for a subtask
    /// another step put there, `.failed` when the family cannot be read).
    func familyGuard(of ids: [UUID], owning owned: Set<UUID>) -> UndoOutcome? {
        switch familyCheck(of: ids, owned: owned) {
        case .reads: .failed
        case .foreign: .obsolete
        case .owned: nil
        }
    }

    /// The one place a command deletes task families straight away (the
    /// first run of Delete, before any history exists for it). An Undo or
    /// Redo closure never calls this: it goes through
    /// `deleteFamiliesFromHistory`, and `FamilyDeleteGuardTests` checks that.
    func deleteFamiliesNow(_ ids: [UUID], includingDoneLog: Bool = false) -> Bool {
        tasks.delete(taskIDs: ids, includingDoneLog: includingDoneLog)
    }

    /// The one way an Undo or Redo closure deletes task families. It refuses
    /// when a live subtask lies outside what the step owns (Tasks and
    /// Recently Deleted keep separate histories, so another step may have put
    /// it there), and takes the ownership again from the deletion record once
    /// the delete is saved.
    func deleteFamiliesFromHistory(
        _ ids: [UUID],
        owning owned: FamilyOwnership,
        includingDoneLog: Bool = false
    ) -> UndoOutcome {
        if let stop = familyGuard(of: ids, owning: owned.members) { return stop }
        if deleteFamiliesNow(ids, includingDoneLog: includingDoneLog) {
            owned.members = recordedMembers(of: ids)
            return .applied
        }
        // Tasks that left the list since (deleted, or moved to the Done log
        // when it is not reached) can't be taken back by this step any more.
        let listed = ids.allSatisfy {
            (includingDoneLog ? tasks.listedTask(withID: $0) : tasks.task(withID: $0)) != nil
        }
        return listed ? .failed : .obsolete
    }

    /// What restoring these tasks would bring back, when that is all the step
    /// owns: the members of each one's current deletion record, read before
    /// the restore clears it. The other case is the outcome that stops the
    /// step: `.obsolete` when a record holds a task outside `owned` (another
    /// step deleted it, and restoring would undo that), `.failed` when the
    /// records cannot be read. A smaller record is fine: a subtask deleted on
    /// its own stays apart.
    func restoreClearance(of ids: [UUID], owning owned: Set<UUID>) -> Result<Set<UUID>, UndoOutcome> {
        let records: [UUID: Set<UUID>]
        do { records = try tasks.deletionRecords(ofRoots: ids) } catch { return .failure(.failed) }
        var members = Set(ids)
        for id in ids {
            guard let record = records[id] else { continue }
            if !record.isSubset(of: owned) { return .failure(.obsolete) }
            members.formUnion(record)
        }
        return .success(members)
    }

    /// The one way an Undo or Redo closure restores task families from
    /// Recently Deleted (for several tasks at once). It refuses when a
    /// deletion record holds a task the step does not own, and replaces the
    /// ownership only once the restore is saved.
    func restoreFamiliesFromHistory(_ ids: [UUID], owning owned: FamilyOwnership) -> UndoOutcome {
        let members: Set<UUID>
        switch restoreClearance(of: ids, owning: owned.members) {
        case .failure(let stop): return stop
        case .success(let read): members = read
        }
        if tasks.restoreDeleted(taskIDs: ids) {
            owned.members = members
            return .applied
        }
        return ids.allSatisfy { state(of: AtticItemRef(.task, $0)) == .deleted } ? .failed : .obsolete
    }

    /// Undo/redo of a restore: only an item still in Recently Deleted can be
    /// restored; a refusal of one that is (a replica conflict) is kept.
    /// The single-item counterpart of `restoreFamiliesFromHistory`, for any
    /// kind of item (notes and canvases own no family).
    func restoreOutcome(_ ref: AtticItemRef, owning owned: FamilyOwnership) -> UndoOutcome {
        var members: Set<UUID>?
        if ref.kind == .task {
            switch restoreClearance(of: [ref.id], owning: owned.members) {
            case .failure(let stop): return stop
            case .success(let read): members = read
            }
        }
        if performRestore(ref) {
            if let members { owned.members = members }
            return .applied
        }
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

/// The deletions a person confirmed when emptying Recently Deleted: every
/// entry the confirmation listed, by identity and the deletion time it had
/// then (so the same item deleted again later is a different deletion).
struct RecentlyDeletedSelection: Equatable {
    var items: [AtticItemRef: Date] = [:]
    /// Attachment id → its owner kind and removal time.
    var attachments: [UUID: (kind: AtticItemKind, removedAt: Date)] = [:]

    init(items: [DeletedItemSummary] = [], attachments: [DeletedAttachmentSummary] = []) {
        for item in items { self.items[item.ref] = item.deletedAt }
        for attachment in attachments {
            self.attachments[attachment.attachmentID] = (attachment.owner.kind, attachment.deletedAt)
        }
    }

    var count: Int { items.count + attachments.count }
    var isEmpty: Bool { count == 0 }

    func contains(item ref: AtticItemRef, deletedAt: Date) -> Bool { items[ref] == deletedAt }
    func contains(attachment id: UUID, removedAt: Date) -> Bool { attachments[id]?.removedAt == removedAt }

    func items(_ kind: AtticItemKind) -> [UUID: Date] {
        Dictionary(uniqueKeysWithValues: items.filter { $0.key.kind == kind }.map { ($0.key.id, $0.value) })
    }

    func attachments(of kind: AtticItemKind) -> [UUID: Date] {
        Dictionary(uniqueKeysWithValues: attachments.filter { $0.value.kind == kind }.map { ($0.key, $0.value.removedAt) })
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items
            && lhs.attachments.mapValues { "\($0.kind.rawValue)|\($0.removedAt.timeIntervalSinceReferenceDate)" }
                == rhs.attachments.mapValues { "\($0.kind.rawValue)|\($0.removedAt.timeIntervalSinceReferenceDate)" }
    }
}
