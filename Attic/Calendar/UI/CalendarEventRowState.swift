import Combine
import Foundation

/// One event page in the agenda. The writer alone determines ownership and
/// commits changes; the editable values remain here until a confirmed save.
@MainActor
final class CalendarEventRowState: ObservableObject {
    @Published private(set) var rowID: String?
    @Published private(set) var rowDay: DueDay?
    @Published private(set) var owned: CalendarOwnedEvent?
    @Published private(set) var calendars: [CalendarWriteCalendar] = []
    @Published var title = ""
    @Published var startText = ""
    @Published var length = 60
    @Published var calendarID = ""
    @Published var expandedChoice: Choice?
    @Published private(set) var failure: String?
    @Published private(set) var busy = false {
        didSet {
            if !busy {
                for id in Array(idleWaiters.keys) { finishIdleWaiter(id, settled: true) }
            }
        }
    }

    private var idleWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var idleTimeouts: [UUID: Task<Void, Never>] = [:]
    private var selectionGeneration: UInt64 = 0
    private var externalOpenGeneration: UInt64 = 0
    var terminationIdleTimeout: Duration = .seconds(2)

    /// A prior close, delete or toggle can already own an asynchronous writer.
    /// Quit waits for it to settle, bounded so a hung writer cannot hang quit.
    func waitForInFlightWorkBeforeQuit() async -> Bool {
        guard busy else { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                guard busy, !Task.isCancelled else {
                    continuation.resume(returning: !Task.isCancelled)
                    return
                }
                idleWaiters[id] = continuation
                let timeout = terminationIdleTimeout
                idleTimeouts[id] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finishIdleWaiter(id, settled: false)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishIdleWaiter(id, settled: false) }
        }
    }

    private func finishIdleWaiter(_ id: UUID, settled: Bool) {
        guard let continuation = idleWaiters.removeValue(forKey: id) else { return }
        idleTimeouts.removeValue(forKey: id)?.cancel()
        continuation.resume(returning: settled)
    }

    enum Choice { case calendar, length }
    var canEdit: Bool { owned != nil }
    var canDelete: Bool { owned != nil }
    var didWrite: (String) -> Void = { _ in }
    private var writer: CalendarEventWriter?
    private let makeWriter: (() throws -> CalendarEventWriter)?

    init(makeWriter: (() throws -> CalendarEventWriter)? = nil) {
        self.makeWriter = makeWriter
    }

    func toggle(_ event: CalendarEvent, on day: DueDay? = nil) async {
        guard !busy else { return }
        let day = day ?? DueDay(date: event.start, calendar: CalendarMonthMath.calendar())
        if rowID == event.id, rowDay == day { _ = await close(); return }
        guard await close() else { return }
        selectionGeneration &+= 1
        rowID = event.id
        rowDay = day
        title = event.title
        failure = nil
        busy = true
        defer { busy = false }
        do {
            if writer == nil { writer = try makeWriter?() }
            owned = try await writer?.ownedEvent(matching: event.id)
            if let draft = owned?.draft {
                title = draft.title
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: draft.timeZoneID) ?? .current
                startText = ComposerCard.clock(calendar.component(.hour, from: draft.start) * 60
                    + calendar.component(.minute, from: draft.start))
                length = Int(draft.end.timeIntervalSince(draft.start) / 60)
                calendarID = draft.calendarID
                calendars = try await writer?.writableCalendars() ?? []
            }
        } catch {
            failure = String(localized: "Couldn’t load event. Try again.")
        }
    }

    static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    private struct Fields: Equatable {
        var title: String
        var start: String
        var length: Int
        var calendar: String
    }
    private var fields: Fields { Fields(title: title, start: startText, length: length, calendar: calendarID) }

    private func editedDraft(_ original: CalendarEventDraft) throws -> CalendarEventDraft {
        var draft = original
        draft.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.calendarID = calendarID
        guard !draft.title.isEmpty else { throw CalendarEventWriteError.invalidDraft }
        if !draft.isAllDay {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: draft.timeZoneID) ?? .current
            let oldMinutes = calendar.component(.hour, from: original.start) * 60
                + calendar.component(.minute, from: original.start)
            let oldDuration = original.end.timeIntervalSince(original.start)
            let oldLength = Int(oldDuration / 60)
            let clockChanged = startText != ComposerCard.clock(oldMinutes)
            let lengthChanged = length != oldLength

            // A title or calendar-only edit must never reconstruct timestamps.
            if clockChanged {
                guard let minutes = Self.minutes(startText) else { throw CalendarEventWriteError.invalidDraft }
                let second = calendar.component(.second, from: original.start)
                let match = DateComponents(hour: minutes / 60, minute: minutes % 60, second: second)
                let beforeDay = calendar.startOfDay(for: original.start).addingTimeInterval(-1)
                guard let first = calendar.nextDate(after: beforeDay, matching: match,
                    matchingPolicy: .strict, repeatedTimePolicy: .first, direction: .forward),
                    calendar.isDate(first, inSameDayAs: original.start) else {
                    // A clock time in the spring DST gap has no valid instant.
                    throw CalendarEventWriteError.invalidDraft
                }
                let last = calendar.nextDate(after: beforeDay, matching: match,
                    matchingPolicy: .strict, repeatedTimePolicy: .last, direction: .forward)
                // During the autumn fold, prefer the existing event's UTC
                // offset. If neither fold has that offset, use the first.
                let previousOffset = calendar.timeZone.secondsFromGMT(for: original.start)
                let chosen = last.flatMap { candidate -> Date? in
                    guard calendar.isDate(candidate, inSameDayAs: original.start),
                          calendar.timeZone.secondsFromGMT(for: candidate) == previousOffset else { return nil }
                    return candidate
                } ?? first
                let reference = original.start.timeIntervalSinceReferenceDate
                draft.start = chosen.addingTimeInterval(reference - floor(reference))
            }
            if lengthChanged {
                guard length > 0 else { throw CalendarEventWriteError.invalidDraft }
            }
            if clockChanged || lengthChanged {
                // The picker edits whole minutes; retain the original seconds
                // and fraction of a minute in the duration when it changes.
                let remainder = oldDuration - Double(oldLength) * 60
                let newDuration = lengthChanged ? Double(length) * 60 + remainder : oldDuration
                draft.end = draft.start.addingTimeInterval(newDuration)
            }
        }
        return draft
    }

    @discardableResult
    func close() async -> Bool {
        guard !busy else { return false }
        guard rowID != nil else { return true }
        guard let owned, let writer else { clear(); return true }
        let submitted = fields
        do {
            let draft = try editedDraft(owned.draft)
            if draft != owned.draft {
                busy = true
                defer { busy = false }
                let saved = try await writer.edit(owned.id, draft: draft, expecting: owned.draft)
                self.owned = saved
                didWrite(String(localized: "Event changed"))
                // A held save cannot close or overwrite newer typing.
                guard fields == submitted else { return false }
            }
            clear()
            return true
        } catch {
            // The writer rolls back. Keep *current* text, even if it changed
            // while the write was held; the failure always remains visible.
            failure = String(localized: "Couldn’t save event. Your changes are kept. Try again.")
            return false
        }
    }

    func delete() async {
        guard !busy, let owned, let writer else { return }
        busy = true
        defer { busy = false }
        do {
            try await writer.delete(owned.id, expecting: owned.draft)
            clear()
            didWrite(String(localized: "Event deleted"))
        } catch {
            failure = String(localized: "Couldn’t delete event. Your changes are kept. Try again.")
        }
    }

    /// An explicit recovery route when the source can no longer accept a save.
    /// Never abandon a draft while its durable write is still in flight.
    func discardChanges() {
        guard !busy else { return }
        clear()
    }

    private func clear() {
        selectionGeneration &+= 1
        rowID = nil
        rowDay = nil
        owned = nil
        expandedChoice = nil
        failure = nil
    }

    func openInCalendar(_ event: CalendarEvent, on day: DueDay? = nil) async {
        externalOpenGeneration &+= 1
        let request = externalOpenGeneration
        let selection = selectionGeneration
        let initialRow = rowID
        do {
            if writer == nil { writer = try makeWriter?() }
            guard let writer else { throw CalendarEventWriteError.openFailed }
            try await writer.openInCalendar(event.id)
        } catch {
            guard externalOpenGeneration == request, selectionGeneration == selection,
                  rowID == initialRow, initialRow == nil || initialRow == event.id else { return }
            if rowID == nil {
                selectionGeneration &+= 1
                rowID = event.id
                rowDay = day ?? DueDay(date: event.start, calendar: CalendarMonthMath.calendar())
            }
            failure = String(localized: "Couldn’t open event in Calendar. Try again.")
        }
    }
}
