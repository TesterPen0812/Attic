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
        -> (Result<T, CalendarEventWriteError>, notify: Bool) {
        await withCheckedContinuation { continuation in
            Self.queue.async { [self] in
                do {
                    let transaction: CalendarEventTransactions
                    if let core { transaction = core }
                    else { transaction = try makeCore(); core = transaction }
                    let result: Result<T, CalendarEventWriteError>
                    do { result = .success(try work(transaction)) }
                    catch { result = .failure(Self.typed(error)) }
                    continuation.resume(returning: (result, transaction.takeNotification()))
                } catch {
                    continuation.resume(returning: (.failure(Self.typed(error)), false))
                }
            }
        }
    }

    private static func typed(_ error: Error) -> CalendarEventWriteError {
        error as? CalendarEventWriteError ?? .saveFailed(error.localizedDescription)
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

    func create(_ draft: CalendarEventDraft) async throws -> CalendarOwnedEvent {
        await CalendarEventCommandGate.shared.enter()
        defer { CalendarEventCommandGate.shared.leave() }
        let route = try history()
        let id = UUID()
        let made = try await reporting { try $0.insert(id, draft: draft) }
        record("Create Event", route: route,
               undo: { try $0.remove(id, expecting: made.draft) },
               redo: { _ = try $0.insert(id, draft: made.draft) })
        return made
    }

    func edit(_ id: UUID, draft: CalendarEventDraft) async throws -> CalendarOwnedEvent {
        await CalendarEventCommandGate.shared.enter()
        defer { CalendarEventCommandGate.shared.leave() }
        let route = try history()
        let (before, edited) = try await reporting { core in
            let before = try core.current(id)
            return (before.draft, try core.update(id, draft: draft, expecting: before.draft))
        }
        record("Edit Event", route: route,
               undo: { _ = try $0.update(id, draft: before, expecting: edited.draft) },
               redo: { _ = try $0.update(id, draft: edited.draft, expecting: before) })
        return edited
    }

    func delete(_ id: UUID) async throws {
        await CalendarEventCommandGate.shared.enter()
        defer { CalendarEventCommandGate.shared.leave() }
        let route = try history()
        let before = try await reporting { core in
            let before = try core.current(id)
            try core.remove(id, expecting: before.draft)
            return before.draft
        }
        record("Delete Event", route: route,
               undo: { _ = try $0.insert(id, draft: before) },
               redo: { try $0.remove(id, expecting: before) })
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
        let (result, notify) = await worker.perform(work)
        if notify { center.post(name: .EKEventStoreChanged, object: self) }
        switch result {
        case let .success(value): lastError = nil; return value
        case let .failure(error): lastError = error; throw error
        }
    }

    private func record(_ name: String, route: UndoRoute,
                        undo: @escaping @Sendable (CalendarEventTransactions) throws -> Void,
                        redo: @escaping @Sendable (CalendarEventTransactions) throws -> Void) {
        var step = UndoStep(name: name, undoOutcome: { .failed }, redoOutcome: { .failed })
        step.replay = { [self] isRedo, commit in
            await CalendarEventCommandGate.shared.enter()
            defer { CalendarEventCommandGate.shared.leave() }
            do {
                try await reporting(isRedo ? redo : undo)
                try commit()
                return .applied
            } catch let error as CalendarEventWriteError {
                switch error {
                case .notOwned, .eventMissing, .eventChanged, .repeatingEvent: return .obsolete
                default: return .failed
                }
            } catch { return .failed }
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

    func create(_ draft: CalendarEventDraft) throws -> CalendarOwnedEvent {
        try reporting {
            guard let undoRoute else { throw CalendarEventWriteError.undoUnavailable }
            let id = UUID()
            let made = try core.insert(id, draft: draft)
            undoRoute.record(UndoStep(name: "Create Event",
                undoOutcome: { [self] in replay { try core.remove(id, expecting: made.draft) } },
                redoOutcome: { [self] in replay { _ = try core.insert(id, draft: made.draft) } }), in: .calendar)
            return made
        }
    }

    func edit(_ id: UUID, draft: CalendarEventDraft) throws -> CalendarOwnedEvent {
        try reporting {
            guard let undoRoute else { throw CalendarEventWriteError.undoUnavailable }
            let previous = try core.current(id)
            let edited = try core.update(id, draft: draft, expecting: previous.draft)
            undoRoute.record(UndoStep(name: "Edit Event",
                undoOutcome: { [self] in replay { _ = try core.update(id, draft: previous.draft, expecting: edited.draft) } },
                redoOutcome: { [self] in replay { _ = try core.update(id, draft: edited.draft, expecting: previous.draft) } }), in: .calendar)
            return edited
        }
    }

    func delete(_ id: UUID) throws {
        try reporting {
            guard let undoRoute else { throw CalendarEventWriteError.undoUnavailable }
            let previous = try core.current(id)
            try core.remove(id, expecting: previous.draft)
            undoRoute.record(UndoStep(name: "Delete Event",
                undoOutcome: { [self] in replay { _ = try core.insert(id, draft: previous.draft) } },
                redoOutcome: { [self] in replay { try core.remove(id, expecting: previous.draft) } }), in: .calendar)
        }
    }

    func openInCalendar(_ occurrenceID: String) throws {
        try reporting {
            if let url = try core.openingURL(occurrenceID), !NSWorkspace.shared.open(url) {
                throw CalendarEventWriteError.openFailed
            }
        }
    }

    private func reporting<T>(_ work: () throws -> T) throws -> T {
        defer { postChanges() }
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

    private func postChanges() {
        if core.takeNotification() { center.post(name: .EKEventStoreChanged, object: self) }
    }

    private func replay(_ work: () throws -> Void) -> UndoOutcome {
        do { try reporting(work); return .applied }
        catch let error as CalendarEventWriteError {
            switch error {
            case .notOwned, .eventMissing, .eventChanged, .repeatingEvent: return .obsolete
            default: return .failed
            }
        } catch { return .failed }
    }
}

/// A complete ownership transaction is synchronous and confined to one owner.
/// Live instances run ONLY on CalendarEventWriteWorker.queue; injected unit
/// fixtures may run synchronously on the main actor through the facade above.
final class CalendarEventTransactions {
    private let store: CalendarEventWriteStore
    private let record: CalendarOwnershipRecord
    private var notificationNeeded = false
    var isFakeBacked: Bool { store is FakeCalendarEventWriteStore }

    init(store: CalendarEventWriteStore, record: CalendarOwnershipRecord) {
        self.store = store
        self.record = record
    }

    func takeNotification() -> Bool {
        defer { notificationNeeded = false }
        return notificationNeeded
    }

    func writableCalendars() throws -> [CalendarWriteCalendar] {
        try requireAccess()
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

    private func begin() throws {
        try requireAccess()
        try record.reload(using: store)
    }

    private func requireWritable(_ calendarID: String) throws {
        guard let calendar = store.calendars().first(where: { $0.id == calendarID }) else {
            throw CalendarEventWriteError.calendarMissing
        }
        guard calendar.isWritable else { throw CalendarEventWriteError.calendarReadOnly }
    }

    private func validate(_ draft: CalendarEventDraft) throws {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              draft.start.timeIntervalSinceReferenceDate.isFinite,
              draft.end.timeIntervalSinceReferenceDate.isFinite,
              draft.end > draft.start, let zone = TimeZone(identifier: draft.timeZoneID) else {
            throw CalendarEventWriteError.invalidDraft
        }
        if draft.isAllDay {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            guard calendar.startOfDay(for: draft.start) == draft.start,
                  calendar.startOfDay(for: draft.end) == draft.end else { throw CalendarEventWriteError.invalidDraft }
        }
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
        try begin()
        guard record.entries[id] == nil else { throw CalendarEventWriteError.eventChanged }
        let draft = draft.roundedToMinutes
        try validate(draft)
        try transaction(id, before: nil) { try store.stageCreate(draft) }
        guard let saved = record.entries[id] else { throw CalendarEventWriteError.eventMissing }
        return owned(id, saved)
    }

    func update(_ id: UUID, draft: CalendarEventDraft, expecting: CalendarEventDraft) throws -> CalendarOwnedEvent {
        try begin()
        let previous = try editable(id)
        guard previous.draft.hasSameOwnedValues(as: expecting) else { throw CalendarEventWriteError.eventChanged }
        // Only newly created events use minute rounding. An edit may retain
        // existing seconds or fractions, including during Undo and Redo.
        try validate(draft)
        try transaction(id, before: previous) { try store.stageEdit(previous, draft: draft) }
        guard let saved = record.entries[id] else { throw CalendarEventWriteError.eventMissing }
        return owned(id, saved)
    }

    func remove(_ id: UUID, expecting: CalendarEventDraft) throws {
        try begin()
        let previous = try editable(id)
        guard previous.draft.hasSameOwnedValues(as: expecting) else { throw CalendarEventWriteError.eventChanged }
        try transaction(id, before: previous) {
            try store.stageDelete(previous)
            return nil
        }
    }

    private func transaction(_ id: UUID, before: CalendarWriteSnapshot?,
                             stage: () throws -> CalendarWriteSnapshot?) throws {
        var attemptedCommit = false
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
        } catch {
            store.rollback()
            // A thrown commit may already have landed. Use the same committed
            // state reconciliation as relaunch, retaining any verified creation.
            let resolution = record.resolve(using: store)
            if resolution.changed && !store.postsChangeNotifications { notificationNeeded = true }
            // A verified landed operation must register/advance Undo normally.
            // Pre-commit failures and ambiguous outcomes retain the typed error.
            if attemptedCommit && resolution.landed { return }
            throw error
        }
        record.resolve(using: store)
        if !store.postsChangeNotifications { notificationNeeded = true }
    }

    private func owned(_ id: UUID, _ snapshot: CalendarWriteSnapshot) -> CalendarOwnedEvent {
        CalendarOwnedEvent(id: id, occurrenceID: snapshot.occurrenceID, draft: snapshot.draft)
    }

}
