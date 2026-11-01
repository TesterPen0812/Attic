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
    @Published private(set) var busy = false

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
            guard let minutes = Self.minutes(startText), length > 0 else { throw CalendarEventWriteError.invalidDraft }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: draft.timeZoneID) ?? .current
            var parts = calendar.dateComponents([.year, .month, .day], from: draft.start)
            parts.hour = minutes / 60
            parts.minute = minutes % 60
            parts.second = 0
            guard let start = calendar.date(from: parts),
                  calendar.component(.hour, from: start) == minutes / 60,
                  calendar.component(.minute, from: start) == minutes % 60 else { throw CalendarEventWriteError.invalidDraft }
            draft.start = start
            draft.end = start.addingTimeInterval(Double(length) * 60)
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
                let saved = try await writer.edit(owned.id, draft: draft)
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
            try await writer.delete(owned.id)
            clear()
            didWrite(String(localized: "Event deleted"))
        } catch {
            failure = String(localized: "Couldn’t delete event. Your changes are kept. Try again.")
        }
    }

    private func clear() {
        rowID = nil
        rowDay = nil
        owned = nil
        expandedChoice = nil
        failure = nil
    }

    func openInCalendar(_ event: CalendarEvent, on day: DueDay? = nil) async {
        do {
            if writer == nil { writer = try makeWriter?() }
            guard let writer else { throw CalendarEventWriteError.openFailed }
            try await writer.openInCalendar(event.id)
        } catch {
            if rowID == nil {
                rowID = event.id
                rowDay = day ?? DueDay(date: event.start, calendar: CalendarMonthMath.calendar())
            }
            failure = String(localized: "Couldn’t open event in Calendar. Try again.")
        }
    }
}
