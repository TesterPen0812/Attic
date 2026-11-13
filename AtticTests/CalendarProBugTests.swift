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

}
