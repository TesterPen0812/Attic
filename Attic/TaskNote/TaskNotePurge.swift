import Foundation
import SwiftData
import SwiftUI

/// Removing for good a deleted task whose family owns notes (UX plan
/// § 2.7.2, S5): the legacy collector leaves these families alone, so the
/// daily cleanup and Empty Recently Deleted send them through the
/// coordinated purge. One store transaction per family materializes each
/// live own note into an ordinary note and clears its association.
///
/// A note open on a task's page is materialized through its session: the
/// draft the person is writing is what the purge saves (merged, never
/// replaced by stored content); a composition, an import or a conflict
/// defers the family to a later cleanup. The page then leaves, and the
/// note is ordinary.
@MainActor
enum TaskNotePurge {
    struct Report: Equatable {
        var removedTaskIDs: Set<UUID> = []
        /// Own notes that became ordinary notes.
        var materializedNoteIDs: Set<UUID> = []
        /// Families kept for a later cleanup (a busy editor, a conflict).
        var deferredRootIDs: Set<UUID> = []
    }

    static func run(tasks: TaskStore, notes: NotesPageController, before cutoff: Date,
                    confirmed: [UUID: Date]? = nil) async -> Report {
        var report = Report()
        guard let coordinator = try? WorkspaceLegacyBridge.coordinator(for: tasks.container) else { return report }
        let context = coordinator.freshContext()
        guard let deleted = try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.deletedAt != nil })) else { return report }
        var roots: [UUID: Date] = [:]
        for row in deleted {
            guard let at = row.deletedAt, at < cutoff else { continue }
            let root = row.deletionRootID ?? row.id
            if let confirmed, confirmed[root] != at { continue }
            roots[root] = at
        }
        for root in roots.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let ids = Set(deleted.filter { ($0.deletionRootID ?? $0.id) == root }.map(\.id))
            guard (try? WorkspacePurge.hasOwnNotesOrAssociations(ids, in: context)) == true else { continue }
            let own = ownNotes(of: ids, in: coordinator.freshContext())
            guard let reservations = notes.reserveTaskNoteInput(own) else {
                report.deferredRootIDs.insert(root)
                continue
            }
            let result = await WorkspacePurge.purge(rootID: root, before: cutoff, confirmed: confirmed?[root],
                                                     coordinator: coordinator, files: tasks.taskImageFiles,
                                                     inventory: { notes.taskNotePurgeInventory(ownNotes: own) })
            guard result.outcome == .committed || result.outcome == .publicationPending else {
                reservations.forEach { $0.releaseInput() }
                report.deferredRootIDs.insert(root)
                continue
            }
            report.removedTaskIDs.formUnion(result.removedIDs)
            for patch in result.materialization {
                report.materializedNoteIDs.insert(patch.noteID)
                notes.retireMaterializedTaskNote(patch.noteID)
                if let operationID = result.operationID {
                    let history = notes.undoRoute.workspace(for: .taskWorkspace(patch.taskID))
                    try? patch.record(operationID: operationID, in: history, coordinator: coordinator, notes: notes)
                    notes.taskNoteMaterialized?(patch, operationID)
                }
            }
            reservations.forEach { $0.releaseInput() }
        }
        if !report.removedTaskIDs.isEmpty {
            tasks.refresh()
            notes.store.refresh()
        }
        return report
    }

    private static func ownNotes(of taskIDs: Set<UUID>, in context: ModelContext) -> Set<UUID> {
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
        TaskNoteRouteHost<EmptyView>.closeRoute(patch.taskID, uiState: uiState)
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
