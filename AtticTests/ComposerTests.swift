import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// The "+" card (Accepted 2026-10-29 and 30 Oct): its model and its view,
/// mounted on their own. Event writes go to a fake store only.
@MainActor
final class ComposerTests: XCTestCase {
    private var container: ModelContainer!
    private var tasks: TaskStore!
    private var notes: NoteStore!
    private var library: AtticLibrary!
    private var page: TasksPageModel!
    private var model: ComposerModel!
    private let events = FakeCalendarEventWriteStore()
    private var opened: [UUID] = []
    private var openedNotes: [UUID] = []
    private var openedEvents: [CalendarOwnedEvent] = []
    private var toasts: [String] = []
    private var windows: [NSWindow] = []
    private let clock: Calendar = Calendar.autoupdatingCurrent
    private lazy var now: Date = clock.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 10))!
    private var today: DueDay { DueDay(date: now, calendar: clock) }
    private func day(_ offset: Int) -> DueDay { DueDay(date: clock.date(byAdding: .day, value: offset, to: now)!, calendar: clock) }

    override func setUp() async throws {
        container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        _ = try WorkspaceLegacyBridge.coordinator(for: container)
        let fixed = now
        tasks = TaskStore(container: container, now: { fixed })
        notes = NoteStore(container: container, now: { fixed }, attachmentFileStore: makeTestAttachmentFileStore())
        library = AtticLibrary(tasks: tasks, notes: notes)
        page = TasksPageModel(library: library, services: TasksPageServices(now: { fixed }))
        events.availableCalendars = [
            CalendarWriteCalendar(id: "home", title: "Home", colour: .init(red: 0.2, green: 0.5, blue: 0.9),
                                  sourceID: "local", sourceTitle: "On My Mac", isWritable: true),
            CalendarWriteCalendar(id: "work", title: "Work", colour: .init(red: 0.9, green: 0.4, blue: 0.2),
                                  sourceID: "local", sourceTitle: "On My Mac", isWritable: true),
        ]
        let store = events, undo = library.undo
        model = ComposerModel(tasks: page, services: ComposerServices(
            makeWriter: { EventKitCalendarEventWriter(store: store, record: try CalendarOwnershipRecord(), undoRoute: undo,
                                                      notificationCenter: NotificationCenter()) },
            openTaskPage: { [unowned self] in opened.append($0) },
            openNote: { [unowned self] in openedNotes.append($0) },
            openEvent: { [unowned self] in openedEvents.append($0) },
            toast: { [unowned self] in toasts.append($0) }))
    }

    override func tearDown() {
        windows.forEach { $0.contentView = nil; $0.close() }
        windows.removeAll()
    }

    private func type(_ text: String) {
        // Typing keeps the draft's picks (the Calendar's day), as the field does.
        var draft = TaskAddBarText(text: text)
        draft.picked = page.addBar.picked
        page.addBar = draft
        page.addBarCaret = nil
    }

    private func liveTasks() -> [TaskItem] { tasks.tasks.filter { $0.deletedAt == nil } }

    // MARK: Kinds

    func testPlusOpensOnThePagesOwnKindWithItsKinds() {
        model.open(on: .tasks(.now))
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(model.kind, .task)
        XCTAssertEqual(model.kinds, [.task, .note])
        model.close()
        model.open(on: .calendar(selected: today))
        XCTAssertEqual(model.kind, .event)
        XCTAssertEqual(model.kinds, [.task, .event, .note])
    }

    func testShiftCommandNOpensOnNote() {
        model.open(on: .tasks(.now), as: .note)
        XCTAssertEqual(model.kind, .note)
    }

    func testAKeptNoteDraftOpensAsNoteOnAnyPage() {
        model.open(on: .tasks(.now))
        model.choose(.note)
        type("Idea #work")
        model.close()
        XCTAssertFalse(model.isOpen)
        model.open(on: .calendar(selected: today))
        XCTAssertEqual(model.kind, .note)
        XCTAssertEqual(page.addBar.text, "Idea #work")
    }

    func testAnEmptyNoteDraftOpensOnThePagesKind() {
        model.open(on: .tasks(.now), as: .note)
        model.close()
        model.open(on: .tasks(.now))
        XCTAssertEqual(model.kind, .task)
    }

    func testAKeptEventDraftIsATaskOutsideCalendar() {
        model.open(on: .calendar(selected: day(2)))
        type("Lunch 1pm")
        model.close()
        model.open(on: .tasks(.now))
        XCTAssertEqual(model.kind, .task)
        XCTAssertEqual(page.addBar.text, "Lunch 1pm")
        XCTAssertFalse(model.kinds.contains(.event))
    }

    func testCalendarStartsOnTheSelectedDayAndNowStartsEmpty() {
        model.open(on: .tasks(.now))
        XCTAssertNil(model.values.day, "Date is empty by default on Now")
        model.close()
        model.open(on: .calendar(selected: day(3)))
        XCTAssertEqual(model.values.day, day(3))
        model.choose(.task)
        XCTAssertEqual(model.values.day, day(3))
    }

    func testTheTitleTintsWhatThisKindReads() {
        model.open(on: .tasks(.now))
        type("Call !! #home tomorrow 4pm")
        XCTAssertEqual(model.chips.count, 4)
        model.choose(.note)
        XCTAssertEqual(model.chips.count, 1)
        XCTAssertEqual(model.values.tags, ["home"])
        model.close()
        model.open(on: .calendar(selected: today))
        model.choose(.event)
        XCTAssertEqual(model.chips.count, 2, "an event reads a day and a time")
        XCTAssertNil(model.values.priority)
    }

    // MARK: Tasks

    func testReturnCreatesATaskWithItsWritingAsOneUndoStep() throws {
        model.open(on: .tasks(.now))
        type("Pay rent !! #home tomorrow 4pm")
        model.writing = "Bank details"
        XCTAssertTrue(model.create())
        let task = try XCTUnwrap(liveTasks().first)
        XCTAssertEqual(task.title, "Pay rent")
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.tags, ["home"])
        XCTAssertEqual(task.dueDay, day(1))
        XCTAssertEqual(task.dueTimeMinutes, 16 * 60)
        XCTAssertEqual(task.status, .todo)
        XCTAssertTrue(TaskNoteConversion.hasWriting(task.id, in: ModelContext(container)))
        XCTAssertFalse(model.isOpen)
        XCTAssertFalse(model.hasDraft)
        XCTAssertTrue(opened.isEmpty)

        XCTAssertEqual(library.undo(in: .tasks), .applied)
        XCTAssertTrue(liveTasks().isEmpty)
        XCTAssertFalse(TaskNoteConversion.hasWriting(task.id, in: ModelContext(container)))
        XCTAssertEqual(library.redo(in: .tasks), .applied)
        XCTAssertEqual(liveTasks().map(\.id), [task.id])
        XCTAssertTrue(TaskNoteConversion.hasWriting(task.id, in: ModelContext(container)))
    }

    func testCommandReturnCreatesAndOpensTheTasksPage() throws {
        model.open(on: .tasks(.now))
        type("Call Sam")
        XCTAssertTrue(model.create(openingPage: true))
        XCTAssertEqual(opened, [try XCTUnwrap(liveTasks().first).id])
    }

    func testLaterMakesAnUndatedPutOffTask() throws {
        model.open(on: .tasks(.backlog))
        type("Someday")
        XCTAssertTrue(model.create())
        let task = try XCTUnwrap(liveTasks().first)
        XCTAssertEqual(task.status, .backlog)
        XCTAssertNil(task.dueDay)
        XCTAssertTrue(toasts.isEmpty)
    }

    func testADatedTaskFromLaterGoesToNow() throws {
        model.open(on: .tasks(.backlog))
        type("Dentist tomorrow")
        XCTAssertTrue(model.create())
        XCTAssertEqual(try XCTUnwrap(liveTasks().first).status, .todo)
        XCTAssertEqual(toasts, ["Added to Now"])
    }

    func testDoneCreatesInNow() throws {
        model.open(on: .tasks(.done))
        type("Follow up")
        XCTAssertTrue(model.create())
        XCTAssertEqual(try XCTUnwrap(liveTasks().first).status, .todo)
        XCTAssertEqual(toasts, ["Added to Now"])
    }

    func testEscapeKeepsTheDraftAndAnEmptyTitleCannotCreate() {
        model.open(on: .tasks(.now))
        XCTAssertFalse(model.create())
        type("Draft")
        model.writing = "kept"
        model.close()
        XCTAssertFalse(model.isOpen)
        model.open(on: .tasks(.now))
        XCTAssertEqual(page.addBar.text, "Draft")
        XCTAssertEqual(model.writing, "kept")
    }

    // MARK: Events

    func testAnEventIsWrittenThroughTheWriterAndUndoneWithIt() throws {
        model.open(on: .calendar(selected: day(2)))
        XCTAssertEqual(model.calendars.map(\.id), ["home", "work"])
        XCTAssertEqual(model.selectedCalendar?.id, "home")
        model.calendarID = "work"
        model.eventLength = 90
        type("Lunch with Ana 1pm")
        XCTAssertTrue(model.create())
        let event = try XCTUnwrap(events.events.values.first)
        XCTAssertEqual(events.events.count, 1)
        XCTAssertEqual(event.draft.title, "Lunch with Ana")
        XCTAssertEqual(event.draft.calendarID, "work")
        XCTAssertFalse(event.draft.isAllDay)
        XCTAssertNil(event.draft.notes, "an empty writing line writes no notes")
        var start = DateComponents(year: day(2).year, month: day(2).month, day: day(2).day, hour: 13)
        start.calendar = clock
        XCTAssertEqual(event.draft.start, clock.date(from: start))
        XCTAssertEqual(event.draft.end.timeIntervalSince(event.draft.start), 90 * 60)
        XCTAssertTrue(liveTasks().isEmpty)
        XCTAssertEqual(model.calendarID, "work", "the calendar choice is kept for the next event")

        XCTAssertEqual(library.undo(in: .calendar), .applied)
        XCTAssertTrue(events.events.isEmpty)
    }

    func testAnEventsWritingLineBecomesItsNotesAndUndoStillRemovesIt() throws {
        model.open(on: .calendar(selected: day(1)))
        type("Dentist 9am")
        model.writing = "  Bring the form\nRoom 4  "
        XCTAssertTrue(model.create())
        let event = try XCTUnwrap(events.events.values.first)
        XCTAssertEqual(event.draft.notes, "Bring the form\nRoom 4")
        XCTAssertEqual(model.writing, "")
        XCTAssertEqual(library.undo(in: .calendar), .applied)
        XCTAssertTrue(events.events.isEmpty)
        XCTAssertEqual(library.redo(in: .calendar), .applied)
        XCTAssertEqual(events.events.values.first?.draft.notes, "Bring the form\nRoom 4")
    }

    func testAWhitespaceWritingLineWritesNoNotes() throws {
        model.open(on: .calendar(selected: day(1)))
        type("Gym")
        model.writing = " \n "
        XCTAssertTrue(model.create())
        XCTAssertNil(try XCTUnwrap(events.events.values.first).draft.notes)
    }

    func testAnEventWithNoTimeIsAllDayAndCommandReturnOpensIt() throws {
        model.open(on: .calendar(selected: day(1)))
        type("Holiday")
        XCTAssertTrue(model.create(openingPage: true))
        let event = try XCTUnwrap(events.events.values.first)
        XCTAssertTrue(event.draft.isAllDay)
        XCTAssertEqual(event.draft.start, day(1).startDate(in: clock).flatMap { clock.startOfDay(for: $0) })
        XCTAssertEqual(openedEvents.count, 1)
    }

    func testATaskMadeOnCalendarIsOneStepInCalendarsHistory() throws {
        model.open(on: .calendar(selected: day(1)))
        model.choose(.task)
        type("Buy flowers")
        XCTAssertTrue(model.create())
        XCTAssertEqual(try XCTUnwrap(liveTasks().first).dueDay, day(1))
        XCTAssertTrue(events.events.isEmpty)
        XCTAssertEqual(library.undo(in: .calendar), .applied)
        XCTAssertTrue(liveTasks().isEmpty)
    }

    func testAFailedEventWriteKeepsTheDraft() {
        model.services.makeWriter = { throw CalendarEventWriteError.accessDenied }
        model.open(on: .calendar(selected: today))
        type("Standup 9am")
        XCTAssertFalse(model.create())
        XCTAssertTrue(model.isOpen)
        XCTAssertTrue(model.failed)
        XCTAssertEqual(page.addBar.text, "Standup 9am")
    }

    // MARK: Quick note

    func testAQuickNoteIsFiledInNotesWithItsTagsAndPin() throws {
        model.open(on: .tasks(.now), as: .note)
        type("Gift ideas #home")
        model.writing = "Scarf"
        model.pinned = true
        XCTAssertTrue(model.create())
        let note = try XCTUnwrap(notes.notes.first { $0.deletedAt == nil })
        XCTAssertEqual(note.title, "Gift ideas")
        XCTAssertEqual(note.tags, ["home"])
        XCTAssertTrue(note.isPinned)
        XCTAssertTrue(note.body.contains("Scarf"))
        XCTAssertNil(note.taskID)
        XCTAssertTrue(liveTasks().isEmpty)
        XCTAssertEqual(toasts, ["Added to Notes"])
        XCTAssertFalse(model.pinned)

        XCTAssertEqual(library.undo(in: .tasks), .applied)
        XCTAssertNil(notes.notes.first { $0.id == note.id && $0.deletedAt == nil })
    }

    func testCommandReturnOpensTheNoteInNotes() throws {
        model.open(on: .tasks(.now), as: .note)
        type("Reading list")
        XCTAssertTrue(model.create(openingPage: true))
        XCTAssertEqual(openedNotes.count, 1)
        XCTAssertTrue(toasts.isEmpty)
    }

    // MARK: The card

    private func host(_ kind: ComposerKind?, on composerPage: ComposerPage) -> NSHostingView<some View> {
        model.open(on: composerPage, as: kind)
        let view = NSHostingView(rootView: ComposerCard(model: model))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        windows.append(window)
        view.layoutSubtreeIfNeeded()
        return view
    }

    func testTheCardIsTheDesignsWidthAndKeepsTheTasksHeightForEveryKind() {
        let task = host(nil, on: .calendar(selected: today)).fittingSize
        XCTAssertEqual(task.width, ComposerMetrics.width, accuracy: 0.5)
        var heights: [CGFloat] = []
        for kind in [ComposerKind.task, .event, .note] {
            model.choose(kind)
            let view = host(kind, on: .calendar(selected: today))
            heights.append(view.fittingSize.height)
        }
        XCTAssertEqual(Set(heights.map { ($0 * 2).rounded() }).count, 1, "\(heights)")
        // 11 + 20 + 2 + 15 + 43 + 28 + 11, give or take the field's line.
        XCTAssertEqual(heights[0], 130, accuracy: 6)
    }

    func testDateLabels() {
        let words: (DueDay) -> String = { _ in "Tomorrow" }
        XCTAssertEqual(ComposerCard.dateLabel(.init(title: "", day: nil, time: nil, priority: nil, tags: []), kind: .task, words: words), "Date")
        XCTAssertEqual(ComposerCard.dateLabel(.init(title: "", day: today, time: 990, priority: nil, tags: []), kind: .task, words: words), "Tomorrow, 16:30")
        XCTAssertEqual(ComposerCard.dateLabel(.init(title: "", day: today, time: nil, priority: nil, tags: []), kind: .event, words: words), "Tomorrow · All day")
        XCTAssertEqual(ComposerCard.length(90), "1 h 30")
        XCTAssertEqual(ComposerCard.length(30), "30 min")
    }
}
