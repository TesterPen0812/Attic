import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// The Calendar page mounted in an off-screen window (Accepted 2026-10-30,
/// "Calendar page"): what the page itself shows and does, not only its
/// helpers. Today in the bottom bar comes and goes with the selection,
/// every day keeps its own date tile (empty days too, owner 2026-10-31: the
/// older agenda) and a tile selects its day, and events loading keep the
/// tiles, the selection and the scroll position while the page updates a
/// bounded number of times.
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

    // MARK: - Every day's tile

    func testEmptyDaysKeepTheirOwnTileAndATileSelectsItsDay() throws {
        // 30 Oct onward are empty: each keeps its own tile, nothing folds.
        try withPage(events: [event("s", on: 29)]) { page in
            XCTAssertTrue(page.ids("calendar-free-").isEmpty, "no free-days line")
            let tiles = page.tiles()
            XCTAssertTrue(["2026-10-29", "2026-10-30", "2026-10-31"].allSatisfy(tiles.contains),
                          "today and the empty days after it, one tile each: \(tiles)")
            let tile = try XCTUnwrap(page.element("calendar-tile-2026-10-31"), "an empty day's tile")
            XCTAssertTrue(tile.accessibilityPerformPress?() ?? false, "the tile takes a click")
            page.settle()
            XCTAssertEqual(page.model.snapshot.selected, day(2026, 10, 31), "the click selects its day")
        }
    }

    /// Events loading while the page is scrolled: the days keep their tiles
    /// with unique ids, the selected day and the scroll position hold, and
    /// each load updates the page boundedly.
    func testEventsLoadingKeepTilesSelectionAndScroll() throws {
        let base = event("s", on: 29)
        try withPage(events: [base]) { page in
            page.scroll(to: 60)
            let offset = page.offset
            XCTAssertEqual(offset, 60, accuracy: 0.5, "scrolled into the month")
            let tiles = page.tiles()
            XCTAssertFalse(tiles.isEmpty)

            @MainActor func load(_ events: [CalendarEvent], _ message: String, line: UInt = #line) {
                let before = CalendarPage.bodyEvaluations
                page.source.replace(events)
                page.settle()
                XCTAssertEqual(page.tiles(), tiles, "\(message): the same day tiles", line: line)
                XCTAssertTrue(page.ids("calendar-free-").isEmpty, "\(message): nothing folds", line: line)
                XCTAssertEqual(page.model.snapshot.selected, day(2026, 10, 29), "\(message): the selection holds", line: line)
                XCTAssertEqual(page.offset, offset, accuracy: 0.5, "\(message): the scroll position holds", line: line)
                let updates = CalendarPage.bodyEvaluations - before
                XCTAssertLessThanOrEqual(updates, 3, "\(message): one load, a bounded number of updates", line: line)
                let quiet = CalendarPage.bodyEvaluations
                page.settle()
                XCTAssertEqual(CalendarPage.bodyEvaluations, quiet, "\(message): settles (no layout loop)", line: line)
            }

            let split = event("split", on: 1, month: 11)
            load([base, split], "an event on an empty day")
            let first = event("first", on: 30)
            load([base, split, first], "another")
            load([base, first], "an event going")
        }
    }

    // MARK: - Folding (item 14, owner rec2 2026-10-31)

    /// While the agenda scrolls the grid away, every frame draws the selected
    /// week once: at its place until it reaches the weekday letters, then
    /// held under them. Each offset is captured straight after the scroll
    /// (before any deferred state update) and again settled, and the scroll
    /// jumps back down past the pin as a fast flick does.
    func testTheSelectedWeekIsDrawnOnceAtEveryScrollOffset() throws {
        try withPage(events: []) { page in
            let top = try XCTUnwrap(page.scrollerTop)
            for y in [0, 60, 120, 136, 140, 142, 160, 200, 60, 150, 20, 175, 100, 0] as [CGFloat] {
                page.jump(to: y)
                try assertOneSelectedWeek(page, offset: y, viewportTop: top, "straight after a scroll to \(y)")
                page.settle(0.05)
                try assertOneSelectedWeek(page, offset: page.offset, viewportTop: top, "settled at \(y)")
            }
        }
    }

    /// The fold itself (the month title): every frame of the animation draws
    /// the selected week once, both ways.
    func testTheFoldAnimationDrawsTheSelectedWeekOnceInEveryFrame() throws {
        try withPage(events: []) { page in
            let top = try XCTUnwrap(page.scrollerTop)
            for direction in ["folding", "unfolding"] {
                let pill = try XCTUnwrap(page.element("calendar-month-pill"), "the month title")
                XCTAssertTrue(pill.accessibilityPerformPress?() ?? false, "\(direction): pressed")
                var frames = 0
                let end = Date().addingTimeInterval(0.8)
                while Date() < end {
                    RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 120))
                    page.window.displayIfNeeded()
                    try assertOneSelectedWeek(page, offset: page.offset, viewportTop: top, "\(direction) frame \(frames)")
                    frames += 1
                }
                XCTAssertGreaterThan(frames, 5, "\(direction): frames sampled")
                page.settle()
            }
            XCTAssertEqual(page.offset, 0, accuracy: 0.5, "unfolded back to the month")
        }
    }

    /// Nothing scrolls up under the weekday letters: the grid is cut at the
    /// top of its scroller, so the letters' band looks the same at any
    /// offset.
    func testNothingShowsUnderTheWeekdayLetters() throws {
        try withPage(events: []) { page in
            let top = try XCTUnwrap(page.scrollerTop)
            let band = (top - CalendarDesign.weekdayRowHeight - 2)..<(top - 0.5)
            let rest = try page.capture()
            for y in [20, 60, 100, 136, 142, 200] as [CGFloat] {
                page.jump(to: y)
                let scrolled = try page.capture()
                page.settle(0.05)
                let settled = try page.capture()
                for (name, image) in [("straight after", scrolled), ("settled", settled)] {
                    let diff = try Self.maxDifference(rest, image, band: band)
                    XCTAssertLessThan(diff, 0.02, "\(name) a scroll to \(y): the letters' band is unchanged (\(diff))")
                }
            }
        }
    }

    /// The selected day (today, so its key is the red one) in its column,
    /// left of the number: one red run of a key's height, where the week sits.
    private func assertOneSelectedWeek(_ page: MountedPage, offset: CGFloat, viewportTop: CGFloat,
                                       _ message: String, line: UInt = #line) throws {
        let image = try page.capture()
        let width = page.host.bounds.width
        let key = (width - 2 * CalendarDesign.gridInset - 6 * CalendarDesign.keyGap) / 7
        let x = CalendarDesign.gridInset + 3 * (key + CalendarDesign.keyGap) + key / 2 - 12
        let scale = CGFloat(image.pixelsHigh) / page.host.bounds.height
        let from = Int((viewportTop - CalendarDesign.weekdayRowHeight - 10) * scale)
        // Down to the grid's end (the agenda's red today tile lies below).
        let gridEnd = max(CalendarDesign.weekPitch, 5 * CalendarDesign.weekPitch - offset)
        let to = Int((viewportTop + gridEnd + 2) * scale)
        var runs: [(start: CGFloat, length: CGFloat)] = []
        var start: Int?
        for py in from...to {
            let c = try XCTUnwrap(image.colorAt(x: Int(x * scale), y: py)?.usingColorSpace(.sRGB))
            let red = c.redComponent - (c.greenComponent + c.blueComponent) / 2 > 0.25 && c.alphaComponent > 0.5
            if red, start == nil { start = py }
            if !red || py == to, let s = start {
                runs.append((CGFloat(s) / scale, CGFloat(py - s) / scale)); start = nil
            }
        }
        let keys = runs.filter { $0.length >= 8 }
        XCTAssertEqual(keys.count, 1, "\(message): one selected week drawn, runs \(runs)", line: line)
        let expected = viewportTop + max(0, 4 * CalendarDesign.weekPitch - offset) + CalendarDesign.weekTop
        if let first = keys.first {
            XCTAssertEqual(first.start, expected, accuracy: 2, "\(message): where the week sits", line: line)
            XCTAssertGreaterThan(first.length, CalendarDesign.keyHeight * 0.7, "\(message): the whole key", line: line)
        }
    }

    private static func maxDifference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, band: Range<CGFloat>) throws -> CGFloat {
        let scale = CGFloat(a.pixelsHigh) / a.size.height
        var worst: CGFloat = 0
        for py in Int(band.lowerBound * scale)..<Int(band.upperBound * scale) {
            for px in stride(from: 0, to: a.pixelsWide, by: 2) {
                let p = try XCTUnwrap(a.colorAt(x: px, y: py)?.usingColorSpace(.sRGB))
                let q = try XCTUnwrap(b.colorAt(x: px, y: py)?.usingColorSpace(.sRGB))
                worst = max(worst, abs(p.redComponent - q.redComponent), abs(p.greenComponent - q.greenComponent),
                            abs(p.blueComponent - q.blueComponent), abs(p.alphaComponent - q.alphaComponent))
            }
        }
        return worst
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

        /// The top of the scroller (where the grid starts), in the host's
        /// flipped coordinates.
        var scrollerTop: CGFloat? {
            host.layoutSubtreeIfNeeded()
            guard let scroller else { return nil }
            return host.convert(scroller.bounds, from: scroller).minY
        }

        /// A scroll without letting the run loop turn: what the very next
        /// frame shows, before any deferred state update.
        func jump(to y: CGFloat) {
            guard let scroller else { return XCTFail("the page's scroller") }
            scroller.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroller.reflectScrolledClipView(scroller.contentView)
            host.layoutSubtreeIfNeeded()
        }

        func capture() throws -> NSBitmapImageRep {
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }

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
