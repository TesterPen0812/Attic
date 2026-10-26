import AppKit
import SwiftData
import XCTest
@testable import Attic

/// List Style: New, Build A (owner, 2026-10-26: "Main page direction: D2"
/// and the six detail picks; FINAL.md § 2–4): short dates, the column that
/// takes turns, a ticked row kept until the list changes, one capture
/// path, Esc keeping edits, Tab and ⇧Tab, single keys, the bottom taking
/// turns, and the two settings.
@MainActor
final class NewStyleMainPageTests: XCTestCase {
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
        model = makeModel(doneHold: .milliseconds(20))
        model.setListStyle(.new)
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
    private func add(_ title: String) throws -> UUID {
        model.addBar.text = title
        return try XCTUnwrap(model.submitAddBar())
    }
    private func openIDs(_ tab: TasksTab = .now) -> [UUID] { model.sections(for: tab).open.map(\.id) }
    private func short(_ offset: Int) -> (String, TasksNewText.Tone) {
        let result = TasksNewText.shortDate(day(offset), today: today, calendar: calendar, locale: Locale(identifier: "en_GB"))
        return (result.text, result.tone)
    }

    // MARK: Settings

    func testListStyleNewIsAThirdChoiceThatPersistsWithAtticTheDefault() throws {
        let suite = "NewStyleMainPageTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.tasksListStyle, .attic, "Attic stays the default")
        settings.tasksListStyle = .new
        XCTAssertEqual(defaults.string(forKey: "tasksListStyle"), "new")
        XCTAssertEqual(AppSettings(defaults: defaults).tasksListStyle, .new)
        XCTAssertEqual(TasksListStyle.allCases, [.attic, .reminders, .new])
        XCTAssertTrue(TasksListStyle.new.isNew && TasksListStyle.new.usesReplicaMachinery && !TasksListStyle.new.isReplica)
    }

    func testGlassTintIsOffByDefaultAndPersists() throws {
        let suite = "NewStyleMainPageTests-tint-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.panelGlassTint, "off by default")
        XCTAssertNil(defaults.object(forKey: "panelGlassTint"), "the default is not written")
        settings.panelGlassTint = true
        XCTAssertTrue(AppSettings(defaults: defaults).panelGlassTint)
        settings.panelGlassTint = false
        XCTAssertFalse(AppSettings(defaults: defaults).panelGlassTint)
        XCTAssertEqual(PanelGlassTint.opacity, 0.22, accuracy: 0.001, "20–25 %, never near-opaque")
    }

    // MARK: Short dates (§ 2.4)

    func testShortDates() {
        XCTAssertEqual(short(0).0, "Today")
        XCTAssertEqual(short(0).1, .today)
        XCTAssertEqual(short(1).0, "Tomorrow")
        XCTAssertEqual(short(1).1, .quiet)
        XCTAssertEqual(short(-1).0, "Yesterday")
        XCTAssertEqual(short(-1).1, .overdue)
        XCTAssertEqual(short(2).0, "Wed", "the weekday within the coming week")
        XCTAssertEqual(short(6).0, "Sun")
        XCTAssertEqual(short(43).0, "3 Nov", "day and month, no year this year")
        XCTAssertEqual(short(43).1, .quiet)
        XCTAssertEqual(short(-29).0, "Late 23 Aug", "an older overdue date")
        XCTAssertEqual(short(-29).1, .overdue)
        XCTAssertEqual(short(104).0, "3 Jan 2027", "the year when it isn't this year")
        XCTAssertEqual(short(-300).0, "Late 25 Nov 2025")
        // Localised: German short forms.
        let german = TasksNewText.shortDate(day(43), today: today, calendar: calendar, locale: Locale(identifier: "de_DE"))
        XCTAssertTrue(german.text.contains("Nov"), german.text)
    }

    func testPriorityMarksAndTagsAndSpokenMarks() {
        XCTAssertNil(TasksNewText.priorityMarks(.none))
        XCTAssertEqual(TasksNewText.priorityMarks(.low), "!")
        XCTAssertEqual(TasksNewText.priorityMarks(.high), "!!!")
        let tags = TasksNewText.tags(["a", "b", "c", "d"])
        XCTAssertEqual(tags.shown, ["a", "b"])
        XCTAssertEqual(tags.more, 2)
        var row = AtticTaskRowModel(title: "Pay")
        row.flagged = true
        row.photos = 2
        row.subtasks = (1, 3)
        let spoken = TasksNewText.accessibilityDescription(row, date: "Today")
        for word in ["flagged", "2 photos", "1 of 3 subtasks done", "due Today"] {
            XCTAssertTrue(spoken.contains(word), "VoiceOver reads \(word): \(spoken)")
        }
    }

    // MARK: The column that takes turns (D1)

    func testTheColumnTakesTurns() throws {
        typealias C = TasksNewColumn
        XCTAssertEqual(C.resolve(isDone: false, isKept: false, isHovered: false, isKeyboardSelected: false, hasDate: true, actionsAvailable: true), .date)
        XCTAssertEqual(C.resolve(isDone: false, isKept: false, isHovered: false, isKeyboardSelected: false, hasDate: false, actionsAvailable: true), .empty)
        XCTAssertEqual(C.resolve(isDone: false, isKept: false, isHovered: true, isKeyboardSelected: false, hasDate: true, actionsAvailable: true), .actions)
        XCTAssertEqual(C.resolve(isDone: false, isKept: false, isHovered: false, isKeyboardSelected: true, hasDate: false, actionsAvailable: true), .actions)
        XCTAssertEqual(C.resolve(isDone: false, isKept: false, isHovered: true, isKeyboardSelected: false, hasDate: true, actionsAvailable: false), .date,
                       "Done's rows have no Date or Move")
        XCTAssertEqual(C.resolve(isDone: true, isKept: true, isHovered: true, isKeyboardSelected: true, hasDate: true, actionsAvailable: true), .undo)
        XCTAssertEqual(C.resolve(isDone: true, isKept: false, isHovered: true, isKeyboardSelected: false, hasDate: true, actionsAvailable: true), .empty)

        let a = try add("Pay the bill")
        XCTAssertTrue(library.updateTask(a, dueDay: day(1)).isApplied)
        XCTAssertEqual(model.newColumn(for: a, isHovered: false, isKeyboardSelected: false), .date)
        XCTAssertEqual(model.newDate(for: a)?.text, "Tomorrow")
        XCTAssertTrue(model.complete(a).isApplied)
        XCTAssertEqual(model.newColumn(for: a, isHovered: false, isKeyboardSelected: false), .undo, "just ticked: Undo")
        XCTAssertTrue(model.undoKeptTick(a).isApplied)
        XCTAssertEqual(store.task(withID: a)?.status, .todo)
        XCTAssertEqual(model.newColumn(for: a, isHovered: false, isKeyboardSelected: false), .date)
    }

    // MARK: Ticked rows stay (4A)

    func testATickedTaskStaysUntilThePanelClosesOrTheListChanges() async throws {
        let a = try add("A")
        let b = try add("B")
        XCTAssertTrue(model.complete(a).isApplied)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(openIDs().contains(a), "nothing moves on a timer")
        model.select(tab: .backlog)
        model.select(tab: .now)
        XCTAssertFalse(openIDs().contains(a), "switching lists lets it go")

        XCTAssertTrue(model.complete(b).isApplied)
        XCTAssertTrue(model.isKeptDone(b))
        model.resetForReveal()
        XCTAssertFalse(openIDs().contains(b), "closing and reopening the panel lets it go")
        XCTAssertTrue(model.undo().isApplied, "⌘Z still undoes")
        XCTAssertEqual(store.task(withID: b)?.status, .todo)
    }

    // MARK: One capture path (§ 2.12)

    func testCaptureGoesToTheAddBarOnlyInNew() throws {
        let a = try add("A")
        model.selectOnly(a)
        let before = model.newAddBarRequest
        XCTAssertEqual(model.beginCapture(), .addBar)
        XCTAssertEqual(model.newAddBarRequest, before &+ 1, "the add bar is asked for the keyboard")
        XCTAssertFalse(model.replicaRowActive, "no hidden extra row under the list")
        XCTAssertTrue(model.selection.isEmpty)
        model.addBar.text = "Half typed"
        XCTAssertEqual(model.beginCapture(), .addBar)
        XCTAssertEqual(model.addBar.text, "Half typed", "the draft is kept")

        model.setListStyle(.reminders)
        XCTAssertEqual(model.beginCapture(), .replicaRow, "the replica keeps its own row")
        XCTAssertTrue(model.replicaRowActive)
        model.setListStyle(.new)
        XCTAssertFalse(model.replicaRowActive)
    }

    // MARK: Esc keeps edits (§ 2.13)

    func testEscapeInTheDetailPanelKeepsTheEditsInNew() throws {
        let a = try add("Old title")
        model.openReplicaDetail(a)
        model.replicaDetail?.draft.title = "New title"
        model.cancelReplicaDetail()
        XCTAssertNil(model.replicaDetail)
        XCTAssertEqual(store.task(withID: a)?.title, "New title", "Esc leaves and keeps")
        XCTAssertTrue(model.undo().isApplied, "⌘Z undoes")
        XCTAssertEqual(store.task(withID: a)?.title, "Old title")

        model.setListStyle(.reminders)
        model.openReplicaDetail(a)
        model.replicaDetail?.draft.title = "Dropped"
        model.cancelReplicaDetail()
        XCTAssertEqual(store.task(withID: a)?.title, "Old title", "the replica's Escape still cancels")
    }

    func testEscapeInTheListsFieldsKeepsWhatWasTyped() throws {
        let a = try add("Draft")
        model.selectOnly(a)
        model.beginEditingTitle(a)
        model.editingTitle = "Final"
        XCTAssertTrue(model.newEscapeEditing())
        XCTAssertNil(model.editingTitleID)
        XCTAssertEqual(store.task(withID: a)?.title, "Final", "a rename is kept")

        model.beginAddingSubtask(to: a)
        model.newSubtaskTitle = "Step one"
        XCTAssertTrue(model.newEscapeEditing())
        XCTAssertNil(model.newSubtaskParentID, "the field closes")
        XCTAssertEqual(store.subtasks(of: a).map(\.title), ["Step one"], "the typed subtask is kept")

        model.beginAddingSubtask(to: a)
        XCTAssertTrue(model.newEscapeEditing())
        XCTAssertEqual(store.subtasks(of: a).count, 1, "an empty field adds nothing")
    }

    // MARK: Tab and ⇧Tab (§ 2.14)

    func testTabIndentsUnderTheTaskAboveAndShiftTabOutdents() throws {
        let a = try add("Parent")
        let b = try add("Child")
        XCTAssertEqual(model.newIndent(.indent, row: b, above: a), .done(.applied))
        XCTAssertEqual(store.task(withID: b)?.parentID, a)
        XCTAssertTrue(model.undo().isApplied)
        XCTAssertNil(store.task(withID: b)?.parentID, "one undoable step")
        XCTAssertTrue(model.redo().isApplied)
        XCTAssertEqual(store.task(withID: b)?.parentID, a)

        guard case .refused = model.newIndent(.indent, row: a, above: nil) else {
            return XCTFail("the first task has nothing above it")
        }
        model.focusedSubtaskID = b
        XCTAssertEqual(model.newIndent(.outdent, row: nil, above: nil), .done(.applied))
        XCTAssertNil(store.task(withID: b)?.parentID, "⇧Tab makes it a task again")
        model.focusedSubtaskID = nil

        model.setListStyle(.attic)
        XCTAssertNil(model.newIndent(.indent, row: b, above: a), "only New indents this way")
    }

    // MARK: Single keys (6B)

    func testSingleKeysMapAndNeverTakeModifiers() {
        XCTAssertEqual(TasksNewKey.command(characters: " ", keyCode: 49, modifiers: []), .complete)
        XCTAssertEqual(TasksNewKey.command(characters: "d", keyCode: 2, modifiers: []), .date)
        XCTAssertEqual(TasksNewKey.command(characters: "l", keyCode: 37, modifiers: []), .move)
        XCTAssertEqual(TasksNewKey.command(characters: "t", keyCode: 17, modifiers: []), .tags)
        XCTAssertEqual(TasksNewKey.command(characters: "2", keyCode: 19, modifiers: []), .priority(2))
        XCTAssertEqual(TasksNewKey.command(characters: "D", keyCode: 2, modifiers: .capsLock), .date)
        XCTAssertNil(TasksNewKey.command(characters: "d", keyCode: 2, modifiers: .command), "⌘D stays Duplicate")
        XCTAssertNil(TasksNewKey.command(characters: "1", keyCode: 18, modifiers: [.command, .option]))
        XCTAssertNil(TasksNewKey.command(characters: "x", keyCode: 7, modifiers: []))
        XCTAssertEqual(TasksNewKey.priority(3, current: .none), .high)
        XCTAssertEqual(TasksNewKey.priority(3, current: .high), .none, "the same key again clears it")
    }

    func testSingleKeysActAndEveryOneUndoes() throws {
        let a = try add("A")
        XCTAssertEqual(model.newKey(.priority(3), on: [a]), .applied)
        XCTAssertEqual(store.task(withID: a)?.priority, .high)
        XCTAssertTrue(model.undo().isApplied)
        XCTAssertEqual(store.task(withID: a)?.priority, TaskPriority.none)

        XCTAssertEqual(model.newKey(.move, on: [a]), .applied)
        XCTAssertEqual(store.task(withID: a)?.status, .backlog, "L moves to Later")
        XCTAssertTrue(model.undo().isApplied)
        XCTAssertEqual(store.task(withID: a)?.status, .todo)

        XCTAssertEqual(model.newKey(.complete, on: [a]), .applied)
        XCTAssertEqual(store.task(withID: a)?.status, .done)
        XCTAssertTrue(model.undo().isApplied)
        XCTAssertEqual(store.task(withID: a)?.status, .todo)

        model.select(tab: .backlog)
        XCTAssertTrue(model.moveToBacklog([a]).isApplied)
        XCTAssertEqual(model.newKey(.move, on: [a]), .applied)
        XCTAssertEqual(store.task(withID: a)?.status, .todo, "L on Later moves to Now")

        XCTAssertNil(model.newKey(.date, on: [a]), "D opens the picker in the page")
        model.setListStyle(.attic)
        XCTAssertNil(model.newKey(.complete, on: [a]), "only in New")
    }

    // MARK: The bottom takes turns (§ 2.15, 6B)

    func testTheAddBarSelectionBarAndKeyStripTakeTurns() {
        typealias B = TasksNewBottom
        XCTAssertEqual(B.resolve(selectionCount: 0, listHasKeyboard: true, addBarFocused: false, onDone: false), .addBar)
        XCTAssertEqual(B.resolve(selectionCount: 1, listHasKeyboard: true, addBarFocused: false, onDone: false), .keyStrip)
        XCTAssertEqual(B.resolve(selectionCount: 1, listHasKeyboard: false, addBarFocused: false, onDone: false), .addBar,
                       "the keys are live only while the list has the keyboard")
        XCTAssertEqual(B.resolve(selectionCount: 3, listHasKeyboard: false, addBarFocused: false, onDone: false), .selectionBar,
                       "several selected: the selection bar instead of the add bar")
        XCTAssertEqual(B.resolve(selectionCount: 3, listHasKeyboard: true, addBarFocused: true, onDone: false), .addBar,
                       "⌘N brings the add bar back")
        XCTAssertEqual(B.resolve(selectionCount: 1, listHasKeyboard: true, addBarFocused: false, onDone: true), .addBar)
    }

    // MARK: Honest states (§ 2.16)

    func testNoMatchesIsNotNothingInNow() throws {
        XCTAssertEqual(model.newEmptyState(for: .now), .nothing(.now))
        _ = try add("Buy milk")
        XCTAssertNil(model.newEmptyState(for: .now))
        model.setSearchQuery("zzz", for: .now)
        XCTAssertEqual(model.newEmptyState(for: .now), .noMatches)
    }
}
