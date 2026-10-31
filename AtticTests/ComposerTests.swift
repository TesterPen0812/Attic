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
    private final class Switch { var on = false }
    private let saveFailure = Switch()
    private let clock: Calendar = Calendar.autoupdatingCurrent
    private lazy var now: Date = clock.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 10))!
    private var today: DueDay { DueDay(date: now, calendar: clock) }
    private func day(_ offset: Int) -> DueDay { DueDay(date: clock.date(byAdding: .day, value: offset, to: now)!, calendar: clock) }

    override func setUp() async throws {
        container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        _ = try WorkspaceLegacyBridge.coordinator(for: container)
        let fixed = now
        tasks = TaskStore(container: container, now: { fixed })
        let failing = saveFailure
        notes = NoteStore(container: container, now: { fixed }, persist: { context in
            if failing.on { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        }, attachmentFileStore: makeTestAttachmentFileStore())
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
        AtticMotionPreference.systemReduceMotionOverride = nil
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

    // MARK: Phase A fixes (review of 15109359)

    private func rows<T: PersistentModel>(_ type: T.Type) throws -> [T] {
        try ModelContext(container).fetch(FetchDescriptor<T>())
    }

    func testAFailedSaveLeavesNoTaskNoWritingNoStepAndARetryMakesOne() throws {
        model.open(on: .tasks(.now))
        type("Pay rent")
        model.writing = "Bank details"
        saveFailure.on = true
        XCTAssertFalse(model.create())
        XCTAssertTrue(try rows(TaskItem.self).isEmpty, "no live or Recently Deleted task")
        XCTAssertTrue(try rows(NoteItem.self).isEmpty)
        XCTAssertTrue(try rows(TaskNoteAssociation.self).isEmpty)
        XCTAssertFalse(library.undo.canUndo(in: .tasks))
        XCTAssertTrue(model.isOpen)
        XCTAssertTrue(model.failed)
        XCTAssertEqual(page.addBar.text, "Pay rent")
        XCTAssertEqual(model.writing, "Bank details")

        saveFailure.on = false
        XCTAssertTrue(model.create())
        XCTAssertEqual(try rows(TaskItem.self).count, 1)
        let task = try XCTUnwrap(liveTasks().first)
        XCTAssertTrue(TaskNoteConversion.hasWriting(task.id, in: ModelContext(container)))
        XCTAssertEqual(library.undo(in: .tasks), .applied)
        XCTAssertTrue(liveTasks().isEmpty)
    }

    func testAPinThatCannotSaveKeepsTheCardOpenWithTheDraft() throws {
        model.open(on: .tasks(.now), as: .note)
        type("Pinned idea")
        model.pinned = true
        saveFailure.on = true
        XCTAssertFalse(model.create())
        XCTAssertTrue(model.isOpen)
        XCTAssertTrue(model.failed)
        XCTAssertTrue(model.pinned)
        XCTAssertTrue(try rows(NoteItem.self).isEmpty)
        XCTAssertTrue(toasts.isEmpty)

        saveFailure.on = false
        XCTAssertTrue(model.create())
        XCTAssertTrue(try XCTUnwrap(notes.notes.first).isPinned)
    }

    func testATypedDayReplacesCalendarsPickedDayEvenAtTheCaret() throws {
        model.open(on: .calendar(selected: today))
        type("Lunch tomorrow")
        XCTAssertTrue(model.create(openingPage: true))
        let event = try XCTUnwrap(events.events.values.first)
        XCTAssertEqual(event.draft.title, "Lunch")
        XCTAssertEqual(DueDay(date: event.draft.start, calendar: clock), day(1))
    }

    func testCalendarUndoReachesTheNewestCalendarActionWhateverItsKind() throws {
        let b = try XCTUnwrap(library.createTasks([TaskDraft(title: "B")])?.first)
        model.open(on: .calendar(selected: today))
        type("A 1pm")
        XCTAssertTrue(model.create())
        XCTAssertEqual(events.events.count, 1)
        CalendarAgendaCommands.toggleDone(b.id, store: tasks)
        XCTAssertEqual(tasks.listedTask(withID: b.id)?.status, .done)

        let history = try XCTUnwrap(AtticPanelController.unhandledUndoHistory(for: .calendar))
        XCTAssertEqual(library.undo(in: history), .applied)
        XCTAssertEqual(tasks.listedTask(withID: b.id)?.status, .todo, "B is reopened")
        XCTAssertEqual(events.events.count, 1, "A stays")
        XCTAssertEqual(library.undo(in: history), .applied)
        XCTAssertTrue(events.events.isEmpty, "then A goes")
        XCTAssertNotNil(tasks.task(withID: b.id), "B's own creation belongs to Tasks")
        XCTAssertEqual(AtticPanelController.unhandledUndoHistory(for: .tasks), .tasks)
    }

    func testAnAgendaRenameIsACalendarStep() throws {
        let b = try XCTUnwrap(library.createTasks([TaskDraft(title: "Old")])?.first)
        XCTAssertTrue(CalendarAgendaCommands.rename(b.id, to: " New ", store: tasks))
        XCTAssertEqual(tasks.task(withID: b.id)?.title, "New")
        XCTAssertEqual(library.undo(in: .calendar), .applied)
        XCTAssertEqual(tasks.task(withID: b.id)?.title, "Old")
    }

    // MARK: Keys through the mounted card

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    private func spin(_ seconds: TimeInterval = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func mountForKeys(on composerPage: ComposerPage) throws -> (NSWindow, NSView, NSTextView) {
        try requireKeyWindowTests()
        model.open(on: composerPage)
        let hosting = NSHostingView(rootView: ComposerCard(model: model))
        hosting.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        let window = KeyWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        window.becomeKey()
        windows.append(window)
        spin()
        let field = try XCTUnwrap(model.editor.textView, "the title field is live")
        window.makeFirstResponder(field)
        spin()
        return (window, hosting, field)
    }

    private func key(_ window: NSWindow, _ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                         isARepeat: false, keyCode: code)!
            window.sendEvent(event)
        }
        spin(0.1)
    }

    private func typeKeys(_ field: NSTextView, _ text: String) {
        field.insertText(text, replacementRange: field.selectedRange())
        spin(0.1)
    }

    func testReturnInTheTitleCreatesAndClosesTheCard() throws {
        let (window, _, field) = try mountForKeys(on: .tasks(.now))
        typeKeys(field, "Call Sam")
        key(window, "\r", code: 36)
        XCTAssertEqual(liveTasks().map(\.title), ["Call Sam"])
        XCTAssertFalse(model.isOpen)
        XCTAssertTrue(opened.isEmpty)
    }

    func testCommandReturnInTheTitleCreatesAndOpens() throws {
        let (window, _, field) = try mountForKeys(on: .tasks(.now))
        typeKeys(field, "Open me")
        key(window, "\r", code: 36, modifiers: .command)
        XCTAssertEqual(opened, liveTasks().map(\.id))
        XCTAssertEqual(opened.count, 1)
    }

    func testEscapeInTheTitleClosesAndKeepsTheDraft() throws {
        let (window, _, field) = try mountForKeys(on: .tasks(.now))
        typeKeys(field, "Keep me")
        key(window, "\u{1B}", code: 53)
        XCTAssertFalse(model.isOpen)
        XCTAssertEqual(page.addBar.text, "Keep me")
        XCTAssertTrue(liveTasks().isEmpty)
    }

    func testTabTakesASuggestionThenMovesOnFromTheTitle() throws {
        XCTAssertNotNil(library.createTasks([TaskDraft(title: "Seed", tags: ["home"])]))
        let (window, hosting, field) = try mountForKeys(on: .tasks(.now))
        typeKeys(field, "Buy #ho")
        XCTAssertNotNil(model.suggestion(focused: true))
        key(window, "\t", code: 48)
        XCTAssertTrue(page.addBar.text.hasPrefix("Buy #home"), page.addBar.text)
        XCTAssertTrue(window.firstResponder === field, "taking a suggestion keeps the keyboard in the title")
        // No list now: Tab moves on to the card's next control.
        typeKeys(field, " ")
        key(window, "\t", code: 48)
        let next = try XCTUnwrap(window.firstResponder as? NSView)
        XCTAssertFalse(next === field)
        XCTAssertTrue(next.isDescendant(of: hosting))
    }

    func testReduceMotionMakesTheCardInstant() {
        AtticMotionPreference.systemReduceMotionOverride = true
        XCTAssertNil(ComposerMotion.animation())
        XCTAssertNil(ComposerMotion.animation(showing: false))
        AtticMotionPreference.systemReduceMotionOverride = false
        let level = AtticMotionPreference.level
        defer { AtticMotionPreference.level = level }
        AtticMotionPreference.level = .lively
        XCTAssertNotNil(ComposerMotion.animation())
    }

    /// The HTML's `cp` box: 54 → 578 design px, radius 32 → 44 (16 → 22 pt),
    /// curve 1.4, one progress for size and radius, on the bar's own corner.
    func testTheGrowRunsFromThePlusToTheCardOnOneProgress() {
        let card = CGSize(width: ComposerMetrics.width, height: 131)
        let closed = ComposerGrow.geometry(progress: 0, card: card)
        XCTAssertEqual(closed.size, CGSize(width: AtticControlSize.headerControl, height: AtticControlSize.headerControl))
        XCTAssertEqual(closed.cornerRadius, 16)
        let open = ComposerGrow.geometry(progress: 1, card: card)
        XCTAssertEqual(open.size, card)
        XCTAssertEqual(open.cornerRadius, 22)
        XCTAssertEqual(ComposerMetrics.radius, 22)
        let half = ComposerGrow.geometry(progress: 0.5, card: card)
        XCTAssertEqual(half.size.width, (27 + 289) / 2, accuracy: 0.01)
        XCTAssertEqual(half.cornerRadius, 19, accuracy: 0.01)
        XCTAssertEqual(ComposerGrow.geometry(progress: 2, card: card), open, "clamped")
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 340, height: 560))
        XCTAssertEqual(ComposerGrow.anchor(layout: layout), PanelSharedBottomBar.plusInsets(layout: layout))
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
