import Foundation
import SwiftData
import SwiftUI

/// Whole-item groups are purged atomically. Surviving independent writing
/// uses the same Remove from Tasks materialization as legacy deletions.
/// Busy, divergent or ambiguously owned families stay for a later cleanup.
@MainActor
enum TaskNotePurge {
    /// A bounded candidate check before materializing any deletion families,
    /// live notes, associations or preservation records. An unreadable
    /// inventory must fall through to the existing conservative collector.
    static func hasExpiredCandidates(in context: ModelContext, before cutoff: Date) -> Bool {
        do {
            var firstTask = FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.deletedAt != nil },
                sortBy: [SortDescriptor(\.deletedAt)])
            firstTask.fetchLimit = 1
            if try context.fetch(firstTask).first?.deletedAt.map({ $0 < cutoff }) == true { return true }

            var firstNote = FetchDescriptor<NoteItem>(
                predicate: #Predicate { $0.deletedAt != nil && $0.deletionGroupID != nil },
                sortBy: [SortDescriptor(\.deletedAt)])
            firstNote.fetchLimit = 1
            return try context.fetch(firstNote).first?.deletedAt.map({ $0 < cutoff }) == true
        } catch {
            return true
        }
    }

    struct Report: Equatable {
        var removedTaskIDs: Set<UUID> = []
        /// Own notes that became ordinary notes.
        var materializedNoteIDs: Set<UUID> = []
        /// Families kept for a later cleanup (a busy editor, a conflict).
        var deferredRootIDs: Set<UUID> = []
        var deferredReasons: [UUID: String] = [:]
        var retainedByteReasons: [UUID: String] = [:]
    }

    @MainActor private final class PublicationState {
        var installed = false
        var keepDrafts: Set<UUID> = []
    }

    static func run(tasks: TaskStore, notes: NotesPageController, before cutoff: Date,
                    confirmed: [UUID: Date]? = nil, confirmedNotes: [UUID: Date]? = nil) async -> Report {
        var report = Report()
        guard let coordinator = try? WorkspaceLegacyBridge.coordinator(for: tasks.container) else { return report }
        let context = coordinator.freshContext()
        guard hasExpiredCandidates(in: context, before: cutoff) else { return report }
        guard let deleted = try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.deletedAt != nil })) else { return report }
        var roots: [UUID: Date] = [:]
        for row in deleted {
            guard let at = row.deletedAt, at < cutoff else { continue }
            let root = row.deletionRootID ?? row.id
            if let confirmed, confirmed[root] != at { continue }
            roots[root] = at
        }
        let circleRoots = (try? TaskStore.circleRemovedRoots(in: context)) ?? []
        let circleMembers = (try? TaskStore.circleRemovedMembers(in: context)) ?? []
        // Only grouped notes, detached redirects and active circle-removal
        // records can contribute to the candidate construction below.
        // The transaction still re-reads complete physical families before
        // deciding whether any of them can be removed.
        let allNotes = (try? context.fetch(FetchDescriptor<NoteItem>(
            predicate: #Predicate { $0.deletionGroupID != nil }
        ))) ?? []
        let associations = (try? context.fetch(FetchDescriptor<TaskNoteAssociation>(
            predicate: #Predicate { $0.detachedAt != nil }
        ))) ?? []
        let records = (try? context.fetch(FetchDescriptor<TaskDeletionPreservation>(
            predicate: #Predicate { $0.retiredAt == nil && $0.provenance == "circle removed" }
        ))) ?? []
        let deletedByRoot = Dictionary(grouping: deleted, by: { $0.deletionRootID ?? $0.id })
        let deletedGroups = Set(deleted.compactMap(\.deletionGroupID))
        let groupedRootIDs = Set(deleted.filter { $0.deletionGroupID != nil }.map(\.id))
        let notesByGroup = Dictionary(grouping: allNotes, by: { $0.deletionGroupID! })
        let redirectsByNote = Dictionary(grouping: associations.filter { circleRoots.contains($0.taskID) }, by: \.noteID)
        let associationsByNote = Dictionary(grouping: associations, by: \.noteID)
        let recordsByRoot = Dictionary(grouping: records, by: \.rootID)
        let recordsByID = Dictionary(grouping: records, by: \.id)
        var work: [(root: UUID, group: UUID?, date: Date)] = []
        // Ordinary redirect notes must also use the combined transaction.
        // Manual selection confirms the note's own date, never the circle's.
        let selectedNotes = confirmedNotes ?? (confirmed == nil ? nil : [:])
        var noteGroups = Set<UUID>()
        for note in allNotes {
            guard let date = note.deletedAt, date < cutoff, let group = note.deletionGroupID,
                  selectedNotes == nil || selectedNotes?[note.id] == date,
                  !deletedGroups.contains(group),
                  let redirect = redirectsByNote[note.id]?.first,
                  noteGroups.insert(group).inserted else { continue }
            work.append((redirect.taskID, group, date))
        }
        work += roots.keys.sorted { $0.uuidString < $1.uuidString }.map { ($0, nil, roots[$0]!) }
        for item in work {
            let root = item.root
            if report.removedTaskIDs.contains(root) || (circleMembers.contains(root) && !circleRoots.contains(root)) { continue }
            var ids = Set((deletedByRoot[root] ?? []).map(\.id))
            var own = ownNotes(of: ids, in: coordinator.freshContext())
            if let group = item.group { own.formUnion((notesByGroup[group] ?? []).map(\.id)) }
            let dependent = Set(own.flatMap { (associationsByNote[$0] ?? []).compactMap(\.detachedPreservationID) })
            let relevantRecords = (recordsByRoot[root] ?? []) + dependent.flatMap { recordsByID[$0] ?? [] }
            var seenRecords = Set<PersistentIdentifier>()
            for record in relevantRecords where seenRecords.insert(record.persistentModelID).inserted {
                if let snapshot = try? JSONDecoder().decode(WorkspacePurge.Preservation.self, from: record.snapshot) {
                    ids.formUnion(snapshot.members.map(\.id))
                }
            }
            own.formUnion(ownNotes(of: ids, in: coordinator.freshContext()))
            let grouped = groupedRootIDs.contains(root)
            guard item.group != nil || grouped || (try? WorkspacePurge.hasOwnNotesOrAssociations(ids, in: context)) == true else { continue }
            guard let reservations = notes.reserveTaskNoteInput(own) else {
                report.deferredRootIDs.insert(root)
                continue
            }
            let published = PublicationState()
            let materialize: (UUID, [WorkspaceMaterializationPatch]) throws -> Void = { [weak notes, weak tasks, weak coordinator] operation, patches in
                    guard let notes, let tasks, let coordinator else { return }
                    for patch in patches {
                        let history = notes.undoRoute.workspace(for: .taskWorkspace(patch.taskID))
                        if history.hasNewerPublicationDraft { published.keepDrafts.insert(patch.noteID) }
                        else {
                            if let session = notes.workspaceSessionIfCached(patch.noteID) {
                                guard session.engine.history.canPrepareWorkspaceCommand, !session.isImporting else {
                                    throw WorkspaceFoundationError.conflict
                                }
                            }
                            notes.retireMaterializedTaskNote(patch.noteID)
                            history.didPublishExternalForm()
                        }
                        try patch.record(operationID: operation, in: history, coordinator: coordinator, notes: notes)
                    }
                    published.installed = true
                    tasks.refresh(); notes.store.refresh()
                }
            let result: WorkspacePurge.Result
            if let group = item.group {
                result = await WorkspaceItemLifecycle.purge(group: group, before: cutoff, confirmed: item.date,
                    coordinator: coordinator, files: tasks.taskImageFiles,
                    inventory: { notes.taskNotePurgeInventory(ownNotes: own) }, publication: .init(), materialize: materialize)
            } else {
                result = await WorkspacePurge.purge(rootID: root, before: cutoff, confirmed: confirmed?[root],
                    coordinator: coordinator, files: tasks.taskImageFiles,
                    inventory: { notes.taskNotePurgeInventory(ownNotes: own) }, materialize: materialize)
            }

            let present: () async -> Void = { [weak notes] in
                guard let notes, let operation = result.operationID else { return }
                for patch in result.materialization where !published.keepDrafts.contains(patch.noteID) {
                    notes.taskNoteMaterialized?(patch, operation)
                }
            }
            if [.unknown, .publicationPending].contains(result.outcome), let operation = result.operationID {
                let leader = reservations.first ?? notes.undoRoute.workspace(for: .taskWorkspace(root))
                leader.trackExternalOperation(operation, using: coordinator, peers: reservations,
                    installed: published.installed, completion: present)
            } else { reservations.forEach { $0.releaseInput() } }
            report.retainedByteReasons.merge(result.retainedByteReasons) { _, latest in latest }
            if let reason = result.retentionReason { report.deferredReasons[root] = reason }
            guard result.outcome == .committed || result.outcome == .publicationPending else {
                report.deferredRootIDs.insert(root)
                continue
            }
            report.removedTaskIDs.formUnion(result.removedIDs)
            report.materializedNoteIDs.formUnion(result.materialization.map(\.noteID))
            if result.outcome == .committed { await present() }

        }
        if !report.removedTaskIDs.isEmpty {
            tasks.refresh()
            notes.store.refresh()
        }
        return report
    }

    /// Each is a table scan on the main actor, so tests bound the count.
    private(set) static var ownNotesFetchCount = 0

    private static func ownNotes(of taskIDs: Set<UUID>, in context: ModelContext) -> Set<UUID> {
        guard !taskIDs.isEmpty else { return [] }
        // A single expiring task should not fetch every other task's live
        // writing on each of its two ownership checks. Query all physical
        // rows for each member UUID, retaining the original broad fallback
        // if SwiftData cannot evaluate a scoped predicate.
        do {
            var owned = Set<UUID>()
            for taskID in taskIDs {
                ownNotesFetchCount += 2
                let noteRows = try context.fetch(FetchDescriptor<NoteItem>(
                    predicate: #Predicate { $0.taskID == taskID }))
                let links = try context.fetch(FetchDescriptor<TaskNoteAssociation>(
                    predicate: #Predicate { $0.taskID == taskID && $0.detachedAt == nil }))
                owned.formUnion(noteRows.map(\.id))
                owned.formUnion(links.map(\.noteID))
            }
            return owned
        } catch { /* Preserve the existing conservative broad read. */ }
        ownNotesFetchCount += 2
        let notes = (try? context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.taskID != nil }))) ?? []
        let links = (try? context.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { $0.detachedAt == nil }))) ?? []
        return Set(notes.filter { $0.taskID.map(taskIDs.contains) == true }.map(\.id))
            .union(links.filter { taskIDs.contains($0.taskID) }.map(\.noteID))
    }
}

/// The open page's side of a purge (§ 2.7.2, § 5.6 "Task purged while the
/// note was open"): its history gets the entry "Task removed permanently",
/// the page leaves, and the note opens in Notes as the ordinary note it now
/// is. The toast's Undo returns the pre-materialization text; the task
/// stays purged.
@MainActor
enum TaskNotePurgePresentation {
    static func finish(_ patch: WorkspaceMaterializationPatch, operationID: UUID, tasks: TaskStore,
                       notes: NotesPageController, uiState: PanelUIState, toasts: PanelToastCenter?,
                       showNotes: () -> Void) async {
        let wasShown = uiState.openTaskNoteID == patch.taskID
        if let presenter = TaskNotePresenter.open(for: patch.taskID), !(await presenter.close()) { return }
        notes.evictRetiredTaskNote(patch.noteID)
        TaskNoteRouteHost<EmptyView>.closeRoute(patch.taskID, uiState: uiState, controller: notes)
        guard let coordinator = try? WorkspaceLegacyBridge.coordinator(for: tasks.container) else { return }
        let history = notes.undoRoute.workspace(for: .taskWorkspace(patch.taskID))
        guard (try? patch.record(operationID: operationID, in: history, coordinator: coordinator, notes: notes)) != nil else { return }
        let stepID = history.route.steps(in: history.historyID, redo: false).last { $0.operationID == operationID }?.id
        if wasShown, notes.open(noteID: patch.noteID) { showNotes() }
        toasts?.show(String(localized: "Task removed permanently"), answersUndoKey: false, performingAsync: { [weak notes, weak history] in
            guard let notes, let history, let stepID else { return .obsolete }
            guard await history.undoLatest(stepID: stepID) == .applied else {
                return .failed(CommandFailure(String(localized: "Couldn't undo: the note changed since")))
            }
            notes.reloadAfterExternalChange(patch.noteID)
            return .applied
        })
    }
}
