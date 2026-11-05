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
        func edit(_ id: UUID, draft: CalendarEventDraft) async throws -> CalendarOwnedEvent {
            if hold { await withCheckedContinuation { gate = $0 } }
            return try base.edit(id, draft: draft)
        }
        func delete(_ id: UUID) async throws { try base.delete(id) }
        func openInCalendar(_ id: String) async throws { try base.openInCalendar(id) }
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

    func testQuitPreparationSavesEveryRegisteredCalendarDraft() async throws {
        let docked = try Fixture(); defer { docked.finish() }
        let detached = try Fixture(); defer { detached.finish() }
        let registry = CalendarDraftTerminationRegistry()
        registry.register(docked.rows)
        registry.register(detached.rows)
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
        registry.register(f.rows)
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
        registry.register(f.rows)
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
