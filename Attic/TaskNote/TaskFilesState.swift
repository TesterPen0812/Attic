import Combine
import Foundation
import SwiftData

/// What every surface reads about a task's files after slice 2 (UX plan
/// § 2.4, § 13): which families' files are in their note (the row's
/// paperclip and count retire), and each family's Earlier files with the
/// reason. Unmigrated families read through the old path exactly as on main.
@MainActor
final class TaskFilesState: ObservableObject {
    typealias Status = TaskAttachmentMigration.Status

    @Published private(set) var statuses: [UUID: Status] = [:]
    /// The last refusal seen for a family (a launch run or Move into Note).
    private var refusals: [UUID: TaskAttachmentMigration.Refusal] = [:]
    /// Families whose launch run waited (their note was open).
    private(set) var deferred: Set<UUID> = []
    private var running = false
    /// The note store follows a migration, a Move into Note or a reversal
    /// (the app's Notes page; tests' stores).
    var onNotesChanged: (() -> Void)?

    /// The status of a top-level task's family; `.none` when it has no
    /// legacy files at all.
    func status(of rootID: UUID) -> Status { statuses[rootID] ?? .none }

    /// The family's files are in its note: the row shows no paperclip
    /// unless Earlier files remain.
    func isMigrated(_ rootID: UUID) -> Bool { statuses[rootID]?.kind == .migrated }

    /// The files a row's paperclip counts and its files list shows: the
    /// legacy list for an unmigrated family (as on main), Earlier files
    /// for a migrated one.
    func rowFiles(for task: TaskItem) -> [TaskImageReference] {
        guard task.parentID == nil, let status = statuses[task.id], status.kind == .migrated else { return task.attachments }
        return status.earlier
    }

    func refresh(_ rootIDs: Set<UUID>? = nil, coordinator: WorkspaceOperationCoordinator) {
        var next = statuses
        let roots: Set<UUID>
        if let rootIDs { roots = rootIDs } else {
            let context = coordinator.freshContext()
            var all = Set((try? TaskAttachmentMigration.candidateRoots(in: context)) ?? [])
            all.formUnion(((try? context.fetch(FetchDescriptor<TaskAttachmentMigrationRecord>())) ?? []).map(\.id))
            roots = all
            next = [:]
        }
        for root in roots {
            let status = TaskAttachmentMigration.status(rootID: root, coordinator: coordinator, refusal: refusals[root])
            next[root] = status == .none ? nil : status
        }
        if next != statuses { statuses = next }
    }

    /// A family whose note is open on a page or in an editor waits: the
    /// migration never writes under an open session.
    static func noteIsOpen(_ rootID: UUID, notes: NotesPageController, coordinator: WorkspaceOperationCoordinator) -> Bool {
        if TaskNotePresenter.open(for: rootID) != nil { return true }
        guard let noteID = try? coordinator.sessions.resolve(.task(rootID)).1 else { return false }
        return notes.workspaceSessionIfCached(noteID) != nil
    }

    /// The background launch run (§ 13 "Safe running"): every family, one
    /// operation each, skipping families whose note is open.
    func runAtLaunch(tasks: TaskStore, isBusy: @escaping (UUID) -> Bool) async {
        guard !running, let coordinator = try? WorkspaceLegacyBridge.coordinator(for: tasks.container) else { return }
        running = true
        defer { running = false }
        refresh(coordinator: coordinator)
        let report = await TaskAttachmentMigration.runAll(coordinator: coordinator, files: tasks.taskImageFiles,
                                                          isBusy: isBusy, publish: { [weak tasks] in tasks?.refresh() })
        for (root, refusal) in report.refused { refusals[root] = refusal }
        deferred = report.deferred
        refresh(coordinator: coordinator)
        if !report.migrated.isEmpty || !report.reconciled.isEmpty { tasks.refresh(); onNotesChanged?() }
    }

    /// Earlier files' **Move into Note** (and the launch retry for a
    /// family that waited): one family, one operation.
    func moveIntoNote(_ rootID: UUID, tasks: TaskStore) async -> TaskAttachmentMigration.Outcome {
        guard let coordinator = try? WorkspaceLegacyBridge.coordinator(for: tasks.container) else { return .deferred }
        let outcome = await TaskAttachmentMigration.migrate(rootID: rootID, coordinator: coordinator, files: tasks.taskImageFiles,
                                                            force: true, publish: { [weak tasks] in tasks?.refresh() })
        if case let .refused(refusal) = outcome { refusals[rootID] = refusal } else { refusals[rootID] = nil }
        deferred.remove(rootID)
        onNotesChanged?()
        refresh([rootID], coordinator: coordinator)
        tasks.refresh()
        return outcome
    }

    /// A legacy list changed (an Earlier file removed): the family's
    /// status follows.
    func refreshAfterLegacyChange(_ rootID: UUID, tasks: TaskStore) {
        guard let coordinator = try? WorkspaceLegacyBridge.coordinator(for: tasks.container) else { return }
        refresh([rootID], coordinator: coordinator)
    }

    /// Reversal (UAT and support): never automatic.
    func reverse(_ rootID: UUID, tasks: TaskStore) async -> TaskAttachmentMigration.ReversalOutcome {
        guard let coordinator = try? WorkspaceLegacyBridge.coordinator(for: tasks.container) else {
            return .refused(String(localized: "Can't reverse now"))
        }
        let outcome = await TaskAttachmentMigration.reverse(rootID: rootID, coordinator: coordinator, publish: { [weak tasks] in tasks?.refresh() })
        onNotesChanged?()
        refresh([rootID], coordinator: coordinator)
        tasks.refresh()
        return outcome
    }
}
