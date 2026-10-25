import AppKit
import SwiftData
import XCTest
@testable import Attic

/// The Reminders replica, slice R1 (owner, 2026-10-25: "Reminders replica
/// first, then adapt"): the setting, adding, the menu's order, the keys and
/// the completion allowlist.
@MainActor
final class RemindersReplicaR1Tests: XCTestCase {
    private let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000)) // Mon 21 Sep 2026, UTC
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private var store: TaskStore!
    private var library: AtticLibrary!
    private var model: TasksPageModel!

    override func setUp() async throws {
        store = try makeTestStore(now: { [clock] in clock.value })
        library = AtticLibrary(tasks: store, now: { [clock] in clock.value })
        model = makeModel(doneHold: .seconds(3_600))
    }

    override func tearDown() {
        model = nil
        library = nil
        store = nil
    }

    private func makeModel(doneHold: Duration) -> TasksPageModel {
        let calendar = self.calendar
        let model = TasksPageModel(library: library, services: TasksPageServices(
            now: { [clock] in clock.value },
            calendar: { calendar },
            locale: Locale(identifier: "en_GB"),
            doneHold: doneHold
        ))
        model.toasts.holdDuration = 3_600
        return model
    }

    private var today: DueDay { DueDay(date: clock.value, calendar: calendar) }
    private func day(_ offset: Int) -> DueDay {
        DueDay(date: calendar.date(byAdding: .day, value: offset, to: clock.value)!, calendar: calendar)
    }
    private func titles(_ tab: TasksTab = .now) -> [String] { model.rows(for: tab).map(\.model.title) }

    private func type(_ text: String) {
        model.replicaDraft.draft.text = text
    }

    // MARK: Setting

    func testListStyleDefaultsToAtticAndPersists() throws {
        let suite = "RemindersReplicaR1Tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.tasksListStyle, .attic, "Attic is the default")
        XCTAssertNil(defaults.object(forKey: "tasksListStyle"), "the default is not written")
        settings.tasksListStyle = .reminders
        XCTAssertEqual(AppSettings(defaults: defaults).tasksListStyle, .reminders)
        settings.tasksListStyle = .attic
        XCTAssertEqual(AppSettings(defaults: defaults).tasksListStyle, .attic)
        XCTAssertEqual(TasksListStyle.allCases.map(\.title), ["Attic", "Reminders (replica)"])
    }

    func testAModelStartsInAtticStyleWithNoReplicaState() {
        XCTAssertEqual(model.listStyle, .attic)
        XCTAssertFalse(model.replicaRowActive)
        model.beginReplicaRow()
        XCTAssertFalse(model.replicaRowActive, "the new-reminder row only opens in the replica")
    }

    // MARK: Adding

    func testReturnCommitsTheTitleBelowTheRowsAndKeepsAFreshRowFocused() throws {
        model.setListStyle(.reminders)
        model.addBar.text = "First"
        _ = model.submitAddBar()
        model.addBar.text = "Second"
        _ = model.submitAddBar()
        XCTAssertEqual(titles(), ["Second", "First"], "Attic's add bar puts new tasks on top")
        model.beginReplicaRow()
        let request = model.replicaRowFocusRequest
        type("Third")
        let id = try XCTUnwrap(model.submitReplicaRow())
        XCTAssertEqual(store.task(withID: id)?.title, "Third")
        XCTAssertEqual(titles(), ["Second", "First", "Third"], "the new reminder lands below the rows")
        XCTAssertTrue(model.replicaRowActive, "a fresh row stays right below it")
        XCTAssertEqual(model.replicaDraft.draft, RemindersReplicaDraft(), "the fresh row is empty")
        XCTAssertGreaterThan(model.replicaRowFocusRequest, request, "and takes the keyboard")
        type("Fourth")
        _ = try XCTUnwrap(model.submitReplicaRow())
        XCTAssertEqual(titles(), ["Second", "First", "Third", "Fourth"], "repeated entry keeps the typed order")
    }

    func testReturnOnAnEmptyRowReusesItWithoutASecondBlank() {
        model.setListStyle(.reminders)
        model.beginReplicaRow()
        type("   ")
        XCTAssertNil(model.submitReplicaRow())
        XCTAssertTrue(store.orderedTasks(for: .todo).isEmpty, "no task is made")
        XCTAssertTrue(model.replicaRowActive, "the same row stays open")
        XCTAssertNil(model.submitReplicaRow())
        XCTAssertTrue(store.orderedTasks(for: .todo).isEmpty)
    }

    func testEscapeDropsABlankRow() {
        model.setListStyle(.reminders)
        model.beginReplicaRow()
        model.endReplicaRow()
        XCTAssertFalse(model.replicaRowActive)
        XCTAssertTrue(store.orderedTasks(for: .todo).isEmpty)
    }

    func testEscapeKeepsTypedWordsAsATask() {
        model.setListStyle(.reminders)
        model.beginReplicaRow()
        type("Kept")
        model.endReplicaRow()
        XCTAssertFalse(model.replicaRowActive)
        XCTAssertEqual(titles(), ["Kept"])
    }

    func testATypedDateIsOnlyOfferedUntilAccepted() throws {
        let parser = model.parser
        var draft = RemindersReplicaDraft(text: "Pay rent tomorrow")
        let offered = try XCTUnwrap(draft.recognisedDate(parser: parser))
        XCTAssertEqual((draft.text as NSString).substring(with: offered.range), "tomorrow")
        let unaccepted = try XCTUnwrap(draft.taskDraft(parser: parser, status: .todo))
        XCTAssertEqual(unaccepted.title, "Pay rent tomorrow", "unaccepted date words stay in the title")
        XCTAssertNil(unaccepted.dueDay)
        XCTAssertNotNil(draft.acceptDate(parser: parser))
        XCTAssertEqual(draft.text, "Pay rent", "accepting removes the words and one boundary space")
        let accepted = try XCTUnwrap(draft.taskDraft(parser: parser, status: .todo))
        XCTAssertEqual(accepted.title, "Pay rent")
        XCTAssertEqual(accepted.dueDay, offered.day)
        XCTAssertNil(draft.recognisedDate(parser: parser), "an accepted date is not offered again")
    }

    func testAcceptingADateInTheMiddleLeavesOneSpace() throws {
        var draft = RemindersReplicaDraft(text: "Call tomorrow about rent")
        XCTAssertNotNil(draft.acceptDate(parser: model.parser))
        XCTAssertEqual(draft.text, "Call about rent")
    }

    func testAcceptedDateReachesTheSavedTask() throws {
        model.setListStyle(.reminders)
        model.beginReplicaRow()
        type("Pay rent tomorrow")
        XCTAssertTrue(model.acceptReplicaDate())
        let id = try XCTUnwrap(model.submitReplicaRow())
        let task = try XCTUnwrap(store.task(withID: id))
        XCTAssertEqual(task.title, "Pay rent")
        XCTAssertEqual(task.dueDay, day(1))
    }

    func testHashTagBecomesARealTag() throws {
        model.setListStyle(.reminders)
        model.beginReplicaRow()
        type("Buy milk #home")
        let id = try XCTUnwrap(model.submitReplicaRow())
        let task = try XCTUnwrap(store.task(withID: id))
        XCTAssertEqual(task.title, "Buy milk")
        XCTAssertEqual(task.tags, ["home"])
        XCTAssertTrue(library.tags.names.contains("home"), "the tag is in the library")
    }

    func testTagHandlingWaitsWhileAnInputMethodComposes() {
        var draft = RemindersReplicaDraft(text: "Buy #ho")
        draft.isComposing = true
        XCTAssertTrue(draft.tagPieces(parser: model.parser).isEmpty)
        XCTAssertTrue(draft.highlights(parser: model.parser).isEmpty)
        draft.isComposing = false
        XCTAssertEqual(draft.tagPieces(parser: model.parser).map(\.tag), ["ho"])
    }

    // MARK: Menu and keys

    func testMenuFollowsRemindersMeasuredOrder() {
        XCTAssertEqual(RemindersReplicaMenu.commands(removeFromTasks: true),
                       [.complete, .date, .priority, .list, .tags, .copy, .removeFromTasks, .delete])
        XCTAssertEqual(RemindersReplicaMenu.commands(removeFromTasks: false),
                       [.complete, .date, .priority, .list, .tags, .copy, .delete])
        let leftOut = RemindersReplicaMenu.leftOut.map(\.0)
        XCTAssertEqual(leftOut, [.askSiri, .markUrgent, .indent, .outdent, .newSection, .newSectionWithSelection,
                                 .editSections, .flag, .cut, .paste])
    }

    func testReplicaKeys() {
        func command(_ characters: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags) -> RemindersReplicaKeys.Command? {
            RemindersReplicaKeys.command(characters: characters, keyCode: code, modifiers: modifiers)
        }
        XCTAssertEqual(command("n", 45, .command), .newReminder)
        XCTAssertEqual(command("i", 34, .command), .showInfo)
        XCTAssertEqual(command("c", 8, [.command, .shift]), .complete)
        XCTAssertEqual(command("t", 17, [.command, .shift]), .addTag)
        XCTAssertNil(command("f", 3, [.command, .shift]), "⇧⌘F stays Attic's Search Done Tasks")
        XCTAssertNil(command("c", 8, .command), "⌘C stays Copy")
        XCTAssertNil(command("i", 34, [.command, .shift]), "⇧⌘I stays Attic's actions menu")
    }

    // MARK: Completion

    func testACompletedRowStaysUntilTheListIsLeft() async throws {
        model = makeModel(doneHold: .milliseconds(20))
        model.setListStyle(.reminders)
        model.addBar.text = "A"
        let a = try XCTUnwrap(model.submitAddBar())
        model.addBar.text = "B"
        _ = try XCTUnwrap(model.submitAddBar())
        XCTAssertTrue(model.complete(a).isApplied)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.sections(for: .now).open.map(\.id).contains(a), true,
                       "the replica keeps it where it was (no timer)")
        model.select(tab: .backlog)
        model.select(tab: .now)
        XCTAssertFalse(model.sections(for: .now).open.map(\.id).contains(a), "navigating lets it go")
    }

    func testAtticStyleStillReleasesOnItsTimer() async throws {
        model = makeModel(doneHold: .milliseconds(20))
        model.addBar.text = "A"
        let a = try XCTUnwrap(model.submitAddBar())
        XCTAssertTrue(model.complete(a).isApplied)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(model.sections(for: .now).open.map(\.id).contains(a))
    }

    func testLeavingTheReplicaReleasesItsKeptRows() throws {
        model.setListStyle(.reminders)
        model.addBar.text = "A"
        let a = try XCTUnwrap(model.submitAddBar())
        XCTAssertTrue(model.complete(a).isApplied)
        XCTAssertTrue(model.sections(for: .now).open.map(\.id).contains(a))
        model.setListStyle(.attic)
        XCTAssertFalse(model.sections(for: .now).open.map(\.id).contains(a))
    }

    func testUndoBringsACompletedRowBack() throws {
        model.setListStyle(.reminders)
        model.addBar.text = "A"
        let a = try XCTUnwrap(model.submitAddBar())
        XCTAssertTrue(model.complete(a).isApplied)
        XCTAssertTrue(model.undo().isApplied)
        XCTAssertEqual(store.task(withID: a)?.status, .todo)
    }

    // MARK: Row values

    func testRowHeightsFollowTheMeasuredSamples() {
        let m = RemindersReplicaMetrics.self
        XCTAssertEqual(m.rowHeight(titleLines: 1, notesLines: 0, hasDateLine: false), 32)
        XCTAssertEqual(m.rowHeight(titleLines: 1, notesLines: 0, hasDateLine: true), 48)
        XCTAssertEqual(m.rowHeight(titleLines: 2, notesLines: 0, hasDateLine: true), 64)
        XCTAssertEqual(m.titleX, 45)
        XCTAssertEqual(m.circleX + m.circleFrame / 2, 25.25, "the circle's measured centre")
        XCTAssertEqual(m.rowHeight(titleLines: 1, notesLines: 2, hasDateLine: true), 79, "notes and a date (UI-GEO-01 row 12)")
        XCTAssertEqual(m.rowHeight(titleLines: 1, notesLines: 8, hasDateLine: true), 169, "eight notes lines (row 22)")
    }

    func testPriorityMarksAndDateLine() throws {
        XCTAssertNil(RemindersReplicaText.priorityMark(.none))
        XCTAssertEqual(RemindersReplicaText.priorityMark(.low), "!")
        XCTAssertEqual(RemindersReplicaText.priorityMark(.medium), "!!")
        XCTAssertEqual(RemindersReplicaText.priorityMark(.high), "!!!")
        let locale = Locale(identifier: "en_GB")
        func line(_ days: Int) -> (String, RemindersReplicaText.DateTone) {
            let day = self.day(days)
            let result = RemindersReplicaText.dateLine(day, today: today, calendar: calendar, locale: locale)
            return (result.text, result.tone)
        }
        XCTAssertEqual(line(0).0, "Today"); XCTAssertEqual(line(0).1, .quiet)
        XCTAssertEqual(line(1).0, "Tomorrow"); XCTAssertEqual(line(1).1, .quiet)
        XCTAssertEqual(line(-1).0, "Yesterday"); XCTAssertEqual(line(-1).1, .overdue)
        XCTAssertEqual(line(-3).1, .overdue)
        XCTAssertEqual(line(8).0, "29/09/2026", "numeric day/month/year")
    }

    func testNotesPreviewComesFromTheWritingWithoutTheTitle() {
        XCTAssertNil(RemindersReplicaText.notesPreview(plainText: "Title only"))
        XCTAssertEqual(RemindersReplicaText.notesPreview(plainText: "Title\n\nFirst line\nSecond"), "First line\nSecond")
    }

    func testReplicaRowsCarryTheWritingPreviewOnlyWhileOn() throws {
        model.addBar.text = "A"
        let a = try XCTUnwrap(model.submitAddBar())
        model.setNotePreviews([a: "Some writing"])
        XCTAssertNil(model.rows(for: .now).first?.model.notes, "Attic's rows never carry it")
        model.setListStyle(.reminders)
        model.setNotePreviews([a: "Some writing"])
        XCTAssertEqual(model.rows(for: .now).first?.model.notes, "Some writing")
        model.setListStyle(.attic)
        XCTAssertNil(model.rows(for: .now).first?.model.notes)
    }
}
