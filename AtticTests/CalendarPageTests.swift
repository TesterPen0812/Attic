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

    func testGridIsFlatAndOnlyTheSelectedDayIsAKey() {
        let weeks = CalendarMonthMath.weeks(for: CalendarMonth(year: 2026, month: 10), today: day(2026, 10, 29),
                                            selected: day(2026, 10, 31), calendar: calendar)
        let all = weeks.flatMap(\.days)
        let days = Dictionary(uniqueKeysWithValues: all.map { ($0.day, $0) })
        XCTAssertEqual(all.filter { $0.style == .selected }.map(\.day), [day(2026, 10, 31)], "the selected day is the only key")
        XCTAssertTrue(all.filter { !$0.isSelected }.allSatisfy { $0.style == .plain }, "no raised keys in any month")
        XCTAssertEqual(days[day(2026, 10, 28)]?.number, .grey, "past days are grey")
        XCTAssertEqual(days[day(2026, 10, 29)]?.number, .red, "today is a red number")
        XCTAssertEqual(days[day(2026, 10, 30)]?.number, .ink, "the rest are ink")
        XCTAssertEqual(days[day(2026, 10, 31)]?.number, .ink)
        let onToday = CalendarMonthMath.weeks(for: CalendarMonth(year: 2026, month: 10), today: day(2026, 10, 29),
                                              selected: day(2026, 10, 29), calendar: calendar).flatMap(\.days)
        let today = onToday.first { $0.day == day(2026, 10, 29) }
        XCTAssertEqual(today?.style, .selected)
        XCTAssertEqual(today?.number, .red, "today's number stays red when selected")
        let onPast = CalendarMonthMath.weeks(for: CalendarMonth(year: 2026, month: 10), today: day(2026, 10, 29),
                                             selected: day(2026, 10, 5), calendar: calendar).flatMap(\.days)
        XCTAssertEqual(onPast.first { $0.day == day(2026, 10, 5) }?.number, .ink, "a selected past day is ink")
        // The key: 60 × 60 px, a whole superellipse on curve 1.4.
        XCTAssertEqual(CalendarDesign.keySize, 30)
        XCTAssertEqual(CalendarDesign.keyCornerRadius, 15)
        XCTAssertEqual(CalendarDesign.keyExponent, pow(2, 1.4), accuracy: 0.0001)
    }

    func testOnlyTheSelectedDayDrawsAThirtyPointGreyKey() throws {
        let selected = try render(key(day(2026, 10, 31), today: day(2026, 10, 29), selected: day(2026, 10, 31)))
        let box = try XCTUnwrap(inkBox(selected, minAlpha: 0.02))
        XCTAssertEqual(box.width, 60, accuracy: 2, "a 30 pt key")
        XCTAssertEqual(box.height, 60, accuracy: 2)
        XCTAssertLessThan(try alpha(selected, px: Int(box.minX) + 2, py: Int(box.minY) + 2), 0.01,
                          "a whole superellipse: its corner is open")
        // The shared selection marker's grey: the design's 6 % heading ink,
        // not the row-selection token (7.5 % in Light).
        XCTAssertEqual(try alpha(selected, px: Int(box.midX) - 22, py: Int(box.midY)), AtticSelectionMarker.fillAlpha,
                       accuracy: 0.008, "the selection marker's 6 % grey")
        for context in [AtticDesignContext(mode: .light), AtticDesignContext(mode: .dark)] {
            let tokens = AtticColorTokens.resolve(context)
            XCTAssertEqual(CalendarKeyButtonStyle.fill(style: .selected, isPressed: false, tokens: tokens),
                           AtticSelectionMarker.fill(tokens), "the key is the shared selection marker, light and dark")
        }
        for plain in [day(2026, 10, 30), day(2026, 10, 28), day(2026, 10, 29)] {
            let image = try render(key(plain, today: day(2026, 10, 29), selected: day(2026, 10, 31)))
            let ink = try XCTUnwrap(inkBox(image, minAlpha: 0.02))
            XCTAssertLessThan(ink.width, 36, "\(plain.rawValue): no key, only its number")
            XCTAssertLessThan(ink.height, 36, "\(plain.rawValue): no key, only its number")
        }
    }

    func testNumbersAreRedOnTodayGreyInThePastAndInkOtherwise() throws {
        let today = day(2026, 10, 29)
        for selected in [today, day(2026, 10, 31)] {
            let red = try numberColour(try render(key(today, today: today, selected: selected)))
            XCTAssertGreaterThan(red.red - red.green, 0.4, "today is red, selected or not")
        }
        let past = try numberColour(try render(key(day(2026, 10, 28), today: today, selected: day(2026, 10, 31))))
        let ink = try numberColour(try render(key(day(2026, 10, 30), today: today, selected: day(2026, 10, 31))))
        XCTAssertEqual(past.red, past.green, accuracy: 0.05, "past days are grey")
        XCTAssertGreaterThan(past.red, ink.red + 0.15, "grey is lighter than ink")
        XCTAssertLessThan(ink.red, 0.25, "the rest are ink")
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

    // MARK: - Free days, date tiles, Today and the fade

    func testFreeDaysFoldIntoOneLineAndTodayKeepsItsCard() {
        let today = day(2026, 10, 29)
        let clock = CalendarAgenda.Clock(today: today, now: date(2026, 10, 29, 12))
        // Events on 30 Oct and 2 Nov; 31 Oct–1 Nov and 3–4 Nov are free.
        let events = [event("a", "Gym", start: date(2026, 10, 30, 7), end: date(2026, 10, 30, 8)),
                      event("b", "Dentist", start: date(2026, 11, 2, 10), end: date(2026, 11, 2, 11))]
        let groups = CalendarAgenda.groups(selected: today, clock: clock, events: events, tasks: [], calendar: calendar)
        let entries = CalendarAgenda.entries(groups, foldsFreeDays: true)
        XCTAssertEqual(entries.map(\.id), ["day-2026-10-29", "day-2026-10-30", "free-2026-10-31", "day-2026-11-02",
                                           "free-2026-11-03"], "today keeps its card even when empty")
        guard case let .free(run) = entries[2], case let .free(tail) = entries[4] else { return XCTFail("runs") }
        let british = Locale(identifier: "en_GB")
        XCTAssertEqual(run.label(locale: british).replacingOccurrences(of: "\u{2009}", with: " "), "31 Oct – 1 Nov")
        XCTAssertEqual(CalendarFreeDays(first: day(2026, 10, 10), last: day(2026, 10, 11)).label(locale: british), "10–11 Oct")
        XCTAssertEqual(tail.label(locale: british), "3–4 Nov")
        XCTAssertEqual(CalendarFreeDays(first: day(2026, 10, 10), last: day(2026, 10, 10)).label(locale: british), "10 Oct")
        XCTAssertEqual(CalendarAgenda.entries(groups, foldsFreeDays: false).count, 7, "a search never folds")
        // Selecting an empty day that is not today folds it too.
        let away = CalendarAgenda.groups(selected: day(2026, 11, 3), clock: clock, events: events, tasks: [], calendar: calendar)
        XCTAssertEqual(CalendarAgenda.entries(away, foldsFreeDays: true).map(\.id), ["free-2026-11-03"])
    }

    func testFreeDaysLineSelectsItsFirstDay() {
        var selected: [DueDay] = []
        let run = CalendarFreeDays(first: day(2026, 10, 10), last: day(2026, 10, 11))
        CalendarFreeDaysLine(run: run, onSelectDay: { selected.append($0) }).select()
        XCTAssertEqual(selected, [day(2026, 10, 10)])
        XCTAssertEqual(CalendarDesign.freeHeight, 20, "a 40 px line")
        XCTAssertEqual(CalendarDesign.freeInsetX, CalendarDesign.dayPadding + 8, "the card's padding plus 16 px")
    }

    func testFreeRunIdsStayStableAsEventsLoad() {
        let today = day(2026, 10, 29)
        let clock = CalendarAgenda.Clock(today: today, now: date(2026, 10, 29, 12))
        let before = CalendarAgenda.entries(CalendarAgenda.groups(selected: today, clock: clock, events: [], tasks: [],
                                                                  calendar: calendar), foldsFreeDays: true)
        XCTAssertEqual(before.map(\.id), ["day-2026-10-29", "free-2026-10-30"])
        let late = [event("x", "Party", start: date(2026, 11, 2, 20), end: date(2026, 11, 2, 22))]
        let after = CalendarAgenda.entries(CalendarAgenda.groups(selected: today, clock: clock, events: late, tasks: [],
                                                                 calendar: calendar), foldsFreeDays: true)
        XCTAssertEqual(after.map(\.id), ["day-2026-10-29", "free-2026-10-30", "day-2026-11-02", "free-2026-11-03"],
                       "days before a new event keep their ids")
        XCTAssertEqual(Set(after.map(\.id)).count, after.count, "unique ids")
    }

    func testDateTilesArePlainAndOnlyTodayHasASquircleCard() throws {
        let today = day(2026, 10, 29)
        let clock = CalendarAgenda.Clock(today: today, now: date(2026, 10, 29, 12))
        let groups = CalendarAgenda.groups(selected: today, clock: clock, events: [], tasks: [], calendar: calendar)
        XCTAssertEqual(groups.map(CalendarAgendaDay.hasCard), [true, false, false, false, false, false, false])
        let tile = try render(AnyView(CalendarDateTile(group: groups[2]) {}.frame(height: 40)),
                              size: CGSize(width: CalendarDesign.tileWidth, height: 40))
        XCTAssertLessThan(try alpha(tile, px: Int((CalendarDesign.tileWidth - 4) * 2), py: 40), 0.01,
                          "no grey box behind the date")
        XCTAssertEqual(CalendarDesign.dayCardExponent, AtticShape.surfaceExponent, "today's card is a squircle surface")
        XCTAssertEqual(CalendarDesign.dayRadius, AtticRadius.card)
        XCTAssertEqual(CalendarDesign.dayPadding(radius: 18), 5, "36 px radius, 10 px padding")
        XCTAssertEqual(CalendarDesign.dayPadding(radius: 32), 8.5, "padding grows with the radius (64 px: 17 px)")
    }

    func testTodayButtonShowsOnlyWhileAnotherDayIsSelected() {
        XCTAssertFalse(CalendarTodayButton.isShown(selected: day(2026, 10, 29), today: day(2026, 10, 29)))
        XCTAssertTrue(CalendarTodayButton.isShown(selected: day(2026, 10, 30), today: day(2026, 10, 29)))
        XCTAssertTrue(CalendarTodayButton.isShown(selected: day(2026, 9, 1), today: day(2026, 10, 29)))
    }

    func testAgendaFadesUnderThePinnedWeekAsAGradientWithNoSoftEdge() throws {
        let size = CGSize(width: 40, height: 120)
        let pinned = try render(AnyView(CalendarScrollMask(pinned: true)), size: size)
        let top = CalendarDesign.weekPitch
        func a(_ y: CGFloat) throws -> Double { try alpha(pinned, px: 40, py: Int(y * 2)) }
        XCTAssertLessThan(try a(top - 2), 0.01, "hidden under the pinned week")
        XCTAssertEqual(try a(top + CalendarDesign.agendaFade / 2), 0.5, accuracy: 0.15, "half way through the fade")
        XCTAssertGreaterThan(try a(top + CalendarDesign.agendaFade + 2), 0.99, "full below the fade")
        XCTAssertEqual(CalendarDesign.agendaFade, 20, "a 40 px fade")
        let unpinned = try render(AnyView(CalendarScrollMask(pinned: false)), size: size)
        XCTAssertGreaterThan(try alpha(unpinned, px: 40, py: 4), 0.99, "nothing hidden before the week pins")
        XCTAssertGreaterThan(try alpha(unpinned, px: 40, py: 40), 0.99)
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Attic/Calendar/UI/CalendarPage.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".atticScrollEdgeEffect()"), "Clean cut: the native soft scroll edge stays off")
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

        // Scrolling through the month and the agenda: the entries keep their
        // ids, and the page re-runs only when the week pins or unpins.
        let ids = model.snapshot.entries.map(\.id)
        let scroller = try XCTUnwrap(Self.scrollView(in: host), "the page's scroller")
        let beforeScroll = CalendarPage.bodyEvaluations
        // The agenda's fade is the mounted scroller's mask: unpinned at the
        // top, the gradient once the week pins, and not re-run per frame.
        XCTAssertEqual(CalendarScrollMask.renders.last, false, "the mounted scroller carries the fade mask, unpinned at rest")
        let masksBefore = CalendarScrollMask.renders.count
        var pinnedMaskSeen = false
        for y in Array(stride(from: 0.0, through: 400.0, by: 10.0)) + Array(stride(from: 400.0, through: 0.0, by: -20.0)) {
            scroller.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroller.reflectScrolledClipView(scroller.contentView)
            settle(0.02)
            if y == 400 { pinnedMaskSeen = CalendarScrollMask.renders.last == true }
        }
        settle(0.3)
        XCTAssertTrue(pinnedMaskSeen, "scrolled past the pin, the mounted mask is the pinned gradient")
        XCTAssertEqual(CalendarScrollMask.renders.last, false, "back at the top, the fade goes")
        XCTAssertLessThanOrEqual(CalendarScrollMask.renders.count - masksBefore, 8,
                                 "the mask re-runs only when the week pins or unpins, not per scroll frame")
        XCTAssertEqual(model.snapshot.entries.map(\.id), ids, "stable ids while scrolling")
        XCTAssertLessThanOrEqual(CalendarPage.bodyEvaluations - beforeScroll, 12,
                                 "61 scroll steps re-run the page only at the pin and week-view changes")
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView != nil { return scroll }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }

    // MARK: - Rendering

    private func key(_ d: DueDay, today: DueDay, selected: DueDay) -> AnyView {
        let grid = CalendarMonthMath.weeks(for: CalendarMonth(d), today: today, selected: selected, calendar: calendar)
        let gridDay = grid.flatMap(\.days).first { $0.day == d }!
        return AnyView(CalendarKey(day: gridDay) {})
    }

    private func render(_ view: AnyView, size: CGSize = CGSize(width: 44, height: 30)) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
            .atticDesign(AtticDesignContext(mode: .light)).environment(\.colorScheme, .light))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func alpha(_ bitmap: NSBitmapImageRep, px: Int, py: Int) throws -> Double {
        try XCTUnwrap(bitmap.colorAt(x: px, y: py)).alphaComponent
    }

    /// The box of every pixel at least `minAlpha` opaque, in pixels.
    private func inkBox(_ bitmap: NSBitmapImageRep, minAlpha: Double) -> CGRect? {
        var box: CGRect?
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) >= minAlpha {
                let pixel = CGRect(x: x, y: y, width: 1, height: 1)
                box = box.map { $0.union(pixel) } ?? pixel
            }
        }
        return box
    }

    /// The average colour of the number's solid pixels.
    private func numberColour(_ bitmap: NSBitmapImageRep) throws -> AtticRGBA {
        var sum = (0.0, 0.0, 0.0), count = 0.0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), colour.alphaComponent > 0.9 else { continue }
                sum = (sum.0 + colour.redComponent, sum.1 + colour.greenComponent, sum.2 + colour.blueComponent)
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 10, "the number is drawn")
        return AtticRGBA(red: sum.0 / count, green: sum.1 / count, blue: sum.2 / count)
    }
}
