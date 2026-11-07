import EventKit
import XCTest
@testable import Attic

/// The real read-source mapping/notifications over fake data, with no EventKit IO.
private final class WriterReadStore: CalendarEventStoring {
    let backend: FakeCalendarEventWriteStore
    init(_ backend: FakeCalendarEventWriteStore) { self.backend = backend }
    func authorizationStatus() -> EKAuthorizationStatus { .fullAccess }
    func requestFullAccess(_ completion: @escaping @Sendable (Result<Bool, Error>) -> Void) { completion(.success(true)) }
    func occurrences(from start: Date, to end: Date) -> [CalendarStoreOccurrence] {
        backend.events.values.map { event in
                CalendarStoreOccurrence(eventIdentifier: event.eventIdentifier, itemIdentifier: event.itemIdentifier,
                    title: event.draft.title, start: event.draft.start, end: event.draft.end,
                    isAllDay: event.draft.isAllDay, location: nil, calendarTitle: "Home", calendarColour: nil,
                    timeZone: TimeZone(identifier: event.draft.timeZoneID))
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

    func testC03EditingAnOwnedEventDoesNotRoundItsSubmittedTimestamps() throws {
        let writer = try writer()
        let original = try writer.create(draft())
        var edited = original.draft
        edited.title = "Precise edit"
        edited.start.addTimeInterval(30.25)
        edited.end.addTimeInterval(30.25)
        let updated = try writer.edit(original.id, draft: edited)
        XCTAssertEqual(updated.draft.start, edited.start)
        XCTAssertEqual(updated.draft.end, edited.end)
        XCTAssertEqual(store.events.values.first?.draft, edited)
        XCTAssertEqual(undo.undo(in: .calendar), true)
        XCTAssertEqual(store.events.values.first?.draft, original.draft)
    }

    func testOwnershipJournalIOLeavesTheMainThread() async throws {
        let record = try CalendarOwnershipRecord(persist: { _ in
            XCTAssertFalse(Thread.isMainThread, "durable event proof must not block the UI")
        })
        store.availableCalendars = [calendar()]
        let backend = store
        let writer = BackgroundCalendarEventWriter(undoRoute: undo) {
            XCTAssertFalse(Thread.isMainThread, "store and ownership file initialization must leave main too")
            return CalendarEventTransactions(store: backend, record: record)
        }
        let made = try await writer.create(draft())
        XCTAssertEqual(made.draft.title, "Lunch")
    }

    func testBackgroundWritersSerializeTheSameJournalAndPreserveUndoRedo() async throws {
        let root = ownedTemporaryDirectory(prefix: "CalendarBackgroundJournal")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("ownership.json")
        let backend = store
        backend.availableCalendars = [calendar()]
        func background() -> BackgroundCalendarEventWriter {
            BackgroundCalendarEventWriter(undoRoute: undo, notificationCenter: center) {
                CalendarEventTransactions(store: backend, record: try CalendarOwnershipRecord(fileURL: url))
            }
        }
        let first = background(), second = background()
        async let a = first.create(draft("First"))
        async let b = second.create(draft("Second"))
        let made = try await (a, b)
        XCTAssertNotEqual(made.0.id, made.1.id)
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(try CalendarOwnershipRecord(fileURL: url).entries.count, 2)
        await XCTAssertEqualAsync(await undo.replay(in: .calendar, redo: false), .applied)
        await XCTAssertEqualAsync(await undo.replay(in: .calendar, redo: false), .applied)
        XCTAssertTrue(store.events.isEmpty)
        await XCTAssertEqualAsync(await undo.replay(in: .calendar, redo: true), .applied)
        await XCTAssertEqualAsync(await undo.replay(in: .calendar, redo: true), .applied)
        XCTAssertEqual(Set(store.events.values.map(\.draft.title)), ["First", "Second"])
    }

    func testBackgroundCommitRecoveryAndFailedOrObsoleteUndoKeepTheirOutcomes() async throws {
        store.availableCalendars = [calendar()]
        store.landsThenThrowsOnCommit = true
        let backend = store
        let writer = BackgroundCalendarEventWriter(undoRoute: undo, notificationCenter: center) {
            CalendarEventTransactions(store: backend, record: try CalendarOwnershipRecord())
        }
        _ = try await writer.create(draft())
        XCTAssertNil(writer.lastError, "a verified landed commit remains successful")
        XCTAssertEqual(undo.undoCount(in: .calendar), 1)
        store.landsThenThrowsOnCommit = false
        store.commitError = .saveFailed("retry")
        await XCTAssertEqualAsync(await undo.replay(in: .calendar, redo: false), .failed)
        XCTAssertEqual(writer.lastError, .saveFailed("retry"))
        XCTAssertEqual(undo.undoCount(in: .calendar), 1)
        store.commitError = nil
        let key = try XCTUnwrap(store.events.keys.first)
        store.events[key]?.draft.title = "Changed outside Attic"
        await XCTAssertEqualAsync(await undo.replay(in: .calendar, redo: false), .failed,
                                  "an unresolved commit cannot discard its durable proof")
        XCTAssertEqual(undo.undoCount(in: .calendar), 1)
        XCTAssertEqual(store.events[key]?.draft.title, "Changed outside Attic")
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
            let foreignID = UUID()
            let event = CalendarWriteSnapshot(eventIdentifier: foreignID.uuidString, itemIdentifier: "foreign-\(foreignID)",
                draft: draft(), isRepeating: repeating)
            store.events[event.eventIdentifier] = event
            XCTAssertNil(try writer.ownedEvent(matching: event.occurrenceID))
            assertError(.notOwned) { try writer.edit(foreignID, draft: draft()) }
            assertError(.notOwned) { try writer.delete(foreignID) }
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

    func testDurableRecordSurvivesNewInstanceAndRejectsCopiedValuesWithDifferentIDs() throws {
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
            if staging {
                assertError(error) { try writer.edit(made.id, draft: draft("Fail")) }
                assertError(error) { try writer.delete(made.id) }
            } else {
                XCTAssertThrowsError(try writer.edit(made.id, draft: draft("Fail")))
                XCTAssertThrowsError(try writer.delete(made.id))
            }
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
        XCTAssertFalse(undo.undo(in: .calendar), "a missing prior create stays held until its commit is proven")
        XCTAssertEqual(store.events.count, 1)
    }

    func testWritesAndUndoInvalidateCalendarPageReadAndSearchCaches() async throws {
        let writer = try writer()
        let source = EventKitCalendarEventSource(store: WriterReadStore(store), notificationCenter: center)
        let taskStore = try makeTestStore()
        let model = CalendarPageModel(store: taskStore, source: source, now: { self.draft().start })
        // Hidden pages defer refresh until presentation; this case verifies
        // the visible page's immediate cache invalidation after writes.
        model.setVisible(true)
        defer { model.setVisible(false) }
        model.setQuery("Lunch")
        model.commitSearch()
        await model.waitForEventReadsForTesting()
        XCTAssertTrue(model.snapshot.showsNoMatches)
        let made = try writer.create(draft())
        await model.waitForEventReadsForTesting()
        XCTAssertFalse(model.snapshot.showsNoMatches)
        _ = try writer.edit(made.id, draft: draft("Dinner"))
        await model.waitForEventReadsForTesting()
        XCTAssertTrue(model.snapshot.showsNoMatches)
        XCTAssertTrue(undo.undo(in: .calendar))
        await model.waitForEventReadsForTesting()
        XCTAssertFalse(model.snapshot.showsNoMatches)
        try writer.delete(made.id)
        await model.waitForEventReadsForTesting()
        XCTAssertTrue(model.snapshot.showsNoMatches)
        XCTAssertTrue(undo.undo(in: .calendar))
        await model.waitForEventReadsForTesting()
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

    func testEventChangingDuringRecordPreparationIsNotOverwrittenOrDeleted() throws {
        for deleting in [false, true] {
            var changeDuringPrepare: (() -> Void)?
            let record = try CalendarOwnershipRecord(persist: { _ in changeDuringPrepare?() })
            let writer = try writer(record: record)
            let made = try writer.create(draft())
            let key = try XCTUnwrap(store.events.values.first { $0.occurrenceID == made.occurrenceID }?.eventIdentifier)
            changeDuringPrepare = { self.store.events[key]?.isRepeating = true }
            assertError(.repeatingEvent) {
                if deleting { try writer.delete(made.id) }
                else { _ = try writer.edit(made.id, draft: draft("Fail")) }
            }
            XCTAssertEqual(store.events[key]?.isRepeating, true)
            XCTAssertEqual(store.events[key]?.draft.title, "Lunch")
        }
    }

    func testWritePreservesUnrelatedEventAddedDuringPreparation() throws {
        let foreign = CalendarWriteSnapshot(eventIdentifier: "external", itemIdentifier: "external-item",
                                            draft: draft("Someone else's event"))
        var injected = false
        let record = try CalendarOwnershipRecord(persist: { _ in
            if !injected {
                self.store.events[foreign.eventIdentifier] = foreign
                injected = true
            }
        })
        let writer = try writer(record: record)
        let made = try writer.create(draft())
        XCTAssertEqual(store.events[foreign.eventIdentifier], foreign)
        XCTAssertEqual(try writer.ownedEvent(matching: made.occurrenceID), made)
        XCTAssertNil(try writer.ownedEvent(matching: foreign.occurrenceID))
    }

    func testCommitTimeIdentifiersRecoverFromJournalAndFollowUndo() throws {
        store.assignsEventIdentifiersOnCommit = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attic-calendar-ids-\(UUID()).json")
        var writes = 0
        let record = try CalendarOwnershipRecord(fileURL: url, persist: { data in
            writes += 1
            if writes == 2 { throw CalendarEventWriteError.recordFailed("compaction") }
            try data.write(to: url, options: .atomic)
        })
        let writer = try writer(record: record)
        let made = try writer.create(draft())
        let committed = try XCTUnwrap(store.events.values.first)
        XCTAssertNotEqual(committed.eventIdentifier, committed.itemIdentifier)
        XCTAssertEqual(made.occurrenceID, committed.occurrenceID)
        let relaunched = try self.writer(record: CalendarOwnershipRecord(fileURL: url))
        XCTAssertEqual(try relaunched.ownedEvent(matching: committed.occurrenceID), made)
        _ = try writer.edit(made.id, draft: draft("Dinner", calendarID: "work"))
        XCTAssertTrue(undo.undo(in: .calendar))
        XCTAssertEqual(store.events.values.first?.draft, made.draft)
        try writer.delete(made.id)
        XCTAssertTrue(undo.undo(in: .calendar))
        let restored = try XCTUnwrap(store.events.values.first)
        XCTAssertEqual(try writer.ownedEvent(matching: restored.occurrenceID)?.id, made.id)
        XCTAssertEqual(store.events.count, 1)
    }

    func testNormalizingProviderCreateUndoRedoAndMinuteRounding() throws {
        store.normalizesOnCommit = true
        let writer = try writer()
        var input = draft()
        input.start.addTimeInterval(17.75)
        input.end.addTimeInterval(44.25)
        let made = try writer.create(input)
        XCTAssertEqual(store.lastStagedDraft?.start, draft().start)
        XCTAssertEqual(store.lastStagedDraft?.end, draft().end.addingTimeInterval(60))
        let live = try XCTUnwrap(store.events.values.first)
        XCTAssertEqual(made.occurrenceID, live.occurrenceID)
        XCTAssertNil(live.url)
        XCTAssertEqual(live.alarms, [-900])
        XCTAssertEqual(try writer.ownedEvent(matching: live.occurrenceID)?.id, made.id)
        XCTAssertTrue(undo.undo(in: .calendar))
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(undo.redo(in: .calendar))
        XCTAssertEqual(store.events.count, 1)
    }

    func testNormalizingProviderEditAndDeleteUndo() throws {
        store.normalizesOnCommit = true
        let writer = try writer()
        let made = try writer.create(draft())
        _ = try writer.edit(made.id, draft: draft("Dinner", calendarID: "work"))
        XCTAssertTrue(undo.undo(in: .calendar))
        XCTAssertEqual(store.events.values.first?.draft.title, "Lunch")
        try writer.delete(made.id)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(undo.undo(in: .calendar))
        let live = try XCTUnwrap(store.events.values.first)
        XCTAssertEqual(try writer.ownedEvent(matching: live.occurrenceID)?.id, made.id)
        XCTAssertTrue(undo.redo(in: .calendar))
        XCTAssertTrue(store.events.isEmpty)
    }

    func testEventIdentifierDriftFallsBackToItemIdentityButUserChangesStillRefuse() throws {
        let writer = try writer()
        let made = try writer.create(draft())
        var live = try XCTUnwrap(store.events.values.first)
        store.events[live.eventIdentifier] = nil
        live.eventIdentifier = "provider-new-id"
        live.alarms = [-600]
        live.availability = 2
        store.events[live.eventIdentifier] = live
        XCTAssertEqual(try writer.ownedEvent(matching: live.occurrenceID)?.id, made.id)
        _ = try writer.edit(made.id, draft: draft("Dinner"))
        store.events[live.eventIdentifier]?.draft.title = "Changed by the user"
        assertError(.eventChanged) { try writer.delete(made.id) }
    }

    func testCommitThatLandsThenThrowsIsConfirmedAndKeepsOwnershipAcrossRelaunch() throws {
        store.normalizesOnCommit = true
        store.landsThenThrowsOnCommit = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attic-calendar-partial-\(UUID()).json")
        let writer = try writer(record: CalendarOwnershipRecord(fileURL: url))
        let made = try writer.create(draft())
        XCTAssertTrue(undo.canUndo(in: .calendar), "confirmed writes keep their inverse")
        let live = try XCTUnwrap(store.events.values.first)
        let relaunched = try self.writer(record: CalendarOwnershipRecord(fileURL: url))
        let owned = try XCTUnwrap(relaunched.ownedEvent(matching: live.occurrenceID))
        XCTAssertEqual(owned.id, made.id)
        store.landsThenThrowsOnCommit = false
        try relaunched.delete(owned.id)
        XCTAssertTrue(store.events.isEmpty)
    }

    func testD01AmbiguousCommittedCreateKeepsDurableProofAcrossReaderMismatchAndRelaunch() throws {
        let root = ownedTemporaryDirectory(prefix: "CalendarAmbiguousCommit")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("ownership.json")
        func pendingOnDisk() throws -> Bool {
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            return state["pending"] is [String: Any]
        }
        store.withholdReadsAfterCommit = true
        let initial = try writer(record: CalendarOwnershipRecord(fileURL: url))
        XCTAssertThrowsError(try initial.create(draft("Held")))
        let committed = try XCTUnwrap(store.events.values.first)
        XCTAssertEqual(store.events.count, 1)
        XCTAssertTrue(try pendingOnDisk())

        let relaunched = try writer(record: CalendarOwnershipRecord(fileURL: url))
        XCTAssertNil(try relaunched.ownedEvent(matching: committed.occurrenceID))
        XCTAssertTrue(try pendingOnDisk())
        XCTAssertEqual(undo.undoCount(in: .calendar), 0)

        store.readsWithheld = false
        XCTAssertEqual(try relaunched.ownedEvent(matching: committed.occurrenceID)?.draft.title, "Held")
        XCTAssertFalse(try pendingOnDisk())
        XCTAssertEqual(undo.undoCount(in: .calendar), 1, "Undo publishes only after ownership is verified")
        XCTAssertTrue(undo.undo(in: .calendar))
        XCTAssertTrue(store.events.isEmpty)
    }

    func testD01AmbiguousCommittedEditKeepsPriorProofThenPublishesRecoveredUndo() throws {
        let root = ownedTemporaryDirectory(prefix: "CalendarAmbiguousEdit")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("ownership.json")
        let initial = try writer(record: CalendarOwnershipRecord(fileURL: url))
        let made = try initial.create(draft("Before"))
        store.withholdReadsAfterCommit = true
        XCTAssertThrowsError(try initial.edit(made.id, draft: draft("After")))
        let committed = try XCTUnwrap(store.events.values.first)
        XCTAssertEqual(committed.draft.title, "After")
        XCTAssertEqual(try CalendarOwnershipRecord(fileURL: url).entries[made.id]?.draft.title, "Before")
        let relaunched = try writer(record: CalendarOwnershipRecord(fileURL: url))
        XCTAssertNil(try relaunched.ownedEvent(matching: committed.occurrenceID))
        store.readsWithheld = false
        XCTAssertEqual(try relaunched.ownedEvent(matching: committed.occurrenceID)?.id, made.id)
        XCTAssertEqual(undo.undoCount(in: .calendar), 2)
        store.withholdReadsAfterCommit = false
        XCTAssertTrue(undo.undo(in: .calendar))
        XCTAssertEqual(store.events.values.first?.draft.title, "Before")
    }

    func testAllDayOwnershipSurvivesFloatingTimeZoneChange() throws {
        let writer = try writer()
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        var newYork = london
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let components = DateComponents(year: 2026, month: 10, day: 30)
        let start = london.date(from: components)!
        let input = CalendarEventDraft(title: "Day", start: start, end: london.date(byAdding: .day, value: 1, to: start)!,
                                       isAllDay: true, calendarID: "home", timeZoneID: london.timeZone.identifier)
        let made = try writer.create(input)
        let key = try XCTUnwrap(store.events.keys.first)
        let shifted = newYork.date(from: components)!
        store.events[key]?.draft.start = shifted
        store.events[key]?.draft.end = newYork.date(byAdding: .day, value: 1, to: shifted)!
        store.events[key]?.draft.timeZoneID = newYork.timeZone.identifier
        let occurrence = try XCTUnwrap(store.events[key]?.occurrenceID)
        XCTAssertEqual(try writer.ownedEvent(matching: occurrence)?.id, made.id)
        XCTAssertTrue(undo.undo(in: .calendar))
        XCTAssertTrue(store.events.isEmpty)
    }

    func testCreateDoesNotWriteAnyMarkerIntoEvent() throws {
        let writer = try writer()
        _ = try writer.create(draft())
        let live = try XCTUnwrap(store.events.values.first)
        let serialized = try JSONEncoder().encode(live)
        XCTAssertFalse(String(decoding: serialized, as: UTF8.self).contains("attic-calendar-event"))
        XCTAssertNil(live.url)
    }

    func testStoreNotificationIsNotDuplicatedByEngine() throws {
        store.postsChangeNotifications = true
        store.notificationCenter = center
        let writer = try writer()
        var changes = 0
        let token = center.addObserver(forName: .EKEventStoreChanged, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { changes += 1 }
        }
        defer { center.removeObserver(token) }
        let made = try writer.create(draft())
        XCTAssertEqual(changes, 1)
        _ = try writer.edit(made.id, draft: draft("Dinner"))
        XCTAssertEqual(changes, 2)
        try writer.delete(made.id)
        XCTAssertEqual(changes, 3)
        XCTAssertTrue(undo.undo(in: .calendar))
        XCTAssertEqual(changes, 4)
    }

    func testDeleteThatLandsThenThrowsStillRecordsUndo() throws {
        let writer = try writer()
        let made = try writer.create(draft())
        store.landsThenThrowsOnCommit = true
        XCTAssertNoThrow(try writer.delete(made.id))
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(undo.undo(in: .calendar))
        XCTAssertEqual(store.events.count, 1)
        XCTAssertTrue(undo.redo(in: .calendar))
        XCTAssertTrue(store.events.isEmpty)
    }

    func testUndoThatLandsThenThrowsAdvancesHistoryAndKeepsRedo() throws {
        let writer = try writer()
        _ = try writer.create(draft())
        store.landsThenThrowsOnCommit = true
        XCTAssertEqual(undo.undoStep(in: .calendar), .applied)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(undo.redoStep(in: .calendar), .applied)
        XCTAssertEqual(store.events.count, 1)
    }
}
