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
        let second = try add("Second", due: -1)
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
        // The › itself is drawn, once (the selected row's), 18 pt, on that row.
        // (The pager may draw the shown page's copy twice: every › drawn
        // must be the selected row's.)
        let opens = probes.filter { if case .control("row-open", _, _, _) = $0.kind { $0.frame != .null } else { false } }
        let open = try XCTUnwrap(opens.last { abs($0.frame.midY - firstTitle.frame.midY) < 1 }, "the selected row's › is drawn on its line")
        XCTAssertEqual(open.frame.width, 18, accuracy: 0.5)
        XCTAssertEqual(open.frame.height, 18, accuracy: 0.5)
        XCTAssertGreaterThan(open.frame.minX, selected.frame.maxX, "after the date")
        XCTAssertEqual(AtticTaskRow.drawsOpen[second], false, "none on the other row")
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

    // MARK: - Later's rule on every copy (fix round 1)

    /// Copies of one task (same UUID) inserted directly, as an import
    /// leaves them; `dated` holds a date, the others none.
    private func insertCopies(_ id: UUID, into store: TaskStore, count: Int = 2, dated: Int?, status: TaskStatus = .todo,
                              parentID: UUID? = nil) throws {
        let context = ModelContext(store.container)
        for index in 0..<count {
            let copy = TaskItem(id: id, title: "Copied", status: status, createdAt: clock.value,
                                updatedAt: clock.value.addingTimeInterval(Double(index)), parentID: parentID)
            copy.listOrderVersion = TaskItem.currentListOrderVersion
            if index == dated { copy.dueDay = day(2) }
            context.insert(copy)
        }
        try context.save()
        store.refresh()
    }

    private func copies(_ id: UUID, in store: TaskStore) throws -> [TaskItem] {
        try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
    }

    /// Review 1: whichever copy is shown, moving to Later clears the date
    /// on every copy (a divergent dated copy too).
    func testMovingToLaterClearsTheDateOnEveryCopyWhateverTheShownOneHolds() throws {
        for dated in 0..<2 {
            let store = try makeTestStore(now: { [clock] in clock.value })
            let id = UUID()
            try insertCopies(id, into: store, dated: dated)
            XCTAssertTrue(store.setStatus(.backlog, for: try XCTUnwrap(store.task(withID: id))), "copy \(dated) dated")
            let all = try copies(id, in: store)
            XCTAssertEqual(all.count, 2)
            XCTAssertEqual(all.map(\.status), [.backlog, .backlog], "copy \(dated) dated")
            XCTAssertEqual(all.map(\.dueDayRaw), [nil, nil], "no copy keeps a date in Later (copy \(dated) was dated)")
        }
    }

    /// A move to Later whose save fails leaves every copy as it was.
    func testAFailedMoveToLaterLeavesEveryCopyAsItWas() throws {
        struct Failure: Error {}
        var rejects = false
        let store = try makeTestStore(now: { [clock] in clock.value }, persist: { if rejects { throw Failure() }; try $0.save() })
        let id = UUID()
        try insertCopies(id, into: store, dated: 1)
        let before = try copies(id, in: store).map { [$0.statusRaw, $0.dueDayRaw ?? "-"] }.sorted { $0[1] < $1[1] }
        rejects = true
        XCTAssertFalse(store.setStatus(.backlog, for: try XCTUnwrap(store.task(withID: id))))
        rejects = false
        let after = try copies(id, in: store).map { [$0.statusRaw, $0.dueDayRaw ?? "-"] }.sorted { $0[1] < $1[1] }
        XCTAssertEqual(after, before, "rolled back on every copy")
        XCTAssertEqual(store.task(withID: id)?.status, .todo)
    }

    /// Review 2: a Later task stored with a date (from before the rule)
    /// lists in Now under its day; reading rewrites nothing; its next edit
    /// stores it as Now, keeping the date.
    func testADatedLaterTaskListsInNowAndItsNextEditStoresItThere() throws {
        let id = UUID()
        try insertCopies(id, into: store, count: 1, dated: 0, status: .backlog)
        XCTAssertFalse(model.rows(for: .backlog).contains { $0.id == id }, "not in Later")
        XCTAssertEqual(model.backlogCount, 0)
        XCTAssertTrue(model.sections(for: .now).groups.contains { $0.kind == .day(day(2)) && $0.ids.contains(id) }, "in Now, under its day")
        XCTAssertEqual(model.rows(for: .now).first { $0.id == id }?.status, .todo, "drawn as a Now task")
        XCTAssertEqual(try copies(id, in: store).map(\.status), [.backlog], "nothing rewritten by reading it")
        XCTAssertTrue(library.updateTask(id, title: "Renamed").isApplied)
        let task = try XCTUnwrap(store.task(withID: id))
        XCTAssertEqual(task.status, .todo, "the next write stores it as Now")
        XCTAssertEqual(task.dueDay, day(2), "with its date")
        XCTAssertTrue(model.sections(for: .now).groups.contains { $0.kind == .day(day(2)) && $0.ids.contains(id) })
    }

    /// ⌘B on such a task (it lists in Now) moves it to Later without its date.
    func testMovingADatedLaterTaskToLaterClearsItsDate() throws {
        let id = UUID()
        try insertCopies(id, into: store, count: 1, dated: 0, status: .backlog)
        model.select(tab: .now)
        XCTAssertTrue(model.moveToBacklog([id]).isApplied)
        let task = try XCTUnwrap(store.task(withID: id))
        XCTAssertEqual(task.status, .backlog)
        XCTAssertNil(task.dueDay, "Later has no date")
        XCTAssertTrue(model.rows(for: .backlog).contains { $0.id == id })
    }

    /// `reparentSubtask` to standalone follows the same rule: an undated
    /// open subtask of a Later task stays in Later with no copy dated; a
    /// dated one lists in Now with its date.
    func testASubtaskMadeStandaloneFromALaterTaskFollowsTheLaterRule() throws {
        for dated in 0..<2 {
            let store = try makeTestStore(now: { [clock] in clock.value })
            let context = ModelContext(store.container)
            let parent = TaskItem(title: "Later parent", status: .backlog, createdAt: clock.value)
            parent.listOrderVersion = TaskItem.currentListOrderVersion
            context.insert(parent)
            try context.save()
            let child = UUID()
            try insertCopies(child, into: store, dated: dated, parentID: parent.id)
            let shownDated = try XCTUnwrap(store.task(withID: child)).dueDayRaw != nil
            XCTAssertTrue(store.reparentSubtask(child, to: nil), "copy \(dated) dated")
            let all = try copies(child, in: store)
            XCTAssertTrue(all.allSatisfy { $0.parentID == nil })
            XCTAssertFalse(all.contains { $0.status == .backlog && $0.dueDayRaw != nil }, "no Later copy keeps a date (copy \(dated))")
            let shown = try XCTUnwrap(store.task(withID: child))
            XCTAssertEqual(shown.listedStatus, shownDated ? .todo : .backlog, "dated: Now; undated: Later (copy \(dated))")
        }
        // One dated subtask alone: Now, keeping its date.
        let context = ModelContext(store.container)
        let parent = TaskItem(title: "Later parent", status: .backlog, createdAt: clock.value)
        parent.listOrderVersion = TaskItem.currentListOrderVersion
        context.insert(parent)
        try context.save()
        let child = UUID()
        try insertCopies(child, into: store, count: 1, dated: 0, parentID: parent.id)
        XCTAssertTrue(store.reparentSubtask(child, to: nil))
        let task = try XCTUnwrap(store.task(withID: child))
        XCTAssertEqual(task.status, .todo)
        XCTAssertEqual(task.dueDay, day(2))
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

    /// Review 6: the row moves on when the shown event ends, and at
    /// midnight to the new day's first event (one-shot wake-ups, no polling).
    func testTheRowMovesOnWhenTheShownEventEndsAndAtMidnight() throws {
        let start = calendar.startOfDay(for: clock.value)
        let source = CountingSource(.granted, events: [event("First", startHour: hour + 0.5), event("Second", startHour: hour + 2),
                                                       event("Tomorrow", startHour: 24 + 9)])
        let calendar = self.calendar
        let feed = TasksNextEventFeed(source: source, now: { [clock] in clock.value }, calendar: { calendar }, locale: locale)
        var shown: [String?] = []
        feed.onUpdate = { shown.append($0?.title) }
        let firstEnd = start.addingTimeInterval((hour + 1.5) * 3_600)
        let secondEnd = start.addingTimeInterval((hour + 3) * 3_600)
        let midnight = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
        feed.setEnabled(true)
        XCTAssertEqual(feed.current?.title, "First")
        XCTAssertEqual(try XCTUnwrap(feed.nextWake).timeIntervalSince(firstEnd), 1, accuracy: 0.01, "wakes as it ends")
        clock.value = firstEnd.addingTimeInterval(1)
        feed.wakeNow()
        XCTAssertEqual(feed.current?.title, "Second", "the event's end: the next one")
        XCTAssertEqual(try XCTUnwrap(feed.nextWake).timeIntervalSince(secondEnd), 1, accuracy: 0.01)
        clock.value = secondEnd.addingTimeInterval(1)
        feed.wakeNow()
        XCTAssertNil(feed.current, "nothing more today")
        XCTAssertEqual(try XCTUnwrap(feed.nextWake).timeIntervalSince(midnight), 1, accuracy: 0.01, "wakes at midnight")
        clock.value = midnight.addingTimeInterval(1)
        feed.wakeNow()
        XCTAssertEqual(feed.current?.title, "Tomorrow", "midnight: the new day's first event")
        XCTAssertEqual(feed.current?.day, DueDay(date: midnight, calendar: calendar))
        XCTAssertEqual(shown, ["First", "Second", nil, "Tomorrow"], "each change heard once")
        XCTAssertEqual(source.requests, 0)
    }

    /// Minor 7: the time's grey is the design's rgb(86,88,92), between the
    /// header's and the date's, through the see-through tone path.
    func testTheNextEventTimeIsTheDesignsOwnGrey() {
        let colour = TasksDesignTone.nextEventTime.designColour
        XCTAssertEqual([colour.red, colour.green, colour.blue].map { ($0 * 255).rounded() }, [86, 88, 92])
        let tones = TasksDesignTone.allCases
        XCTAssertEqual(tones.firstIndex(of: .nextEventTime), tones.firstIndex(of: .groupHeader)! + 1)
        XCTAssertEqual(tones.firstIndex(of: .nextEventTime), tones.firstIndex(of: .date)! - 1)
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

    /// Tracking areas the pointer is inside (hover tests).
    private var insideAreas: Set<ObjectIdentifier> = []

    /// The pointer over a point of the page (nil: off every row): each
    /// tracking area's owner hears it enter, move and leave, as AppKit
    /// tells them when the real pointer moves.
    private func hover(_ hosted: Hosted, at point: CGPoint?) throws {
        let content = try XCTUnwrap(hosted.window.contentView)
        content.layoutSubtreeIfNeeded()
        let location = point.map { CGPoint(x: $0.x, y: hosted.height - $0.y) } ?? CGPoint(x: -40, y: -40)
        let now = ProcessInfo.processInfo.systemUptime, window = hosted.window.windowNumber
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let moved = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: now,
                                                     windowNumber: window, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        for view in views(content) {
            for area in view.trackingAreas {
                guard let owner = area.owner as? NSResponder else { continue }
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                let inside = rect.contains(view.convert(location, from: nil))
                let key = ObjectIdentifier(area)
                func edge(_ type: NSEvent.EventType) -> NSEvent? {
                    NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [], timestamp: now, windowNumber: window,
                                           context: nil, eventNumber: 0, trackingNumber: unsafeBitCast(area, to: Int.self),
                                           userData: nil)
                }
                if inside, !insideAreas.contains(key), area.options.contains(.mouseEnteredAndExited), let event = edge(.mouseEntered) {
                    insideAreas.insert(key)
                    owner.mouseEntered(with: event)
                } else if !inside, insideAreas.contains(key), let event = edge(.mouseExited) {
                    insideAreas.remove(key)
                    owner.mouseExited(with: event)
                }
                if inside, area.options.contains(.mouseMoved) { owner.mouseMoved(with: moved) }
            }
        }
        hosted.spin(0.6)
    }

    /// Review 6: the › appears with the selection: it is drawn (one), its
    /// row redraws (at least once, a bounded number of times), no other row
    /// redraws for it, and the page settles (no layout feedback loop,
    /// `hang-report.md`).
    func testShowingTheOpenButtonRedrawsOnlyItsRowAndSettles() throws {
        let hosted = try hosted()
        defer { hosted.close() }
        let (id, _) = try datedRow(hosted)
        hosted.spin(0.5)
        XCTAssertNotEqual(AtticTaskRow.drawsOpen[id], true, "no › at rest")
        AtticTaskRow.evaluations = [:]
        hosted.model.selectOnly(id)
        hosted.spin(1)
        let settled = AtticTaskRow.evaluations
        XCTAssertEqual(AtticTaskRow.drawsOpen[id], true, "the selected row draws its ›")
        XCTAssertTrue((1...4).contains(settled[id] ?? 0), "the selected row redraws, a few times: \(settled)")
        // A selection change reaches every row's cell once (its key is
        // compared); none of them redraws again for the › or the slide.
        XCTAssertTrue(settled.filter { $0.key != id }.values.allSatisfy { $0 <= 1 }, "other rows at most once: \(settled)")
        hosted.spin(1)
        XCTAssertEqual(AtticTaskRow.evaluations, settled, "and it settles")
        hosted.model.clearSelection()
        hosted.spin(0.6)
        XCTAssertEqual(AtticTaskRow.drawsOpen[id], false, "gone with the selection")
    }

    /// Review 6: hover entry and exit, each bounded on its own: only the
    /// hovered row redraws, the › comes and goes, and each settles.
    func testHoverEntryAndExitEachRedrawOnlyTheRowAndSettle() throws {
        let hosted = try hosted()
        defer { hosted.close() }
        let (id, frame) = try datedRow(hosted)
        hosted.model.clearSelection()
        try hover(hosted, at: nil)
        hosted.spin(0.5)
        XCTAssertNotEqual(AtticTaskRow.drawsOpen[id], true, "no › at rest")
        // Entry.
        AtticTaskRow.evaluations = [:]
        try hover(hosted, at: CGPoint(x: frame.midX, y: frame.minY + TasksRowDesign.paddingY + TasksRowDesign.line / 2))
        let entered = AtticTaskRow.evaluations
        XCTAssertEqual(AtticTaskRow.drawsOpen[id], true, "hovered: its › is drawn")
        XCTAssertTrue((1...4).contains(entered[id] ?? 0), "the hovered row redraws, a few times: \(entered)")
        XCTAssertTrue(entered.filter { $0.key != id }.values.allSatisfy { $0 == 0 }, "no other row: \(entered)")
        hosted.spin(0.6)
        XCTAssertEqual(AtticTaskRow.evaluations, entered, "entry settles")
        // Exit.
        AtticTaskRow.evaluations = [:]
        try hover(hosted, at: nil)
        let left = AtticTaskRow.evaluations
        XCTAssertEqual(AtticTaskRow.drawsOpen[id], false, "left: the › goes")
        XCTAssertTrue((1...4).contains(left[id] ?? 0), "the row redraws once more, a few times: \(left)")
        XCTAssertTrue(left.filter { $0.key != id }.values.allSatisfy { $0 == 0 }, "no other row: \(left)")
        hosted.spin(0.6)
        XCTAssertEqual(AtticTaskRow.evaluations, left, "exit settles")
    }

    // MARK: - Done (review 3)

    /// Done's rows go in the same way: the ›, a double-click and ⇧⌘I open
    /// the task's page; its details stay in the menu.
    func testDoneRowsOpenTheirPageLikeNowAndLater() throws {
        let hosted = try hosted()
        defer { hosted.close() }
        hosted.go(to: .done)
        let row = try XCTUnwrap(hosted.model.doneDays().flatMap(\.rows).first, "the demo has a Done row")
        let frame = try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .done, id: row.id)])
        // ⇧⌘I (the page's key and the row's own map to Open page).
        hosted.page.actions(for: row.id, in: .done).openPage()
        hosted.spin(0.3)
        XCTAssertEqual(opened, [row.id], "⇧⌘I opens a Done task's page")
        XCTAssertNil(hosted.model.doneDetailID, "not its details")
        // A double-click on its title.
        hosted.model.clearSelection()
        let line = frame.minY + TasksRowDesign.paddingY + TasksRowDesign.line / 2
        doubleClick(hosted, at: CGPoint(x: frame.minX + TasksDesignMetrics.textX + 8, y: line))
        XCTAssertEqual(opened, [row.id, row.id], "a double-click opens it")
        XCTAssertNil(hosted.model.editingTitleID, "and no longer renames")
        // Selected, its › shows.
        hosted.model.selectOnly(row.id)
        hosted.spin(0.6)
        XCTAssertEqual(AtticTaskRow.drawsOpen[row.id], true, "the › on a selected Done row")
        // The menu: Open Page with ⌘Return; Show Details still there.
        let commands = hosted.page.taskCommands(row.id, tab: .done)
        let titles = AtticMenuCommand.titles(in: commands)
        XCTAssertTrue(titles.contains("Open Page"), "\(titles)")
        XCTAssertTrue(titles.contains("Show Details"), "its details stay reachable: \(titles)")
        XCTAssertEqual(AtticMenuCommand.keyOwner(for: AtticTaskShortcut.openPage, in: commands)?.title, "Open Page")
    }

    // MARK: - Back (review 5)

    /// Opening one of several selected tasks and coming Back (the host's
    /// own calls: the page hides, then returns with its anchor row) keeps
    /// the whole selection, the tab and the scroll position.
    func testBackFromOneOfSeveralSelectedKeepsTheSelectionTabAndScroll() throws {
        var services = TasksPageServices()
        services.openTaskNote = { [weak self] in self?.opened.append($0) }
        let hosted = try Hosted(height: 520, long: true, services: services)
        defer { hosted.close() }
        let list = try XCTUnwrap(hosted.lists(in: try XCTUnwrap(hosted.window.contentView)).first {
            let frame = $0.convert($0.bounds, to: nil)
            return frame.minX > -1 && frame.minX < 100 && frame.height > 200
        }, "the shown page's list")
        list.contentView.scroll(to: NSPoint(x: 0, y: 120))
        list.reflectScrolledClipView(list.contentView)
        hosted.spin(0.6)
        let offset = list.contentView.bounds.origin.y
        XCTAssertGreaterThan(offset, 60, "scrolled")
        let visible = hosted.model.rows(for: .now).map(\.id).filter { id in
            guard let frame = hosted.pointer.frames[TasksRowID(tab: .now, id: id)] else { return false }
            return frame.minY > 80 && frame.maxY < hosted.height - 120
        }
        XCTAssertGreaterThanOrEqual(visible.count, 3, "rows on screen")
        let ids = Array(visible.prefix(3))
        hosted.model.selectOnly(ids[0])
        hosted.model.extendSelection(to: ids[2], visible: hosted.model.rows(for: .now).map(\.id))
        let selection = hosted.model.selection
        XCTAssertEqual(selection.count, 3)
        // The › (and ⇧⌘I, and a double-click's second click) on the middle one.
        hosted.page.actions(for: ids[1], in: .now).openPage()
        hosted.spin(0.3)
        XCTAssertEqual(opened, [ids[1]])
        XCTAssertEqual(hosted.model.selection, selection, "opening keeps the selection")
        // Covered by the page, then Back (TasksPageHost's calls).
        hosted.model.isPageShown = false
        hosted.spin(0.3)
        hosted.model.isPageShown = true
        hosted.model.pageDidReturn()
        hosted.model.requestReturnFocus(ids[1])
        hosted.spin(0.8)
        XCTAssertEqual(hosted.model.selection, selection, "Back keeps the whole selection")
        XCTAssertEqual(hosted.model.tab, .now, "and the tab")
        XCTAssertEqual(list.contentView.bounds.origin.y, offset, accuracy: 1, "and the scroll position")
    }
}

/// The page-becomes-current refresh of the next event (review 6), through
/// the shell's own host.
@MainActor
final class TasksNextEventHostTests: XCTestCase {
    @MainActor
    private final class Source: CalendarEventSource {
        var accessState: CalendarAccessState = .notDetermined
        var onChange: (@MainActor () -> Void)?
        var events: [CalendarEvent] = []
        var requests = 0
        func requestAccess() async -> CalendarAccessState { requests += 1; return accessState }
        func events(in interval: DateInterval) -> [CalendarEvent] {
            accessState == .granted ? events.filter { $0.overlaps(interval) }.sortedForAgenda() : []
        }
        func search(_ text: String, in interval: DateInterval) -> [CalendarEvent] { [] }
    }

    private final class Current: ObservableObject { @Published var value = true }

    private struct Shell: View {
        @ObservedObject var current: Current
        let make: (Bool) -> TasksPageHost
        var body: some View { make(current.value) }
    }

    func testAccessGrantedElsewhereShowsTheRowWhenTasksBecomesCurrent() throws {
        let suite = "NextEventHost.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = try makeTestStore()
        let source = Source()
        let soon = Date().addingTimeInterval(600)
        let calendar = CalendarMonthMath.calendar()
        let end = min(soon.addingTimeInterval(600), calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!)
        guard end > soon else { throw XCTSkip("too close to midnight for an event ahead today") }
        source.events = [CalendarEvent(id: "e", title: "Launch sync", start: soon, end: end, isAllDay: false, location: nil,
                                       calendarTitle: "Work", colour: CalendarEventColour(red: 0.2, green: 0.4, blue: 0.9))]
        let feed = TasksNextEventFeed(source: source, calendar: { calendar })
        let state = TasksPageState(nextEventFeed: feed)
        let current = Current()
        let size = CGSize(width: AtticLayout.panelSize.width, height: 520)
        let shell = Shell(current: current) { isCurrent in
            TasksPageHost(store: store, uiState: PanelUIState(), settings: AppSettings(defaults: defaults), state: state,
                          layout: PanelPageLayout(cornerSize: 24, panelSize: size), chromeInteractionState: PanelChromeInteractionState(),
                          primaryInputFocusRequest: 0, isCurrent: isCurrent)
        }
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: shell.frame(width: size.width, height: size.height))
        window.orderFront(nil)
        defer { window.close() }
        func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        spin(0.6)
        let model = state.model(for: store, toasts: nil)
        XCTAssertNil(model.nextEvent, "no access: no row")
        current.value = false
        spin(0.3)
        // Access granted on the Calendar page (its own source: no change
        // reaches this feed).
        source.accessState = .granted
        spin(0.3)
        XCTAssertNil(model.nextEvent, "hidden: not read yet")
        current.value = true
        spin(0.6)
        XCTAssertEqual(model.nextEvent?.title, "Launch sync", "Tasks current again: the row")
        XCTAssertEqual(source.requests, 0, "Tasks never asks")
    }
}
