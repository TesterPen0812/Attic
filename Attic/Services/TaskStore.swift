import Combine
import CoreData
import Foundation
import SwiftData

struct TaskSectionSnapshot: Identifiable {
    let status: TaskStatus
    let tasks: [TaskItem]

    var id: TaskStatus { status }
}

struct TaskScopeSnapshot {
    let sections: [TaskSectionSnapshot]
    let visibleCount: Int
    let activeCount: Int
}

enum CloudSyncActivityKind: Equatable {
    case setup
    case importData
    case exportData
}

struct CloudSyncEventUpdate: Equatable {
    let id: UUID
    let kind: CloudSyncActivityKind
    let endedAt: Date?
    let succeeded: Bool
    let errorMessage: String?
}

struct CloudSyncStatus: Equatable {
    private(set) var activeEventIDs: Set<UUID> = []
    private(set) var lastSuccessfulImportAt: Date?
    private(set) var lastSuccessfulExportAt: Date?
    private(set) var lastErrorMessage: String?
    private var lastErrorKind: CloudSyncActivityKind?

    var isSyncing: Bool { !activeEventIDs.isEmpty }

    var lastSuccessfulActivityAt: Date? {
        [lastSuccessfulImportAt, lastSuccessfulExportAt]
            .compactMap { $0 }
            .max()
    }

    var title: String {
        if isSyncing { return "Syncing…" }
        if lastErrorMessage != nil { return "Sync issue" }
        if lastSuccessfulActivityAt != nil { return "Synced" }
        return "Waiting for iCloud"
    }

    var symbolName: String {
        if isSyncing { return "arrow.triangle.2.circlepath.icloud" }
        if lastErrorMessage != nil { return "exclamationmark.icloud" }
        if lastSuccessfulActivityAt != nil { return "checkmark.icloud" }
        return "icloud"
    }

    mutating func apply(_ update: CloudSyncEventUpdate) {
        guard let endedAt = update.endedAt else {
            activeEventIDs.insert(update.id)
            return
        }

        activeEventIDs.remove(update.id)
        if update.succeeded {
            switch update.kind {
            case .setup:
                break
            case .importData:
                lastSuccessfulImportAt = endedAt
            case .exportData:
                lastSuccessfulExportAt = endedAt
            }
            if lastErrorKind == update.kind {
                lastErrorMessage = nil
                lastErrorKind = nil
            }
        } else {
            lastErrorMessage = update.errorMessage ?? "iCloud couldn't complete the sync operation."
            lastErrorKind = update.kind
        }
    }
}

struct CloudSyncProtectionState: Equatable {
    private var localSaveGeneration: UInt64 = 0
    private var exportedSaveGeneration: UInt64 = 0
    private var exportStartGenerationByID: [UUID: UInt64] = [:]
    private var activeImportEventIDs: Set<UUID> = []
    private var importRefreshPending = false

    var protectsExport: Bool {
        exportedSaveGeneration < localSaveGeneration
            || !exportStartGenerationByID.isEmpty
    }

    var protectsImport: Bool {
        !activeImportEventIDs.isEmpty || importRefreshPending
    }

    mutating func noteLocalSave() {
        localSaveGeneration &+= 1
    }

    mutating func apply(_ update: CloudSyncEventUpdate) {
        switch (update.kind, update.endedAt) {
        case (.exportData, nil):
            if exportStartGenerationByID[update.id] == nil {
                exportStartGenerationByID[update.id] = localSaveGeneration
            }
        case (.exportData, .some):
            if let coveredGeneration = exportStartGenerationByID.removeValue(forKey: update.id),
               update.succeeded {
                exportedSaveGeneration = max(exportedSaveGeneration, coveredGeneration)
            }
        case (.importData, nil):
            activeImportEventIDs.insert(update.id)
        case (.importData, .some):
            activeImportEventIDs.remove(update.id)
            importRefreshPending = true
        case (.setup, _):
            break
        }
    }

    mutating func completeImportRefresh() {
        importRefreshPending = false
    }
}

private struct TaskReplicaSnapshot: Equatable {
    let id: UUID
    let title: String
    let statusRaw: String
    let priorityRaw: String
    let createdAt: Date
    let updatedAt: Date
    let completedAt: Date?
    let manualOrder: Int64?
    let parentID: UUID?
    private(set) var imageReferencesData: Data?
    let deletedAt: Date?
    let deletionRootID: UUID?
    let deletionMembersRaw: String
    private(set) var removedAttachmentsData: Data?
    let doneLoggedAt: Date?
    let tagsRaw: String
    let dueDayRaw: String?

    /// The same snapshot without the attachment lists, which each replica
    /// keeps as its own (they are never copied between replicas).
    var ignoringAttachmentLists: TaskReplicaSnapshot {
        var copy = self
        copy.imageReferencesData = nil
        copy.removedAttachmentsData = nil
        return copy
    }

    init(_ task: TaskItem) {
        id = task.id
        title = task.title
        statusRaw = task.statusRaw
        priorityRaw = task.priorityRaw
        createdAt = task.createdAt
        updatedAt = task.updatedAt
        completedAt = task.completedAt
        manualOrder = task.manualOrder
        parentID = task.parentID
        imageReferencesData = task.imageReferencesData
        deletedAt = task.deletedAt
        deletionRootID = task.deletionRootID
        deletionMembersRaw = task.deletionMembersRaw
        removedAttachmentsData = task.removedAttachmentsData
        doneLoggedAt = task.doneLoggedAt
        tagsRaw = task.tagsRaw
        dueDayRaw = task.dueDayRaw
    }
}

/// What a task holds, without when it was last touched or how it was
/// deleted: two replicas with equal content show the same task.
private struct TaskContentSnapshot: Equatable {
    let title: String
    let statusRaw: String
    let priorityRaw: String
    let createdAt: Date
    let completedAt: Date?
    let manualOrder: Int64?
    let parentID: UUID?
    let imageReferencesData: Data?
    let removedAttachmentsData: Data?
    let doneLoggedAt: Date?
    let tagsRaw: String
    let dueDayRaw: String?

    init(_ task: TaskItem) {
        title = task.title
        statusRaw = task.statusRaw
        priorityRaw = task.priorityRaw
        createdAt = task.createdAt
        completedAt = task.completedAt
        manualOrder = task.manualOrder
        parentID = task.parentID
        imageReferencesData = task.imageReferencesData
        removedAttachmentsData = task.removedAttachmentsData
        doneLoggedAt = task.doneLoggedAt
        tagsRaw = task.tagsRaw
        dueDayRaw = task.dueDayRaw
    }
}

/// The fields an undo step puts back on a task: everything a person can
/// edit in the list, plus the ordering and completion time they imply.
struct TaskEditableState: Equatable {
    let id: UUID
    let title: String
    let statusRaw: String
    let priorityRaw: String
    let completedAt: Date?
    let manualOrder: Int64?
    let tagsRaw: String
    let dueDayRaw: String?

    init(_ task: TaskItem) {
        id = task.id
        title = task.title
        statusRaw = task.statusRaw
        priorityRaw = task.priorityRaw
        completedAt = task.completedAt
        manualOrder = task.manualOrder
        tagsRaw = task.tagsRaw
        dueDayRaw = task.dueDayRaw
    }
}

private enum TaskReplicaMutationError: LocalizedError {
    case missingReplica(UUID)
    case notRecentlyDeleted(UUID)
    case incompleteRestore(UUID)
    case parentNotLive(UUID)
    case attachmentNotRemoved(UUID)
    case divergentLiveCopy(UUID)

    var errorDescription: String? {
        switch self {
        case let .missingReplica(id):
            "The task replicas for \(id.uuidString) could not be loaded safely."
        case let .notRecentlyDeleted(id):
            "The task \(id.uuidString) is not in Recently Deleted."
        case .incompleteRestore:
            "Part of this deleted task is missing or its copies disagree, so it can’t be restored safely."
        case .parentNotLive:
            "Restore its main task first; this subtask returns to it."
        case .attachmentNotRemoved:
            "That attachment is not in Recently Deleted."
        case .divergentLiveCopy:
            "Another copy of this task changed after it was deleted, so it can’t be restored safely. Refresh and try again."
        }
    }
}

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [TaskItem] = [] {
        // The family index follows the visible list itself, not only the
        // revision counter: `$revision` sinks run in willSet, before the new
        // value stores, and must already see a deleted task gone.
        didSet { familyIndexCache = nil }
    }
    /// A task failure together with the surface that owns it. Message and
    /// owner are one value on purpose: while they were separate properties
    /// every later `lastErrorMessage = …` inherited the previous operation's
    /// owner, so a general failure that followed a family-scoped one stayed
    /// attached to that family — the main banner suppressed it and a closed
    /// family panel could not show it either.
    struct ErrorNotice: Equatable {
        let message: String
        /// The family whose panel shows the message. nil is a general or
        /// main-composer error, shown by the main panel alone.
        let owner: UUID?
    }

    @Published private(set) var errorNotice: ErrorNotice?

    var lastErrorMessage: String? { errorNotice?.message }
    /// The family a task error concerns, when it concerns one: its panel
    /// shows the message and the main panel stays quiet. nil is a general
    /// or main-composer error, shown by the main panel alone.
    var lastErrorOwnerID: UUID? { errorNotice?.owner }

    /// The user dismissed the notice, or a later success made it stale.
    func dismissError() {
        guard errorNotice != nil else { return }
        errorNotice = nil
    }

    /// The single boundary every task error passes through, so no message can
    /// reach the UI without the owner that operation decided.
    private func report(_ message: String, owner: UUID?) {
        errorNotice = ErrorNotice(message: message, owner: owner)
    }

    func reportUnavailableAttachment(named filename: String, owner: UUID? = nil) {
        report("“\(filename)” is missing or changed in Attic’s private storage.", owner: owner)
    }

    func reportAttachmentOpenFailure(named filename: String, error: Error, owner: UUID? = nil) {
        report("Couldn’t open “\(filename)”. \(error.localizedDescription)", owner: owner)
    }

    /// The surface that owns a failure concerning `task`. A validated child's
    /// failure belongs to its family panel, which is the only place that row
    /// can be acted on; a root's belongs to the main panel. Orphaned,
    /// self-linked and nested links resolve to nil because `parent(of:)` and
    /// the family index already present them as roots — naming a family that
    /// has no panel would hide the message from every surface.
    private func familyOwner(of task: TaskItem) -> UUID? {
        parent(of: task)?.id
    }

    /// The owner for an operation that names a family directly rather than a
    /// row, such as creating a subtask. The family exists only while that id
    /// is a live top-level task; anything else is a general failure.
    private func familyOwner(forParentID parentID: UUID?) -> UUID? {
        guard let parentID, let parent = task(withID: parentID),
              parent.parentID == nil else { return nil }
        return parentID
    }

    /// The same rule for an operation that only has an id: a row that is gone
    /// leaves the failure general, which is where it can still be read.
    private func familyOwner(forTaskID taskID: UUID) -> UUID? {
        guard let task = task(withID: taskID) else { return nil }
        return familyOwner(of: task)
    }
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var cloudSyncStatus = CloudSyncStatus()

    let container: ModelContainer
    private var context: ModelContext
    private let now: () -> Date
    let taskImageFiles: TaskImageFiles
    @Published private(set) var importingAttachmentTaskIDs: Set<UUID> = []
    private let persist: (ModelContext) throws -> Void
    private(set) var remoteChangeObservation: AnyCancellable?
    private(set) var cloudKitEventObservation: AnyCancellable?
    private(set) var cloudImportRefreshTask: Task<Void, Never>?
    private var cloudSyncProtection = CloudSyncProtectionState()
#if os(macOS)
    private(set) var exportActivityToken: NSObjectProtocol?
    private(set) var importActivityToken: NSObjectProtocol?
    private(set) var exportActivityTimeoutTask: Task<Void, Never>?
    private(set) var importActivityTimeoutTask: Task<Void, Never>?
#endif
    private var snapshotCache: [TaskScope: (revision: UInt64, snapshot: TaskScopeSnapshot)] = [:]
    /// Family relationships indexed once per revision (see `familyIndex`).
    private var familyIndexCache: FamilyIndex?

    /// `id → task`, the visible root list, and `parent → children`, built in
    /// one pass over the visible tasks and reused until the next mutation.
    /// Row bodies ask for a family's children several times per evaluation,
    /// so each lookup must be O(1) rather than a scan of every task. Child
    /// rows are sorted per family on first use: the index is rebuilt after
    /// every mutation, and eagerly materializing sort keys for every family
    /// made each post-edit snapshot dominate toggle cost at scale (every
    /// model property read goes through SwiftData's storage).
    private final class FamilyIndex {
        let revision: UInt64
        let byID: [UUID: TaskItem]
        /// Tasks that are not a validated child of a live top-level parent:
        /// true roots plus orphaned, self-linked and nested links, which stay
        /// visible instead of vanishing (same rule as `parent(of:)`).
        let roots: [TaskItem]
        private let childrenByParent: [UUID: [TaskItem]]
        private var sortedChildrenByParent: [UUID: [TaskItem]] = [:]

        init(
            revision: UInt64,
            byID: [UUID: TaskItem],
            roots: [TaskItem],
            childrenByParent: [UUID: [TaskItem]]
        ) {
            self.revision = revision
            self.byID = byID
            self.roots = roots
            self.childrenByParent = childrenByParent
        }

        func children(of parentID: UUID) -> [TaskItem] {
            if let sorted = sortedChildrenByParent[parentID] { return sorted }
            guard let unsorted = childrenByParent[parentID] else { return [] }
            // Sort keys are read once per task: comparators must not re-read
            // model properties O(n log n) times.
            let sorted = unsorted
                .map(SubtaskSortKey.init)
                .sorted(by: SubtaskSortKey.comesBefore)
                .map(\.task)
            sortedChildrenByParent[parentID] = sorted
            return sorted
        }

        func hasChildren(_ parentID: UUID) -> Bool {
            childrenByParent[parentID]?.isEmpty == false
        }
    }
    private static let manualOrderStride: Int64 = 1_024
#if os(macOS)
    private static let cloudSyncActivityTimeout: Duration = .seconds(120)
#endif

    init(
        container: ModelContainer,
        now: @escaping () -> Date = Date.init,
        persist: @escaping (ModelContext) throws -> Void = { try $0.save() },
        taskImageFiles: TaskImageFiles = .shared
    ) {
        self.container = container
        context = ModelContext(container)
        self.now = now
        self.persist = persist
        self.taskImageFiles = taskImageFiles
        refresh()
        // Deferred iPhone/CloudKit work stays dormant in local-only builds,
        // exactly as NoteStore and CanvasStore keep theirs: no observers, no
        // event handling, no activity assertions.
        #if !ATTIC_LOCAL_ONLY
        observeRemoteChanges()
        observeCloudKitEvents()
        #endif
    }

    /// O(1) lookup of a visible task by application identity.
    func task(withID id: UUID) -> TaskItem? {
        familyIndex.byID[id]
    }

    private var familyIndex: FamilyIndex {
        if let familyIndexCache, familyIndexCache.revision == revision {
            return familyIndexCache
        }
        var byID: [UUID: TaskItem] = [:]
        byID.reserveCapacity(tasks.count)
        for task in tasks where byID[task.id] == nil {
            byID[task.id] = task
        }
        var childrenByParent: [UUID: [TaskItem]] = [:]
        var roots: [TaskItem] = []
        for task in tasks {
            // Same root-validation rule as parent(of:): a child counts only
            // under a live top-level parent; orphaned links stay visible as
            // roots instead of vanishing.
            if let parentID = task.parentID, parentID != task.id,
               let parent = byID[parentID], parent.parentID == nil {
                childrenByParent[parentID, default: []].append(task)
            } else {
                roots.append(task)
            }
        }
        let index = FamilyIndex(
            revision: revision, byID: byID, roots: roots,
            childrenByParent: childrenByParent
        )
        familyIndexCache = index
        return index
    }

    private struct SubtaskSortKey {
        let task: TaskItem
        let isDone: Bool
        let manualOrder: Int64?
        let createdAt: Date
        let id: UUID

        init(_ task: TaskItem) {
            self.task = task
            isDone = task.statusRaw == TaskStatus.done.rawValue
            manualOrder = task.manualOrder
            createdAt = task.createdAt
            id = task.id
        }

        static func comesBefore(_ lhs: SubtaskSortKey, _ rhs: SubtaskSortKey) -> Bool {
            if lhs.isDone != rhs.isDone { return !lhs.isDone }
            if lhs.manualOrder != rhs.manualOrder {
                return (lhs.manualOrder ?? 0) > (rhs.manualOrder ?? 0)
            }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Section ordering key, read once per task per rebuild.
    private struct SectionSortKey {
        let task: TaskItem
        let statusRaw: String
        let priorityRank: Int
        let manualOrder: Int64?
        let updatedAt: Date
        let id: UUID

        init(_ task: TaskItem) {
            self.task = task
            statusRaw = task.statusRaw
            priorityRank = task.priority.sortRank
            manualOrder = task.manualOrder
            updatedAt = task.updatedAt
            id = task.id
        }

        static func comesBefore(_ lhs: SectionSortKey, _ rhs: SectionSortKey) -> Bool {
            if lhs.priorityRank != rhs.priorityRank {
                return lhs.priorityRank > rhs.priorityRank
            }
            switch (lhs.manualOrder, rhs.manualOrder) {
            case let (.some(lhsOrder), .some(rhsOrder)) where lhsOrder != rhsOrder:
                return lhsOrder > rhsOrder
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                break
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    @discardableResult
    func create(
        title: String,
        priority: TaskPriority = .none,
        status: TaskStatus = .todo,
        parentID: UUID? = nil,
        attachments: [TaskImageReference] = []
    ) -> TaskItem? {
        commit([TaskDraft(
            title: title,
            priority: priority,
            status: status,
            parentID: parentID,
            attachments: attachments
        )])?.first
    }

    /// Turns drafts into tasks in one save: either every draft becomes a
    /// task or none does. Drafts keep their order: the first ends up highest
    /// in its group, as if each later one had been added below it. Returns
    /// the tasks in draft order, or nil after reporting why nothing changed
    /// (a draft with no title is refused silently, like an empty add bar).
    @discardableResult
    func commit(_ drafts: [TaskDraft]) -> [TaskItem]? {
        guard !drafts.isEmpty else { return [] }
        let titles = drafts.map { Self.normalized($0.title) }
        guard titles.allSatisfy({ !$0.isEmpty }) else { return nil }

        let timestamp = now()
        // Resolved before the first failure can be reported: a composer error
        // belongs to the family panel that asked for the subtask.
        let parentIDs = Set(drafts.map(\.parentID))
        let owner = parentIDs.count == 1 ? familyOwner(forParentID: parentIDs.first ?? nil) : nil
        var created: [TaskItem?] = Array(repeating: nil, count: drafts.count)
        do {
            for parentID in parentIDs.compactMap({ $0 }) {
                let parents = try storedTasks(matching: parentID)
                guard task(withID: parentID) != nil,
                      parents.allSatisfy({ $0.parentID == nil && $0.status != .done
                          && $0.deletedAt == nil && $0.doneLoggedAt == nil }) else {
                    report("Subtasks need an unfinished main task. Reopen the main task first.", owner: owner)
                    return nil
                }
            }
            // Inserted last-first: each new task is placed above the ones
            // already in its group, so the first draft ends up on top.
            for index in drafts.indices.reversed() {
                let draft = drafts[index]
                // A lone task in an unordered group stays unordered, exactly as
                // before; a batch is ordered explicitly so its tasks, which
                // share one timestamp, keep the drafts' order.
                let manualOrder = try nextManualOrder(
                    status: draft.status,
                    priority: draft.priority,
                    parentID: draft.parentID,
                    updatedAt: timestamp
                ) ?? (drafts.count > 1 ? Self.manualOrderStride : nil)
                let task = TaskItem(
                    title: titles[index],
                    status: draft.status,
                    priority: draft.priority,
                    createdAt: timestamp,
                    completedAt: draft.status == .done ? timestamp : nil,
                    manualOrder: manualOrder,
                    parentID: draft.parentID
                )
                task.tags = draft.tags
                task.dueDay = draft.dueDay
                // References the composer already imported are bound in this
                // same save, so a new task never exists without them (or they
                // without it).
                if !draft.attachments.isEmpty {
                    task.imageReferencesData = try JSONEncoder().encode(draft.attachments)
                }
                context.insert(task)
                tasks.append(task)
                created[index] = task
            }
        } catch {
            if created.contains(where: { $0 != nil }) {
                context.rollback()
                try? reloadTasks()
            }
            report(error.localizedDescription, owner: owner)
            return nil
        }
        guard save(owner: owner) else { return nil }
        return created.compactMap { $0 }
    }

    @discardableResult
    func rename(_ task: TaskItem, to title: String) -> Bool {
        update(task, title: title)
    }

    @discardableResult
    func setPriority(_ priority: TaskPriority, for task: TaskItem) -> Bool {
        update(task, priority: priority)
    }

    @discardableResult
    func setStatus(_ status: TaskStatus, for task: TaskItem, allowingUnfinishedSubtasks: Bool = false) -> Bool {
        update(task, status: status, allowingUnfinishedSubtasks: allowingUnfinishedSubtasks)
    }

    /// Applies a task edit as one SwiftData transaction so callers never see
    /// a partially persisted title, priority, or status change.
    @discardableResult
    func update(
        _ task: TaskItem,
        title: String? = nil,
        priority: TaskPriority? = nil,
        status: TaskStatus? = nil,
        tags: [String]? = nil,
        dueDay: DueDay?? = nil,
        allowingUnfinishedSubtasks: Bool = false
    ) -> Bool {
        guard let task = tasks.first(where: { $0.id == task.id }) else { return false }
        // Every refusal and every failure below concerns this row, so they all
        // belong to the surface that owns it: a child's family panel, or the
        // main panel for a root.
        let owner = familyOwner(of: task)
        let replicas: [TaskItem]
        do {
            replicas = try storedTasks(matching: task.id)
        } catch {
            report(error.localizedDescription, owner: owner)
            return false
        }
        let normalizedTitle = title.map(Self.normalized)
        if let normalizedTitle, normalizedTitle.isEmpty { return false }

        let destinationTitle = normalizedTitle ?? task.title
        let destinationPriority = priority ?? task.priority
        let destinationStatus = status ?? task.status
        let destinationTagsRaw = tags.map { AtticTag.encode($0) } ?? task.tagsRaw
        let destinationDueDayRaw = dueDay.map { $0?.rawValue } ?? task.dueDayRaw
        // Status rules are checked against every stored replica, but only
        // the rows they concern: a title or priority edit fetches nothing.
        if destinationStatus != task.status {
            do {
                let doneRaw = TaskStatus.done.rawValue
                if destinationStatus == .done, !allowingUnfinishedSubtasks {
                    let taskID = task.id
                    var unfinishedChildren = FetchDescriptor<TaskItem>(
                        predicate: #Predicate {
                            $0.parentID == taskID && $0.statusRaw != doneRaw && $0.deletedAt == nil
                        }
                    )
                    unfinishedChildren.fetchLimit = 1
                    if try !context.fetch(unfinishedChildren).isEmpty {
                        report("Finish the subtasks before completing this task.", owner: owner)
                        return false
                    }
                }
                if destinationStatus != .done, task.status == .done, let parentID = task.parentID {
                    var doneParents = FetchDescriptor<TaskItem>(
                        predicate: #Predicate {
                            $0.id == parentID && $0.statusRaw == doneRaw && $0.deletedAt == nil
                        }
                    )
                    doneParents.fetchLimit = 1
                    if try !context.fetch(doneParents).isEmpty {
                        report("Reopen the main task before reopening a subtask.", owner: owner)
                        return false
                    }
                }
            } catch {
                report(error.localizedDescription, owner: owner)
                return false
            }
        }
        let titleChanged = destinationTitle != task.title
        let priorityChanged = destinationPriority != task.priority
        let statusChanged = destinationStatus != task.status
        let tagsChanged = destinationTagsRaw != task.tagsRaw
        let dueChanged = destinationDueDayRaw != task.dueDayRaw
        // Attachment lists are not the edit's concern and are never copied
        // between replicas, so copies that differ only there need no repair.
        let visibleSnapshot = TaskReplicaSnapshot(task).ignoringAttachmentLists
        let replicasNeedRepair = replicas.contains {
            TaskReplicaSnapshot($0).ignoringAttachmentLists != visibleSnapshot
        }
        guard titleChanged || priorityChanged || statusChanged || tagsChanged || dueChanged
            || replicasNeedRepair else {
            return true
        }

        let timestamp = now()
        let destinationManualOrder: Int64?
        if priorityChanged || statusChanged {
            do {
                destinationManualOrder = try nextManualOrder(
                    status: destinationStatus,
                    priority: destinationPriority,
                    parentID: task.parentID,
                    excluding: task.id,
                    updatedAt: timestamp
                )
            } catch {
                report(error.localizedDescription, owner: owner)
                return false
            }
        } else {
            destinationManualOrder = task.manualOrder
        }
        let destinationCompletedAt: Date?
        if statusChanged {
            destinationCompletedAt = destinationStatus == .done ? timestamp : nil
        } else {
            destinationCompletedAt = task.completedAt
        }

        // Each replica keeps its own attachment lists (shown and removed):
        // writing the visible copy's lists over a duplicate would drop a
        // reference only the duplicate holds, and the launch sweep would
        // then delete its file. A duplicate whose lists differ keeps its
        // time, so the shown copy stays the one shown.
        let visibleLists = (task.imageReferencesData, task.removedAttachmentsData)
        for replica in replicas {
            replica.title = destinationTitle
            replica.priority = destinationPriority
            replica.status = destinationStatus
            replica.createdAt = task.createdAt
            replica.parentID = task.parentID
            replica.manualOrder = destinationManualOrder
            replica.completedAt = destinationCompletedAt
            replica.tagsRaw = destinationTagsRaw
            replica.dueDayRaw = destinationDueDayRaw
            // An edit to a visible task wins on every replica, including one
            // another device hid: the list only ever shows live tasks.
            replica.deletedAt = task.deletedAt
            replica.deletionRootID = task.deletionRootID
            replica.deletionMembersRaw = task.deletionMembersRaw
            replica.doneLoggedAt = task.doneLoggedAt
            if replica === task
                || (replica.imageReferencesData, replica.removedAttachmentsData) == visibleLists {
                replica.updatedAt = timestamp
            }
        }
        return save(owner: owner)
    }

    @discardableResult
    func setTags(_ tags: [String], for task: TaskItem) -> Bool {
        update(task, tags: tags)
    }

    @discardableResult
    func setDueDay(_ dueDay: DueDay?, for task: TaskItem) -> Bool {
        update(task, dueDay: .some(dueDay))
    }

    /// The editable fields of a visible task, for an undo step.
    func editableState(of id: UUID) -> TaskEditableState? {
        task(withID: id).map(TaskEditableState.init)
    }

    /// Puts earlier editable fields back on visible tasks, every replica, in
    /// one save. Used only by undo and redo, which restore a state the store
    /// itself produced, so the status rules are not re-applied: undoing a
    /// completion brings back the exact earlier completion time and order.
    @discardableResult
    func restoreEditableStates(_ states: [TaskEditableState]) -> Bool {
        guard !states.isEmpty else { return true }
        guard states.allSatisfy({ task(withID: $0.id) != nil }) else {
            report("The task is no longer available.", owner: nil)
            return false
        }
        let owner = states.count == 1 ? familyOwner(forTaskID: states[0].id) : nil
        let timestamp = now()
        do {
            let groups = try storedTaskGroups(matching: Set(states.map(\.id)))
            for state in states {
                for replica in groups[state.id] ?? [] {
                    replica.title = state.title
                    replica.statusRaw = state.statusRaw
                    replica.priorityRaw = state.priorityRaw
                    replica.completedAt = state.completedAt
                    replica.manualOrder = state.manualOrder
                    replica.tagsRaw = state.tagsRaw
                    replica.dueDayRaw = state.dueDayRaw
                    replica.updatedAt = timestamp
                }
            }
        } catch {
            context.rollback()
            report(error.localizedDescription, owner: owner)
            return false
        }
        return save(owner: owner)
    }

    @discardableResult
    func advanceToInProgress(_ task: TaskItem) -> Bool {
        guard let task = tasks.first(where: { $0.id == task.id }) else { return false }
        guard task.status == .todo else { return false }
        return setStatus(.inProgress, for: task)
    }

    /// Imports images and general files into the parent that owns them. A
    /// child row resolves to its parent (subtasks are one level deep). Files
    /// are copied into private storage first; the reference list is written to
    /// every replica in one save, and a failed save removes the new copies.
    @discardableResult
    func attachFiles(_ urls: [URL], to taskID: UUID) async -> Bool {
        guard !urls.isEmpty else { return false }
        return await attachStagedFiles(to: taskID) { TaskAttachmentStaging(urls: urls) } != nil
    }

    /// The shared import path for pickers and drops. The owner is reserved
    /// before `stage` runs, so loading dropped content, copying and binding
    /// are one serialized operation: an overlapping import for the same owner
    /// is refused with a message instead of silently doing nothing. Returns
    /// the new attachment IDs, or nil after reporting why nothing attached.
    /// Only the staging's owned directory is ever discarded, never originals.
    /// A `stage` that throws must already have discarded any directory it
    /// owns (`TaskDroppedFiles.stage` does); only a returned staging is
    /// discarded here.
    func attachStagedFiles(
        to taskID: UUID,
        stage: () async throws -> TaskAttachmentStaging
    ) async -> [UUID]? {
        await attachImported(to: taskID) { _, existing in
            var staging = TaskAttachmentStaging()
            defer { staging.discard() }
            staging = try await stage()
            return try await taskImageFiles.importAttachments(staging.urls, existing: existing)
        }
    }

    /// Gallery cards dropped on another task: each source becomes a new,
    /// separately owned private copy (see `TaskImageFiles.importCopies`),
    /// under the same reservation, binding and rollback as any import.
    /// `sources` runs inside the reservation, and its result is checked
    /// against the store before anything is read.
    func attachCopies(
        to taskID: UUID,
        of sources: () async throws -> [TaskAttachmentSource]
    ) async -> [UUID]? {
        await attachImported(to: taskID) { ownerID, existing in
            let references = try verifiedCopySources(try await sources(), excludingOwner: ownerID)
            return try await taskImageFiles.importCopies(of: references, existing: existing)
        }
    }

    /// The owner and stored reference of an attachment, resolved from the
    /// store alone. nil when no task holds it, more than one does, or its
    /// subtask has no parent to resolve to.
    func attachmentSource(for attachmentID: UUID) -> TaskAttachmentSource? {
        var found: TaskAttachmentSource?
        for task in tasks {
            guard let reference = task.attachments.first(where: { $0.id == attachmentID }) else { continue }
            guard found == nil, let ownerID = attachmentOwnerID(for: task.id) else { return nil }
            found = TaskAttachmentSource(reference: reference, ownerID: ownerID)
        }
        return found
    }

    /// Dragged sources that still match the store exactly (same attachment,
    /// digest and owner) and never belong to `excludedOwner`.
    func verifiedCopySources(_ sources: [TaskAttachmentSource], excludingOwner excludedOwner: UUID?) throws -> [TaskImageReference] {
        guard !sources.isEmpty else { throw TaskDropError.attachmentUnavailable }
        return try sources.map { source in
            guard attachmentSource(for: source.reference.id) == source else { throw TaskDropError.attachmentUnavailable }
            guard source.ownerID != excludedOwner else { throw TaskDropError.alreadyAttached }
            return source.reference
        }
    }

    /// `importing` receives the owner and its current attachments, and on
    /// throwing must leave no private copies behind (the importer rolls back
    /// its own batch).
    private func attachImported(
        to taskID: UUID,
        importing: (_ ownerID: UUID, _ existing: [TaskImageReference]) async throws -> [TaskImageReference]
    ) async -> [UUID]? {
        // The attachment owner is where the files are written; the error owner
        // is the surface the user acted on. They differ for a parent, whose
        // row exists in the main panel as well as in its own family panel —
        // and a family panel is not opened for a failed import, so reporting
        // there would leave nothing on screen.
        let errorOwner = familyOwner(forTaskID: taskID)
        guard let ownerID = attachmentOwnerID(for: taskID),
              let initial = tasks.first(where: { $0.id == ownerID }) else {
            report("Couldn’t attach files. The task is no longer available.", owner: errorOwner)
            return nil
        }
        guard !importingAttachmentTaskIDs.contains(ownerID) else {
            report("Attic is still attaching files to “\(initial.title)”. Try again when it finishes.", owner: errorOwner)
            return nil
        }
        importingAttachmentTaskIDs.insert(ownerID)
        defer { importingAttachmentTaskIDs.remove(ownerID) }
        var imported: [TaskImageReference] = []
        do {
            imported = try await importing(ownerID, initial.attachments)
            guard let current = tasks.first(where: { $0.id == ownerID }) else {
                await taskImageFiles.remove(imported)
                report("Couldn’t attach files. The task was deleted while they were copied.", owner: errorOwner)
                return nil
            }
            // Each replica gains the new files on top of its own list, never
            // the visible copy's, so a reference only a duplicate holds is
            // kept (see `removeAttachment`).
            let timestamp = now()
            let shownCopy = TaskReplicaSnapshot(current)
            for replica in try storedTasks(matching: ownerID) {
                let stamp = replica === current || TaskReplicaSnapshot(replica) == shownCopy
                let shown = try Self.attachmentLists(of: replica).shown
                replica.imageReferencesData = try JSONEncoder().encode(shown + imported)
                if stamp { replica.updatedAt = timestamp }
            }
            guard save(owner: errorOwner) else {
                await taskImageFiles.remove(imported); return nil
            }
            return imported.map(\.id)
        } catch {
            await taskImageFiles.remove(imported)
            reportAttachmentImportFailure(error, owner: errorOwner)
            return nil
        }
    }

    private var hasSweptAttachmentStorage = false

    /// Once per launch, before anything is being attached: removes private
    /// attachment copies no stored task references, such as a composer's
    /// pending items when Attic quit before the task was added, and drop
    /// staging a quit left behind. References are collected from every
    /// physical replica, so a duplicate that differs from the visible task
    /// still keeps its files, and a replica whose references can't be read
    /// stops the sweep. Anything created or modified within `minimumAge` is
    /// kept, which also covers an import that starts while the sweep runs.
    /// Only Attic's own storage is touched, never originals. Returns how many
    /// copies were removed, or nil when the sweep did not run.
    @discardableResult
    func sweepUnreferencedAttachmentStorage(minimumAge: TimeInterval = 24 * 60 * 60,
                                            dropStagingRoot: URL = TaskAttachmentStaging.ownedRootURL) async -> Int? {
        guard !hasSweptAttachmentStorage, importingAttachmentTaskIDs.isEmpty else { return nil }
        hasSweptAttachmentStorage = true
        let referencedIDs: Set<UUID>
        do {
            referencedIDs = try storedAttachmentIDs(excludingTaskIDs: [])
        } catch {
            return nil
        }
        // File dates are wall-clock times, whatever clock the store was given.
        let cutoff = Date().addingTimeInterval(-minimumAge)
        TaskAttachmentStaging.removeAbandoned(modifiedBefore: cutoff, in: dropStagingRoot)
        return await taskImageFiles.removeUnreferenced(keeping: referencedIDs, modifiedBefore: cutoff,
                                                       limit: Self.attachmentSweepLimit)
    }

    private static let attachmentSweepLimit = 500

    /// Calm, task-worded reason an import did not attach anything. `owner`
    /// is the family whose panel should show it; nil for the main composer.
    func reportAttachmentImportFailure(_ error: Error, owner: UUID? = nil) {
        report("Couldn’t attach files. \(Self.attachmentErrorDescription(error))", owner: owner)
    }

    /// Attachments belong to a top-level task; a child resolves to its parent.
    func attachmentOwnerID(for taskID: UUID) -> UUID? {
        guard let task = task(withID: taskID) else { return nil }
        guard let parentID = task.parentID else { return task.id }
        return parent(of: task) != nil ? parentID : nil
    }

    private static func attachmentErrorDescription(_ error: Error) -> String {
        switch error as? AttachmentFileStoreError {
        case .tooManyAttachments:
            "A task can hold at most \(AttachmentLimits.maxAttachmentsPerNote) attachments."
        case .noteTooLarge:
            "Attachments for a task cannot exceed 100 MiB."
        default:
            error.localizedDescription
        }
    }

    /// Removes one attachment from a task into Recently Deleted: the
    /// reference moves to the task's removed list on every replica, and its
    /// file stays until the removal is purged 30 days later.
    ///
    /// Each replica is changed from its own lists, never overwritten from the
    /// visible one: a duplicate that holds attachments the visible task does
    /// not keeps every one of them, so no reference (and no file the launch
    /// sweep would then treat as unreferenced) is lost. A replica whose lists
    /// can't be read refuses the removal.
    @discardableResult
    func removeAttachment(_ attachmentID: UUID, from taskID: UUID) -> Bool {
        guard let task = tasks.first(where: { $0.id == taskID }),
              let removed = task.attachments.first(where: { $0.id == attachmentID }) else { return false }
        // Attachments are reached from the family panel — a parent’s through
        // its own attachments view, a subtask’s through its row — so a failed
        // removal has to be visible there rather than behind a closed panel.
        let owner = familyOwner(of: task)
        do {
            let timestamp = now()
            let shownCopy = TaskReplicaSnapshot(task)
            for replica in try storedTasks(matching: taskID) {
                // An identical copy is stamped with the shown one and stays
                // identical. A differing duplicate keeps its time, so the
                // shown copy stays the one shown: restamping it could let it
                // win the next refresh and change what the task displays.
                let stamp = replica === task || TaskReplicaSnapshot(replica) == shownCopy
                let lists = try Self.attachmentLists(of: replica)
                // The replica's own copy of the reference, if it holds one.
                let reference = lists.shown.first { $0.id == attachmentID } ?? removed
                let kept = lists.shown.filter { $0.id != attachmentID }
                let removedList = lists.removed.filter { $0.reference.id != attachmentID }
                    + [RemovedTaskAttachment(reference: reference, removedAt: timestamp)]
                replica.imageReferencesData = kept.isEmpty && replica.imageReferencesData == nil
                    ? nil : try JSONEncoder().encode(kept)
                replica.removedAttachmentsData = try JSONEncoder().encode(removedList)
                if stamp { replica.updatedAt = timestamp }
            }
        } catch {
            context.rollback()
            report(error.localizedDescription, owner: owner)
            return false
        }
        return save(owner: owner)
    }

    /// A replica's shown and removed attachments, decoded strictly: callers
    /// that rewrite them refuse rather than drop what they can't read.
    private static func attachmentLists(of replica: TaskItem) throws
        -> (shown: [TaskImageReference], removed: [RemovedTaskAttachment]) {
        let decoder = JSONDecoder()
        let shown = try replica.imageReferencesData.flatMap { $0.isEmpty ? nil : $0 }
            .map { try decoder.decode([TaskImageReference].self, from: $0) } ?? []
        let removed = try replica.removedAttachmentsData.flatMap { $0.isEmpty ? nil : $0 }
            .map { try decoder.decode([RemovedTaskAttachment].self, from: $0) } ?? []
        return (shown, removed)
    }

    /// Attachments removed from tasks that are still shown, newest first.
    func recentlyDeletedAttachments() -> [DeletedAttachmentSummary] {
        tasks.flatMap { task in
            task.removedAttachments.map {
                DeletedAttachmentSummary(
                    attachmentID: $0.reference.id,
                    owner: AtticItemRef(.task, task.id),
                    filename: $0.reference.filename,
                    deletedAt: $0.removedAt
                )
            }
        }
        .sorted { $0.deletedAt != $1.deletedAt ? $0.deletedAt > $1.deletedAt : $0.attachmentID.uuidString < $1.attachmentID.uuidString }
    }

    /// Puts a removed attachment back at the end of its task's attachments,
    /// on every replica, in one save. As with removal, each replica is
    /// changed from its own lists, so references only a duplicate holds stay.
    @discardableResult
    func restoreAttachment(_ attachmentID: UUID) -> Bool {
        guard let task = tasks.first(where: { $0.removedAttachments.contains { $0.reference.id == attachmentID } }),
              let entry = task.removedAttachments.first(where: { $0.reference.id == attachmentID }) else {
            report(TaskReplicaMutationError.attachmentNotRemoved(attachmentID).localizedDescription, owner: nil)
            return false
        }
        let owner = familyOwner(of: task)
        guard task.attachments.count < AttachmentLimits.maxAttachmentsPerNote else {
            report("A task can hold at most \(AttachmentLimits.maxAttachmentsPerNote) attachments.", owner: owner)
            return false
        }
        do {
            let timestamp = now()
            let shownCopy = TaskReplicaSnapshot(task)
            for replica in try storedTasks(matching: task.id) {
                let stamp = replica === task || TaskReplicaSnapshot(replica) == shownCopy
                let lists = try Self.attachmentLists(of: replica)
                let reference = lists.removed.first { $0.reference.id == attachmentID }?.reference ?? entry.reference
                let shown = lists.shown.contains { $0.id == attachmentID } ? lists.shown : lists.shown + [reference]
                let remaining = lists.removed.filter { $0.reference.id != attachmentID }
                replica.imageReferencesData = try JSONEncoder().encode(shown)
                replica.removedAttachmentsData = remaining.isEmpty ? nil : try JSONEncoder().encode(remaining)
                if stamp { replica.updatedAt = timestamp }
            }
        } catch {
            context.rollback()
            report(error.localizedDescription, owner: owner)
            return false
        }
        return save(owner: owner)
    }

    /// Drops removals older than `cutoff` from every task whose replicas
    /// agree, then releases files no surviving replica (shown, removed or
    /// deleted) still references. Returns how many attachments were purged.
    @discardableResult
    func purgeRemovedAttachments(before cutoff: Date) -> Int {
        var expired: [TaskImageReference] = []
        do {
            let rows = try context.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.removedAttachmentsData != nil }
            ))
            let ids = Array(Set(rows.map(\.id)))
            let all = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { ids.contains($0.id) }))
            for replicas in Dictionary(grouping: all, by: \.id).values {
                guard let first = replicas.first, let data = first.removedAttachmentsData else { continue }
                let snapshot = TaskReplicaSnapshot(first)
                guard replicas.allSatisfy({ TaskReplicaSnapshot($0) == snapshot }) else { continue }
                let entries = try JSONDecoder().decode([RemovedTaskAttachment].self, from: data)
                let old = entries.filter { $0.removedAt < cutoff }
                guard !old.isEmpty else { continue }
                let remaining = entries.filter { $0.removedAt >= cutoff }
                let remainingData = remaining.isEmpty ? nil : try JSONEncoder().encode(remaining)
                for replica in replicas { replica.removedAttachmentsData = remainingData }
                expired += old.map(\.reference)
            }
        } catch {
            context.rollback()
            report(error.localizedDescription, owner: nil)
            return 0
        }
        guard !expired.isEmpty, save() else { return 0 }
        removeAttachmentFiles(expired, excludingTaskIDs: [])
        return expired.count
    }

    /// Removes private files only for references no surviving replica still
    /// holds. A crafted or corrupt store can share one attachment identity
    /// across two logical tasks; deleting one must never break the other, so
    /// the same replica-wide check the launch sweep performs runs here too.
    /// A failed check keeps every file (the sweep reclaims true orphans later).
    private func removeAttachmentFiles(_ references: [TaskImageReference], excludingTaskIDs deleted: Set<UUID>) {
        guard !references.isEmpty else { return }
        let survivingIDs: Set<UUID>
        do {
            survivingIDs = try storedAttachmentIDs(excludingTaskIDs: deleted)
        } catch {
            return
        }
        let removable = references.filter { !survivingIDs.contains($0.id) }
        guard !removable.isEmpty else { return }
        Task { await taskImageFiles.remove(removable) }
    }

    /// Attachment identities held by every stored replica (of any task not
    /// in `deleted`). Only rows that carry attachments are fetched; a replica
    /// whose references cannot be decoded aborts the query so callers keep
    /// files rather than guess.
    private func storedAttachmentIDs(excludingTaskIDs deleted: Set<UUID>) throws -> Set<UUID> {
        let withAttachments = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.imageReferencesData != nil || $0.removedAttachmentsData != nil }
        )
        var referencedIDs = Set<UUID>()
        for replica in try context.fetch(withAttachments) where !deleted.contains(replica.id) {
            if let data = replica.imageReferencesData, !data.isEmpty {
                let references = try JSONDecoder().decode([TaskImageReference].self, from: data)
                referencedIDs.formUnion(references.map(\.id))
            }
            // Removed attachments keep their files while they are restorable.
            if let data = replica.removedAttachmentsData, !data.isEmpty {
                let removed = try JSONDecoder().decode([RemovedTaskAttachment].self, from: data)
                referencedIDs.formUnion(removed.map(\.reference.id))
            }
        }
        return referencedIDs
    }

    @discardableResult
    func performDoubleClickAction(_ task: TaskItem) -> Bool {
        guard let task = tasks.first(where: { $0.id == task.id }) else { return false }
        guard let destination = task.status.doubleClickDestination else { return false }
        return setStatus(destination, for: task)
    }

    @discardableResult
    func markDone(_ task: TaskItem) -> Bool {
        guard let task = tasks.first(where: { $0.id == task.id }) else { return false }
        guard task.status != .done else { return true }
        return setStatus(.done, for: task)
    }

    @discardableResult
    func performPrimaryAction(_ task: TaskItem) -> Bool {
        guard let task = tasks.first(where: { $0.id == task.id }) else { return false }
        return setStatus(task.status.primaryActionDestination, for: task)
    }

    /// Moves a task, and its subtasks when it is a main task, to Recently
    /// Deleted. Nothing is removed: every replica is marked with the deletion
    /// time and the id of the task this delete started from, and files stay
    /// in private storage, so `restoreDeleted(taskID:)` can bring back the
    /// family exactly as it was. The same family rules as before refuse an
    /// ambiguous or nested family instead of hiding a peer's task.
    @discardableResult
    func delete(_ task: TaskItem) -> Bool {
        delete(taskIDs: [task.id])
    }

    /// Several deletes in one save (undoing a batch creation): each task and
    /// its family move to Recently Deleted as their own entry, or nothing
    /// changes when any of them is refused.
    @discardableResult
    func delete(taskIDs: [UUID]) -> Bool {
        let visible = taskIDs.compactMap { id in tasks.first(where: { $0.id == id }) }
        guard !visible.isEmpty, visible.count == Set(taskIDs).count else { return false }
        // Read while the rows are still there: the family a deleted subtask
        // belonged to is the panel the user is looking at, and a refusal has
        // to appear beside the row it refused.
        let owner = visible.count == 1 ? familyOwner(of: visible[0]) : nil
        // A subtask whose main task is in the same batch goes with it.
        let requested = Set(taskIDs)
        let roots = visible.filter { task in
            guard let parentID = task.parentID, parent(of: task) != nil else { return true }
            return !requested.contains(parentID)
        }
        var staged: [(root: UUID, rows: [TaskItem])] = []
        for task in roots {
            guard let family = deletionFamily(of: task, owner: owner) else { return false }
            staged.append((task.id, family))
        }
        let timestamp = now()
        var deletedIDs = Set<UUID>()
        for (root, rows) in staged {
            let members = Set(rows.map(\.id)).map(\.uuidString).sorted().joined(separator: " ")
            for replica in rows {
                replica.deletedAt = timestamp
                replica.deletionRootID = root
                replica.deletionMembersRaw = members
                deletedIDs.insert(replica.id)
            }
        }
        tasks.removeAll { deletedIDs.contains($0.id) }
        return save(owner: owner)
    }

    /// The rows one delete of `task` hides: every replica of the task and,
    /// for a main task, of its subtasks. The same family rules as before
    /// refuse an ambiguous or nested family instead of hiding a peer's task;
    /// a refusal is reported and returns nil.
    private func deletionFamily(of task: TaskItem, owner: UUID?) -> [TaskItem]? {
        do {
            // Only the task's own replicas and its direct children are read;
            // anything linked below a child is unsupported nesting, checked
            // separately below. Refuse ambiguous family ownership rather than
            // deleting a peer's task through a conflicting imported link.
            let taskID = task.id
            let linked = try context.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.id == taskID || $0.parentID == taskID }
            ))
            // Every physical replica of each linked id, including a duplicate
            // that claims a different parent: that conflict must refuse the
            // deletion rather than slip past a parent-only predicate.
            let linkedIDs = Array(Set(linked.map(\.id)))
            let stored = try context.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { linkedIDs.contains($0.id) }
            ))
            // A subtask already in Recently Deleted on its own keeps its own
            // deletion (and its own restore); it is not part of this one.
            let family = Dictionary(grouping: stored, by: \.id)
                .filter { id, rows in id == taskID || !rows.allSatisfy { $0.deletedAt != nil } }
                .values.flatMap { $0 }
            let groups = Dictionary(grouping: family, by: \.id)
            guard groups[task.id]?.isEmpty == false else {
                throw TaskReplicaMutationError.missingReplica(task.id)
            }
            guard groups.values.allSatisfy({ Set($0.map(\.parentID)).count == 1 }) else {
                report("Conflicting subtask links prevent safe deletion. Refresh and resolve them first.", owner: owner)
                return nil
            }
            guard family.allSatisfy({ item in
                item.id == task.id || (task.parentID == nil && item.parentID == task.id)
            }) else {
                report("An unsupported nested or cyclic subtask link prevents safe deletion.", owner: owner)
                return nil
            }
            for childID in Set(family.map(\.id)).subtracting([task.id]) {
                var nested = FetchDescriptor<TaskItem>(
                    predicate: #Predicate { $0.parentID == childID && $0.deletedAt == nil }
                )
                nested.fetchLimit = 1
                if try !context.fetch(nested).isEmpty {
                    report("An unsupported nested or cyclic subtask link prevents safe deletion.", owner: owner)
                    return nil
                }
            }
            return family
        } catch {
            report(error.localizedDescription, owner: owner)
            return nil
        }
    }

    /// One entry per delete: the task a delete started from, newest first.
    /// Subtasks that went with their parent are counted, not listed.
    func recentlyDeletedTasks() -> [DeletedItemSummary] {
        let deleted: [TaskItem]
        do {
            deleted = try ModelContext(container).fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.deletedAt != nil }
            ))
        } catch {
            report(error.localizedDescription, owner: nil)
            return []
        }
        return Dictionary(grouping: deleted) { $0.deletionRootID ?? $0.id }
            .compactMap { rootID, rows -> DeletedItemSummary? in
                let rootRows = rows.filter { $0.id == rootID }
                guard let root = visibleUniqueTasks(from: rootRows).first,
                      let deletedAt = root.deletedAt else { return nil }
                return DeletedItemSummary(
                    ref: AtticItemRef(.task, rootID),
                    title: root.title,
                    deletedAt: deletedAt,
                    includedCount: Set(rows.map(\.id)).count - 1,
                    retentionStart: deletedAt
                )
            }
            .sorted { lhs, rhs in
                lhs.deletedAt != rhs.deletedAt
                    ? lhs.deletedAt > rhs.deletedAt
                    : lhs.ref.id.uuidString < rhs.ref.id.uuidString
            }
    }

    /// Brings back exactly what one delete hid (the task and the subtasks
    /// that went with it), on every replica, in one save: all of it comes
    /// back or none of it. Order, parent link, files and tags are untouched,
    /// so the family returns where it was.
    @discardableResult
    func restoreDeleted(taskID: UUID) -> Bool {
        restoreDeleted(taskIDs: [taskID])
    }

    /// Several restores in one save (redoing a batch creation). Before
    /// anything is written, every physical replica of every task the delete
    /// recorded is inspected, live duplicates included: each member must still
    /// have its deleted rows, no replica may belong to a different delete,
    /// the copies must agree on who was deleted together, and a live
    /// duplicate must hold the same content as the deleted copies (a changed
    /// one refuses the restore rather than being reconciled by guesswork).
    /// A subtask deleted on its own comes back only while its main task is
    /// live (restore the main task first), so it always returns to its
    /// family, never as a stray row.
    @discardableResult
    func restoreDeleted(taskIDs: [UUID]) -> Bool {
        guard !taskIDs.isEmpty else { return false }
        do {
            var batches: [UUID: [TaskItem]] = [:]
            for taskID in Set(taskIDs) {
                batches[taskID] = try context.fetch(FetchDescriptor<TaskItem>(
                    predicate: #Predicate { $0.deletionRootID == taskID && $0.deletedAt != nil }
                ))
            }
            // A subtask created with its parent in one batch was deleted with
            // it and comes back with it.
            let covered = Set(batches.values.flatMap { $0.map(\.id) })
            var restoring = Set<UUID>()
            for (rootID, batch) in batches {
                if batch.isEmpty {
                    guard covered.contains(rootID) else { throw TaskReplicaMutationError.notRecentlyDeleted(rootID) }
                    continue
                }
                guard batch.contains(where: { $0.id == rootID }) else {
                    throw TaskReplicaMutationError.notRecentlyDeleted(rootID)
                }
                let recorded = batch[0].deletionMembersRaw
                let members = batch[0].deletionMembers
                guard !members.isEmpty, members.contains(rootID),
                      batch.allSatisfy({ $0.deletionMembersRaw == recorded }),
                      members.allSatisfy({ id in batch.contains { $0.id == id } }),
                      Set(batch.map(\.id)).isSubset(of: members) else {
                    throw TaskReplicaMutationError.incompleteRestore(rootID)
                }
                let ids = Array(members)
                let replicas = try context.fetch(FetchDescriptor<TaskItem>(
                    predicate: #Predicate { ids.contains($0.id) }
                ))
                guard replicas.allSatisfy({ $0.deletedAt == nil || $0.deletionRootID == rootID }) else {
                    throw TaskReplicaMutationError.incompleteRestore(rootID)
                }
                // A copy that stayed live (a late replica the delete never
                // reached) must hold what the deleted copies hold. If it was
                // changed, restoring would put two different versions of the
                // task side by side and let the list pick one, so nothing is
                // restored until the copies agree.
                for copies in Dictionary(grouping: replicas, by: \.id).values
                where copies.contains(where: { $0.deletedAt == nil }) {
                    let content = TaskContentSnapshot(copies[0])
                    guard copies.allSatisfy({ TaskContentSnapshot($0) == content }) else {
                        throw TaskReplicaMutationError.divergentLiveCopy(rootID)
                    }
                }
                restoring.formUnion(members)
            }
            // A root that is a subtask returns only under a live main task.
            for (rootID, batch) in batches where !batch.isEmpty {
                guard let parentID = batch.first(where: { $0.id == rootID })?.parentID,
                      parentID != rootID, !restoring.contains(parentID) else { continue }
                let parentRows = try context.fetch(FetchDescriptor<TaskItem>(
                    predicate: #Predicate { $0.id == parentID }
                ))
                // A parent that no longer exists at all leaves the subtask
                // visible as a root, as for any orphaned link.
                if !parentRows.isEmpty, task(withID: parentID) == nil {
                    throw TaskReplicaMutationError.parentNotLive(rootID)
                }
            }
            for batch in batches.values {
                for replica in batch {
                    replica.deletedAt = nil
                    replica.deletionRootID = nil
                    replica.deletionMembersRaw = ""
                }
            }
        } catch {
            context.rollback()
            report(error.localizedDescription, owner: nil)
            return false
        }
        guard save(owner: nil) else { return false }
        do {
            try reloadTasks()
        } catch {
            report("Restored, but the list could not be refreshed: \(error.localizedDescription)", owner: nil)
        }
        return true
    }

    /// Removes for good what was deleted before `cutoff` (30 days ago, at
    /// the daily cleanup). A delete is purged only when every task it
    /// recorded is still there under the same deletion, and every replica of
    /// every task in it agrees; a divergent copy keeps the whole family.
    /// Files go only once no surviving replica references them. Returns the
    /// ids of the purged deletes' tasks.
    @discardableResult
    func purgeDeleted(before cutoff: Date) -> Set<UUID> {
        let rootsByID: [UUID: [TaskItem]]
        let storedByID: [UUID: [TaskItem]]
        do {
            let deleted = try context.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.deletedAt != nil }
            ))
            let expiredRoots = Set(deleted.compactMap { row -> UUID? in
                guard let deletedAt = row.deletedAt, deletedAt < cutoff else { return nil }
                return row.deletionRootID ?? row.id
            })
            guard !expiredRoots.isEmpty else { return [] }
            rootsByID = Dictionary(grouping: deleted.filter { expiredRoots.contains($0.deletionRootID ?? $0.id) }) {
                $0.deletionRootID ?? $0.id
            }
            let ids = Array(Set(rootsByID.values.flatMap { $0.map(\.id) }))
            storedByID = Dictionary(grouping: try context.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { ids.contains($0.id) }
            )), by: \.id)
        } catch {
            report(error.localizedDescription, owner: nil)
            return []
        }

        var purgedIDs = Set<UUID>()
        var removed: [TaskItem] = []
        for (rootID, batch) in rootsByID {
            let ids = Set(batch.map(\.id))
            // The delete must be exactly the one it recorded: every row names
            // the same root, time and member list, and every recorded member
            // is still here. A family missing a member, or mixing rows from
            // different deletes, is one a restore would refuse, so it is kept
            // rather than purged in part.
            let first = batch[0]
            let members = first.deletionMembers
            guard !members.isEmpty, members.contains(rootID), ids == members,
                  batch.allSatisfy({
                      $0.deletionRootID == rootID && $0.deletedAt == first.deletedAt
                          && $0.deletionMembersRaw == first.deletionMembersRaw
                  }) else { continue }
            let agreed = ids.allSatisfy { id in
                guard let replicas = storedByID[id], let first = replicas.first,
                      first.deletedAt.map({ $0 < cutoff }) == true,
                      (first.deletionRootID ?? first.id) == rootID else { return false }
                let snapshot = TaskReplicaSnapshot(first)
                return replicas.allSatisfy { TaskReplicaSnapshot($0) == snapshot }
            }
            guard agreed else { continue }
            purgedIDs.formUnion(ids)
            removed += ids.flatMap { storedByID[$0] ?? [] }
        }
        guard !removed.isEmpty else { return [] }
        let removedFiles = removed.flatMap { $0.attachments + $0.removedAttachments.map(\.reference) }
        removed.forEach(context.delete)
        guard save() else { return [] }
        removeAttachmentFiles(removedFiles, excludingTaskIDs: purgedIDs)
        return purgedIDs
    }

    /// The daily cleanup: finished tasks completed before `cutoff` (the start
    /// of the current local day) leave today's list and move to the Done log.
    /// Nothing is deleted. Same rules as the old purge: every replica of a
    /// candidate must agree (a divergent duplicate blocks it), and a family
    /// moves together or not at all. Running it again changes nothing, so a
    /// repeated wake, clock or time-zone change can never log twice.
    @discardableResult
    func moveCompletedToDoneLog(before cutoff: Date) -> Int {
        // Fetch done rows and parent-linked rows in batches, then retain the
        // expiry candidates and their immediate families. Every candidate's
        // replicas participate so divergent duplicates still refuse cleanup.
        let stored: [TaskItem]
        do {
            let doneRaw = TaskStatus.done.rawValue
            // Read only the done rows, then apply the completion cutoff in
            // memory. Hosted macOS 26.6 rejects the ForcedUnwrap predicate
            // expression used by the previous completedAt comparison. This
            // batch query avoids that unsupported optional operation.
            let candidates = try context.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate {
                    $0.statusRaw == doneRaw && $0.deletedAt == nil && $0.doneLoggedAt == nil
                }
            )).filter { task in
                guard let completedAt = task.completedAt else { return false }
                return completedAt < cutoff
            }
            guard !candidates.isEmpty else { return 0 }
            let candidateIDSet = Set(candidates.map(\.id))
            let candidateIDs = Array(candidateIDSet)
            let parentIDs = Array(Set(candidates.compactMap(\.parentID)))
            let relatedIDs = candidateIDs + parentIDs
            let replicas = try context.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { relatedIDs.contains($0.id) }
            ))
            // Match the optional parent link in memory: the hosted macOS
            // 26.6 runtime rejects any predicate that force-unwraps an
            // optional (`unsupportedPredicate` for PredicateExpressions
            // .ForcedUnwrap), and the old `candidateIDs.contains($0.parentID!)`
            // form therefore made every expiry attempt fail with
            // SwiftDataError-1. Rows carrying a parent link are read, the
            // membership test runs on the values.
            let children = try context.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.parentID != nil }
            )).filter { task in
                guard let parentID = task.parentID else { return false }
                return candidateIDSet.contains(parentID)
            }
            var seen = Set<PersistentIdentifier>()
            let related = (replicas + children).filter { seen.insert($0.persistentModelID).inserted }
            // A subtask in Recently Deleted on its own is no longer part of
            // the family shown in the list, exactly as when deletes removed
            // it: it neither blocks nor follows its parent.
            let hiddenIDs = Set(Dictionary(grouping: related, by: \.id)
                .filter { $0.value.allSatisfy { $0.deletedAt != nil } }.keys)
            stored = related.filter { !hiddenIDs.contains($0.id) }
        } catch {
            report(error.localizedDescription, owner: nil)
            return 0
        }

        let grouped = Dictionary(grouping: stored, by: \.id)
        var expiredIDs = Set(grouped.compactMap { id, replicas -> UUID? in
            guard let first = replicas.first else { return nil }
            let agreedSnapshot = TaskReplicaSnapshot(first)
            guard replicas.dropFirst().allSatisfy({ TaskReplicaSnapshot($0) == agreedSnapshot }) else {
                return nil
            }
            return first.status == .done
                && first.deletedAt == nil
                && first.doneLoggedAt == nil
                && first.completedAt.map { $0 < cutoff } == true
                ? id
                : nil
        })
        // Keep a family together: neither completed children of an active
        // parent nor a parent with active/recent/divergent children may expire.
        var previousCount = -1
        while previousCount != expiredIDs.count {
            previousCount = expiredIDs.count
            for item in stored {
                if let parentID = item.parentID {
                    if !expiredIDs.contains(parentID) { expiredIDs.remove(item.id) }
                    if !expiredIDs.contains(item.id) { expiredIDs.remove(parentID) }
                }
            }
        }
        guard !expiredIDs.isEmpty else { return 0 }
        let timestamp = now()
        for replica in stored where expiredIDs.contains(replica.id) {
            replica.doneLoggedAt = timestamp
        }
        tasks.removeAll { expiredIDs.contains($0.id) }
        guard save() else { return 0 }
        return expiredIDs.count
    }

    /// Everything the daily cleanup moved out of today's list, most recently
    /// completed first (the Done page arrives in phase 1).
    func doneLog() -> [TaskItem] {
        do {
            let logged = try context.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.doneLoggedAt != nil && $0.deletedAt == nil }
            ))
            return visibleUniqueTasks(from: logged).sorted { lhs, rhs in
                let left = lhs.completedAt ?? lhs.updatedAt
                let right = rhs.completedAt ?? rhs.updatedAt
                return left != right ? left > right : lhs.id.uuidString < rhs.id.uuidString
            }
        } catch {
            report(error.localizedDescription, owner: nil)
            return []
        }
    }

    func orderedTasks(for status: TaskStatus) -> [TaskItem] {
        let raw = status.rawValue
        return tasks
            .filter { $0.statusRaw == raw }
            .map(SectionSortKey.init)
            .sorted(by: SectionSortKey.comesBefore)
            .map(\.task)
    }

    /// Invalid/orphaned imported links remain visible as roots; never hide data.
    func parent(of task: TaskItem) -> TaskItem? {
        guard let parentID = task.parentID, parentID != task.id,
              let parent = familyIndex.byID[parentID], parent.parentID == nil else { return nil }
        return parent
    }

    /// The family's children in display order — unfinished first, then
    /// manual order, then creation. O(1) per call between mutations.
    func subtasks(of parentID: UUID) -> [TaskItem] {
        familyIndex.children(of: parentID)
    }

    /// Whether the family has any child, without materializing the list.
    func hasSubtasks(_ parentID: UUID) -> Bool {
        familyIndex.hasChildren(parentID)
    }

    /// Memoized per revision: SwiftUI evaluates view bodies far more often
    /// than tasks change, so repeated calls between edits are O(1). Every
    /// mutation path goes through save()/reloadTasks(), which bump `revision`.
    func snapshot(for scope: TaskScope) -> TaskScopeSnapshot {
        if let cached = snapshotCache[scope], cached.revision == revision {
            return cached.snapshot
        }

        // The index already classified roots, so sections read only root
        // keys; each section then sorts its own slice.
        var keysByStatus: [String: [SectionSortKey]] = [:]
        for task in familyIndex.roots {
            let key = SectionSortKey(task)
            keysByStatus[key.statusRaw, default: []].append(key)
        }
        let sections = scope.statuses.compactMap { status -> TaskSectionSnapshot? in
            guard let keys = keysByStatus[status.rawValue], !keys.isEmpty else { return nil }
            return TaskSectionSnapshot(status: status, tasks: keys.sorted(by: SectionSortKey.comesBefore).map(\.task))
        }
        let activeStatuses = Set(scope.countedStatuses)
        let snapshot = TaskScopeSnapshot(
            sections: sections,
            visibleCount: sections.reduce(0) { $0 + $1.tasks.count },
            activeCount: sections.reduce(0) { count, section in
                count + (activeStatuses.contains(section.status) ? section.tasks.count : 0)
            }
        )
        snapshotCache[scope] = (revision, snapshot)
        return snapshot
    }

    @discardableResult
    func startAfterExternalDrag(taskID: UUID) -> Bool {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return false }
        switch task.status {
        case .todo, .backlog:
            return setStatus(.inProgress, for: task)
        case .inProgress:
            return true
        case .done:
            return false
        }
    }

    /// Drop onto another row: same section reorders, a different section
    /// adopts that section's status (placing the task near the target row
    /// when their priorities allow it).
    @discardableResult
    func drop(taskID: UUID, onto targetID: UUID, allowingUnfinishedSubtasks: Bool = false) -> Bool {
        guard taskID != targetID,
              let task = tasks.first(where: { $0.id == taskID }),
              let target = tasks.first(where: { $0.id == targetID }) else {
            return false
        }

        guard task.parentID == target.parentID else { return false }

        if task.status == target.status {
            return reorder(taskID: taskID, relativeTo: targetID)
        }

        guard setStatus(target.status, for: task, allowingUnfinishedSubtasks: allowingUnfinishedSubtasks) else { return false }
        if task.priority == target.priority {
            reorder(taskID: taskID, relativeTo: targetID)
        }
        return true
    }

    /// Drop onto a section's own area (header, gaps, empty placeholder).
    @discardableResult
    func drop(taskID: UUID, into status: TaskStatus, allowingUnfinishedSubtasks: Bool = false) -> Bool {
        guard let task = tasks.first(where: { $0.id == taskID }),
              task.status != status else {
            return false
        }
        return setStatus(status, for: task, allowingUnfinishedSubtasks: allowingUnfinishedSubtasks)
    }

    @discardableResult
    func reorder(taskID: UUID, relativeTo targetID: UUID) -> Bool {
        guard taskID != targetID,
              let task = tasks.first(where: { $0.id == taskID }),
              let target = tasks.first(where: { $0.id == targetID }),
              task.parentID == target.parentID,
              task.status == target.status,
              task.priority == target.priority else {
            return false
        }

        let owner = familyOwner(of: task)
        var group = (task.parentID.map(subtasks(of:)) ?? orderedTasks(for: task.status)).filter {
            $0.priority == task.priority && $0.parentID == task.parentID && $0.status == task.status
        }
        guard let sourceIndex = group.firstIndex(where: { $0.id == taskID }),
              let targetIndex = group.firstIndex(where: { $0.id == targetID }) else {
            return false
        }

        let movedTask = group.remove(at: sourceIndex)
        group.insert(movedTask, at: min(targetIndex, group.count))

        guard let destinationIndex = group.firstIndex(where: { $0.id == taskID }) else {
            return false
        }
        let timestamp = now()
        do {
            if let sparseOrder = sparseManualOrder(at: destinationIndex, in: group) {
                for replica in try storedTasks(matching: task.id) {
                    replica.manualOrder = sparseOrder
                    replica.updatedAt = timestamp
                }
            } else {
                // Legacy stores can have missing or tightly packed values. Pay the
                // O(n) rebalance once, then normal reorders only dirty the moved row.
                try assignSpacedManualOrders(to: group, updatedAt: timestamp)
            }
        } catch {
            context.rollback()
            // refresh() clears the notice on success, so the reorder failure
            // is reported after it, with the surface the row belongs to.
            refresh()
            report(error.localizedDescription, owner: owner)
            return false
        }
        return save(owner: owner)
    }

    func refresh() {
        do {
            try reloadTasks()
            errorNotice = nil
        } catch {
            report(error.localizedDescription, owner: nil)
        }
    }

    /// `owner` is the surface a failed save belongs to, decided by the
    /// operation that asked for it; a success clears any notice outright.
    @discardableResult
    private func save(owner: UUID? = nil) -> Bool {
        do {
            try persist(context)
            errorNotice = nil
            revision &+= 1
            #if !ATTIC_LOCAL_ONLY
            cloudSyncProtection.noteLocalSave()
            reconcileProtectedCloudSyncActivity(for: .exportData)
            #endif
            return true
        } catch {
            let saveError = error.localizedDescription
            context.rollback()
            do {
                try reloadTasks()
                report(saveError, owner: owner)
            } catch {
                report("\(saveError) · Reload failed: \(error.localizedDescription)", owner: owner)
            }
            return false
        }
    }

    private func reloadTasks() throws {
        // A long-lived ModelContext can return cached model instances after
        // CloudKit updates the underlying store. Refresh through a new context
        // so remote values replace the old objects instead of being written
        // back to CloudKit by the next local save.
        let refreshedContext = ModelContext(container)
        let fetched = try refreshedContext.fetch(FetchDescriptor<TaskItem>())
        context = refreshedContext
        // Deduplicate first, then hide: the replica presentation would show
        // decides whether the logical task is in Recently Deleted or the Done
        // log, exactly as it decides every other field.
        tasks = visibleUniqueTasks(from: fetched).filter {
            $0.deletedAt == nil && $0.doneLoggedAt == nil
        }
        revision &+= 1
    }

    /// CloudKit can't enforce a unique UUID attribute. If a malformed import
    /// ever produces duplicates, expose one app-level record. Never delete
    /// duplicates during refresh: device clocks aren't an ownership signal,
    /// and a cleanup save could destroy the valid peer copy across CloudKit.
    private func visibleUniqueTasks(from fetched: [TaskItem]) -> [TaskItem] {
        var newestByID: [UUID: TaskItem] = [:]

        for task in fetched {
            guard let existing = newestByID[task.id] else {
                newestByID[task.id] = task
                continue
            }

            if task.updatedAt > existing.updatedAt {
                newestByID[task.id] = task
            } else if task.updatedAt == existing.updatedAt,
                      Self.tieBreakKey(for: task) > Self.tieBreakKey(for: existing) {
                newestByID[task.id] = task
            }
        }

        return fetched.filter { task in
            newestByID[task.id] === task
        }
    }

    private func storedTasks(matching id: UUID) throws -> [TaskItem] {
        let groups = try storedTaskGroups(matching: [id])
        guard let replicas = groups[id], !replicas.isEmpty else {
            throw TaskReplicaMutationError.missingReplica(id)
        }
        return replicas
    }

    private func storedTaskGroups(
        matching ids: Set<UUID>
    ) throws -> [UUID: [TaskItem]] {
        // Every physical replica of each id, and nothing else: mutations
        // still fan out to all duplicates without reading the whole table.
        let idList = Array(ids)
        let stored = try context.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { idList.contains($0.id) }
        ))
        let groups = Dictionary(grouping: stored, by: \.id)
        if let missingID = ids.first(where: { groups[$0]?.isEmpty != false }) {
            throw TaskReplicaMutationError.missingReplica(missingID)
        }
        return groups
    }

    private func observeRemoteChanges() {
        #if !ATTIC_LOCAL_ONLY
        remoteChangeObservation = NotificationCenter.default.publisher(
            for: .NSPersistentStoreRemoteChange
        )
        .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.refresh()
        }
        #endif
    }

    private func observeCloudKitEvents() {
        #if !ATTIC_LOCAL_ONLY
        cloudKitEventObservation = NotificationCenter.default.publisher(
            for: NSPersistentCloudKitContainer.eventChangedNotification
        )
        .compactMap { notification in
            notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event
        }
        .receive(on: DispatchQueue.main)
        .sink { [weak self] event in
            guard let self, let kind = Self.activityKind(for: event.type) else { return }
            handleCloudSyncEvent(CloudSyncEventUpdate(
                id: event.identifier,
                kind: kind,
                endedAt: event.endDate,
                succeeded: event.succeeded,
                errorMessage: Self.cloudSyncErrorMessage(event.error)
            ))
        }
        #endif
    }

    /// A successful CloudKit import means the SQLite store has changed, but
    /// macOS does not reliably emit `NSPersistentStoreRemoteChange` for every
    /// SwiftData import. Coalesce completed imports and replace the context so
    /// the panel cannot remain attached to stale model instances.
    func handleCloudSyncEvent(_ update: CloudSyncEventUpdate) {
        #if ATTIC_LOCAL_ONLY
        // Dormant: a local-only build has no CloudKit container, so an event
        // posted in-process must not touch status, protection or refreshes.
        return
        #else
        handleDeferredCloudSyncEvent(update)
        #endif
    }

    private func handleDeferredCloudSyncEvent(_ update: CloudSyncEventUpdate) {
        cloudSyncProtection.apply(update)
        reconcileProtectedCloudSyncActivity(for: update.kind)
        cloudSyncStatus.apply(update)
        if !update.succeeded, let errorMessage = update.errorMessage {
            NSLog("CloudKit %@ failed: %@", String(describing: update.kind), errorMessage)
        }
        // A failed import may still have committed earlier batches. Refresh
        // after every completed import so partially applied changes are not
        // left hidden behind stale SwiftData model instances.
        guard update.kind == .importData, update.endedAt != nil else { return }

        cloudImportRefreshTask?.cancel()
        cloudImportRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.refresh()
            self?.cloudSyncProtection.completeImportRefresh()
            self?.reconcileProtectedCloudSyncActivity(for: .importData)
            self?.cloudImportRefreshTask = nil
        }
    }

    private func reconcileProtectedCloudSyncActivity(for kind: CloudSyncActivityKind) {
        let shouldProtect: Bool
        switch kind {
        case .exportData:
            shouldProtect = cloudSyncProtection.protectsExport
        case .importData:
            shouldProtect = cloudSyncProtection.protectsImport
        case .setup:
            return
        }

        if shouldProtect {
            beginProtectedCloudSyncActivity(for: kind)
        } else {
            endProtectedCloudSyncActivity(for: kind)
        }
    }

    /// Attic is an LSUIElement app and is normally hidden. Keep the process
    /// out of App Nap only while Core Data is handing a local save to CloudKit
    /// or applying an import, then release the assertion immediately. The
    /// timeout is a safety net for framework events that never complete.
    private func beginProtectedCloudSyncActivity(for kind: CloudSyncActivityKind) {
#if os(macOS)
        guard kind != .setup else { return }

        let processInfo = ProcessInfo.processInfo
        let reason: String
        switch kind {
        case .exportData:
            reason = "Exporting Attic changes to iCloud"
            if exportActivityToken == nil {
                exportActivityToken = processInfo.beginActivity(
                    options: .userInitiatedAllowingIdleSystemSleep,
                    reason: reason
                )
            }
            exportActivityTimeoutTask?.cancel()
            exportActivityTimeoutTask = activityTimeoutTask(for: .exportData)
        case .importData:
            reason = "Importing Attic changes from iCloud"
            if importActivityToken == nil {
                importActivityToken = processInfo.beginActivity(
                    options: .userInitiatedAllowingIdleSystemSleep,
                    reason: reason
                )
            }
            importActivityTimeoutTask?.cancel()
            importActivityTimeoutTask = activityTimeoutTask(for: .importData)
        case .setup:
            break
        }
#endif
    }

    private func endProtectedCloudSyncActivity(for kind: CloudSyncActivityKind) {
#if os(macOS)
        switch kind {
        case .exportData:
            exportActivityTimeoutTask?.cancel()
            exportActivityTimeoutTask = nil
            if let exportActivityToken {
                ProcessInfo.processInfo.endActivity(exportActivityToken)
                self.exportActivityToken = nil
            }
        case .importData:
            importActivityTimeoutTask?.cancel()
            importActivityTimeoutTask = nil
            if let importActivityToken {
                ProcessInfo.processInfo.endActivity(importActivityToken)
                self.importActivityToken = nil
            }
        case .setup:
            break
        }
#endif
    }

#if os(macOS)
    private func activityTimeoutTask(
        for kind: CloudSyncActivityKind
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.cloudSyncActivityTimeout)
            guard !Task.isCancelled else { return }
            self?.endProtectedCloudSyncActivity(for: kind)
        }
    }
#endif

    private func nextManualOrder(
        status: TaskStatus,
        priority: TaskPriority,
        parentID: UUID? = nil,
        excluding excludedID: UUID? = nil,
        updatedAt: Date
    ) throws -> Int64? {
        let group = tasks.filter {
            $0.id != excludedID && $0.status == status && $0.priority == priority && $0.parentID == parentID
        }
        guard let maximum = group.compactMap(\.manualOrder).max() else { return nil }
        guard maximum <= .max - Self.manualOrderStride else {
            let orderedGroup = (parentID.map(subtasks(of:)) ?? orderedTasks(for: status)).filter {
                $0.id != excludedID && $0.status == status && $0.priority == priority && $0.parentID == parentID
            }
            try assignSpacedManualOrders(to: orderedGroup, updatedAt: updatedAt)
            return Int64(orderedGroup.count + 1) * Self.manualOrderStride
        }
        return maximum + Self.manualOrderStride
    }

    private func sparseManualOrder(at index: Int, in orderedGroup: [TaskItem]) -> Int64? {
        guard orderedGroup.indices.contains(index) else { return nil }
        if orderedGroup.count == 1 { return Self.manualOrderStride }

        if index == 0 {
            guard let lower = orderedGroup[1].manualOrder,
                  lower <= .max - Self.manualOrderStride else { return nil }
            return lower + Self.manualOrderStride
        }

        if index == orderedGroup.count - 1 {
            guard let upper = orderedGroup[index - 1].manualOrder,
                  upper >= .min + Self.manualOrderStride else { return nil }
            return upper - Self.manualOrderStride
        }

        guard let upper = orderedGroup[index - 1].manualOrder,
              let lower = orderedGroup[index + 1].manualOrder,
              upper > lower else { return nil }
        let (distance, overflowed) = upper.subtractingReportingOverflow(lower)
        guard !overflowed, distance > 1 else { return nil }
        return lower + (distance / 2)
    }

    private func assignSpacedManualOrders(
        to orderedGroup: [TaskItem],
        updatedAt: Date
    ) throws {
        let groups = try storedTaskGroups(matching: Set(orderedGroup.map(\.id)))
        for (index, item) in orderedGroup.enumerated() {
            let order = Int64(orderedGroup.count - index) * Self.manualOrderStride
            for replica in groups[item.id] ?? [] {
                replica.manualOrder = order
                replica.updatedAt = updatedAt
            }
        }
    }

    private static func activityKind(
        for type: NSPersistentCloudKitContainer.EventType
    ) -> CloudSyncActivityKind? {
        switch type {
        case .setup: .setup
        case .import: .importData
        case .export: .exportData
        @unknown default: nil
        }
    }

    private static func cloudSyncErrorMessage(_ error: Error?) -> String? {
        guard let error else { return nil }
        let nsError = error as NSError
        var message = "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            message += " · \(underlyingError.domain) \(underlyingError.code): "
                + underlyingError.localizedDescription
        }
        return message
    }

    private static func normalized(_ title: String) -> String {
        title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func tieBreakKey(for task: TaskItem) -> String {
        // Built as separately typed statements: one 16-part literal was too
        // slow for some compilers to type-check. Same parts, same order.
        func bits(_ date: Date?) -> String {
            guard let date else { return "" }
            return String(date.timeIntervalSinceReferenceDate.bitPattern)
        }
        var parts: [String] = []
        parts.reserveCapacity(16)
        parts.append(task.title)
        parts.append(task.statusRaw)
        parts.append(task.priorityRaw)
        parts.append(bits(task.createdAt))
        parts.append(bits(task.completedAt))
        parts.append(task.manualOrder.map { String($0) } ?? "")
        parts.append(task.parentID?.uuidString ?? "")
        parts.append(task.imageReferencesData?.base64EncodedString() ?? "")
        parts.append(bits(task.deletedAt))
        parts.append(task.deletionRootID?.uuidString ?? "")
        parts.append(task.deletionMembersRaw)
        parts.append(task.removedAttachmentsData?.base64EncodedString() ?? "")
        parts.append(bits(task.doneLoggedAt))
        parts.append(task.tagsRaw)
        parts.append(task.dueDayRaw ?? "")
        parts.append(String(reflecting: task.persistentModelID))
        return parts.joined(separator: "\u{1F}")
    }
}
