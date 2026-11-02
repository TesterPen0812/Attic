import Foundation
import SwiftData

/// Stage 4 task-page persistence. All commands use a private, non-autosaving
/// context and commit once; the caller never receives a live SwiftData model.
@MainActor
final class PhoneTaskSubtasks {
    enum Failure: LocalizedError, Equatable {
        case missingTask, notMainTask, notSubtask, inactiveTask, conflictingReplicas
        case parentCompleted, emptyTitle, invalidOrder, orderLimit, conflictingNote, unsafeWriting, existingWriting

        var errorDescription: String? {
            switch self {
            case .missingTask: "The task no longer exists."
            case .notMainTask: "A subtask needs a main task, not another subtask."
            case .notSubtask: "This task is not a subtask."
            case .inactiveTask: "This task is deleted or in the Done log."
            case .conflictingReplicas: "Task copies disagree. Refresh before editing."
            case .parentCompleted: "Reopen the main task before adding or reopening a subtask."
            case .emptyTitle: "A subtask needs a title."
            case .invalidOrder: "The subtask order changed. Refresh before moving it."
            case .orderLimit: "The subtask order has no remaining space."
            case .conflictingNote: "The task's note association or stored copies disagree."
            case .unsafeWriting: "This writing contains an unsupported inline object."
            case .existingWriting: "This task already has writing. Open it before editing."
            }
        }
    }

    struct Subtask: Identifiable, Equatable {
        let id: UUID, parentID: UUID, title: String, status: TaskStatus
        let manualOrder: Int64?, createdAt: Date, updatedAt: Date, completedAt: Date?
        var isDone: Bool { status == .done }

        fileprivate init(_ row: TaskItem) {
            id = row.id
            parentID = row.parentID! // requiredChild/children verify the parent before construction
            title = row.title; status = row.status; manualOrder = row.manualOrder
            createdAt = row.createdAt; updatedAt = row.updatedAt; completedAt = row.completedAt
        }
    }

    /// Content is the exact stored wire image, including nil and unknown formats.
    /// Opening the note never decodes or saves the document.
    struct TaskNote: Identifiable, Equatable {
        let id: UUID, taskID: UUID, title: String, body: String, content: Data?
        let contentFormat: Int, contentFingerprint: String?, revision: Int64, revisionID: UUID?
        let updatedAt: Date

        fileprivate init(_ row: NoteItem) {
            id = row.id
            taskID = row.taskID! // ownedNote verifies ownership
            title = row.title; body = row.body; content = row.content
            contentFormat = row.contentFormat; contentFingerprint = row.contentFingerprint
            revision = row.revision; revisionID = row.revisionID; updatedAt = row.updatedAt
        }
    }

    private let container: ModelContainer
    private let now: () -> Date
    private let save: (ModelContext) throws -> Void
    private let stride: Int64 = 1_024

    init(container: ModelContainer, now: @escaping () -> Date = { Date() },
         save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.container = container; self.now = now; self.save = save
    }

    private func context() -> ModelContext {
        let result = ModelContext(container)
        result.autosaveEnabled = false
        return result
    }

    private func transaction<Result>(_ operation: (ModelContext) throws -> Result) throws -> Result {
        let writer = context()
        do {
            let result = try operation(writer)
            if writer.hasChanges { try save(writer) }
            return result
        } catch {
            writer.rollback()
            throw error
        }
    }

    private static func cleanTitle(_ title: String) -> String {
        title.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private typealias Families = [UUID: [TaskItem]]

    private func taskFamilies(in context: ModelContext) throws -> Families {
        Dictionary(grouping: try context.fetch(FetchDescriptor<TaskItem>()), by: \.id)
    }

    /// Detect ambiguous physical copies before any stage writes. Never
    /// choose a live replica over a tombstone or a different parent/status.
    private func task(_ id: UUID, in families: Families, active: Bool = true) throws -> (TaskItem, [TaskItem]) {
        guard let rows = families[id], let first = rows.first else { throw Failure.missingTask }
        guard rows.allSatisfy({ row in
            row.parentID == first.parentID && row.deletedAt == first.deletedAt && row.doneLoggedAt == first.doneLoggedAt &&
            row.statusRaw == first.statusRaw && row.manualOrder == first.manualOrder && row.title == first.title &&
            row.associationGeneration == first.associationGeneration && row.completedAt == first.completedAt &&
            row.completedFromRaw == first.completedFromRaw && row.completedFromOrder == first.completedFromOrder
        }), TaskStatus(rawValue: first.statusRaw) != nil else { throw Failure.conflictingReplicas }
        if active && (first.deletedAt != nil || first.doneLoggedAt != nil) { throw Failure.inactiveTask }
        let shown = rows.max { a, b in
            a.updatedAt == b.updatedAt
                ? String(reflecting: a.persistentModelID) < String(reflecting: b.persistentModelID)
                : a.updatedAt < b.updatedAt
        }!
        return (shown, rows)
    }

    private func mainTask(_ id: UUID, in families: Families, canAdd: Bool = false) throws -> TaskItem {
        let (root, _) = try task(id, in: families)
        guard root.parentID == nil else { throw Failure.notMainTask }
        if canAdd && root.status == .done { throw Failure.parentCompleted }
        return root
    }

    private func child(_ id: UUID, in families: Families) throws -> (TaskItem, [TaskItem], TaskItem) {
        let (child, replicas) = try task(id, in: families)
        guard let parentID = child.parentID, parentID != id else { throw Failure.notSubtask }
        let parent = try mainTask(parentID, in: families)
        // Do not strand a grandchild when manipulating a malformed nested family.
        for (otherID, copies) in families where otherID != id && copies.contains(where: { $0.parentID == id }) {
            let (descendant, _) = try task(otherID, in: families, active: false)
            if descendant.deletedAt == nil { throw Failure.notMainTask }
        }
        return (child, replicas, parent)
    }

    private func children(of parentID: UUID, in families: Families) throws -> [TaskItem] {
        var visible: [TaskItem] = []
        for (id, copies) in families where copies.contains(where: { $0.parentID == parentID }) {
            let (row, _) = try task(id, in: families, active: false)
            guard row.parentID == parentID else { throw Failure.conflictingReplicas }
            if row.deletedAt == nil && row.doneLoggedAt == nil { visible.append(row) }
        }
        return visible.sorted(by: Self.before)
    }

    private static func before(_ a: TaskItem, _ b: TaskItem) -> Bool {
        if (a.status == .done) != (b.status == .done) { return a.status != .done }
        if (a.manualOrder ?? 0) != (b.manualOrder ?? 0) {
            return (a.manualOrder ?? 0) > (b.manualOrder ?? 0)
        }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    func subtasks(of parentID: UUID) throws -> [Subtask] {
        let reader = context()
        let families = try taskFamilies(in: reader)
        _ = try mainTask(parentID, in: families)
        return try children(of: parentID, in: families).map(Subtask.init)
    }

    @discardableResult
    func addSubtask(to parentID: UUID, title: String) throws -> Subtask {
        let clean = Self.cleanTitle(title)
        guard !clean.isEmpty else { throw Failure.emptyTitle }
        return try transaction { context in
            let families = try taskFamilies(in: context)
            _ = try mainTask(parentID, in: families, canAdd: true)
            let open = try children(of: parentID, in: families).filter { $0.status != .done }
            var order: Int64?
            if let lowest = open.map({ $0.manualOrder ?? 0 }).min() {
                let (newOrder, overflow) = lowest.subtractingReportingOverflow(stride)
                guard !overflow else { throw Failure.orderLimit }
                order = newOrder
            }
            let stamp = now()
            let row = TaskItem(title: clean, createdAt: stamp, manualOrder: order, parentID: parentID)
            row.listOrderVersion = TaskItem.currentListOrderVersion
            context.insert(row)
            return Subtask(row)
        }
    }

    @discardableResult
    func editSubtask(id: UUID, title: String) throws -> Subtask {
        let clean = Self.cleanTitle(title)
        guard !clean.isEmpty else { throw Failure.emptyTitle }
        return try transaction { context in
            let families = try taskFamilies(in: context)
            let (current, copies, _) = try child(id, in: families)
            guard current.title != clean else { return Subtask(current) }
            let stamp = now()
            for row in copies {
                row.title = clean
                row.updatedAt = max(row.updatedAt, stamp)
            }
            return Subtask(current)
        }
    }

    /// Toggle the step's circle. A previously in-progress step reopens in
    /// progress; any newly completed step goes to the front of Done steps.
    @discardableResult
    func toggleSubtask(id: UUID) throws -> Subtask {
        try transaction { context in
            let families = try taskFamilies(in: context)
            let (current, copies, parent) = try child(id, in: families)
            let reopening = current.status == .done
            if reopening && parent.status == .done { throw Failure.parentCompleted }
            let siblings = try children(of: parent.id, in: families)
            let destinationOrder = siblings.filter { $0.id != id && ($0.status == .done) == !reopening }
                .map { $0.manualOrder ?? 0 }.max() ?? 0
            let (order, overflow) = destinationOrder.addingReportingOverflow(stride)
            guard !overflow else { throw Failure.orderLimit }
            let restored = current.completedFromRaw.flatMap(TaskStatus.init(rawValue:))
            let destination: TaskStatus = reopening && restored != nil && restored != .done ? restored! : .todo
            let timestamp = now()
            for row in copies {
                if reopening {
                    row.status = destination
                    row.completedAt = nil; row.completedFromRaw = nil; row.completedFromOrder = nil
                } else {
                    row.completedFromRaw = row.statusRaw
                    row.completedFromOrder = row.manualOrder
                    row.status = .done; row.completedAt = timestamp
                }
                row.manualOrder = order; row.listOrderVersion = TaskItem.currentListOrderVersion
                row.updatedAt = max(row.updatedAt, timestamp)
            }
            return Subtask(current)
        }
    }

    /// The index belongs to this subtask's own unfinished/Done group, not the
    /// combined visible list. No move may cross the group boundary.
    @discardableResult
    func reorderSubtask(id: UUID, toIndex: Int) throws -> [Subtask] {
        try transaction { context in
            let families = try taskFamilies(in: context)
            let (current, _, parent) = try child(id, in: families)
            let siblings = try children(of: parent.id, in: families)
            var group = siblings.filter { ($0.status == .done) == (current.status == .done) }
            guard let from = group.firstIndex(where: { $0.id == id }), group.indices.contains(toIndex) else {
                throw Failure.invalidOrder
            }
            guard from != toIndex else { return siblings.map(Subtask.init) }
            let moving = group.remove(at: from)
            group.insert(moving, at: toIndex)
            guard group.count <= Int(Int64.max / stride) else { throw Failure.orderLimit }
            let stamp = now()
            for (index, member) in group.enumerated() {
                let position = Int64(group.count - index) * stride
                for copy in families[member.id] ?? [] {
                    if copy.manualOrder != position || copy.listOrderVersion != TaskItem.currentListOrderVersion {
                        copy.manualOrder = position
                        copy.listOrderVersion = TaskItem.currentListOrderVersion
                        copy.updatedAt = max(copy.updatedAt, stamp)
                    }
                }
            }
            return try children(of: parent.id, in: families).map(Subtask.init)
        }
    }

    /// One-item deletion record for a child; all physical copies stay in
    /// Recently Deleted. Neither the child's nor the parent's note is touched.
    func deleteSubtask(id: UUID) throws {
        try transaction { context in
            let families = try taskFamilies(in: context)
            let (_, copies, _) = try child(id, in: families)
            let stamp = now(), groupID = UUID()
            for row in copies {
                row.deletedAt = stamp
                row.deletionGroupID = groupID
                row.deletionRootID = id
                row.deletionMembersRaw = id.uuidString
                row.updatedAt = max(row.updatedAt, stamp)
            }
        }
    }

    /// A nil result means no live writing has been created yet. Read-only,
    /// including when the note uses an unsupported/newer document format.
    func loadTaskNote(taskID: UUID) throws -> TaskNote? {
        let reader = context()
        let families = try taskFamilies(in: reader)
        let (owner, _) = try task(taskID, in: families)
        return try ownedNote(for: owner, in: reader).map(TaskNote.init)
    }

    /// Create the task's writing only on an explicit write interaction. The
    /// existing note (even opaque content) always wins and is never re-encoded.
    @discardableResult
    func createTaskNoteIfNeeded(taskID: UUID, initialWriting: String = "") throws -> TaskNote {
        guard !initialWriting.contains(NoteDocument.objectCharacter) else { throw Failure.unsafeWriting }
        return try transaction { context in
            let families = try taskFamilies(in: context)
            let (owner, _) = try task(taskID, in: families)
            if let existing = try ownedNote(for: owner, in: context) {
                guard initialWriting.isEmpty else { throw Failure.existingWriting }
                return TaskNote(existing)
            }
            let blocks: [NoteBlock] = [.text(owner.title)] +
                (initialWriting.isEmpty ? [] : initialWriting.components(separatedBy: "\n").map { NoteBlock.text($0) })
            let document = NoteDocument(blocks: blocks, requires: ["taskNote"])
            let bytes = try NoteContentCodec.encode(document)
            let stamp = now()
            let note = NoteItem(title: owner.title, createdAt: stamp)
            note.content = bytes
            note.contentFormat = document.format
            note.body = NoteTextExport.plainBody(document)
            note.plainText = NoteTextExport.plainText(document)
            note.revision = 1; note.revisionID = UUID()
            note.taskID = taskID
            let association = TaskNoteAssociation(taskID: taskID, noteID: note.id)
            association.taskGeneration = owner.associationGeneration
            association.noteGeneration = note.associationGeneration
            context.insert(note)
            context.insert(association)
            return TaskNote(note)
        }
    }

    /// A task may have no note, but never two live own notes. Validate all
    /// physical note/association copies and foreign links before using the slot.
    private func ownedNote(for owner: TaskItem, in context: ModelContext) throws -> NoteItem? {
        let ownerID = owner.id
        let candidates = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.taskID == ownerID }))
        let allLinks = try context.fetch(FetchDescriptor<TaskNoteAssociation>())
        let ownerLinks = allLinks.filter { $0.taskID == ownerID }
        let ids = Array(Set(candidates.map(\.id)).union(ownerLinks.map(\.noteID)))
        let related = ids.isEmpty ? [] : try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate {
            ids.contains($0.id)
        }))
        let families = Dictionary(grouping: related, by: \.id)
        var live: [NoteItem] = []
        for (_, replicas) in families {
            guard let first = replicas.first, replicas.allSatisfy({ row in
                row.taskID == first.taskID && row.deletedAt == first.deletedAt &&
                row.associationGeneration == first.associationGeneration && row.title == first.title &&
                row.body == first.body && row.content == first.content && row.contentFormat == first.contentFormat &&
                row.contentFingerprint == first.contentFingerprint && row.revision == first.revision &&
                row.revisionID == first.revisionID
            }) else { throw Failure.conflictingNote }
            if first.deletedAt == nil && first.taskID == ownerID {
                live.append(replicas.max(by: { $0.updatedAt < $1.updatedAt }) ?? first)
            }
        }
        guard live.count <= 1 else { throw Failure.conflictingNote }
        let current = live.first
        // A corrupt duplicate association UUID or a link to a foreign/live
        // note may not take over this task's slot.
        let relevantLinks = allLinks.filter { $0.taskID == ownerID || (current != nil && $0.noteID == current!.id) }
        for copies in Dictionary(grouping: relevantLinks, by: \.id).values {
            guard let first = copies.first, copies.allSatisfy({ link in
                link.taskID == first.taskID && link.noteID == first.noteID &&
                link.taskGeneration == first.taskGeneration && link.noteGeneration == first.noteGeneration &&
                link.detachedAt == first.detachedAt && link.detachedPreservationID == first.detachedPreservationID
            }) else { throw Failure.conflictingNote }
        }
        for link in relevantLinks where link.detachedAt == nil {
            guard link.detachedPreservationID == nil else { throw Failure.conflictingNote }
            guard let note = families[link.noteID]?.first else { throw Failure.conflictingNote }
            if note.deletedAt != nil { continue } // old deleted note does not occupy the slot
            guard let current, link.taskID == ownerID, link.noteID == current.id,
                  link.taskGeneration == owner.associationGeneration,
                  link.noteGeneration == current.associationGeneration else { throw Failure.conflictingNote }
        }
        return current
    }
}
