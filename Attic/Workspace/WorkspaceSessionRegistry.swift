import AppKit
import Foundation
import SwiftData

/// A store identity, never an app/window/display identity. Memory stores are
/// distinct even when their configuration URLs happen to be the same.
enum WorkspacePersistenceDomain: Hashable {
    case disk([String])
    case memory(ObjectIdentifier)

    init(_ container: ModelContainer) {
        let stores = container.configurations.filter { !$0.isStoredInMemoryOnly }
        self = stores.isEmpty ? .memory(ObjectIdentifier(container))
            : .disk(stores.map { $0.url.resolvingSymlinksInPath().standardizedFileURL.path }.sorted())
    }
}

/// Headless authority for the future task-page surfaces. The Notes controller
/// supplies the existing editor and durability machinery; no second draft,
/// timer, history cursor or recovery journal is created here.
@MainActor
final class WorkspaceSessionRegistry {
    enum Identity: Hashable { case task(UUID), note(UUID) }
    struct Key: Hashable {
        let domain: WorkspacePersistenceDomain
        let workspace: Identity
    }
    private final class WeakRegistry {
        weak var value: WorkspaceSessionRegistry?
        init(_ value: WorkspaceSessionRegistry) { self.value = value }
    }
    private static var domains: [WorkspacePersistenceDomain: WeakRegistry] = [:]
    static func shared(for coordinator: WorkspaceOperationCoordinator) -> WorkspaceSessionRegistry {
        let domain = WorkspacePersistenceDomain(coordinator.container)
        domains = domains.filter { $0.value.value != nil }
        if let existing = domains[domain]?.value {
            if existing.coordinator == nil {
                existing.rebind(to: coordinator)
            }
            return existing
        }
        let registry = WorkspaceSessionRegistry(coordinator: coordinator, domain: domain)
        domains[domain] = WeakRegistry(registry)
        return registry
    }

    private weak var coordinator: WorkspaceOperationCoordinator?
    let domain: WorkspacePersistenceDomain
    private var sessions: [Identity: WorkspacePageSession] = [:]
    /// Optional diagnostic of rows actually materialized by alias resolution.
    var didFetchResolutionRows: ((Int, Int) -> Void)?
    private init(coordinator: WorkspaceOperationCoordinator, domain: WorkspacePersistenceDomain) {
        self.coordinator = coordinator; self.domain = domain
    }
    /// Shared-domain lookup calls this only after the previous coordinator
    /// disappears. Never carry pages bound to that coordinator into its successor.
    func rebind(to coordinator: WorkspaceOperationCoordinator) {
        sessions.removeAll()
        self.coordinator = coordinator
    }

    /// Resolve every physical alias conservatively. Divergent association
    /// replicas refuse instead of merging independently ordered workspaces.
    private func resolve(_ identity: Identity) throws -> (Identity, UUID?) {
        guard let coordinator else { throw WorkspaceFoundationError.protectedOwner }
        let context = coordinator.freshContext()
        var noteRows = 0, associationRows = 0
        func notes(id: UUID) throws -> [NoteItem] {
            let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
            noteRows += rows.count
            return rows
        }
        func links(noteID: UUID) throws -> [TaskNoteAssociation] {
            let rows = try context.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { $0.noteID == noteID && $0.detachedAt == nil }))
            associationRows += rows.count
            return rows
        }
        defer { didFetchResolutionRows?(noteRows, associationRows) }
        let taskID: UUID?
        switch identity {
        case let .task(id): taskID = id
        case let .note(id):
            let rows = try notes(id: id)
            guard !rows.isEmpty else { throw WorkspaceFoundationError.conflict }
            let associations = try links(noteID: id)
            let owners = Set(rows.compactMap(\.taskID)).union(associations.map(\.taskID))
            guard owners.count <= 1, rows.allSatisfy({ $0.taskID == rows[0].taskID }) else {
                throw WorkspaceFoundationError.conflict
            }
            taskID = owners.first
        }
        guard let taskID else {
            if case let .note(id) = identity { return (identity, id) }
            throw WorkspaceFoundationError.invalidIdentity
        }
        guard try context.fetchCount(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })) > 0 else {
            throw WorkspaceFoundationError.conflict
        }
        let taskNotes = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.taskID == taskID }))
        let taskLinks = try context.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { $0.taskID == taskID && $0.detachedAt == nil }))
        noteRows += taskNotes.count; associationRows += taskLinks.count
        let own = Set(taskNotes.map(\.id)).union(taskLinks.map(\.noteID))
        guard own.count <= 1 else { throw WorkspaceFoundationError.conflict }
        if let noteID = own.first {
            let rows = try notes(id: noteID)
            let associations = try links(noteID: noteID)
            guard !rows.isEmpty, rows.allSatisfy({ $0.taskID == nil || $0.taskID == taskID }),
                  associations.allSatisfy({ $0.taskID == taskID }) else {
                throw WorkspaceFoundationError.conflict
            }
        }
        return (.task(taskID), own.first)
    }

    func session(for identity: Identity, notes: NotesPageController) throws -> WorkspacePageSession {
        guard let coordinator else { throw WorkspaceFoundationError.protectedOwner }
        guard notes.store.container === coordinator.container else { throw WorkspaceFoundationError.invalidIdentity }
        let (canonical, noteID) = try resolve(identity)
        if let session = sessions[canonical] {
            guard session.controller === notes else { throw WorkspaceFoundationError.protectedOwner }
            // Lazy note creation may add an alias later, but never replace a
            // live draft or merge a second cursor.
            if session.note == nil, let noteID { try session.attach(noteID: noteID) }
            guard session.note?.noteID == noteID else { throw WorkspaceFoundationError.conflict }
            return session
        }
        let key = Key(domain: domain, workspace: canonical)
        let session = try WorkspacePageSession(key: key, controller: notes, coordinator: coordinator, noteID: noteID)
        session.onRelease = { [weak self] page in
            guard self?.sessions[canonical] === page else { return }
            self?.sessions[canonical] = nil
        }
        sessions[canonical] = session
        return session
    }
}

@MainActor
final class WorkspacePageSession {
    struct Lease: Equatable {
        fileprivate let sessionID: UUID
        let surfaceID: UUID
        fileprivate let generation: UInt64
    }
    struct CallbackStamp {
        fileprivate let lease: Lease
        fileprivate let note: NoteSession.CallbackStamp?
    }
    let id = UUID()
    let key: WorkspaceSessionRegistry.Key
    private(set) weak var controller: NotesPageController?
    private let route: UndoRoute
    let history: WorkspaceHistory
    private(set) var note: NoteSession?
    private(set) var activeLease: Lease?
    private var bindingGeneration: UInt64 = 0
    private var closing = false
    private var released = false
    fileprivate var onRelease: ((WorkspacePageSession) -> Void)?

    fileprivate init(key: WorkspaceSessionRegistry.Key, controller: NotesPageController,
                     coordinator: WorkspaceOperationCoordinator, noteID: UUID?) throws {
        self.key = key; self.controller = controller; route = controller.undoRoute
        let historyID: UndoHistoryID = switch key.workspace {
        case let .task(id): .taskWorkspace(id)
        case let .note(id): .note(id)
        }
        history = controller.undoRoute.workspace(for: historyID)
        coordinator.registerHistory(controller.undoRoute)
        if let noteID { try attach(noteID: noteID) }
    }
    fileprivate func attach(noteID: UUID) throws {
        guard let controller, note == nil,
              let session = controller.workspaceSession(noteID: noteID) else { throw WorkspaceFoundationError.conflict }
        let adapter = session.engine.history
        guard adapter.workspace === history || (adapter.workspace == nil && adapter.redoOps.isEmpty),
              history.bind(noteID: noteID) else { throw WorkspaceFoundationError.conflict }
        history.attach(adapter)
        session.usesWorkspaceBinding = true
        session.workspacePage = self
        note = session
    }

    func acquire(surfaceID: UUID) throws -> Lease {
        guard !closing, !released, controller != nil else { throw WorkspaceFoundationError.protectedOwner }
        if let activeLease {
            guard activeLease.surfaceID == surfaceID else { throw WorkspaceFoundationError.protectedOwner }
            return activeLease
        }
        return bind(surfaceID)
    }
    private func bind(_ surfaceID: UUID) -> Lease {
        bindingGeneration &+= 1
        note?.invalidateCallbacks()
        let lease = Lease(sessionID: id, surfaceID: surfaceID, generation: bindingGeneration)
        activeLease = lease
        if let note { controller?.resumeWorkspaceDurability(note) }
        return lease
    }
    func handoff(from lease: Lease, to surfaceID: UUID) throws -> Lease {
        guard !closing, controller != nil, activeLease == lease else { throw WorkspaceFoundationError.protectedOwner }
        if let note {
            guard NoteSessionPolicy.canLeave(note.engine.activity, hasMarkedText: note.engine.textView?.hasMarkedText() == true) else {
                throw WorkspaceFoundationError.protectedOwner
            }
        }
        // The editor/undo/staged bytes stay put. Native hosts attach the same
        // engine after the old host has detached in the page round.
        history.closeGroup()
        if let note { controller?.cancelWorkspaceImport(note) }
        note?.engine.detachView()
        return bind(surfaceID)
    }
    /// Event-driven invalidation; an external refresh is a named history
    /// barrier and cannot publish an older prepared editor snapshot.
    func externalRefresh(origin: String) {
        guard !released else { return }
        if let current = note, let refreshed = controller?.refreshWorkspaceSession(current) {
            history.attach(refreshed.engine.history)
            refreshed.usesWorkspaceBinding = true
            note = refreshed
        }
        history.recordExternalBarrier(origin: origin)
    }
    func captureCallback(for lease: Lease) -> CallbackStamp? {
        guard !closing, controller != nil, activeLease == lease else { return nil }
        return CallbackStamp(lease: lease, note: note?.callbackStamp)
    }
    @discardableResult
    func install(_ stamp: CallbackStamp, _ apply: () -> Void) -> Bool {
        guard !closing, controller != nil, activeLease == stamp.lease,
              stamp.note.map({ note?.accepts($0) == true }) ?? (note == nil) else { return false }
        apply(); return true
    }
    /// Publication can finish durably after its surface leaves. Drop only the
    /// stale editor installation; never repeat the committed store mutation.
    func publication(for stamp: CallbackStamp, install apply: @escaping () -> Void) -> WorkspaceOperationCoordinator.Publication {
        .init(steps: [{ [weak self] _ in _ = self?.install(stamp, apply) }])
    }
    func close(_ lease: Lease, resolvingFields: () -> Bool = { true }) async -> Bool {
        guard let controller, !closing, activeLease == lease, history.pendingCommandID == nil, history.pendingReplayID == nil else { return false }
        if let note {
            guard NoteSessionPolicy.canLeave(note.engine.activity, hasMarkedText: note.engine.textView?.hasMarkedText() == true) else { return false }
        }
        closing = true
        defer { closing = false }
        if let note {
            controller.cancelWorkspaceImport(note)
            guard await controller.preserveDurably(note), activeLease == lease, self.note === note,
                  controller.workspaceIsDurable(note),
                  NoteSessionPolicy.canLeave(note.engine.activity, hasMarkedText: note.engine.textView?.hasMarkedText() == true) else { return false }
        }
        // Resolve any native field entered while the checkpoint was awaited.
        // No suspension separates this boundary from revoking the lease.
        guard resolvingFields() else { return false }
        if let note { controller.suspendWorkspace(note) }
        bindingGeneration &+= 1
        note?.invalidateCallbacks()
        activeLease = nil
        if let note { controller.releaseWorkspace(note) }
        released = true
        onRelease?(self)
        onRelease = nil
        return true
    }
    /// A read-only projection for future lifecycle UI and the existing purge
    /// inventory. Hidden sessions retain the same ownership; no polling work.
    var activitySnapshot: WorkspacePurge.SessionSnapshot {
        var snapshot = WorkspacePurge.SessionSnapshot()
        if let note {
            snapshot.activity = note.engine.activity; snapshot.state = note.state
            snapshot.importing = note.isImporting
        }
        snapshot.replay = history.pendingReplayID != nil
        snapshot.publication = history.pendingCommandID != nil
        return snapshot
    }
}

/// Each field has its own undo target. Callers register native field actions
/// against `target`, never against their window or the workspace history.
@MainActor
final class WorkspaceFieldUndo {
    final class Target: NSObject {}
    let target = Target()
    private weak var manager: UndoManager?
    private var retired = false
    init(manager: UndoManager) { self.manager = manager }

    /// The store-confirmed commit supplies exactly one existing UndoStep.
    /// A refused commit leaves both draft and field-local Undo available.
    @discardableResult
    func commit(to history: WorkspaceHistory, save: () -> UndoStep?) -> Bool {
        guard !retired, history.reserveInput() else { return false }
        defer { history.releaseInput() }
        guard let step = save() else { return false }
        history.closeGroup()
        history.route.record(step, in: history.historyID)
        retire(); return true
    }
    func cancel() { retire() }
    private func retire() {
        guard !retired else { return }
        manager?.removeAllActions(withTarget: target)
        retired = true
    }
}
