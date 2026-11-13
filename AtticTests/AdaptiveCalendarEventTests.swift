import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Hosted row tests: only a transactional fake and in-memory ownership.
@MainActor
final class AdaptiveCalendarEventTests: XCTestCase {
    private var previousAX: Any?

    override func setUp() {
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = true
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        previousAX = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
    }
    override func tearDown() {
        NSApp.accessibilitySetValue(previousAX, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        previousAX = nil
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
    }

    private final class HeldWriter: CalendarEventWriter {
        let base: EventKitCalendarEventWriter
        var gate: CheckedContinuation<Void, Never>?
        var hold = false
        var lastError: CalendarEventWriteError? { base.lastError }
        init(_ base: EventKitCalendarEventWriter) { self.base = base }
        func writableCalendars() async throws -> [CalendarWriteCalendar] { try base.writableCalendars() }
        func ownedEvent(matching id: String) async throws -> CalendarOwnedEvent? { try base.ownedEvent(matching: id) }
        func create(_ draft: CalendarEventDraft) async throws -> CalendarOwnedEvent { try base.create(draft) }
        func edit(_ id: UUID, draft: CalendarEventDraft, expecting: CalendarEventDraft? = nil) async throws -> CalendarOwnedEvent {
            if hold { await withCheckedContinuation { gate = $0 } }
            return try base.edit(id, draft: draft, expecting: expecting)
        }
        func delete(_ id: UUID, expecting: CalendarEventDraft? = nil) async throws { try base.delete(id, expecting: expecting) }
        func openInCalendar(_ id: String) async throws { try base.openInCalendar(id) }
    }

    /// Exact fake for events received with seconds and DST-fold precision.
    /// The transactional fake rounds events created by Attic to minutes.
    private final class PreciseWriter: CalendarEventWriter {
        var saved: CalendarOwnedEvent
        var lastError: CalendarEventWriteError?
        init(_ draft: CalendarEventDraft) {
            saved = CalendarOwnedEvent(id: UUID(), occurrenceID: "precise", draft: draft)
        }
        func writableCalendars() async throws -> [CalendarWriteCalendar] { [] }
        func ownedEvent(matching id: String) async throws -> CalendarOwnedEvent? {
            id == saved.occurrenceID ? saved : nil
        }
        func create(_ draft: CalendarEventDraft) async throws -> CalendarOwnedEvent { throw CalendarEventWriteError.invalidDraft }
        func edit(_ id: UUID, draft: CalendarEventDraft, expecting: CalendarEventDraft? = nil) async throws -> CalendarOwnedEvent {
            guard id == saved.id else { throw CalendarEventWriteError.notOwned }
            guard expecting == nil || expecting == saved.draft else { throw CalendarEventWriteError.eventChanged }
            saved.draft = draft
            return saved
        }
        func delete(_ id: UUID, expecting: CalendarEventDraft? = nil) async throws { throw CalendarEventWriteError.notOwned }
        func openInCalendar(_ id: String) async throws { throw CalendarEventWriteError.openFailed }
    }

    private final class HeldExternalOpenWriter: CalendarEventWriter {
        var gate: CheckedContinuation<Void, Never>?
        var lastError: CalendarEventWriteError? { nil }
        func writableCalendars() async throws -> [CalendarWriteCalendar] { [] }
        func ownedEvent(matching id: String) async throws -> CalendarOwnedEvent? { nil }
        func create(_ draft: CalendarEventDraft) async throws -> CalendarOwnedEvent { throw CalendarEventWriteError.invalidDraft }
        func edit(_ id: UUID, draft: CalendarEventDraft, expecting: CalendarEventDraft? = nil) async throws -> CalendarOwnedEvent { throw CalendarEventWriteError.notOwned }
        func delete(_ id: UUID, expecting: CalendarEventDraft? = nil) async throws { throw CalendarEventWriteError.notOwned }
        func openInCalendar(_ id: String) async throws {
            await withCheckedContinuation { gate = $0 }
            throw CalendarEventWriteError.openFailed
        }
    }

    private func preciseRow(start: Date, duration: TimeInterval) -> (rows: CalendarEventRowState, writer: PreciseWriter, event: CalendarEvent) {
        let draft = CalendarEventDraft(title: "Lunch", start: start, length: duration,
                                       calendarID: "home", timeZoneID: "Europe/London")
        let writer = PreciseWriter(draft)
        let rows = CalendarEventRowState(makeWriter: { writer })
        let event = CalendarEvent(id: writer.saved.occurrenceID, title: draft.title, start: start, end: draft.end,
                                  isAllDay: false, location: nil, calendarTitle: "Home",
                                  colour: .init(red: 0.2, green: 0.5, blue: 0.9))
        return (rows, writer, event)
    }

    @MainActor
    private final class Fixture {
        let backend = FakeCalendarEventWriteStore()
        let undo = UndoRoute()
        let writer: HeldWriter
        let made: CalendarOwnedEvent
        let rows: CalendarEventRowState
        let event: CalendarEvent
        let host: NSHostingView<AnyView>
        let window: NSWindow
        init() throws {
            backend.availableCalendars = [CalendarWriteCalendar(id: "home", title: "Home",
                colour: .init(red: 0.2, green: 0.5, blue: 0.9), sourceID: "local", sourceTitle: "Local", isWritable: true)]
            let base = EventKitCalendarEventWriter(store: backend, record: try CalendarOwnershipRecord(),
                undoRoute: undo, notificationCenter: NotificationCenter())
            writer = HeldWriter(base)
            let start = Date(timeIntervalSince1970: 1_793_361_600)
            made = try base.create(CalendarEventDraft(title: "Lunch", start: start, length: 3600,
                calendarID: "home", timeZoneID: "Europe/London", notes: "Keep these notes"))
            let writer = writer
            rows = CalendarEventRowState(makeWriter: { writer })
            event = CalendarEvent(id: made.occurrenceID, title: "Lunch", start: start, end: start.addingTimeInterval(3600),
                isAllDay: false, location: nil, calendarTitle: "Home", colour: .init(red: 0.2, green: 0.5, blue: 0.9))
            let day = DueDay(date: start, calendar: CalendarMonthMath.calendar())
            var design = AtticDesignContext(mode: .light)
            design.reduceMotion = true
            design.reduceTransparency = true
            host = NSHostingView(rootView: AnyView(CalendarEventRow(event: event, day: day, today: day, rows: rows)
                .atticDesign(design).frame(width: 225)))
            window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 225, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
        }
        func settle() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded()
        }
        func element(_ id: String) -> AnyObject? {
            @MainActor func walk(_ root: AnyObject) -> [AnyObject] {
                [root] + ((root.accessibilityChildren?() ?? nil) ?? []).flatMap { walk($0 as AnyObject) }
            }
            return walk(host).first { $0.accessibilityIdentifier?() == id }
        }
        func finish() { window.orderOut(nil); window.contentView = nil; window.close() }
    }

    func testOwnedEventEditsInTheRowWithUndoAndDelete() async throws {
        let f = try Fixture(); defer { f.finish() }
        await f.rows.toggle(f.event); f.settle()
        XCTAssertNotNil(f.element("calendar-event-title-\(f.event.id)"))
        XCTAssertNotNil(f.element("calendar-event-delete-\(f.event.id)"))
        f.rows.title = "Lunch edited"
        f.rows.length = 90
        let closed = await f.rows.close()
        XCTAssertTrue(closed)
        XCTAssertEqual(f.backend.events.values.first?.draft.title, "Lunch edited")
        XCTAssertEqual(f.backend.events.values.first?.draft.end.timeIntervalSince(f.made.draft.start), 5400)
        XCTAssertEqual(f.backend.events.values.first?.draft.notes, "Keep these notes")
        let outcome = await f.undo.replay(in: .calendar, redo: false)
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(f.backend.events.values.first?.draft, f.made.draft)
    }

    func testC03RenamingAnEventPreservesSubminuteTimingAndSecondDSTFold() async throws {
        let secondFold = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T01:45:30Z"))
        let f = preciseRow(start: secondFold.addingTimeInterval(0.25), duration: 3641.5)
        await f.rows.toggle(f.event)
        f.rows.title = "Renamed"
        let renamed = await f.rows.close()
        XCTAssertTrue(renamed)
        let saved = f.writer.saved.draft
        XCTAssertEqual(saved.title, "Renamed")
        XCTAssertEqual(saved.start, secondFold.addingTimeInterval(0.25), "the second occurrence keeps its exact timestamp")
        XCTAssertEqual(saved.end.timeIntervalSince(saved.start), 3641.5, accuracy: 0.00001)

        let short = preciseRow(start: secondFold, duration: 38.5)
        await short.rows.toggle(short.event)
        short.rows.title = "Short renamed"
        let shortened = await short.rows.close()
        XCTAssertTrue(shortened, "a title-only edit must not reject a subminute event")
        XCTAssertEqual(short.writer.saved.draft.start, secondFold)
        XCTAssertEqual(short.writer.saved.draft.end.timeIntervalSince(secondFold), 38.5, accuracy: 0.00001)
    }

    func testC03ChangingClockAndLengthPreservesPrecisionAndOriginalDSTFold() async throws {
        let formatter = ISO8601DateFormatter()
        let secondFold = try XCTUnwrap(formatter.date(from: "2026-10-25T01:45:30Z"))
        let f = preciseRow(start: secondFold.addingTimeInterval(0.25), duration: 3641.5)
        await f.rows.toggle(f.event)
        XCTAssertEqual(f.rows.startText, "01:45")
        f.rows.startText = "01:15"
        f.rows.length = 75
        let changed = await f.rows.close()
        XCTAssertTrue(changed)
        let saved = f.writer.saved.draft
        let expected = try XCTUnwrap(formatter.date(from: "2026-10-25T01:15:30Z"))
            .addingTimeInterval(0.25)
        XCTAssertEqual(saved.start, expected, "retain the second repeated hour when changing the clock")
        XCTAssertEqual(saved.end.timeIntervalSince(saved.start), 75 * 60 + 41.5,
                       accuracy: 0.00001, "retain the duration's subminute remainder")
    }

    func testC03SpringGapRejectsAnImpossibleClockAndKeepsTheDraft() async throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-29T00:45:20Z"))
        let f = preciseRow(start: start, duration: 3600)
        await f.rows.toggle(f.event)
        f.rows.startText = "01:30" // skipped when London jumps to 02:00
        let closed = await f.rows.close()
        XCTAssertFalse(closed)
        XCTAssertNotNil(f.rows.rowID)
        XCTAssertNotNil(f.rows.failure)
        XCTAssertEqual(f.writer.saved.draft.start, start)
    }

    func testQuitPreparationSavesEveryRegisteredCalendarDraft() async throws {
        let docked = try Fixture(); defer { docked.finish() }
        let detached = try Fixture(); defer { detached.finish() }
        let registry = CalendarDraftTerminationRegistry()
        registry.register(docked.rows, owner: .docked)
        registry.register(detached.rows, owner: .floating)
        await docked.rows.toggle(docked.event)
        await detached.rows.toggle(detached.event)
        docked.rows.title = "Docked edit"
        detached.rows.title = "Detached edit"

        await XCTAssertTrueAsync(await registry.prepareForTerminationDurably())
        XCTAssertEqual(docked.backend.events.values.first?.draft.title, "Docked edit")
        XCTAssertEqual(detached.backend.events.values.first?.draft.title, "Detached edit")
        XCTAssertNil(docked.rows.rowID)
        XCTAssertNil(detached.rows.rowID)
    }

    func testV6QuitRefusalNamesTheActualFailedCalendarOwner() async throws {
        let docked = try Fixture(); defer { docked.finish() }
        let floating = try Fixture(); defer { floating.finish() }
        let registry = CalendarDraftTerminationRegistry()
        registry.register(docked.rows, owner: .docked)
        registry.register(floating.rows, owner: .floating)
        await docked.rows.toggle(docked.event)
        await floating.rows.toggle(floating.event)
        docked.rows.title = "" // invalid: this draft belongs to the docked page
        floating.rows.title = "Valid floating edit"

        let outcome = await registry.prepareForTerminationResult()
        XCTAssertEqual(outcome, .refused(.docked))
        XCTAssertNotNil(docked.rows.rowID, "failed owner must keep its draft")
        XCTAssertNil(floating.rows.rowID, "the other owner may close normally")
    }

    func testV7QuitWaitsForAnExistingInFlightCalendarSave() async throws {
        let f = try Fixture(); defer { f.finish() }
        let registry = CalendarDraftTerminationRegistry()
        registry.register(f.rows, owner: .docked)
        await f.rows.toggle(f.event)
        f.rows.title = "Already saving"
        f.writer.hold = true
        let earlierClose = Task { await f.rows.close() }
        for _ in 0..<100 where f.writer.gate == nil { await Task.yield() }
        let gate = try XCTUnwrap(f.writer.gate, "the existing save reached its writer")
        var quitResult: Bool?
        let quit = Task { @MainActor in quitResult = await registry.prepareForTerminationDurably() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertNil(quitResult, "quit must await the already running save")
        gate.resume()
        await XCTAssertTrueAsync(await earlierClose.value)
        await quit.value
        XCTAssertEqual(quitResult, true)
        XCTAssertEqual(f.backend.events.values.first?.draft.title, "Already saving")
    }

    func testQuitPreparationRefusesFailedSaveAndPreservesNewerTyping() async throws {
        let f = try Fixture(); defer { f.finish() }
        let registry = CalendarDraftTerminationRegistry()
        registry.register(f.rows, owner: .docked)
        await f.rows.toggle(f.event)
        f.rows.title = "First edit"
        f.backend.commitError = .saveFailed("Full disk")
        await XCTAssertFalseAsync(await registry.prepareForTerminationDurably())
        XCTAssertEqual(f.rows.title, "First edit")
        XCTAssertNotNil(f.rows.rowID)

        f.backend.commitError = nil
        f.writer.hold = true
        let prepare = Task { await registry.prepareForTerminationDurably() }
        for _ in 0..<100 where f.writer.gate == nil { await Task.yield() }
        guard let gate = f.writer.gate else { prepare.cancel(); return XCTFail("save reached the held writer") }
        f.rows.title = "Newer typing"
        gate.resume()
        await XCTAssertFalseAsync(await prepare.value)
        XCTAssertEqual(f.rows.title, "Newer typing")
        XCTAssertNotNil(f.rows.rowID)
        f.writer.hold = false
        await XCTAssertTrueAsync(await registry.prepareForTerminationDurably())
        XCTAssertEqual(f.backend.events.values.first?.draft.title, "Newer typing")
    }

    func testFailedEditRollsBackKeepsTheTextAndShowsFailure() async throws {
        let f = try Fixture(); defer { f.finish() }
        await f.rows.toggle(f.event)
        f.rows.title = "Keep my edit"
        f.backend.commitError = .saveFailed("Full disk")
        let closed = await f.rows.close(); f.settle()
        XCTAssertFalse(closed)
        XCTAssertEqual(f.rows.rowID, f.event.id)
        XCTAssertEqual(f.rows.title, "Keep my edit")
        XCTAssertNotNil(f.element("calendar-event-failure-\(f.event.id)"))
        XCTAssertEqual(f.backend.events.values.first?.draft, f.made.draft)
        XCTAssertEqual(f.backend.rollbacks, 1)
        f.backend.commitError = nil
        let retried = await f.rows.close()
        XCTAssertTrue(retried)
        XCTAssertEqual(f.backend.events.values.first?.draft.title, "Keep my edit")
    }

    func testHeldFailedEditKeepsNewerTypingAndReportsFailure() async throws {
        let f = try Fixture(); defer { f.finish() }
        await f.rows.toggle(f.event)
        f.rows.title = "Submitted"
        f.writer.hold = true
        f.backend.commitError = .saveFailed("Full disk")
        let close = Task { await f.rows.close() }
        for _ in 0..<100 where f.writer.gate == nil { await Task.yield() }
        guard let gate = f.writer.gate else { close.cancel(); return XCTFail("edit reached the held writer") }
        f.rows.title = "Newer typing"
        gate.resume()
        let closed = await close.value; f.settle()
        XCTAssertFalse(closed)
        XCTAssertEqual(f.rows.title, "Newer typing")
        XCTAssertNotNil(f.element("calendar-event-failure-\(f.event.id)"))
        XCTAssertEqual(f.backend.events.values.first?.draft, f.made.draft)
    }

    func testUnownedEventCannotEditOrDeleteAndOpensThroughWriter() async throws {
        let f = try Fixture(); defer { f.finish() }
        var external = f.event
        external.id = "external"
        await f.rows.toggle(external)
        XCTAssertFalse(f.rows.canEdit)
        XCTAssertFalse(f.rows.canDelete)
        let commits = f.backend.commits
        f.rows.title = "Not a permitted edit"
        await f.rows.delete()
        await f.rows.close()
        XCTAssertEqual(f.backend.commits, commits)
        XCTAssertEqual(f.backend.events.values.first?.draft, f.made.draft)
        await f.rows.openInCalendar(external)
        XCTAssertEqual(f.backend.opened, [external.id])
    }

    func testFix18LateExternalOpenFailureCannotMarkAnotherEventOrReopenDismissedEvent() async throws {
        let writer = HeldExternalOpenWriter()
        let rows = CalendarEventRowState(makeWriter: { writer })
        let start = Date(timeIntervalSince1970: 1_793_361_600)
        let a = CalendarEvent(id: "external-a", title: "A", start: start,
            end: start.addingTimeInterval(3600), isAllDay: false, location: nil,
            calendarTitle: "Test", colour: .init(red: 0.2, green: 0.5, blue: 0.9))
        var b = a
        b.id = "external-b"
        b.title = "B"

        await rows.toggle(a)
        let openA = Task { await rows.openInCalendar(a) }
        for _ in 0..<200 where writer.gate == nil { await Task.yield() }
        let firstGate = try XCTUnwrap(writer.gate)
        let closedA = await rows.close()
        XCTAssertTrue(closedA)
        await rows.toggle(b)
        firstGate.resume()
        await openA.value
        XCTAssertEqual(rows.rowID, b.id)
        XCTAssertNil(rows.failure, "A's external-open error must not mark B")

        writer.gate = nil
        let openB = Task { await rows.openInCalendar(b) }
        for _ in 0..<200 where writer.gate == nil { await Task.yield() }
        let secondGate = try XCTUnwrap(writer.gate)
        let closedB = await rows.close()
        XCTAssertTrue(closedB)
        secondGate.resume()
        await openB.value
        XCTAssertNil(rows.rowID, "a dismissed event must stay dismissed")
        XCTAssertNil(rows.failure)
    }

    func testDeleteFailureKeepsDraftAndSuccessfulDeleteHasUndo() async throws {
        let f = try Fixture(); defer { f.finish() }
        await f.rows.toggle(f.event)
        f.rows.title = "Unsubmitted text"
        f.backend.commitError = .saveFailed("Full disk")
        await f.rows.delete(); f.settle()
        XCTAssertEqual(f.rows.title, "Unsubmitted text")
        XCTAssertNotNil(f.element("calendar-event-failure-\(f.event.id)"))
        XCTAssertEqual(f.backend.events.count, 1)
        XCTAssertEqual(f.backend.rollbacks, 1)
        f.backend.commitError = nil
        await f.rows.delete()
        XCTAssertNil(f.rows.rowID)
        XCTAssertTrue(f.backend.events.isEmpty)
        let outcome = await f.undo.replay(in: .calendar, redo: false)
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(f.backend.events.values.first?.draft, f.made.draft)
    }
}
