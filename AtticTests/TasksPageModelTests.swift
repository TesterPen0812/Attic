import AppKit
import SwiftData
import XCTest
@testable import Attic

/// The Tasks page's model: what each list shows and in what order, what
/// every action does (always one undoable step), the add bar's chips and
/// shorthand, the Done log, and how rows read.
@MainActor
final class TasksPageModelTests: XCTestCase {
    /// Mon 21 Sep 2026, 14:13 UTC.
    private let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000))
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private var store: TaskStore!
    private var library: AtticLibrary!
    private var model: TasksPageModel!
    private var opened: [UUID] = []

    override func setUp() async throws {
        store = try makeTestStore(now: { [clock] in clock.value })
        library = AtticLibrary(tasks: store, now: { [clock] in clock.value })
        let calendar = self.calendar
        model = TasksPageModel(library: library, services: TasksPageServices(
            openPage: { [weak self] in self?.opened.append($0) },
            now: { [clock] in clock.value },
            calendar: { calendar },
            locale: Locale(identifier: "en_GB"),
            doneHold: .seconds(3_600)
        ))
        model.toasts.holdDuration = 3_600
    }

    override func tearDown() {
        model = nil
        library = nil
        store = nil
    }

    private func titles(_ tab: TasksTab) -> [String] { model.rows(for: tab).map(\.model.title) }

    @discardableResult
    private func add(_ text: String, tab: TasksTab = .now) -> UUID? {
        model.select(tab: tab)
        model.addBar.text = text
        return model.submitAddBar()
    }

    func testAR08TabAndShiftTabPreserveExtendedSelectionButReturnUsesNewFocus() throws {
        let a = try XCTUnwrap(add("A")), b = try XCTUnwrap(add("B")), c = try XCTUnwrap(add("C"))
        let visible = [a, b, c]
        model.selectOnly(a)
        model.extendSelection(to: b, visible: visible)
        XCTAssertEqual(model.selection, [a, b])
        model.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.now.rawValue, id: c), keyboardDriving: true)
        XCTAssertEqual(model.selection, [a, b], "Tab preserves the extended selection")
        XCTAssertEqual(model.keyboardRow(focused: c, visible: visible), c, "the later key uses the visible focus")
        model.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.now.rawValue, id: b), keyboardDriving: true)
        XCTAssertEqual(model.selection, [a, b], "Shift-Tab preserves it too")
        XCTAssertEqual(model.keyboardRow(focused: b, visible: visible), b)
        model.selectOnly(a)
        XCTAssertEqual(model.keyboardRow(focused: b, visible: visible), a, "a later menu selection supersedes old focus")
    }

    // MARK: - Lists

    func testNowIsInProgressThenToDoThenDoneAndBacklogIsItsOwnList() throws {
        let a = try XCTUnwrap(add("A"))
        _ = try XCTUnwrap(add("B"))
        let c = try XCTUnwrap(add("C"))
        _ = try XCTUnwrap(add("Idea", tab: .backlog))
        model.select(tab: .now)
        model.toggleWorking([a])    // to do → in progress (⇧Space, the menu)
        model.toggleDone(c)         // done (held in place for now)
        XCTAssertEqual(titles(.now), ["A", "C", "B"], "a finished row holds its place")
        XCTAssertEqual(model.completedTodayCount, 0, "it joins Completed today once it moves")
        model.releaseHold(c)
        XCTAssertEqual(titles(.now), ["A", "B"], "done rows recede into Completed today")
        XCTAssertEqual(model.sections(for: .now).done.map(\.model.title), ["C"])
        XCTAssertEqual(model.completedTodayCount, 1)
        model.toggleCompletedToday()
        XCTAssertEqual(titles(.now), ["A", "B", "C"], "open, the done rows follow the open ones")
        XCTAssertEqual(model.rows(for: .now).map(\.model.state), [.inProgress, .todo, .done])
        model.resetForReveal()
        XCTAssertTrue(model.completedTodayExpanded, "Completed today stays open for the session")
        XCTAssertEqual(titles(.backlog), ["Idea"])
        XCTAssertEqual(model.nowCount, 2)
        XCTAssertEqual(model.backlogCount, 1)
        XCTAssertTrue(model.hasDoneToday)
    }

    /// The model's side of the circle (Direction A: one click completes,
    /// another puts the task back as it was; ⇧Space starts and stops).
    func testTheCircleCompletesInOneClickAndRestoresThePreviousState() throws {
        let id = try XCTUnwrap(add("Task"))
        _ = try XCTUnwrap(add("Other"))
        XCTAssertEqual(titles(.now), ["Other", "Task"])
        model.toggleDone(id)
        XCTAssertEqual(store.task(withID: id)?.status, .done, "one click completes")
        model.toggleDone(id)
        XCTAssertEqual(store.task(withID: id)?.status, .todo, "a second click puts it back")
        XCTAssertEqual(titles(.now), ["Other", "Task"], "right after finishing, it keeps its place")

        model.toggleWorking([id])
        XCTAssertEqual(store.task(withID: id)?.status, .inProgress)
        model.toggleWorking([id])
        XCTAssertEqual(store.task(withID: id)?.status, .todo, "⇧Space again stops working")
        model.toggleWorking([id])
        model.toggleDone(id)
        model.releaseHold(id)
        _ = try XCTUnwrap(add("Later step"))   // the completion is no longer the latest step
        model.toggleDone(id)
        XCTAssertEqual(store.task(withID: id)?.status, .inProgress, "a finished task goes back to what it was")

        let idea = try XCTUnwrap(add("Idea", tab: .backlog))
        model.toggleDone(idea)
        XCTAssertEqual(store.task(withID: idea)?.status, .done, "Later's circle completes too")
        XCTAssertEqual(titles(.backlog), ["Idea"], "and the row holds its place on Later")
        model.releaseHold(idea)
        XCTAssertEqual(titles(.backlog), [])
        model.select(tab: .now)
        model.toggleDone(idea)
        XCTAssertEqual(store.task(withID: idea)?.status, .backlog, "back to Later, where it was")
    }

    /// The right-click menu on several tasks: all done, then all back.
    func testCompletingSeveralTasksFromTheMenu() throws {
        let a = try XCTUnwrap(add("A"))
        let b = try XCTUnwrap(add("B"))
        model.toggleWorking([a])
        model.toggleDone([a, b])
        XCTAssertEqual(store.task(withID: a)?.status, .done)
        XCTAssertEqual(store.task(withID: b)?.status, .done)
        model.toggleDone([a, b])
        XCTAssertEqual(store.task(withID: a)?.status, .inProgress)
        XCTAssertEqual(store.task(withID: b)?.status, .todo)
    }

    /// Direction A's empty states: Now says why it is empty; Later has its own.
    func testEmptyListsSayWhyTheyAreEmpty() throws {
        XCTAssertEqual(model.emptyMessage[.now], "Add your first task")
        XCTAssertEqual(model.emptyMessage[.backlog], "Nothing for later")
        _ = try XCTUnwrap(add("Idea", tab: .backlog))
        XCTAssertEqual(model.emptyMessage[.now], "Nothing active")
        XCTAssertTrue(model.offersLater, "with \"Choose from Later\" under it")
        let done = try XCTUnwrap(add("Water plants"))
        model.complete(done)
        XCTAssertEqual(model.emptyMessage[.now], "You’re caught up")
    }

    func testMovesAndDeletesShowAnUndoToastAndUndoPutsThemBack() throws {
        let a = try XCTUnwrap(add("A"))
        let b = try XCTUnwrap(add("B"))
        model.moveToBacklog([a])
        XCTAssertEqual(model.toasts.current?.message, "Moved to Later")
        XCTAssertEqual(titles(.backlog), ["A"])
        model.undo()
        XCTAssertNil(model.toasts.current)
        XCTAssertEqual(store.task(withID: a)?.status, .todo)

        model.click(a, modifiers: [], visible: [b, a])
        model.click(b, modifiers: .command, visible: [b, a])
        XCTAssertEqual(model.selection, [a, b])
        XCTAssertEqual(Set(model.targets(for: a)), [a, b])
        model.delete(model.targets(for: a))
        XCTAssertEqual(model.toasts.current?.message, "Deleted 2 tasks")
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertTrue(model.selection.isEmpty)
        model.undo()
        XCTAssertEqual(Set(store.tasks.map(\.id)), [a, b])
    }

    func testClickSelectionTogglesAndExtends() throws {
        let ids = (0..<4).map { _ in UUID() }
        model.click(ids[1], modifiers: [], visible: ids)
        model.click(ids[3], modifiers: .shift, visible: ids)
        XCTAssertEqual(model.selection, Set(ids[1...3]))
        model.click(ids[2], modifiers: .command, visible: ids)
        XCTAssertEqual(model.selection, [ids[1], ids[3]])
        model.click(ids[0], modifiers: [], visible: ids)
        XCTAssertEqual(model.selection, [ids[0]])
    }

    /// ⌘↑ ⌘↓ and the drop a drag ends in (the drag gesture itself is driven
    /// in `TasksPageUITests`).
    func testReorderMovesAreOneUndoableStepEach() throws {
        let a = try XCTUnwrap(add("A"))
        _ = try XCTUnwrap(add("B"))
        _ = try XCTUnwrap(add("C"))
        XCTAssertEqual(titles(.now), ["C", "B", "A"])
        model.moveBy(a, offset: -1)
        XCTAssertEqual(titles(.now), ["C", "A", "B"])
        model.move(a, toGroupIndex: 0)
        XCTAssertEqual(titles(.now), ["A", "C", "B"])
        model.undo()
        XCTAssertEqual(titles(.now), ["C", "A", "B"])
    }

    func testTitleEditingAndSubtasksInTheQuickLook() throws {
        let id = try XCTUnwrap(add("Plan trip"))
        model.beginEditingTitle(id)
        XCTAssertEqual(model.editingTitle, "Plan trip")
        model.editingTitle = "Plan the trip"
        model.commitTitle()
        XCTAssertEqual(store.task(withID: id)?.title, "Plan the trip")
        XCTAssertNil(model.editingTitleID)

        model.beginAddingSubtask(to: id)
        XCTAssertTrue(model.expanded.contains(id))
        model.newSubtaskTitle = "Book flights #travel"
        model.commitNewSubtask()
        XCTAssertEqual(model.newSubtaskParentID, id, "the field stays for the next subtask")
        XCTAssertEqual(model.newSubtaskTitle, "")
        let subtask = try XCTUnwrap(store.subtasks(of: id).first)
        XCTAssertEqual(subtask.title, "Book flights")
        XCTAssertEqual(subtask.tags, ["travel"])
        XCTAssertEqual(model.rows(for: .now).first?.subtasks.map(\.title), ["Book flights"])
        XCTAssertEqual(model.rows(for: .now).first?.model.subtasks?.total, 1)

        model.toggleSubtask(subtask.id)
        XCTAssertEqual(store.task(withID: subtask.id)?.status, .done)
        model.complete(id)
        XCTAssertEqual(store.task(withID: id)?.status, .done)
        model.toggleExpanded(id)
        XCTAssertFalse(model.expanded.contains(id))
    }

    // MARK: - Add bar

    func testTheAddBarUnderstandsShorthandAndFollowsThePage() throws {
        let id = try XCTUnwrap(add("Call mom fri #family !!"))
        let task = try XCTUnwrap(store.task(withID: id))
        XCTAssertEqual(task.title, "Call mom")
        XCTAssertEqual(task.tags, ["family"])
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.dueDay, DueDay(year: 2026, month: 9, day: 25))
        XCTAssertEqual(model.addBar.text, "", "the bar clears and keeps focus for the next one")
        XCTAssertEqual(model.addPlaceholder, "Add a task")

        let idea = try XCTUnwrap(add("Paint the fence", tab: .backlog))
        XCTAssertEqual(store.task(withID: idea)?.status, .backlog)
        XCTAssertEqual(model.addPlaceholder, "Add to later")
        XCTAssertNil(add("   "), "blank text adds nothing")

        model.select(tab: .now)
        model.addBar.text = "Ship it"
        let opened = try XCTUnwrap(model.submitAddBar(openingPage: true))
        XCTAssertEqual(self.opened, [opened], "⌘Return adds and opens the task's page")

        // On Done the bar still adds, to Now, and says so.
        model.select(tab: .done)
        XCTAssertEqual(model.addPlaceholder, "Add a task")
        model.addBar.text = "From Done"
        let fromDone = try XCTUnwrap(model.submitAddBar())
        XCTAssertEqual(store.task(withID: fromDone)?.status, .todo)
        XCTAssertEqual(model.toasts.current?.message, "Added to Now")
    }

    func testChipsFormOnceAWordIsFinishedAndBackspaceTurnsOneBackIntoText() throws {
        var bar = TaskAddBarText(text: "Call fri #home")
        let parser = model.parser
        let fri = NSRange(location: 5, length: 3)
        let home = NSRange(location: 9, length: 5)
        XCTAssertEqual(bar.chips(parser: parser, caret: 14), [fri], "the tag being typed is not a chip yet")
        XCTAssertEqual(bar.chips(parser: parser, caret: nil), [fri, home])
        bar.dismiss(fri)
        XCTAssertEqual(bar.chips(parser: parser, caret: nil), [home])
        let draft = try XCTUnwrap(bar.draft(parser: parser, status: .todo))
        XCTAssertEqual(draft.title, "Call fri", "a dismissed piece stays as text")
        XCTAssertNil(draft.dueDay)
        XCTAssertEqual(draft.tags, ["home"])

        // Typing before it moves it; typing a space after it keeps it; typing
        // straight on from its end joins the word and forgets it.
        bar.text = "Now call fri #home"
        bar.edited(NSRange(location: 0, length: 0), replacement: "Now ")
        XCTAssertEqual(bar.dismissed, [NSRange(location: 9, length: 3)])
        bar.edited(NSRange(location: 12, length: 0), replacement: " ")
        XCTAssertEqual(bar.dismissed, [NSRange(location: 9, length: 3)])
        bar.edited(NSRange(location: 12, length: 0), replacement: "day")
        XCTAssertTrue(bar.dismissed.isEmpty)

        XCTAssertEqual(TaskAddBarText(text: "#home").draft(parser: parser, status: .todo)?.title, "#home",
                       "a line that is only pieces keeps its text")
        XCTAssertEqual(TaskAddBarText(text: "Call mom!").draft(parser: parser, status: .todo)?.priority, TaskPriority.none,
                       "a ! inside a word stays text")
    }

    func testPastedLinesOfferManyTasksOrOne() throws {
        XCTAssertNil(TaskPasteOffer("one line"))
        let offer = try XCTUnwrap(TaskPasteOffer("- Milk\n- Eggs #shop\n\n- Bread"))
        XCTAssertEqual(offer.lineCount, 3)
        model.pasteOffer = offer
        model.acceptPaste(asOne: false)
        XCTAssertNil(model.pasteOffer)
        XCTAssertEqual(titles(.now), ["Milk", "Eggs", "Bread"])
        XCTAssertEqual(store.tasks.first { $0.title == "Eggs" }?.tags, ["shop"])
        model.undo()
        XCTAssertTrue(store.tasks.isEmpty, "the batch is one step")
        model.pasteOffer = offer
        model.acceptPaste(asOne: true)
        XCTAssertEqual(titles(.now), ["Milk Eggs Bread"])
    }

    // MARK: - Done log

    func testTheDoneLogGroupsByDaySearchesAndRestoresToNow() throws {
        let old = try XCTUnwrap(add("Invoice"))
        model.complete(old)
        clock.value = clock.value.addingTimeInterval(2 * 86_400)   // Wed 23 Sep
        XCTAssertEqual(store.moveCompletedToDoneLog(before: calendar.startOfDay(for: clock.value)), 1)
        let today = try XCTUnwrap(add("Water plants"))
        model.complete(today)
        model.select(tab: .done)
        model.loadDoneLogIfNeeded()
        let days = model.doneDays()
        XCTAssertEqual(days.first?.title, "Today")
        XCTAssertTrue(days.last?.title.hasPrefix("Mon 21 Sep") == true, days.last?.title ?? "")
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days.map { $0.rows.map(\.model.title) }, [["Water plants"], ["Invoice"]])

        model.doneSearch = "voice"
        model.loadDoneLogIfNeeded()
        XCTAssertEqual(model.doneDays().flatMap { $0.rows.map(\.model.title) }, ["Invoice"])

        model.restoreToNow(old)
        XCTAssertEqual(model.toasts.current?.message, "Restored to Now")
        XCTAssertEqual(store.task(withID: old)?.status, .todo)
        XCTAssertTrue(model.doneDays().isEmpty)
        model.undo()
        XCTAssertNil(store.task(withID: old), "undo returns it to the Done log")
    }

    // MARK: - How rows read

    func testDueDatesReadAsTheSpecSays() {
        let today = DueDay(year: 2026, month: 9, day: 21)!
        let locale = Locale(identifier: "en_GB")
        func due(_ day: Int, month: Int = 9, year: Int = 2026) -> AtticTaskRowModel.Due {
            TaskRowPresentation.due(DueDay(year: year, month: month, day: day)!, today: today, calendar: calendar, locale: locale)
        }
        XCTAssertEqual(due(21).text, "Today")
        XCTAssertEqual(due(21).tone, .today, "today reads in the body colour, not red")
        XCTAssertEqual(due(20).text, "Yesterday")
        XCTAssertEqual(due(20).tone, .overdue)
        XCTAssertTrue(due(14).text.hasPrefix("14 Sep"), due(14).text)
        XCTAssertEqual(due(14).tone, .overdue, "only overdue is red")
        XCTAssertEqual(due(22).text, "Tomorrow")
        XCTAssertEqual(due(22).tone, .quiet)
        XCTAssertEqual(due(25).text, "Fri")
        XCTAssertEqual(due(27).text, "Sun")
        XCTAssertTrue(due(28).text.hasPrefix("28 Sep"), "a week or more away is a short date")
        XCTAssertEqual(due(5, month: 1, year: 2027).text, "5 Jan 2027")
    }

    func testKeyboardFocusRingsShowOnlyWhileTheKeyboardDrives() {
        let tracker = AtticKeyboardFocusTracker()
        tracker.observe(.keyDown, keyCode: 0) // typing "a"
        XCTAssertFalse(tracker.isKeyboardDriving, "typing is not navigating")
        tracker.observe(.keyDown, keyCode: 48) // Tab
        XCTAssertTrue(tracker.isKeyboardDriving)
        tracker.observe(.leftMouseDown, keyCode: nil)
        XCTAssertFalse(tracker.isKeyboardDriving, "a click hides the rings")
        tracker.observe(.keyDown, keyCode: 125) // ↓
        XCTAssertTrue(tracker.isKeyboardDriving)
    }

    func testThePanelKeepsOnePageModelOverTheAppsCommandLayer() {
        let state = TasksPageState()
        let toasts = PanelToastCenter()
        let first = state.model(for: store, toasts: toasts)
        XCTAssertTrue(first.library === library, "the page records its steps in the app's undo history")
        XCTAssertTrue(state.model(for: store, toasts: toasts) === first, "the page's state survives page switches")
        XCTAssertTrue(first.toasts === toasts, "the page posts to the shell's one toast host")
    }

    /// One Undo toast: the page posts to the shell's host, whose button
    /// undoes the step; ⌘Z (the page's undo) takes the page's own toast
    /// away but never another page's.
    func testThePagesUndoToastIsTheShellsToast() throws {
        let toasts = PanelToastCenter()
        let page = TasksPageModel(library: library, toasts: toasts)
        let a = try XCTUnwrap(add("A"))
        page.moveToBacklog([a])
        XCTAssertEqual(toasts.current?.message, "Moved to Later")
        XCTAssertEqual(toasts.current?.actionTitle, "Undo")
        toasts.performAction()
        XCTAssertNil(toasts.current)
        XCTAssertEqual(store.task(withID: a)?.status, .todo, "the toast's Undo puts the task back")

        toasts.show("Note deleted") {}
        page.undo()
        XCTAssertEqual(toasts.current?.message, "Note deleted", "⌘Z on Tasks leaves another page's toast")
    }

    func testTabsResetToNowWhenThePageOpens() {
        model.select(tab: .done)
        model.resetForReveal()
        XCTAssertEqual(model.tab, .now)
    }

    /// Search (the menu-bar item) opens the Done page's search field (the
    /// add bar keeps adding); the reveal that follows keeps it there until
    /// the panel hides, and the next reveal opens on Now again.
    func testSearchOpensTheDonePageUntilThePanelHides() {
        model.beginSearch()
        XCTAssertEqual(model.tab, .done)
        XCTAssertTrue(model.pendingSearchFocus, "the keyboard goes to the search field")
        XCTAssertEqual(model.searchPlaceholder, "Search done tasks")
        XCTAssertEqual(model.addPlaceholder, "Add a task")
        model.resetForReveal()
        XCTAssertEqual(model.tab, .done, "the reveal that Search caused keeps the search")
        model.pageDidHide()
        model.resetForReveal()
        XCTAssertEqual(model.tab, .now)

        model.beginSearch()
        model.select(tab: .backlog)
        model.resetForReveal()
        XCTAssertEqual(model.tab, .now, "moving away ends the search")
    }

    /// An agent's `show` of a task: the tab that lists it, the row alone
    /// selected and scrolled into view; a subtask shows in its parent's
    /// quick look.
    func testShowingATaskSelectsItOnItsTab() throws {
        let parked = try XCTUnwrap(add("Parked", tab: .backlog))
        XCTAssertEqual(model.show(parked), .shown)
        XCTAssertEqual(model.tab, .backlog)
        XCTAssertEqual(model.selection, [parked])
        XCTAssertEqual(model.scrollRequest?.id, parked)
        model.resetForReveal()
        XCTAssertEqual(model.tab, .backlog)
        XCTAssertEqual(model.selection, [parked], "the reveal keeps what show selected")

        let parent = try XCTUnwrap(add("Plan"))
        let child = try XCTUnwrap(store.create(title: "Step", parentID: parent)?.id)
        XCTAssertEqual(model.show(child), .shown)
        XCTAssertEqual(model.tab, .now)
        XCTAssertEqual(model.selection, [parent])
        XCTAssertTrue(model.expanded.contains(parent))
        XCTAssertEqual(model.show(UUID()), .missing)
    }
}
