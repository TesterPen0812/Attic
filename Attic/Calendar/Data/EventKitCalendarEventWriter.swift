import EventKit
import Foundation

@MainActor
final class EventKitCalendarEventWriter: CalendarEventWriter {
    private(set) var lastError: CalendarEventWriteError?
    private let store: CalendarEventWriteStore
    private let record: CalendarOwnershipRecord
    // History retains the engine through its closures, so it survives a page
    // view going away. The engine must not retain that history in a cycle.
    private weak var undoRoute: UndoRoute?
    private let center: NotificationCenter

    init(store: CalendarEventWriteStore, record: CalendarOwnershipRecord, undoRoute: UndoRoute,
         notificationCenter: NotificationCenter = .default) {
        self.store = store
        self.record = record
        self.undoRoute = undoRoute
        self.center = notificationCenter
    }

    func writableCalendars() throws -> [CalendarWriteCalendar] {
        try reporting {
            try requireAccess()
            return store.calendars().filter(\.isWritable)
        }
    }

    func ownedEvent(matching occurrenceID: String) throws -> CalendarOwnedEvent? {
        try reporting {
            try begin()
            guard let (id, _) = record.entries.first(where: { $0.value.occurrenceID == occurrenceID }),
                  let current = try? editable(id) else { return nil }
            return owned(id, current)
        }
    }

    func create(_ draft: CalendarEventDraft) throws -> CalendarOwnedEvent {
        try reporting {
            guard let undoRoute else { throw CalendarEventWriteError.undoUnavailable }
            let id = UUID()
            let made = try insert(id, draft: draft)
            undoRoute.record(UndoStep(name: "Create Event",
                undoOutcome: { [self] in replay { try remove(id, expecting: draft) } },
                redoOutcome: { [self] in replay { _ = try insert(id, draft: draft) } }), in: .calendar)
            return made
        }
    }

    func edit(_ id: UUID, draft: CalendarEventDraft) throws -> CalendarOwnedEvent {
        try reporting {
            guard let undoRoute else { throw CalendarEventWriteError.undoUnavailable }
            try begin()
            let previous = try editable(id)
            let edited = try update(id, draft: draft, expecting: previous.draft)
            undoRoute.record(UndoStep(name: "Edit Event",
                undoOutcome: { [self] in replay { _ = try update(id, draft: previous.draft, expecting: draft) } },
                redoOutcome: { [self] in replay { _ = try update(id, draft: draft, expecting: previous.draft) } }), in: .calendar)
            return edited
        }
    }

    func delete(_ id: UUID) throws {
        try reporting {
            guard let undoRoute else { throw CalendarEventWriteError.undoUnavailable }
            try begin()
            let previous = try editable(id)
            try remove(id, expecting: previous.draft)
            undoRoute.record(UndoStep(name: "Delete Event",
                undoOutcome: { [self] in replay { _ = try insert(id, draft: previous.draft) } },
                redoOutcome: { [self] in replay { try remove(id, expecting: previous.draft) } }), in: .calendar)
        }
    }

    func openInCalendar(_ occurrenceID: String) throws {
        try reporting { try store.openInCalendar(occurrenceID) }
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
        guard let live = store.event(identifier: proof.eventIdentifier) else { throw CalendarEventWriteError.eventMissing }
        guard !live.isRepeating else { throw CalendarEventWriteError.repeatingEvent }
        try requireWritable(live.draft.calendarID)
        guard live == proof else { throw CalendarEventWriteError.eventChanged }
        return live
    }

    private func insert(_ id: UUID, draft: CalendarEventDraft) throws -> CalendarOwnedEvent {
        try begin()
        guard record.entries[id] == nil else { throw CalendarEventWriteError.eventChanged }
        try validate(draft)
        let marker = "attic-calendar-event://\(UUID().uuidString)"
        try transaction(id, before: nil) { try store.stageCreate(draft, marker: marker) }
        return owned(id, record.entries[id]!)
    }

    private func update(_ id: UUID, draft: CalendarEventDraft, expecting: CalendarEventDraft) throws -> CalendarOwnedEvent {
        try begin()
        let previous = try editable(id)
        guard previous.draft == expecting else { throw CalendarEventWriteError.eventChanged }
        try validate(draft)
        try transaction(id, before: previous) { try store.stageEdit(previous, draft: draft) }
        return owned(id, record.entries[id]!)
    }

    private func remove(_ id: UUID, expecting: CalendarEventDraft) throws {
        try begin()
        let previous = try editable(id)
        guard previous.draft == expecting else { throw CalendarEventWriteError.eventChanged }
        try transaction(id, before: previous) {
            try store.stageDelete(previous)
            return nil
        }
    }

    private func transaction(_ id: UUID, before: CalendarWriteSnapshot?,
                             stage: () throws -> CalendarWriteSnapshot?) throws {
        do {
            let after = try stage()
            try record.prepare(id: id, before: before, after: after)
            try requireAccess()
            if let after { try requireWritable(after.draft.calendarID) }
            try store.commit()
        } catch {
            store.rollback()
            record.finish(committed: false, using: store)
            throw error
        }
        record.finish(committed: true, using: store)
        center.post(name: .EKEventStoreChanged, object: self)
    }

    private func owned(_ id: UUID, _ snapshot: CalendarWriteSnapshot) -> CalendarOwnedEvent {
        CalendarOwnedEvent(id: id, occurrenceID: snapshot.occurrenceID, draft: snapshot.draft)
    }

    private func reporting<T>(_ work: () throws -> T) throws -> T {
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
