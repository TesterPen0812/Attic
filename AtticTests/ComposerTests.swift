import AppKit
import Combine
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
    private var failureNotices: [String] = []
    private var toastUndos: [@MainActor () -> CommandOutcome] = []
    private var windows: [NSWindow] = []
    private final class Switch { var on = false }
    private let saveFailure = Switch()
    private let clock: Calendar = Calendar.autoupdatingCurrent
    private lazy var now: Date = clock.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 10))!
    private var today: DueDay { DueDay(date: now, calendar: clock) }
    private func day(_ offset: Int) -> DueDay { DueDay(date: clock.date(byAdding: .day, value: offset, to: now)!, calendar: clock) }

    override func setUp() async throws {
        AtticMotionPreference.systemReduceMotionOverride = false
        AtticTransparencySeam.systemOverride = false
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
            toast: { [unowned self] message, undo in toasts.append(message); toastUndos.append(undo) },
            eventFailure: { [unowned self] message in failureNotices.append(message) }))
    }

    override func tearDown() {
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
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

    func testQueuedEventSubmissionCannotCreateAReplacementSession() async {
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        type("Old event")
        model.submit(openingPage: true)
        // Stay on this actor turn: the queued event has not started yet.
        model.close()
        model.open(on: .tasks(.now))
        type("Replacement draft")
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertTrue(events.events.isEmpty)
        XCTAssertTrue(liveTasks().isEmpty)
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(page.addBar.text, "Replacement draft")
    }

    func testUnhandledEscapeClosesTheComposerAndKeepsItsDraftBeforeWindowDismissal() {
        let state = PanelComposerState()
        let shared = state.model(tasks: page, services: ComposerServices())
        shared.open(on: .tasks(.now))
        type("Keep this draft")
        XCTAssertTrue(state.closeForUnhandledEscape())
        XCTAssertFalse(shared.isOpen)
        XCTAssertEqual(page.addBar.text, "Keep this draft")
        XCTAssertFalse(state.closeForUnhandledEscape(), "A second Escape can dismiss the panel")
    }

    func testAnInFlightEventCreatesOnceAndLeavesAReopenedDraftAlone() async throws {
        let staged = expectation(description: "event proof staged off main")
        let release = DispatchSemaphore(value: 0)
        var paused = false // confined to the writer worker
        let record = try CalendarOwnershipRecord(persist: { _ in
            if !paused {
                paused = true
                staged.fulfill()
                _ = release.wait(timeout: .now() + 10)
            }
        })
        let backend = events
        let writer = BackgroundCalendarEventWriter(undoRoute: library.undo) {
            CalendarEventTransactions(store: backend, record: record)
        }
        model.services.makeWriter = { writer }
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        type("Submitted event")
        let submission = Task { await self.model.create() }
        await fulfillment(of: [staged], timeout: 3)
        XCTAssertTrue(model.isCreating)
        let duplicate = Task { await self.model.create() }
        await Task.yield()
        model.close()
        model.open(on: .tasks(.now))
        type("New draft")
        release.signal()
        defer { release.signal() }
        await XCTAssertTrueAsync(await submission.value)
        await XCTAssertFalseAsync(await duplicate.value)
        XCTAssertEqual(events.events.count, 1)
        XCTAssertEqual(events.events.values.first?.draft.title, "Submitted event")
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(page.addBar.text, "New draft")
    }

    /// A held write: the record's persist parks on the writer worker until
    /// released, then fails (rolled back) or succeeds. Fakes only.
    private func holdEventWrite(failing: Bool) throws -> (staged: XCTestExpectation, release: DispatchSemaphore) {
        let staged = expectation(description: "event write held off main")
        let release = DispatchSemaphore(value: 0)
        var held = false // confined to the writer worker
        let record = try CalendarOwnershipRecord(persist: { _ in
            guard !held else { return }
            held = true
            staged.fulfill()
            _ = release.wait(timeout: .now() + 10)
            if failing { throw CocoaError(.fileWriteUnknown) }
        })
        let backend = events
        let writer = BackgroundCalendarEventWriter(undoRoute: library.undo) {
            CalendarEventTransactions(store: backend, record: record)
        }
        model.services.makeWriter = { writer }
        return (staged, release)
    }

    func testAHeldEventWriteThatFailsAfterTheDraftChangesSaysSoAndKeepsTheEdit() async throws {
        let (staged, release) = try holdEventWrite(failing: true)
        defer { release.signal() }
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        type("Submitted event")
        let submission = Task { await self.model.create() }
        await fulfillment(of: [staged], timeout: 3)
        type("Edited event")
        model.writing = "Edited notes"
        release.signal()
        await XCTAssertFalseAsync(await submission.value)
        XCTAssertTrue(model.failed)
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(page.addBar.text, "Edited event")
        XCTAssertEqual(model.writing, "Edited notes")
        XCTAssertTrue(events.events.isEmpty)
    }

    func testAHeldEventFailureAfterReopeningAsTaskNotifiesAndRecoversOriginalEvent() async throws {
        let suite = "ComposerFailedEvent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let drafts = ComposerDraftStore(defaults: defaults)
        model.services.drafts = drafts
        let (staged, release) = try holdEventWrite(failing: true)
        defer { release.signal() }

        let selected = day(3)
        model.open(on: .calendar(selected: selected))
        await model.loadCalendars()
        type("Original event 2pm")
        model.writing = "Original notes"
        model.eventLength = 90
        model.calendarID = "work"
        let submission = Task { await self.model.create() }
        await fulfillment(of: [staged], timeout: 3)
        model.close()
        model.open(on: .tasks(.now))
        type("Replacement task")
        model.writing = "Different notes"
        release.signal()

        await XCTAssertFalseAsync(await submission.value)
        XCTAssertTrue(failureNotices.contains { $0.contains("Couldn’t save event") },
                      "a failed closed/reopened event must be announced")
        XCTAssertEqual(page.addBar.text, "Replacement task", "the new task is untouched")
        XCTAssertEqual(model.writing, "Different notes")
        XCTAssertTrue(events.events.isEmpty, "failure rolls back the event")
        XCTAssertEqual(drafts.loadFailedEvents().map(\.title), ["Original event 2pm"])

        await XCTAssertTrueAsync(await model.create())
        model.close()
        model.open(on: .calendar(selected: today))
        XCTAssertEqual(model.kind, .event)
        XCTAssertEqual(page.addBar.text, "Original event 2pm")
        XCTAssertEqual(model.writing, "Original notes")
        XCTAssertEqual(model.values.day, selected)
        XCTAssertEqual(model.eventLength, 90)
        XCTAssertEqual(model.calendarID, "work")
        XCTAssertTrue(model.failed, "the recovered event clearly remains unsaved")
        XCTAssertEqual(drafts.loadFailedEvents().map(\.title), ["Original event 2pm"],
                       "reopening is not a durable save; recovery stays backed up")
        await XCTAssertTrueAsync(await model.create())
        XCTAssertTrue(drafts.loadFailedEvents().isEmpty, "durable retry consumes the recovery backup")
        XCTAssertEqual(events.events.values.first?.draft.title, "Original event")
    }

    func testAHeldEventFailureAfterCloseSurvivesAComposerRelaunch() async throws {
        let suite = "ComposerFailedEvent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let drafts = ComposerDraftStore(defaults: defaults)
        model.services.drafts = drafts
        let (staged, release) = try holdEventWrite(failing: true)
        defer { release.signal() }
        model.open(on: .calendar(selected: day(2)))
        await model.loadCalendars()
        type("Still mine")
        let submission = Task { await self.model.create() }
        await fulfillment(of: [staged], timeout: 3)
        model.close()
        release.signal()
        await XCTAssertFalseAsync(await submission.value)
        XCTAssertTrue(failureNotices.contains { $0.contains("Couldn’t save event") })

        // An app restart reconstructs the composer using its saved drafts.
        let fixed = now
        let freshPage = TasksPageModel(library: library, services: TasksPageServices(now: { fixed }))
        let restarted = ComposerModel(tasks: freshPage, services: ComposerServices(drafts: drafts))
        restarted.open(on: .calendar(selected: today))
        XCTAssertEqual(freshPage.addBar.text, "Still mine")
        XCTAssertEqual(restarted.values.day, day(2))
        XCTAssertTrue(restarted.failed)
        restarted.close()
        let lastPage = TasksPageModel(library: library, services: TasksPageServices(now: { fixed }))
        let stillRecoverable = ComposerModel(tasks: lastPage, services: ComposerServices(drafts: drafts))
        stillRecoverable.open(on: .calendar(selected: today))
        XCTAssertEqual(stillRecoverable.values.day, day(2), "closing without saving keeps the original date")
        XCTAssertTrue(stillRecoverable.failed)
    }

    func testFailedEventRecoveryRemembersTypedDateOverEarlierPickedDay() async throws {
        let suite = "ComposerFailedEvent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let drafts = ComposerDraftStore(defaults: defaults)
        model.services.drafts = drafts
        let (staged, release) = try holdEventWrite(failing: true)
        defer { release.signal() }
        model.open(on: .calendar(selected: day(3)))
        await model.loadCalendars()
        type("Appointment tomorrow 2pm")
        let submission = Task { await self.model.create() }
        await fulfillment(of: [staged], timeout: 3)
        model.close()
        release.signal()
        await XCTAssertFalseAsync(await submission.value)
        XCTAssertEqual(drafts.loadFailedEvents().first?.day, day(1), "the typed day wins before submission")

        model.open(on: .calendar(selected: today))
        XCTAssertEqual(model.values.day, day(1))
        await XCTAssertTrueAsync(await model.create())
        XCTAssertEqual(events.events.values.first?.draft.start, day(1).startDate(in: clock)?.addingTimeInterval(14 * 3600))
    }

    func testAHeldEventWriteThatSucceedsAfterTheDraftChangesShowsNoFailure() async throws {
        let (staged, release) = try holdEventWrite(failing: false)
        defer { release.signal() }
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        type("Submitted event")
        let submission = Task { await self.model.create() }
        await fulfillment(of: [staged], timeout: 3)
        type("Edited event")
        model.writing = "Edited notes"
        release.signal()
        await XCTAssertTrueAsync(await submission.value)
        XCTAssertFalse(model.failed)
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(page.addBar.text, "Edited event")
        XCTAssertEqual(model.writing, "Edited notes")
        XCTAssertEqual(events.events.values.map(\.draft.title), ["Submitted event"])
    }

    func testTypingDuringCalendarLoadingCannotSubmitTheNewerDraft() async throws {
        let loading = expectation(description: "calendar load")
        let submitting = expectation(description: "submission entered")
        let release = DispatchSemaphore(value: 0)
        let backend = events
        let writer = BackgroundCalendarEventWriter(undoRoute: library.undo) {
            loading.fulfill()
            _ = release.wait(timeout: .now() + 10)
            return CalendarEventTransactions(store: backend, record: try CalendarOwnershipRecord())
        }
        model.services.makeWriter = { writer }
        let token = model.$isCreating.dropFirst().filter { $0 }.sink { _ in submitting.fulfill() }
        defer { token.cancel(); release.signal() }
        model.open(on: .calendar(selected: today))
        type("First draft")
        let submission = Task { await self.model.create() }
        await fulfillment(of: [loading, submitting], timeout: 3)
        type("Newer draft")
        release.signal()
        await XCTAssertFalseAsync(await submission.value)
        XCTAssertTrue(events.events.isEmpty)
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(page.addBar.text, "Newer draft")
    }

    // MARK: Kinds

    func testPlusOpensOnThePagesOwnKindWithItsKinds() async {
        model.open(on: .tasks(.now))
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(model.kind, .task)
        XCTAssertEqual(model.kinds, [.task, .note])
        model.close()
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        XCTAssertEqual(model.kind, .event)
        XCTAssertEqual(model.kinds, [.task, .event, .note])
    }

    func testShiftCommandNOpensOnNote() {
        model.open(on: .tasks(.now), as: .note)
        XCTAssertEqual(model.kind, .note)
    }

    func testAKeptNoteDraftOpensAsNoteOnAnyPage() async {
        model.open(on: .tasks(.now))
        model.choose(.note)
        type("Idea #work")
        model.close()
        XCTAssertFalse(model.isOpen)
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        XCTAssertEqual(model.kind, .note)
        XCTAssertEqual(page.addBar.text, "Idea #work")
    }

    func testAnEmptyNoteDraftOpensOnThePagesKind() {
        model.open(on: .tasks(.now), as: .note)
        model.close()
        model.open(on: .tasks(.now))
        XCTAssertEqual(model.kind, .task)
    }

    func testAKeptEventDraftIsATaskOutsideCalendar() async {
        model.open(on: .calendar(selected: day(2)))
        await model.loadCalendars()
        type("Lunch 1pm")
        model.close()
        model.open(on: .tasks(.now))
        XCTAssertEqual(model.kind, .task)
        XCTAssertEqual(page.addBar.text, "Lunch 1pm")
        XCTAssertFalse(model.kinds.contains(.event))
    }

    func testCalendarStartsOnTheSelectedDayAndNowStartsEmpty() async {
        model.open(on: .tasks(.now))
        XCTAssertNil(model.values.day, "Date is empty by default on Now")
        model.close()
        model.open(on: .calendar(selected: day(3)))
        await model.loadCalendars()
        XCTAssertEqual(model.values.day, day(3))
        model.choose(.task)
        XCTAssertEqual(model.values.day, day(3))
    }

    func testTheTitleTintsWhatThisKindReads() async {
        model.open(on: .tasks(.now))
        type("Call !! #home tomorrow 4pm")
        XCTAssertEqual(model.chips.count, 4)
        model.choose(.note)
        XCTAssertEqual(model.chips.count, 1)
        XCTAssertEqual(model.values.tags, ["home"])
        model.close()
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        model.choose(.event)
        XCTAssertEqual(model.chips.count, 2, "an event reads a day and a time")
        XCTAssertNil(model.values.priority)
    }

    // MARK: Tasks

    func testReturnCreatesATaskWithItsWritingAsOneUndoStep() async throws {
        model.open(on: .tasks(.now))
        type("Pay rent !! #home tomorrow 4pm")
        model.writing = "Bank details"
        await XCTAssertTrueAsync(await model.create())
        let task = try XCTUnwrap(liveTasks().first)
        XCTAssertEqual(task.title, "Pay rent")
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.tags, ["home"])
        XCTAssertEqual(task.dueDay, day(1))
        XCTAssertEqual(task.dueTimeMinutes, 16 * 60)
        XCTAssertEqual(task.status, .todo)
        XCTAssertTrue(TaskNoteConversion.hasWriting(task.id, in: ModelContext(container)))
        XCTAssertTrue(model.isOpen, "P4: Return adds the task and the card stays open")
        XCTAssertFalse(model.hasDraft)
        XCTAssertTrue(opened.isEmpty)

        XCTAssertEqual(library.undo(in: .tasks), .applied)
        XCTAssertTrue(liveTasks().isEmpty)
        XCTAssertFalse(TaskNoteConversion.hasWriting(task.id, in: ModelContext(container)))
        XCTAssertEqual(library.redo(in: .tasks), .applied)
        XCTAssertEqual(liveTasks().map(\.id), [task.id])
        XCTAssertTrue(TaskNoteConversion.hasWriting(task.id, in: ModelContext(container)))
    }

    func testCommandReturnCreatesAndOpensTheTasksPage() async throws {
        model.open(on: .tasks(.now))
        type("Call Sam")
        await XCTAssertTrueAsync(await model.create(openingPage: true))
        XCTAssertEqual(opened, [try XCTUnwrap(liveTasks().first).id])
    }

    func testLaterMakesAnUndatedPutOffTask() async throws {
        model.open(on: .tasks(.backlog))
        type("Someday")
        await XCTAssertTrueAsync(await model.create())
        let task = try XCTUnwrap(liveTasks().first)
        XCTAssertEqual(task.status, .backlog)
        XCTAssertNil(task.dueDay)
        XCTAssertTrue(toasts.isEmpty)
    }

    func testADatedTaskFromLaterGoesToNow() async throws {
        model.open(on: .tasks(.backlog))
        type("Dentist tomorrow")
        await XCTAssertTrueAsync(await model.create())
        XCTAssertEqual(try XCTUnwrap(liveTasks().first).status, .todo)
        XCTAssertEqual(toasts, ["Added to Now"])
    }

    func testDoneCreatesInNow() async throws {
        model.open(on: .tasks(.done))
        type("Follow up")
        await XCTAssertTrueAsync(await model.create())
        XCTAssertEqual(try XCTUnwrap(liveTasks().first).status, .todo)
        XCTAssertEqual(toasts, ["Added to Now"])
    }

    /// Review B-4: once closing starts, nothing creates.
    func testAClosedCardCreatesNothing() async {
        model.open(on: .tasks(.now))
        type("Not yet")
        model.close()
        await XCTAssertFalseAsync(await model.create())
        XCTAssertTrue(liveTasks().isEmpty)
        XCTAssertEqual(page.addBar.text, "Not yet", "the draft is kept")
    }

    func testEscapeKeepsTheDraftAndAnEmptyTitleCannotCreate() async {
        model.open(on: .tasks(.now))
        await XCTAssertFalseAsync(await model.create())
        type("Draft")
        model.writing = "kept"
        model.close()
        XCTAssertFalse(model.isOpen)
        model.open(on: .tasks(.now))
        XCTAssertEqual(page.addBar.text, "Draft")
        XCTAssertEqual(model.writing, "kept")
    }

    /// Accepted 2026-11-04 (#9): a page switch closes the card at once and
    /// whole; Escape and a click outside fold it back into "+". The draft
    /// is kept either way.
    func testAPageSwitchClosesTheCardAtOnceKeepingItsDraft() {
        model.open(on: .tasks(.now))
        type("Draft")
        model.close(atOnce: true)
        XCTAssertFalse(model.isOpen)
        XCTAssertTrue(model.closedAtOnce)
        model.open(on: .tasks(.now))
        XCTAssertEqual(page.addBar.text, "Draft")
        model.close()
        XCTAssertFalse(model.closedAtOnce, "Escape folds it")
    }

    /// Accepted 2026-11-04: a press anywhere outside the open card closes
    /// it (keeping its draft); a press on the card keeps it.
    func testAPressOutsideTheCardClosesIt() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        window.contentView = content
        let watcher = ComposerOutsideClick.Watcher(frame: NSRect(x: 100, y: 20, width: 289, height: 90))
        content.addSubview(watcher)
        var open = true
        watcher.isOpen = { open }
        func press(_ point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1))
        }
        XCTAssertFalse(watcher.closes(on: try press(NSPoint(x: 150, y: 60))), "on the card")
        XCTAssertTrue(watcher.closes(on: try press(NSPoint(x: 150, y: 300))), "on the list above it")
        XCTAssertTrue(watcher.closes(on: try press(NSPoint(x: 20, y: 30))), "on the bar beside it")
        open = false
        XCTAssertFalse(watcher.closes(on: try press(NSPoint(x: 150, y: 300))), "a closed card closes nothing")
    }

    /// Accepted 2026-11-03 (P4): Return or Create adds the task and the card
    /// stays open, empty, its title asked for the keyboard again; ⌘Return
    /// opens the task's page, so the card folds.
    func testReturnAddsTheTaskAndTheCardStaysOpenEmptyForTheNextOne() async throws {
        model.open(on: .tasks(.now))
        type("Call Sam")
        let asked = model.focusRequest
        model.submit()
        XCTAssertEqual(liveTasks().map(\.title), ["Call Sam"])
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(page.addBar.text, "")
        XCTAssertNotEqual(model.focusRequest, asked, "the title takes the keyboard for the next one")
        type("Call Ann")
        model.submit()
        XCTAssertEqual(Set(liveTasks().map(\.title)), ["Call Sam", "Call Ann"])
        XCTAssertTrue(model.isOpen)
        type("Open it")
        model.submit(openingPage: true)
        XCTAssertFalse(model.isOpen, "⌘Return opens the page and the card folds")
        XCTAssertEqual(opened.count, 1)
    }

    /// UX audit A2: a draft kept with Escape comes back after a quit and
    /// relaunch (a new model on the same defaults), and is gone once used.
    func testAKeptDraftComesBackAfterRelaunchAndGoesOnceUsed() throws {
        let suite = "ComposerDraft.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ComposerDraftStore(defaults: defaults)
        func relaunch() -> (TasksPageModel, ComposerModel) {
            let fixed = now
            let page = TasksPageModel(library: library, services: TasksPageServices(now: { fixed }))
            return (page, ComposerModel(tasks: page, services: ComposerServices(drafts: store)))
        }
        let (first, card) = relaunch()
        card.open(on: .tasks(.now))
        card.choose(.note)
        first.addBar = TaskAddBarText(text: "Plan the trip #travel")
        card.writing = "Book trains"
        card.close()
        let (second, again) = relaunch()
        XCTAssertEqual(second.addBar.text, "Plan the trip #travel")
        XCTAssertEqual(again.writing, "Book trains")
        XCTAssertEqual(again.kind, .note)
        // The app quitting with the card open keeps what it holds too.
        again.open(on: .tasks(.now))
        second.addBar = TaskAddBarText(text: "Plan the trip, then pack")
        again.saveKeptDraft()
        let (third, card3) = relaunch()
        XCTAssertEqual(third.addBar.text, "Plan the trip, then pack")
        card3.open(on: .notes)
        card3.submit()
        XCTAssertNil(store.load(), "a used draft is not kept")
        let (fourth, card4) = relaunch()
        XCTAssertEqual(fourth.addBar.text, "")
        XCTAssertEqual(card4.writing, "")
    }

    /// B1: a long title wraps into the writing line's space while the
    /// writing is empty and not being typed in.
    func testALongTitleTakesTheWritingLinesSpaceOnlyWhileTheWritingIsEmpty() {
        XCTAssertTrue(ComposerCard.titleTakesWritingSpace(titleWraps: true, writing: "", writingFocused: false))
        XCTAssertFalse(ComposerCard.titleTakesWritingSpace(titleWraps: false, writing: "", writingFocused: false))
        XCTAssertFalse(ComposerCard.titleTakesWritingSpace(titleWraps: true, writing: "notes", writingFocused: false))
        XCTAssertFalse(ComposerCard.titleTakesWritingSpace(titleWraps: true, writing: "", writingFocused: true))
    }

    // MARK: Events

    func testAnEventIsWrittenThroughTheWriterAndUndoneWithIt() async throws {
        model.open(on: .calendar(selected: day(2)))
        await model.loadCalendars()
        XCTAssertEqual(model.calendars.map(\.id), ["home", "work"])
        XCTAssertEqual(model.selectedCalendar?.id, "home")
        model.calendarID = "work"
        model.eventLength = 90
        type("Lunch with Ana 1pm")
        await XCTAssertTrueAsync(await model.create())
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

    func testAnEventsWritingLineBecomesItsNotesAndUndoStillRemovesIt() async throws {
        model.open(on: .calendar(selected: day(1)))
        await model.loadCalendars()
        type("Dentist 9am")
        model.writing = "  Bring the form\nRoom 4  "
        await XCTAssertTrueAsync(await model.create())
        let event = try XCTUnwrap(events.events.values.first)
        XCTAssertEqual(event.draft.notes, "Bring the form\nRoom 4")
        XCTAssertEqual(model.writing, "")
        XCTAssertEqual(library.undo(in: .calendar), .applied)
        XCTAssertTrue(events.events.isEmpty)
        XCTAssertEqual(library.redo(in: .calendar), .applied)
        XCTAssertEqual(events.events.values.first?.draft.notes, "Bring the form\nRoom 4")
    }

    func testAWhitespaceWritingLineWritesNoNotes() async throws {
        model.open(on: .calendar(selected: day(1)))
        await model.loadCalendars()
        type("Gym")
        model.writing = " \n "
        await XCTAssertTrueAsync(await model.create())
        XCTAssertNil(try XCTUnwrap(events.events.values.first).draft.notes)
    }

    func testAnEventWithNoTimeIsAllDayAndCommandReturnOpensIt() async throws {
        model.open(on: .calendar(selected: day(1)))
        await model.loadCalendars()
        type("Holiday")
        await XCTAssertTrueAsync(await model.create(openingPage: true))
        let event = try XCTUnwrap(events.events.values.first)
        XCTAssertTrue(event.draft.isAllDay)
        XCTAssertEqual(event.draft.start, day(1).startDate(in: clock).flatMap { clock.startOfDay(for: $0) })
        XCTAssertEqual(openedEvents.count, 1)
    }

    func testATaskMadeOnCalendarIsOneStepInCalendarsHistory() async throws {
        model.open(on: .calendar(selected: day(1)))
        await model.loadCalendars()
        model.choose(.task)
        type("Buy flowers")
        await XCTAssertTrueAsync(await model.create())
        XCTAssertEqual(try XCTUnwrap(liveTasks().first).dueDay, day(1))
        XCTAssertTrue(events.events.isEmpty)
        XCTAssertEqual(library.undo(in: .calendar), .applied)
        XCTAssertTrue(liveTasks().isEmpty)
    }

    func testAFailedEventWriteKeepsTheDraft() async {
        let failureToast = PanelToastCenter()
        model.services.eventFailure = { [failureToast] message in failureToast.showFailure(message) }
        model.services.makeWriter = { throw CalendarEventWriteError.accessDenied }
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        type("Standup 9am")
        await XCTAssertFalseAsync(await model.create())
        XCTAssertTrue(model.isOpen)
        XCTAssertTrue(model.failed)
        XCTAssertEqual(page.addBar.text, "Standup 9am")
        XCTAssertEqual(failureToast.current?.isFailure, true, "Calendar reports the red failure toast")
        XCTAssertEqual(failureToast.current?.actionTitle, "OK")
        XCTAssertFalse(failureToast.current?.answersUndoKey ?? true, "the failed save did not create an Undo step")
        XCTAssertFalse(failureToast.hasPendingDismissalForTesting, "failure persists for acknowledgement")
    }

    // MARK: Quick note

    func testAQuickNoteIsFiledInNotesWithItsTagsAndPin() async throws {
        model.open(on: .tasks(.now), as: .note)
        type("Gift ideas #home")
        model.writing = "Scarf"
        model.pinned = true
        await XCTAssertTrueAsync(await model.create())
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

    /// Review B-1: the toast undoes the history its creation went into,
    /// even after the card moved to another page.
    func testAToastsUndoUndoesTheHistoryItsCreationWentInto() async throws {
        model.open(on: .tasks(.now), as: .note)
        type("Tasks-side idea")
        await XCTAssertTrueAsync(await model.create())
        let note = try XCTUnwrap(notes.notes.first { $0.deletedAt == nil })
        let undo = try XCTUnwrap(toastUndos.last)
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        model.close()
        XCTAssertEqual(undo(), .applied)
        XCTAssertNil(notes.notes.first { $0.id == note.id && $0.deletedAt == nil }, "the note went, not a Calendar step")
    }

    func testCommandReturnOpensTheNoteInNotes() async throws {
        model.open(on: .tasks(.now), as: .note)
        type("Reading list")
        await XCTAssertTrueAsync(await model.create(openingPage: true))
        XCTAssertEqual(openedNotes.count, 1)
        XCTAssertTrue(toasts.isEmpty)
    }

    // MARK: Phase A fixes (review of 15109359)

    private func rows<T: PersistentModel>(_ type: T.Type) throws -> [T] {
        try ModelContext(container).fetch(FetchDescriptor<T>())
    }

    func testAFailedSaveLeavesNoTaskNoWritingNoStepAndARetryMakesOne() async throws {
        model.open(on: .tasks(.now))
        type("Pay rent")
        model.writing = "Bank details"
        saveFailure.on = true
        await XCTAssertFalseAsync(await model.create())
        XCTAssertTrue(try rows(TaskItem.self).isEmpty, "no live or Recently Deleted task")
        XCTAssertTrue(try rows(NoteItem.self).isEmpty)
        XCTAssertTrue(try rows(TaskNoteAssociation.self).isEmpty)
        XCTAssertFalse(library.undo.canUndo(in: .tasks))
        XCTAssertTrue(model.isOpen)
        XCTAssertTrue(model.failed)
        XCTAssertEqual(page.addBar.text, "Pay rent")
        XCTAssertEqual(model.writing, "Bank details")

        saveFailure.on = false
        await XCTAssertTrueAsync(await model.create())
        XCTAssertEqual(try rows(TaskItem.self).count, 1)
        let task = try XCTUnwrap(liveTasks().first)
        XCTAssertTrue(TaskNoteConversion.hasWriting(task.id, in: ModelContext(container)))
        XCTAssertEqual(library.undo(in: .tasks), .applied)
        XCTAssertTrue(liveTasks().isEmpty)
    }

    func testAPinThatCannotSaveKeepsTheCardOpenWithTheDraft() async throws {
        model.open(on: .tasks(.now), as: .note)
        type("Pinned idea")
        model.pinned = true
        saveFailure.on = true
        await XCTAssertFalseAsync(await model.create())
        XCTAssertTrue(model.isOpen)
        XCTAssertTrue(model.failed)
        XCTAssertTrue(model.pinned)
        XCTAssertTrue(try rows(NoteItem.self).isEmpty)
        XCTAssertTrue(toasts.isEmpty)

        saveFailure.on = false
        await XCTAssertTrueAsync(await model.create())
        XCTAssertTrue(try XCTUnwrap(notes.notes.first).isPinned)
    }

    func testATypedDayReplacesCalendarsPickedDayEvenAtTheCaret() async throws {
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        type("Lunch tomorrow")
        await XCTAssertTrueAsync(await model.create(openingPage: true))
        let event = try XCTUnwrap(events.events.values.first)
        XCTAssertEqual(event.draft.title, "Lunch")
        XCTAssertEqual(DueDay(date: event.draft.start, calendar: clock), day(1))
    }

    func testCalendarUndoReachesTheNewestCalendarActionWhateverItsKind() async throws {
        let b = try XCTUnwrap(library.createTasks([TaskDraft(title: "B")])?.first)
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        type("A 1pm")
        await XCTAssertTrueAsync(await model.create())
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

    /// The full Tasks page and its overlaid card share a key window. A
    /// printable key belongs to the card on either tab, never to Find.
    func testTypingInOpenTaskComposerDoesNotReachSearchOnDoneOrNow() throws {
        try requireKeyWindowTests()
        let composer = try XCTUnwrap(model)
        let size = CGSize(width: AtticLayout.panelSize.width, height: 520)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: size)
        let route = PanelComposerRoute(
            open: { page, kind in composer.open(on: page, as: kind) },
            isOpen: { composer.isOpen }
        )

        for tab in [TasksTab.done, .now] {
            page.select(tab: tab)
            composer.open(on: .tasks(tab))
            let host = NSHostingView(rootView: TasksPage(
                model: page, store: tasks, layout: layout, addBarFocused: .constant(false)
            )
            .environment(\.panelComposer, route)
            .overlay(alignment: .bottomTrailing) { ComposerCard(model: composer) }
            .atticDesign(AtticDesignContext(mode: .light))
            .frame(width: size.width, height: size.height))
            let window = KeyWindow(
                contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            window.becomeKey()
            windows.append(window)
            spin(0.4)

            let field = try XCTUnwrap(composer.editor.textView)
            XCTAssertTrue(window.makeFirstResponder(field))
            spin(0.1)
            XCTAssertTrue(window.firstResponder === field, "\(tab): composer starts with the keyboard")
            for (letter, code) in [("c", UInt16(8)), ("a", UInt16(0)), ("t", UInt16(17))] {
                key(window, letter, code: code)
                XCTAssertTrue(window.firstResponder === field, "\(tab): \(letter) did not steal the caret")
                XCTAssertEqual(page.searchQuery(for: tab), "", "\(tab): \(letter) never entered Find")
            }
            XCTAssertEqual(page.addBar.text, "cat", "\(tab): the card receives the typed text")
            composer.close(atOnce: true)
            window.contentView = nil
            window.close()
            page.addBar = TaskAddBarText(text: "")
        }
    }

    func testPriorityWidensFoldsItsNeighboursAndEscapeHasTwoSteps() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let (window, hosting, field) = try mountForKeys(on: .tasks(.now))
        typeKeys(field, "Keep priority !")
        @MainActor func elements(_ root: AnyObject) -> [AnyObject] {
            [root] + ((root.accessibilityChildren?() ?? nil) ?? []).flatMap { elements($0 as AnyObject) }
        }
        @MainActor func element(_ id: String) -> AnyObject? {
            hosting.layoutSubtreeIfNeeded()
            return elements(hosting).first { $0.accessibilityIdentifier?() == id }
        }
        let create = try XCTUnwrap((element("composer-create") as? NSAccessibilityElementProtocol)?.accessibilityFrame())
        let priority = try XCTUnwrap(element("composer-chip-priority"))
        XCTAssertTrue(priority.accessibilityPerformPress?() ?? false)
        spin()
        XCTAssertNotNil(element("composer-priority-low"), "choices widen in the card")
        XCTAssertEqual(model.values.priority, .medium, "typed ! keeps the existing parser meaning")
        XCTAssertNil(element("composer-chip-date"))
        XCTAssertNil(element("composer-chip-tags"))
        XCTAssertNotNil(element("composer-create"))
        window.makeFirstResponder(field)
        key(window, "\u{1b}", code: 53)
        XCTAssertTrue(model.isOpen, "first Escape closes only the choices")
        XCTAssertNotNil(element("composer-chip-date"))
        XCTAssertNotNil(element("composer-chip-tags"))
        key(window, "\u{1b}", code: 53)
        XCTAssertFalse(model.isOpen)
        XCTAssertEqual(page.addBar.text, "Keep priority !")
        model.open(on: .tasks(.now)); spin()
        XCTAssertTrue(try XCTUnwrap(element("composer-chip-priority")).accessibilityPerformPress?() ?? false)
        spin()
        XCTAssertTrue(try XCTUnwrap(element("composer-priority-high")).accessibilityPerformPress?() ?? false)
        spin()
        XCTAssertEqual(model.values.priority, .high)
        XCTAssertNil(element("composer-priority-high"), "picking closes the levels")
        XCTAssertNotNil(element("composer-chip-date"))
        XCTAssertNotNil(element("composer-chip-tags"))
        let restoredCreate = try XCTUnwrap((element("composer-create") as? NSAccessibilityElementProtocol)?.accessibilityFrame())
        XCTAssertEqual(restoredCreate, create, "Create stays in place")

    }

    func testReturnInTheTitleCreatesAndTheCardStaysOpenInTheTitle() throws {
        let (window, _, field) = try mountForKeys(on: .tasks(.now))
        typeKeys(field, "Call Sam")
        key(window, "\r", code: 36)
        XCTAssertEqual(liveTasks().map(\.title), ["Call Sam"])
        XCTAssertTrue(model.isOpen, "P4: the card stays open")
        XCTAssertTrue(window.firstResponder === field, "ready for the next one")
        XCTAssertEqual(field.string, "")
        XCTAssertTrue(opened.isEmpty)
    }

    /// UX audit A4: Tab and ⇧Tab move between the title and the writing
    /// line and never leave the card.
    func testTabAndShiftTabStayInsideTheCard() throws {
        let (window, hosting, field) = try mountForKeys(on: .tasks(.now))
        typeKeys(field, "Call Sam")
        @MainActor func inWriting() -> Bool {
            guard let editor = window.firstResponder as? NSTextView, editor !== field else { return false }
            return (editor.delegate as? NSView)?.isDescendant(of: hosting) ?? editor.isDescendant(of: hosting)
        }
        key(window, "\t", code: 48)
        XCTAssertTrue(inWriting(), "Tab from the title goes to the writing line, not out of the card")
        key(window, "\t", code: 48)
        XCTAssertTrue(window.firstResponder === field, "Tab from the writing line comes back to the title")
        key(window, "\u{19}", code: 48, modifiers: .shift)
        XCTAssertTrue(inWriting(), "⇧Tab from the title goes to the writing line")
        key(window, "\u{19}", code: 48, modifiers: .shift)
        XCTAssertTrue(window.firstResponder === field, "⇧Tab from the writing line comes back to the title")
        XCTAssertEqual(page.addBar.text, "Call Sam")
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

    /// Review B-4: Escape then Return at once (the shrink still drawing)
    /// creates nothing, and the keyboard has left the card.
    func testReturnRightAfterEscapeCreatesNothing() throws {
        let (window, _, field) = try mountForKeys(on: .tasks(.now))
        typeKeys(field, "Keep me too")
        key(window, "\u{1B}", code: 53)
        key(window, "\r", code: 36)
        XCTAssertTrue(liveTasks().isEmpty)
        XCTAssertFalse(window.firstResponder === field, "the keyboard leaves the card as it closes")
        XCTAssertEqual(page.addBar.text, "Keep me too")
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

    /// Review B-2: in the panel, Tab after the last row reaches the shown
    /// "+", never the add bar or its strip that the panel no longer draws.
    func testInThePanelTabReachesThePlusNotTheAddBar() {
        let a = UUID(), b = UUID()
        let stops = TasksTabOrder.stops(find: true, rows: [(a, []), (b, [])], strip: true, plus: true)
        XCTAssertEqual(stops, [.find, .row(a), .row(b), .plus])
        XCTAssertEqual(TasksTabOrder.next(after: .row(b), in: stops, forward: true), .plus)
        XCTAssertEqual(TasksTabOrder.next(after: .plus, in: stops, forward: true), .find)
        XCTAssertEqual(TasksTabOrder.stops(find: false, rows: [(a, [])], strip: false), [.row(a), .addBar], "hosted on its own: as before")
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

    func testFollowupChangingKindsClosesThePreviousKindsInlinePicker() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let view = host(.task, on: .calendar(selected: today))
        func elements(_ root: AnyObject) -> [AnyObject] {
            [root] + ((root.accessibilityChildren?() ?? nil) ?? []).flatMap { elements($0 as AnyObject) }
        }
        func element(_ id: String) -> AnyObject? {
            view.layoutSubtreeIfNeeded()
            return elements(view).first { $0.accessibilityIdentifier?() == id }
        }
        XCTAssertTrue(try XCTUnwrap(element("composer-chip-priority")).accessibilityPerformPress?() ?? false)
        spin(0.1)
        XCTAssertNotNil(element("composer-priority-low"))
        model.choose(.event); spin(0.1)
        model.choose(.task); spin(0.1)
        XCTAssertNil(element("composer-priority-low"), "switching kind closes its old inline picker")
        XCTAssertNotNil(element("composer-chip-date"))
        XCTAssertNotNil(element("composer-chip-tags"))
    }

    func testFollowupEventGetsLengthAndCalendarRowsAndGrowsTheListRoom() async throws {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        model.open(on: .calendar(selected: today), as: .event)
        await model.loadCalendars()
        type("Appointment tomorrow at 10am")
        let view = host(.event, on: .calendar(selected: today))
        spin(0.2)
        func elements(_ root: AnyObject) -> [AnyObject] {
            [root] + ((root.accessibilityChildren?() ?? nil) ?? []).flatMap { elements($0 as AnyObject) }
        }
        let all = elements(view)
        func frame(_ id: String) throws -> CGRect {
            let element = try XCTUnwrap(all.first { $0.accessibilityIdentifier?() == id }, id)
            return try XCTUnwrap(element.accessibilityFrame?())
        }
        let date = try frame("composer-chip-date"), length = try frame("composer-chip-length"), calendar = try frame("composer-chip-calendar")
        XCTAssertGreaterThan(abs(date.midY - length.midY), 20, "length has its own row")
        XCTAssertGreaterThan(abs(length.midY - calendar.midY), 20, "calendar has its own row")
        XCTAssertGreaterThan(view.fittingSize.height, ComposerMetrics.height + 40)
        // The chip hugs its name (Accepted 2026-11-04: the Date hover was
        // far too wide); the row leaves a long name its room before Create.
        XCTAssertGreaterThan(try frame("composer-create").minX - calendar.minX, 150, "calendar names have room")
        let room = PanelComposerRoom()
        let overlay = NSHostingView(rootView: ComposerOverlay(model: model,
            layout: PanelPageLayout(cornerSize: 28, panelSize: CGSize(width: 352, height: 520)), room: room)
            .frame(width: 352, height: 520))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 352, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = overlay; windows.append(window)
        spin(0.4); overlay.layoutSubtreeIfNeeded(); spin(0.1)
        XCTAssertEqual(room.height, view.fittingSize.height, accuracy: 1, "the inset follows the actual Event card")
    }

    func testTheCardKeepsTheTasksHeightExceptForEvents() {
        let task = host(nil, on: .calendar(selected: today)).fittingSize
        XCTAssertEqual(task.width, ComposerMetrics.width, accuracy: 0.5)
        var heights: [CGFloat] = []
        for kind in [ComposerKind.task, .event, .note] {
            model.choose(kind)
            let view = host(kind, on: .calendar(selected: today))
            heights.append(view.fittingSize.height)
        }
        XCTAssertEqual(heights[0], heights[2], accuracy: 1, "Task and Note keep the compact card")
        XCTAssertGreaterThan(heights[1], heights[0], "P4 supersedes the old same-height Event card")
        // P4: 9 + 20 + 5 + 15 + 5 + 28 + 8 = 90 (the design's 180 px).
        XCTAssertEqual(heights[0], ComposerMetrics.height, accuracy: 1)
        XCTAssertEqual(ComposerMetrics.height, 90)
    }

    /// B1 on screen: a title too long for one line wraps into the writing
    /// line's space, and the card keeps its 90 pt.
    func testALongTitleWrapsAndTheCardKeepsItsHeight() {
        let short = host(nil, on: .tasks(.now)).fittingSize.height
        type("Ring the plumber about the dripping kitchen tap before the weekend")
        let view = host(nil, on: .tasks(.now))
        for _ in 0..<3 { view.layoutSubtreeIfNeeded(); spin(0.05) }
        XCTAssertEqual(view.fittingSize.height, short, accuracy: 1, "the card keeps its height")
        @MainActor func elements(_ root: AnyObject) -> [AnyObject] {
            [root] + ((root.accessibilityChildren?() ?? nil) ?? []).flatMap { elements($0 as AnyObject) }
        }
        XCTAssertNil(elements(view).first { $0.accessibilityIdentifier?() == "composer-writing" },
                     "the writing line gives its space to the title")
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
