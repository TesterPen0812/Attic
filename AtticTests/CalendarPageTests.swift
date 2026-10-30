import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// The Calendar page (owner's panel design, 28 Oct): the month grid's
/// Monday-first math and key states, the pinned week, the agenda's grouping
/// and order, search across dates, and a page that updates a bounded number
/// of times with no layout loop.
@MainActor
final class CalendarPageTests: XCTestCase {
    private let calendar = CalendarMonthMath.calendar(timeZone: TimeZone(identifier: "Europe/London")!)

    private func day(_ y: Int, _ m: Int, _ d: Int) -> DueDay { DueDay(year: y, month: m, day: d)! }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func event(_ id: String, _ title: String, start: Date, end: Date, allDay: Bool = false,
                       location: String? = nil) -> CalendarEvent {
        CalendarEvent(id: id, title: title, start: start, end: end, isAllDay: allDay, location: location,
                      calendarTitle: "Home", colour: CalendarEventColour(red: 0.2, green: 0.5, blue: 0.9))
    }

    // MARK: - Month and week math

    func testOctober2026StartsOnMondayTheTwentyEighthOfSeptember() {
        let weeks = CalendarMonthMath.weeks(for: CalendarMonth(year: 2026, month: 10), today: day(2026, 10, 29),
                                            selected: day(2026, 10, 31), calendar: calendar)
        XCTAssertEqual(weeks.count, 5)
        XCTAssertEqual(weeks.first?.days.first?.day, day(2026, 9, 28), "Monday first")
        XCTAssertEqual(weeks.last?.days.last?.day, day(2026, 11, 1))
        XCTAssertTrue(weeks.allSatisfy { $0.days.count == 7 })
        XCTAssertEqual(weeks[0].days.prefix(3).map(\.isInMonth), [false, false, false], "Sep 28–30 are September's")
        XCTAssertTrue(weeks[0].days[3].isInMonth)
        XCTAssertFalse(weeks[4].days[6].isInMonth, "1 Nov is November's")
        XCTAssertEqual(CalendarMonthMath.weekdayIndex(of: day(2026, 11, 1), calendar: calendar), 6, "Sunday is last")
    }

    func testMonthEdgesGiveFourToSixWeeks() {
        // February 2027 starts on a Monday and has 28 days: exactly 4 rows.
        XCTAssertEqual(CalendarMonthMath.weeks(for: CalendarMonth(year: 2027, month: 2), today: day(2027, 2, 1),
                                               selected: day(2027, 2, 1), calendar: calendar).count, 4)
        // August 2027 starts on a Sunday and has 31 days: 6 rows.
        XCTAssertEqual(CalendarMonthMath.weeks(for: CalendarMonth(year: 2027, month: 8), today: day(2027, 8, 1),
                                               selected: day(2027, 8, 1), calendar: calendar).count, 6)
        XCTAssertEqual(CalendarMonth(year: 2026, month: 13), CalendarMonth(year: 2027, month: 1))
        XCTAssertEqual(CalendarMonth(year: 2026, month: 0), CalendarMonth(year: 2025, month: 12))
    }

    func testTodayPastAndSelectedKeys() {
        let weeks = CalendarMonthMath.weeks(for: CalendarMonth(year: 2026, month: 10), today: day(2026, 10, 29),
                                            selected: day(2026, 10, 31), calendar: calendar)
        let days = Dictionary(uniqueKeysWithValues: weeks.flatMap(\.days).map { ($0.day, $0) })
        XCTAssertEqual(days[day(2026, 10, 28)]?.style, .flat, "past days are flat")
        XCTAssertEqual(days[day(2026, 10, 29)]?.style, .raised, "today onward is raised")
        XCTAssertEqual(days[day(2026, 10, 29)]?.isToday, true)
        XCTAssertEqual(days[day(2026, 10, 30)]?.style, .raised)
        XCTAssertEqual(days[day(2026, 10, 31)]?.style, .selected, "selected is the ink key")
        let onToday = CalendarMonthMath.weeks(for: CalendarMonth(year: 2026, month: 10), today: day(2026, 10, 29),
                                              selected: day(2026, 10, 29), calendar: calendar)
        XCTAssertEqual(onToday.flatMap(\.days).first { $0.day == day(2026, 10, 29) }?.style, .selectedToday,
                       "selected today is the red key")
        let raised = weeks.flatMap(\.days).filter { $0.isInMonth && $0.style == .raised }
        XCTAssertEqual(raised.count, 2, "29 and 30 Oct (31 is selected)")
    }

    func testPinnedWeekAndWeekViewOffsets() {
        let weeks = CalendarMonthMath.weeks(for: CalendarMonth(year: 2026, month: 10), today: day(2026, 10, 29),
                                            selected: day(2026, 10, 31), calendar: calendar)
        XCTAssertEqual(CalendarMonthMath.pinnedWeekIndex(weeks), 4)
        let first = CalendarMonthMath.weeks(for: CalendarMonth(year: 2026, month: 10), today: day(2026, 10, 29),
                                            selected: day(2026, 10, 1), calendar: calendar)
        XCTAssertEqual(CalendarMonthMath.pinnedWeekIndex(first), 0)
        // 30 pt keys, 1 above and 3.5 below: 34.5 a row.
        XCTAssertEqual(CalendarDesign.weekPitch, 34.5)
        XCTAssertFalse(CalendarMonthMath.isPinned(offset: 4 * 34.5, pinnedIndex: 4))
        XCTAssertTrue(CalendarMonthMath.isPinned(offset: 4 * 34.5 + 1, pinnedIndex: 4))
        XCTAssertFalse(CalendarMonthMath.isPinned(offset: 0, pinnedIndex: 0))
        XCTAssertTrue(CalendarMonthMath.isPinned(offset: 1, pinnedIndex: 0))
        XCTAssertEqual(CalendarMonthMath.weekViewOffset(weekCount: 5), 4 * 34.5 + 4)
        XCTAssertTrue(CalendarMonthMath.isWeekView(offset: 142, weekCount: 5))
        XCTAssertFalse(CalendarMonthMath.isWeekView(offset: 100, weekCount: 5))
    }

    func testPreviousAndNextMoveByMonthOrWeek() {
        let today = day(2026, 10, 29)
        XCTAssertEqual(CalendarMonthMath.shifted(today, by: 1, weekView: false, today: today, calendar: calendar), day(2026, 11, 1))
        XCTAssertEqual(CalendarMonthMath.shifted(day(2026, 11, 20), by: -1, weekView: false, today: today, calendar: calendar),
                       today, "back to today's month lands on today")
        XCTAssertEqual(CalendarMonthMath.shifted(day(2026, 12, 3), by: 1, weekView: false, today: today, calendar: calendar),
                       day(2027, 1, 1))
        XCTAssertEqual(CalendarMonthMath.shifted(today, by: 1, weekView: true, today: today, calendar: calendar), day(2026, 11, 5))
        XCTAssertEqual(CalendarMonthMath.shifted(today, by: -1, weekView: true, today: today, calendar: calendar), day(2026, 10, 22))
    }

    // MARK: - Agenda

    func testAgendaGroupsSevenDaysInOrder() {
        let today = day(2026, 10, 29)
        let clock = CalendarAgenda.Clock(today: today, now: date(2026, 10, 29, 12, 0))
        let events = [
            event("late", "Dinner", start: date(2026, 10, 29, 19), end: date(2026, 10, 29, 21), location: "Home"),
            event("early", "Standup", start: date(2026, 10, 29, 9), end: date(2026, 10, 29, 9, 30)),
            event("allday", "Holiday", start: date(2026, 10, 29), end: date(2026, 10, 30), allDay: true),
            event("next", "Dentist", start: date(2026, 10, 31, 10), end: date(2026, 10, 31, 11)),
        ]
        let tasks = [
            CalendarTaskEntry(id: UUID(), title: "Due today", due: today, isOpen: true),
            CalendarTaskEntry(id: UUID(), title: "Overdue", due: day(2026, 10, 20), isOpen: true),
            CalendarTaskEntry(id: UUID(), title: "Overdue but done", due: day(2026, 10, 21), isOpen: false),
        ]
        let groups = CalendarAgenda.groups(selected: today, clock: clock, events: events, tasks: tasks, calendar: calendar)
        XCTAssertEqual(groups.map(\.day), (0..<7).map { CalendarMonthMath.adding(days: $0, to: today, calendar: calendar) })
        XCTAssertEqual(groups.map(\.relative), [.today, .tomorrow, nil, nil, nil, nil, nil])
        XCTAssertEqual(groups[0].items.map(\.id), [
            "event-allday", "task-" + tasks[1].id.uuidString, "task-" + tasks[0].id.uuidString,
            "event-early", "now", "event-late",
        ], "all-day, overdue first, today's tasks, then timed events around the now line")
        XCTAssertTrue(groups[1].items.isEmpty, "a free day shows its tile alone")
        XCTAssertEqual(groups[2].items.map(\.id), ["event-next"], "no now line away from today")
    }

    func testDayMarksDotsAndRing() {
        let events = (0..<5).map { event("e\($0)", "E\($0)", start: date(2026, 10, 30, 8 + $0), end: date(2026, 10, 30, 9 + $0)) }
        let tasks = [CalendarTaskEntry(id: UUID(), title: "Open", due: day(2026, 10, 30), isOpen: true),
                     CalendarTaskEntry(id: UUID(), title: "Done", due: day(2026, 10, 31), isOpen: false)]
        let marks = CalendarAgenda.marks(for: [day(2026, 10, 30), day(2026, 10, 31), day(2026, 11, 1)],
                                         events: events, tasks: tasks, calendar: calendar)
        XCTAssertEqual(marks[day(2026, 10, 30)]?.eventColours.count, 3, "at most three dots")
        XCTAssertEqual(marks[day(2026, 10, 30)]?.hasOpenTasks, true)
        XCTAssertNil(marks[day(2026, 10, 31)], "a done task leaves no ring")
        XCTAssertNil(marks[day(2026, 11, 1)])
    }

    func testAllDayEventEndingAtMidnightStaysOnItsDay() {
        let allDay = event("a", "Trip", start: date(2026, 10, 30), end: date(2026, 10, 31), allDay: true)
        XCTAssertEqual(CalendarAgenda.events(on: day(2026, 10, 30), in: [allDay], calendar: calendar).count, 1)
        XCTAssertEqual(CalendarAgenda.events(on: day(2026, 10, 31), in: [allDay], calendar: calendar).count, 0)
    }

    // MARK: - Search

    func testSearchListsOnlyMatchingDaysInDateOrder() {
        let today = day(2026, 10, 29)
        let clock = CalendarAgenda.Clock(today: today, now: date(2026, 10, 29, 12))
        let matching = [event("b", "Dentist", start: date(2027, 3, 2, 9), end: date(2027, 3, 2, 10)),
                        event("a", "Dentist", start: date(2026, 1, 5, 9), end: date(2026, 1, 5, 10))]
        let open = CalendarTaskEntry(id: UUID(), title: "Call the dentist", due: day(2026, 11, 4), isOpen: true)
        let done = CalendarTaskEntry(id: UUID(), title: "Pay dentist", due: day(2026, 11, 5), isOpen: false)
        let other = CalendarTaskEntry(id: UUID(), title: "Groceries", due: day(2026, 11, 6), isOpen: true)
        let groups = CalendarAgenda.searchGroups(query: " dentist ", clock: clock, matchingEvents: matching,
                                                 tasks: [open, done, other], calendar: calendar)
        XCTAssertEqual(groups.map(\.day), [day(2026, 1, 5), day(2026, 11, 4), day(2027, 3, 2)])
        XCTAssertFalse(groups.contains { $0.items.contains(.now) }, "no now line in results")
        XCTAssertTrue(CalendarAgenda.searchGroups(query: "  ", clock: clock, matchingEvents: matching, tasks: [open],
                                                  calendar: calendar).isEmpty)
        let window = CalendarAgenda.searchInterval(today: today, calendar: calendar)!
        XCTAssertEqual(window.start, date(2025, 10, 29))
        XCTAssertEqual(window.end, date(2028, 10, 29))
    }

    func testModelSearchesEventsAndOpenTasksAndShowsNoMatches() async throws {
        let store = try makeTestStore()
        _ = store.commit([TaskDraft(title: "Book flights", dueDay: day(2026, 12, 1)),
                          TaskDraft(title: "Book done", dueDay: day(2026, 12, 2), status: .done)])
        let source = CalendarEventSourceStub(events: [event("x", "Flight to Rome", start: date(2027, 1, 10, 8),
                                                            end: date(2027, 1, 10, 11), location: "LHR")])
        let model = CalendarPageModel(store: store, source: source, calendar: calendar, now: { self.date(2026, 10, 29, 12) })
        model.setQuery("book")
        XCTAssertEqual(model.searchText, "book")
        XCTAssertFalse(model.snapshot.isSearching, "the agenda waits for the typing to pause")
        model.commitSearch()
        XCTAssertEqual(model.snapshot.groups.map(\.day), [day(2026, 12, 1)], "only open tasks")
        model.setQuery("lhr")
        model.commitSearch()
        XCTAssertEqual(model.snapshot.groups.map(\.day), [day(2027, 1, 10)], "events match on location too")
        model.setQuery("zzz")
        model.commitSearch()
        XCTAssertTrue(model.snapshot.showsNoMatches)
        model.setQuery("")
        XCTAssertFalse(model.snapshot.isSearching, "clearing applies at once")
        XCTAssertEqual(model.snapshot.groups.count, CalendarAgenda.dayCount)
    }

    func testSameTaskAppearsOnceInNotesAndCalendarSearch() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        let task = TaskItem(title: "Book the boathouse")
        task.dueDay = day(2026, 12, 1)
        context.insert(task)
        try context.save()
        let notes = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()))
        let id = UUID()
        _ = try notes.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Old compatibility title"), .text("Call the venue")]), taskOwner: task.id).get()
        let tasks = TaskStore(container: container)
        let matches = try await notes.searchNoteIDs(matching: "boathouse")
        XCTAssertEqual(matches, [id])
        let library = NotesLibraryModel(search: { try await notes.searchNoteIDs(matching: $0) }, store: notes, taskStore: tasks)
        let row = try XCTUnwrap(library.groups(store: notes, drafts: []).flatMap(\.rows).first { $0.id == id })
        XCTAssertEqual(library.preparedRow(row, store: notes).title, task.title)
        let model = CalendarPageModel(store: tasks, source: CalendarEventSourceStub(), calendar: calendar,
                                      now: { self.date(2026, 10, 29, 12) })
        model.setQuery("boathouse"); model.commitSearch()
        let results = model.snapshot.groups.flatMap(\.items)
        XCTAssertEqual(results.map(\.id), ["task-" + task.id.uuidString])
        guard case let .task(result) = try XCTUnwrap(results.first) else { return XCTFail("the matching task") }
        XCTAssertEqual(result.title, task.title)
        XCTAssertEqual(result.row.title, task.title)
    }

    func testCalendarMenuUsesTheSharedRemovalRuleAndRoutesOpenAndFiles() throws {
        let id = UUID(), state = PanelUIState()
        state.selectSection(.calendar)
        var removed: [UUID] = [], files: [UUID] = []
        let actions = CalendarTaskRowActions(toggleDone: { _ in }, open: {
            state.openTaskNote($0, from: .calendar, row: $0, backTitle: "Back to Calendar")
        }, removeFromTasks: { removed.append($0) }, canRemoveFromTasks: { _ in true }, addFiles: { files.append($0) })
        let menu = actions.commands(for: id)
        XCTAssertEqual(menu.map(\.title), ["Open Page", "More", "Remove from Tasks"])
        XCTAssertEqual(menu[0].shortcut, AtticTaskShortcut.openPage)
        XCTAssertEqual(AtticMenuSymbols.rowsWithoutIcons(menu), [])
        menu[0].action()
        XCTAssertEqual(state.taskNoteOrigin, .calendar)
        XCTAssertEqual(PanelPage(state.selectedSection), .calendar)
        XCTAssertEqual(state.taskNoteBackTitle, "Back to Calendar")
        try XCTUnwrap(menu.first { $0.title == "Remove from Tasks" }).action()
        try XCTUnwrap(menu.first { $0.title == "More" }?.children.first { $0.title == "Add Files…" }).action()
        XCTAssertEqual(removed, [id]); XCTAssertEqual(files, [id])
        var bare = actions
        bare.canRemoveFromTasks = { _ in false }
        XCTAssertFalse(bare.commands(for: id).contains { $0.title == "Remove from Tasks" })
    }

    func testCalendarRowKeepsClickEntryAndCommandReturnOpensItsPage() throws {
        let id = UUID(), today = day(2026, 10, 29)
        let task = CalendarTaskEntry(id: id, title: "A Calendar task", due: today, isOpen: true)
        var opened: [UUID] = []
        let actions = CalendarTaskRowActions(toggleDone: { _ in }, open: { opened.append($0) })
        let group = CalendarAgenda.groups(selected: today, clock: .init(today: today, now: date(2026, 10, 29, 12)),
            events: [], tasks: [task], calendar: calendar)[0]
        let row = CalendarAgendaDay(group: group, today: today, taskActions: actions, onSelectDay: { _ in }).taskRow(task)
        XCTAssertNil(row.onSelect, "base wiring: the row click falls back to Open Page")
        (row.onSelect ?? row.actions.openPage)()
        XCTAssertNotNil(row.onOpenTitle)
        row.onOpenTitle?()
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        // The row's shared focused-key dispatcher, using this Calendar row's actions.
        let command = try XCTUnwrap(AtticTaskKeys.command(key: .return, characters: event.characters ?? "",
            modifiers: EventModifiers(event.modifierFlags), listCommands: true))
        XCTAssertTrue(AtticTaskKeys.offers(command, row.actions))
        AtticTaskKeys.perform(command, row.actions)
        XCTAssertEqual(opened, [id, id, id], "row click, title click and ⌘Return share the Calendar route")
    }

    func testTypingIsDebouncedIntoOneSearch() async throws {
        let store = try makeTestStore()
        let model = CalendarPageModel(store: store, source: CalendarEventSourceStub(), calendar: calendar,
                                      now: { self.date(2026, 10, 29, 12) })
        let fetches = model.sourceFetches
        for prefix in ["d", "de", "den", "dent"] { model.setQuery(prefix) }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.snapshot.query, "dent")
        XCTAssertEqual(model.sourceFetches - fetches, 1, "one search for the whole word")
    }

    // MARK: - Model updates

    func testModelPublishesOnlyRealChangesAndCachesEvents() throws {
        let store = try makeTestStore()
        let source = CalendarEventSourceStub(events: [event("e", "Gym", start: date(2026, 10, 30, 7), end: date(2026, 10, 30, 8))])
        let model = CalendarPageModel(store: store, source: source, calendar: calendar, now: { self.date(2026, 10, 29, 12) })
        let published = model.publishCount, fetches = model.sourceFetches
        model.rebuild()
        model.select(model.snapshot.selected)
        XCTAssertEqual(model.publishCount, published, "nothing changed: nothing published")
        XCTAssertEqual(model.sourceFetches, fetches, "the same range is not fetched again")
        model.select(day(2026, 10, 30))
        XCTAssertEqual(model.publishCount, published + 1)
        XCTAssertEqual(model.snapshot.pinnedWeekIndex, 4)
        let afterSelect = model.sourceFetches
        source.replace([])
        XCTAssertEqual(model.sourceFetches, afterSelect + 1, "a source change fetches again")
        XCTAssertTrue(model.snapshot.weeks.flatMap(\.days).allSatisfy { $0.marks.eventColours.isEmpty })
    }

    func testWithoutAccessOnlyTasksShow() throws {
        let store = try makeTestStore()
        _ = store.commit([TaskDraft(title: "Return parcel", dueDay: day(2026, 10, 29))])
        let source = CalendarEventSourceStub(accessState: .denied,
                                             events: [event("e", "Gym", start: date(2026, 10, 29, 7), end: date(2026, 10, 29, 8))])
        let model = CalendarPageModel(store: store, source: source, calendar: calendar, now: { self.date(2026, 10, 29, 12) })
        let ids = model.snapshot.groups[0].items.map(\.id)
        XCTAssertEqual(ids.count, 2, "the task and the now line")
        XCTAssertFalse(ids.contains { $0.hasPrefix("event-") })
    }

    func testCalendarIsTheThirdPage() {
        XCTAssertEqual(PanelPage.allCases, [.tasks, .notes, .calendar, .canvas])
        XCTAssertEqual(PanelPage(.calendar), .calendar)
        XCTAssertEqual(PanelPage.calendar.section, .calendar)
        XCTAssertEqual(PanelPage.calendar.keyEquivalent, "3")
        XCTAssertNil(PanelSection.calendar.taskScope)
        XCTAssertTrue(PanelUIState.keepsBuilt(.calendar))
    }

    // MARK: - Hosted: bounded updates, no layout loop

    func testHostedPageSettlesAndUpdatesBoundedly() throws {
        let store = try makeTestStore()
        _ = store.commit([TaskDraft(title: "Water plants", dueDay: day(2026, 10, 30))])
        let source = CalendarEventSourceStub(events: [
            event("e1", "Standup", start: date(2026, 10, 29, 9), end: date(2026, 10, 29, 9, 30)),
            event("e2", "Trip", start: date(2026, 10, 31), end: date(2026, 11, 1), allDay: true),
        ])
        let model = CalendarPageModel(store: store, source: source, calendar: calendar, now: { self.date(2026, 10, 29, 12) })
        let size = CGSize(width: 320, height: 460)
        let layout = PanelPageLayout(cornerSize: 28, panelSize: size)
        let page = CalendarPage(model: model, layout: layout,
                                taskActions: CalendarTaskRowActions(toggleDone: { _ in }, open: { _ in }),
                                onNewTask: { _ in })
            .atticDesign(AtticDesignContext(mode: .light))
            .frame(width: size.width, height: size.height)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: page)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle(_ seconds: TimeInterval = 0.3) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        settle(0.5)
        let settled = CalendarPage.bodyEvaluations
        settle(0.5)
        XCTAssertEqual(CalendarPage.bodyEvaluations, settled, "at rest the page does not re-run (no layout loop)")
        model.select(day(2026, 11, 3))
        settle()
        let afterSelect = CalendarPage.bodyEvaluations - settled
        XCTAssertGreaterThanOrEqual(afterSelect, 1)
        XCTAssertLessThanOrEqual(afterSelect, 3, "one change, a bounded number of updates")
        XCTAssertEqual(model.snapshot.month, CalendarMonth(year: 2026, month: 11))
        let quiet = CalendarPage.bodyEvaluations
        settle(0.5)
        XCTAssertEqual(CalendarPage.bodyEvaluations, quiet)
    }
}
