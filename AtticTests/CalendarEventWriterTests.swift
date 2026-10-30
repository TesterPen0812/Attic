import EventKit
import XCTest
@testable import Attic

/// The real read-source mapping/notifications over fake data, with no EventKit IO.
private final class WriterReadStore: CalendarEventStoring {
    let backend: FakeCalendarEventWriteStore
    init(_ backend: FakeCalendarEventWriteStore) { self.backend = backend }
    func authorizationStatus() -> EKAuthorizationStatus { .fullAccess }
    func requestFullAccess() async throws -> Bool { true }
    func occurrences(from start: Date, to end: Date) -> [CalendarStoreOccurrence] {
        MainActor.assumeIsolated {
            backend.events.values.map { event in
                CalendarStoreOccurrence(eventIdentifier: event.eventIdentifier, itemIdentifier: event.itemIdentifier,
                    title: event.draft.title, start: event.draft.start, end: event.draft.end,
                    isAllDay: event.draft.isAllDay, location: nil, calendarTitle: "Home", calendarColour: nil,
                    timeZone: TimeZone(identifier: event.draft.timeZoneID))
            }
        }
    }
}

@MainActor
final class CalendarEventWriterTests: XCTestCase {
    private let center = NotificationCenter()
    private let undo = UndoRoute()
    private let store = FakeCalendarEventWriteStore()

    private func calendar(_ id: String = "home", source: String = "local", writable: Bool = true) -> CalendarWriteCalendar {
        CalendarWriteCalendar(id: id, title: "Home", colour: .init(red: 0.2, green: 0.5, blue: 0.9),
                              sourceID: source, sourceTitle: source, isWritable: writable)
    }
    private func draft(_ title: String = "Lunch", calendarID: String = "home") -> CalendarEventDraft {
        CalendarEventDraft(title: title, start: Date(timeIntervalSince1970: 1_793_361_600),
                           length: 3_600, calendarID: calendarID, timeZoneID: "Europe/London")
    }
    private func writer(record: CalendarOwnershipRecord? = nil) throws -> EventKitCalendarEventWriter {
        store.availableCalendars = [calendar(), calendar("work", source: "Work"), calendar("ro", writable: false)]
        return EventKitCalendarEventWriter(store: store, record: try record ?? CalendarOwnershipRecord(),
                                           undoRoute: undo, notificationCenter: center)
    }
    private func assertError<T>(_ expected: CalendarEventWriteError, _ body: () throws -> T,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? CalendarEventWriteError, expected, file: file, line: line)
        }
    }

    func testWritableCalendarsKeepSourceIdentityAndColour() throws {
        let writer = try writer()
        XCTAssertEqual(try writer.writableCalendars(), [calendar(), calendar("work", source: "Work")])
    }

    func testCreateUndoRedoTracksNewEventIdentifierAndRefreshes() throws {
        let writer = try writer()
        var refreshes = 0
        let token = center.addObserver(forName: .EKEventStoreChanged, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { refreshes += 1 }
        }
        defer { center.removeObserver(token) }
        let made = try writer.create(draft())
        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(try writer.ownedEvent(matching: made.occurrenceID), made)
        XCTAssertTrue(undo.undo(in: .calendar))
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(undo.redo(in: .calendar))
        let restored = try XCTUnwrap(store.events.values.first)
        XCTAssertNotEqual(restored.occurrenceID, made.occurrenceID)
        XCTAssertEqual(try writer.ownedEvent(matching: restored.occurrenceID)?.id, made.id)
        XCTAssertEqual(refreshes, 3)
    }

    func testEditUndoRedoRestoresValuesAndCalendar() throws {
        let writer = try writer()
        let made = try writer.create(draft())
        let changed = try writer.edit(made.id, draft: draft("Dinner", calendarID: "work"))
        XCTAssertEqual(changed.draft.title, "Dinner")
        XCTAssertTrue(undo.undo(in: .calendar))
        XCTAssertEqual(store.events.values.first?.draft, made.draft)
        XCTAssertTrue(undo.redo(in: .calendar))
        XCTAssertEqual(store.events.values.first?.draft, changed.draft)
    }

    func testDeleteUndoRedoAndEarlierStepsUseRestoredIdentity() throws {
        let writer = try writer()
        let made = try writer.create(draft())
        _ = try writer.edit(made.id, draft: draft("Dinner"))
        try writer.delete(made.id)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(undo.undo(in: .calendar))
        let restored = try XCTUnwrap(store.events.values.first)
        XCTAssertEqual(try writer.ownedEvent(matching: restored.occurrenceID)?.id, made.id)
        XCTAssertTrue(undo.undo(in: .calendar), "edit Undo follows the recreated EventKit ID")
        XCTAssertEqual(store.events.values.first?.draft.title, "Lunch")
        XCTAssertTrue(undo.undo(in: .calendar))
        XCTAssertTrue(store.events.isEmpty)
        for _ in 0..<3 { XCTAssertTrue(undo.redo(in: .calendar)) }
        XCTAssertTrue(store.events.isEmpty)
    }

    func testForeignAndRepeatingEventsAreNeverAdoptedButCanOpen() throws {
        let writer = try writer()
        for repeating in [false, true] {
            let event = CalendarWriteSnapshot(eventIdentifier: UUID().uuidString, itemIdentifier: "foreign",
                marker: "attic-calendar-event://\(UUID())", draft: draft(), isRepeating: repeating)
            store.events[event.eventIdentifier] = event
            XCTAssertNil(try writer.ownedEvent(matching: event.occurrenceID))
            assertError(.notOwned) { try writer.edit(UUID(), draft: draft()) }
            assertError(.notOwned) { try writer.delete(UUID()) }
            try writer.openInCalendar(event.occurrenceID)
        }
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.opened.count, 2)
        XCTAssertEqual(store.commits, 0)
    }

    func testOwnedEventBecomingRepeatingReadOnlyChangedOrMissingRefusesBothMutations() throws {
        for reason in [CalendarEventWriteError.repeatingEvent, .calendarReadOnly, .eventChanged, .eventMissing] {
            let writer = try writer()
            let made = try writer.create(draft())
            let key = try XCTUnwrap(store.events.values.first { $0.occurrenceID == made.occurrenceID }?.eventIdentifier)
            switch reason {
            case .repeatingEvent: store.events[key]?.isRepeating = true
            case .calendarReadOnly: store.availableCalendars[0].isWritable = false
            case .eventChanged: store.events[key]?.draft.title = "Changed in Calendar"
            default: store.events[key] = nil
            }
            let before = store.events
            XCTAssertNil(try writer.ownedEvent(matching: made.occurrenceID))
            assertError(reason) { try writer.edit(made.id, draft: draft("New")) }
            assertError(reason) { try writer.delete(made.id) }
            XCTAssertEqual(store.events, before)
        }
    }

    func testDurableRecordSurvivesNewInstanceAndRejectsClonedMarker() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attic-calendar-writer-\(UUID()).json")
        let writer = try writer(record: CalendarOwnershipRecord(fileURL: url))
        let made = try writer.create(draft())
        let relaunched = try self.writer(record: CalendarOwnershipRecord(fileURL: url))
        XCTAssertEqual(try relaunched.ownedEvent(matching: made.occurrenceID), made)
        var clone = try XCTUnwrap(store.events.values.first)
        clone.eventIdentifier = "clone"
        clone.itemIdentifier = "other-item"
        store.events[clone.eventIdentifier] = clone
        XCTAssertNil(try relaunched.ownedEvent(matching: clone.occurrenceID))
        _ = try relaunched.edit(made.id, draft: draft("After relaunch"))
        XCTAssertEqual(store.events["clone"], clone)
    }

    func testAccessDeniedAndReadOnlyLeaveNoEventsOrUndo() throws {
        let writer = try writer()
        store.accessState = .denied
        assertError(.accessDenied) { try writer.writableCalendars() }
        assertError(.accessDenied) { try writer.create(draft()) }
        store.accessState = .granted
        assertError(.calendarReadOnly) { try writer.create(draft(calendarID: "ro")) }
        assertError(.calendarMissing) { try writer.create(draft(calendarID: "missing")) }
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertFalse(undo.canUndo(in: .calendar))
    }

    func testStageAndCommitFailureLeaveStateRecordUndoAndRefreshUnchanged() throws {
        let writer = try writer()
        let made = try writer.create(draft())
        var refreshes = 0
        let token = center.addObserver(forName: .EKEventStoreChanged, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { refreshes += 1 }
        }
        defer { center.removeObserver(token) }
        let before = store.events
        let revision = undo.revision
        for staging in [true, false] {
            let error = CalendarEventWriteError.saveFailed(staging ? "stage" : "commit")
            store.stageError = staging ? error : nil
            store.commitError = staging ? nil : error
            assertError(error) { try writer.create(draft("Fail")) }
            assertError(error) { try writer.edit(made.id, draft: draft("Fail")) }
            assertError(error) { try writer.delete(made.id) }
            XCTAssertEqual(store.events, before)
            XCTAssertEqual(try writer.ownedEvent(matching: made.occurrenceID), made)
            XCTAssertEqual(undo.revision, revision)
            XCTAssertEqual(refreshes, 0)
        }
    }

    func testFailedUndoStaysRetryableAndExposesTypedError() throws {
        let writer = try writer()
        let made = try writer.create(draft())
        store.commitError = .saveFailed("disk")
        XCTAssertEqual(undo.undoStep(in: .calendar), .failed)
        XCTAssertEqual(writer.lastError, .saveFailed("disk"))
        XCTAssertEqual(try writer.ownedEvent(matching: made.occurrenceID), made)
        store.commitError = nil
        XCTAssertTrue(undo.undo(in: .calendar))
        XCTAssertNil(writer.lastError)
    }

    func testTimedLengthAndAllDayDSTBoundsAndInvalidDrafts() throws {
        let writer = try writer()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 25))!
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        XCTAssertEqual(end.timeIntervalSince(start), 90_000)
        let allDay = CalendarEventDraft(title: "Holiday", start: start, end: end, isAllDay: true,
                                        calendarID: "home", timeZoneID: "Europe/London")
        XCTAssertEqual(try writer.create(allDay).draft, allDay)
        var invalid = allDay
        invalid.end = start.addingTimeInterval(86_400)
        assertError(.invalidDraft) { try writer.create(invalid) }
        invalid = draft(); invalid.end = invalid.start
        assertError(.invalidDraft) { try writer.create(invalid) }
        invalid = draft("")
        assertError(.invalidDraft) { try writer.create(invalid) }
        invalid = draft(); invalid.timeZoneID = "unknown"
        assertError(.invalidDraft) { try writer.create(invalid) }
        XCTAssertEqual(store.events.count, 1)
    }

    func testOwnedEventMovedToReadOnlyCalendarAndRevokedAccessRefuseWrites() throws {
        let writer = try writer()
        let made = try writer.create(draft())
        let key = try XCTUnwrap(store.events.keys.first)
        store.accessState = .denied
        assertError(.accessDenied) { try writer.edit(made.id, draft: draft()) }
        assertError(.accessDenied) { try writer.delete(made.id) }
        store.accessState = .granted
        store.events[key]?.draft.calendarID = "ro"
        assertError(.calendarReadOnly) { try writer.edit(made.id, draft: draft()) }
        assertError(.calendarReadOnly) { try writer.delete(made.id) }
        XCTAssertNil(try writer.ownedEvent(matching: made.occurrenceID))
    }

    func testRecordWriteFailureRollsBackStagedCreateEditAndDelete() throws {
        var fail = false
        let record = try CalendarOwnershipRecord(persist: { _ in
            if fail { throw CalendarEventWriteError.recordFailed("disk") }
        })
        let writer = try writer(record: record)
        let made = try writer.create(draft())
        let before = store.events
        let revision = undo.revision
        fail = true
        assertError(.recordFailed("disk")) { try writer.create(draft("Fail")) }
        assertError(.recordFailed("disk")) { try writer.edit(made.id, draft: draft("Fail")) }
        assertError(.recordFailed("disk")) { try writer.delete(made.id) }
        XCTAssertEqual(store.events, before)
        XCTAssertEqual(undo.revision, revision)
        XCTAssertEqual(try writer.ownedEvent(matching: made.occurrenceID), made)
    }

    func testUnfinishedJournalRecoversCreateEditAndDeleteAfterRelaunch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attic-calendar-journal-\(UUID()).json")
        var writes = 0
        let record = try CalendarOwnershipRecord(fileURL: url, persist: { data in
            writes += 1
            // Each second write is journal compaction after the committed
            // transaction. Simulate losing it; the prepared journal is durable.
            if writes.isMultiple(of: 2) { throw CalendarEventWriteError.recordFailed("compaction") }
            try data.write(to: url, options: .atomic)
        })
        let writer = try writer(record: record)
        let made = try writer.create(draft())
        let reader = try self.writer(record: CalendarOwnershipRecord(fileURL: url))
        XCTAssertEqual(try reader.ownedEvent(matching: made.occurrenceID), made)
        // Continue from the first record only after it reloads the compacted
        // disk state: separate instances must not lose one another's entries.
        let edited = try writer.edit(made.id, draft: draft("Dinner"))
        let afterEdit = try self.writer(record: CalendarOwnershipRecord(fileURL: url))
        XCTAssertEqual(try afterEdit.ownedEvent(matching: edited.occurrenceID)?.draft.title, "Dinner")
        try writer.delete(made.id)
        let afterDelete = try self.writer(record: CalendarOwnershipRecord(fileURL: url))
        XCTAssertNil(try afterDelete.ownedEvent(matching: edited.occurrenceID))
        XCTAssertTrue(store.events.isEmpty)
    }

    func testStaleUndoNeverOverwritesExternalChangesAndFailedDeleteUndoRetries() throws {
        let writer = try writer()
        let made = try writer.create(draft())
        _ = try writer.edit(made.id, draft: draft("Dinner"))
        let key = try XCTUnwrap(store.events.keys.first)
        store.events[key]?.draft.title = "Changed externally"
        XCTAssertEqual(undo.undoStep(in: .calendar), .obsolete)
        XCTAssertEqual(store.events[key]?.draft.title, "Changed externally")
        let second = try writer.create(draft("Other"))
        try writer.delete(second.id)
        store.commitError = .saveFailed("disk")
        XCTAssertEqual(undo.undoStep(in: .calendar), .failed)
        XCTAssertEqual(store.events.count, 1)
        store.commitError = nil
        XCTAssertTrue(undo.undo(in: .calendar))
        XCTAssertEqual(store.events.count, 2)
    }

    func testWritesAndUndoInvalidateCalendarPageReadAndSearchCaches() throws {
        let writer = try writer()
        let source = EventKitCalendarEventSource(store: WriterReadStore(store), notificationCenter: center)
        let taskStore = try makeTestStore()
        let model = CalendarPageModel(store: taskStore, source: source, now: { self.draft().start })
        model.setQuery("Lunch")
        model.commitSearch()
        XCTAssertTrue(model.snapshot.showsNoMatches)
        let made = try writer.create(draft())
        XCTAssertFalse(model.snapshot.showsNoMatches)
        _ = try writer.edit(made.id, draft: draft("Dinner"))
        XCTAssertTrue(model.snapshot.showsNoMatches)
        XCTAssertTrue(undo.undo(in: .calendar))
        XCTAssertFalse(model.snapshot.showsNoMatches)
        try writer.delete(made.id)
        XCTAssertTrue(model.snapshot.showsNoMatches)
        XCTAssertTrue(undo.undo(in: .calendar))
        XCTAssertFalse(model.snapshot.showsNoMatches)
    }

    func testSeparateRecordInstancesDoNotOverwriteEachOthersOwnership() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attic-calendar-multiple-\(UUID()).json")
        let first = try writer(record: CalendarOwnershipRecord(fileURL: url))
        let second = try writer(record: CalendarOwnershipRecord(fileURL: url))
        let a = try first.create(draft("A"))
        let b = try second.create(draft("B"))
        let relaunched = try writer(record: CalendarOwnershipRecord(fileURL: url))
        XCTAssertEqual(try relaunched.ownedEvent(matching: a.occurrenceID)?.id, a.id)
        XCTAssertEqual(try relaunched.ownedEvent(matching: b.occurrenceID)?.id, b.id)
    }

    func testCorruptOwnershipFileFailsClosed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attic-calendar-corrupt-\(UUID()).json")
        try Data("broken".utf8).write(to: url, options: .atomic)
        XCTAssertThrowsError(try CalendarOwnershipRecord(fileURL: url)) { error in
            guard case .recordFailed = error as? CalendarEventWriteError else {
                return XCTFail("expected a typed record error, got \(error)")
            }
        }
    }
}
