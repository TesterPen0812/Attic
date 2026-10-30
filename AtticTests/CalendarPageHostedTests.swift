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
    private func withPage(events: [CalendarEvent], _ body: (MountedPage) throws -> Void) throws {
        let store = try makeTestStore()
        let source = CalendarEventSourceStub(events: events)
        let model = CalendarPageModel(store: store, source: source, calendar: calendar, now: { self.date(2026, 10, 29, 12) })
        let size = CGSize(width: 320, height: 900)
        let layout = PanelPageLayout(cornerSize: 28, panelSize: size)
        let page = CalendarPage(model: model, layout: layout,
                                taskActions: CalendarTaskRowActions(toggleDone: { _ in }, open: { _ in }),
                                onNewTask: { _ in })
            .atticDesign(AtticDesignContext(mode: .light))
            .frame(width: size.width, height: size.height)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(page))
        window.contentView = host
        window.orderFront(nil)
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
