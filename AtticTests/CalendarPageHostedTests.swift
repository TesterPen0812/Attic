import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// The Calendar page mounted in an off-screen window (Accepted 2026-10-30,
/// "Calendar page"): what the page itself shows and does, not only its
/// helpers. Today in the bottom bar comes and goes with the selection, the
/// free-days line selects its first day, and free-day runs re-form as
/// events load while the selection and scroll position hold and the page
/// updates a bounded number of times.
///
/// Uses only the page, its model and accessibility identifiers, so the
/// suite also runs against the page before the free-days line and the
/// Today fade were built.
@MainActor
final class CalendarPageHostedTests: XCTestCase {
    private let calendar = CalendarMonthMath.calendar(timeZone: TimeZone(identifier: "Europe/London")!)

    private func day(_ y: Int, _ m: Int, _ d: Int) -> DueDay { DueDay(year: y, month: m, day: d)! }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func event(_ id: String, on d: Int, month m: Int = 10, hour h: Int = 9) -> CalendarEvent {
        CalendarEvent(id: id, title: "Event \(id)", start: date(2026, m, d, h), end: date(2026, m, d, h + 1),
                      isAllDay: false, location: nil, calendarTitle: "Home",
                      colour: CalendarEventColour(red: 0.2, green: 0.5, blue: 0.9))
    }

    // MARK: - Today

    func testTodayButtonIsAbsentOnTodayAndPresentOnAnotherDay() throws {
        try withPage(events: [event("s", on: 29)]) { page in
            XCTAssertEqual(page.model.snapshot.selected, day(2026, 10, 29))
            XCTAssertNil(page.element("calendar-today"), "today selected: no Today button")
            page.model.select(day(2026, 10, 31))
            page.settle()
            let today = try XCTUnwrap(page.element("calendar-today"), "another day selected: Today shows")
            XCTAssertTrue(today.accessibilityPerformPress?() ?? false, "Today takes a click")
            page.settle(0.6)
            XCTAssertEqual(page.model.snapshot.selected, day(2026, 10, 29), "Today goes to today")
            XCTAssertNil(page.element("calendar-today"), "back on today, the button goes again")
        }
    }

    // MARK: - Free days

    func testClickingTheFreeDaysLineSelectsItsFirstDay() throws {
        // 30 Oct–4 Nov are free: one line, "free-2026-10-30".
        try withPage(events: [event("s", on: 29)]) { page in
            let line = try XCTUnwrap(page.element("calendar-free-2026-10-30"), "the free days fold into one line")
            XCTAssertNil(page.element("calendar-tile-2026-10-31"), "the run's other days have no tile")
            XCTAssertTrue(line.accessibilityPerformPress?() ?? false, "the line takes a click")
            page.settle()
            XCTAssertEqual(page.model.snapshot.selected, day(2026, 10, 30), "the click selects the run's first day")
        }
    }

    /// Events loading while the page is scrolled: one landing on a run's
    /// first day, on its last day, splitting a run, and one going so two
    /// runs merge. The runs re-form with unique ids, the selected day and
    /// the scroll position hold, and each load updates the page boundedly.
    func testFreeRunsReformAsEventsLoadWhileSelectionAndScrollHold() throws {
        let base = event("s", on: 29)
        try withPage(events: [base]) { page in
            XCTAssertEqual(page.freeLines(), ["2026-10-30"], "30 Oct–4 Nov: one run")
            page.scroll(to: 60)
            let offset = page.offset
            XCTAssertEqual(offset, 60, accuracy: 0.5, "scrolled into the month")

            @MainActor func load(_ events: [CalendarEvent], free expected: [String], days: [String],
                      _ message: String, line: UInt = #line) {
                let before = CalendarPage.bodyEvaluations
                page.source.replace(events)
                page.settle()
                XCTAssertEqual(page.freeLines(), expected, "\(message): free runs", line: line)
                XCTAssertEqual(page.tiles(), days, "\(message): day tiles", line: line)
                let ids = page.freeLines() + page.tiles()
                XCTAssertEqual(Set(ids).count, ids.count, "\(message): unique ids", line: line)
                XCTAssertEqual(page.model.snapshot.selected, day(2026, 10, 29), "\(message): the selection holds", line: line)
                XCTAssertEqual(page.offset, offset, accuracy: 0.5, "\(message): the scroll position holds", line: line)
                let updates = CalendarPage.bodyEvaluations - before
                XCTAssertLessThanOrEqual(updates, 3, "\(message): one load, a bounded number of updates", line: line)
                let quiet = CalendarPage.bodyEvaluations
                page.settle()
                XCTAssertEqual(CalendarPage.bodyEvaluations, quiet, "\(message): settles (no layout loop)", line: line)
            }

            let split = event("split", on: 1, month: 11)
            load([base, split], free: ["2026-10-30", "2026-11-02"], days: ["2026-10-29", "2026-11-01"],
                 "an event splitting the run")
            let first = event("first", on: 30)
            load([base, split, first], free: ["2026-10-31", "2026-11-02"],
                 days: ["2026-10-29", "2026-10-30", "2026-11-01"], "an event on a run's first day")
            let last = event("last", on: 4, month: 11)
            load([base, split, first, last], free: ["2026-10-31", "2026-11-02"],
                 days: ["2026-10-29", "2026-10-30", "2026-11-01", "2026-11-04"], "an event on a run's last day")
            load([base, first, last], free: ["2026-10-31"], days: ["2026-10-29", "2026-10-30", "2026-11-04"],
                 "an event going, so two runs merge")
        }
    }

    // MARK: - Agenda task rows (w2-tasks review 4)

    private func seedAgendaTask(_ id: UUID) -> (TaskStore) throws -> Void {
        { store in
            let context = ModelContext(store.container)
            let task = TaskItem(id: id, title: "Agenda task", createdAt: self.date(2026, 10, 1))
            task.listOrderVersion = TaskItem.currentListOrderVersion
            task.dueDay = self.day(2026, 10, 29)
            context.insert(task)
            try context.save()
            store.refresh()
        }
    }

    private func agendaActions(opened: @escaping (UUID) -> Void) -> (TaskStore) -> CalendarTaskRowActions {
        { store in
            CalendarTaskRowActions(toggleDone: { _ in }, open: opened, rename: { id, title in
                guard let task = store.task(withID: id) else { return false }
                return store.rename(task, to: title)
            })
        }
    }

    /// The mounted row's frame in window coordinates and its title's point.
    private func agendaRow(_ page: MountedPage, _ id: UUID) throws -> (element: AnyObject, title: CGPoint) {
        let row = try XCTUnwrap(page.element("calendar-task-\(id.uuidString)"), "the task's row in the agenda")
        let screen = try XCTUnwrap((row as? NSAccessibilityElementProtocol)?.accessibilityFrame())
        let frame = page.window.convertFromScreen(screen)
        return (row, CGPoint(x: frame.minX + TasksDesignMetrics.textX + 8, y: frame.maxY - TasksRowDesign.paddingY - TasksRowDesign.line / 2))
    }

    /// Runs one of the mounted row's own commands (VoiceOver's actions: the
    /// same closures its keys run).
    private func perform(_ name: String, on element: AnyObject, line: UInt = #line) {
        let actions = (element as? NSObject)?.value(forKey: "accessibilityCustomActions") as? [NSAccessibilityCustomAction] ?? []
        guard let action = actions.first(where: { $0.name == name }) else {
            return XCTFail("no \(name) in \(actions.map(\.name))", line: line)
        }
        if let handler = action.handler { _ = handler() } else if let target = action.target as? NSObject {
            _ = target.perform(action.selector, with: action)
        }
    }

    /// The agenda's task rows behave as the Tasks rows do, in the mounted
    /// page: a real click on the title selects, Return's command and a real
    /// double-click rename the task, Open page opens it.
    func testAgendaTaskRowsSelectOnAClickRenameAndOpenInTheMountedPage() throws {
        let id = UUID()
        var opened: [UUID] = []
        let makeActions = agendaActions { opened.append($0) }
        try withPage(events: [], seed: seedAgendaTask(id), taskActions: makeActions) { page in
            let rows = page.model.taskRows
            var (row, title) = try agendaRow(page, id)
            page.click(at: title, count: 1)
            XCTAssertEqual(rows.selected, id, "a real click on the title selects")
            XCTAssertEqual(opened, [], "and opens nothing")
            XCTAssertNil(rows.renaming)
            (row, title) = try agendaRow(page, id)
            perform("Edit title", on: row)
            page.settle()
            XCTAssertEqual(rows.renaming, id, "Return's command renames the selected task")
            XCTAssertEqual(rows.draft, "Agenda task")
            // The field's Return saves: the row's own editing commit.
            rows.draft = "Renamed in Calendar"
            let task = try XCTUnwrap(page.model.snapshot.groups.flatMap(\.items).compactMap { item -> CalendarTaskEntry? in
                if case let .task(task) = item, task.id == id { task } else { nil }
            }.first)
            let group = try XCTUnwrap(page.model.snapshot.groups.first { $0.day == self.day(2026, 10, 29) })
            let editing = try XCTUnwrap(CalendarAgendaDay(group: group, today: group.day, taskActions: makeActions(page.model.store),
                                                          rows: rows, onSelectDay: { _ in }).taskRow(task).titleEditing)
            XCTAssertTrue(editing.commit())
            page.settle()
            XCTAssertNil(rows.renaming, "saved")
            XCTAssertEqual(page.model.store.task(withID: id)?.title, "Renamed in Calendar")
            XCTAssertEqual(rows.selected, id, "still selected")
            (row, title) = try agendaRow(page, id)
            perform("Open page", on: row)
            XCTAssertEqual(opened, [id], "⇧⌘I's command opens its page")
            page.click(at: title, count: 1)
            page.click(at: title, count: 2)
            page.settle()
            XCTAssertEqual(rows.renaming, id, "a real double-click edits the title (owner, 2026-10-31)")
            XCTAssertEqual(opened, [id], "and opens nothing")
        }
    }

    /// The same with real keys (needs a key window and the desktop).
    func testAgendaTaskRowsAnswerRealReturnAndShiftCommandI() throws {
        try requireKeyWindowTests()
        let id = UUID()
        var opened: [UUID] = []
        let makeActions = agendaActions { opened.append($0) }
        try withPage(events: [], seed: seedAgendaTask(id), taskActions: makeActions, keyWindow: true) { page in
            let rows = page.model.taskRows
            page.click(at: try agendaRow(page, id).title, count: 1)
            XCTAssertEqual(rows.selected, id)
            page.press("\r", keyCode: 36)
            XCTAssertEqual(rows.renaming, id, "Return renames")
            page.press("\u{1b}", keyCode: 53)
            XCTAssertNil(rows.renaming, "Esc cancels")
            page.press("i", keyCode: 34, modifiers: [.command, .shift])
            XCTAssertEqual(opened, [id], "⇧⌘I opens")
        }
    }

    // MARK: - Mounting

    @MainActor private struct MountedPage {
        let model: CalendarPageModel
        let source: CalendarEventSourceStub
        let host: NSHostingView<AnyView>
        let window: NSWindow

        func settle(_ seconds: TimeInterval = 0.3) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        /// A real click (window coordinates), through the app's queue.
        func click(at point: CGPoint, count: Int) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 9, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)!
                NSApp.postEvent(event, atStart: false)
            }
            Hosted.pumpEvents()
            settle(0.3)
        }

        /// A real key press, through the app's queue.
        func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                             isARepeat: false, keyCode: keyCode)!
                NSApp.postEvent(event, atStart: false)
                Hosted.pumpEvents()
            }
            settle(0.4)
        }

        var scroller: NSScrollView? { Self.scrollView(in: host) }

        var offset: CGFloat { scroller?.contentView.bounds.origin.y ?? -1 }

        func scroll(to y: CGFloat) {
            guard let scroller else { return XCTFail("the page's scroller") }
            scroller.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroller.reflectScrolledClipView(scroller.contentView)
            settle()
        }

        func element(_ identifier: String) -> AnyObject? {
            host.layoutSubtreeIfNeeded()
            return Self.elements(host).first { ($0.accessibilityIdentifier?() ?? "") == identifier }
        }

        /// The dates (yyyy-MM-dd) of the drawn elements whose id starts with `prefix`.
        func ids(_ prefix: String) -> [String] {
            host.layoutSubtreeIfNeeded()
            let ids = Self.elements(host).compactMap { $0.accessibilityIdentifier?() }
                .filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            var seen = Set<String>()
            return ids.filter { seen.insert($0).inserted }.sorted()
        }

        func freeLines() -> [String] { ids("calendar-free-") }
        func tiles() -> [String] { ids("calendar-tile-") }

        private static func elements(_ root: AnyObject) -> [AnyObject] {
            let children = (root.accessibilityChildren?() ?? nil) ?? []
            return [root] + children.flatMap { elements($0 as AnyObject) }
        }

        private static func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView != nil { return scroll }
            for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
            return nil
        }
    }

    /// Today is 29 Oct 2026 at noon and selected. The window is tall enough
    /// that all seven agenda days are drawn.
    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private func withPage(events: [CalendarEvent], seed: (TaskStore) throws -> Void = { _ in },
                          taskActions: ((TaskStore) -> CalendarTaskRowActions)? = nil, keyWindow: Bool = false,
                          _ body: (MountedPage) throws -> Void) throws {
        let store = try makeTestStore()
        try seed(store)
        let source = CalendarEventSourceStub(events: events)
        let model = CalendarPageModel(store: store, source: source, calendar: calendar, now: { self.date(2026, 10, 29, 12) })
        let size = CGSize(width: 320, height: 900)
        let layout = PanelPageLayout(cornerSize: 28, panelSize: size)
        let page = CalendarPage(model: model, layout: layout,
                                taskActions: taskActions?(store) ?? CalendarTaskRowActions(toggleDone: { _ in }, open: { _ in }),
                                onNewTask: { _ in })
            .atticDesign(AtticDesignContext(mode: .light))
            .frame(width: size.width, height: size.height)
        let window: NSWindow = keyWindow
            ? KeyPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            : NSWindow(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                       styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(page))
        window.contentView = host
        window.orderFront(nil)
        if keyWindow { window.makeKey() }
        defer { window.orderOut(nil) }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let mounted = MountedPage(model: model, source: source, host: host, window: window)
        mounted.settle(0.6)
        try body(mounted)
    }
}
