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
    let imageReferencesData: Data?

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
    }
}

private enum TaskReplicaMutationError: LocalizedError {
    case missingReplica(UUID)

    var errorDescription: String? {
        switch self {
        case let .missingReplica(id):
            "The task replicas for \(id.uuidString) could not be loaded safely."
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
    @Published private(set) var lastErrorMessage: String? {
        didSet { if lastErrorMessage == nil { lastErrorOwnerID = nil } }
    }
    /// The family a task error concerns, when it concerns one: its panel
    /// shows the message and the main panel stays quiet. nil is a general
    /// or main-composer error, shown by the main panel alone.
    @Published private(set) var lastErrorOwnerID: UUID?

    /// The user dismissed the notice, or a later success made it stale.
    func dismissError() {
        guard lastErrorMessage != nil else { return }
        lastErrorMessage = nil
    }

    private func report(_ message: String, owner: UUID?) {
        lastErrorOwnerID = owner
        lastErrorMessage = message
    }

    func reportUnavailableAttachment(named filename: String, owner: UUID? = nil) {
        report("“\(filename)” is missing or changed in Attic’s private storage.", owner: owner)
    }

    func reportAttachmentOpenFailure(named filename: String, error: Error, owner: UUID? = nil) {
        report("Couldn’t open “\(filename)”. \(error.localizedDescription)", owner: owner)
    }
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var cloudSyncStatus = CloudSyncStatus()

    private let container: ModelContainer
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
        let normalizedTitle = Self.normalized(title)
        guard !normalizedTitle.isEmpty else { return nil }

        let timestamp = now()
        let manualOrder: Int64?
        do {
            if let parentID {
                let parents = try storedTasks(matching: parentID)
                guard parents.allSatisfy({ $0.parentID == nil && $0.status != .done }) else {
                    report("Subtasks need an unfinished main task. Reopen the main task first.", owner: parentID)
                    return nil
                }
            }
            manualOrder = try nextManualOrder(
                status: status,
                priority: priority,
                parentID: parentID,
                updatedAt: timestamp
            )
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
        let task = TaskItem(
            title: normalizedTitle,
            status: status,
            priority: priority,
            createdAt: timestamp,
            completedAt: status == .done ? timestamp : nil,
            manualOrder: manualOrder,
            parentID: parentID
        )
        // References the composer already imported are bound in this same
        // save, so a new task never exists without them (or they without it).
        if !attachments.isEmpty {
            do {
                task.imageReferencesData = try JSONEncoder().encode(attachments)
            } catch {
                lastErrorMessage = error.localizedDescription
                return nil
            }
        }
        context.insert(task)
        tasks.append(task)
        guard save() else { return nil }
        return task
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
        allowingUnfinishedSubtasks: Bool = false
    ) -> Bool {
        guard let task = tasks.first(where: { $0.id == task.id }) else { return false }
        let replicas: [TaskItem]
        do {
            replicas = try storedTasks(matching: task.id)
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
        let normalizedTitle = title.map(Self.normalized)
        if let normalizedTitle, normalizedTitle.isEmpty { return false }

        let destinationTitle = normalizedTitle ?? task.title
        let destinationPriority = priority ?? task.priority
        let destinationStatus = status ?? task.status
        // Status rules are checked against every stored replica, but only
        // the rows they concern: a title or priority edit fetches nothing.
        if destinationStatus != task.status {
            do {
                let doneRaw = TaskStatus.done.rawValue
                if destinationStatus == .done, !allowingUnfinishedSubtasks {
                    let taskID = task.id
                    var unfinishedChildren = FetchDescriptor<TaskItem>(
                        predicate: #Predicate { $0.parentID == taskID && $0.statusRaw != doneRaw }
                    )
                    unfinishedChildren.fetchLimit = 1
                    if try !context.fetch(unfinishedChildren).isEmpty {
                        lastErrorMessage = "Finish the subtasks before completing this task."
                        return false
                    }
                }
                if destinationStatus != .done, task.status == .done, let parentID = task.parentID {
                    var doneParents = FetchDescriptor<TaskItem>(
                        predicate: #Predicate { $0.id == parentID && $0.statusRaw == doneRaw }
                    )
                    doneParents.fetchLimit = 1
                    if try !context.fetch(doneParents).isEmpty {
                        lastErrorMessage = "Reopen the main task before reopening a subtask."
                        return false
                    }
                }
            } catch {
                lastErrorMessage = error.localizedDescription
                return false
            }
        }
        let titleChanged = destinationTitle != task.title
        let priorityChanged = destinationPriority != task.priority
        let statusChanged = destinationStatus != task.status
        let visibleSnapshot = TaskReplicaSnapshot(task)
        let replicasNeedRepair = replicas.contains {
            TaskReplicaSnapshot($0) != visibleSnapshot
        }
        guard titleChanged || priorityChanged || statusChanged || replicasNeedRepair else {
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
                lastErrorMessage = error.localizedDescription
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

        for replica in replicas {
            replica.title = destinationTitle
            replica.priority = destinationPriority
            replica.status = destinationStatus
            replica.createdAt = task.createdAt
            replica.parentID = task.parentID
            replica.imageReferencesData = task.imageReferencesData
            replica.manualOrder = destinationManualOrder
            replica.completedAt = destinationCompletedAt
            replica.updatedAt = timestamp
        }
        return save()
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
        guard let ownerID = attachmentOwnerID(for: taskID),
              let initial = tasks.first(where: { $0.id == ownerID }) else {
            lastErrorMessage = "Couldn’t attach files. The task is no longer available."
            return nil
        }
        guard !importingAttachmentTaskIDs.contains(ownerID) else {
            report("Attic is still attaching files to “\(initial.title)”. Try again when it finishes.", owner: ownerID)
            return nil
        }
        importingAttachmentTaskIDs.insert(ownerID)
        defer { importingAttachmentTaskIDs.remove(ownerID) }
        var imported: [TaskImageReference] = []
        do {
            imported = try await importing(ownerID, initial.attachments)
            guard let current = tasks.first(where: { $0.id == ownerID }) else {
                await taskImageFiles.remove(imported)
                report("Couldn’t attach files. The task was deleted while they were copied.", owner: nil)
                return nil
            }
            let data = try JSONEncoder().encode(current.attachments + imported)
            for replica in try storedTasks(matching: ownerID) {
                replica.imageReferencesData = data
                replica.updatedAt = now()
            }
            guard save() else {
                await taskImageFiles.remove(imported); return nil
            }
            return imported.map(\.id)
        } catch {
            await taskImageFiles.remove(imported)
            reportAttachmentImportFailure(error, owner: ownerID)
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

    @discardableResult
    func removeAttachment(_ attachmentID: UUID, from taskID: UUID) -> Bool {
        guard let task = tasks.first(where: { $0.id == taskID }),
              let removed = task.attachments.first(where: { $0.id == attachmentID }) else { return false }
        do {
            let data = try JSONEncoder().encode(task.attachments.filter { $0.id != attachmentID })
            for replica in try storedTasks(matching: taskID) {
                replica.imageReferencesData = data; replica.updatedAt = now()
            }
            guard save() else { return false }
            removeAttachmentFiles([removed], excludingTaskIDs: [])
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
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
            predicate: #Predicate { $0.imageReferencesData != nil }
        )
        var referencedIDs = Set<UUID>()
        for replica in try context.fetch(withAttachments) where !deleted.contains(replica.id) {
            guard let data = replica.imageReferencesData, !data.isEmpty else { continue }
            let references = try JSONDecoder().decode([TaskImageReference].self, from: data)
            referencedIDs.formUnion(references.map(\.id))
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

    @discardableResult
    func delete(_ task: TaskItem) -> Bool {
        guard let task = tasks.first(where: { $0.id == task.id }) else { return false }
        let replicas: [TaskItem]
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
            let family = try context.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { linkedIDs.contains($0.id) }
            ))
            let groups = Dictionary(grouping: family, by: \.id)
            guard groups[task.id]?.isEmpty == false else {
                throw TaskReplicaMutationError.missingReplica(task.id)
            }
            guard groups.values.allSatisfy({ Set($0.map(\.parentID)).count == 1 }) else {
                lastErrorMessage = "Conflicting subtask links prevent safe deletion. Refresh and resolve them first."
                return false
            }
            guard family.allSatisfy({ item in
                item.id == task.id || (task.parentID == nil && item.parentID == task.id)
            }) else {
                lastErrorMessage = "An unsupported nested or cyclic subtask link prevents safe deletion."
                return false
            }
            for childID in Set(family.map(\.id)).subtracting([task.id]) {
                var nested = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.parentID == childID })
                nested.fetchLimit = 1
                if try !context.fetch(nested).isEmpty {
                    lastErrorMessage = "An unsupported nested or cyclic subtask link prevents safe deletion."
                    return false
                }
            }
            replicas = family
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
        let removedImages = replicas.flatMap(\.attachments)
        replicas.forEach(context.delete)
        let deletedIDs = Set(replicas.map(\.id))
        tasks.removeAll { deletedIDs.contains($0.id) }
        guard save() else { return false }
        removeAttachmentFiles(removedImages, excludingTaskIDs: deletedIDs)
        return true
    }

    @discardableResult
    func purgeCompleted(before cutoff: Date) -> Int {
        // Only expiry candidates and their immediate family are read: every
        // replica of each candidate (so divergent duplicates still refuse
        // cleanup), the candidates' children, and their parents. Rows that
        // are neither can't change which candidates expire.
        let stored: [TaskItem]
        do {
            let doneRaw = TaskStatus.done.rawValue
            // Read only the done rows, then apply the completion cutoff in
            // memory. The hosted macOS 26.6 runtime throws SwiftDataError-1
            // for predicates that order-compare the optional completedAt
            // date (and silently returned no rows for the earlier coalesced
            // form), so the date never belongs in the fetch. Done rows are
            // what the daily purge can expire, which keeps this bounded.
            let candidates = try context.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.statusRaw == doneRaw }
            )).filter { task in
                guard let completedAt = task.completedAt else { return false }
                return completedAt < cutoff
            }
            guard !candidates.isEmpty else { return 0 }
            let candidateIDs = Array(Set(candidates.map(\.id)))
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
                return candidateIDs.contains(parentID)
            }
            var seen = Set<PersistentIdentifier>()
            stored = (replicas + children).filter { seen.insert($0.persistentModelID).inserted }
        } catch {
            lastErrorMessage = error.localizedDescription
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
        let expired = stored.filter { expiredIDs.contains($0.id) }
        let removedImages = expired.flatMap(\.attachments)
        expired.forEach(context.delete)
        tasks.removeAll { expiredIDs.contains($0.id) }
        guard save() else { return 0 }
        removeAttachmentFiles(removedImages, excludingTaskIDs: expiredIDs)
        return expiredIDs.count
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
            refresh()
            lastErrorMessage = error.localizedDescription
            return false
        }
        return save()
    }

    func refresh() {
        do {
            try reloadTasks()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func save() -> Bool {
        do {
            try persist(context)
            lastErrorMessage = nil
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
                lastErrorMessage = saveError
            } catch {
                lastErrorMessage = "\(saveError) · Reload failed: \(error.localizedDescription)"
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
        tasks = visibleUniqueTasks(from: fetched)
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
        [
            task.title,
            task.statusRaw,
            task.priorityRaw,
            String(task.createdAt.timeIntervalSinceReferenceDate.bitPattern),
            task.completedAt.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "",
            task.manualOrder.map(String.init) ?? "",
            task.parentID?.uuidString ?? "",
            task.imageReferencesData?.base64EncodedString() ?? "",
            String(reflecting: task.persistentModelID)
        ].joined(separator: "\u{1F}")
    }
}
