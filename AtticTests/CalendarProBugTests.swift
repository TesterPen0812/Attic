import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Pro's calendar reproducers use only in-memory models and injected providers.
@MainActor
final class CalendarProBugTests: XCTestCase {
    private let calendar = CalendarMonthMath.calendar(timeZone: TimeZone(identifier: "Europe/London")!)
    private var windows: [NSWindow] = []
    override func tearDown() {
        for window in windows { window.orderOut(nil); window.contentView = nil; window.close() }
        windows.removeAll()
    }
    private func date(_ d: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: hour))!
    }
    private func mount<V: View>(_ view: V) -> (NSWindow, NSHostingView<V>) {
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 320, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let plain = NSHostingView(rootView: view)
        plain.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        window.contentView = plain
        windows.append(window)
        window.orderFront(nil)
        settle()
        return (window, plain)
    }
    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }
    private func elements(_ root: AnyObject) -> [AnyObject] {
        [root] + ((root.accessibilityChildren?() ?? nil) ?? []).flatMap { elements($0 as AnyObject) }
    }
    private func press(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        NSApp.postEvent(event, atStart: false)
        Hosted.pumpEvents()
        settle()
    }

    private final class TextInput: NSTextView {
        var escapes = 0
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { escapes += 1; unmarkText() } else { super.keyDown(with: event) }
        }
    }
    func testBG39EscapeBelongsToMarkedTextBeforeCalendar() throws {
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 320, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let input = CalendarPageInput.Input(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let text = TextInput(frame: CGRect(x: 0, y: 0, width: 300, height: 80))
        var closes = 0
        input.route = CalendarPageInput(enabled: { true }, today: {}, escape: { closes += 1; return true }, emptyPress: {})
        window.contentView = NSView(frame: input.frame)
        window.contentView?.addSubview(input)
        window.contentView?.addSubview(text)
        window.orderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(text))
        // The invisible host never owns native keyboard focus. Exercise the
        // same handler its local monitor calls, forwarding only returned keys
        // to the actual text-input client, without global AppKit key delivery.
        func escape() throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            if let returned = input.handle(event) { text.keyDown(with: returned) }
        }
        // Search and event title both use this native input boundary.
        for _ in 0..<2 {
            text.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(text.hasMarkedText())
            let before = closes
            try escape()
            XCTAssertEqual(closes, before, "composition cancellation cannot close Search or save an event")
            XCTAssertFalse(text.hasMarkedText())
            try escape()
            XCTAssertEqual(closes, before + 1, "after composition, page Escape still works")
        }
        XCTAssertEqual(text.escapes, 2)
        input.stop()
    }

    private final class Visibility: ObservableObject {
        @Published var current = false
        var effective = true
    }
    private struct Recorder: NSViewRepresentable {
        @Environment(\.atticPanelPageIsCurrent) var current
        let visibility: Visibility
        func makeNSView(context: Context) -> NSView { NSView() }
        func updateNSView(_ view: NSView, context: Context) { visibility.effective = current }
    }
    private final class AccessSource: CalendarEventSource {
        var accessState: CalendarAccessState = .notDetermined
        var onChange: (@MainActor () -> Void)?
        var requests = 0
        func requestAccess() async -> CalendarAccessState { requests += 1; accessState = .granted; return .granted }
        func events(in interval: DateInterval) -> [CalendarEvent] { [] }
        func search(_ text: String, in interval: DateInterval) -> [CalendarEvent] { [] }
    }
    private struct RetainedCalendar: View {
        @ObservedObject var visibility: Visibility
        let model: CalendarPageModel
        let notes: NoteStore
        let draft: NoteDraftController
        let ui: PanelUIState
        var body: some View {
            let layout = PanelPageLayout(cornerSize: 28, panelSize: CGSize(width: 320, height: 600))
            TaskNoteRouteHost(page: .calendar, noteStore: notes, taskStore: model.store, noteDraft: draft,
                uiState: ui, layout: layout, isReady: true) { _ in
                CalendarPage(model: model, layout: layout,
                    taskActions: CalendarTaskRowActions(toggleDone: { _ in }, open: { _ in }), onNewTask: { _ in })
                    .background(Recorder(visibility: visibility))
            }
            .modifier(PanelPageVisibility(isCurrent: visibility.current, restingOffset: 0, disablesWhenHidden: false))
            .atticDesign(AtticDesignContext(mode: .light))
        }
    }
    func testBG69RetainedCalendarCannotPromoteItsHiddenAncestor() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let tasks = TaskStore(container: container)
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let draft = NoteDraftController(noteStore: notes)
        let source = AccessSource()
        let model = CalendarPageModel(store: tasks, source: source, calendar: calendar, now: { self.date(29, hour: 12) })
        let visibility = Visibility()
        let (window, _) = mount(RetainedCalendar(visibility: visibility, model: model, notes: notes, draft: draft, ui: PanelUIState()))
        model.select(DueDay(year: 2026, month: 10, day: 31)!)
        settle()
        XCTAssertFalse(visibility.effective)
        XCTAssertEqual(source.requests, 0, "warming an unselected page cannot request access")
        try press("t", code: 17, flags: .command, in: window)
        XCTAssertEqual(model.snapshot.selected.day, 31, "a retained Calendar must not consume another page's Command-T")
        visibility.current = true
        settle()
        XCTAssertTrue(visibility.effective)
        XCTAssertEqual(source.requests, 1)
        try press("t", code: 17, flags: .command, in: window)
        XCTAssertEqual(model.snapshot.selected.day, 29)
        visibility.current = false
        settle()
        XCTAssertFalse(visibility.effective)
        XCTAssertEqual(source.requests, 1)
    }

    func testBG41DiscardReleasesTheRealNavigationBarrierWithoutWriting() async throws {
        let writer = CalendarProHeldWriter(start: date(29, hour: 9))
        let source = CalendarEventSourceStub(events: [writer.event])
        let model = CalendarPageModel(store: try makeTestStore(), source: source, calendar: calendar,
            now: { self.date(29, hour: 12) }, makeWriter: { writer })
        model.setVisible(true)
        defer { model.setVisible(false) }
        await model.eventRows.toggle(writer.event)
        model.eventRows.title = "Retained edit"
        writer.error = .eventMissing
        source.replace([])
        var navigated = false
        let destination = DueDay(year: 2026, month: 10, day: 31)!
        model.navigateAfterClosingEvent { model.select(destination); navigated = true }
        for _ in 0..<100 where model.eventRows.failure == nil { await Task.yield() }
        XCTAssertNotNil(model.eventRows.failure)
        XCTAssertFalse(navigated)
        XCTAssertEqual(model.snapshot.selected.day, 29)
        let writes = writer.editCalls
        model.eventRows.discardChanges()
        model.navigateAfterClosingEvent { model.select(destination); navigated = true }
        for _ in 0..<100 where !navigated { await Task.yield() }
        XCTAssertTrue(navigated)
        XCTAssertEqual(model.snapshot.selected, destination)
        XCTAssertEqual(writer.editCalls, writes)
    }

    func testBG41DiscardCannotRaceAHeldSaveOrLoseNewerTyping() async throws {
        let writer = CalendarProHeldWriter(start: date(29, hour: 9))
        let rows = CalendarEventRowState(makeWriter: { writer })
        await rows.toggle(writer.event)
        rows.title = "Submitted edit"
        writer.hold = true
        writer.error = .accessDenied
        let save = Task { await rows.close() }
        for _ in 0..<100 where writer.gate == nil { await Task.yield() }
        let gate = try XCTUnwrap(writer.gate)
        rows.title = "Newer typing"
        rows.discardChanges()
        XCTAssertNotNil(rows.rowID)
        XCTAssertEqual(rows.title, "Newer typing")
        gate.resume(); writer.gate = nil
        let closed = await save.value
        XCTAssertFalse(closed)
        XCTAssertEqual(rows.title, "Newer typing")
        XCTAssertNotNil(rows.failure)
        rows.discardChanges()
        XCTAssertNil(rows.rowID)
        XCTAssertEqual(writer.editCalls, 1)
    }

    func testBG41FailedEditCanBeDiscardedEvenWhenItsRowDisappears() async throws {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        for error in [CalendarEventWriteError.eventMissing, .accessDenied, .eventChanged] {
            let writer = CalendarProHeldWriter(start: date(29, hour: 9))
            let store = try makeTestStore()
            let source = CalendarEventSourceStub(events: [writer.event])
            let model = CalendarPageModel(store: store, source: source, calendar: calendar,
                now: { self.date(29, hour: 12) }, makeWriter: { writer })
            let layout = PanelPageLayout(cornerSize: 28, panelSize: CGSize(width: 320, height: 600))
            let (_, host) = mount(CalendarPage(model: model, layout: layout,
                taskActions: CalendarTaskRowActions(toggleDone: { _ in }, open: { _ in }), onNewTask: { _ in })
                .atticDesign(AtticDesignContext(mode: .light)))
            await model.eventRows.toggle(writer.event)
            model.eventRows.title = "Keep my draft"
            writer.error = error
            source.replace([])
            let closed = await model.eventRows.close()
            XCTAssertFalse(closed)
            XCTAssertEqual(model.eventRows.title, "Keep my draft")
            XCTAssertNotNil(model.eventRows.owned)
            settle()
            host.layoutSubtreeIfNeeded()
            guard let discard = elements(host).first(where: { $0.accessibilityIdentifier?() == "calendar-event-discard" }) else {
                XCTFail("no reachable discard after \(error)"); continue
            }
            XCTAssertTrue(discard.accessibilityPerformPress?() ?? false)
            settle()
            XCTAssertNil(model.eventRows.rowID)
            XCTAssertNil(model.eventRows.owned)
            let canClose = await model.eventRows.close()
            XCTAssertTrue(canClose)
            model.select(DueDay(year: 2026, month: 10, day: 31)!)
            XCTAssertEqual(model.snapshot.selected.day, 31)
            XCTAssertEqual(writer.editCalls, 1, "discard never writes")
        }
    }
}

@MainActor
final class CalendarProHeldWriter: CalendarEventWriter {
    var saved: CalendarOwnedEvent
    var error: CalendarEventWriteError?
    var hold = false
    var gate: CheckedContinuation<Void, Never>?
    var editCalls = 0
    var lastError: CalendarEventWriteError? { error }
    init(start: Date) {
        saved = CalendarOwnedEvent(id: UUID(), occurrenceID: "pro-owned", draft: CalendarEventDraft(
            title: "Meeting", start: start, length: 3600, calendarID: "home", timeZoneID: "Europe/London"))
    }
    var event: CalendarEvent {
        CalendarEvent(id: saved.occurrenceID, title: saved.draft.title, start: saved.draft.start, end: saved.draft.end,
            isAllDay: false, location: nil, calendarTitle: "Home", colour: .init(red: 0.2, green: 0.5, blue: 0.9))
    }
    func writableCalendars() async throws -> [CalendarWriteCalendar] { [] }
    func ownedEvent(matching id: String) async throws -> CalendarOwnedEvent? { saved }
    func create(_ draft: CalendarEventDraft) async throws -> CalendarOwnedEvent { throw CalendarEventWriteError.invalidDraft }
    func edit(_ id: UUID, draft: CalendarEventDraft) async throws -> CalendarOwnedEvent {
        editCalls += 1
        if hold { await withCheckedContinuation { gate = $0 } }
        if let error { throw error }
        saved.draft = draft
        return saved
    }
    // Support the displayed-baseline writer contract now on the integration
    // branch, while this job remains built against its assigned base.
    func edit(_ id: UUID, draft: CalendarEventDraft, expecting baseline: CalendarEventDraft?) async throws -> CalendarOwnedEvent {
        if let baseline, baseline != saved.draft { throw CalendarEventWriteError.eventChanged }
        return try await edit(id, draft: draft)
    }
    func delete(_ id: UUID, expecting baseline: CalendarEventDraft?) async throws {
        if let baseline, baseline != saved.draft { throw CalendarEventWriteError.eventChanged }
        try await delete(id)
    }
    func delete(_ id: UUID) async throws { throw CalendarEventWriteError.notOwned }
    func openInCalendar(_ id: String) async throws {}
}
