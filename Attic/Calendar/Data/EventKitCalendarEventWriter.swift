import AppKit
import EventKit
import Foundation

/// One queue across engines: the same ownership file must never have two
/// transactions staged at once. No EventKit object leaves this queue.
private final class CalendarEventWriteWorker: @unchecked Sendable {
    static let queue = DispatchQueue(label: "com.taha.Attic.calendar-writes", qos: .userInitiated)
    private let makeCore: () throws -> CalendarEventTransactions
    private var core: CalendarEventTransactions?

    init(makeCore: @escaping () throws -> CalendarEventTransactions) { self.makeCore = makeCore }

    func perform<T: Sendable>(_ work: @escaping @Sendable (CalendarEventTransactions) throws -> T) async
        -> (Result<T, CalendarEventWriteError>, notify: Bool, recoveries: [CalendarOwnershipRecord.Recovery]) {
        await withCheckedContinuation { continuation in
            Self.queue.async { [self] in
                do {
                    let transaction: CalendarEventTransactions
                    if let core { transaction = core }
                    else { transaction = try makeCore(); core = transaction }
                    let result: Result<T, CalendarEventWriteError>
                    do { result = .success(try work(transaction)) }
                    catch { result = .failure(Self.typed(error)) }
                    continuation.resume(returning: (result, transaction.takeNotification(), transaction.takeRecoveries()))
                } catch {
                    continuation.resume(returning: (.failure(Self.typed(error)), false, []))
                }
            }
        }
    }

    private static func typed(_ error: Error) -> CalendarEventWriteError {
        error as? CalendarEventWriteError ?? .saveFailed(error.localizedDescription)
    }
}

/// A committed command and its exact inverse. Both EventKit adapters execute
/// the same plan; only their scheduling and Undo publication differ.
private struct CalendarEventCommandPlan<Value: Sendable>: Sendable {
    let name: String
    let value: Value
    let undo: @Sendable (CalendarEventTransactions) throws -> Void
    let redo: @Sendable (CalendarEventTransactions) throws -> Void
}

private enum CalendarEventCommands {
    static func undoAgentChange(_ id: UUID, expected: CalendarEventDraft?,
                                restore: CalendarEventDraft?, in core: CalendarEventTransactions) throws {
        switch (expected, restore) {
        case (let after?, nil): try core.remove(id, expecting: after)
        case (let after?, let before?): _ = try core.update(id, draft: before, expecting: after)
        case (nil, let before?): _ = try core.insert(id, draft: before)
        case (nil, nil): throw CalendarEventWriteError.undoUnavailable
        }
    }

    static func create(_ draft: CalendarEventDraft, id: UUID,
                       in core: CalendarEventTransactions) throws -> CalendarEventCommandPlan<CalendarOwnedEvent> {
        let made = try core.insert(id, draft: draft)
        return CalendarEventCommandPlan(name: "Create Event", value: made,
            undo: { try $0.remove(id, expecting: made.draft) },
            redo: { _ = try $0.insert(id, draft: made.draft) })
    }

    static func edit(_ id: UUID, draft: CalendarEventDraft, expecting: CalendarEventDraft?,
                     in core: CalendarEventTransactions) throws -> CalendarEventCommandPlan<CalendarOwnedEvent> {
        let before = try core.current(id).draft
        let edited = try core.update(id, draft: draft, expecting: expecting ?? before)
        return CalendarEventCommandPlan(name: "Edit Event", value: edited,
            undo: { _ = try $0.update(id, draft: before, expecting: edited.draft) },
            redo: { _ = try $0.update(id, draft: edited.draft, expecting: before) })
    }

    static func delete(_ id: UUID, expecting: CalendarEventDraft?, in core: CalendarEventTransactions) throws -> CalendarEventCommandPlan<Void> {
        let before = try core.current(id).draft
        try core.remove(id, expecting: expecting ?? before)
        return CalendarEventCommandPlan(name: "Delete Event", value: (),
            undo: { _ = try $0.insert(id, draft: before) },
            redo: { try $0.remove(id, expecting: before) })
    }

    static func replayOutcome(for error: Error) -> UndoOutcome {
        switch error as? CalendarEventWriteError {
        case .notOwned, .eventMissing, .eventChanged, .repeatingEvent: .obsolete
        default: .failed
        }
    }
}

/// Keep event commands serialized through their main-actor history publication,
/// not just through the disk commit. Cancellation never abandons a staged write.
@MainActor
private final class CalendarEventCommandGate {
    static let shared = CalendarEventCommandGate()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func leave() {
        if waiters.isEmpty { held = false }
        else { waiters.removeFirst().resume() }
    }
}

/// The live UI facade. Only immutable results cross the worker boundary;
/// errors, notifications, Undo and opening Calendar.app stay on main.
@MainActor
final class BackgroundCalendarEventWriter: CalendarEventWriter {
    private(set) var lastError: CalendarEventWriteError?
    private weak var undoRoute: UndoRoute?
    private let worker: CalendarEventWriteWorker
    private let center: NotificationCenter

    init(undoRoute: UndoRoute, notificationCenter: NotificationCenter = .default,
         makeCore: @escaping () throws -> CalendarEventTransactions) {
        self.undoRoute = undoRoute
        self.center = notificationCenter
        self.worker = CalendarEventWriteWorker(makeCore: makeCore)
    }

    func writableCalendars() async throws -> [CalendarWriteCalendar] {
        try await reporting { try $0.writableCalendars() }
    }

    func ownedEvent(matching occurrenceID: String) async throws -> CalendarOwnedEvent? {
        try await reporting { try $0.ownedEvent(matching: occurrenceID) }
    }

    func ownedEvent(id: UUID) async throws -> CalendarOwnedEvent? {
        try await reporting { try $0.ownedEvent(id: id) }
    }

    func create(_ draft: CalendarEventDraft) async throws -> CalendarOwnedEvent {
        await CalendarEventCommandGate.shared.enter()
        defer { CalendarEventCommandGate.shared.leave() }
        let route = try history()
        let id = UUID()
        let plan = try await reporting { try CalendarEventCommands.create(draft, id: id, in: $0) }
        record(plan, route: route)
        return plan.value
    }

    func edit(_ id: UUID, draft: CalendarEventDraft) async throws -> CalendarOwnedEvent {
        try await edit(id, draft: draft, expecting: nil)
    }

    func edit(_ id: UUID, draft: CalendarEventDraft, expecting: CalendarEventDraft?) async throws -> CalendarOwnedEvent {
        await CalendarEventCommandGate.shared.enter()
        defer { CalendarEventCommandGate.shared.leave() }
        let route = try history()
        let plan = try await reporting { try CalendarEventCommands.edit(id, draft: draft, expecting: expecting, in: $0) }
        record(plan, route: route)
        return plan.value
    }

    func delete(_ id: UUID) async throws {
        try await delete(id, expecting: nil)
    }

    func delete(_ id: UUID, expecting: CalendarEventDraft?) async throws {
        await CalendarEventCommandGate.shared.enter()
        defer { CalendarEventCommandGate.shared.leave() }
        let route = try history()
        let plan = try await reporting { try CalendarEventCommands.delete(id, expecting: expecting, in: $0) }
        record(plan, route: route)
    }

    func undoAgentChange(_ id: UUID, expected: CalendarEventDraft?,
                         restore: CalendarEventDraft?) async throws {
        await CalendarEventCommandGate.shared.enter()
        defer { CalendarEventCommandGate.shared.leave() }
        try await reporting { try CalendarEventCommands.undoAgentChange(id, expected: expected,
                                                                       restore: restore, in: $0) }
    }

    func openInCalendar(_ occurrenceID: String) async throws {
        if let url = try await reporting({ try $0.openingURL(occurrenceID) }), !NSWorkspace.shared.open(url) {
            lastError = .openFailed
            throw CalendarEventWriteError.openFailed
        }
    }

    private func history() throws -> UndoRoute {
        guard let undoRoute else {
            lastError = .undoUnavailable
            throw CalendarEventWriteError.undoUnavailable
        }
        return undoRoute
    }

    private func reporting<T: Sendable>(_ work: @escaping @Sendable (CalendarEventTransactions) throws -> T) async throws -> T {
        let (result, notify, recoveries) = await worker.perform(work)
        if let undoRoute {
            UndoRoute.$actionRecording.withValue(nil) {
                for recovery in recoveries { recordRecovery(recovery, route: undoRoute) }
            }
        }
        if notify { center.post(name: .EKEventStoreChanged, object: self) }
        switch result {
        case let .success(value): lastError = nil; return value
        case let .failure(error): lastError = error; throw error
        }
    }

    private func recordRecovery(_ recovery: CalendarOwnershipRecord.Recovery, route: UndoRoute) {
        let id = recovery.id
        switch (recovery.before, recovery.after) {
        case (nil, let after?):
            record(CalendarEventCommandPlan(name: "Create Event", value: (),
                undo: { try $0.remove(id, expecting: after.draft) },
                redo: { _ = try $0.insert(id, draft: after.draft) }), route: route)
        case (let before?, let after?):
            record(CalendarEventCommandPlan(name: "Edit Event", value: (),
                undo: { _ = try $0.update(id, draft: before.draft, expecting: after.draft) },
                redo: { _ = try $0.update(id, draft: after.draft, expecting: before.draft) }), route: route)
        case (let before?, nil):
            record(CalendarEventCommandPlan(name: "Delete Event", value: (),
                undo: { _ = try $0.insert(id, draft: before.draft) },
                redo: { try $0.remove(id, expecting: before.draft) }), route: route)
        case (nil, nil): break
        }
    }

    private func record<Value: Sendable>(_ plan: CalendarEventCommandPlan<Value>, route: UndoRoute) {
        var step = UndoStep(name: plan.name, undoOutcome: { .failed }, redoOutcome: { .failed })
        step.replay = { [self] isRedo, commit in
            await CalendarEventCommandGate.shared.enter()
            defer { CalendarEventCommandGate.shared.leave() }
            do {
                try await reporting(isRedo ? plan.redo : plan.undo)
                try commit()
                return .applied
            } catch { return CalendarEventCommands.replayOutcome(for: error) }
        }
        route.record(step, in: .calendar)
    }
}

/// Synchronous fixture facade over the same transactions. The app factory uses
/// BackgroundCalendarEventWriter; unit/UI fixtures retain deterministic Undo.
@MainActor
final class EventKitCalendarEventWriter: CalendarEventWriter {
    private(set) var lastError: CalendarEventWriteError?
    private let core: CalendarEventTransactions
    // History retains the engine through its closures, so it survives a page
    // view going away. The engine must not retain that history in a cycle.
    private weak var undoRoute: UndoRoute?
    private let center: NotificationCenter
    var isFakeBacked: Bool { core.isFakeBacked }

    init(store: CalendarEventWriteStore, record: CalendarOwnershipRecord, undoRoute: UndoRoute,
         notificationCenter: NotificationCenter = .default) {
        self.core = CalendarEventTransactions(store: store, record: record)
        self.undoRoute = undoRoute
        self.center = notificationCenter
    }

    func writableCalendars() throws -> [CalendarWriteCalendar] {
        try reporting { try core.writableCalendars() }
    }

    func ownedEvent(matching occurrenceID: String) throws -> CalendarOwnedEvent? {
        try reporting { try core.ownedEvent(matching: occurrenceID) }
    }

    func ownedEvent(id: UUID) throws -> CalendarOwnedEvent? {
        try reporting { try core.ownedEvent(id: id) }
    }

    func create(_ draft: CalendarEventDraft) throws -> CalendarOwnedEvent {
        try reporting {
            guard let undoRoute else { throw CalendarEventWriteError.undoUnavailable }
            let id = UUID()
            let plan = try CalendarEventCommands.create(draft, id: id, in: core)
            record(plan, route: undoRoute)
            return plan.value
        }
    }

    func edit(_ id: UUID, draft: CalendarEventDraft) throws -> CalendarOwnedEvent {
        try edit(id, draft: draft, expecting: nil)
    }

    func edit(_ id: UUID, draft: CalendarEventDraft, expecting: CalendarEventDraft?) throws -> CalendarOwnedEvent {
        try reporting {
            guard let undoRoute else { throw CalendarEventWriteError.undoUnavailable }
            let plan = try CalendarEventCommands.edit(id, draft: draft, expecting: expecting, in: core)
            record(plan, route: undoRoute)
            return plan.value
        }
    }

    func delete(_ id: UUID) throws {
        try delete(id, expecting: nil)
    }

    func delete(_ id: UUID, expecting: CalendarEventDraft?) throws {
        try reporting {
            guard let undoRoute else { throw CalendarEventWriteError.undoUnavailable }
            let plan = try CalendarEventCommands.delete(id, expecting: expecting, in: core)
            record(plan, route: undoRoute)
        }
    }

    func undoAgentChange(_ id: UUID, expected: CalendarEventDraft?,
                         restore: CalendarEventDraft?) throws {
        try reporting { try CalendarEventCommands.undoAgentChange(id, expected: expected,
                                                                  restore: restore, in: core) }
    }

    func openInCalendar(_ occurrenceID: String) throws {
        try reporting {
            if let url = try core.openingURL(occurrenceID), !NSWorkspace.shared.open(url) {
                throw CalendarEventWriteError.openFailed
            }
        }
    }

    private func reporting<T>(_ work: () throws -> T) throws -> T {
        defer {
            UndoRoute.$actionRecording.withValue(nil) { publishRecoveries() }
            postChanges()
        }
        do {
            let value = try work()
            lastError = nil
            return value
        } catch {
            let typed = error as? CalendarEventWriteError ?? .saveFailed(error.localizedDescription)
            lastError = typed
            throw typed
        }
    }

    private func publishRecoveries() {
        let recovered = core.takeRecoveries()
        guard let undoRoute else { return }
        for recovery in recovered {
            let id = recovery.id
            let step: UndoStep
            switch (recovery.before, recovery.after) {
            case (nil, let after?):
                step = UndoStep(name: "Create Event",
                    undoOutcome: { [self] in replay { try core.remove(id, expecting: after.draft) } },
                    redoOutcome: { [self] in replay { _ = try core.insert(id, draft: after.draft) } })
            case (let before?, let after?):
                step = UndoStep(name: "Edit Event",
                    undoOutcome: { [self] in replay { _ = try core.update(id, draft: before.draft, expecting: after.draft) } },
                    redoOutcome: { [self] in replay { _ = try core.update(id, draft: after.draft, expecting: before.draft) } })
            case (let before?, nil):
                step = UndoStep(name: "Delete Event",
                    undoOutcome: { [self] in replay { _ = try core.insert(id, draft: before.draft) } },
                    redoOutcome: { [self] in replay { try core.remove(id, expecting: before.draft) } })
            case (nil, nil): continue
            }
            undoRoute.record(step, in: .calendar)
        }
    }

    private func postChanges() {
        if core.takeNotification() { center.post(name: .EKEventStoreChanged, object: self) }
    }

    private func record<Value: Sendable>(_ plan: CalendarEventCommandPlan<Value>, route: UndoRoute) {
        route.record(UndoStep(name: plan.name,
            undoOutcome: { [self] in replay { try plan.undo(core) } },
            redoOutcome: { [self] in replay { try plan.redo(core) } }), in: .calendar)
    }

    private func replay(_ work: () throws -> Void) -> UndoOutcome {
        do { try reporting(work); return .applied }
        catch { return CalendarEventCommands.replayOutcome(for: error) }
    }
}

/// A complete ownership transaction is synchronous and confined to one owner.
/// Live instances run ONLY on CalendarEventWriteWorker.queue; injected unit
/// fixtures may run synchronously on the main actor through the facade above.
final class CalendarEventTransactions {
    private let store: CalendarEventWriteStore
    private let record: CalendarOwnershipRecord
    private var notificationNeeded = false
    private var recovered: [CalendarOwnershipRecord.Recovery] = []
    var isFakeBacked: Bool { store is FakeCalendarEventWriteStore }

    init(store: CalendarEventWriteStore, record: CalendarOwnershipRecord) {
        self.store = store
        self.record = record
    }

    func takeNotification() -> Bool {
        defer { notificationNeeded = false }
        return notificationNeeded
    }

    func takeRecoveries() -> [CalendarOwnershipRecord.Recovery] {
        defer { recovered.removeAll() }
        return recovered
    }

    func writableCalendars() throws -> [CalendarWriteCalendar] {
        try begin()
        return store.calendars().filter(\.isWritable)
    }

    func ownedEvent(matching occurrenceID: String) throws -> CalendarOwnedEvent? {
        try begin()
        for id in record.entries.keys {
            guard let current = try? editable(id), current.occurrenceID == occurrenceID else { continue }
            return owned(id, current)
        }
        return nil
    }

    func ownedEvent(id: UUID) throws -> CalendarOwnedEvent? {
        try begin()
        guard let current = try? editable(id) else { return nil }
        return owned(id, current)
    }

    func current(_ id: UUID) throws -> CalendarWriteSnapshot {
        try begin()
        return try editable(id)
    }

    func openingURL(_ occurrenceID: String) throws -> URL? {
        try store.openInCalendar(occurrenceID)
    }

    private func requireAccess() throws {
        guard store.accessState == .granted else { throw CalendarEventWriteError.accessDenied }
    }

    private func begin(write: Bool = false) throws {
        try requireAccess()
        let recovery = try record.reload(using: store)
        if let recovery {
            recovered.append(recovery)
            if !store.postsChangeNotifications { notificationNeeded = true }
        }
        // Do not let a retried Create stage a duplicate while the previous
        // committed event is held, or in the same request that resolves it.
        if write && (record.hasPendingTransition || recovery != nil) {
            throw CalendarEventWriteError.saveFailed("A previous Calendar write is awaiting verification or review.")
        }
    }

    private func requireWritable(_ calendarID: String) throws {
        guard let calendar = store.calendars().first(where: { $0.id == calendarID }) else {
            throw CalendarEventWriteError.calendarMissing
        }
        guard calendar.isWritable else { throw CalendarEventWriteError.calendarReadOnly }
    }

    private func validate(_ draft: CalendarEventDraft) throws {
        try draft.validateForWrite()
        try requireWritable(draft.calendarID)
    }

    private func editable(_ id: UUID) throws -> CalendarWriteSnapshot {
        guard let proof = record.entries[id] else { throw CalendarEventWriteError.notOwned }
        guard let live = store.event(identifier: proof.eventIdentifier) ?? store.event(identifier: proof.itemIdentifier) else {
            throw CalendarEventWriteError.eventMissing
        }
        guard !live.isRepeating else { throw CalendarEventWriteError.repeatingEvent }
        try requireWritable(live.draft.calendarID)
        guard live.matchesOwnership(of: proof) else { throw CalendarEventWriteError.eventChanged }
        return live
    }

    func insert(_ id: UUID, draft: CalendarEventDraft) throws -> CalendarOwnedEvent {
        try begin(write: true)
        guard record.entries[id] == nil else { throw CalendarEventWriteError.eventChanged }
        let draft = draft.roundedToMinutes
        try validate(draft)
        try transaction(id, before: nil) { try store.stageCreate(draft) }
        guard let saved = record.entries[id] else { throw CalendarEventWriteError.eventMissing }
        return owned(id, saved)
    }

    func update(_ id: UUID, draft: CalendarEventDraft, expecting: CalendarEventDraft) throws -> CalendarOwnedEvent {
        try begin(write: true)
        let previous = try editable(id)
        guard previous.draft.hasSameOwnedValues(as: expecting),
              (previous.draft.notes ?? "") == (expecting.notes ?? "") else { throw CalendarEventWriteError.eventChanged }
        // Only newly created events use minute rounding. An edit may retain
        // existing seconds or fractions, including during Undo and Redo.
        try validate(draft)
        try transaction(id, before: previous) { try store.stageEdit(previous, draft: draft) }
        guard let saved = record.entries[id] else { throw CalendarEventWriteError.eventMissing }
        return owned(id, saved)
    }

    func remove(_ id: UUID, expecting: CalendarEventDraft) throws {
        try begin(write: true)
        let previous = try editable(id)
        guard previous.draft.hasSameOwnedValues(as: expecting),
              (previous.draft.notes ?? "") == (expecting.notes ?? "") else { throw CalendarEventWriteError.eventChanged }
        try transaction(id, before: previous) {
            try store.stageDelete(previous)
            return nil
        }
    }

    private func transaction(_ id: UUID, before: CalendarWriteSnapshot?,
                             stage: () throws -> CalendarWriteSnapshot?) throws {
        var attemptedCommit = false
        var commitConfirmed = false
        do {
            let after = try stage()
            try record.prepare(id: id, before: before, after: after)
            try requireAccess()
            // The file write can take time. Re-read committed state through
            // the backend's independent reader before committing staged edits.
            if before != nil { _ = try editable(id) }
            if let after { try requireWritable(after.draft.calendarID) }
            attemptedCommit = true
            try store.commit()
            commitConfirmed = true
            let resolution = record.resolve(using: store, commitConfirmed: true)
            if !store.postsChangeNotifications { notificationNeeded = true }
            guard resolution.landed else {
                throw CalendarEventWriteError.saveFailed("Calendar has not verified the write; it is held for recovery.")
            }
        } catch {
            store.rollback()
            if !attemptedCommit {
                try record.abortUncommitted()
                throw error
            }
            if commitConfirmed { throw error }
            // A thrown commit may already have landed. Use the same committed
            // state reconciliation as relaunch, retaining any verified creation.
            let resolution = record.resolve(using: store)
            if resolution.changed && !store.postsChangeNotifications { notificationNeeded = true }
            // A verified landed operation must register/advance Undo normally.
            // Pre-commit failures and ambiguous outcomes retain the typed error.
            if attemptedCommit && resolution.landed { return }
            if let refusal = error as? CalendarEventWriteError, refusal.isPrecommitRefusal {
                throw CalendarEventWriteError.saveFailed("The Calendar commit result could not be verified.")
            }
            throw error
        }
    }

    private func owned(_ id: UUID, _ snapshot: CalendarWriteSnapshot) -> CalendarOwnedEvent {
        CalendarOwnedEvent(id: id, occurrenceID: snapshot.occurrenceID, draft: snapshot.draft)
    }

}
