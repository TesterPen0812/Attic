import AppKit
import Combine
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Wave 2 `w2-tasks` (Accepted 2026-10-29 and 2026-10-30): going into a
/// task's page (the ›, double-click, ⇧⌘I, Back), Later as the backlog, and
/// the next event in Now.
@MainActor
final class TasksGoingInTests: XCTestCase {
    private let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000))
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let locale = Locale(identifier: "en_GB")
    private var store: TaskStore!
    private var library: AtticLibrary!
    private var model: TasksPageModel!

    override func setUp() async throws {
        store = try makeTestStore(now: { [clock] in clock.value })
        library = AtticLibrary(tasks: store, now: { [clock] in clock.value })
        let calendar = self.calendar
        model = TasksPageModel(library: library, services: TasksPageServices(
            now: { [clock] in clock.value }, calendar: { calendar }, locale: locale, doneHold: .seconds(3_600)))
        model.toasts.holdDuration = 3_600
    }

    override func tearDown() {
        model = nil
        library = nil
        store = nil
    }

    private func day(_ offset: Int) -> DueDay {
        DueDay(date: calendar.date(byAdding: .day, value: offset, to: clock.value)!, calendar: calendar)
    }

    @discardableResult
    private func add(_ title: String, due offset: Int? = nil, tab: TasksTab = .now) throws -> UUID {
        model.select(tab: tab)
        model.addBar.text = title
        let id = try XCTUnwrap(model.submitAddBar())
        if let offset { XCTAssertTrue(model.setDueDay(day(offset), for: [id]).isApplied) }
        return id
    }

    // MARK: - The ›

    func testTheOpenButtonShowsOnHoverOrSelectionAndNeverWhileRenaming() {
        typealias Row = AtticTaskRow
        XCTAssertFalse(Row.showsOpenButton(hovered: false, selected: false, renaming: false, opens: true), "at rest")
        XCTAssertTrue(Row.showsOpenButton(hovered: true, selected: false, renaming: false, opens: true), "hovered")
        XCTAssertTrue(Row.showsOpenButton(hovered: false, selected: true, renaming: false, opens: true), "selected")
        XCTAssertFalse(Row.showsOpenButton(hovered: true, selected: true, renaming: true, opens: true), "never while renaming")
        XCTAssertFalse(Row.showsOpenButton(hovered: true, selected: true, renaming: false, opens: false), "nothing to open")
    }

    /// The design's 36 px button 12 px after the date: 18 pt, and the date
    /// slides 24 pt left while it shows.
    func testTheOpenButtonIsEighteenPointsAndTheDateSlidesTwentyFour() {
        XCTAssertEqual(AtticRowOpenMetrics.size, 18)
        XCTAssertEqual(AtticRowOpenMetrics.gap, 6)
        XCTAssertEqual(AtticTaskRow.dateSlide(showsOpen: true), 24)
        XCTAssertEqual(AtticTaskRow.dateSlide(showsOpen: false), 0)
        XCTAssertEqual(AtticShape.controlRadius(height: AtticRowOpenMetrics.size), 9, "a whole superellipse")
    }

    func testOnlyTheSecondClickOfADoubleClickOpens() {
        XCTAssertEqual(AtticTaskRow.clickRoute(clickCount: 1, opens: true), .select, "a click (the title's too) selects")
        XCTAssertEqual(AtticTaskRow.clickRoute(clickCount: 2, opens: true), .open)
        XCTAssertEqual(AtticTaskRow.clickRoute(clickCount: 2, opens: false), .select, "no page: the row's own double-click")
    }

    /// Drawn: the selected row's date ends 24 pt left of an unselected
    /// row's, and the › sits on the row's padding (its right edge 9 pt in
    /// from the highlight's).
    func testTheSelectedRowsDateSlidesLeftByTheOpenButtonsRoom() throws {
        let a = try add("First", due: -1)
        try add("Second", due: -1)
        model.services.openTaskNote = { _ in }
        model.select(tab: .now)
        // The page starts with no selection: select once it is up.
        let probes = try drawn { self.model.selectOnly(a) }
        XCTAssertEqual(model.selection, [a], "still selected when drawn")
        let dates = probes.filter { if case .text(.taskDate, _) = $0.kind { $0.frame != .null } else { false } }
            .sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(dates.count, 2, "both dates drawn")
        let firstTitle = try XCTUnwrap(probes.last { if case .text(.taskTitle, "First") = $0.kind { $0.frame != .null } else { false } })
        let selected = try XCTUnwrap(dates.min { abs($0.frame.midY - firstTitle.frame.midY) < abs($1.frame.midY - firstTitle.frame.midY) })
        let other = try XCTUnwrap(dates.first { $0.id != selected.id })
        XCTAssertEqual(other.frame.maxX - selected.frame.maxX, 24, accuracy: 0.5, "the date makes room for the ›")
    }

    private func drawn(onceUp: () -> Void = {}) throws -> [AtticProbe] {
        let collector = AtticProbeCollector()
        let size = CGSize(width: AtticLayout.panelSize.width, height: 400)
        let page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: size),
                             addBarFocused: .constant(false), pointer: TasksPointer())
        let window = NSPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: page.atticDesign(AtticDesignContext(mode: .light))
            .environment(\.atticCapture, AtticCaptureContext(collector: collector, backdrop: .desktop(.midGrey)))
            .coordinateSpace(name: AtticCaptureContext.coordinateSpace)
            .frame(width: size.width, height: size.height))
        window.orderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        onceUp()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        return collector.all
    }

    // MARK: - Later is the backlog

    func testLaterIsOneListWithoutDateGroups() throws {
        try add("Someday A", tab: .backlog)
        try add("Someday B", tab: .backlog)
        let groups = model.sections(for: .backlog).groups
        XCTAssertEqual(groups.map(\.kind), [.backlog], "one group")
        XCTAssertFalse(try XCTUnwrap(groups.first).showsHeader, "without a header")
        XCTAssertEqual(model.rows(for: .backlog).map(\.model.title).sorted(), ["Someday A", "Someday B"])
        try add("Due", due: 1)
        XCTAssertTrue(model.sections(for: .now).groups.allSatisfy(\.showsHeader), "Now keeps its date groups")
    }

    func testDatingALaterTaskMovesItToNowUnderThatDayAndTheTabFollows() throws {
        let id = try add("Someday", tab: .backlog)
        model.selectOnly(id)
        XCTAssertTrue(model.setDueDay(day(2), for: [id]).isApplied)
        let task = try XCTUnwrap(store.task(withID: id))
        XCTAssertEqual(task.status, .todo, "to Now")
        XCTAssertEqual(task.dueDay, day(2), "under that day")
        XCTAssertEqual(model.tab, .now, "the page follows it, as the design does")
        XCTAssertEqual(model.selection, [id], "still selected there")
        XCTAssertTrue(model.sections(for: .now).groups.contains { $0.ids.contains(id) && $0.kind == .day(day(2)) })
        // One step: Undo puts it back in Later without a date.
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(store.task(withID: id)?.status, .backlog)
        XCTAssertNil(store.task(withID: id)?.dueDay)
    }

    func testMovingATaskToLaterClearsItsDate() throws {
        let id = try add("Dated", due: 3)
        XCTAssertTrue(model.moveToBacklog([id]).isApplied)
        let task = try XCTUnwrap(store.task(withID: id))
        XCTAssertEqual(task.status, .backlog)
        XCTAssertNil(task.dueDay, "a put-off task has no date")
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(store.task(withID: id)?.dueDay, day(3), "Undo brings the date back with the move")
    }

    // MARK: - The next event in Now

    private func event(_ title: String, startHour: Double, hours: Double = 1, allDay: Bool = false) -> CalendarEvent {
        let start = calendar.startOfDay(for: clock.value).addingTimeInterval(startHour * 3_600)
        return CalendarEvent(id: title, title: title, start: start, end: start.addingTimeInterval(hours * 3_600), isAllDay: allDay,
                             location: nil, calendarTitle: "Work", colour: CalendarEventColour(red: 0.2, green: 0.4, blue: 0.9))
    }

    /// The clock's hour (UTC).
    private var hour: Double {
        clock.value.timeIntervalSince(calendar.startOfDay(for: clock.value)) / 3_600
    }

    func testTheNextEventIsTodaysFirstTimedEventNotYetOver() {
        let now = clock.value
        let events = [event("Over", startHour: hour - 2), event("All day", startHour: 0, hours: 24, allDay: true),
                      event("Later on", startHour: hour + 2), event("Soon", startHour: hour + 0.5),
                      event("Tomorrow", startHour: 26)]
        XCTAssertEqual(TasksNextEvent.pick(events, now: now, calendar: calendar)?.title, "Soon")
        XCTAssertNil(TasksNextEvent.pick([event("Over", startHour: hour - 2)], now: now, calendar: calendar))
    }

    @MainActor
    private final class CountingSource: CalendarEventSource {
        var accessState: CalendarAccessState
        var onChange: (@MainActor () -> Void)?
        var events: [CalendarEvent]
        var requests = 0
        init(_ access: CalendarAccessState, events: [CalendarEvent]) {
            accessState = access
            self.events = events
        }
        func requestAccess() async -> CalendarAccessState { requests += 1; return accessState }
        func events(in interval: DateInterval) -> [CalendarEvent] {
            accessState == .granted ? events.filter { $0.overlaps(interval) }.sortedForAgenda() : []
        }
        func search(_ text: String, in interval: DateInterval) -> [CalendarEvent] { [] }
    }

    func testTheRowNeedsAccessAnEventAheadTodayAndTheSwitchAndNeverAsksForAccess() {
        let source = CountingSource(.notDetermined, events: [event("Launch sync", startHour: hour + 1)])
        let calendar = self.calendar
        let feed = TasksNextEventFeed(source: source, now: { [clock] in clock.value }, calendar: { calendar }, locale: locale)
        var shown: [TasksNextEvent?] = []
        feed.onUpdate = { shown.append($0) }
        let enabled = CurrentValueSubject<Bool, Never>(true)
        feed.follow(enabled.eraseToAnyPublisher())
        XCTAssertNil(feed.current, "no access yet: no row")
        XCTAssertEqual(source.requests, 0, "Tasks never asks for Calendar access")
        source.accessState = .granted
        source.onChange?()
        XCTAssertEqual(feed.current?.title, "Launch sync", "access granted: the row")
        XCTAssertEqual(feed.current?.day, day(0))
        enabled.send(false)
        XCTAssertNil(feed.current, "the switch off: no row")
        enabled.send(true)
        source.events = [event("Over", startHour: hour - 2)]
        source.onChange?()
        XCTAssertNil(feed.current, "nothing ahead today: no row")
        XCTAssertEqual(source.requests, 0)
        // Shown, hidden (switch off), shown again (switch on), gone (over):
        // the page hears each change once.
        XCTAssertEqual(shown.map { $0?.title }, ["Launch sync", nil, "Launch sync", nil])
    }

    func testTheNextEventSitsAtTheTopOfTodayEvenWithoutTasksAndOpensThatDay() throws {
        try add("Tomorrow's", due: 1)
        let next = TasksNextEvent(event("Launch sync", startHour: hour + 1), calendar: calendar, locale: locale)
        model.nextEvent = next
        let groups = model.sections(for: .now).groups
        XCTAssertEqual(groups.first?.kind, .today, "Today shows for the event alone")
        XCTAssertEqual(groups.first?.ids, [])
        XCTAssertEqual(model.nextEvent(on: .now), next)
        XCTAssertNil(model.nextEvent(on: .backlog), "Now only")
        var opened: [DueDay] = []
        model.services.openCalendarDay = { opened.append($0) }
        model.openNextEvent()
        XCTAssertEqual(opened, [day(0)], "a click opens that day on the Calendar page")
        model.setSearchQuery("tom", for: .now)
        XCTAssertNil(model.nextEvent(on: .now), "not while Find narrows the list")
    }
}

/// The same, on the hosted page with real clicks.
@MainActor
final class TasksGoingInHostedTests: XCTestCase {
    private var opened: [UUID] = []

    private func hosted() throws -> Hosted {
        var services = TasksPageServices()
        services.openTaskNote = { [weak self] in self?.opened.append($0) }
        return try Hosted(height: 520, keyWindow: false, services: services)
    }

    private func post(_ hosted: Hosted, at point: CGPoint, clickCount: Int) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x, y: hosted.height - point.y), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: hosted.window.windowNumber,
                                           context: nil, eventNumber: 9, clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.postEvent(event, atStart: false)
        }
        Hosted.pumpEvents()
        hosted.spin(0.15)
    }

    private func doubleClick(_ hosted: Hosted, at point: CGPoint) {
        post(hosted, at: point, clickCount: 1)
        post(hosted, at: point, clickCount: 2)
        hosted.spin(0.3)
    }

    /// A dated, undone row on Now and its frame.
    private func datedRow(_ hosted: Hosted) throws -> (id: UUID, frame: CGRect) {
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.trailingDue != nil && $0.status != .done },
                                "the demo has a dated row with its date shown")
        return (row.id, try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .now, id: row.id)]))
    }

    func testADoubleClickOnTheRowOpensThePageButNotOnItsRingOrDate() throws {
        let hosted = try hosted()
        defer { hosted.close() }
        let (id, frame) = try datedRow(hosted)
        let line = frame.minY + TasksRowDesign.paddingY + TasksRowDesign.line / 2
        // The ring takes its own clicks.
        doubleClick(hosted, at: CGPoint(x: frame.minX + AtticLayout.circleX + AtticControlSize.statusCircle / 2, y: line))
        hosted.spin(0.3)
        XCTAssertEqual(opened, [], "a double-click on the ring opens nothing")
        // A single click on the title selects; it opens nothing.
        hosted.model.clearSelection()
        let title = CGPoint(x: frame.minX + TasksDesignMetrics.textX + 8, y: line)
        post(hosted, at: title, clickCount: 1)
        XCTAssertEqual(hosted.model.selection, [id], "a click on the title selects")
        XCTAssertEqual(opened, [], "and opens nothing")
        XCTAssertNil(hosted.model.editingTitleID)
        // The second click of a double-click anywhere else on the row opens it.
        post(hosted, at: title, clickCount: 2)
        hosted.spin(0.3)
        XCTAssertEqual(opened, [id], "a double-click opens the page")
        XCTAssertNil(hosted.model.editingTitleID, "it no longer renames")
        XCTAssertEqual(hosted.model.selection, [id], "the row stays the anchor Back returns to")
        XCTAssertEqual(hosted.model.tab, .now)
        // The date takes its own clicks too (with no selection it is back
        // in its place).
        hosted.model.clearSelection()
        hosted.spin(0.4)
        let dateEnd = frame.maxX - AtticLayout.rowHighlightInset - TasksRowDesign.paddingX - TasksRowDesign.dateInset
        doubleClick(hosted, at: CGPoint(x: dateEnd - 4, y: line))
        XCTAssertEqual(opened, [id], "a double-click on the date opens nothing")
    }

    /// Return renames the selected task and ⇧⌘I opens its page (the keys'
    /// own map; the page's monitor answers ⇧⌘I with the row's Open page).
    func testReturnRenamesAndShiftCommandIOpensThePage() throws {
        func command(_ key: KeyEquivalent, _ characters: String, _ modifiers: EventModifiers) -> AtticTaskKeys.Command? {
            AtticTaskKeys.command(key: key, characters: characters, modifiers: modifiers, listCommands: true)
        }
        XCTAssertEqual(command(.return, "\r", []), .editTitle, "Return renames")
        XCTAssertEqual(command("i", "I", [.command, .shift]), .openPage, "⇧⌘I opens the page")
        XCTAssertEqual(command(.return, "\r", .command), .openPage, "⌘Return still opens it")
        XCTAssertTrue(TasksPage.typingFieldPasses(AtticTaskShortcut.page, composerDraft: "a draft"))
        let hosted = try hosted()
        defer { hosted.close() }
        let (id, _) = try datedRow(hosted)
        let actions = hosted.page.actions(for: id, in: .now)
        AtticTaskKeys.perform(.editTitle, actions)
        XCTAssertEqual(hosted.model.editingTitleID, id)
        hosted.model.cancelEditing()
        AtticTaskKeys.perform(try XCTUnwrap(command("i", "I", [.command, .shift])), actions)
        hosted.spin(0.2)
        XCTAssertEqual(opened, [id])
    }

    /// A real ⇧⌘I on the selected row (the page's key monitor).
    func testARealShiftCommandIOpensTheSelectedRowsPage() throws {
        try requireKeyWindowTests()
        var services = TasksPageServices()
        services.openTaskNote = { [weak self] in self?.opened.append($0) }
        let hosted = try Hosted(height: 520, services: services)
        defer { hosted.close() }
        let (id, _) = try datedRow(hosted)
        try hosted.clickRow(id, tab: .now)
        hosted.press("i", keyCode: 34, modifiers: [.command, .shift])
        hosted.spin(0.3)
        XCTAssertEqual(opened, [id])
    }

    /// The › appears with the selection (the same path as hover): the row
    /// redraws a bounded number of times and settles, and no other row
    /// redraws for it (no layout feedback loop, `hang-report.md`).
    func testShowingTheOpenButtonRedrawsOnlyItsRowAndSettles() throws {
        let hosted = try hosted()
        defer { hosted.close() }
        let (id, _) = try datedRow(hosted)
        hosted.spin(0.5)
        AtticTaskRow.evaluations = [:]
        hosted.model.selectOnly(id)
        hosted.spin(1)
        let settled = AtticTaskRow.evaluations
        XCTAssertLessThanOrEqual(settled[id] ?? 0, 4, "the selected row redraws a few times: \(settled)")
        // A selection change reaches every row's cell once (its key is
        // compared); none of them redraws again for the › or the slide.
        XCTAssertTrue(settled.filter { $0.key != id }.values.allSatisfy { $0 <= 1 }, "other rows at most once: \(settled)")
        hosted.spin(1)
        XCTAssertEqual(AtticTaskRow.evaluations, settled, "and it settles")
    }
}
