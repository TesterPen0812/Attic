import Foundation
import XCTest
@testable import AtticMobile

final class MobileCalendarOwnershipTests: XCTestCase {
    private func fixture() throws -> (FakeCalendarEventWriteStore, CalendarEventTransactions, CalendarEventDraft) {
        let backend = FakeCalendarEventWriteStore()
        backend.availableCalendars = [.init(id: "synthetic", title: "Synthetic", colour: .init(red: 0, green: 0.3, blue: 1), sourceID: "local", sourceTitle: "Local", isWritable: true)]
        backend.assignsEventIdentifiersOnCommit = true
        let draft = CalendarEventDraft(title: "Sketch review", start: Date(timeIntervalSinceReferenceDate: 600), length: 1800, calendarID: "synthetic", timeZoneID: "UTC")
        return (backend, CalendarEventTransactions(store: backend, record: try CalendarOwnershipRecord()), draft)
    }

    func testPhoneRefusesToOverwriteOrRemoveAnEventEditedOutsideAttic() throws {
        let (backend, core, draft) = try fixture()
        let event = try core.insert(UUID(), draft: draft)
        XCTAssertEqual(try core.ownedEvent(matching: event.occurrenceID)?.id, event.id)
        let key = try XCTUnwrap(backend.events.keys.first)
        var external = try XCTUnwrap(backend.events[key]); external.draft.title = "Changed in Calendar"
        backend.events[key] = external
        XCTAssertNil(try core.ownedEvent(matching: event.occurrenceID))
        XCTAssertThrowsError(try core.update(event.id, draft: draft, expecting: event.draft)) { XCTAssertEqual($0 as? CalendarEventWriteError, .eventChanged) }
        XCTAssertThrowsError(try core.remove(event.id, expecting: event.draft)) { XCTAssertEqual($0 as? CalendarEventWriteError, .eventChanged) }
        XCTAssertEqual(backend.events[key], external)
        XCTAssertEqual(backend.commits, 1)
    }

    func testFailedOwnershipJournalNeverCommitsAnEvent() throws {
        let (backend, _, draft) = try fixture()
        let broken = try CalendarOwnershipRecord(persist: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let core = CalendarEventTransactions(store: backend, record: broken)
        XCTAssertThrowsError(try core.insert(UUID(), draft: draft))
        XCTAssertTrue(backend.events.isEmpty)
        XCTAssertTrue(broken.entries.isEmpty)
        XCTAssertEqual(backend.commits, 0)
        XCTAssertEqual(backend.rollbacks, 1)
    }
}
