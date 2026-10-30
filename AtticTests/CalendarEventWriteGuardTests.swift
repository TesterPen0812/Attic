import EventKit
import XCTest
@testable import Attic

@MainActor
final class CalendarEventWriteGuardTests: XCTestCase {
    private enum Probe: Error { case storeCreationForbidden }

    func testLiveStagesCommitOpenAndRollbackNeverCreateEventKitStoreUnderTests() throws {
        var creations = 0
        // Even a regressed guard cannot reach live data: the injected factory
        // throws before any EKEventStore could be constructed.
        let live = LiveCalendarEventWriteStore(storeFactory: {
            creations += 1
            throw Probe.storeCreationForbidden
        })
        let draft = CalendarEventDraft(title: "Guard", start: Date(timeIntervalSince1970: 0),
                                       length: 3_600, calendarID: "fake", timeZoneID: "GMT")
        let snapshot = CalendarWriteSnapshot(eventIdentifier: "fake-event", itemIdentifier: "fake-item", draft: draft)
        func blocked(_ body: () throws -> Void,
                     expected: CalendarEventWriteError = .saveFailed("Live calendar writes are disabled in tests.")) {
            XCTAssertThrowsError(try body()) { XCTAssertEqual($0 as? CalendarEventWriteError, expected) }
            XCTAssertEqual(creations, 0)
        }
        blocked { _ = try live.stageCreate(draft) }
        blocked { _ = try live.stageEdit(snapshot, draft: draft) }
        blocked { try live.stageDelete(snapshot) }
        blocked { try live.commit() }
        blocked({ try live.openInCalendar(snapshot.occurrenceID) }, expected: .openFailed)
        live.rollback()
        XCTAssertEqual(creations, 0, "rollback must not instantiate an unused store")
    }

    func testFactoryIsFakeBackedEvenWhenCallerSuppliesAppEnvironment() throws {
        let undo = UndoRoute()
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-factory-\(UUID())")
        // A regressed factory must still be confined to a disposable test path.
        let app = AppRuntimeEnvironment(environment: [:], bundleIdentifier: "dev.attic.calwrites.guard", applicationSupportURL: support)
        let uiTest = AppRuntimeEnvironment(environment: ["ATTIC_UI_TESTING": "1"],
            bundleIdentifier: "dev.attic.calwrites.guard", applicationSupportURL: support)
        for environment in [app, uiTest] {
            let engine = try XCTUnwrap(CalendarEventWriters.makeDefault(undoRoute: undo, environment: environment) as? EventKitCalendarEventWriter)
            XCTAssertTrue(engine.isFakeBacked)
        }
    }

    func testCalendarURLFormattingDoesNotOpenAnything() throws {
        let start = Date(timeIntervalSince1970: 0)
        let timed = try XCTUnwrap(LiveCalendarEventWriteStore.calendarURL(itemIdentifier: "item id", start: start, isRepeating: false))
        XCTAssertEqual(timed.absoluteString, "ical://ekevent/19700101T000000Z/item%20id?method=show&options=more")
        let repeating = try XCTUnwrap(LiveCalendarEventWriteStore.calendarURL(itemIdentifier: "item", start: start, isRepeating: true))
        XCTAssertEqual(repeating.absoluteString, "ical://ekevent/item?method=show&options=more")
        XCTAssertNil(LiveCalendarEventWriteStore.calendarURL(itemIdentifier: "", start: start, isRepeating: false))
    }

    func testEventKitErrorMappingIsTypedWithoutEventKitIO() {
        XCTAssertEqual(LiveCalendarEventWriteStore.typed(NSError(domain: EKErrorDomain, code: EKError.Code.calendarReadOnly.rawValue)), .calendarReadOnly)
        XCTAssertEqual(LiveCalendarEventWriteStore.typed(NSError(domain: EKErrorDomain, code: EKError.Code.eventStoreNotAuthorized.rawValue)), .accessDenied)
        XCTAssertEqual(LiveCalendarEventWriteStore.typed(NSError(domain: EKErrorDomain, code: EKError.Code.noCalendar.rawValue)), .calendarMissing)
        XCTAssertEqual(LiveCalendarEventWriteStore.typed(NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed"])), .saveFailed("Failed"))
    }
}
